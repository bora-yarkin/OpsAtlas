#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only
# ruff: noqa: E402

from __future__ import annotations

import os
from pathlib import Path
import sys
import time

from sqlalchemy import text


BACKEND_ROOT = Path(__file__).resolve().parents[1]
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))

from app.core.db import engine


def _int_env(name: str, default: int) -> int:
    raw = (os.getenv(name) or "").strip()
    if not raw:
        return default
    try:
        return max(1, int(raw))
    except ValueError:
        return default


def main() -> None:
    timeout_seconds = _int_env("WAIT_FOR_DB_TIMEOUT_SECONDS", 90)
    interval_seconds = _int_env("WAIT_FOR_DB_INTERVAL_SECONDS", 2)
    deadline = time.monotonic() + timeout_seconds
    attempt = 0
    last_error: Exception | None = None

    while time.monotonic() < deadline:
        attempt += 1
        try:
            with engine.connect() as conn:
                conn.execute(text("SELECT 1"))
            print(f"Database connection ready after {attempt} attempt(s).")
            return
        except Exception as error:  # pragma: no cover - runtime retry path
            last_error = error
            print(f"Waiting for database (attempt {attempt}): {error}")
            time.sleep(interval_seconds)

    message = f"Database did not become ready within {timeout_seconds} seconds."
    if last_error is not None:
        raise RuntimeError(f"{message} Last error: {last_error}") from last_error
    raise RuntimeError(message)


if __name__ == "__main__":
    main()