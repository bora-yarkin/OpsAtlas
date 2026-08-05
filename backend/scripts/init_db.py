#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only
# ruff: noqa: E402

from __future__ import annotations

from pathlib import Path
import sys


BACKEND_ROOT = Path(__file__).resolve().parents[1]
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))

from app.core.db import SessionLocal, init_db
from app.modules.admin import service as admin_service
from app.modules.localization import service as localization_service


def main() -> None:
    init_db()
    with SessionLocal() as db:
        admin_service.sync_organization_items(db)
        rebuilt_codes = localization_service.reinstall_builtin_bundles(db)

    print("Database schema initialized and additive schema sync applied.")
    if rebuilt_codes:
        print("Built-in localization bundles refreshed: " + ", ".join(rebuilt_codes))
    else:
        print("Built-in localization bundles refreshed: none")


if __name__ == "__main__":
    main()