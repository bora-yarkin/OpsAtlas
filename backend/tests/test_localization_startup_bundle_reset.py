# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

from app.core.db import Base, SessionLocal, engine, init_db
from app.main import app
from app.modules.localization import service as localization_service
from app.modules.localization.models import LocalizationBundle, LocalizationLanguage


@pytest.fixture(autouse=True)
def reset_db() -> None:
    init_db()
    Base.metadata.drop_all(bind=engine)
    init_db()


def _bundle_entries(code: str) -> dict[str, str]:
    with SessionLocal() as db:
        bundle = db.get(LocalizationBundle, code)
        assert bundle is not None
        return json.loads(bundle.entries_json)


def test_app_start_reinstalls_builtin_bundles_without_touching_db_only_languages() -> None:
    builtin_bundles = localization_service.discover_builtin_bundles()

    with SessionLocal() as db:
        localization_service.ensure_seed(db)

        english_bundle = db.get(LocalizationBundle, "en")
        german_bundle = db.get(LocalizationBundle, "de")
        turkish_bundle = db.get(LocalizationBundle, "tr")
        assert english_bundle is not None
        assert german_bundle is not None
        assert turkish_bundle is not None

        english_bundle.entries_json = json.dumps({"dashboard": "Wrong"})
        german_bundle.entries_json = json.dumps({"dashboard": "Falsch"})
        turkish_bundle.entries_json = json.dumps({"dashboard": "Yanlis"})

        db.add(
            LocalizationLanguage(
                code="fr",
                name="French",
                enabled=True,
                is_default=False,
                is_rtl=False,
                fallback_order_json='["fr", "en"]',
                bundle_version=7,
            )
        )
        db.add(
            LocalizationBundle(
                language_code="fr",
                entries_json=json.dumps({"dashboard": "Tableau de bord"}),
            )
        )
        db.commit()

    with TestClient(app, base_url="http://localhost"):
        pass

    assert _bundle_entries("en") == builtin_bundles["en"]
    assert _bundle_entries("de") == builtin_bundles["de"]
    assert _bundle_entries("tr") == builtin_bundles["tr"]
    assert _bundle_entries("fr") == {"dashboard": "Tableau de bord"}

    with SessionLocal() as db:
        french_language = db.get(LocalizationLanguage, "fr")
        english_language = db.get(LocalizationLanguage, "en")
        german_language = db.get(LocalizationLanguage, "de")
        turkish_language = db.get(LocalizationLanguage, "tr")
        assert french_language is not None
        assert english_language is not None
        assert german_language is not None
        assert turkish_language is not None
        assert french_language.bundle_version == 7
        assert english_language.bundle_version == 1
        assert german_language.bundle_version == 1
        assert turkish_language.bundle_version == 1
