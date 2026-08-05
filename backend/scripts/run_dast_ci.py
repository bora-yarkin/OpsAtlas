#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import os
import secrets
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BACKEND_ROOT = REPO_ROOT / "backend"
INSTANCE_ENV_PATH = BACKEND_ROOT / "instance" / ".env"


def _runtime_root() -> tuple[Path, bool]:
    runner_temp = (os.environ.get("RUNNER_TEMP") or "").strip()
    if runner_temp:
        root = Path(runner_temp).resolve()
        root.mkdir(parents=True, exist_ok=True)
        return root, False
    return Path(tempfile.mkdtemp(prefix="opsatlas-dast-")).resolve(), True


def _write_runtime_env(runtime_root: Path) -> str | None:
    previous = None
    if INSTANCE_ENV_PATH.exists():
        previous = INSTANCE_ENV_PATH.read_text(encoding="utf-8")

    media_root = runtime_root / "media_storage"
    quarantine_root = media_root / "quarantine"
    quarantine_root.mkdir(parents=True, exist_ok=True)

    base = (BACKEND_ROOT / ".env.example").read_text(encoding="utf-8").rstrip()
    additions = {
        "APP_ENV": "test",
        "DATABASE_URL": f"sqlite:///{(runtime_root / 'opsatlas-ci-dast.db').as_posix()}",
        "CORS_ORIGINS": "http://localhost:3000",
        "TRUSTED_HOSTS": "127.0.0.1,localhost",
        "AUTO_CREATE_TABLES": "true",
        "AUTH_COOKIE_SECURE": "false",
        "AUTH_COOKIE_SECURE_IN_DEV": "false",
        "MEDIA_STORAGE_DIR": str(media_root),
        "MEDIA_QUARANTINE_DIR": str(quarantine_root),
        "MEDIA_MALWARE_SCAN_ENABLED": "false",
        "BACKGROUND_WORKERS_ENABLED": "false",
        "JWT_SECRET": secrets.token_urlsafe(32),
        "JWT_ISSUER": "opsatlas-ci",
        "JWT_AUDIENCE": "opsatlas-clients",
    }

    INSTANCE_ENV_PATH.parent.mkdir(parents=True, exist_ok=True)
    INSTANCE_ENV_PATH.write_text(
        base + "\n" + "\n".join(f"{key}={value}" for key, value in additions.items()) + "\n",
        encoding="utf-8",
    )
    return previous


def _restore_runtime_env(previous: str | None) -> None:
    if previous is None:
        INSTANCE_ENV_PATH.unlink(missing_ok=True)
        return
    INSTANCE_ENV_PATH.write_text(previous, encoding="utf-8")


def _run(*args: str) -> None:
    subprocess.run(args, cwd=REPO_ROOT, check=True)


def _start_server() -> subprocess.Popen[str]:
    return subprocess.Popen(
        [
            sys.executable,
            "-m",
            "uvicorn",
            "app.main:app",
            "--host",
            "127.0.0.1",
            "--port",
            "8000",
            "--log-level",
            "warning",
            "--app-dir",
            "backend",
        ],
        cwd=REPO_ROOT,
        text=True,
    )


def _stop_server(process: subprocess.Popen[str] | None) -> None:
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def main() -> None:
    runtime_root, should_cleanup_root = _runtime_root()
    previous_env = _write_runtime_env(runtime_root)
    server: subprocess.Popen[str] | None = None
    try:
        _run(sys.executable, str(BACKEND_ROOT / "scripts" / "seed_db.py"))
        server = _start_server()
        _run(sys.executable, str(BACKEND_ROOT / "scripts" / "dast_smoke.py"))
    finally:
        _stop_server(server)
        _restore_runtime_env(previous_env)
        if should_cleanup_root:
            shutil.rmtree(runtime_root, ignore_errors=True)


if __name__ == "__main__":
    main()
