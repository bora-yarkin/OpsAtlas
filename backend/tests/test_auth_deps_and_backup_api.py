# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from fastapi import HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app.core.auth.security import create_access_token
from app.core.config import settings
from app.core.secret_crypto import encrypt_secret
from app.modules.auth import deps as auth_deps
from app.modules.auth.models import UserSecurityState, UserSession
from app.modules.backup.service import backup_service


def _request_with_cookie(cookie_header: str = "") -> Request:
    headers = []
    if cookie_header:
        headers.append((b"cookie", cookie_header.encode("utf-8")))
    return Request(
        {
            "type": "http",
            "method": "GET",
            "path": "/",
            "scheme": "http",
            "query_string": b"",
            "headers": headers,
            "client": ("127.0.0.1", 12345),
            "server": ("testserver", 80),
        }
    )


def test_get_current_user_rejects_missing_invalid_and_deactivated_tokens(
    db_session: Session,
    user_factory,
) -> None:
    user = user_factory(
        email="authdeps@example.com",
        name="Deps User",
        password="AuthDeps1!",
        role="member",
    )
    deactivated = user_factory(
        email="inactive@example.com",
        name="Inactive User",
        password="Inactive1!",
        role="member",
    )
    deactivated.is_active = False
    db_session.commit()

    with pytest.raises(HTTPException) as missing_exc:
        auth_deps.get_current_user(request=_request_with_cookie(), creds=None, db=db_session)
    assert missing_exc.value.status_code == 401

    invalid_creds = HTTPAuthorizationCredentials(
        scheme="Bearer",
        credentials="not-a-jwt",
    )
    with pytest.raises(HTTPException) as invalid_exc:
        auth_deps.get_current_user(
            request=_request_with_cookie(),
            creds=invalid_creds,
            db=db_session,
        )
    assert invalid_exc.value.status_code == 401

    inactive_token = create_access_token(
        sub=deactivated.id,
        role=deactivated.global_role,
        mfa_verified=False,
    )
    with pytest.raises(HTTPException) as inactive_exc:
        auth_deps.get_current_user(
            request=_request_with_cookie(),
            creds=HTTPAuthorizationCredentials(
                scheme="Bearer",
                credentials=inactive_token,
            ),
            db=db_session,
        )
    assert inactive_exc.value.status_code == 401
    assert "deactivated" in str(inactive_exc.value.detail)

    cookie_token = encrypt_secret(
        create_access_token(
            sub=user.id,
            role=user.global_role,
            mfa_verified=True,
        )
    )
    assert cookie_token is not None
    hydrated = auth_deps.get_current_user(
        request=_request_with_cookie(f"{settings.auth_cookie_access_name}={cookie_token}"),
        creds=None,
        db=db_session,
    )
    assert hydrated.id == user.id
    assert getattr(hydrated, "_auth_mfa_verified", False) is True
    assert getattr(hydrated, "_auth_session_id", None) is None


def test_get_current_user_enforces_session_invalidation_and_session_rows(
    db_session: Session,
    user_factory,
) -> None:
    user = user_factory(
        email="sessiondeps@example.com",
        name="Session Deps",
        password="Session1!",
        role="admin",
    )

    invalidated_token = create_access_token(
        sub=user.id,
        role=user.global_role,
        mfa_verified=True,
    )
    db_session.add(
        UserSecurityState(
            user_id=user.id,
            session_invalid_before=datetime.now(timezone.utc) + timedelta(seconds=60),
        )
    )
    db_session.commit()

    with pytest.raises(HTTPException) as invalidated_exc:
        auth_deps.get_current_user(
            request=_request_with_cookie(),
            creds=HTTPAuthorizationCredentials(
                scheme="Bearer",
                credentials=invalidated_token,
            ),
            db=db_session,
        )
    assert invalidated_exc.value.status_code == 401
    assert "expired" in str(invalidated_exc.value.detail)

    state = db_session.get(UserSecurityState, user.id)
    assert state is not None
    state.session_invalid_before = None
    session_row = UserSession(
        id="session-deps-1",
        user_id=user.id,
        refresh_token_hash="refresh-hash",
        refresh_expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        revoked_at=None,
        revoke_reason=None,
        ip_address="127.0.0.1",
        user_agent="pytest",
        mfa_verified_at=datetime.now(timezone.utc),
    )
    db_session.add(session_row)
    db_session.commit()

    session_token = create_access_token(
        sub=user.id,
        role=user.global_role,
        mfa_verified=True,
        session_id=session_row.id,
    )
    hydrated = auth_deps.get_current_user(
        request=_request_with_cookie(),
        creds=HTTPAuthorizationCredentials(
            scheme="Bearer",
            credentials=session_token,
        ),
        db=db_session,
    )
    assert hydrated.id == user.id
    assert getattr(hydrated, "_auth_session_id", None) == session_row.id

    session_row.revoked_at = datetime.now(timezone.utc)
    db_session.commit()
    with pytest.raises(HTTPException) as revoked_exc:
        auth_deps.get_current_user(
            request=_request_with_cookie(),
            creds=HTTPAuthorizationCredentials(
                scheme="Bearer",
                credentials=session_token,
            ),
            db=db_session,
        )
    assert revoked_exc.value.status_code == 401

    session_row.revoked_at = None
    session_row.refresh_expires_at = datetime.now(timezone.utc) - timedelta(minutes=5)
    db_session.commit()
    with pytest.raises(HTTPException) as expired_exc:
        auth_deps.get_current_user(
            request=_request_with_cookie(),
            creds=HTTPAuthorizationCredentials(
                scheme="Bearer",
                credentials=session_token,
            ),
            db=db_session,
        )
    assert expired_exc.value.status_code == 401


def test_require_mfa_for_sensitive_action_respects_role_and_verification(
    monkeypatch: pytest.MonkeyPatch,
    db_session: Session,
    user_factory,
) -> None:
    admin = user_factory(
        email="mfa-admin@example.com",
        name="MFA Admin",
        password="AdminMfa1!",
        role="admin",
    )
    member = user_factory(
        email="mfa-member@example.com",
        name="MFA Member",
        password="MemberMfa1!",
        role="member",
    )

    monkeypatch.setattr(settings, "mfa_enabled", True)
    monkeypatch.setattr(settings, "app_env", "production")
    monkeypatch.setattr(settings, "mfa_enforce_in_dev", True)

    hydrated_admin = auth_deps.hydrate_user_auth_context(db_session, admin)
    setattr(hydrated_admin, "_auth_mfa_verified", False)
    with pytest.raises(HTTPException) as enrollment_exc:
        auth_deps.require_mfa_for_sensitive_action(
            user=hydrated_admin,
            db=db_session,
        )
    assert enrollment_exc.value.status_code == 403
    assert "enrollment" in str(enrollment_exc.value.detail)

    db_session.add(
        UserSecurityState(
            user_id=admin.id,
            mfa_enabled=True,
            mfa_secret="BASE32SECRET",
        )
    )
    db_session.commit()

    with pytest.raises(HTTPException) as verification_exc:
        auth_deps.require_mfa_for_sensitive_action(
            user=hydrated_admin,
            db=db_session,
        )
    assert verification_exc.value.status_code == 403
    assert "verification" in str(verification_exc.value.detail)

    setattr(hydrated_admin, "_auth_mfa_verified", True)
    assert (
        auth_deps.require_mfa_for_sensitive_action(user=hydrated_admin, db=db_session).id
        == admin.id
    )

    hydrated_member = auth_deps.hydrate_user_auth_context(db_session, member)
    setattr(hydrated_member, "_auth_mfa_verified", False)
    assert (
        auth_deps.require_mfa_for_sensitive_action(user=hydrated_member, db=db_session).id
        == member.id
    )

    monkeypatch.setattr(settings, "mfa_enabled", False)
    assert (
        auth_deps.require_mfa_for_sensitive_action(user=hydrated_admin, db=db_session).id
        == admin.id
    )


def test_backup_endpoints_enforce_role_and_mfa(
    monkeypatch: pytest.MonkeyPatch,
    client: TestClient,
    db_session: Session,
    user_factory,
    auth_headers_factory,
) -> None:
    backup_service._snapshots.clear()
    monkeypatch.setattr(settings, "mfa_enabled", True)
    monkeypatch.setattr(settings, "mfa_enforce_in_dev", True)
    monkeypatch.setattr(settings, "app_env", "production")

    admin = user_factory(
        email="backup-admin@example.com",
        name="Backup Admin",
        password="VaultRoot1!",
        role="admin",
    )
    moderator = user_factory(
        email="backup-mod@example.com",
        name="Backup Moderator",
        password="ShieldOps1!",
        role="moderator",
    )
    member = user_factory(
        email="backup-member@example.com",
        name="Backup Member",
        password="OrbitUser1!",
        role="member",
    )

    unauthorized_create = client.post(
        "/admin/backups/snapshots",
        headers=auth_headers_factory(admin, mfa_verified=False),
    )
    assert unauthorized_create.status_code == 403

    db_session.add(
        UserSecurityState(
            user_id=admin.id,
            mfa_enabled=True,
            mfa_secret="BASE32SECRET",
        )
    )
    db_session.commit()

    still_unverified = client.post(
        "/admin/backups/snapshots",
        headers=auth_headers_factory(admin, mfa_verified=False),
    )
    assert still_unverified.status_code == 403

    moderator_create = client.post(
        "/admin/backups/snapshots",
        headers=auth_headers_factory(moderator, mfa_verified=True),
    )
    assert moderator_create.status_code == 403

    member_list = client.get(
        "/admin/backups/snapshots",
        headers=auth_headers_factory(member, mfa_verified=True),
    )
    assert member_list.status_code == 403

    created = client.post(
        "/admin/backups/snapshots",
        headers=auth_headers_factory(admin, mfa_verified=True),
        params={"mode": "full"},
    )
    assert created.status_code == 200
    snapshot_id = created.json()["id"]

    listed = client.get(
        "/admin/backups/snapshots",
        headers=auth_headers_factory(moderator, mfa_verified=True),
    )
    assert listed.status_code == 200
    assert listed.json()["snapshots"][0]["id"] == snapshot_id

    tree_response = client.get(
        f"/admin/backups/snapshots/{snapshot_id}/tree",
        params={"path": "/spaces/demo"},
        headers=auth_headers_factory(moderator, mfa_verified=True),
    )
    assert tree_response.status_code == 200
    assert {child["name"] for child in tree_response.json()["children"]} == {
        "incidents",
        "kb",
        "sops",
    }

    node_response = client.get(
        f"/admin/backups/snapshots/{snapshot_id}/node",
        params={"path": "/manifest.json"},
        headers=auth_headers_factory(moderator, mfa_verified=True),
    )
    assert node_response.status_code == 200
    assert node_response.json()["type"] == "file"
    assert snapshot_id in node_response.json()["content"]
