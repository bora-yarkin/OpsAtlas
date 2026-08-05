# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.core.db import SessionLocal
from app.main import app
from app.modules.auth.models import (
    UserNotificationPreferenceAudit,
    UserSession,
)


def _login(
    client: TestClient,
    *,
    email: str,
    password: str,
    session_profile: str = "remember_device",
) -> dict[str, object]:
    response = client.post(
        "/auth/login",
        json={
            "email": email,
            "password": password,
            "session_profile": session_profile,
        },
    )
    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload["access_token"]
    assert payload["refresh_token"]
    assert payload["session_id"]
    return payload


def _auth_headers(access_token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {access_token}"}


def test_login_refresh_logout_and_session_lifecycle(
    client: TestClient,
    user_factory,
) -> None:
    user = user_factory(
        email="admin.authflow@example.com",
        name="Auth Flow Admin",
        password="Adm1n!FlowPass",
    )

    login_payload = _login(
        client,
        email=user.email,
        password="Adm1n!FlowPass",
    )
    headers = _auth_headers(str(login_payload["access_token"]))

    me_response = client.get("/auth/me", headers=headers)
    assert me_response.status_code == 200
    assert me_response.json() == {
        "id": user.id,
        "email": user.email,
        "name": user.name,
        "global_role": "admin",
        "is_active": True,
    }

    status_response = client.get("/auth/me/session-status", headers=headers)
    assert status_response.status_code == 200
    status_payload = status_response.json()
    assert status_payload["session_id"] == login_payload["session_id"]
    assert status_payload["session_profile"] == "remember_device"
    assert status_payload["expires_in_seconds"] > 0

    sessions_response = client.get("/auth/me/sessions", headers=headers)
    assert sessions_response.status_code == 200
    sessions_payload = sessions_response.json()
    assert len(sessions_payload) == 1
    assert sessions_payload[0]["id"] == login_payload["session_id"]
    assert sessions_payload[0]["current"] is True
    assert sessions_payload[0]["revoked_at"] is None

    refresh_response = client.post(
        "/auth/refresh",
        json={"refresh_token": login_payload["refresh_token"]},
    )
    assert refresh_response.status_code == 200
    refresh_payload = refresh_response.json()
    assert refresh_payload["session_id"] == login_payload["session_id"]
    assert refresh_payload["refresh_token"] != login_payload["refresh_token"]
    assert refresh_payload["access_token"]

    logout_response = client.post(
        "/auth/logout",
        headers=_auth_headers(str(refresh_payload["access_token"])),
    )
    assert logout_response.status_code == 200
    assert logout_response.json() == {"ok": True, "revoked": True}

    with SessionLocal() as db:
        session_row = db.get(UserSession, str(login_payload["session_id"]))
        assert session_row is not None
        assert session_row.revoked_at is not None
        assert session_row.revoke_reason == "logout"

    post_logout_refresh = client.post(
        "/auth/refresh",
        json={"refresh_token": refresh_payload["refresh_token"]},
    )
    assert post_logout_refresh.status_code == 401


def test_account_preferences_and_session_retention_flow(
    client: TestClient,
    user_factory,
) -> None:
    user = user_factory(
        email="member.preferences@example.com",
        name="Preference Member",
        password="Memb3r!PrefsPass",
        role="member",
    )

    primary_login = _login(
        client,
        email=user.email,
        password="Memb3r!PrefsPass",
        session_profile="this_browser",
    )
    primary_headers = _auth_headers(str(primary_login["access_token"]))

    with TestClient(app, base_url="http://localhost") as secondary_client:
        secondary_login = _login(
            secondary_client,
            email=user.email,
            password="Memb3r!PrefsPass",
            session_profile="remember_device",
        )

        notification_response = client.patch(
            "/auth/me/notification-preferences",
            json={
                "include_view": True,
                "include_search": True,
                "include_publish": False,
                "include_task": True,
                "digest_mode": "daily",
                "digest_hour": 7,
                "digest_minute": 30,
            },
            headers=primary_headers,
        )
        assert notification_response.status_code == 200
        assert notification_response.json() == {
            "include_view": True,
            "include_search": True,
            "include_publish": False,
            "include_task": True,
            "digest_mode": "daily",
            "digest_hour": 7,
            "digest_minute": 30,
        }

        with SessionLocal() as db:
            audits = db.execute(
                select(UserNotificationPreferenceAudit).where(
                    UserNotificationPreferenceAudit.user_id == user.id,
                )
            ).scalars().all()
            assert len(audits) == 1
            assert set(audits[0].changed_keys_csv.split(",")) == {
                "include_view",
                "include_search",
                "include_publish",
                "digest_mode",
                "digest_hour",
                "digest_minute",
            }

        dashboard_response = client.patch(
            "/auth/me/dashboard-preferences",
            json={
                "selected_space_id": " space-ops ",
                "widget_order": [
                    "My_Tasks",
                    "my_tasks",
                    "activity_feed",
                    "spaces_overview",
                ],
                "hidden_widgets": [
                    "mentions",
                    "MENTIONS",
                    "profile_actions",
                ],
            },
            headers=primary_headers,
        )
        assert dashboard_response.status_code == 200
        assert dashboard_response.json()["selected_space_id"] == "space-ops"
        assert dashboard_response.json()["widget_order"] == [
            "my_tasks",
            "activity_feed",
            "spaces_overview",
        ]
        assert dashboard_response.json()["hidden_widgets"] == [
            "mentions",
            "profile_actions",
        ]

        active_sessions_before = client.get(
            "/auth/me/sessions",
            headers=primary_headers,
        )
        assert active_sessions_before.status_code == 200
        active_payload_before = active_sessions_before.json()
        assert len(active_payload_before) == 2
        assert {session["id"] for session in active_payload_before} == {
            primary_login["session_id"],
            secondary_login["session_id"],
        }

        revoke_response = client.post(
            "/auth/me/sessions/revoke-others",
            headers=primary_headers,
        )
        assert revoke_response.status_code == 200
        assert revoke_response.json()["revoked_count"] == 1
        assert revoke_response.json()["current_session_id"] == primary_login["session_id"]

        active_sessions_after = client.get(
            "/auth/me/sessions",
            headers=primary_headers,
        )
        assert active_sessions_after.status_code == 200
        active_payload_after = active_sessions_after.json()
        assert active_payload_after == [
            {
                **active_payload_after[0],
                "id": primary_login["session_id"],
                "current": True,
                "revoked_at": None,
                "revoke_reason": None,
            }
        ]

        revoked_sessions = client.get(
            "/auth/me/sessions",
            params={"scope": "revoked"},
            headers=primary_headers,
        )
        assert revoked_sessions.status_code == 200
        revoked_payload = revoked_sessions.json()
        assert len(revoked_payload) == 1
        assert revoked_payload[0]["id"] == secondary_login["session_id"]
        assert revoked_payload[0]["current"] is False
        assert revoked_payload[0]["revoke_reason"] == "manual_revoke_others"
        assert revoked_payload[0]["revoked_at"] is not None

        revoked_refresh = secondary_client.post(
            "/auth/refresh",
            json={"refresh_token": secondary_login["refresh_token"]},
        )
        assert revoked_refresh.status_code == 401

        with SessionLocal() as db:
            session_row = db.get(UserSession, str(secondary_login["session_id"]))
            assert session_row is not None
            session_row.revoked_at = datetime.now(timezone.utc) - timedelta(days=8)
            db.commit()

        retained_sessions = client.get(
            "/auth/me/sessions",
            params={"scope": "revoked"},
            headers=primary_headers,
        )
        assert retained_sessions.status_code == 200
        assert retained_sessions.json() == []

        with SessionLocal() as db:
            assert db.get(UserSession, str(secondary_login["session_id"])) is None


def test_change_password_revokes_existing_sessions_and_allows_new_login(
    client: TestClient,
    user_factory,
) -> None:
    user = user_factory(
        email="member.password@example.com",
        name="Password Member",
        password="Curr3nt!Password",
        role="member",
    )

    primary_login = _login(
        client,
        email=user.email,
        password="Curr3nt!Password",
    )

    with TestClient(app, base_url="http://localhost") as secondary_client:
        secondary_login = _login(
            secondary_client,
            email=user.email,
            password="Curr3nt!Password",
        )

        password_change = client.post(
            "/auth/me/password",
            json={
                "current_password": "Curr3nt!Password",
                "new_password": "N3w!PasswordFlow",
            },
            headers=_auth_headers(str(primary_login["access_token"])),
        )
        assert password_change.status_code == 200
        assert password_change.json() == {"ok": True, "revoked_sessions": 2}

        old_password_login = secondary_client.post(
            "/auth/login",
            json={
                "email": user.email,
                "password": "Curr3nt!Password",
            },
        )
        assert old_password_login.status_code == 401

        old_primary_refresh = client.post(
            "/auth/refresh",
            json={"refresh_token": primary_login["refresh_token"]},
        )
        assert old_primary_refresh.status_code == 401

        old_secondary_refresh = secondary_client.post(
            "/auth/refresh",
            json={"refresh_token": secondary_login["refresh_token"]},
        )
        assert old_secondary_refresh.status_code == 401

        new_password_login = secondary_client.post(
            "/auth/login",
            json={
                "email": user.email,
                "password": "N3w!PasswordFlow",
            },
        )
        assert new_password_login.status_code == 200
        payload = new_password_login.json()
        assert payload["access_token"]
        assert payload["refresh_token"]
        assert payload["session_id"]
