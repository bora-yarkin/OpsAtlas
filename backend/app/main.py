# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""FastAPI application bootstrap, security middleware, and public utility endpoints."""

import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import datetime
from urllib.parse import urlparse

from fastapi import Depends, FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session
from starlette.middleware.trustedhost import TrustedHostMiddleware

from app.core.auth.policy import is_dev_environment
from app.core.background import maintenance_loop, stop_maintenance_loop
from app.core.build_info import APP_BUILD, APP_RELEASE, APP_VERSION
from app.core.config import settings
from app.core.db import SessionLocal
from app.core.db import init_db
from app.core.deps import get_db
from app.core.secret_crypto import require_secret_encryption_keys

from app.modules.auth.router import router as auth_router
from app.modules.spaces.router import router as spaces_router
from app.modules.kb.router import router as kb_router
from app.modules.sop.router import router as sop_router
from app.modules.incidents.router import router as incidents_router
from app.modules.analytics.router import router as analytics_router
from app.modules.admin.router import router as admin_router
from app.modules.backup.router import router as backup_router
from app.modules.ai.router import router as ai_router
from app.modules.tasks.router import router as tasks_router
from app.modules.media.router import router as media_router
from app.modules.localization.router import router as localization_router
from app.modules.localization import service as localization_service
from app.modules.admin import service as admin_service
from app.modules.admin.schemas import BrandingManifestOut, BrandingOut


def _normalize_host_token(raw: str) -> str:
    """Extract a normalized hostname token from a host or origin string."""
    value = raw.strip().lower()
    if not value:
        return ""
    if value.startswith("http://") or value.startswith("https://"):
        parsed = urlparse(value)
        return (parsed.hostname or "").strip().lower()
    if value.startswith("[") and "]" in value:
        return value[1 : value.index("]")].strip().lower()
    if ":" in value and value.count(":") == 1:
        return value.split(":", 1)[0].strip().lower()
    return value


def _is_local_host_token(raw: str) -> bool:
    """Return whether the provided token points at a localhost-style target."""
    host = _normalize_host_token(raw)
    return host in {"localhost", "127.0.0.1", "::1"} or host == "*.localhost" or host.endswith(".localhost")


def _dedupe_host_tokens(values: list[str]) -> list[str]:
    """Preserve host order while dropping empty and duplicate values."""
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        token = value.strip()
        if not token or token in seen:
            continue
        seen.add(token)
        result.append(token)
    return result


def _resolve_public_api_trusted_hosts() -> list[str]:
    """Derive trusted hosts from the public API base URL in production-like deployments."""
    if is_dev_environment():
        return []
    host = _normalize_host_token(settings.public_api_base_url or "")
    if not host or _is_local_host_token(host):
        return []
    return [host]


def _resolve_public_web_cors_origins() -> list[str]:
    """Derive allowed browser origins from the configured public web origin."""
    if is_dev_environment():
        return []
    origin = (settings.public_web_origin or "").strip()
    if not origin:
        return []
    host = _normalize_host_token(origin)
    if not host or _is_local_host_token(host):
        return []
    return [origin]


def _validate_runtime_security_configuration() -> None:
    """Fail fast when runtime security settings are unsafe for the current environment."""
    if not is_dev_environment():
        if settings.auto_create_tables:
            raise RuntimeError("AUTO_CREATE_TABLES must be false outside development environments")
        require_secret_encryption_keys()
        return

    relaxed_auth_bypass = (not settings.password_enforce_in_dev) or (settings.mfa_enabled and not settings.mfa_enforce_in_dev)
    if not relaxed_auth_bypass:
        return

    if not settings.cors_origins:
        raise RuntimeError(
            "APP_ENV=dev with relaxed password/MFA enforcement requires explicit localhost-only CORS_ORIGINS"
        )

    unsafe_origins = [origin for origin in settings.cors_origins if origin.strip() and not _is_local_host_token(origin)]
    unsafe_hosts = [host for host in settings.trusted_hosts if host.strip() and not _is_local_host_token(host)]
    if unsafe_origins or unsafe_hosts:
        raise RuntimeError(
            "Development auth policy bypass is restricted to localhost-only deployments; "
            "set APP_ENV to a non-development value or enable PASSWORD_ENFORCE_IN_DEV and MFA_ENFORCE_IN_DEV"
        )


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    """Initialize persistent state on startup and stop background workers on shutdown."""
    maintenance_task: asyncio.Task[None] | None = None
    maintenance_stop: asyncio.Event | None = None
    _validate_runtime_security_configuration()
    if settings.auto_create_tables:
        init_db()
    with SessionLocal() as db:
        if settings.auto_create_tables:
            admin_service.sync_organization_items(db)
        localization_service.reinstall_builtin_bundles(db)
    if settings.background_workers_enabled:
        maintenance_stop = asyncio.Event()
        maintenance_task = asyncio.create_task(maintenance_loop(maintenance_stop))
    yield
    await stop_maintenance_loop(maintenance_task, maintenance_stop)


app = FastAPI(title=settings.app_name, lifespan=lifespan)


def _resolve_cors_origins() -> list[str]:
    """Resolve the effective CORS allowlist for the current environment."""
    configured = [origin.strip() for origin in settings.cors_origins if origin.strip()]
    derived = _resolve_public_web_cors_origins()
    combined = _dedupe_host_tokens([*configured, *derived])
    if combined:
        if not is_dev_environment() and "*" in combined:
            raise RuntimeError("Unsafe CORS configuration: '*' is not allowed outside development")
        return combined
    if is_dev_environment():
        return ["*"]
    raise RuntimeError("CORS_ORIGINS must be configured for non-development environments")


def _resolve_trusted_hosts() -> list[str]:
    """Resolve the trusted host allowlist used by Starlette's host middleware."""
    configured = [host.strip() for host in settings.trusted_hosts if host.strip()]
    derived = _resolve_public_api_trusted_hosts()
    combined = _dedupe_host_tokens([*configured, *derived])
    if combined:
        return combined
    if is_dev_environment():
        return ["localhost", "127.0.0.1", "[::1]", "*.localhost"]
    raise RuntimeError(
        "TRUSTED_HOSTS must be configured for non-development environments; "
        "PUBLIC_API_BASE_URL can provide the primary API hostname"
    )


def _security_csp_value() -> str:
    """Build the content-security-policy header value for the active environment."""
    if is_dev_environment():
        return "default-src 'self'; " "base-uri 'self'; " "object-src 'none'; " "frame-ancestors 'none'; " "img-src 'self' data: blob: https: http:; " "style-src 'self' 'unsafe-inline'; " "script-src 'self' 'unsafe-inline' 'unsafe-eval'; " "connect-src 'self' https: http: ws: wss:"
    return "default-src 'self'; " "base-uri 'self'; " "object-src 'none'; " "frame-ancestors 'none'; " "form-action 'self'; " "img-src 'self' data: https:; " "font-src 'self' data:; " "style-src 'self' 'unsafe-inline'; " "script-src 'self'; " "connect-src 'self' https:; " "manifest-src 'self'; " "worker-src 'self' blob:; " "upgrade-insecure-requests"


cors_origins = _resolve_cors_origins()
cors_allow_credentials = "*" not in cors_origins
trusted_hosts = _resolve_trusted_hosts()

app.add_middleware(
    CORSMiddleware,
    allow_origins=cors_origins,
    allow_credentials=cors_allow_credentials,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.add_middleware(
    TrustedHostMiddleware,
    allowed_hosts=trusted_hosts,
)


@app.middleware("http")
async def security_headers_middleware(request: Request, call_next):
    """Attach baseline security headers to every HTTP response."""
    response = await call_next(request)
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("X-Frame-Options", "DENY")
    response.headers.setdefault("X-Permitted-Cross-Domain-Policies", "none")
    response.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
    response.headers.setdefault("Cross-Origin-Opener-Policy", "same-origin")
    response.headers.setdefault("Cross-Origin-Resource-Policy", "same-site")
    response.headers.setdefault("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
    response.headers.setdefault(
        "Content-Security-Policy",
        _security_csp_value(),
    )
    if not is_dev_environment():
        response.headers.setdefault(
            "Strict-Transport-Security",
            f"max-age={settings.hsts_max_age_seconds}; includeSubDomains; preload",
        )
    return response


app.include_router(auth_router)
app.include_router(spaces_router)
app.include_router(kb_router)
app.include_router(sop_router)
app.include_router(incidents_router)
app.include_router(analytics_router)
app.include_router(admin_router)
app.include_router(backup_router)
app.include_router(ai_router)
app.include_router(tasks_router)
app.include_router(media_router)
app.include_router(localization_router)


@app.get("/branding", response_model=BrandingOut, tags=["branding"])
def public_branding(db: Session = Depends(get_db)):
    """Return the effective public branding payload consumed by the frontend shell."""
    payload = admin_service.get_effective_branding(db)
    return BrandingOut(
        company_name=payload.get("company_name") if isinstance(payload.get("company_name"), str) else None,
        application_title=payload.get("application_title") if isinstance(payload.get("application_title"), str) else None,
        application_short_name=payload.get("application_short_name")
        if isinstance(payload.get("application_short_name"), str)
        else None,
        web_description=payload.get("web_description") if isinstance(payload.get("web_description"), str) else None,
        apple_web_app_title=payload.get("apple_web_app_title")
        if isinstance(payload.get("apple_web_app_title"), str)
        else None,
        logo_url=payload.get("logo_url") if isinstance(payload.get("logo_url"), str) else None,
        light_logo_url=payload.get("light_logo_url") if isinstance(payload.get("light_logo_url"), str) else None,
        dark_logo_url=payload.get("dark_logo_url") if isinstance(payload.get("dark_logo_url"), str) else None,
        favicon_url=payload.get("favicon_url") if isinstance(payload.get("favicon_url"), str) else None,
        login_background_url=payload.get("login_background_url") if isinstance(payload.get("login_background_url"), str) else None,
        light_seed_hex=payload.get("light_seed_hex") if isinstance(payload.get("light_seed_hex"), str) else None,
        dark_accent_hex=payload.get("dark_accent_hex") if isinstance(payload.get("dark_accent_hex"), str) else None,
        dark_bg_hex=payload.get("dark_bg_hex") if isinstance(payload.get("dark_bg_hex"), str) else None,
        browser_theme_hex=payload.get("browser_theme_hex") if isinstance(payload.get("browser_theme_hex"), str) else None,
        install_background_hex=payload.get("install_background_hex")
        if isinstance(payload.get("install_background_hex"), str)
        else None,
        resolved_app_title=payload.get("resolved_app_title") if isinstance(payload.get("resolved_app_title"), str) else "OpsAtlas",
        resolved_application_short_name=payload.get("resolved_application_short_name")
        if isinstance(payload.get("resolved_application_short_name"), str)
        else "OpsAtlas",
        resolved_web_description=payload.get("resolved_web_description")
        if isinstance(payload.get("resolved_web_description"), str)
        else "OpsAtlas is a self-hosted operations workspace for procedures, incidents, knowledge, and follow-up work.",
        resolved_apple_web_app_title=payload.get("resolved_apple_web_app_title")
        if isinstance(payload.get("resolved_apple_web_app_title"), str)
        else "OpsAtlas",
        resolved_theme_color_hex=payload.get("resolved_theme_color_hex")
        if isinstance(payload.get("resolved_theme_color_hex"), str)
        else "#0F67E8",
        resolved_install_background_hex=payload.get("resolved_install_background_hex")
        if isinstance(payload.get("resolved_install_background_hex"), str)
        else "#0A0D12",
        updated_at=payload.get("updated_at") if isinstance(payload.get("updated_at"), datetime) else None,
    )


@app.get("/branding/manifest.webmanifest", response_model=BrandingManifestOut, tags=["branding"])
def public_branding_manifest(db: Session = Depends(get_db)):
    """Return the installable web manifest generated from organization branding."""
    return BrandingManifestOut(**admin_service.get_branding_manifest(db))


@app.get("/health")
def health():
    """Provide a lightweight liveness probe for process health checks."""
    return {
        "ok": True,
        "version": APP_VERSION,
        "build": APP_BUILD,
        "release": APP_RELEASE,
    }
