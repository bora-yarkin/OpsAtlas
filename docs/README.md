<!-- SPDX-FileCopyrightText: 2026 Bora Yarkın -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# OpsAtlas Documentation

This directory holds the project documentation that does not belong at the
repository root.

## Development

- [Getting started](development/getting-started.md): first-run local setup,
  seed data, databases, common commands, and pre-push checks.
- [GitHub security automation](development/github-security.md): how GitHub
  Actions, CodeQL, and code scanning are intended to run for this repository.
- [iOS developer target](development/ios.md): developer-only native iOS setup
  for simulator or device testing. This target is not part of release bundles.

## Architecture

- [Backend architecture](architecture/backend.md): FastAPI module layout,
  service boundaries, cross-cutting helpers, and backend testing rules.
- [Frontend architecture](architecture/frontend.md): Flutter app structure,
  routing, state, API access, UI conventions, and test strategy.
- [Domain and data model](architecture/data-model.md): spaces, KB docs, SOPs,
  incidents, tasks, media, analytics, and ownership boundaries.

## Deployment

- [Docker deployment](deployment/docker-compose.md): Compose setup,
  persistence, seeded demo data, and release-bundle deployment.

## Reference

- [API reference](reference/api.md): backend endpoint guide.
- [UI reference](reference/ui.md): frontend route and navigation guide.

## Project

- [Versioning](project/versioning.md): automated semantic versioning and
  changelog rules.
- [Roadmap](project/roadmap.md): detailed forward-looking feature roadmap.
- [Codebase audit](project/codebase-audit.md): current maintenance findings and
  priorities.
