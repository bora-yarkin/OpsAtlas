# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import os
import tempfile
from pathlib import Path

BACKEND_ROOT = Path(__file__).resolve().parents[1]
TEST_DB_PATH = BACKEND_ROOT / "instance" / "db" / "test.db"
EXPECTED_TEST_DB_URL = f"sqlite:///{TEST_DB_PATH.as_posix()}"


def _load_env_example_defaults() -> None:
    env_example = BACKEND_ROOT / ".env.example"
    for raw_line in env_example.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())


def _apply_test_overrides() -> None:
    tmp_root = Path(tempfile.mkdtemp(prefix="opsatlas-tests-"))
    media_root = tmp_root / "media_storage"
    quarantine_root = media_root / "quarantine"
    quarantine_root.mkdir(parents=True, exist_ok=True)

    TEST_DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    TEST_DB_PATH.touch(exist_ok=True)

    os.environ.setdefault("APP_ENV", "test")
    os.environ["DATABASE_URL"] = EXPECTED_TEST_DB_URL
    os.environ.setdefault("MEDIA_STORAGE_DIR", str(media_root))
    os.environ.setdefault("MEDIA_QUARANTINE_DIR", str(quarantine_root))
    os.environ.setdefault("BACKGROUND_WORKERS_ENABLED", "false")
    os.environ.setdefault("MEDIA_MALWARE_SCAN_ENABLED", "false")
    os.environ["JWT_SECRET"] = "opsatlas-test-secret-opsatlas-test-secret"
    os.environ["JWT_ISSUER"] = "opsatlas-tests"
    os.environ["JWT_AUDIENCE"] = "opsatlas-client"
    os.environ["ACCESS_TOKEN_MINUTES"] = "30"
    os.environ.setdefault("AUTH_COOKIE_SECURE", "false")
    os.environ.setdefault("AUTH_COOKIE_SECURE_IN_DEV", "false")


_load_env_example_defaults()
_apply_test_overrides()
