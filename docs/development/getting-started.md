<!-- SPDX-FileCopyrightText: 2026 Bora Yarkin -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Developer Getting Started

This guide is the shortest path from a fresh checkout to a useful local
OpsAtlas development environment.

## Prerequisites

- Python 3.11 or newer
- Flutter stable
- Docker Desktop or another Docker-compatible runtime
- PostgreSQL if you are not using SQLite for local development
- Xcode and CocoaPods only if you are building the iOS developer target

## First Run

From the repository root:

```bash
mkdir -p backend/instance
cp backend/.env.example backend/instance/.env
make deps
make seed-db
make opsatlas
```

Default local endpoints:

- Web: `http://localhost:3000`
- API: `http://localhost:8000`

Seeded demo accounts:

| Role | Email | Password |
| --- | --- | --- |
| Admin | `admin@admin.com` | `admin` |
| Moderator | `moderator@moderator.com` | `moderator` |
| Member | `member@member.com` | `member` |
| Viewer | `viewer@viewer.com` | `viewer` |

## Local Databases

The backend reads configuration from `backend/instance/.env`.

- `dev.db`, PostgreSQL, or any configured `DATABASE_URL` is application data.
- `backend/instance/db/test.db` is reserved for tests.
- Tests should never bind to a developer database or production-like database.
- If seeded demo credentials stop working after a test run, check that
  `DATABASE_URL` in `backend/instance/.env` still points where you expect.

## Useful Commands

| Command | Purpose |
| --- | --- |
| `make clean` | Remove generated caches and build artifacts only |
| `make cleanup` | Alias for `make clean` |
| `make deps` | Sync backend and frontend dependencies |
| `make refresh` | Run `make clean` and then `make deps` |
| `make opsatlas` | Start backend and Flutter web together |
| `make opsatlas seeddb` | Seed demo data and start the stack |
| `make opsatlas-stop` | Stop local backend and web listeners |
| `make tests` | Run backend lint/tests and frontend analyze/tests |
| `make release` | Build `dist/release.zip` |

## Backend Development

The backend virtual environment lives at `backend/.venv` and is managed by
Makefile targets.

```bash
make deps-backend
make backend-lint
make backend-test
```

Run the API only:

```bash
make api
```

Run a migration:

```bash
make api-migrate
```

Generate a migration:

```bash
make api-rev m="describe change"
```

## Frontend Development

The Flutter app lives in `client/`.

```bash
make deps-frontend
make client-analyze
make client-test
```

Run the web client only:

```bash
make flutter-web
```

When running against a remote API:

```bash
cd client
flutter run -d chrome --dart-define=API_BASE_URL=https://opsatlas.example.com
```

## iOS Developer Target

The iOS project is a developer target, not a release artifact. Open
`client/ios/Runner.xcworkspace`, not `Runner.xcodeproj`.

```bash
cd client
flutter pub get
flutter build ios --config-only --no-codesign
open ios/Runner.xcworkspace
```

More detail lives in [iOS developer target](ios.md).

## Common Problems

### Flutter prints newer package warnings after `make cleanup`

`make cleanup` is now a clean-only target. If you see package availability
warnings after dependency commands, they are usually advisory messages from
`flutter pub get` or `flutter pub outdated`, not build failures.

### `Module 'file_picker' not found` during iOS builds

Regenerate the iOS integration:

```bash
cd client
flutter build ios --config-only --no-codesign
cd ios
pod install
```

Then build from `Runner.xcworkspace`.

### Browser cannot reach the API

Check `backend/instance/.env` for `API_PORT`, `WEB_PORT`, `CORS_ORIGINS`, and
`TRUSTED_HOSTS`. The local defaults expect the API on `localhost:8000` and the
web client on `localhost:3000`.

## Before Pushing

```bash
make tests
reuse lint
git diff --check
```

For dependency or native iOS changes, also run:

```bash
cd client
flutter build ios --no-codesign
```
