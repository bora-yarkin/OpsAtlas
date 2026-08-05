<!-- SPDX-FileCopyrightText: 2026 Bora Yarkın -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Frontend UI Reference

This document is the human-maintained frontend map for the main screens,
navigation rules, and shared UI building blocks in OpsAtlas.

## Shared Runtime Layers

- `lib/app/app.dart`
  Global app widget that applies branding, theme, locale, and router config.
- `lib/app/router.dart`
  Central route table and auth redirect policy.
- `lib/app/shell.dart`
  Shared authenticated shell for nav chrome, notifications, and session status.
- `lib/core/api/api_client.dart`
  Dio wrapper with refresh-token retry logic.
- `lib/core/api/auth_store.dart`
  Riverpod-backed auth/session state holder.
- `lib/core/theme/theme.dart`
  Global theme tokens and Material configuration.
- `lib/core/widgets/atlas_ui.dart`
  Shared page, panel, and stat/layout primitives.

## Route Families

## `/connect`

Purpose: first-run server selection for generalized mobile builds.

Key responsibilities:

- Prompts the user for the company-hosted OpsAtlas domain.
- Verifies that the target exposes the public OpsAtlas branding contract.
- Persists the selected backend base URL before normal auth begins.

Code to read:

- `lib/features/auth/server_connect_screen.dart`
- `lib/core/api/server_config.dart`

## `/login`

Purpose: sign-in, onboarding continuation, and session-profile selection.

Key responsibilities:

- Loads session policy so the user can choose browser-only vs remember-device sessions.
- Handles onboarding flows that may continue from temporary credentials or invite tokens.
- Bridges branding, locale, and auth state before the main shell is entered.
- For generalized mobile builds, links back to `/connect` so the user can switch company domains.

Code to read:

- `lib/features/auth/login_screen.dart`
- `lib/core/api/auth_store.dart`

## `/dashboard`

Purpose: operational summary for the current user and optionally a selected space.

Key responsibilities:

- Loads profile and dashboard preferences.
- Aggregates spaces, tasks, feed events, due SOP runs, mentions, and open incidents.
- Persists widget layout and hidden-widget choices through dashboard preferences.

Code to read:

- `lib/features/dashboard/dashboard_screen.dart`

## `/spaces`

Purpose: discover and search spaces.

Key responsibilities:

- Fetches accessible spaces.
- Supports structured search input and saved search state.
- Acts as the primary launch point into `/spaces/:spaceId`.

Code to read:

- `lib/features/spaces/spaces_screen.dart`

## `/spaces/:spaceId`

Purpose: content-focused operational workspace for KB, SOPs, and incidents.

Key responsibilities:

- Loads a single space context.
- Keeps KB, SOP, and incident sections in one route and one pager.
- Mirrors section state back into query parameters so deep links can reopen
  a specific tab, doc, SOP, incident, timeline entry, or action item.
- Supports mobile back navigation and Cupertino-style stack entry.

Section breakdown:

- KB
  Docs, folders, review flows, comments, and publishing.
- SOPs
  Procedure authoring, execution runs, approvals, schedules, and linked follow-up work.
- Incidents
  Incident records, timelines, impacts, action items, reminders, and postmortems.

Code to read:

- `lib/features/spaces/space_workspace_screen.dart`
- `lib/features/spaces/workspace_surface_shell.dart`
- `lib/features/spaces/space_workspace_*.dart`

## `/tasks`

Purpose: manage standalone tasks plus tasks derived from incidents or SOPs.

Key responsibilities:

- Supports scoped search, quick filters, board/list views, and saved searches.
- Reuses workspace-style toolbars and editor surfaces.
- Can open directly into a create flow from query parameters.

Code to read:

- `lib/features/tasks/tasks_screen.dart`

## `/analytics`

Purpose: privileged reporting view over usage, content activity, and search quality.

Key responsibilities:

- Loads per-space trend data and top entities.
- Supports export actions.
- Reuses shared page framing rather than workspace framing.

Code to read:

- `lib/features/analytics/analytics_screen.dart`

## `/organization`

Purpose: administrative control plane for organization, roles, media, branding, and backups.

Subroutes:

- `/organization`
  Core organization management UI.
- `/organization/media`
  Admin media manager.
- `/organization/backups`
  Backup snapshot list.
- `/organization/backups/:snapshotId`
  Snapshot browser.

Code to read:

- `lib/features/admin/organization/admin_organization_screen.dart`
- `lib/features/admin/media/admin_media_screen.dart`
- `lib/features/admin/backups/backups_screen.dart`
- `lib/features/admin/backups/snapshot_browser_screen.dart`

## `/account`

Purpose: current-user profile and security settings.

Key responsibilities:

- Profile editing.
- Password change flow.
- MFA status, setup, verify, and disable flows.
- Active and revoked session management.
- Notification preference management.

Code to read:

- `lib/features/account/account_screen.dart`

## Shared Navigation Rules

- Top-level authenticated routes render inside `AppShell`.
- Desktop shell routes use a small fade and upward slide transition.
- Space workspaces use Cupertino page transitions because they behave like a
  stacked detail destination.
- `atlasOpenRoute` decides whether a route should push or replace based on
  whether it represents a stack-style workspace destination.
- `AtlasEdgeBackGesture` adds mobile edge-swipe back behavior to compact pages
  and panels that opt in.

## Notifications Panel

The notifications panel is not owned by individual screens. It lives in
`AppShell` and aggregates:

- unread KB mentions
- incident reminder history
- pending SOP approvals

This keeps cross-workspace operational signals accessible from anywhere.

## UI Smoke Coverage

`test/ui_smoke_test.dart` is the main route-sweep safety net. It boots the app
in desktop and mobile sizes, walks through the main screens, opens key drawers
and detail flows, and fails on Flutter runtime errors.
