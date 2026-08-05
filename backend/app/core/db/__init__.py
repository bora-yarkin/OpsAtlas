# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Database engine, session factory, and declarative base configuration."""

from datetime import date, datetime, time
from importlib import import_module
from pathlib import Path
from typing import Any

from sqlalchemy import create_engine, inspect
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from app.core.config import settings


class Base(DeclarativeBase):
    pass


engine_kwargs: dict[str, Any] = {
    "echo": settings.db_echo,
    "pool_pre_ping": True,
}
if settings.database_url.startswith("sqlite"):
    engine_kwargs["connect_args"] = {"check_same_thread": False}

engine = create_engine(settings.database_url, **engine_kwargs)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, class_=Session)

_MODULES_PACKAGE = "app.modules"


def init_db() -> None:
    # Import every `models.py` under `app.modules.*` so SQLAlchemy metadata stays
    # in sync as modules are added and we do not have to maintain a hardcoded list.
    _import_model_modules()
    Base.metadata.create_all(bind=engine)
    _apply_additive_schema_sync()


def _import_model_modules() -> tuple[str, ...]:
    package = import_module(_MODULES_PACKAGE)
    package_paths = getattr(package, "__path__", None)
    if not package_paths:
        return ()

    imported: set[str] = set()
    normalized_roots = {
        candidate.resolve()
        for raw_path in package_paths
        if (candidate := Path(str(raw_path))).is_dir()
    }
    for root in sorted(normalized_roots):
        for child in sorted(root.iterdir()):
            if not child.is_dir() or child.name.startswith("_"):
                continue
            if not (child / "models.py").is_file():
                continue
            model_module = f"{_MODULES_PACKAGE}.{child.name}.models"
            import_module(model_module)
            imported.add(model_module)
    return tuple(sorted(imported))


def _apply_additive_schema_sync() -> None:
    inspector = inspect(engine)
    _ensure_missing_columns(inspector)
    _ensure_missing_indexes(inspector)


def _ensure_missing_columns(inspector: Any) -> None:
    for table in Base.metadata.sorted_tables:
        if not inspector.has_table(table.name, schema=table.schema):
            continue

        existing = {
            column["name"]
            for column in inspector.get_columns(table.name, schema=table.schema)
        }
        missing = [column for column in table.columns if column.name not in existing]
        if not missing:
            continue

        table_sql = _quoted_table_name(table.name, schema=table.schema)
        for column in missing:
            ddl = _column_definition_sql(column)
            if ddl is None:
                continue
            with engine.begin() as conn:
                conn.exec_driver_sql(f"ALTER TABLE {table_sql} ADD COLUMN {ddl}")


def _ensure_missing_indexes(inspector: Any) -> None:
    for table in Base.metadata.sorted_tables:
        if not inspector.has_table(table.name, schema=table.schema):
            continue
        existing_indexes = {
            index_info["name"]
            for index_info in inspector.get_indexes(table.name, schema=table.schema)
            if index_info.get("name")
        }
        existing_indexes.update(
            constraint_info["name"]
            for constraint_info in inspector.get_unique_constraints(table.name, schema=table.schema)
            if constraint_info.get("name")
        )
        for index in table.indexes:
            if index.name in existing_indexes:
                continue
            index.create(bind=engine, checkfirst=False)
            if index.name is not None:
                existing_indexes.add(index.name)


def _column_definition_sql(column: Any) -> str | None:
    if column.primary_key or getattr(column, "computed", None) is not None:
        return None

    preparer = engine.dialect.identifier_preparer
    parts = [
        preparer.quote(column.name),
        column.type.compile(dialect=engine.dialect),
    ]

    default_sql = _column_default_sql(column)
    if default_sql is not None:
        parts.append(f"DEFAULT {default_sql}")

    # For legacy local databases we prefer a successful additive upgrade over
    # failing startup because an old table has rows and a new non-null column
    # lacks a safe default. If there is no usable default, add the column as
    # nullable and let application writes backfill it.
    if not column.nullable and default_sql is not None:
        parts.append("NOT NULL")

    return " ".join(parts)


def _column_default_sql(column: Any) -> str | None:
    server_default = getattr(column, "server_default", None)
    if server_default is not None and getattr(server_default, "arg", None) is not None:
        compiled = _compile_sql_expression(server_default.arg)
        if compiled is not None:
            return compiled

    default = getattr(column, "default", None)
    if default is None:
        return None
    if getattr(default, "is_scalar", False):
        return _literal_sql(default.arg)
    if getattr(default, "is_clause_element", False):
        compiled = _compile_sql_expression(default.arg)
        if compiled is not None:
            return compiled
    return None


def _compile_sql_expression(expression: Any) -> str | None:
    try:
        return str(
            expression.compile(
                dialect=engine.dialect,
                compile_kwargs={"literal_binds": True},
            )
        )
    except Exception:
        return None


def _literal_sql(value: Any) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, (date, datetime, time)):
        return f"'{value.isoformat()}'"
    return "'" + str(value).replace("'", "''") + "'"


def _quoted_table_name(name: str, *, schema: str | None = None) -> str:
    preparer = engine.dialect.identifier_preparer
    base = preparer.quote(name)
    if not schema:
        return base
    return f"{preparer.quote_schema(schema)}.{base}"
