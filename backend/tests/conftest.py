# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

from collections.abc import Callable, Iterator

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from tests._env_bootstrap import EXPECTED_TEST_DB_URL

# Import backend modules only after forcing the isolated pytest environment.
# `settings` and the SQLAlchemy engine are constructed at import time, so doing
# this earlier can make tests bind to the developer's real local database.
from app.core.auth.security import create_access_token
from app.core.db import Base, SessionLocal, engine, init_db
from app.main import app
from app.modules.auth import service as auth_service
from app.modules.auth.models import User

if str(engine.url) != EXPECTED_TEST_DB_URL:
    raise RuntimeError(
        "Pytest must run against backend/instance/db/test.db. "
        f"Resolved engine URL: {engine.url}"
    )


@pytest.fixture
def reset_db() -> None:
    """Recreate the SQLite schema for tests that exercise the FastAPI app."""
    init_db()
    Base.metadata.drop_all(bind=engine)
    init_db()


@pytest.fixture
def client(reset_db: None) -> Iterator[TestClient]:
    """Provide a clean FastAPI test client with cookie persistence enabled."""
    with TestClient(app, base_url="http://localhost") as test_client:
        yield test_client


@pytest.fixture
def db_session(reset_db: None) -> Iterator[Session]:
    """Yield a SQLAlchemy session bound to the freshly initialized test DB."""
    with SessionLocal() as db:
        yield db


@pytest.fixture
def user_factory(db_session: Session) -> Callable[..., User]:
    """Create durable users for integration tests with realistic password policy."""

    def _create_user(
        *,
        email: str,
        name: str = "Test User",
        password: str = "Str0ng!Passw0rd",
        role: str | None = None,
    ) -> User:
        user = auth_service.register(
            db_session,
            email=email,
            name=name,
            password=password,
        )
        if role is not None and user.global_role != role:
            user.global_role = role
            db_session.commit()
            db_session.refresh(user)
        return user

    return _create_user


@pytest.fixture
def auth_headers_factory() -> Callable[..., dict[str, str]]:
    """Build bearer-token headers for an existing user row."""

    def _headers(
        user: User,
        *,
        role: str | None = None,
        mfa_verified: bool = True,
        session_id: str | None = None,
    ) -> dict[str, str]:
        token = create_access_token(
            sub=user.id,
            role=role or user.global_role,
            mfa_verified=mfa_verified,
            session_id=session_id,
        )
        return {"Authorization": f"Bearer {token}"}

    return _headers
