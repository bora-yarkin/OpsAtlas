# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import importlib.util
from pathlib import Path

from scripts import container_entrypoint


_BOOTSTRAP_ENV_PATH = (
    Path(__file__).resolve().parents[2] / "docker" / "release" / "bootstrap_env.py"
)
_BOOTSTRAP_ENV_SPEC = importlib.util.spec_from_file_location(
    "opsatlas_release_bootstrap_env",
    _BOOTSTRAP_ENV_PATH,
)
assert _BOOTSTRAP_ENV_SPEC is not None
assert _BOOTSTRAP_ENV_SPEC.loader is not None
release_bootstrap_env = importlib.util.module_from_spec(_BOOTSTRAP_ENV_SPEC)
_BOOTSTRAP_ENV_SPEC.loader.exec_module(release_bootstrap_env)


def test_load_runtime_env_file_reads_values_and_overrides_existing_env(
    monkeypatch,
    tmp_path: Path,
) -> None:
    env_file = tmp_path / "generated.env"
    env_file.write_text(
        "\n".join(
            [
                "# generated values",
                "DATABASE_URL=postgresql+psycopg://opsatlas:secret@db:5432/opsatlas",
                'JWT_SECRET="runtime-secret"',
                "SECRET_ENCRYPTION_KEYS=abc123",
                "EMPTY_VALUE=",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    monkeypatch.setenv("OPSATLAS_RUNTIME_ENV_FILE", str(env_file))
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.setenv("JWT_SECRET", "existing-jwt-secret")
    monkeypatch.delenv("SECRET_ENCRYPTION_KEYS", raising=False)
    monkeypatch.delenv("EMPTY_VALUE", raising=False)

    container_entrypoint._load_runtime_env_file()

    assert (
        container_entrypoint.os.environ["DATABASE_URL"]
        == "postgresql+psycopg://opsatlas:secret@db:5432/opsatlas"
    )
    assert container_entrypoint.os.environ["JWT_SECRET"] == "runtime-secret"
    assert container_entrypoint.os.environ["SECRET_ENCRYPTION_KEYS"] == "abc123"
    assert container_entrypoint.os.environ["EMPTY_VALUE"] == ""


def test_release_bootstrap_env_path_prefers_existing_env_docker_when_env_missing(
    monkeypatch,
    tmp_path: Path,
) -> None:
    monkeypatch.delenv("OPSATLAS_ENV_FILE", raising=False)
    monkeypatch.setenv("OPSATLAS_RELEASE_ROOT", str(tmp_path))

    (tmp_path / ".env.docker").write_text("TRUSTED_HOSTS=api-dev.example.com\n")

    assert release_bootstrap_env._env_relative_path() == ".env.docker"


def test_release_bootstrap_env_path_prefers_env_when_both_exist(
    monkeypatch,
    tmp_path: Path,
) -> None:
    monkeypatch.delenv("OPSATLAS_ENV_FILE", raising=False)
    monkeypatch.setenv("OPSATLAS_RELEASE_ROOT", str(tmp_path))

    (tmp_path / ".env").write_text("TRUSTED_HOSTS=localhost\n")
    (tmp_path / ".env.docker").write_text("TRUSTED_HOSTS=api-dev.example.com\n")

    assert release_bootstrap_env._env_relative_path() == ".env"


def test_release_bootstrap_reuses_existing_generated_secrets_for_placeholders(
    tmp_path: Path,
) -> None:
    env_file = tmp_path / ".env.docker"
    env_file.write_text(
        "\n".join(
            [
                "OPSATLAS_DB_PASSWORD=change_me_postgres_password",
                "JWT_SECRET=change_me_long_random",
                "SECRET_ENCRYPTION_KEYS=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    bootstrap_dir = tmp_path / "bootstrap"
    bootstrap_dir.mkdir()
    (bootstrap_dir / "generated.env").write_text(
        "\n".join(
            [
                "OPSATLAS_DB_PASSWORD=existing-db-password",
                "JWT_SECRET=existing-jwt-secret",
                "SECRET_ENCRYPTION_KEYS=existing-secret-key",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    materialized_path, values = release_bootstrap_env._materialize_host_env(
        tmp_path,
        ".env.docker",
        bootstrap_dir,
    )

    assert values["OPSATLAS_DB_PASSWORD"] == "existing-db-password"
    assert values["JWT_SECRET"] == "existing-jwt-secret"
    assert values["SECRET_ENCRYPTION_KEYS"] == "existing-secret-key"
    assert "existing-db-password" in materialized_path.read_text(encoding="utf-8")


def test_ensure_database_url_builds_runtime_postgres_url(monkeypatch) -> None:
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.setenv("OPSATLAS_DB_NAME", "opsatlas")
    monkeypatch.setenv("OPSATLAS_DB_USER", "opsatlas")
    monkeypatch.setenv("OPSATLAS_DB_PASSWORD", "runtime-secret")

    container_entrypoint._ensure_database_url()

    assert (
        container_entrypoint.os.environ["DATABASE_URL"]
        == "postgresql+psycopg://opsatlas:runtime-secret@db:5432/opsatlas"
    )


def test_main_seeddb_defaults_to_reset(monkeypatch) -> None:
    calls: list[tuple[str, ...]] = []

    monkeypatch.setattr(container_entrypoint, "_load_runtime_env_file", lambda: None)
    monkeypatch.setattr(container_entrypoint, "_ensure_database_url", lambda: None)
    monkeypatch.setattr(
        container_entrypoint,
        "_run",
        lambda *args: calls.append(tuple(args)),
    )
    monkeypatch.setattr(
        container_entrypoint,
        "_exec_python",
        lambda *args: calls.append(tuple(args)),
    )

    container_entrypoint.main(["seeddb"])

    assert calls == [
        ("scripts/wait_for_db.py",),
        ("scripts/seed_db.py", "--reset"),
    ]


def test_main_seeddb_preserves_explicit_reset_arguments(monkeypatch) -> None:
    calls: list[tuple[str, ...]] = []

    monkeypatch.setattr(container_entrypoint, "_load_runtime_env_file", lambda: None)
    monkeypatch.setattr(container_entrypoint, "_ensure_database_url", lambda: None)
    monkeypatch.setattr(
        container_entrypoint,
        "_run",
        lambda *args: calls.append(tuple(args)),
    )
    monkeypatch.setattr(
        container_entrypoint,
        "_exec_python",
        lambda *args: calls.append(tuple(args)),
    )

    container_entrypoint.main(["seeddb", "--reset"])

    assert calls == [
        ("scripts/wait_for_db.py",),
        ("scripts/seed_db.py", "--reset"),
    ]
