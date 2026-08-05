<!-- SPDX-FileCopyrightText: 2026 Bora Yarkın -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Backend Guide

OpsAtlas uses a feature-module backend with a thin FastAPI bootstrap layer.
The code is organized so request wiring, business rules, and persistence are
easy to read separately.

## How To Read The Backend

When you are tracing behavior, read files in this order:

1. `app/main.py`
   Wires middleware, startup behavior, and every router prefix.
2. `app/modules/<feature>/router.py`
   Defines the HTTP contract and request-level authorization checks.
3. `app/modules/<feature>/schemas.py`
   Shows request and response payload shapes.
4. `app/modules/<feature>/service.py`
   Holds workflow, validation, orchestration, and side effects.
5. `app/modules/<feature>/models.py`
   Declares SQLAlchemy persistence models.
6. `app/modules/<feature>/repo.py`
   Exists only in query-heavy features and contains persistence helpers.
7. `app/core/*`
   Shared infrastructure such as auth, config, search, HTML handling, and DB helpers.

## Request Lifecycle

Most requests follow the same path:

1. FastAPI receives the request in `app/main.py`.
2. A router validates input and resolves dependencies such as `get_db` and `get_current_user`.
3. The router enforces coarse access control and delegates to a service.
4. The service applies business rules, talks to SQLAlchemy, and triggers side effects.
5. Schemas and serializer helpers shape the final response.

## Architectural Rules

- Routers stay thin and should not contain business policy.
- Services own workflow, validation, and cross-module coordination.
- Models describe storage state, not request handling.
- Schemas describe API contracts and validation intent.
- Core utilities stay reusable and feature-agnostic.

## Important Subsystems

- Auth and sessions:
  `app/core/auth/*` plus `app/modules/auth/*` implement password hashing,
  JWT access tokens, refresh-token rotation, MFA, lockouts, and session policy.
- Knowledge search:
  `app/core/search/*` and `app/modules/kb/*` handle search parsing,
  query translation, and KB discovery behavior.
- Localization:
  `app/modules/localization/*` provides runtime bundles, translation settings,
  and per-user language preferences used throughout content features.
- Organization and admin:
  `app/modules/admin/*` owns user provisioning, org graph, custom roles,
  branding, and session policy administration.
- Operational content:
  `app/modules/kb/*`, `app/modules/sop/*`, `app/modules/incidents/*`, and
  `app/modules/tasks/*` contain the main product workflows.

## API Surface Map

These router families are registered in `app/main.py`:

- `/auth`: authentication, onboarding, MFA, sessions, profile, and user preferences
- `/spaces`: space discovery, creation, and member listings
- `/kb`: folders, documents, review workflow, versions, comments, mentions, and search
- `/sop`: SOP authoring, approval, schedules, run execution, and audit exports
- `/incidents`: incident tracking, templates, timelines, action items, impacts, and reports
- `/tasks`: personal tasks, space tasks, SOP-linked tasks, and comments
- `/analytics`: activity ingest, feed queries, trends, search quality, and exports
- `/admin`: user lifecycle, org graph, branding, role administration, and session policy
- `/media`: uploads, attachments, metadata, usage, and signed file access
- `/localization`: runtime bundles, translation queues, catalog management, and preferences
- `/ai`: AI-assisted summarization and drafting endpoints
- `/admin/backups`: backup snapshot browsing and restore support utilities

See [docs/reference/api.md](../docs/reference/api.md) for the endpoint guide.

## Documentation Style

Documentation is meant to speed up maintenance, not add noise:

- Module docstrings explain a file's role in the system.
- Class docstrings explain what a model, schema, or dataclass represents.
- Function docstrings explain intent, invariants, and workflow when the name alone is not enough.
- Inline comments are reserved for non-obvious decisions and tradeoffs.

## Good Entry Points

- Overall runtime: `app/main.py`
- Auth/session debugging: `app/core/auth/security.py`, `app/modules/auth/service.py`
- API contracts: `app/modules/<feature>/router.py` and `schemas.py`
- Search behavior: `app/core/search/translation.py`, `app/modules/kb/service.py`
- Localization behavior: `app/modules/localization/service.py`
- Organization and access-control behavior: `app/modules/admin/service.py`
