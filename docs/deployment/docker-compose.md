<!-- SPDX-FileCopyrightText: 2026 Bora Yarkın -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Docker Deployment

OpsAtlas ships a Docker Compose stack with separate containers for:

- `db`: PostgreSQL
- `filestorage`: Docker-managed persistent instance storage
- `backend`: FastAPI API runtime
- `web`: Flutter web build served by Nginx
- `seeddb`: optional one-shot demo-data seeding job

Persistent data lives in Docker named volumes:

- `opsatlas_postgres_data`
- `opsatlas_instance_data`

The Docker deployment always uses the PostgreSQL `db` service plus separate
`backend`, `web`, and `filestorage` containers. Docker deployments do not use
SQLite, even if other local development flows do.

OpsAtlas keeps `PGDATA=/var/lib/postgresql/data` explicitly in Compose even
when `postgres:latest` resolves to PostgreSQL 18+. That preserves compatibility
with existing named volumes created by earlier release bundles instead of
forcing an immediate PostgreSQL 18 volume-layout migration.

## Quick Start

1. Copy the Docker env template.

```bash
cp .env.docker.example .env.docker
```

2. Edit at least these values in `.env.docker`:

- `OPSATLAS_DB_PASSWORD`
- `JWT_SECRET`
- `SECRET_ENCRYPTION_KEYS`
- `OPSATLAS_PUBLIC_API_BASE_URL`
- `CORS_ORIGINS`
- `TRUSTED_HOSTS`

3. Start the stack.

```bash
docker compose --env-file .env.docker up --build -d
```

4. Open the services:

- Web UI: `http://localhost:3000`
- API health: `http://localhost:8000/health`

The backend waits for PostgreSQL, runs `scripts/init_db.py`, refreshes the
built-in localization bundles, and then starts Uvicorn.

## Demo Data

`seeddb` is a one-shot persistent demo-data seeder. It writes into PostgreSQL
once, exits, and leaves the data in the Docker volumes. Restarts keep that data
until you explicitly remove the volumes.

```bash
docker compose --env-file .env.docker up -d db filestorage
docker compose --env-file .env.docker run --rm --build seeddb
```

If you want the whole seeded stack in one repo command, use:

```bash
make docker-up-seeded
```

Demo credentials after seeding:

- `admin@admin.com` / `admin`
- `moderator@moderator.com` / `moderator`
- `member@member.com` / `member`
- `viewer@viewer.com` / `viewer`

## Persistence And Reset

Stop containers but keep persistent data:

```bash
docker compose --env-file .env.docker down
```

Stop containers and remove persistent data volumes:

```bash
docker compose --env-file .env.docker down -v
```

That is the destructive reset path for Docker data persistence.

View logs:

```bash
docker compose --env-file .env.docker logs -f backend web db
```

Run localization bundle refresh inside a one-shot backend container:

```bash
docker compose --env-file .env.docker run --rm backend reset-localization
```

## Release Bundle

Build the portable deployment bundle with:

```bash
make release
```

That creates `dist/release.zip` with this layout:

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

The extracted outer release bundle is immediately runnable. It includes the
sanitized backend and frontend runtime sources in place, a root-level Compose
file, root `.env.example` and `.env.docker.example` templates, Docker helper
files, and a nested `opsatlas-source.zip` copy of the same runtime source
bundle.

Recommended deployment flow from the bundle:

1. Extract `release.zip` on the target machine.
2. Either copy `.env.example` to `.env`, or copy `.env.docker.example` to
  `.env.docker`. The `.env.docker.example` template already sets
  `OPSATLAS_ENV_FILE=.env.docker` so runtime bootstrap and Compose stay on the
  same env file.
3. Run `docker compose up --build -d`

If you keep your release settings in `.env.docker`, use:

```bash
docker compose --env-file .env.docker up --build -d
```

If `.env` is missing, OpsAtlas creates it automatically on first run and
generates random database and application secrets.

If `.env` is absent but `.env.docker` exists, the backend bootstrap still uses
`.env.docker` for runtime settings such as `TRUSTED_HOSTS`. Use
`--env-file .env.docker` whenever you also need Compose-level interpolation,
such as port mappings or the web build's `OPSATLAS_PUBLIC_API_BASE_URL`, to
come from that file.

If placeholder secrets remain in the env file, the release bootstrap reuses the
previously generated secrets from the persistent bootstrap volume. That avoids
unexpected PostgreSQL password drift across restarts or env-file switches while
the database volume is still in use.

If you want seeded demo data from the release bundle, run:

```bash
docker compose run --rm --build seeddb
```

If you keep your release settings in `.env.docker`, use:

```bash
docker compose --env-file .env.docker run --rm --build seeddb
```

`seeddb` only seeds PostgreSQL and exits. It does not keep the API or web
containers running. After the seed step finishes, start the long-running stack
with:

```bash
docker compose up --build -d backend web db filestorage
```

If you want the full seeded flow from a fresh release bundle, run these two
commands in order:

```bash
docker compose run --rm --build seeddb
docker compose up --build -d backend web db filestorage
```

The extracted bundle still needs network access to pull its first-run base
images. If Docker fails before the seed job starts with a registry error such
as `TLS handshake timeout`, the problem is upstream image retrieval rather than
OpsAtlas itself. For the seeded demo-data path, retry the required pulls
separately and then rerun the seed command:

```bash
docker pull python:3.14
docker pull postgres:latest
docker pull debian:latest
docker compose run --rm --build seeddb
docker compose up --build -d backend web db filestorage
```

For a full release-bundle startup with `docker compose up --build -d`, Docker
also needs the current Flutter builder and web runtime bases:

```bash
docker pull ghcr.io/cirruslabs/flutter:stable
docker pull nginx:latest
```

If timeouts persist, restart Docker Desktop and check proxy, VPN, firewall, or
registry-mirror settings before retrying.

If `postgres:latest` starts failing with an error about PostgreSQL 18+ wanting
`/var/lib/postgresql` while data exists in `/var/lib/postgresql/data`, the
bundle is missing the explicit `PGDATA=/var/lib/postgresql/data` setting.
Update the bundle or add that variable under the `db` service before retrying.

If `seeddb` or `backend` exits with `ModuleNotFoundError: No module named
'sqlalchemy'`, the backend container is launching the system interpreter
instead of the image's synced virtualenv. Use a release bundle that includes
the backend Dockerfile `PATH` fix for `/srv/opsatlas/backend/.venv/bin` before
retrying.

If the backend reaches PostgreSQL but fails with `password authentication failed
for user "opsatlas"`, the env file password no longer matches the password
stored in the persistent PostgreSQL volume. Updated release bundles reuse the
existing generated bootstrap secrets automatically while placeholders remain.
If you already forced a new explicit password, either restore the original
`OPSATLAS_DB_PASSWORD` or reset Docker volumes with `docker compose down -v`.

`--rm` only removes the finished seed container. Persistent PostgreSQL and file
storage data remain until you run `docker compose down -v` or remove the named
volumes directly.

The deployment machine does not need the repository `Makefile`, host-side
extraction scripts, or the original full source tree.

## Configuration Notes

- `OPSATLAS_PUBLIC_API_BASE_URL` is compiled into the Flutter web image. Change
  it before building the `web` image.
- The backend automatically trusts the hostname from
  `OPSATLAS_PUBLIC_API_BASE_URL`. Keep `TRUSTED_HOSTS` for any extra hostnames.
- `AUTH_COOKIE_SECURE=false` in the example file is only for local HTTP usage.
  Turn it on for HTTPS deployments.
- `filestorage` is intentionally separate because media storage is still
  filesystem-backed.

## Longer-Term Direction

The release bundle is now slimmed down, but deployments still build images from
source on the target host. The cleaner long-term path is to publish immutable
backend and web images per tagged release and deploy by image tag instead of by
source bundle.
