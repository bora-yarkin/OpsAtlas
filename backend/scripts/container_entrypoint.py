from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys


def _load_runtime_env_file() -> None:
    env_file = (os.environ.get("OPSATLAS_RUNTIME_ENV_FILE") or "").strip()
    if not env_file:
        return
    path = Path(env_file)
    if not path.exists():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        normalized_key = key.strip()
        if not normalized_key:
            continue
        normalized_value = value.strip()
        if len(normalized_value) >= 2 and normalized_value[0] == normalized_value[-1] and normalized_value[0] in {"'", '"'}:
            normalized_value = normalized_value[1:-1]
        os.environ[normalized_key] = normalized_value


def _ensure_database_url() -> None:
    if (os.environ.get("DATABASE_URL") or "").strip():
        return
    db_name = (os.environ.get("OPSATLAS_DB_NAME") or "opsatlas").strip() or "opsatlas"
    db_user = (os.environ.get("OPSATLAS_DB_USER") or "opsatlas").strip() or "opsatlas"
    db_password = (os.environ.get("OPSATLAS_DB_PASSWORD") or "").strip()
    if not db_password:
        return
    os.environ["DATABASE_URL"] = (
        f"postgresql+psycopg://{db_user}:{db_password}@db:5432/{db_name}"
    )


def _run(*args: str) -> None:
    subprocess.run([sys.executable, *args], check=True)


def _exec_python(*args: str) -> None:
    os.execv(sys.executable, [sys.executable, *args])


def main(argv: list[str] | None = None) -> None:
    _load_runtime_env_file()
    _ensure_database_url()
    args = list(argv or sys.argv[1:])
    if not args:
        args = ["api"]

    command, *rest = args
    if command == "api":
        _run("scripts/wait_for_db.py")
        _run("scripts/init_db.py")
        _exec_python(
            "-m",
            "uvicorn",
            "app.main:app",
            "--host",
            "0.0.0.0",
            "--port",
            os.environ.get("API_PORT", "8000"),
            *rest,
        )
        return
    if command == "initdb":
        _run("scripts/wait_for_db.py")
        _exec_python("scripts/init_db.py", *rest)
        return
    if command == "seeddb":
        _run("scripts/wait_for_db.py")
        seed_args = list(rest)
        if "--reset" not in seed_args and "--erase" not in seed_args:
            seed_args.insert(0, "--reset")
        _exec_python("scripts/seed_db.py", *seed_args)
        return
    if command == "reset-localization":
        _run("scripts/wait_for_db.py")
        _exec_python("scripts/reset_localization_bundles.py", *rest)
        return

    os.execvp(command, [command, *rest])


if __name__ == "__main__":
    main()
