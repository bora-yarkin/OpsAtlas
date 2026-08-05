# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

from app.modules.localization import service as localization_service


def test_builtin_bundle_discovery_reads_split_dart_catalogs() -> None:
    bundles = localization_service.discover_builtin_bundles()

    assert sorted(bundles) == ["de", "en", "tr"]
    assert bundles["en"]["dashboard"] == "Dashboard"
    assert bundles["de"]["dashboard"] == "Übersicht"
    assert bundles["tr"]["dashboard"] == "Panel"
    assert len(bundles["en"]) > 1_000


def test_reference_keys_come_from_full_english_catalog() -> None:
    bundles = localization_service.discover_builtin_bundles()

    assert localization_service.discover_reference_keys() == tuple(bundles["en"])
