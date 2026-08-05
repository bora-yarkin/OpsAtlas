<!-- SPDX-FileCopyrightText: 2026 Bora Yarkın -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Changelog

All notable changes to OpsAtlas are documented here.

OpsAtlas is still pre-1.0. Historical entries before formal release tagging are
reconstructed from manifest versions and commit history, so they are recorded as
dated milestones instead of pretending a precise tagged-release ledger already
exists.

## [Unreleased]

Automated release notes are generated below from synchronized commit history.

### Changed

- Added roadmap coverage for per-commit GitHub releases that publish
  version-matched release notes and downloadable deployment artifacts.
- Reworked the release bundle layout so the extracted outer bundle is runnable
  immediately with root-level Compose files, a root `.env.example`, extracted
  backend and client sources, and a nested archival source zip.
- Added first-run environment bootstrapping so `docker compose up` can create
  `.env` and generate random secrets automatically when the file is missing.
- Added GitHub release automation so successful pushes to `main` can create or
  update a tagged release whose notes come from the synchronized changelog and
  whose asset is the generated deployment bundle.
- Smoothed GitHub-native security workflows so Dependency Review reports when it
  is intentionally not applicable and CodeQL/SARIF uploads skip cleanly when
  GitHub code scanning is not enabled for the repository.
- Changed Docker demo seeding to a one-shot persistent flow that writes into
  PostgreSQL once, skips reseeding when the dataset already exists, and removes
  the finished seed container without erasing stored data.
- Updated release documentation to describe the new root-level deploy flow.
- Added release-bundle troubleshooting guidance for first-run Docker registry
  pull timeouts during seeded deployments.
- Switched Docker deployment images to moving tags, including full `python:3.14`
  bases for bootstrap and backend builds and non-Alpine runtime images.
- Kept PostgreSQL on `postgres:latest` but pinned `PGDATA` to
  `/var/lib/postgresql/data` so existing Docker volumes remain compatible after
  PostgreSQL 18 layout changes.
- Fixed the backend container image so shell-invoked `python` resolves to the
  synced virtualenv, preventing release-bundle `seeddb` failures such as
  `ModuleNotFoundError: No module named 'sqlalchemy'`.
- Clarified the release-bundle seeded deployment flow so operators run
  `seeddb` first and then explicitly start `backend`, `web`, `db`, and
  `filestorage` afterward.
- Added first-class release-bundle support for `.env.docker`, including runtime
  autodetection, updated usage docs, and a packaged `.env.docker.example`
  template.
- Preserved previously generated release-bundle secrets across restarts while
  env files still contain placeholders, preventing PostgreSQL password drift
  against existing Docker volumes.

### Fixed

- Fixed the space workspace task copy-link route and removed stale folder-tree
  expansion code so Dart analysis stays clean.
- Fixed the space workspace search box so multi-word queries can keep typed
  spaces instead of collapsing back to a single token while editing.

<!-- opsatlas-versioning:start -->

## [0.10.0] - 2026-07-01

### Added

- New client parity improvement.

## [0.9.0] - 2026-06-30

### Added

- Add a new experimental client.

## [0.8.4] - 2026-06-29

### Changed

- Bump dio in /client in the frontend-dart group.

## [0.8.3] - 2026-06-29

### Changed

- Bump actions/download-artifact in the github-actions group.

## [0.8.2] - 2026-06-26

### Fixed

- Restore inherited space access and KB doc viewing for members.

## [0.8.1] - 2026-06-26

### Fixed

- Fix docker release bundle.

## [0.8.0] - 2026-06-26

### Added

- Add manual task screen with checklist functionality.

## [0.7.0] - 2026-06-26

### Added

- Refactor space workspace shared widgets and add SOP run task screen.

## [0.6.2] - 2026-06-25

### Fixed

- Refactor code structure for improved readability and maintainability.

## [0.6.1] - 2026-06-25

### Fixed

- Refactor spaces and tasks screens for improved navigation and search functionality.

## [0.6.0] - 2026-06-24

### Added

- Enhance DAST smoke checks with improved HTTP request handling and JSON encoding.

## [0.5.0] - 2026-06-24

### Added

- Implement automated version sync with post-commit hook and update version to 0.4.6.

## [0.4.6] - 2026-06-24

### Fixed

- Enhance media storage path validation and improve test coverage.

## [0.4.5] - 2026-06-24

### Fixed

- Reduce code scanning and supply chain alerts.

## [0.4.4] - 2026-06-24

### Changed

- Update version to 0.4.3 and enforce encrypted cookies.

## [0.4.3] - 2026-06-24

### Fixed

- Enforce encrypted cookies and safe storage paths.

## [0.4.2] - 2026-06-24

### Fixed

- Resolve CodeQL findings and stabilize release/DAST CI.

## [0.4.1] - 2026-06-24

### Fixed

- Resolve CodeQL findings and stabilize release/DAST CI.

## [0.4.0] - 2026-06-24

### Added

- Update version to 0.3.0 and enhance GitHub workflows for security automation.

## [0.3.0] - 2026-06-24

### Added

- Automate tagged GitHub releases and fix reuse compliance.

## [0.2.0] - 2026-06-24

### Added

- Implement synchronized semantic versioning and automated changelog.

<!-- opsatlas-versioning:end -->

## 2026-06-24 - Documentation And Release Structure

- Reorganized the repository documentation so the README, docs index, roadmap,
  audit, and changelog each own a distinct job instead of duplicating shipped
  history.
- Documented a formal versioning policy and moved shipped work out of
  planning-oriented docs.
- Slimmed the portable release bundle to runtime-only sources plus license
  material, removing repository-only content and development-only mobile
  targets such as `client/ios`.
- Added dedicated iOS developer-target documentation under `docs/development/`.
- Added a fresh codebase audit based on the current repository instead of the
  older April snapshot.

## 2026-06-20 - Backend Coverage Expansion

- Added broad backend coverage for core runtime helpers, database helpers, and
  spaces/tasks API behavior.

## 2026-06-18 - UI Smoke And Reference Docs

- Added desktop and mobile UI smoke coverage across the main application
  surfaces.
- Refined client layout and responsiveness across the workspace-heavy screens.
- Added backend API and frontend UI reference documentation.
- Expanded inline code documentation across the workspace UI.

## 2026-06-07 To 2026-06-11 - Navigation And Workspace Refactor

- Refactored the SOP detail flow into a more structured content presentation.
- Reworked spaces navigation and shared workspace UI structure.
- Added iOS-style edge back gesture support for compact navigation flows.

## 2026-06-03 To 2026-06-05 - Deployment, Analytics, And Platform Groundwork

- Expanded spaces and tasks surfaces with richer metrics and filtering.
- Added branding-aware web metadata and manifest updates.
- Broadened analytics instrumentation across the product.
- Introduced Docker deployment support and the first portable release-bundle
  flow.
- Added a developer-oriented iOS target and related API base-URL handling.
- Removed the legacy monolithic source-zip packaging approach from the main
  repository history.

## 2026-04-17 - SOP Editing And Media Test Coverage

- Added SOP editor support and media upload section tests.

## 2026-04-13 - Initial Public Baseline

- Published the first public repository baseline for OpsAtlas.
- Refactored the Makefile and CI setup for more reliable local/backend
  workflows.
- Hardened auth refresh throttling and password-hash upgrade behavior.
- Centralized request-error handling across admin features.
