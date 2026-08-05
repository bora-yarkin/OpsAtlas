# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

from sqlalchemy.orm import Session

from app.core.db import SessionLocal
from app.modules.localization import service as localization_service
from app.modules.localization.models import LocalizationBundle, LocalizationLanguage


def reset_builtin_bundles(db: Session) -> list[tuple[str, int, int]]:
    builtin_bundles = localization_service.discover_builtin_bundles()
    if not builtin_bundles:
        raise RuntimeError("No built-in localization bundles were discovered")

    localization_service.ensure_seed(db)
    updated: list[tuple[str, int, int]] = []
    for code, entries in sorted(builtin_bundles.items()):
        language = db.get(LocalizationLanguage, code)
        if language is None:
            continue

        bundle = db.get(LocalizationBundle, code)
        if bundle is None:
            bundle = LocalizationBundle(language_code=code, entries_json="{}")
            db.add(bundle)

        bundle.entries_json = localization_service._json_dump(entries)
        language.bundle_version = int(language.bundle_version or 1) + 1
        updated.append((code, len(entries), int(language.bundle_version)))

    db.commit()
    return updated


def main() -> None:
    with SessionLocal() as db:
        updated = reset_builtin_bundles(db)

    print("Built-in localization bundles refreshed.")
    for code, entry_count, bundle_version in updated:
        print(f"  {code}: {entry_count} entries (version {bundle_version})")
    print("Content translation variants and user language preferences were preserved.")


if __name__ == "__main__":
    main()
