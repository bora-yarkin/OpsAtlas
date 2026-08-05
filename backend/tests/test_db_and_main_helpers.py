# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

from datetime import date, datetime, time

import pytest
from sqlalchemy import Boolean, Column, Integer, String, Table, text
from sqlalchemy.orm import DeclarativeBase, mapped_column

from app.core import db as db_core
from app.core.config import settings
from app import main as app_main


class _ScratchBase(DeclarativeBase):
    pass


def _set_settings(monkeypatch: pytest.MonkeyPatch, **overrides: object) -> None:
    for key, value in overrides.items():
        monkeypatch.setattr(settings, key, value)


def test_literal_sql_handles_scalars_dates_and_quotes() -> None:
    assert db_core._literal_sql(None) == "NULL"
    assert db_core._literal_sql(True) == "TRUE"
    assert db_core._literal_sql(False) == "FALSE"
    assert db_core._literal_sql(7) == "7"
    assert db_core._literal_sql(3.5) == "3.5"
    assert db_core._literal_sql(date(2026, 6, 19)) == "'2026-06-19'"
    assert db_core._literal_sql(time(12, 34, 56)) == "'12:34:56'"
    assert db_core._literal_sql(datetime(2026, 6, 19, 12, 34, 56)) == "'2026-06-19T12:34:56'"
    assert db_core._literal_sql("O'Hare") == "'O''Hare'"


def test_quoted_table_name_supports_schema() -> None:
    assert db_core._quoted_table_name("users") == "users"
    assert db_core._quoted_table_name("audit-log", schema="ops") == "ops.\"audit-log\""


def test_compile_and_column_defaults_cover_scalar_and_clause_defaults() -> None:
    scalar_table = Table(
        "scalar_defaults",
        _ScratchBase.metadata,
        Column("flag", Boolean, default=True, nullable=False),
        Column("name", String(20), default="ops", nullable=False),
    )
    clause_table = Table(
        "clause_defaults",
        _ScratchBase.metadata,
        Column("created_at", String(40), server_default=text("'now'"), nullable=False),
    )

    assert db_core._column_default_sql(scalar_table.c.flag) == "TRUE"
    assert db_core._column_default_sql(scalar_table.c.name) == "'ops'"
    assert db_core._column_default_sql(clause_table.c.created_at) == "'now'"
    assert db_core._compile_sql_expression(text("'value'")) == "'value'"

    class Uncompilable:
        def compile(self, *args, **kwargs):  # type: ignore[no-untyped-def]
            raise RuntimeError("boom")

    assert db_core._compile_sql_expression(Uncompilable()) is None


def test_column_definition_sql_skips_primary_and_computed_columns() -> None:
    class Row(_ScratchBase):
        __tablename__ = "helper_rows"

        id = mapped_column(Integer, primary_key=True)
        title = mapped_column(String(40), default="draft", nullable=False)

    title_column = Row.__table__.c.title
    id_column = Row.__table__.c.id

    assert db_core._column_definition_sql(id_column) is None
    definition = db_core._column_definition_sql(title_column)
    assert definition is not None
    assert "title" in definition
    assert "VARCHAR(40)" in definition
    assert "DEFAULT 'draft'" in definition
    assert "NOT NULL" in definition


def test_import_model_modules_returns_sorted_tuple_and_handles_missing_paths(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path,
) -> None:
    class FakePackage:
        __path__ = [str(tmp_path)]

    imported: list[str] = []
    (tmp_path / "auth").mkdir()
    (tmp_path / "auth" / "models.py").write_text("", encoding="utf-8")
    (tmp_path / "spaces").mkdir()
    (tmp_path / "_internal").mkdir()
    (tmp_path / "README.md").write_text("", encoding="utf-8")

    monkeypatch.setattr(
        db_core,
        "import_module",
        lambda name: FakePackage() if name == "app.modules" else imported.append(name) or object(),
    )

    modules = db_core._import_model_modules()
    assert modules == ("app.modules.auth.models",)
    assert imported == ["app.modules.auth.models"]

    class EmptyPackage:
        __path__ = None

    monkeypatch.setattr(db_core, "import_module", lambda name: EmptyPackage())
    assert db_core._import_model_modules() == ()


def test_main_host_and_trusted_host_helpers_handle_edge_cases(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert app_main._normalize_host_token(" https://Example.com:8443/path ") == "example.com"
    assert app_main._normalize_host_token("[::1]:8000") == "::1"
    assert app_main._normalize_host_token("localhost:3000") == "localhost"
    assert app_main._is_local_host_token("https://foo.localhost") is True
    assert app_main._is_local_host_token("https://opsatlas.example.com") is False
    assert app_main._dedupe_host_tokens(["example.com", "example.com", "", "api.example.com"]) == [
        "example.com",
        "api.example.com",
    ]

    _set_settings(
        monkeypatch,
        app_env="production",
        public_api_base_url="https://api.opsatlas.example.com/v1",
    )
    assert app_main._resolve_public_api_trusted_hosts() == ["api.opsatlas.example.com"]
    assert app_main._resolve_public_web_cors_origins() == []

    _set_settings(
        monkeypatch,
        app_env="dev",
        public_api_base_url="https://api.opsatlas.example.com/v1",
    )
    assert app_main._resolve_public_api_trusted_hosts() == []
    assert app_main._resolve_public_web_cors_origins() == []

    _set_settings(
        monkeypatch,
        app_env="production",
        public_web_origin="https://opsatlas.example.com",
    )
    assert app_main._resolve_public_web_cors_origins() == [
        "https://opsatlas.example.com"
    ]


def test_main_runtime_security_configuration_enforces_safe_combinations(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _set_settings(
        monkeypatch,
        app_env="production",
        auto_create_tables=False,
        cors_origins=["https://opsatlas.example.com"],
        trusted_hosts=["opsatlas.example.com"],
        password_enforce_in_dev=True,
        mfa_enabled=True,
        mfa_enforce_in_dev=True,
    )
    monkeypatch.setattr(app_main, "require_secret_encryption_keys", lambda: None)
    app_main._validate_runtime_security_configuration()

    _set_settings(monkeypatch, auto_create_tables=True)
    with pytest.raises(RuntimeError) as prod_tables_exc:
        app_main._validate_runtime_security_configuration()
    assert "AUTO_CREATE_TABLES" in str(prod_tables_exc.value)

    _set_settings(
        monkeypatch,
        app_env="dev",
        auto_create_tables=True,
        cors_origins=[],
        trusted_hosts=["localhost"],
        password_enforce_in_dev=False,
        mfa_enabled=True,
        mfa_enforce_in_dev=False,
    )
    with pytest.raises(RuntimeError) as missing_origins_exc:
        app_main._validate_runtime_security_configuration()
    assert "CORS_ORIGINS" in str(missing_origins_exc.value)

    _set_settings(monkeypatch, cors_origins=["https://opsatlas.example.com"])
    with pytest.raises(RuntimeError) as unsafe_origins_exc:
        app_main._validate_runtime_security_configuration()
    assert "localhost-only" in str(unsafe_origins_exc.value)

    _set_settings(
        monkeypatch,
        cors_origins=["http://localhost:3000"],
        trusted_hosts=["localhost", "127.0.0.1"],
        password_enforce_in_dev=False,
        mfa_enabled=True,
        mfa_enforce_in_dev=False,
    )
    app_main._validate_runtime_security_configuration()


def test_main_cors_trusted_hosts_and_csp_resolution(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _set_settings(
        monkeypatch,
        app_env="production",
        cors_origins=["https://opsatlas.example.com"],
        trusted_hosts=["opsatlas.example.com", "opsatlas.example.com"],
        public_api_base_url="https://api.opsatlas.example.com",
        public_web_origin="https://opsatlas.example.com",
        hsts_max_age_seconds=31536000,
    )
    assert app_main._resolve_cors_origins() == ["https://opsatlas.example.com"]
    assert app_main._resolve_trusted_hosts() == [
        "opsatlas.example.com",
        "api.opsatlas.example.com",
    ]
    assert "upgrade-insecure-requests" in app_main._security_csp_value()

    _set_settings(monkeypatch, cors_origins=["*"])
    with pytest.raises(RuntimeError) as wildcard_exc:
        app_main._resolve_cors_origins()
    assert "Unsafe CORS configuration" in str(wildcard_exc.value)

    _set_settings(
        monkeypatch,
        app_env="production",
        cors_origins=[],
        trusted_hosts=["api.opsatlas.example.com"],
        public_api_base_url="https://api.opsatlas.example.com",
        public_web_origin="https://opsatlas.example.com",
    )
    assert app_main._resolve_cors_origins() == ["https://opsatlas.example.com"]

    _set_settings(
        monkeypatch,
        app_env="dev",
        cors_origins=[],
        trusted_hosts=[],
        public_api_base_url="",
    )
    assert app_main._resolve_cors_origins() == ["*"]
    assert app_main._resolve_trusted_hosts() == [
        "localhost",
        "127.0.0.1",
        "[::1]",
        "*.localhost",
    ]
    assert "unsafe-eval" in app_main._security_csp_value()
