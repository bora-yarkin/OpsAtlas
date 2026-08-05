<!-- SPDX-FileCopyrightText: 2026 Bora Yarkin -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Backend Architecture

The backend is a FastAPI application organized around product modules. Each
module owns its HTTP routes, schemas, persistence models, and service logic.

## Runtime Entry Points

- `app/main.py` creates the FastAPI application, installs middleware, and
  includes module routers.
- `app/core/config.py` loads settings from environment variables and
  `backend/instance/.env`.
- `app/core/db/__init__.py` owns the SQLAlchemy engine, session factory, and
  startup database initialization helpers.
- `scripts/seed_db.py` creates local demo data.
- `scripts/container_entrypoint.py` is the Docker runtime entrypoint.

## Module Pattern

Most backend modules follow this layout:

| File | Responsibility |
| --- | --- |
| `models.py` | SQLAlchemy tables and relationships |
| `schemas.py` | Pydantic request and response contracts |
| `router.py` | FastAPI endpoints, dependency wiring, HTTP status mapping |
| `service.py` | Business rules, authorization decisions, writes, orchestration |
| `repo.py` | Optional query helpers for modules with heavier persistence logic |

Routers should stay thin. If a route starts carrying policy, write behavior, or
cross-module orchestration, move that logic into the service layer.

## Product Modules

- `admin`: organization graph, users, roles, branding, admin-level controls.
- `analytics`: activity events, feed shaping, search quality, top content, and
  trends.
- `auth`: login, sessions, refresh tokens, MFA, account security, onboarding.
- `backup`: backup access and security gates.
- `incidents`: incident lifecycle, status updates, action items, reminders,
  postmortems.
- `kb`: knowledge base folders, documents, comments, reviews, suggestions.
- `localization`: runtime language bundles and translatable content.
- `media`: upload policy, attachments, signed URLs, cleanup.
- `sop`: procedures, runs, steps, schedules, evidence, task integration.
- `spaces`: workspace membership, permissions, and space metadata.
- `tasks`: follow-up tasks linked to spaces, SOPs, and incidents.

## Cross-Cutting Core

- `core/auth`: password policy, token handling, cookies, and security helpers.
- `core/search`: query parsing and translation used by search endpoints.
- `core/rich_html.py`: HTML sanitization shared by content modules.
- `core/background.py`: lightweight maintenance workers.
- `core/secret_crypto.py`: secret sealing helpers.

Cross-cutting code should be small and boring. If a helper only matters to one
module, keep it in that module.

## Data And Sessions

Routes receive a database session through FastAPI dependencies. Tests override
the app configuration early so `SessionLocal` and the SQLAlchemy engine bind to
the isolated test database rather than the developer database.

Authentication uses short-lived access tokens, refresh sessions, cookie helpers,
and server-side session rows. Sensitive actions should go through the existing
auth dependency helpers instead of checking roles inline.

## Testing Strategy

Backend tests live in `backend/tests/`.

- Contract tests cover API shapes and key status codes.
- Boundary tests cover permissions between spaces, SOPs, incidents, tasks, and
  auth.
- Security tests cover tokens, password migration, media signing, MFA, and
  hardening helpers.
- SQLite compatibility tests protect local development behavior.

When adding a feature, prefer one focused service-level test plus one API-level
test for the user-visible contract.

## Maintenance Rules

- Keep routers thin.
- Keep module ownership clear.
- Use schemas for API contracts instead of raw dictionaries.
- Avoid binding tests to `dev.db`, PostgreSQL, or any configured real database.
- Put compatibility migrations and legacy support behind named helper functions
  with tests.
