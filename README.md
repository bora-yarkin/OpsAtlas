<!-- SPDX-FileCopyrightText: 2026 Bora Yarkın -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# OpsAtlas

OpsAtlas is a self-hosted operations workspace for teams that keep procedures,
incident context, and follow-up work in the same system. It combines a Flutter
web client with a FastAPI backend and is aimed at internal operational
workflows where auditability matters.

The repository is still pre-1.0. The supported product surface today is the web
client plus the backend API; native iOS files are kept only as a developer
testing target and are intentionally excluded from release bundles.

## Product Areas

- Spaces workspace for knowledge base documents, SOPs, and incidents
- Tasks for follow-through work linked back to SOPs and incidents
- Dashboard and analytics for activity, search quality, and operational trends
- Organization administration for users, roles, branding, media, and backups
- Account and security flows for sessions, MFA, password changes, and
  notification preferences

## Repository Layout

- `client/`: Flutter UI
- `backend/`: FastAPI app, SQLAlchemy models, and backend scripts
- `compose.yaml`: local Docker Compose stack
- `docs/`: deployment, reference, and project-maintenance documentation
- `.github/workflows/ci.yml`: product CI, security tooling, and DAST smoke jobs
- `.github/workflows/github-native.yml`: dependency review, CodeQL, and
  OpenSSF Scorecard
- `.github/workflows/release.yml`: manual release republish fallback for the
  tagged release bundle

## Quick Start

### Prerequisites

- Python 3.11+
- Flutter SDK
- PostgreSQL or SQLite

### Local stack

```bash
cd backend
mkdir -p instance
cp .env.example instance/.env
cd ..
make opsatlas
```

Default local endpoints:

- Web: `http://localhost:3000`
- API: `http://localhost:8000`

Seed demo data:

```bash
make seed-db
```

`make seed-db` is destructive: it drops the current application database and
reseeds it from scratch.

Demo accounts after seeding:

- `admin@admin.com` / `admin`
- `moderator@moderator.com` / `moderator`
- `member@member.com` / `member`
- `viewer@viewer.com` / `viewer`

Stop the local stack:

```bash
make opsatlas-stop
```

Useful commands:

| Command | Purpose |
| --- | --- |
| `make opsatlas` | Start backend and web client together |
| `make opsatlas seeddb` | Drop, reseed, and then start the stack |
| `make backend-test` | Run backend tests |
| `make client-test` | Run Flutter tests |
| `make tests` | Run backend lint/tests and frontend analyze/tests |
| `make clean` | Remove generated caches and build artifacts |
| `make deps` | Sync backend and frontend dependencies |
| `make refresh` | Run `make clean` and then `make deps` |
| `make install-git-hooks` | Enable automatic one-commit version sync hooks locally |
| `make version-sync` | Rebuild synced version files and generated release notes |
| `make version-check` | Fail if manifests and changelog drifted from commit history |
| `make docker-up` | Start the Docker stack |
| `make docker-seeddb` | Drop and reseed the Docker Postgres database |
| `make release` | Build the minimal release bundle in `dist/release.zip` |

Run `make help` for the full command list.

## Docker Deployment

OpsAtlas ships a Compose-based deployment with separate `db`, `filestorage`,
`backend`, `web`, and optional `seeddb` services.

Quick start:

```bash
cp .env.docker.example .env.docker
make docker-up
```

Seeded Docker demo data:

```bash
make docker-seeddb
```

Deployment details live in [docs/deployment/docker-compose.md](docs/deployment/docker-compose.md).

## Release Bundle

Build the portable release artifact with:

```bash
make release
```

That produces `dist/release.zip` with this top-level layout:

```text
backend/
client/
compose.yaml
docker/
opsatlas-source.zip
USAGE.md
.env.example
.env.docker.example
LICENSE
LICENSES/
REUSE.toml
```

The extracted outer bundle is immediately runnable. It includes the sanitized
`backend/` and `client/` sources in place, a root-level Compose file, root
`.env.example` and `.env.docker.example` templates, Docker helper files, and a
nested `opsatlas-source.zip` copy of the same runtime source bundle.

Deploy it by extracting `release.zip`, then either copying `.env.example` to
`.env` or copying `.env.docker.example` to `.env.docker` and editing it. The
`.env.docker.example` template already pins `OPSATLAS_ENV_FILE=.env.docker` so
runtime bootstrap and Compose stay aligned.

If you use `.env`, run from the extracted root:

```bash
docker compose up --build -d
```

If you use `.env.docker`, run:

```bash
docker compose --env-file .env.docker up --build -d
```

If `.env` is missing, OpsAtlas creates it automatically on first run and
generates random database and application secrets.

## Versioning

OpsAtlas now uses commit-driven `MAJOR.MINOR.PATCH` versioning. Breaking
changes bump the first number, `feat:` commits bump the second, and other
allowed commit types bump the third. The Flutter build number increments on
every synchronized commit.

Versioning rules, changelog ownership, and release discipline are documented in
[docs/project/versioning.md](docs/project/versioning.md).

Every successful push to `main` now publishes or updates a GitHub release from
the final `Product CI` workflow once all required jobs pass. The tag and title
match the synchronized repository version and the asset is the generated
`dist/release.zip` bundle.

## Documentation

- [docs/README.md](docs/README.md): documentation index
- [docs/development/getting-started.md](docs/development/getting-started.md):
  first-run developer guide
- [docs/deployment/docker-compose.md](docs/deployment/docker-compose.md):
  Docker deployment and release-bundle usage
- [docs/development/github-security.md](docs/development/github-security.md):
  GitHub Actions security automation, CodeQL setup, and code scanning guidance
- [docs/development/ios.md](docs/development/ios.md): developer-only iOS target
  setup
- [docs/architecture/backend.md](docs/architecture/backend.md): backend module
  and service architecture
- [docs/architecture/frontend.md](docs/architecture/frontend.md): Flutter app
  structure, routing, and UI conventions
- [docs/architecture/data-model.md](docs/architecture/data-model.md): domain
  model and ownership boundaries
- [docs/reference/api.md](docs/reference/api.md): backend endpoint guide
- [docs/reference/ui.md](docs/reference/ui.md): client route and navigation
  guide
- [docs/project/versioning.md](docs/project/versioning.md): automated semantic
  versioning and changelog policy
- [CHANGELOG.md](CHANGELOG.md): shipped work in chronological order
- [docs/project/roadmap.md](docs/project/roadmap.md): detailed forward-looking
  feature roadmap
- [docs/project/codebase-audit.md](docs/project/codebase-audit.md): current
  maintenance audit

## Quality And Security

Local validation:

```bash
make tests
reuse lint
```

Repository automation is split across two workflows:

- `.github/workflows/ci.yml`
  Backend lint/tests, frontend analyze/tests, security tooling, and DAST smoke
  checks.
- `.github/workflows/github-native.yml`
  Dependency Review, CodeQL, and OpenSSF Scorecard.
- `.github/workflows/release.yml`
  Provides a manual fallback for republishing the tagged GitHub release bundle
  from a trusted `main` checkout when needed.

GitHub code scanning should use the committed advanced workflow, not GitHub's
default setup. Default setup currently mis-detects the developer-only iOS host
project and creates failing Ruby/Swift jobs that do not reflect the supported
release surface. See
[docs/development/github-security.md](docs/development/github-security.md).

Security reporting instructions live in [.github/SECURITY.md](.github/SECURITY.md).

## Contributing

Contribution guidelines live in [.github/CONTRIBUTING.md](.github/CONTRIBUTING.md).
Please also review the [Code of Conduct](.github/CODE_OF_CONDUCT.md).

## License

OpsAtlas is licensed under `GPL-3.0-only`. See [LICENSE](LICENSE) and the
license texts in [LICENSES](LICENSES).
