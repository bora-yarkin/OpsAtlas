<!-- SPDX-FileCopyrightText: 2026 Bora Yarkin -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Frontend Architecture

The frontend is a Flutter app that targets web first and keeps an iOS host
project for developer testing.

## Runtime Entry Points

- `client/lib/main.dart` starts the Flutter app.
- `client/lib/app/app.dart` owns the top-level app widget.
- `client/lib/app/router.dart` defines route guards and route-to-screen mapping.
- `client/lib/app/shell.dart` owns the application shell, desktop sidebar,
  mobile navigation, notifications panel, and route chrome.

## Directory Layout

| Path | Responsibility |
| --- | --- |
| `core/api` | API client, auth storage, server/domain connection, errors |
| `core/i18n` | Runtime localization maps and locale controller |
| `core/navigation` | Route transition helpers and navigation behavior |
| `core/search` | Query parsing, validation, diagnostics, analytics |
| `core/security` | Client-side HTML and media policy helpers |
| `core/theme` | Theme tokens and theme controller |
| `core/widgets` | Shared app surfaces, dialogs, media, rich content |
| `features/*` | Product screens and feature-specific widgets |

Shared widgets belong in `core/widgets` only when they are genuinely reused
outside one feature. Feature-specific widgets should stay beside the feature.

## Routing And Navigation

The router protects authenticated routes, admin-only surfaces, onboarding, and
server-connection flows. Navigation helpers in `core/navigation` centralize the
mobile/desktop transition behavior so feature screens do not each invent their
own route motion.

For iOS-style mobile navigation, use the existing route helper APIs rather than
calling `Navigator` directly from feature widgets.

## State And API Access

The app uses Riverpod for shared state and feature controllers. API traffic goes
through `ApiClient`, which handles base URL selection, auth behavior, refresh
flows, and request errors.

New feature code should avoid constructing raw `Dio` clients. Add focused
methods to the API layer or a feature repository/helper if the endpoint needs
typed handling.

## UI Conventions

OpsAtlas is an operations workspace. Screens should prioritize content density,
clear hierarchy, and repeated-use ergonomics over decorative layouts.

Preferred patterns:

- Keep page-level controls compact and close to the relevant content.
- Use full screens for complex create/edit flows.
- Use dialogs only for short confirmations or tightly scoped actions.
- Preserve mobile reachability and avoid sticky headers that shrink content too
  much.
- Keep cards for repeated items or genuinely framed tools, not whole-page
  sections.

## Web And iOS Targets

The supported product surface is the web app plus backend API. The iOS target is
kept for developer testing and future mobile work. Release bundles intentionally
exclude `client/ios`.

When native iOS dependencies change, regenerate the native integration with:

```bash
cd client
flutter build ios --config-only --no-codesign
```

Then open `client/ios/Runner.xcworkspace`.

## Testing Strategy

Frontend tests live in `client/test/`.

- Localization guard tests protect translation parity and raw text mistakes.
- API/client contract tests protect request behavior and server configuration.
- UI smoke tests exercise major routes, responsive layouts, and framework error
  trapping.
- Widget tests cover reusable components and user-visible states.

For UI changes, add or extend smoke coverage for the route, viewport, or
interaction that failed before.
