# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient

from app.core.db import Base, engine, init_db
from app.core.build_info import APP_BUILD, APP_RELEASE, APP_VERSION
from app.main import app


@pytest.fixture(autouse=True)
def reset_db() -> None:
    init_db()
    Base.metadata.drop_all(bind=engine)
    init_db()


@pytest.fixture
def client() -> Iterator[TestClient]:
    with TestClient(app, base_url="http://localhost") as test_client:
        yield test_client


SECURITY_HEADERS = {
    "content-security-policy",
    "cross-origin-opener-policy",
    "cross-origin-resource-policy",
    "permissions-policy",
    "referrer-policy",
    "x-content-type-options",
    "x-frame-options",
    "x-permitted-cross-domain-policies",
}


REQUIRED_OPENAPI_PATHS = {
    "/health": {"get"},
    "/branding": {"get"},
    "/branding/manifest.webmanifest": {"get"},
    "/auth/login": {"post"},
    "/auth/refresh": {"post"},
    "/auth/me": {"get", "patch"},
    "/auth/session/policy": {"get"},
    "/spaces": {"get", "post"},
    "/kb/spaces/{space_id}/docs": {"get"},
    "/kb/docs": {"post"},
    "/sop/spaces/{space_id}/sops": {"get"},
    "/sop/sops": {"post"},
    "/incidents/spaces/{space_id}": {"get"},
    "/incidents": {"post"},
    "/tasks/my": {"get"},
    "/tasks/spaces/{space_id}": {"get"},
    "/analytics/events": {"post"},
    "/analytics/feed": {"get"},
    "/admin/org/items": {"get"},
    "/admin/org/item-links/bulk/preview": {"post"},
    "/admin/org/graph/export": {"post"},
    "/admin/customization": {"get", "put"},
    "/admin/backups/snapshots": {"get"},
    "/media/upload": {"post"},
    "/localization/runtime": {"get"},
    "/localization/catalog": {"get", "patch"},
    "/ai/summarize": {"post"},
}


@pytest.mark.parametrize("header", sorted(SECURITY_HEADERS))
def test_health_includes_baseline_security_headers(client: TestClient, header: str) -> None:
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {
        "ok": True,
        "version": APP_VERSION,
        "build": APP_BUILD,
        "release": APP_RELEASE,
    }
    assert header in response.headers


def test_openapi_contract_exposes_expected_product_surfaces(client: TestClient) -> None:
    response = client.get("/openapi.json")

    assert response.status_code == 200
    paths = response.json()["paths"]
    for path, methods in REQUIRED_OPENAPI_PATHS.items():
        assert path in paths, f"Missing OpenAPI path: {path}"
        for method in methods:
            assert method in paths[path], f"Missing {method.upper()} {path}"


def test_openapi_operation_ids_are_unique(client: TestClient) -> None:
    response = client.get("/openapi.json")

    assert response.status_code == 200
    operation_ids: list[str] = []
    for path_item in response.json()["paths"].values():
        for operation in path_item.values():
            if isinstance(operation, dict) and operation.get("operationId"):
                operation_ids.append(str(operation["operationId"]))

    duplicates = sorted({value for value in operation_ids if operation_ids.count(value) > 1})
    assert duplicates == []


@pytest.mark.parametrize(
    ("method", "path", "json_payload"),
    [
        ("GET", "/auth/me", None),
        ("GET", "/auth/me/dashboard-preferences", None),
        ("GET", "/spaces", None),
        ("GET", "/tasks/my", None),
        ("POST", "/analytics/events", {"event_type": "view", "path": "/dashboard"}),
        ("GET", "/admin/org/items", None),
        ("GET", "/admin/backups/snapshots", None),
        ("GET", "/localization/runtime", None),
    ],
)
def test_authenticated_surfaces_reject_anonymous_requests(
    client: TestClient,
    method: str,
    path: str,
    json_payload: dict[str, object] | None,
) -> None:
    response = client.request(method, path, json=json_payload)

    assert response.status_code in {401, 403}


def test_public_branding_contract_has_resolved_defaults(client: TestClient) -> None:
    branding = client.get("/branding")
    manifest = client.get("/branding/manifest.webmanifest")

    assert branding.status_code == 200
    branding_payload = branding.json()
    assert branding_payload["resolved_app_title"] == "OpsAtlas"
    assert branding_payload["resolved_application_short_name"] == "OpsAtlas"
    assert branding_payload["resolved_theme_color_hex"].startswith("#")

    assert manifest.status_code == 200
    manifest_payload = manifest.json()
    assert manifest_payload["name"]
    assert manifest_payload["short_name"]
    assert manifest_payload["theme_color"].startswith("#")
