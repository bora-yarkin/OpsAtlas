# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import asyncio
import base64
import hashlib
from http.cookies import SimpleCookie

import pytest
from fastapi import Request, Response

from app.core import deps
from app.core.auth import cookies as auth_cookies
from app.core.auth import policy as auth_policy
from app.core import background
from app.core.config import settings
from app.core.secret_crypto import (
    decrypt_secret,
    encrypt_secret,
    has_configured_secret_encryption_keys,
    is_current_secret_encryption,
    require_secret_encryption_keys,
)
from app.modules.backup.service import BackupService


def _set_settings(monkeypatch: pytest.MonkeyPatch, **overrides: object) -> None:
    for key, value in overrides.items():
        monkeypatch.setattr(settings, key, value)


def _cookie_request(cookie_header: str) -> Request:
    return Request(
        {
            "type": "http",
            "method": "GET",
            "path": "/",
            "scheme": "http",
            "query_string": b"",
            "headers": [(b"cookie", cookie_header.encode("utf-8"))],
            "client": ("127.0.0.1", 12345),
            "server": ("testserver", 80),
        }
    )


def _encoded_key(seed: bytes) -> str:
    return base64.urlsafe_b64encode(seed).decode("ascii").rstrip("=")


def _cookie_value(header_line: str, key: str) -> str | None:
    cookie = SimpleCookie()
    cookie.load(header_line)
    morsel = cookie.get(key)
    return None if morsel is None else morsel.value


def test_auth_policy_environment_flags_and_token_hashing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _set_settings(
        monkeypatch,
        app_env="dev",
        password_enforce_in_dev=False,
        mfa_enabled=True,
        mfa_enforce_in_dev=False,
    )

    assert auth_policy.is_dev_environment() is True
    assert auth_policy.should_enforce_password_policy() is False
    assert auth_policy.should_enforce_mfa() is False

    onboarding = auth_policy.generate_onboarding_token(8)
    refresh = auth_policy.generate_refresh_token(12)
    assert len(onboarding) >= 22
    assert len(refresh) >= 32
    assert auth_policy.hash_onboarding_token("  abc  ") == hashlib.sha256(
        b"abc"
    ).hexdigest()
    assert auth_policy.hash_refresh_token("  xyz  ") == hashlib.sha256(
        b"xyz"
    ).hexdigest()
    assert auth_policy.hash_onboarding_token("") == ""
    assert auth_policy.hash_refresh_token("") == ""

    _set_settings(
        monkeypatch,
        app_env="production",
        password_enforce_in_dev=True,
        mfa_enforce_in_dev=True,
    )
    assert auth_policy.is_dev_environment() is False
    assert auth_policy.should_enforce_password_policy() is True
    assert auth_policy.should_enforce_mfa() is True


def test_validate_password_policy_relaxed_dev_only_enforces_baseline(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _set_settings(
        monkeypatch,
        app_env="test",
        password_enforce_in_dev=False,
        password_min_length=12,
        password_require_upper=True,
        password_require_lower=True,
        password_require_digit=True,
        password_require_symbol=True,
        password_compromised_check_enabled=True,
    )

    auth_policy.validate_password_policy("simple1")

    with pytest.raises(Exception) as exc_info:
        auth_policy.validate_password_policy("tiny")
    assert "at least 6 characters" in str(exc_info.value)


@pytest.mark.parametrize(
    ("password", "expected_detail", "email", "name"),
    [
        ("lowercase1!", "uppercase letter", None, None),
        ("UPPERCASE1!", "lowercase letter", None, None),
        ("NoDigits!!", "one digit", None, None),
        ("NoSymbols1", "special character", None, None),
        ("password", "too common", None, None),
        ("aliceSecure1!", "email name", "alice@example.com", None),
        ("JordanSecure1!", "your name", None, "Jordan Example"),
    ],
)
def test_validate_password_policy_rejects_common_and_personalized_passwords(
    monkeypatch: pytest.MonkeyPatch,
    password: str,
    expected_detail: str,
    email: str | None,
    name: str | None,
) -> None:
    compromised_case = expected_detail == "too common"
    _set_settings(
        monkeypatch,
        app_env="production",
        password_enforce_in_dev=True,
        password_min_length=8,
        password_require_upper=not compromised_case,
        password_require_lower=True,
        password_require_digit=not compromised_case,
        password_require_symbol=not compromised_case,
        password_compromised_check_enabled=True,
    )

    with pytest.raises(Exception) as exc_info:
        auth_policy.validate_password_policy(password, email=email, name=name)
    assert expected_detail in str(exc_info.value)

    auth_policy.validate_password_policy(
        "Stronger1!Pass",
        email="someone@example.com",
        name="Jordan Example",
    )


def test_cookie_helpers_set_read_and_clear_auth_cookies(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _set_settings(
        monkeypatch,
        app_env="production",
        auth_cookie_secure=True,
        auth_cookie_secure_in_dev=False,
        auth_cookie_domain="example.com",
        auth_cookie_path="auth",
        auth_cookie_samesite="strict",
        auth_cookie_access_name="ops_access",
        auth_cookie_refresh_name="ops_refresh",
        auth_cookie_session_name="ops_session",
        access_token_minutes=15,
        refresh_token_days=5,
        secret_encryption_keys=["unit-test-cookie-key"],
    )

    response = Response()
    auth_cookies.set_auth_cookies(
        response,
        access_token="access-token",
        refresh_token="refresh-token",
        session_id="session-token",
        refresh_max_age_seconds=7200,
    )
    auth_cookies.set_access_cookie(response, access_token="access-only")

    cookie_headers = response.headers.getlist("set-cookie")
    assert len(cookie_headers) == 4
    assert any("HttpOnly" in header for header in cookie_headers)
    assert any("SameSite=strict" in header for header in cookie_headers)
    assert any("Domain=example.com" in header for header in cookie_headers)
    assert any("Path=/auth" in header for header in cookie_headers)
    assert any("Secure" in header for header in cookie_headers)
    assert _cookie_value(cookie_headers[0], "ops_access") != "access-token"
    assert _cookie_value(cookie_headers[1], "ops_refresh") != "refresh-token"
    assert _cookie_value(cookie_headers[2], "ops_session") != "session-token"
    assert _cookie_value(cookie_headers[3], "ops_access") != "access-only"

    request = _cookie_request(
        "; ".join(
            [
                f"ops_access={_cookie_value(cookie_headers[0], 'ops_access')}",
                f"ops_refresh={_cookie_value(cookie_headers[1], 'ops_refresh')}",
                f"ops_session={_cookie_value(cookie_headers[2], 'ops_session')}",
            ]
        )
    )
    assert auth_cookies.read_access_cookie(request) == "access-token"
    assert auth_cookies.read_refresh_cookie(request) == "refresh-token"
    assert auth_cookies.read_session_cookie(request) == "session-token"

    legacy_request = _cookie_request(
        "ops_access= access-cookie ; ops_refresh=refresh-cookie; ops_session=session-cookie"
    )
    assert auth_cookies.read_access_cookie(legacy_request) is None
    assert auth_cookies.read_refresh_cookie(legacy_request) is None
    assert auth_cookies.read_session_cookie(legacy_request) is None

    clear_response = Response()
    auth_cookies.clear_auth_cookies(clear_response)
    cleared_headers = clear_response.headers.getlist("set-cookie")
    assert len(cleared_headers) == 3
    assert all("Max-Age=0" in header for header in cleared_headers)

    _set_settings(
        monkeypatch,
        app_env="dev",
        auth_cookie_domain="",
        auth_cookie_path="",
        auth_cookie_samesite="invalid",
        auth_cookie_secure_in_dev=True,
    )
    dev_response = Response()
    auth_cookies.set_access_cookie(dev_response, access_token="dev-token")
    dev_header = dev_response.headers.get("set-cookie", "")
    assert "SameSite=lax" in dev_header
    assert "Path=/" in dev_header
    assert "Secure" in dev_header


def test_deps_helpers_return_http_exceptions_and_close_sessions(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class DummySession:
        def __init__(self) -> None:
            self.closed = False

        def close(self) -> None:
            self.closed = True

    dummy = DummySession()
    monkeypatch.setattr(deps, "SessionLocal", lambda: dummy)

    generator = deps.get_db()
    assert next(generator) is dummy
    with pytest.raises(StopIteration):
        next(generator)
    assert dummy.closed is True

    assert deps.forbidden("nope").status_code == 403
    assert deps.unauthorized("bad").status_code == 401
    assert deps.not_found("gone").status_code == 404
    assert deps.bad_request("oops").status_code == 400
    assert deps.too_many_requests("slow down").status_code == 429


def test_secret_crypto_handles_rotation_and_fallback(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    key_one = _encoded_key(b"1" * 32)
    key_two = _encoded_key(b"2" * 32)

    _set_settings(
        monkeypatch,
        app_env="production",
        jwt_secret="jwt-seed",
        secret_encryption_keys=[key_one],
    )

    assert has_configured_secret_encryption_keys() is True
    require_secret_encryption_keys()

    encrypted = encrypt_secret("top-secret")
    assert encrypted is not None
    assert decrypt_secret(encrypted) == "top-secret"
    assert is_current_secret_encryption(encrypted) is True
    assert decrypt_secret("bogus") is None
    assert decrypt_secret("v1:missing:bad:payload") is None

    _set_settings(
        monkeypatch,
        app_env="production",
        secret_encryption_keys=[key_two, key_one],
    )
    assert decrypt_secret(encrypted) == "top-secret"
    assert is_current_secret_encryption(encrypted) is True

    rotated = encrypt_secret("rotated-secret")
    assert rotated is not None
    assert rotated != encrypted
    assert decrypt_secret(rotated) == "rotated-secret"
    assert is_current_secret_encryption(rotated) is True

    _set_settings(
        monkeypatch,
        app_env="test",
        jwt_secret="fallback-jwt",
        secret_encryption_keys=[],
    )
    assert has_configured_secret_encryption_keys() is False
    require_secret_encryption_keys()
    fallback_encrypted = encrypt_secret("fallback-secret")
    assert fallback_encrypted is not None
    assert decrypt_secret(fallback_encrypted) == "fallback-secret"

    _set_settings(
        monkeypatch,
        app_env="production",
        secret_encryption_keys=[],
    )
    with pytest.raises(RuntimeError):
        require_secret_encryption_keys()


def test_backup_service_creates_and_browses_snapshots() -> None:
    service = BackupService()

    assert service.list_snapshots() == {"snapshots": []}

    created = service.create_snapshot(" incremental ")
    assert created["mode"] == "incremental"

    listing = service.list_snapshots()
    assert len(listing["snapshots"]) == 1
    snapshot_id = str(listing["snapshots"][0]["id"])

    root = service.tree(snapshot_id=snapshot_id, path="")
    assert root["path"] == "/"
    assert {child["name"] for child in root["children"]} == {"manifest.json", "spaces"}

    nested = service.tree(snapshot_id=snapshot_id, path="spaces/demo")
    assert {child["name"] for child in nested["children"]} == {
        "incidents",
        "kb",
        "sops",
    }

    file_node = service.node(snapshot_id=snapshot_id, path="/manifest.json")
    assert file_node["type"] == "file"
    assert snapshot_id in file_node["content"]

    folder_node = service.node(snapshot_id=snapshot_id, path="spaces/demo/kb")
    assert folder_node == {"path": "/spaces/demo/kb", "type": "folder"}

    assert service.tree(snapshot_id="missing", path="/") == {
        "snapshot_id": "missing",
        "path": "/",
        "children": [],
    }
    assert service.node(snapshot_id="missing", path="/") == {
        "error": "snapshot_not_found"
    }
    assert service.node(snapshot_id=snapshot_id, path="/missing.json") == {
        "error": "node_not_found"
    }


def test_run_maintenance_cycle_invokes_all_services(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[tuple[str, object]] = []

    class DummySession:
        def __enter__(self) -> object:
            return self

        def __exit__(self, exc_type, exc, tb) -> bool:
            return False

    monkeypatch.setattr(background, "SessionLocal", lambda: DummySession())
    monkeypatch.setattr(
        background.kb_service,
        "run_all_due_purge_jobs",
        lambda db: calls.append(("kb_purge", db)),
    )
    monkeypatch.setattr(
        background.kb_service,
        "run_all_due_relevance_benchmark_jobs",
        lambda db: calls.append(("kb_bench", db)),
    )
    monkeypatch.setattr(
        background.tasks_service,
        "process_due_sop_execution_reminders",
        lambda db: calls.append(("task_reminders", db)),
    )
    monkeypatch.setattr(
        background.incidents_service,
        "process_overdue_action_item_reminders",
        lambda db: calls.append(("incident_reminders", db)),
    )
    monkeypatch.setattr(
        background.media_service,
        "cleanup_expired_assets",
        lambda db: calls.append(("media_cleanup", db)),
    )
    monkeypatch.setattr(
        background.localization_service,
        "process_due_translation_jobs",
        lambda db: calls.append(("localization_jobs", db)),
    )

    background._run_maintenance_cycle()

    assert [name for name, _ in calls] == [
        "kb_purge",
        "kb_bench",
        "task_reminders",
        "incident_reminders",
        "media_cleanup",
        "localization_jobs",
    ]


@pytest.mark.asyncio
async def test_background_wait_loop_and_stop_behaviors(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    stop_event = asyncio.Event()
    assert await background._wait_or_stop(stop_event, 0.01) is False
    stop_event.set()
    assert await background._wait_or_stop(stop_event, 0.01) is True

    cycle_runs: list[str] = []
    wait_calls: list[int] = []

    async def fake_wait_or_stop(event: asyncio.Event, timeout_seconds: int) -> bool:
        wait_calls.append(timeout_seconds)
        if len(wait_calls) == 1:
            return False
        event.set()
        return True

    async def fake_to_thread(fn):
        fn()

    monkeypatch.setattr(background, "_wait_or_stop", fake_wait_or_stop)
    monkeypatch.setattr(background.asyncio, "to_thread", fake_to_thread)
    monkeypatch.setattr(background, "_run_maintenance_cycle", lambda: cycle_runs.append("ok"))
    monkeypatch.setattr(settings, "maintenance_interval_seconds", 45)

    await background.maintenance_loop(asyncio.Event())

    assert wait_calls == [10, 45]
    assert cycle_runs == ["ok"]

    async def fake_wait_with_exception(event: asyncio.Event, timeout_seconds: int) -> bool:
        wait_calls.append(timeout_seconds)
        if len(wait_calls) == 3:
            return False
        event.set()
        return True

    monkeypatch.setattr(background, "_wait_or_stop", fake_wait_with_exception)
    monkeypatch.setattr(
        background,
        "_run_maintenance_cycle",
        lambda: (_ for _ in ()).throw(RuntimeError("boom")),
    )

    await background.maintenance_loop(asyncio.Event())

    pending_stop = asyncio.Event()
    task = asyncio.create_task(asyncio.sleep(30))
    await background.stop_maintenance_loop(task, pending_stop)
    assert pending_stop.is_set() is True
    assert task.done() is True

    await background.stop_maintenance_loop(None, None)
