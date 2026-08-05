<!-- SPDX-FileCopyrightText: 2026 Bora Yarkın -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Frontend Guide

OpsAtlas uses a Flutter frontend organized around an authenticated app shell,
feature screens, and a small shared core layer for API, theme, search, and
navigation helpers.

## How To Read The Frontend

When you need to understand UI behavior, read files in this order:

1. `lib/main.dart`
   Bootstraps Flutter, Riverpod, and web URL strategy.
2. `lib/app/app.dart`
   Wires global theme, localization, branding, and router configuration.
3. `lib/app/router.dart`
   Defines route structure, auth redirects, and page transition rules.
4. `lib/app/shell.dart`
   Owns shared authenticated chrome such as sidebar, session warning banner,
   notifications panel, and top-level navigation behavior.
5. `lib/core/api/*`
   Handles auth state, API transport, refresh-token rotation, and request errors.
6. `lib/core/theme/*` and `lib/core/widgets/*`
   Defines the design primitives used by feature screens.
7. `lib/features/<feature>/*`
   Contains the actual user-facing workflows.

## Screen Model

The UI is built around a few large route families:

- `/login`
  Unauthenticated entry point with onboarding and session-profile controls.
- `/dashboard`
  Multi-widget operational overview driven by user preferences.
- `/spaces`
  Space discovery and search.
- `/spaces/:spaceId`
  Content-focused workspace with KB, SOP, and incidents living inside a
  single route and switching sections in-place.
- `/tasks`
  Personal and scoped task management.
- `/analytics`
  Read-only reporting for privileged roles.
- `/organization`
  Administrative organization management, branding, media, and backups.
- `/account`
  Profile, password, MFA, session, and notification settings.

See [docs/reference/ui.md](../docs/reference/ui.md) for the route-by-route guide.

## Navigation Model

OpsAtlas intentionally uses different navigation behaviors for different kinds
of movement:

- Desktop top-level routes use the authenticated shell and a subtle fade plus
  slight upward slide transition.
- Mobile top-level routes share the same shell but avoid heavy desktop motion.
- `/spaces/:spaceId` is treated like a stack destination and opens with a
  Cupertino-style page transition.
- Inside a space workspace, KB, SOP, and incidents switch with a `PageView`
  because they are peer sections rather than nested subpages.
- Compact pages can opt into `AtlasEdgeBackGesture` to support iOS-style
  edge-swipe back navigation.
- Notifications are owned by the shell and appear as a left-side overlay:
  panel-style on desktop, full-screen on mobile.

## State Model

State is intentionally split by responsibility:

- Riverpod `Provider` and `FutureProvider`
  Used for route-level data loading and derived screen state.
- `AuthStore`
  Holds the current auth/session model and bridges cookie-based web sessions
  with token-based non-web sessions.
- `ApiClient`
  Adds auth headers, handles refresh-token retries, and clears client session
  state when the backend invalidates auth.
- Local widget state
  Used for transient UI concerns such as search text, open panels, selected
  filters, or editor draft values.
- Shared preferences
  Used for lightweight persistence such as sidebar expansion or saved search
  preferences.

## Layout Primitives

Most screens are built from a shared set of layout widgets:

- `AtlasPageFrame`
  Standard full-page frame for desktop-style pages.
- `AtlasCompactPageFrame`
  Compact/mobile-friendly frame with back affordances.
- `AtlasPanel`
  Section container for content-heavy screens.
- `WorkspaceSurfaceShell`
  Shared scaffold for KB, SOP, incident, and task toolbars plus body content.
- `WorkspaceInlineStrip`
  Horizontal strip used for filters, actions, and tab-like controls.

Using these primitives keeps spacing, header behavior, and responsive layout
rules consistent across large screens and mobile.

## Search Model

Spaces, tasks, and other content-heavy surfaces use a shared structured-search
layer:

- `core/search/query_ast.dart`
  AST model for structured search.
- `core/search/search_validation.dart`
  Parsing and diagnostics helpers.
- `core/search/search_state.dart`
  Saved view and recent query structures.
- `core/search/search_analytics.dart`
  Search telemetry helpers used by feature screens.

Feature screens are expected to normalize raw text input, produce a shared AST
payload, and keep the raw query visible to the user.

## Testing And Verification

The main UI verification entry point is:

- `test/ui_smoke_test.dart`
  Drives desktop and mobile route sweeps through the major product surfaces
  and asserts that Flutter runtime errors are not thrown.

Useful local commands:

- `dart format lib test`
- `flutter analyze`
- `flutter test test/ui_smoke_test.dart`

## Good Entry Points

- App bootstrap: `lib/main.dart`, `lib/app/app.dart`
- Routing and transitions: `lib/app/router.dart`
- Shared shell behavior: `lib/app/shell.dart`
- Session/auth behavior: `lib/core/api/auth_store.dart`, `lib/core/api/api_client.dart`
- Visual system: `lib/core/theme/theme.dart`, `lib/core/widgets/atlas_ui.dart`
- Space workspace behavior: `lib/features/spaces/space_workspace_screen.dart`
- UI smoke coverage: `test/ui_smoke_test.dart`
