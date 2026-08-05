<!-- SPDX-FileCopyrightText: 2026 Bora Yarkın -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# OpsAtlas Release Bundle

This file becomes `USAGE.md` in the outer portable release bundle.

Expected extracted layout:

```text
release/
  backend/
  client/
  compose.yaml
  docker/
    backend/
      Dockerfile
    web/
      Dockerfile
      nginx.conf
    release/
      bootstrap_env.py
  opsatlas-source.zip
  USAGE.md
  .env.example
  .env.docker.example
  LICENSE
  LICENSES/
  REUSE.toml
```

## Usage

1. Extract `release.zip` on the deployment machine.
2. Choose one env-file style:

   - copy `.env.example` to `.env` for the default `docker compose ...` flow
   - or copy `.env.docker.example` to `.env.docker` for the explicit
  `docker compose --env-file .env.docker ...` flow; this template already
  pins `OPSATLAS_ENV_FILE=.env.docker` so runtime bootstrap and Compose use
  the same file
3. Start the stack from the extracted root:

```bash
docker compose up --build -d
```

If you keep settings in `.env.docker`, use:

```bash
docker compose --env-file .env.docker up --build -d
```

Optional one-shot demo-data seeding:

```bash
docker compose run --rm --build seeddb
```

`seeddb` is only the seeding step. It does not leave the API or web containers
running. Start the long-running stack after seeding with:

```bash
docker compose up --build -d backend web db filestorage
```

For a seeded release-bundle startup from scratch, run:

```bash
docker compose run --rm --build seeddb
docker compose up --build -d backend web db filestorage
```

For the `.env.docker` flow, use the same commands with `--env-file`:

```bash
docker compose --env-file .env.docker run --rm --build seeddb
docker compose --env-file .env.docker up --build -d backend web db filestorage
```

If `.env` is missing, OpsAtlas creates it automatically on first run and
generates random database and application secrets.

If `.env` is absent but `.env.docker` exists, the backend bootstrap will still
pick up `.env.docker` for runtime settings such as `TRUSTED_HOSTS`. Use
`--env-file .env.docker` when you also want Compose-level settings such as port
bindings and web build args to come from that file.

If you keep placeholder secrets in the env file, the release bootstrap reuses
the previously generated values from the persistent bootstrap volume instead of
silently rotating the database password on restart.

`seeddb` is a one-shot persistent seeder. It writes the demo data into
PostgreSQL, exits, and the `--rm` flag removes the seed container while the
seeded data remains in Docker volumes.

Useful Docker Compose commands:

- `docker compose up --build -d`
- `docker compose --env-file .env.docker up --build -d`
- `docker compose run --rm --build seeddb`
- `docker compose --env-file .env.docker run --rm --build seeddb`
- `docker compose up --build -d backend web db filestorage`
- `docker compose --env-file .env.docker up --build -d backend web db filestorage`
- `docker compose down`
- `docker compose down -v`
- `docker compose logs -f backend web db`
- `docker compose run --rm backend reset-localization`

## Why This Layout Exists

- `opsatlas-source.zip` keeps the sanitized source archive portable and easy to
  swap or attach to GitHub releases.
- `backend/` and `client/` are already extracted in the outer bundle so the
  deployment is runnable immediately after extraction.
- `compose.yaml`, `.env.example`, and `.env.docker.example` live in the root so
  the operator never has to move into a nested folder just to deploy.
- `docker/` keeps the build helpers and first-run bootstrap script in one place
  without hiding the main deploy files.
- License material is shipped alongside the runtime sources.

The release bundle intentionally excludes repo-only content such as CI files,
tests, local runtime state, caches, and developer-only mobile targets.
