#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import base64
import os
import secrets
from pathlib import Path


PLACEHOLDER_DB_PASSWORD = "change_me_postgres_password"
PLACEHOLDER_JWT_SECRET = "change_me_long_random"
PLACEHOLDER_SECRET_KEY = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"


def _release_root() -> Path:
    return Path(os.environ.get("OPSATLAS_RELEASE_ROOT", "/release-root"))


def _bootstrap_dir() -> Path:
    return Path(os.environ.get("OPSATLAS_BOOTSTRAP_DIR", "/bootstrap"))


def _env_relative_path() -> str:
    explicit = (os.environ.get("OPSATLAS_ENV_FILE") or "").strip()
    if explicit:
        return explicit

    root = _release_root()
    for candidate in (".env", ".env.docker"):
        if (root / candidate).exists():
            return candidate

    return ".env"


def _template_relative_path(env_relative_path: str) -> str:
    if env_relative_path.endswith(".env"):
        return f"{env_relative_path}.example"
    return f"{env_relative_path}.example"


def _load_existing_generated_values(bootstrap_dir: Path) -> dict[str, str]:
    generated_path = bootstrap_dir / "generated.env"
    if not generated_path.exists():
        return {}
    return _parse_env_file(generated_path.read_text(encoding="utf-8"))


def _parse_env_file(content: str) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        parsed[key.strip()] = value.strip()
    return parsed


def _urlsafe_secret(length: int) -> str:
    return secrets.token_urlsafe(length)


def _secret_encryption_key() -> str:
    return base64.urlsafe_b64encode(secrets.token_bytes(32)).decode("ascii").rstrip("=")


def _replace_or_append_env_value(content: str, key: str, value: str) -> str:
    lines = content.splitlines()
    prefix = f"{key}="
    for index, line in enumerate(lines):
        if line.startswith(prefix):
            lines[index] = f"{key}={value}"
            return "\n".join(lines) + "\n"
    if lines and lines[-1].strip():
        lines.append("")
    lines.append(f"{key}={value}")
    return "\n".join(lines).rstrip() + "\n"


def _materialize_host_env(
    root: Path,
    env_relative_path: str,
    bootstrap_dir: Path | None = None,
) -> tuple[Path, dict[str, str]]:
    env_path = root / env_relative_path
    template_path = root / _template_relative_path(env_relative_path)
    persisted_values = _load_existing_generated_values(bootstrap_dir or _bootstrap_dir())
    if not template_path.exists():
        fallback = root / ".env.example"
        if fallback.exists():
            template_path = fallback
    if env_path.exists():
        content = env_path.read_text(encoding="utf-8")
    else:
        content = template_path.read_text(encoding="utf-8")

    values = _parse_env_file(content)
    updates: dict[str, str] = {}

    db_password = values.get("OPSATLAS_DB_PASSWORD", "").strip()
    if not db_password or db_password == PLACEHOLDER_DB_PASSWORD:
        updates["OPSATLAS_DB_PASSWORD"] = (
            persisted_values.get("OPSATLAS_DB_PASSWORD", "").strip()
            or _urlsafe_secret(24)
        )

    jwt_secret = values.get("JWT_SECRET", "").strip()
    if not jwt_secret or jwt_secret == PLACEHOLDER_JWT_SECRET:
        updates["JWT_SECRET"] = (
            persisted_values.get("JWT_SECRET", "").strip() or _urlsafe_secret(48)
        )

    secret_keys = values.get("SECRET_ENCRYPTION_KEYS", "").strip()
    if not secret_keys or secret_keys == PLACEHOLDER_SECRET_KEY:
        updates["SECRET_ENCRYPTION_KEYS"] = (
            persisted_values.get("SECRET_ENCRYPTION_KEYS", "").strip()
            or _secret_encryption_key()
        )

    for key, value in updates.items():
        content = _replace_or_append_env_value(content, key, value)
        values[key] = value

    env_path.write_text(content, encoding="utf-8")
    os.chmod(env_path, 0o600)
    return env_path, values


def _write_generated_env(bootstrap_dir: Path, values: dict[str, str]) -> Path:
    bootstrap_dir.mkdir(parents=True, exist_ok=True)

    db_name = values.get("OPSATLAS_DB_NAME", "opsatlas").strip() or "opsatlas"
    db_user = values.get("OPSATLAS_DB_USER", "opsatlas").strip() or "opsatlas"

    generated = dict(values)
    generated["POSTGRES_DB"] = db_name
    generated["POSTGRES_USER"] = db_user

    lines = [f"{key}={value}" for key, value in sorted(generated.items())]
    output_path = bootstrap_dir / "generated.env"
    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.chmod(output_path, 0o600)
    return output_path


def main() -> None:
    root = _release_root()
    bootstrap_dir = _bootstrap_dir()
    env_relative_path = _env_relative_path()
    env_path, values = _materialize_host_env(root, env_relative_path, bootstrap_dir)
    generated_path = _write_generated_env(bootstrap_dir, values)
    print(f"OpsAtlas environment ready at {env_path}")
    print(f"Generated runtime secrets written to {generated_path}")


if __name__ == "__main__":
    main()
