<!-- SPDX-FileCopyrightText: 2026 Bora Yarkın -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# OpsAtlas Codebase Audit

**Date:** June 22, 2026

## Executive Summary

The repository is in materially better shape than the April audit reflected.
Backend and frontend tests are much broader, the docs structure is clearer, and
the portable release bundle no longer needs to mirror the whole repository.

The biggest remaining risks are now concentrated in maintainability and release
discipline rather than missing fundamentals:

- a small set of very large backend and Flutter files still carry too much logic
- releases are still built from source on the deployment host
- the main UI smoke suite is broad but too monolithic to stay easy to evolve
- historical release provenance still starts late because earlier versions were
  never tagged before the new automation work

## Improvements Since The Previous Audit

- Historical workflow and deployment-doc drift has been corrected.
- The release bundle now ships only runtime sources plus license material.
- Delivered work is being moved out of planning/audit docs and into the
  changelog.
- Backend tests now span 17 files and about 3,980 lines.
- Frontend tests now span 11 files and about 3,526 lines, including a full app
  smoke sweep.

## Open Findings

### 1. Critical: File-Size Concentration

The biggest maintainability issue is still concentration of business logic in a
small number of files.

| File | Lines | Why It Matters | Recommended Action |
| --- | ---: | --- | --- |
| `backend/app/modules/admin/service.py` | 3,784 | Too many admin workflows in one service boundary | Split branding, org graph, governance, and session-policy logic |
| `backend/app/modules/localization/service.py` | 3,136 | Import/export, runtime bundles, and translation flows are tightly coupled | Extract runtime bundle, import/export, and queue helpers |
| `client/lib/features/admin/media/admin_media_screen.dart` | 2,872 | List, detail, upload, and filtering all live together | Break into explorer, preview, and upload widgets |
| `client/lib/features/admin/organization/admin_organization_mutations.dart` | 2,773 | Mutations and modal/editor logic are still dense | Separate mutation services from UI flows |
| `client/lib/features/tasks/tasks_screen.dart` | 2,629 | Browse, filters, editor, and detail behavior remain too entangled | Split board/list shell, editor, and shared task detail widgets |
| `client/lib/app/shell.dart` | 2,314 | Navigation, notifications, responsive layout, and chrome state are all mixed | Extract nav chrome, notifications, and mobile/desktop layout slices |

### 2. High: Release Distribution Still Builds From Source

The release bundle is now minimal, but target hosts still build backend and web
images from source. That is acceptable for pre-1.0 self-hosted distribution,
but it is not the strongest long-term release model.

Recommended action:

- publish tagged backend and web container images
- keep `release.zip` as optional deployment metadata only, or replace it with a
  Compose file plus image tags

### 3. Medium: Historical Release Provenance Starts Late

The repository now carries synchronized manifest and changelog versions and the
main `Product CI` workflow can publish matching GitHub releases going forward,
but older historical versions still have no tags or published artifacts. That
means rollback provenance is strong from the new automation point onward, not
across the full visible history.

Recommended action:

- keep future releases flowing only through the automated tagged path
- avoid backfilling pretend historical tags unless they can be justified from
  real shipped artifacts or verifiable deployment records

### 4. Medium: Frontend Smoke Coverage Is Broad But Monolithic

`client/test/ui_smoke_test.dart` is doing valuable work, but at 2,338 lines it
is becoming its own maintenance hotspot. The suite catches many runtime errors,
yet it is harder than it should be to add focused assertions or isolate route
families.

Recommended action:

- split the smoke suite by route family
- add more route-local overflow and layout assertions
- keep a thin top-level full-app sweep that proves navigation still works

### 5. Medium: Generated Localization Catalogs Dominate Client File Size

The localization bundles are expected to be large, but the generated files are
among the largest Dart files in the tree. That is acceptable operationally, but
it makes manual review noisy.

Recommended action:

- keep generated localization output clearly separated from hand-maintained UI
  files
- avoid mixing manual edits into generated catalog files

## Priority Order

1. Split the largest backend and Flutter files.
2. Move release publishing from source-built bundles toward tagged container
   images.
3. Keep future release publishing on the automated tagged path and avoid
   splitting release provenance across manual and automated flows.
4. Break the UI smoke suite into smaller route-focused tests.
