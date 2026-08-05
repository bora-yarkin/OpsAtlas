# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Business logic for localization runtime data, catalog admin, and translation queue processing."""

from __future__ import annotations

from collections import deque
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import base64
import hashlib
import json
from pathlib import Path
import re
from typing import Any
from urllib import error as url_error
from urllib import parse as url_parse
from urllib import request as url_request
import uuid

from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.deps import bad_request, not_found
from app.core.secret_crypto import decrypt_secret, encrypt_secret, is_current_secret_encryption
from app.modules.admin.models import (
    OrganizationAuditEvent,
    OrganizationItemLink,
    OrganizationUnit,
)
from .models import (
    LocalizationBundle,
    LocalizationLanguage,
    LocalizationTranslationJob,
    LocalizationTranslationSetting,
    LocalizationTranslationSource,
    LocalizationTranslationVariant,
    OrganizationLocalizationSetting,
    UserLocalizationPreference,
)

# Validation and normalization rules used across catalog, bundle, and queue flows.
_LANGUAGE_CODE_RE = re.compile(r"^[a-z]{2,3}(?:-[a-z0-9]{2,8})*$")
_TRANSLATION_KEY_RE = re.compile(r"^[a-z0-9_]+$")
_CONTENT_KIND_RE = re.compile(r"^[a-z0-9][a-z0-9_.-]{1,79}$")
_FIELD_KEY_RE = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,119}$")
_TRANSLATION_PROVIDER_RE = re.compile(r"^[a-z0-9][a-z0-9_.-]{1,31}$")
_URL_RE = re.compile(r"^https?://", flags=re.IGNORECASE)
_MAX_SOURCE_TEXT_LENGTH = 24_000
_DEFAULT_TRANSLATION_PROMPT = "You are a localization engine. Translate the provided source text exactly " "into the target language while preserving placeholders, markdown, urls, " "and product names. Return only the translated text."

# Provider presets drive both admin UI defaults and runtime request shaping.
_PROVIDER_DEFAULTS: dict[str, dict[str, Any]] = {
    "openai": {
        "label": "OpenAI",
        "default_base_url": "https://api.openai.com/v1",
        "default_model": "gpt-5-mini",
        "models": (
            {"id": "gpt-5-mini", "label": "GPT-5 Mini", "usage_multiplier": 1.0},
            {"id": "gpt-5", "label": "GPT-5", "usage_multiplier": 1.8},
            {"id": "gpt-5-nano", "label": "GPT-5 Nano", "usage_multiplier": 0.45},
            {"id": "gpt-4.1-mini", "label": "GPT-4.1 Mini", "usage_multiplier": 0.65},
        ),
    },
    "gemini": {
        "label": "Gemini",
        "default_base_url": "https://generativelanguage.googleapis.com/v1beta",
        "default_model": "gemini-3-flash",
        "models": (
            {"id": "gemini-3-flash", "label": "Gemini 3 Flash", "usage_multiplier": 0.85},
            {"id": "gemini-3-pro", "label": "Gemini 3 Pro", "usage_multiplier": 1.4},
            {"id": "gemini-2.5-flash", "label": "Gemini 2.5 Flash", "usage_multiplier": 0.6},
            {
                "id": "gemini-2.5-flash-lite",
                "label": "Gemini 2.5 Flash Lite",
                "usage_multiplier": 0.35,
            },
        ),
    },
    "custom": {
        "label": "Custom HTTP",
        "default_base_url": "",
        "default_model": "custom-model",
        "models": ({"id": "custom-model", "label": "Custom Model", "usage_multiplier": 1.0},),
    },
}

# Lightweight heuristics help infer a source language when writers do not supply one.
_LANGUAGE_DETECTION_STOPWORDS: dict[str, tuple[str, ...]] = {
    "en": (
        "the",
        "and",
        "for",
        "with",
        "from",
        "your",
        "this",
        "that",
        "please",
    ),
    "tr": (
        "ve",
        "ile",
        "için",
        "bir",
        "olan",
        "bu",
        "şu",
        "lütfen",
        "kullanıcı",
    ),
    "de": (
        "und",
        "für",
        "mit",
        "ist",
        "nicht",
        "bitte",
        "benutzer",
        "konto",
        "sprache",
    ),
}
_LANGUAGE_DETECTION_CHARS: dict[str, str] = {
    "tr": "çğıöşüİı",
    "de": "äöüß",
}
_TERMINAL_JOB_STATES = frozenset({"done", "failed"})
_ACTIVE_JOB_STATES = frozenset({"queued", "retry", "processing"})
_REVIEWABLE_VARIANT_STATES = frozenset({"translated", "needs_review", "approved", "fallback", "failed", "locked"})
_DISPLAYABLE_VARIANT_STATES = frozenset({"translated", "needs_review", "approved", "fallback", "locked"})

_DEFAULT_LANGUAGES: tuple[dict[str, Any], ...] = (
    {
        "code": "en",
        "name": "English",
        "enabled": True,
        "is_default": True,
        "is_rtl": False,
        "fallback_order": ["en"],
    },
    {
        "code": "tr",
        "name": "Turkish",
        "enabled": True,
        "is_default": False,
        "is_rtl": False,
        "fallback_order": ["tr", "en"],
    },
    {
        "code": "de",
        "name": "German",
        "enabled": True,
        "is_default": False,
        "is_rtl": False,
        "fallback_order": ["de", "en"],
    },
)

_DEFAULT_REFERENCE_KEYS: tuple[str, ...] = (
    "dashboard",
    "account",
    "login",
    "search",
    "save",
    "cancel",
    "language",
    "organization_access",
)

_SourceSignature = tuple[tuple[str, float], ...]

# Source-derived caches avoid reparsing client localization assets on every request.
_REFERENCE_KEYS_CACHE: tuple[_SourceSignature, tuple[str, ...]] | None = None
_BUILTIN_BUNDLES_CACHE: tuple[_SourceSignature, dict[str, dict[str, str]]] | None = None


@dataclass(frozen=True)
class ValidationIssue:
    """Structured validation message returned by import and health operations."""
    code: str
    message: str


@dataclass(frozen=True)
class ImportLanguageResult:
    """Summary of one language bundle updated during import."""
    code: str
    entry_count: int
    bundle_version: int


@dataclass(frozen=True)
class TranslationResult:
    """Normalized translation provider response."""
    translated_text: str
    confidence: float | None
    provider: str
    model: str


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _normalize_language_code(value: object | None) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = value.strip().replace("_", "-").lower()
    if not normalized:
        return None
    if not _LANGUAGE_CODE_RE.fullmatch(normalized):
        return None
    return normalized


def _normalize_translation_key(value: object | None) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = value.strip()
    if not normalized:
        return None
    if not _TRANSLATION_KEY_RE.fullmatch(normalized):
        return None
    return normalized


def _string_or_default(value: object | None, *, default: str) -> str:
    if isinstance(value, str):
        candidate = value.strip()
        if candidate:
            return candidate
    return default


def _normalize_content_kind(value: object | None) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = value.strip().lower()
    if not normalized:
        return None
    if not _CONTENT_KIND_RE.fullmatch(normalized):
        return None
    return normalized


def _normalize_field_key(value: object | None) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = value.strip().lower()
    if not normalized:
        return None
    if not _FIELD_KEY_RE.fullmatch(normalized):
        return None
    return normalized


def _normalize_provider(value: object | None) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = value.strip().lower()
    if not normalized:
        return None
    if not _TRANSLATION_PROVIDER_RE.fullmatch(normalized):
        return None
    return normalized


def _text_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _source_key(content_kind: str, content_id: str, field_key: str) -> str:
    basis = f"{content_kind}|{content_id}|{field_key}"
    return hashlib.sha256(basis.encode("utf-8")).hexdigest()


def _idempotency_key(
    *,
    source_id: str,
    source_hash: str,
    language_code: str,
    provider: str,
    model: str,
) -> str:
    basis = "|".join([source_id, source_hash, language_code, provider, model])
    return hashlib.sha256(basis.encode("utf-8")).hexdigest()


def _normalize_api_base_url(value: object | None) -> str | None:
    if not isinstance(value, str):
        return None
    raw = value.strip()
    if not raw:
        return None
    if not _URL_RE.match(raw):
        raise bad_request("Translation API base URL must start with http:// or https://")
    return raw.rstrip("/")


def _provider_default(provider: str) -> dict[str, Any]:
    return _PROVIDER_DEFAULTS.get(provider, _PROVIDER_DEFAULTS["custom"])


def _provider_default_base_url(provider: str) -> str | None:
    raw = _provider_default(provider).get("default_base_url")
    if not isinstance(raw, str) or not raw.strip():
        return None
    return raw.strip().rstrip("/")


def _provider_default_model(provider: str) -> str:
    raw = _provider_default(provider).get("default_model")
    if isinstance(raw, str) and raw.strip():
        return raw.strip()
    return "custom-model"


def _provider_defaults_catalog() -> dict[str, dict[str, object]]:
    catalog: dict[str, dict[str, object]] = {}
    for provider, payload in _PROVIDER_DEFAULTS.items():
        models_payload = payload.get("models")
        models: list[dict[str, object]] = []
        if isinstance(models_payload, Sequence):
            for item in models_payload:
                if not isinstance(item, Mapping):
                    continue
                model_id = str(item.get("id", "")).strip()
                if not model_id:
                    continue
                model_label = str(item.get("label", model_id)).strip() or model_id
                multiplier = item.get("usage_multiplier", 1.0)
                try:
                    usage_multiplier = round(float(multiplier), 3)
                except Exception:
                    usage_multiplier = 1.0
                models.append(
                    {
                        "id": model_id,
                        "label": model_label,
                        "usage_multiplier": usage_multiplier,
                    }
                )
        catalog[provider] = {
            "label": str(payload.get("label", provider)),
            "default_base_url": _provider_default_base_url(provider),
            "default_model": _provider_default_model(provider),
            "models": models,
        }
    return catalog


def _seal_secret(value: str | None) -> str | None:
    return encrypt_secret(value)


def _legacy_unseal_secret(value: str | None) -> str | None:
    if not isinstance(value, str):
        return None
    raw = value.strip()
    if not raw:
        return None
    try:
        payload = base64.urlsafe_b64decode(raw.encode("ascii"))
    except Exception:
        return None
    seed = str(getattr(settings, "jwt_secret", "opsatlas-localization-secret")).encode("utf-8")
    if not seed:
        seed = b"opsatlas-localization-secret"
    transformed = bytes(payload[idx] ^ seed[idx % len(seed)] for idx in range(len(payload)))
    try:
        return transformed.decode("utf-8")
    except Exception:
        return None


def _unseal_secret(value: str | None) -> str | None:
    decrypted = decrypt_secret(value)
    if decrypted is not None:
        return decrypted
    return _legacy_unseal_secret(value)


def _secret_needs_reseal(value: str | None) -> bool:
    if not isinstance(value, str):
        return False
    raw = value.strip()
    if not raw:
        return False
    if not raw.startswith("v1:"):
        return True
    return not is_current_secret_encryption(raw)


def _safe_int(value: object | None, *, default: int, minimum: int, maximum: int) -> int:
    try:
        parsed = int(value)  # type: ignore[arg-type]
    except Exception:
        return default
    return max(minimum, min(maximum, parsed))


def _json_dump(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _json_load_dict(value: object | None) -> dict[str, Any]:
    if not isinstance(value, str) or not value.strip():
        return {}
    try:
        decoded = json.loads(value)
    except Exception:
        return {}
    if isinstance(decoded, dict):
        return {str(k): v for k, v in decoded.items()}
    return {}


def _json_load_list(value: object | None) -> list[Any]:
    if not isinstance(value, str) or not value.strip():
        return []
    try:
        decoded = json.loads(value)
    except Exception:
        return []
    if isinstance(decoded, list):
        return decoded
    return []


def _normalize_fallback_order(raw: object | None, *, default_code: str) -> list[str]:
    values: list[str] = []
    if isinstance(raw, list):
        candidates = raw
    elif isinstance(raw, tuple):
        candidates = list(raw)
    else:
        candidates = []
    seen: set[str] = set()
    for item in candidates:
        code = _normalize_language_code(item)
        if code is None or code in seen:
            continue
        seen.add(code)
        values.append(code)
    if default_code not in seen:
        values.insert(0, default_code)
    return values


def _reference_source_path() -> Path:
    return Path(__file__).resolve().parents[4] / "client/lib/core/i18n/app_localizations.dart"


def _split_bundle_source_paths() -> dict[str, Path]:
    sources: dict[str, Path] = {}
    for source in sorted(_reference_source_path().parent.glob("app_localizations_*.dart")):
        raw_code = source.stem.removeprefix("app_localizations_").replace("_", "-")
        code = _normalize_language_code(raw_code)
        if code is not None:
            sources[code] = source
    return sources


def _bundle_source_signature() -> _SourceSignature:
    paths = [_reference_source_path(), *_split_bundle_source_paths().values()]
    signature: list[tuple[str, float]] = []
    for path in paths:
        try:
            signature.append((str(path), path.stat().st_mtime))
        except OSError:
            continue
    return tuple(signature)


def _decode_dart_single_quoted_literal(raw: str) -> str:
    mapped_escapes = {
        "n": "\n",
        "r": "\r",
        "t": "\t",
        "b": "\b",
        "f": "\f",
        "'": "'",
        '"': '"',
        "\\": "\\",
        "$": "$",
    }
    out: list[str] = []
    idx = 0
    while idx < len(raw):
        char = raw[idx]
        if char != "\\":
            out.append(char)
            idx += 1
            continue
        idx += 1
        if idx >= len(raw):
            break
        escaped = raw[idx]
        if escaped == "u" and idx + 4 < len(raw):
            hex_part = raw[idx + 1 : idx + 5]
            if re.fullmatch(r"[0-9a-fA-F]{4}", hex_part):
                out.append(chr(int(hex_part, 16)))
                idx += 5
                continue
        out.append(mapped_escapes.get(escaped, escaped))
        idx += 1
    return "".join(out)


def _extract_balanced_brace_block(content: str, start_index: int) -> tuple[str, int]:
    if start_index < 0 or start_index >= len(content) or content[start_index] != "{":
        return "", start_index

    depth = 0
    in_string = False
    escaped = False
    for idx in range(start_index, len(content)):
        char = content[idx]
        if in_string:
            if escaped:
                escaped = False
                continue
            if char == "\\":
                escaped = True
                continue
            if char == "'":
                in_string = False
            continue

        if char == "'":
            in_string = True
            continue
        if char == "{":
            depth += 1
            continue
        if char == "}":
            depth -= 1
            if depth == 0:
                return content[start_index : idx + 1], idx + 1
    return "", start_index


def _parse_string_map_block(block: str) -> dict[str, str]:
    entries: dict[str, str] = {}
    for match in re.finditer(
        r"'((?:\\.|[^'\\])+)'\s*:\s*'((?:\\.|[^'\\])*)'",
        block,
        flags=re.DOTALL,
    ):
        raw_key = _decode_dart_single_quoted_literal(match.group(1))
        key = _normalize_translation_key(raw_key)
        if key is None:
            continue
        entries[key] = _decode_dart_single_quoted_literal(match.group(2))
    return entries


def _discover_builtin_bundles_from_source(content: str) -> dict[str, dict[str, str]]:
    marker = "_values = <String, Map<String, String>>"
    marker_index = content.find(marker)
    if marker_index < 0:
        return {}
    root_start = content.find("{", marker_index)
    root_block, _ = _extract_balanced_brace_block(content, root_start)
    if not root_block:
        return {}

    bundles: dict[str, dict[str, str]] = {}
    cursor = 1
    while cursor < len(root_block) - 1:
        next_quote = root_block.find("'", cursor)
        if next_quote < 0:
            break
        key_match = re.match(r"'((?:\\.|[^'\\])*)'", root_block[next_quote:])
        if key_match is None:
            cursor = next_quote + 1
            continue
        raw_code = _decode_dart_single_quoted_literal(key_match.group(1))
        after_key = next_quote + key_match.end()
        while after_key < len(root_block) and root_block[after_key].isspace():
            after_key += 1
        if after_key >= len(root_block) or root_block[after_key] != ":":
            cursor = next_quote + 1
            continue
        after_key += 1
        while after_key < len(root_block) and root_block[after_key].isspace():
            after_key += 1
        if after_key >= len(root_block) or root_block[after_key] != "{":
            cursor = next_quote + 1
            continue

        language_block, after_language = _extract_balanced_brace_block(root_block, after_key)
        if not language_block:
            break
        code = _normalize_language_code(raw_code)
        if code is not None:
            parsed = _parse_string_map_block(language_block)
            if parsed:
                bundles[code] = parsed
        cursor = after_language
    return bundles


def discover_builtin_bundles() -> dict[str, dict[str, str]]:
    """Parse built-in frontend localization source files into language bundles."""
    global _BUILTIN_BUNDLES_CACHE
    signature = _bundle_source_signature()
    if not signature:
        return {}

    if _BUILTIN_BUNDLES_CACHE is not None and _BUILTIN_BUNDLES_CACHE[0] == signature:
        cached = _BUILTIN_BUNDLES_CACHE[1]
        return {code: dict(entries) for code, entries in cached.items()}

    bundles: dict[str, dict[str, str]] = {}
    source = _reference_source_path()
    try:
        content = source.read_text(encoding="utf-8")
    except OSError:
        pass
    else:
        bundles.update(_discover_builtin_bundles_from_source(content))

    for code, split_source in _split_bundle_source_paths().items():
        try:
            content = split_source.read_text(encoding="utf-8")
        except OSError:
            continue
        entries = _parse_string_map_block(content)
        if entries:
            bundles[code] = entries

    if not bundles:
        fallback_entries = {key: key for key in _DEFAULT_REFERENCE_KEYS}
        for seed in _DEFAULT_LANGUAGES:
            code = _normalize_language_code(seed.get("code"))
            if code is not None:
                bundles[code] = dict(fallback_entries)

    _BUILTIN_BUNDLES_CACHE = (signature, bundles)
    return {code: dict(entries) for code, entries in bundles.items()}


def discover_reference_keys() -> tuple[str, ...]:
    """Return the canonical key set that imported bundles are validated against."""
    global _REFERENCE_KEYS_CACHE
    signature = _bundle_source_signature()
    if not signature:
        return _DEFAULT_REFERENCE_KEYS

    if _REFERENCE_KEYS_CACHE is not None and _REFERENCE_KEYS_CACHE[0] == signature:
        return _REFERENCE_KEYS_CACHE[1]

    builtin_english = discover_builtin_bundles().get("en", {})
    if builtin_english:
        resolved = tuple(builtin_english)
        _REFERENCE_KEYS_CACHE = (signature, resolved)
        return resolved

    source = _reference_source_path()
    try:
        content = source.read_text(encoding="utf-8")
    except OSError:
        return _DEFAULT_REFERENCE_KEYS

    matches = re.findall(r"'([a-z0-9_]+)'\s*:\s*'", content)
    keys: list[str] = []
    seen: set[str] = set()
    for key in matches:
        normalized = _normalize_translation_key(key)
        if normalized is None or normalized in seen:
            continue
        seen.add(normalized)
        keys.append(normalized)

    resolved = tuple(keys or _DEFAULT_REFERENCE_KEYS)
    _REFERENCE_KEYS_CACHE = (signature, resolved)
    return resolved


def ensure_seed(
    db: Session,
) -> tuple[OrganizationLocalizationSetting, list[LocalizationLanguage]]:
    """Create the baseline localization catalog rows and missing bundle records."""
    settings = db.get(OrganizationLocalizationSetting, 1)
    if settings is None:
        settings = OrganizationLocalizationSetting(
            id=1,
            default_language_code="en",
            fallback_order_json='["en"]',
            version=1,
        )
        db.add(settings)
        db.flush()

    rows = db.execute(select(LocalizationLanguage)).scalars().all()
    by_code = {row.code: row for row in rows}

    changed = False
    builtin_bundles = discover_builtin_bundles()
    for seed in _DEFAULT_LANGUAGES:
        code = seed["code"]
        row = by_code.get(code)
        if row is None:
            row = LocalizationLanguage(
                code=code,
                name=seed["name"],
                enabled=bool(seed["enabled"]),
                is_default=bool(seed["is_default"]),
                is_rtl=bool(seed["is_rtl"]),
                fallback_order_json=_json_dump(seed["fallback_order"]),
                bundle_version=1,
            )
            db.add(row)
            db.flush()
            by_code[code] = row
            changed = True

    if not by_code:
        raise bad_request("Localization catalog bootstrap failed")

    default_code = _normalize_language_code(settings.default_language_code) or "en"
    if default_code not in by_code:
        default_code = "en" if "en" in by_code else sorted(by_code.keys())[0]
        settings.default_language_code = default_code
        changed = True

    for code, row in by_code.items():
        should_default = code == default_code
        if bool(row.is_default) != should_default:
            row.is_default = should_default
            changed = True
        if should_default and not bool(row.enabled):
            row.enabled = True
            changed = True

    fallback = _normalize_fallback_order(
        _json_load_list(settings.fallback_order_json),
        default_code=default_code,
    )
    fallback_json = _json_dump(fallback)
    if settings.fallback_order_json != fallback_json:
        settings.fallback_order_json = fallback_json
        changed = True

    for code in sorted(by_code.keys()):
        bundle = db.get(LocalizationBundle, code)
        seed_entries = builtin_bundles.get(code, {})
        seed_json = _json_dump(seed_entries) if seed_entries else "{}"
        if bundle is None:
            db.add(LocalizationBundle(language_code=code, entries_json=seed_json))
            changed = True
            continue
        if seed_entries:
            current_entries = _parse_bundle_entries(bundle.entries_json)
            if not current_entries:
                bundle.entries_json = seed_json
                changed = True

    if changed:
        db.commit()

    rows = db.execute(select(LocalizationLanguage)).scalars().all()
    return settings, list(rows)


def reinstall_builtin_bundles(db: Session) -> tuple[str, ...]:
    """Rewrite stored built-in bundles from the source-controlled frontend defaults."""
    ensure_seed(db)
    builtin_bundles = discover_builtin_bundles()
    rebuilt_codes = tuple(sorted(builtin_bundles))
    changed = False

    for code in rebuilt_codes:
        seed_json = _json_dump(builtin_bundles.get(code, {}))
        bundle = db.get(LocalizationBundle, code)
        if bundle is None:
            db.add(LocalizationBundle(language_code=code, entries_json=seed_json))
            changed = True
            continue
        if bundle.entries_json != seed_json:
            bundle.entries_json = seed_json
            changed = True

    if changed:
        db.commit()

    return rebuilt_codes


def _language_out(row: LocalizationLanguage) -> dict[str, Any]:
    fallback = _normalize_fallback_order(
        _json_load_list(row.fallback_order_json),
        default_code=row.code,
    )
    return {
        "code": row.code,
        "name": row.name,
        "enabled": bool(row.enabled),
        "is_default": bool(row.is_default),
        "is_rtl": bool(row.is_rtl),
        "fallback_order": fallback,
        "bundle_version": int(row.bundle_version or 1),
        "updated_at": row.updated_at,
    }


def read_catalog(db: Session) -> dict[str, Any]:
    """Return the normalized localization catalog payload for admin consumers."""
    settings, rows = ensure_seed(db)
    rows_sorted = sorted(rows, key=lambda row: (not bool(row.is_default), row.code))
    fallback = _normalize_fallback_order(
        _json_load_list(settings.fallback_order_json),
        default_code=settings.default_language_code,
    )
    return {
        "default_language_code": settings.default_language_code,
        "organization_fallback_order": fallback,
        "version": int(settings.version or 1),
        "languages": [_language_out(row) for row in rows_sorted],
    }


def _parse_bundle_entries(value: object | None) -> dict[str, str]:
    raw = _json_load_dict(value)
    out: dict[str, str] = {}
    for key, raw_value in raw.items():
        normalized_key = _normalize_translation_key(key)
        if normalized_key is None:
            continue
        if isinstance(raw_value, str):
            out[normalized_key] = raw_value
        else:
            out[normalized_key] = str(raw_value)
    return out


def get_or_create_user_preference(
    db: Session,
    *,
    user_id: str,
) -> UserLocalizationPreference:
    """Return a user's localization preference row, creating one on demand."""
    pref = db.get(UserLocalizationPreference, user_id)
    if pref is not None:
        return pref
    pref = UserLocalizationPreference(
        user_id=user_id,
        language_code=None,
        use_org_default=True,
    )
    db.add(pref)
    db.commit()
    db.refresh(pref)
    return pref


def _active_department_parent_ids_by_child(db: Session) -> dict[str, set[str]]:
    rows = db.execute(
        select(OrganizationItemLink.parent_id, OrganizationItemLink.child_id).where(
            OrganizationItemLink.parent_kind == "department",
            OrganizationItemLink.child_kind == "department",
            OrganizationItemLink.active.is_(True),
        )
    ).all()
    mapped: dict[str, set[str]] = {}
    for parent_id, child_id in rows:
        if not isinstance(parent_id, str) or not isinstance(child_id, str):
            continue
        next_parent = parent_id.strip()
        next_child = child_id.strip()
        if not next_parent or not next_child:
            continue
        mapped.setdefault(next_child, set()).add(next_parent)
    return mapped


def _active_user_department_ids(db: Session, *, user_id: str) -> set[str]:
    rows = db.execute(
        select(OrganizationItemLink.parent_id).where(
            OrganizationItemLink.parent_kind == "department",
            OrganizationItemLink.child_kind == "user",
            OrganizationItemLink.child_id == user_id,
            OrganizationItemLink.active.is_(True),
        )
    ).all()
    unit_ids: set[str] = set()
    for (parent_id,) in rows:
        if not isinstance(parent_id, str):
            continue
        normalized = parent_id.strip()
        if normalized:
            unit_ids.add(normalized)
    return unit_ids


def _region_language_code_for_user(
    db: Session,
    *,
    user_id: str,
    enabled_codes: set[str],
) -> str | None:
    if not enabled_codes:
        return None
    linked_units = _active_user_department_ids(db, user_id=user_id)
    if not linked_units:
        return None

    parent_ids_by_child = _active_department_parent_ids_by_child(db)
    distance_by_unit: dict[str, int] = {}
    queue: deque[tuple[str, int]] = deque((unit_id, 0) for unit_id in linked_units)
    while queue:
        unit_id, distance = queue.popleft()
        current_distance = distance_by_unit.get(unit_id)
        if current_distance is not None and current_distance <= distance:
            continue
        distance_by_unit[unit_id] = distance
        for parent_id in parent_ids_by_child.get(unit_id, set()):
            queue.append((parent_id, distance + 1))

    if not distance_by_unit:
        return None

    rows = (
        db.execute(
            select(OrganizationUnit).where(
                OrganizationUnit.id.in_(sorted(distance_by_unit.keys())),
                OrganizationUnit.active.is_(True),
                OrganizationUnit.unit_type == "region",
            )
        )
        .scalars()
        .all()
    )
    if not rows:
        return None

    candidates: list[tuple[int, str, str]] = []
    for row in rows:
        meta = _json_load_dict(row.meta_json)
        normalized = _normalize_language_code(meta.get("default_language_code"))
        if normalized is None or normalized not in enabled_codes:
            continue
        rank = distance_by_unit.get(row.id, 10_000)
        label = row.slug if isinstance(row.slug, str) else row.id
        candidates.append((rank, label.lower(), normalized))

    if not candidates:
        return None
    candidates.sort(key=lambda item: (item[0], item[1], item[2]))
    return candidates[0][2]


def _effective_language_code(
    *,
    catalog_rows: Sequence[LocalizationLanguage],
    default_language_code: str,
    user_language_code: str | None,
    use_org_default: bool,
    region_default_language_code: str | None = None,
) -> str:
    enabled_codes = {row.code for row in catalog_rows if bool(row.enabled)}
    if use_org_default:
        normalized_region = _normalize_language_code(region_default_language_code)
        if normalized_region is not None and normalized_region in enabled_codes:
            return normalized_region
        return default_language_code if default_language_code in enabled_codes else (sorted(enabled_codes)[0] if enabled_codes else default_language_code)

    normalized_user_code = _normalize_language_code(user_language_code)
    if normalized_user_code and normalized_user_code in enabled_codes:
        return normalized_user_code

    if default_language_code in enabled_codes:
        return default_language_code

    return sorted(enabled_codes)[0] if enabled_codes else default_language_code


def read_runtime_payload(db: Session, *, user_id: str) -> dict[str, Any]:
    """Build the runtime localization payload used by the authenticated frontend."""
    catalog = read_catalog(db)
    rows = db.execute(select(LocalizationLanguage)).scalars().all()
    pref = get_or_create_user_preference(db, user_id=user_id)
    enabled_codes = {row.code for row in rows if bool(row.enabled)}
    region_default = _region_language_code_for_user(
        db,
        user_id=user_id,
        enabled_codes=enabled_codes,
    )

    effective = _effective_language_code(
        catalog_rows=rows,
        default_language_code=catalog["default_language_code"],
        user_language_code=pref.language_code,
        use_org_default=bool(pref.use_org_default),
        region_default_language_code=region_default,
    )

    enabled_codes = {str(item["code"]) for item in catalog["languages"] if bool(item["enabled"])}
    if effective not in enabled_codes:
        enabled_codes.add(effective)

    bundles: dict[str, dict[str, str]] = {}
    for code in sorted(enabled_codes):
        bundle = db.get(LocalizationBundle, code)
        bundles[code] = _parse_bundle_entries(None if bundle is None else bundle.entries_json)

    return {
        "catalog": catalog,
        "user_preference": {
            "language_code": pref.language_code,
            "use_org_default": bool(pref.use_org_default),
            "effective_language_code": effective,
            "updated_at": pref.updated_at,
        },
        "bundles": bundles,
        "generated_at": _now_utc(),
    }


def resolve_effective_content_language_code(
    db: Session,
    *,
    user_id: str | None,
    explicit_language_code: str | None = None,
) -> str:
    """Resolve which language code content-localization lookups should prefer."""
    normalized_explicit = _normalize_language_code(explicit_language_code)
    if normalized_explicit is not None:
        return normalized_explicit
    if user_id is None:
        return "en"
    runtime = read_runtime_payload(db, user_id=user_id)
    preference = runtime.get("user_preference")
    if isinstance(preference, Mapping):
        normalized = _normalize_language_code(preference.get("effective_language_code"))
        if normalized is not None:
            return normalized
    catalog = runtime.get("catalog")
    if isinstance(catalog, Mapping):
        normalized_default = _normalize_language_code(catalog.get("default_language_code"))
        if normalized_default is not None:
            return normalized_default
    return "en"


def localized_fields_for_contents(
    db: Session,
    *,
    content_kind: str,
    content_ids: Sequence[str],
    field_keys: Sequence[str],
    user_id: str | None = None,
    language_code: str | None = None,
) -> dict[str, dict[str, str]]:
    """Return translated field values grouped by content id for the requested items."""
    normalized_kind = _normalize_content_kind(content_kind)
    if normalized_kind is None:
        return {}
    normalized_ids = sorted({value for raw in content_ids if isinstance(raw, str) for value in [raw.strip()] if value})
    normalized_field_keys = sorted({normalized for raw in field_keys for normalized in [_normalize_field_key(raw)] if normalized is not None})
    if not normalized_ids or not normalized_field_keys:
        return {}

    effective_language = resolve_effective_content_language_code(
        db,
        user_id=user_id,
        explicit_language_code=language_code,
    )
    if not effective_language:
        return {}

    rows = db.execute(
        select(
            LocalizationTranslationVariant.content_id,
            LocalizationTranslationVariant.field_key,
            LocalizationTranslationVariant.translated_text,
            LocalizationTranslationVariant.source_version,
            LocalizationTranslationSource.source_version,
        )
        .join(
            LocalizationTranslationSource,
            LocalizationTranslationSource.id == LocalizationTranslationVariant.source_id,
        )
        .where(
            LocalizationTranslationVariant.content_kind == normalized_kind,
            LocalizationTranslationVariant.content_id.in_(normalized_ids),
            LocalizationTranslationVariant.field_key.in_(normalized_field_keys),
            LocalizationTranslationVariant.language_code == effective_language,
            LocalizationTranslationVariant.status.in_(sorted(_DISPLAYABLE_VARIANT_STATES)),
            LocalizationTranslationSource.active.is_(True),
        )
    ).all()

    mapped: dict[str, dict[str, str]] = {}
    for (
        content_id,
        field_key,
        translated_text,
        variant_source_version,
        current_source_version,
    ) in rows:
        if not isinstance(content_id, str) or not isinstance(field_key, str):
            continue
        if not isinstance(translated_text, str):
            continue
        if int(variant_source_version or 1) < int(current_source_version or 1):
            continue
        text_value = translated_text.strip()
        if not text_value:
            continue
        mapped.setdefault(content_id, {})[field_key] = text_value

    missing_pairs = [
        (content_id, field_key)
        for content_id in normalized_ids
        for field_key in normalized_field_keys
        if field_key not in mapped.get(content_id, {})
    ]
    if not missing_pairs:
        return mapped

    source_rows = db.execute(
        select(
            LocalizationTranslationSource.content_id,
            LocalizationTranslationSource.field_key,
            LocalizationTranslationSource.source_text,
            LocalizationTranslationSource.source_language_code,
        ).where(
            LocalizationTranslationSource.content_kind == normalized_kind,
            LocalizationTranslationSource.content_id.in_(normalized_ids),
            LocalizationTranslationSource.field_key.in_(normalized_field_keys),
            LocalizationTranslationSource.active.is_(True),
        )
    ).all()
    source_by_pair = {
        (content_id, field_key): (source_text, source_language_code)
        for content_id, field_key, source_text, source_language_code in source_rows
        if isinstance(content_id, str)
        and isinstance(field_key, str)
        and isinstance(source_text, str)
        and source_text.strip()
    }
    for content_id, field_key in missing_pairs:
        source_row = source_by_pair.get((content_id, field_key))
        if source_row is None:
            continue
        source_text, source_language_code = source_row
        if (
            _normalize_language_code(source_language_code) == effective_language
            or bool(source_text.strip())
        ):
            mapped.setdefault(content_id, {})[field_key] = source_text.strip()
    return mapped


def localized_fields_for_content(
    db: Session,
    *,
    content_kind: str,
    content_id: str,
    field_keys: Sequence[str],
    user_id: str | None = None,
    language_code: str | None = None,
) -> dict[str, str]:
    """Return translated field values for one content record."""
    mapped = localized_fields_for_contents(
        db,
        content_kind=content_kind,
        content_ids=[content_id],
        field_keys=field_keys,
        user_id=user_id,
        language_code=language_code,
    )
    return mapped.get(content_id.strip(), {})


def update_user_preference(
    db: Session,
    *,
    user_id: str,
    language_code: str | None,
    use_org_default: bool | None,
    apply_language_code: bool,
    apply_use_org_default: bool,
) -> dict[str, Any]:
    """Persist a user's localization preference and return the effective result."""
    catalog = read_catalog(db)
    rows = db.execute(select(LocalizationLanguage)).scalars().all()
    all_codes = {row.code for row in rows}
    enabled_codes = {row.code for row in rows if bool(row.enabled)}
    region_default = _region_language_code_for_user(
        db,
        user_id=user_id,
        enabled_codes=enabled_codes,
    )

    pref = get_or_create_user_preference(db, user_id=user_id)

    if apply_language_code:
        normalized = _normalize_language_code(language_code)
        if normalized is not None and normalized not in all_codes:
            raise bad_request(f"Unknown language code: {normalized}")
        pref.language_code = normalized

    if apply_use_org_default:
        pref.use_org_default = bool(use_org_default)

    if not apply_use_org_default and not apply_language_code:
        effective = _effective_language_code(
            catalog_rows=rows,
            default_language_code=catalog["default_language_code"],
            user_language_code=pref.language_code,
            use_org_default=bool(pref.use_org_default),
            region_default_language_code=region_default,
        )
        return {
            "language_code": pref.language_code,
            "use_org_default": bool(pref.use_org_default),
            "effective_language_code": effective,
            "updated_at": pref.updated_at,
        }

    db.commit()
    db.refresh(pref)

    effective = _effective_language_code(
        catalog_rows=rows,
        default_language_code=catalog["default_language_code"],
        user_language_code=pref.language_code,
        use_org_default=bool(pref.use_org_default),
        region_default_language_code=region_default,
    )
    return {
        "language_code": pref.language_code,
        "use_org_default": bool(pref.use_org_default),
        "effective_language_code": effective,
        "updated_at": pref.updated_at,
    }


def update_catalog(
    db: Session,
    *,
    default_language_code: str | None,
    organization_fallback_order: list[str] | None,
    languages: list[dict[str, Any]] | None,
    actor_user_id: str,
) -> dict[str, Any]:
    """Apply admin catalog changes and trigger follow-up translation work if configured."""
    settings, rows = ensure_seed(db)
    by_code = {row.code: row for row in rows}

    explicit_default = _normalize_language_code(default_language_code)

    if languages:
        for entry in languages:
            code = _normalize_language_code(entry.get("code"))
            if code is None:
                raise bad_request("Invalid language code in catalog update")
            row = by_code.get(code)
            if row is None:
                row = LocalizationLanguage(
                    code=code,
                    name=_string_or_default(entry.get("name"), default=code.upper()),
                    enabled=True,
                    is_default=False,
                    is_rtl=bool(entry.get("is_rtl", False)),
                    fallback_order_json=_json_dump([code]),
                    bundle_version=1,
                )
                db.add(row)
                db.flush()
                by_code[code] = row
                if db.get(LocalizationBundle, code) is None:
                    db.add(LocalizationBundle(language_code=code, entries_json="{}"))
            if "name" in entry and isinstance(entry.get("name"), str):
                row.name = _string_or_default(entry.get("name"), default=row.name)
            if "enabled" in entry and entry.get("enabled") is not None:
                row.enabled = bool(entry.get("enabled"))
            if "is_rtl" in entry and entry.get("is_rtl") is not None:
                row.is_rtl = bool(entry.get("is_rtl"))
            if entry.get("is_default") is True:
                explicit_default = code
            if "fallback_order" in entry and entry.get("fallback_order") is not None:
                row.fallback_order_json = _json_dump(_normalize_fallback_order(entry.get("fallback_order"), default_code=code))

    resolved_default = explicit_default or _normalize_language_code(settings.default_language_code)
    if resolved_default is None or resolved_default not in by_code:
        resolved_default = "en" if "en" in by_code else sorted(by_code.keys())[0]

    for code, row in by_code.items():
        row.is_default = code == resolved_default
        if row.is_default:
            row.enabled = True

    settings.default_language_code = resolved_default
    if organization_fallback_order is not None:
        settings.fallback_order_json = _json_dump(_normalize_fallback_order(organization_fallback_order, default_code=resolved_default))
    else:
        settings.fallback_order_json = _json_dump(
            _normalize_fallback_order(
                _json_load_list(settings.fallback_order_json),
                default_code=resolved_default,
            )
        )

    settings.updated_by_user_id = actor_user_id
    settings.version = int(settings.version or 1) + 1

    db.commit()
    translation_settings = _translation_setting_row(db)
    if bool(translation_settings.auto_retranslate_on_bundle_change):
        bulk_retranslate(
            db,
            actor_user_id=actor_user_id,
            reason="language_pack_change",
            include_locked=False,
        )
    return read_catalog(db)


def export_bundles(db: Session, *, format_name: str) -> dict[str, Any]:
    """Export stored bundles in ARB or ICU-compatible shape."""
    normalized_format = format_name.strip().lower()
    if normalized_format not in {"arb", "icu"}:
        raise bad_request("format must be arb or icu")

    catalog = read_catalog(db)
    bundles: dict[str, dict[str, str]] = {}
    for language in catalog["languages"]:
        code = str(language["code"])
        bundle = db.get(LocalizationBundle, code)
        entries = _parse_bundle_entries(None if bundle is None else bundle.entries_json)
        if normalized_format == "arb":
            bundles[code] = {"@@locale": code, **entries}
        else:
            bundles[code] = entries

    return {
        "format": normalized_format,
        "generated_at": _now_utc(),
        "catalog": catalog,
        "bundles": bundles,
    }


def _validate_import_bundle(
    *,
    code: str,
    raw_entries: dict[str, object],
    format_name: str,
    reference_keys: set[str],
) -> tuple[dict[str, str], list[ValidationIssue], list[ValidationIssue]]:
    errors: list[ValidationIssue] = []
    warnings: list[ValidationIssue] = []
    normalized_entries: dict[str, str] = {}

    for raw_key, raw_value in raw_entries.items():
        if not isinstance(raw_key, str):
            errors.append(
                ValidationIssue(
                    code="invalid_key",
                    message=f"{code}: non-string key encountered",
                )
            )
            continue
        if format_name == "arb" and raw_key.startswith("@"):
            continue
        key = _normalize_translation_key(raw_key)
        if key is None:
            errors.append(
                ValidationIssue(
                    code="invalid_key",
                    message=f"{code}: invalid translation key '{raw_key}'",
                )
            )
            continue
        if not isinstance(raw_value, str):
            errors.append(
                ValidationIssue(
                    code="invalid_value",
                    message=f"{code}:{key} must be a string",
                )
            )
            continue
        normalized_entries[key] = raw_value

    if reference_keys:
        missing = sorted(reference_keys - set(normalized_entries.keys()))
        if missing:
            warnings.append(
                ValidationIssue(
                    code="missing_keys",
                    message=f"{code}: missing {len(missing)} reference keys (sample: {', '.join(missing[:6])})",
                )
            )

    if not normalized_entries:
        errors.append(
            ValidationIssue(
                code="empty_bundle",
                message=f"{code}: bundle has no valid translation entries",
            )
        )

    return normalized_entries, errors, warnings


def import_bundles(
    db: Session,
    *,
    format_name: str,
    bundles: dict[str, dict[str, object]],
    dry_run: bool,
    actor_user_id: str,
) -> dict[str, Any]:
    """Validate and optionally apply imported localization bundles."""
    normalized_format = format_name.strip().lower()
    if normalized_format not in {"arb", "icu"}:
        raise bad_request("format must be arb or icu")

    settings, rows = ensure_seed(db)
    by_code = {row.code: row for row in rows}

    reference_keys = set(discover_reference_keys())

    errors: list[ValidationIssue] = []
    warnings: list[ValidationIssue] = []
    prepared: dict[str, dict[str, str]] = {}

    for raw_code, raw_entries in bundles.items():
        code = _normalize_language_code(raw_code)
        if code is None:
            errors.append(
                ValidationIssue(
                    code="invalid_language_code",
                    message=f"Invalid language code '{raw_code}'",
                )
            )
            continue
        if not isinstance(raw_entries, dict):
            errors.append(
                ValidationIssue(
                    code="invalid_bundle",
                    message=f"{code}: bundle must be an object/map",
                )
            )
            continue
        entries, bundle_errors, bundle_warnings = _validate_import_bundle(
            code=code,
            raw_entries=raw_entries,
            format_name=normalized_format,
            reference_keys=reference_keys,
        )
        errors.extend(bundle_errors)
        warnings.extend(bundle_warnings)
        if not bundle_errors:
            prepared[code] = entries

    if errors:
        return {
            "applied": False,
            "dry_run": bool(dry_run),
            "errors": errors,
            "warnings": warnings,
            "updated_languages": [],
        }

    updated_languages: list[ImportLanguageResult] = []

    if dry_run:
        for code, entries in sorted(prepared.items()):
            row = by_code.get(code)
            current_version = int(row.bundle_version or 1) if row is not None else 1
            updated_languages.append(
                ImportLanguageResult(
                    code=code,
                    entry_count=len(entries),
                    bundle_version=current_version + 1,
                )
            )
        return {
            "applied": False,
            "dry_run": True,
            "errors": [],
            "warnings": warnings,
            "updated_languages": updated_languages,
        }

    for code, entries in sorted(prepared.items()):
        row = by_code.get(code)
        if row is None:
            row = LocalizationLanguage(
                code=code,
                name=code.upper(),
                enabled=True,
                is_default=False,
                is_rtl=False,
                fallback_order_json=_json_dump([code, settings.default_language_code]),
                bundle_version=1,
            )
            db.add(row)
            db.flush()
            by_code[code] = row

        bundle = db.get(LocalizationBundle, code)
        if bundle is None:
            bundle = LocalizationBundle(language_code=code, entries_json="{}")
            db.add(bundle)
            db.flush()

        bundle.entries_json = _json_dump(entries)
        row.bundle_version = int(row.bundle_version or 1) + 1

        updated_languages.append(
            ImportLanguageResult(
                code=code,
                entry_count=len(entries),
                bundle_version=int(row.bundle_version),
            )
        )

    settings.updated_by_user_id = actor_user_id
    settings.version = int(settings.version or 1) + 1

    db.commit()
    translation_settings = _translation_setting_row(db)
    if bool(translation_settings.auto_retranslate_on_bundle_change):
        bulk_retranslate(
            db,
            actor_user_id=actor_user_id,
            reason="language_pack_change",
            include_locked=False,
        )

    return {
        "applied": True,
        "dry_run": False,
        "errors": [],
        "warnings": warnings,
        "updated_languages": updated_languages,
    }


def health_report(db: Session) -> dict[str, Any]:
    """Summarize bundle coverage and staleness against the reference key set."""
    catalog = read_catalog(db)
    reference_keys = set(discover_reference_keys())
    reference_key_count = len(reference_keys)

    rows = db.execute(select(LocalizationLanguage)).scalars().all()
    by_code = {row.code: row for row in rows}
    max_bundle_version = max((int(row.bundle_version or 1) for row in rows), default=1)
    stale_codes: list[str] = []

    languages_health: list[dict[str, Any]] = []
    stale_cutoff = _now_utc() - timedelta(days=30)

    for language in catalog["languages"]:
        code = str(language["code"])
        row = by_code.get(code)
        bundle = db.get(LocalizationBundle, code)
        entries = _parse_bundle_entries(None if bundle is None else bundle.entries_json)

        key_count = len(entries)
        missing = sorted(reference_keys - set(entries.keys())) if reference_keys else []
        coverage = 100.0
        if reference_key_count > 0:
            coverage = round((max(reference_key_count - len(missing), 0) / reference_key_count) * 100, 2)

        row_updated_at = row.updated_at if row is not None else None
        stale_by_version = int(language["bundle_version"]) < max_bundle_version
        stale_by_age = row_updated_at is not None and row_updated_at < stale_cutoff
        stale_bundle = bool(stale_by_version or stale_by_age)
        if stale_bundle:
            stale_codes.append(code)

        languages_health.append(
            {
                "code": code,
                "enabled": bool(language["enabled"]),
                "coverage_pct": coverage,
                "key_count": key_count,
                "missing_key_count": len(missing),
                "missing_keys_sample": missing[:20],
                "bundle_version": int(language["bundle_version"]),
                "stale_bundle": stale_bundle,
            }
        )

    return {
        "reference_key_count": reference_key_count,
        "default_language_code": catalog["default_language_code"],
        "stale_bundle_versions": sorted(set(stale_codes)),
        "languages": languages_health,
    }


def _translation_setting_row(db: Session) -> LocalizationTranslationSetting:
    row = db.get(LocalizationTranslationSetting, 1)
    if row is not None:
        return row
    row = LocalizationTranslationSetting(
        id=1,
        translation_enabled=True,
        provider="openai",
        model=_provider_default_model("openai"),
        api_base_url=_provider_default_base_url("openai"),
        auto_translate_on_write=True,
        auto_approve=False,
        auto_retranslate_on_bundle_change=False,
        fallback_to_source=True,
        queue_max_attempts=4,
        queue_backoff_seconds=30,
        queue_batch_size=20,
        glossary_json="{}",
        provider_options_json="{}",
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return row


def _glossary_map_from_json(value: object | None) -> dict[str, str]:
    raw = _json_load_dict(value)
    out: dict[str, str] = {}
    for key, mapped in raw.items():
        term = str(key).strip()
        if not term:
            continue
        replacement = str(mapped).strip()
        out[term] = replacement or term
    return out


def _provider_options_from_json(value: object | None) -> dict[str, object]:
    raw = _json_load_dict(value)
    out: dict[str, object] = {}
    for key, mapped in raw.items():
        normalized = str(key).strip()
        if not normalized:
            continue
        out[normalized] = mapped
    return out


def _translation_settings_out(row: LocalizationTranslationSetting) -> dict[str, Any]:
    provider = _normalize_provider(row.provider) or "openai"
    api_base_url = _normalize_api_base_url(row.api_base_url)
    resolved_api_base_url = api_base_url or _provider_default_base_url(provider)
    return {
        "translation_enabled": bool(row.translation_enabled),
        "provider": provider,
        "model": _string_or_default(row.model, default=_provider_default_model(provider)),
        "api_base_url": api_base_url,
        "resolved_api_base_url": resolved_api_base_url,
        "has_api_key": _unseal_secret(row.api_key_encrypted) is not None,
        "provider_defaults": _provider_defaults_catalog(),
        "auto_translate_on_write": bool(row.auto_translate_on_write),
        "auto_approve": bool(row.auto_approve),
        "auto_retranslate_on_bundle_change": bool(row.auto_retranslate_on_bundle_change),
        "fallback_to_source": bool(row.fallback_to_source),
        "queue_max_attempts": _safe_int(row.queue_max_attempts, default=4, minimum=1, maximum=10),
        "queue_backoff_seconds": _safe_int(
            row.queue_backoff_seconds,
            default=30,
            minimum=1,
            maximum=3600,
        ),
        "queue_batch_size": _safe_int(row.queue_batch_size, default=20, minimum=1, maximum=250),
        "glossary": _glossary_map_from_json(row.glossary_json),
        "translation_prompt": _string_or_default(
            row.translation_prompt,
            default=_DEFAULT_TRANSLATION_PROMPT,
        ),
        "provider_options": _provider_options_from_json(row.provider_options_json),
        "updated_at": row.updated_at,
    }


def _reseal_translation_api_key_if_needed(db: Session, row: LocalizationTranslationSetting) -> None:
    if not _secret_needs_reseal(row.api_key_encrypted):
        return
    plain = _unseal_secret(row.api_key_encrypted)
    if plain is None:
        return
    row.api_key_encrypted = _seal_secret(plain)
    db.commit()
    db.refresh(row)


def read_translation_settings(db: Session) -> dict[str, Any]:
    """Return normalized machine-translation settings for admin tooling."""
    row = _translation_setting_row(db)
    _reseal_translation_api_key_if_needed(db, row)
    return _translation_settings_out(row)


def update_translation_settings(
    db: Session,
    *,
    changes: Mapping[str, Any],
    fields_set: set[str],
    actor_user_id: str,
) -> dict[str, Any]:
    """Persist translation provider settings and normalize dependent defaults."""
    row = _translation_setting_row(db)
    previous_provider = _normalize_provider(row.provider) or "openai"

    if "translation_enabled" in fields_set:
        row.translation_enabled = bool(changes.get("translation_enabled"))

    if "provider" in fields_set:
        provider = _normalize_provider(changes.get("provider"))
        if provider is None:
            raise bad_request("Invalid translation provider")
        row.provider = provider

    if "model" in fields_set:
        current_provider = _normalize_provider(row.provider) or "openai"
        row.model = _string_or_default(
            changes.get("model"),
            default=_provider_default_model(current_provider),
        )

    if "api_base_url" in fields_set:
        row.api_base_url = _normalize_api_base_url(changes.get("api_base_url"))

    if "api_key" in fields_set:
        candidate = changes.get("api_key")
        if candidate is None:
            row.api_key_encrypted = None
        elif isinstance(candidate, str):
            normalized = candidate.strip()
            row.api_key_encrypted = _seal_secret(normalized) if normalized else None
        else:
            raise bad_request("api_key must be a string")

    if "clear_api_key" in fields_set and bool(changes.get("clear_api_key")):
        row.api_key_encrypted = None

    if "auto_translate_on_write" in fields_set:
        row.auto_translate_on_write = bool(changes.get("auto_translate_on_write"))
    if "auto_approve" in fields_set:
        row.auto_approve = bool(changes.get("auto_approve"))
    if "auto_retranslate_on_bundle_change" in fields_set:
        row.auto_retranslate_on_bundle_change = bool(changes.get("auto_retranslate_on_bundle_change"))
    if "fallback_to_source" in fields_set:
        row.fallback_to_source = bool(changes.get("fallback_to_source"))

    if "queue_max_attempts" in fields_set:
        row.queue_max_attempts = _safe_int(
            changes.get("queue_max_attempts"),
            default=4,
            minimum=1,
            maximum=10,
        )
    if "queue_backoff_seconds" in fields_set:
        row.queue_backoff_seconds = _safe_int(
            changes.get("queue_backoff_seconds"),
            default=30,
            minimum=1,
            maximum=3600,
        )
    if "queue_batch_size" in fields_set:
        row.queue_batch_size = _safe_int(
            changes.get("queue_batch_size"),
            default=20,
            minimum=1,
            maximum=250,
        )

    if "glossary" in fields_set:
        raw_glossary = changes.get("glossary")
        if raw_glossary is None:
            row.glossary_json = "{}"
        elif isinstance(raw_glossary, Mapping):
            normalized = _glossary_map_from_json(raw_glossary)
            row.glossary_json = _json_dump(normalized)
        else:
            raise bad_request("glossary must be an object")

    if "translation_prompt" in fields_set:
        raw_prompt = changes.get("translation_prompt")
        if raw_prompt is None:
            row.translation_prompt = None
        elif isinstance(raw_prompt, str):
            normalized = raw_prompt.strip()
            row.translation_prompt = normalized or None
        else:
            raise bad_request("translation_prompt must be a string")

    if "provider_options" in fields_set:
        raw_options = changes.get("provider_options")
        if raw_options is None:
            row.provider_options_json = "{}"
        elif isinstance(raw_options, Mapping):
            row.provider_options_json = _json_dump({str(k): v for k, v in raw_options.items() if str(k).strip()})
        else:
            raise bad_request("provider_options must be an object")

    resolved_provider = _normalize_provider(row.provider) or "openai"
    if "provider" in fields_set and "model" not in fields_set and (not isinstance(row.model, str) or not row.model.strip()):
        row.model = _provider_default_model(resolved_provider)

    if "provider" in fields_set and "api_base_url" not in fields_set:
        previous_default_base = _provider_default_base_url(previous_provider)
        current_base = _normalize_api_base_url(row.api_base_url)
        if current_base is None or current_base == previous_default_base:
            row.api_base_url = _provider_default_base_url(resolved_provider)

    row.updated_by_user_id = actor_user_id
    db.commit()
    db.refresh(row)
    _reseal_translation_api_key_if_needed(db, row)
    return _translation_settings_out(row)


def _resolve_source_language_code(
    db: Session,
    *,
    preferred_code: str | None,
) -> str:
    settings, rows = ensure_seed(db)
    available = {row.code for row in rows}
    normalized = _normalize_language_code(preferred_code)
    if normalized is not None and normalized in available:
        return normalized
    fallback = _normalize_language_code(settings.default_language_code)
    if fallback is not None and fallback in available:
        return fallback
    return "en"


def _language_detection_score(text: str, language_code: str) -> float:
    if not text:
        return 0.0
    sample = f" {text.lower()} "
    score = 0.0
    for stopword in _LANGUAGE_DETECTION_STOPWORDS.get(language_code, ()):
        token = f" {stopword} "
        if token in sample:
            score += 1.2
    special_chars = _LANGUAGE_DETECTION_CHARS.get(language_code)
    if special_chars:
        score += sum(1 for char in text if char in special_chars) * 1.8
    return score


def _detect_source_language_code(
    *,
    text: str,
    candidate_codes: Sequence[str],
) -> str | None:
    normalized_candidates: list[str] = []
    seen: set[str] = set()
    for raw in candidate_codes:
        normalized = _normalize_language_code(raw)
        if normalized is None or normalized in seen:
            continue
        seen.add(normalized)
        normalized_candidates.append(normalized)
    if not normalized_candidates:
        return None

    ranked = sorted(
        ((_language_detection_score(text, code), code) for code in normalized_candidates),
        key=lambda item: (item[0], item[1]),
        reverse=True,
    )
    if not ranked or ranked[0][0] <= 0:
        return None
    return ranked[0][1]


def _enabled_target_language_codes(
    db: Session,
    *,
    source_language_code: str,
) -> list[str]:
    _, rows = ensure_seed(db)
    return sorted({row.code for row in rows if bool(row.enabled) and row.code != source_language_code})


def _append_translation_audit_event(
    db: Session,
    *,
    action: str,
    actor_user_id: str | None,
    content_kind: str,
    content_id: str,
    summary: str,
    before: Mapping[str, object] | None = None,
    after: Mapping[str, object] | None = None,
) -> None:
    audit_item_kind = content_kind[4:] if content_kind.startswith("org_") else content_kind
    db.add(
        OrganizationAuditEvent(
            id=str(uuid.uuid4()),
            scope_kind="translation",
            action=action,
            item_kind=audit_item_kind[:50],
            item_id=content_id[:120],
            actor_user_id=actor_user_id,
            summary=summary[:400],
            before_json=_json_from_payload(before),
            after_json=_json_from_payload(after),
        )
    )


def _json_from_payload(payload: Mapping[str, object] | None) -> str | None:
    if payload is None:
        return None
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def _upsert_translation_source(
    db: Session,
    *,
    content_kind: str,
    content_id: str,
    field_key: str,
    source_language_code: str,
    source_text: str,
    actor_user_id: str | None,
) -> tuple[LocalizationTranslationSource, bool]:
    source_id = _source_key(content_kind, content_id, field_key)
    row = db.get(LocalizationTranslationSource, source_id)
    if row is None:
        row = db.scalar(
            select(LocalizationTranslationSource).where(
                LocalizationTranslationSource.content_kind == content_kind,
                LocalizationTranslationSource.content_id == content_id,
                LocalizationTranslationSource.field_key == field_key,
            )
        )
    normalized_text = source_text.strip()
    if len(normalized_text) > _MAX_SOURCE_TEXT_LENGTH:
        normalized_text = normalized_text[:_MAX_SOURCE_TEXT_LENGTH]
    source_hash = _text_hash(normalized_text)
    if row is None:
        row = LocalizationTranslationSource(
            id=source_id,
            content_kind=content_kind,
            content_id=content_id,
            field_key=field_key,
            source_language_code=source_language_code,
            source_text=normalized_text,
            source_hash=source_hash,
            source_version=1,
            active=True,
            updated_by_user_id=actor_user_id,
        )
        db.add(row)
        db.flush()
        return row, True

    changed = False
    row.active = True
    if row.source_text != normalized_text or row.source_hash != source_hash:
        row.source_text = normalized_text
        row.source_hash = source_hash
        row.source_version = int(row.source_version or 1) + 1
        changed = True
    if row.source_language_code != source_language_code:
        row.source_language_code = source_language_code
        changed = True
    row.updated_by_user_id = actor_user_id
    return row, changed


def _variant_for_source_language(
    db: Session,
    *,
    source: LocalizationTranslationSource,
    language_code: str,
) -> LocalizationTranslationVariant | None:
    return db.scalar(
        select(LocalizationTranslationVariant).where(
            LocalizationTranslationVariant.content_kind == source.content_kind,
            LocalizationTranslationVariant.content_id == source.content_id,
            LocalizationTranslationVariant.field_key == source.field_key,
            LocalizationTranslationVariant.language_code == language_code,
        )
    )


def _queue_translation_jobs_for_source(
    db: Session,
    *,
    source: LocalizationTranslationSource,
    settings_row: LocalizationTranslationSetting,
    triggered_by: str,
    actor_user_id: str | None,
    language_codes: Sequence[str] | None = None,
    include_locked: bool = False,
    force: bool = False,
) -> int:
    if not bool(settings_row.translation_enabled):
        return 0
    normalized_trigger = _string_or_default(triggered_by, default="auto_write")
    if language_codes is None:
        target_codes = _enabled_target_language_codes(
            db,
            source_language_code=source.source_language_code,
        )
    else:
        target_codes = []
        seen: set[str] = set()
        for raw in language_codes:
            normalized = _normalize_language_code(raw)
            if normalized is None or normalized in seen:
                continue
            if normalized == source.source_language_code:
                continue
            seen.add(normalized)
            target_codes.append(normalized)

    queued = 0
    provider = _normalize_provider(settings_row.provider) or "openai"
    model = _string_or_default(settings_row.model, default="gpt-4.1-mini")
    max_attempts = _safe_int(
        settings_row.queue_max_attempts,
        default=4,
        minimum=1,
        maximum=10,
    )
    backoff_seconds = _safe_int(
        settings_row.queue_backoff_seconds,
        default=30,
        minimum=1,
        maximum=3600,
    )

    for code in target_codes:
        variant = _variant_for_source_language(db, source=source, language_code=code)
        if variant is not None and bool(variant.locked) and not include_locked:
            continue

        if not force and variant is not None and int(variant.source_version or 1) == int(source.source_version or 1) and variant.status in _REVIEWABLE_VARIANT_STATES and variant.status != "failed":
            continue

        if variant is None:
            variant = LocalizationTranslationVariant(
                id=str(uuid.uuid4()),
                source_id=source.id,
                content_kind=source.content_kind,
                content_id=source.content_id,
                field_key=source.field_key,
                language_code=code,
                source_language_code=source.source_language_code,
                source_version=int(source.source_version or 1),
                translated_text="",
                status="pending",
                provider=provider,
                model=model,
                locked=False,
            )
            db.add(variant)
            db.flush()
        else:
            variant.source_id = source.id
            variant.source_language_code = source.source_language_code
            variant.source_version = int(source.source_version or 1)
            if not variant.locked:
                variant.status = "pending"
                variant.last_error = None
            variant.provider = provider
            variant.model = model

        job_key = _idempotency_key(
            source_id=source.id,
            source_hash=source.source_hash,
            language_code=code,
            provider=provider,
            model=model,
        )
        if force:
            job_key = f"{job_key}:{uuid.uuid4().hex[:12]}"

        existing_active = db.scalar(
            select(LocalizationTranslationJob).where(
                LocalizationTranslationJob.idempotency_key == job_key,
                LocalizationTranslationJob.status.in_(sorted(_ACTIVE_JOB_STATES)),
            )
        )
        if existing_active is not None:
            continue

        db.add(
            LocalizationTranslationJob(
                id=str(uuid.uuid4()),
                source_id=source.id,
                content_kind=source.content_kind,
                content_id=source.content_id,
                field_key=source.field_key,
                language_code=code,
                source_language_code=source.source_language_code,
                source_text=source.source_text,
                source_hash=source.source_hash,
                source_version=int(source.source_version or 1),
                provider=provider,
                model=model,
                status="queued",
                idempotency_key=job_key,
                attempt_count=0,
                max_attempts=max_attempts,
                backoff_seconds=backoff_seconds,
                next_attempt_at=_now_utc(),
                triggered_by=normalized_trigger,
                actor_user_id=actor_user_id,
            )
        )
        queued += 1

    return queued


def queue_content_translations(
    db: Session,
    *,
    content_kind: str,
    content_id: str,
    fields: Mapping[str, str | None],
    actor_user_id: str | None,
    source_language_code: str | None = None,
    triggered_by: str = "auto_write",
    force: bool = False,
    include_locked: bool = False,
    language_codes: Sequence[str] | None = None,
) -> int:
    """Upsert source rows and enqueue translation jobs for changed content fields."""
    normalized_content_kind = _normalize_content_kind(content_kind)
    if normalized_content_kind is None:
        raise bad_request("Invalid content_kind for translation queue")
    normalized_content_id = str(content_id).strip()
    if not normalized_content_id:
        raise bad_request("content_id is required")

    settings_row = _translation_setting_row(db)
    if not bool(settings_row.translation_enabled):
        return 0
    if not force and triggered_by == "auto_write" and not bool(settings_row.auto_translate_on_write):
        return 0

    _, catalog_rows = ensure_seed(db)
    candidate_source_codes = sorted({row.code for row in catalog_rows})
    resolved_source_language = _resolve_source_language_code(
        db,
        preferred_code=source_language_code,
    )

    total_queued = 0
    for raw_field_key, raw_text in fields.items():
        normalized_field_key = _normalize_field_key(raw_field_key)
        if normalized_field_key is None:
            continue
        if raw_text is None:
            continue
        normalized_text = str(raw_text).strip()
        if not normalized_text:
            continue
        field_source_language = resolved_source_language
        if source_language_code is None:
            detected = _detect_source_language_code(
                text=normalized_text,
                candidate_codes=candidate_source_codes,
            )
            if detected is not None:
                field_source_language = detected
        source, changed = _upsert_translation_source(
            db,
            content_kind=normalized_content_kind,
            content_id=normalized_content_id,
            field_key=normalized_field_key,
            source_language_code=field_source_language,
            source_text=normalized_text,
            actor_user_id=actor_user_id,
        )
        if not changed and not force:
            continue

        queued = _queue_translation_jobs_for_source(
            db,
            source=source,
            settings_row=settings_row,
            triggered_by=triggered_by,
            actor_user_id=actor_user_id,
            language_codes=language_codes,
            include_locked=include_locked,
            force=force,
        )
        total_queued += queued
        if queued > 0:
            _append_translation_audit_event(
                db,
                action="enqueue",
                actor_user_id=actor_user_id,
                content_kind=normalized_content_kind,
                content_id=normalized_content_id,
                summary=f"Queued {queued} translation job(s) for {normalized_field_key}",
                after={
                    "field_key": normalized_field_key,
                    "queued_jobs": queued,
                    "source_version": int(source.source_version or 1),
                    "triggered_by": triggered_by,
                },
            )
    return total_queued


def try_queue_content_translations(
    db: Session,
    *,
    content_kind: str,
    content_id: str,
    fields: Mapping[str, str | None],
    actor_user_id: str | None,
    source_language_code: str | None = None,
    triggered_by: str = "auto_write",
    force: bool = False,
    include_locked: bool = False,
    language_codes: Sequence[str] | None = None,
) -> int:
    """Best-effort translation enqueue wrapper that never blocks content writes."""
    try:
        with db.begin_nested():
            return queue_content_translations(
                db,
                content_kind=content_kind,
                content_id=content_id,
                fields=fields,
                actor_user_id=actor_user_id,
                source_language_code=source_language_code,
                triggered_by=triggered_by,
                force=force,
                include_locked=include_locked,
                language_codes=language_codes,
            )
    except Exception:
        # Translation enqueue should not block content writes.
        return 0


def _apply_glossary_protection(
    text: str,
    glossary: Mapping[str, str],
) -> tuple[str, dict[str, str]]:
    protected = text
    replacements: dict[str, str] = {}
    terms = sorted(
        ((term, replacement) for term, replacement in glossary.items() if term),
        key=lambda item: len(item[0]),
        reverse=True,
    )
    for idx, (term, replacement) in enumerate(terms):
        token = f"[[GLOSSARY_{idx}]]"
        if term not in protected:
            continue
        protected = protected.replace(term, token)
        replacements[token] = replacement or term
    return protected, replacements


def _restore_glossary_tokens(text: str, replacements: Mapping[str, str]) -> str:
    resolved = text
    for token, value in replacements.items():
        resolved = resolved.replace(token, value)
    return resolved


def _http_post_json(
    *,
    url: str,
    headers: Mapping[str, str],
    payload: Mapping[str, object],
    timeout_seconds: int = 40,
) -> dict[str, Any]:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = url_request.Request(
        url=url,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            **headers,
        },
        data=body,
    )
    try:
        with url_request.urlopen(request, timeout=timeout_seconds) as response:
            raw = response.read().decode("utf-8", errors="replace")
    except url_error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Translation provider HTTP {exc.code}: {detail}") from exc
    except url_error.URLError as exc:
        raise RuntimeError(f"Translation provider request failed: {exc.reason}") from exc

    try:
        decoded = json.loads(raw)
    except Exception as exc:
        raise RuntimeError("Translation provider returned non-JSON response") from exc
    if not isinstance(decoded, dict):
        raise RuntimeError("Translation provider returned invalid response payload")
    return decoded


def _openai_endpoint(base_url: str | None) -> str:
    if base_url is None:
        return "https://api.openai.com/v1/chat/completions"
    if base_url.endswith("/chat/completions"):
        return base_url
    if base_url.endswith("/v1"):
        return f"{base_url}/chat/completions"
    return f"{base_url}/v1/chat/completions"


def _gemini_endpoint(base_url: str | None, model: str, api_key: str) -> str:
    if base_url is None:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    elif base_url.endswith(":generateContent"):
        url = base_url
    else:
        url = f"{base_url}/models/{model}:generateContent"
    query = url_parse.urlencode({"key": api_key})
    separator = "&" if "?" in url else "?"
    return f"{url}{separator}{query}"


def _translate_via_openai(
    *,
    api_key: str,
    api_base_url: str | None,
    model: str,
    prompt: str,
    source_text: str,
    source_language_code: str,
    target_language_code: str,
) -> TranslationResult:
    payload: dict[str, object] = {
        "model": model,
        "temperature": 0.2,
        "messages": [
            {
                "role": "system",
                "content": prompt,
            },
            {
                "role": "user",
                "content": (f"Source language: {source_language_code}\n" f"Target language: {target_language_code}\n" f"Text:\n{source_text}"),
            },
        ],
    }
    decoded = _http_post_json(
        url=_openai_endpoint(api_base_url),
        headers={"Authorization": f"Bearer {api_key}"},
        payload=payload,
    )
    choices = decoded.get("choices")
    if not isinstance(choices, list) or not choices:
        raise RuntimeError("OpenAI response missing choices")
    first = choices[0]
    if not isinstance(first, Mapping):
        raise RuntimeError("OpenAI response has invalid choice payload")
    message = first.get("message")
    content: str | None = None
    if isinstance(message, Mapping):
        raw_content = message.get("content")
        if isinstance(raw_content, str):
            content = raw_content
        elif isinstance(raw_content, list):
            parts = [part.get("text", "") for part in raw_content if isinstance(part, Mapping)]
            joined = "".join(str(part) for part in parts)
            content = joined if joined.strip() else None
    if content is None:
        raise RuntimeError("OpenAI response missing translated text")
    return TranslationResult(
        translated_text=content.strip(),
        confidence=None,
        provider="openai",
        model=model,
    )


def _translate_via_gemini(
    *,
    api_key: str,
    api_base_url: str | None,
    model: str,
    prompt: str,
    source_text: str,
    source_language_code: str,
    target_language_code: str,
) -> TranslationResult:
    payload: dict[str, object] = {"contents": [{"parts": [{"text": (f"{prompt}\n\n" f"Source language: {source_language_code}\n" f"Target language: {target_language_code}\n" f"Text:\n{source_text}")}]}]}
    decoded = _http_post_json(
        url=_gemini_endpoint(api_base_url, model, api_key),
        headers={},
        payload=payload,
    )
    candidates = decoded.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        raise RuntimeError("Gemini response missing candidates")
    first = candidates[0]
    if not isinstance(first, Mapping):
        raise RuntimeError("Gemini response has invalid candidate payload")
    content = first.get("content")
    if not isinstance(content, Mapping):
        raise RuntimeError("Gemini response missing content")
    parts = content.get("parts")
    if not isinstance(parts, list) or not parts:
        raise RuntimeError("Gemini response missing content parts")
    text_parts = [part.get("text", "") for part in parts if isinstance(part, Mapping)]
    translated = "".join(str(part) for part in text_parts).strip()
    if not translated:
        raise RuntimeError("Gemini response returned empty translated text")
    return TranslationResult(
        translated_text=translated,
        confidence=None,
        provider="gemini",
        model=model,
    )


def _translate_via_custom(
    *,
    api_key: str | None,
    api_base_url: str,
    provider: str,
    model: str,
    prompt: str,
    source_text: str,
    source_language_code: str,
    target_language_code: str,
    glossary: Mapping[str, str],
    provider_options: Mapping[str, object],
) -> TranslationResult:
    headers: dict[str, str] = {}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    payload: dict[str, object] = {
        "provider": provider,
        "model": model,
        "source_language_code": source_language_code,
        "target_language_code": target_language_code,
        "source_text": source_text,
        "prompt": prompt,
        "glossary": dict(glossary),
        "options": dict(provider_options),
    }
    decoded = _http_post_json(
        url=api_base_url,
        headers=headers,
        payload=payload,
    )
    translated = decoded.get("translated_text")
    if not isinstance(translated, str) or not translated.strip():
        raise RuntimeError("Custom provider response missing translated_text")
    confidence_raw = decoded.get("confidence")
    confidence = None
    if isinstance(confidence_raw, (int, float)):
        confidence = float(confidence_raw)
    return TranslationResult(
        translated_text=translated.strip(),
        confidence=confidence,
        provider=provider,
        model=model,
    )


def _translate_with_settings(
    settings_row: LocalizationTranslationSetting,
    *,
    source_text: str,
    source_language_code: str,
    target_language_code: str,
) -> TranslationResult:
    provider = _normalize_provider(settings_row.provider) or "openai"
    model = _string_or_default(settings_row.model, default="gpt-4.1-mini")
    api_base_url = _normalize_api_base_url(settings_row.api_base_url) or _provider_default_base_url(provider)
    prompt = _string_or_default(
        settings_row.translation_prompt,
        default=_DEFAULT_TRANSLATION_PROMPT,
    )
    glossary = _glossary_map_from_json(settings_row.glossary_json)
    provider_options = _provider_options_from_json(settings_row.provider_options_json)

    protected_text, replacements = _apply_glossary_protection(source_text, glossary)
    if replacements:
        glossary_hint = "\nDo not alter glossary placeholders like [[GLOSSARY_0]]. " "Keep placeholders exactly as-is."
    else:
        glossary_hint = ""

    api_key = _unseal_secret(settings_row.api_key_encrypted)
    if provider in {"openai", "gemini"} and not api_key:
        raise RuntimeError(f"Missing API key for translation provider '{provider}'")

    effective_prompt = f"{prompt}{glossary_hint}".strip()
    if provider == "openai":
        translated = _translate_via_openai(
            api_key=api_key or "",
            api_base_url=api_base_url,
            model=model,
            prompt=effective_prompt,
            source_text=protected_text,
            source_language_code=source_language_code,
            target_language_code=target_language_code,
        )
    elif provider == "gemini":
        translated = _translate_via_gemini(
            api_key=api_key or "",
            api_base_url=api_base_url,
            model=model,
            prompt=effective_prompt,
            source_text=protected_text,
            source_language_code=source_language_code,
            target_language_code=target_language_code,
        )
    else:
        if api_base_url is None:
            raise RuntimeError("Custom translation provider requires api_base_url")
        translated = _translate_via_custom(
            api_key=api_key,
            api_base_url=api_base_url,
            provider=provider,
            model=model,
            prompt=effective_prompt,
            source_text=protected_text,
            source_language_code=source_language_code,
            target_language_code=target_language_code,
            glossary=glossary,
            provider_options=provider_options,
        )

    restored = _restore_glossary_tokens(translated.translated_text, replacements)
    return TranslationResult(
        translated_text=restored,
        confidence=translated.confidence,
        provider=translated.provider,
        model=translated.model,
    )


def _upsert_variant_from_job(
    db: Session,
    *,
    job: LocalizationTranslationJob,
) -> LocalizationTranslationVariant:
    existing = db.scalar(
        select(LocalizationTranslationVariant).where(
            LocalizationTranslationVariant.content_kind == job.content_kind,
            LocalizationTranslationVariant.content_id == job.content_id,
            LocalizationTranslationVariant.field_key == job.field_key,
            LocalizationTranslationVariant.language_code == job.language_code,
        )
    )
    if existing is not None:
        return existing
    row = LocalizationTranslationVariant(
        id=str(uuid.uuid4()),
        source_id=job.source_id,
        content_kind=job.content_kind,
        content_id=job.content_id,
        field_key=job.field_key,
        language_code=job.language_code,
        source_language_code=job.source_language_code,
        source_version=int(job.source_version or 1),
        translated_text="",
        status="pending",
        provider=job.provider,
        model=job.model,
        locked=False,
    )
    db.add(row)
    db.flush()
    return row


def process_due_translation_jobs(
    db: Session,
    *,
    batch_size: int | None = None,
) -> dict[str, int]:
    """Process due translation jobs, including retries and fallback behavior."""
    settings_row = _translation_setting_row(db)
    if not bool(settings_row.translation_enabled):
        return {
            "processed": 0,
            "succeeded": 0,
            "retried": 0,
            "failed": 0,
            "fallback_applied": 0,
        }
    max_batch = _safe_int(
        batch_size if batch_size is not None else settings_row.queue_batch_size,
        default=20,
        minimum=1,
        maximum=250,
    )
    now = _now_utc()
    jobs = (
        db.execute(
            select(LocalizationTranslationJob)
            .where(
                LocalizationTranslationJob.status.in_(("queued", "retry")),
                or_(
                    LocalizationTranslationJob.next_attempt_at.is_(None),
                    LocalizationTranslationJob.next_attempt_at <= now,
                ),
            )
            .order_by(
                LocalizationTranslationJob.next_attempt_at.asc().nullsfirst(),
                LocalizationTranslationJob.created_at.asc(),
                LocalizationTranslationJob.id.asc(),
            )
            .limit(max_batch)
        )
        .scalars()
        .all()
    )

    processed = 0
    succeeded = 0
    retried = 0
    failed = 0
    fallback_applied = 0

    for job in jobs:
        processed += 1
        job.status = "processing"
        job.attempt_count = int(job.attempt_count or 0) + 1
        job.updated_at = now

        source = db.get(LocalizationTranslationSource, job.source_id)
        variant = _upsert_variant_from_job(db, job=job)

        if source is None or not bool(source.active):
            job.status = "failed"
            job.completed_at = now
            job.last_error = "Translation source is missing or inactive"
            variant.status = "failed"
            variant.last_error = job.last_error
            failed += 1
            continue

        if bool(variant.locked):
            job.status = "done"
            job.completed_at = now
            job.last_error = None
            continue

        try:
            result = _translate_with_settings(
                settings_row,
                source_text=job.source_text,
                source_language_code=job.source_language_code,
                target_language_code=job.language_code,
            )
            variant.source_id = source.id
            variant.source_language_code = source.source_language_code
            variant.source_version = int(source.source_version or job.source_version or 1)
            variant.translated_text = result.translated_text
            variant.confidence = result.confidence
            variant.provider = result.provider
            variant.model = result.model
            variant.translated_at = now
            variant.last_error = None
            if bool(settings_row.auto_approve):
                variant.status = "approved"
                variant.reviewed_at = now
                variant.reviewed_by_user_id = job.actor_user_id
            else:
                variant.status = "needs_review"
                variant.reviewed_at = None
                variant.reviewed_by_user_id = None

            job.status = "done"
            job.completed_at = now
            job.last_error = None
            succeeded += 1
            _append_translation_audit_event(
                db,
                action="translated",
                actor_user_id=job.actor_user_id,
                content_kind=job.content_kind,
                content_id=job.content_id,
                summary=(f"Translated {job.field_key} to {job.language_code}" f"{' (auto-approved)' if bool(settings_row.auto_approve) else ''}"),
                after={
                    "field_key": job.field_key,
                    "language_code": job.language_code,
                    "status": variant.status,
                    "provider": result.provider,
                    "model": result.model,
                    "source_version": int(variant.source_version or 1),
                },
            )
        except Exception as error:
            error_message = str(error).strip() or "Translation request failed"
            max_attempts = max(1, int(job.max_attempts or settings_row.queue_max_attempts or 4))
            backoff_seconds = max(1, int(job.backoff_seconds or settings_row.queue_backoff_seconds or 30))

            if bool(settings_row.fallback_to_source):
                variant.source_id = source.id
                variant.source_language_code = source.source_language_code
                variant.source_version = int(source.source_version or job.source_version or 1)
                variant.translated_text = job.source_text
                variant.confidence = 0.0
                variant.provider = _normalize_provider(settings_row.provider) or "openai"
                variant.model = _string_or_default(settings_row.model, default="gpt-4.1-mini")
                variant.status = "fallback"
                variant.translated_at = now
                variant.last_error = error_message

                job.status = "done"
                job.completed_at = now
                job.last_error = error_message
                fallback_applied += 1
                _append_translation_audit_event(
                    db,
                    action="fallback",
                    actor_user_id=job.actor_user_id,
                    content_kind=job.content_kind,
                    content_id=job.content_id,
                    summary=f"Translation fallback applied for {job.field_key}:{job.language_code}",
                    after={
                        "field_key": job.field_key,
                        "language_code": job.language_code,
                        "status": "fallback",
                        "error": error_message,
                    },
                )
                continue

            if int(job.attempt_count or 0) >= max_attempts:
                job.status = "failed"
                job.completed_at = now
                job.last_error = error_message
                variant.status = "failed"
                variant.last_error = error_message
                failed += 1
            else:
                delay_seconds = backoff_seconds * (2 ** max(0, int(job.attempt_count or 1) - 1))
                job.status = "retry"
                job.next_attempt_at = now + timedelta(seconds=delay_seconds)
                job.last_error = error_message
                variant.status = "pending"
                variant.last_error = error_message
                retried += 1

    db.commit()
    return {
        "processed": processed,
        "succeeded": succeeded,
        "retried": retried,
        "failed": failed,
        "fallback_applied": fallback_applied,
    }


def translation_queue_status(
    db: Session,
    *,
    limit: int = 40,
) -> dict[str, Any]:
    """Return queue counters and a recent activity window for translation jobs."""
    settings_row = _translation_setting_row(db)
    safe_limit = max(1, min(int(limit), 200))
    now = _now_utc()
    queued = int(db.scalar(select(func.count(LocalizationTranslationJob.id)).where(LocalizationTranslationJob.status == "queued")) or 0)
    processing = int(db.scalar(select(func.count(LocalizationTranslationJob.id)).where(LocalizationTranslationJob.status == "processing")) or 0)
    retry = int(db.scalar(select(func.count(LocalizationTranslationJob.id)).where(LocalizationTranslationJob.status == "retry")) or 0)
    failed = int(db.scalar(select(func.count(LocalizationTranslationJob.id)).where(LocalizationTranslationJob.status == "failed")) or 0)
    done = int(db.scalar(select(func.count(LocalizationTranslationJob.id)).where(LocalizationTranslationJob.status == "done")) or 0)
    due_now = int(
        db.scalar(
            select(func.count(LocalizationTranslationJob.id)).where(
                LocalizationTranslationJob.status.in_(("queued", "retry")),
                or_(
                    LocalizationTranslationJob.next_attempt_at.is_(None),
                    LocalizationTranslationJob.next_attempt_at <= now,
                ),
            )
        )
        or 0
    )
    recent_rows = (
        db.execute(
            select(LocalizationTranslationJob)
            .order_by(
                LocalizationTranslationJob.created_at.desc(),
                LocalizationTranslationJob.id.desc(),
            )
            .limit(safe_limit)
        )
        .scalars()
        .all()
    )
    recent_jobs: list[dict[str, Any]] = []
    for row in recent_rows:
        recent_jobs.append(
            {
                "id": row.id,
                "content_kind": row.content_kind,
                "content_id": row.content_id,
                "field_key": row.field_key,
                "language_code": row.language_code,
                "status": row.status,
                "attempt_count": int(row.attempt_count or 0),
                "max_attempts": int(row.max_attempts or 1),
                "next_attempt_at": row.next_attempt_at,
                "last_error": row.last_error,
                "triggered_by": row.triggered_by,
                "created_at": row.created_at,
                "updated_at": row.updated_at,
            }
        )
    return {
        "translation_enabled": bool(settings_row.translation_enabled),
        "queued": queued,
        "processing": processing,
        "retry": retry,
        "failed": failed,
        "done": done,
        "due_now": due_now,
        "recent_jobs": recent_jobs,
    }


def list_translation_variants(
    db: Session,
    *,
    content_kind: str | None = None,
    content_id: str | None = None,
    field_key: str | None = None,
    language_code: str | None = None,
    status: str | None = None,
    limit: int = 200,
    offset: int = 0,
) -> dict[str, Any]:
    """List stored translation variants together with their source text context."""
    safe_limit = max(1, min(int(limit), 500))
    safe_offset = max(0, int(offset))
    q = select(LocalizationTranslationVariant, LocalizationTranslationSource).join(
        LocalizationTranslationSource,
        LocalizationTranslationSource.id == LocalizationTranslationVariant.source_id,
    )

    normalized_content_kind = _normalize_content_kind(content_kind)
    if content_kind is not None and normalized_content_kind is None:
        raise bad_request("Invalid content_kind filter")
    if normalized_content_kind is not None:
        q = q.where(LocalizationTranslationVariant.content_kind == normalized_content_kind)

    normalized_content_id = None if content_id is None else str(content_id).strip()
    if normalized_content_id:
        q = q.where(LocalizationTranslationVariant.content_id == normalized_content_id)

    normalized_field_key = _normalize_field_key(field_key)
    if field_key is not None and normalized_field_key is None:
        raise bad_request("Invalid field_key filter")
    if normalized_field_key is not None:
        q = q.where(LocalizationTranslationVariant.field_key == normalized_field_key)

    normalized_language_code = _normalize_language_code(language_code)
    if language_code is not None and normalized_language_code is None:
        raise bad_request("Invalid language_code filter")
    if normalized_language_code is not None:
        q = q.where(LocalizationTranslationVariant.language_code == normalized_language_code)

    normalized_status = None if status is None else str(status).strip().lower()
    if normalized_status:
        q = q.where(LocalizationTranslationVariant.status == normalized_status)

    count_subquery = q.subquery()
    total = int(db.scalar(select(func.count()).select_from(count_subquery)) or 0)
    rows = db.execute(
        q.order_by(
            LocalizationTranslationVariant.updated_at.desc(),
            LocalizationTranslationVariant.id.desc(),
        )
        .offset(safe_offset)
        .limit(safe_limit)
    ).all()

    items: list[dict[str, Any]] = []
    for variant, source in rows:
        items.append(
            {
                "id": variant.id,
                "content_kind": variant.content_kind,
                "content_id": variant.content_id,
                "field_key": variant.field_key,
                "language_code": variant.language_code,
                "source_language_code": variant.source_language_code,
                "source_version": int(variant.source_version or 1),
                "source_text": source.source_text,
                "translated_text": variant.translated_text,
                "status": variant.status,
                "confidence": variant.confidence,
                "provider": variant.provider,
                "model": variant.model,
                "locked": bool(variant.locked),
                "last_error": variant.last_error,
                "translated_at": variant.translated_at,
                "reviewed_by_user_id": variant.reviewed_by_user_id,
                "reviewed_at": variant.reviewed_at,
                "updated_at": variant.updated_at,
            }
        )
    return {"items": items, "total": total}


def _queue_retranslate_for_variant(
    db: Session,
    *,
    variant: LocalizationTranslationVariant,
    actor_user_id: str | None,
    reason: str,
    include_locked: bool = False,
) -> int:
    source = db.get(LocalizationTranslationSource, variant.source_id)
    if source is None or not bool(source.active):
        return 0
    settings_row = _translation_setting_row(db)
    queued = _queue_translation_jobs_for_source(
        db,
        source=source,
        settings_row=settings_row,
        triggered_by=reason,
        actor_user_id=actor_user_id,
        language_codes=[variant.language_code],
        include_locked=include_locked,
        force=True,
    )
    return queued


def update_translation_variant(
    db: Session,
    *,
    variant_id: str,
    action: str,
    actor_user_id: str | None,
    translated_text: str | None = None,
    note: str | None = None,
) -> dict[str, Any]:
    """Apply a reviewer action such as approve, edit, lock, or retranslate."""
    variant = db.get(LocalizationTranslationVariant, variant_id)
    if variant is None:
        raise not_found("Translation variant not found")
    source = db.get(LocalizationTranslationSource, variant.source_id)
    if source is None:
        raise not_found("Translation source not found")

    normalized_action = action.strip().lower()
    before = {
        "status": variant.status,
        "locked": bool(variant.locked),
        "translated_text": variant.translated_text,
    }
    now = _now_utc()
    queued_jobs = 0

    if normalized_action == "approve":
        variant.status = "approved"
        variant.reviewed_at = now
        variant.reviewed_by_user_id = actor_user_id
    elif normalized_action == "edit":
        if translated_text is None or not translated_text.strip():
            raise bad_request("translated_text is required for edit action")
        variant.translated_text = translated_text.strip()
        variant.status = "approved"
        variant.reviewed_at = now
        variant.reviewed_by_user_id = actor_user_id
        variant.translated_at = now
        variant.last_error = None
    elif normalized_action == "lock":
        variant.locked = True
        variant.status = "locked"
        variant.reviewed_at = now
        variant.reviewed_by_user_id = actor_user_id
    elif normalized_action == "unlock":
        variant.locked = False
        if variant.status == "locked":
            variant.status = "needs_review"
        variant.reviewed_at = now
        variant.reviewed_by_user_id = actor_user_id
    elif normalized_action == "retranslate":
        variant.locked = False
        queued_jobs = _queue_retranslate_for_variant(
            db,
            variant=variant,
            actor_user_id=actor_user_id,
            reason="manual_retranslate",
            include_locked=True,
        )
    else:
        raise bad_request("Unsupported translation action")

    after = {
        "status": variant.status,
        "locked": bool(variant.locked),
        "translated_text": variant.translated_text,
        "queued_jobs": queued_jobs,
        "note": note.strip() if isinstance(note, str) and note.strip() else None,
    }
    _append_translation_audit_event(
        db,
        action=f"review_{normalized_action}",
        actor_user_id=actor_user_id,
        content_kind=variant.content_kind,
        content_id=variant.content_id,
        summary=(f"Translation {normalized_action} for " f"{variant.field_key}:{variant.language_code}"),
        before=before,
        after=after,
    )
    db.commit()
    db.refresh(variant)
    return {
        "id": variant.id,
        "content_kind": variant.content_kind,
        "content_id": variant.content_id,
        "field_key": variant.field_key,
        "language_code": variant.language_code,
        "source_language_code": variant.source_language_code,
        "source_version": int(variant.source_version or 1),
        "source_text": source.source_text,
        "translated_text": variant.translated_text,
        "status": variant.status,
        "confidence": variant.confidence,
        "provider": variant.provider,
        "model": variant.model,
        "locked": bool(variant.locked),
        "last_error": variant.last_error,
        "translated_at": variant.translated_at,
        "reviewed_by_user_id": variant.reviewed_by_user_id,
        "reviewed_at": variant.reviewed_at,
        "updated_at": variant.updated_at,
    }


def translate_missing_content(
    db: Session,
    *,
    actor_user_id: str | None,
    content_kind: str | None = None,
    content_id: str | None = None,
    language_codes: Sequence[str] | None = None,
    include_locked: bool = False,
) -> dict[str, int]:
    """Queue translations only for missing, empty, failed, or stale variants."""
    q = select(LocalizationTranslationSource).where(LocalizationTranslationSource.active.is_(True))
    normalized_content_kind = _normalize_content_kind(content_kind)
    if content_kind is not None and normalized_content_kind is None:
        raise bad_request("Invalid content_kind")
    if normalized_content_kind is not None:
        q = q.where(LocalizationTranslationSource.content_kind == normalized_content_kind)
    normalized_content_id = None if content_id is None else str(content_id).strip()
    if normalized_content_id:
        q = q.where(LocalizationTranslationSource.content_id == normalized_content_id)

    sources = db.execute(q).scalars().all()
    settings_row = _translation_setting_row(db)
    total_jobs = 0
    target_variants = 0

    for source in sources:
        if language_codes is None:
            candidate_codes = _enabled_target_language_codes(
                db,
                source_language_code=source.source_language_code,
            )
        else:
            candidate_codes = []
            seen_codes: set[str] = set()
            for raw in language_codes:
                normalized = _normalize_language_code(raw)
                if normalized is None or normalized in seen_codes or normalized == source.source_language_code:
                    continue
                seen_codes.add(normalized)
                candidate_codes.append(normalized)

        missing_codes: list[str] = []
        for code in candidate_codes:
            variant = db.scalar(
                select(LocalizationTranslationVariant).where(
                    LocalizationTranslationVariant.content_kind == source.content_kind,
                    LocalizationTranslationVariant.content_id == source.content_id,
                    LocalizationTranslationVariant.field_key == source.field_key,
                    LocalizationTranslationVariant.language_code == code,
                )
            )
            target_variants += 1
            if variant is None:
                missing_codes.append(code)
                continue
            if bool(variant.locked) and not include_locked:
                continue
            translated_text = (variant.translated_text or "").strip()
            if not translated_text:
                missing_codes.append(code)
                continue
            if int(variant.source_version or 1) < int(source.source_version or 1):
                missing_codes.append(code)
                continue
            if variant.status in {"failed", "pending"}:
                missing_codes.append(code)
                continue

        if not missing_codes:
            continue
        queued = _queue_translation_jobs_for_source(
            db,
            source=source,
            settings_row=settings_row,
            triggered_by="translate_missing",
            actor_user_id=actor_user_id,
            language_codes=missing_codes,
            include_locked=include_locked,
            force=False,
        )
        total_jobs += queued

    if total_jobs > 0:
        _append_translation_audit_event(
            db,
            action="translate_missing",
            actor_user_id=actor_user_id,
            content_kind=normalized_content_kind or "all",
            content_id=normalized_content_id or "all",
            summary=f"Queued {total_jobs} missing translation job(s)",
            after={
                "queued_jobs": total_jobs,
                "target_variants": target_variants,
                "include_locked": include_locked,
            },
        )
    db.commit()
    return {"queued_jobs": total_jobs, "target_variants": target_variants}


def bulk_retranslate(
    db: Session,
    *,
    actor_user_id: str | None,
    content_kind: str | None = None,
    content_id: str | None = None,
    language_codes: Sequence[str] | None = None,
    include_locked: bool = False,
    reason: str = "manual_bulk",
) -> dict[str, int]:
    """Force a retranslation pass for matching sources and target languages."""
    q = select(LocalizationTranslationSource).where(LocalizationTranslationSource.active.is_(True))
    normalized_content_kind = _normalize_content_kind(content_kind)
    if content_kind is not None and normalized_content_kind is None:
        raise bad_request("Invalid content_kind")
    if normalized_content_kind is not None:
        q = q.where(LocalizationTranslationSource.content_kind == normalized_content_kind)
    normalized_content_id = None if content_id is None else str(content_id).strip()
    if normalized_content_id:
        q = q.where(LocalizationTranslationSource.content_id == normalized_content_id)

    sources = db.execute(q).scalars().all()
    settings_row = _translation_setting_row(db)
    total_jobs = 0
    for source in sources:
        queued = _queue_translation_jobs_for_source(
            db,
            source=source,
            settings_row=settings_row,
            triggered_by=reason,
            actor_user_id=actor_user_id,
            language_codes=language_codes,
            include_locked=include_locked,
            force=True,
        )
        total_jobs += queued

    if total_jobs > 0:
        _append_translation_audit_event(
            db,
            action="bulk_retranslate",
            actor_user_id=actor_user_id,
            content_kind=normalized_content_kind or "all",
            content_id=normalized_content_id or "all",
            summary=f"Queued {total_jobs} bulk translation job(s)",
            after={
                "queued_jobs": total_jobs,
                "reason": reason,
                "include_locked": include_locked,
            },
        )

    db.commit()
    return {"queued_jobs": total_jobs, "target_variants": len(sources)}
