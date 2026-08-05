# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

SHELL := /bin/bash

# -----------------------------------------------------------------------------
# OpsAtlas Makefile — all configuration is read from backend/instance/.env.
#
# Primary targets:
#   make opsatlas [nochrome] [seeddb] [nondev]
#   make opsatlas-stop
#   make tests / test-backend / test-frontend
#   make api / api-rev m="message" / api-migrate / seed-db
#   make purge-localization-cache
#   make flutter-web
#   make clean / make deps / make refresh
# -----------------------------------------------------------------------------

BACKEND_DIR := backend
CLIENT_DIR  := client
CLIENT_NEW_DIR := client_new
BACKEND_VENV_DIR := $(BACKEND_DIR)/.venv
BACKEND_VENV_PY := $(BACKEND_VENV_DIR)/bin/python
BACKEND_PYTHON := $(abspath $(BACKEND_VENV_PY))
CLIENT_NEW_VENV_DIR := $(CLIENT_NEW_DIR)/.venv
CLIENT_NEW_VENV_PY := $(CLIENT_NEW_VENV_DIR)/bin/python
CLIENT_NEW_PYTHON := $(abspath $(CLIENT_NEW_VENV_PY))
_ENV_FILE   := $(BACKEND_DIR)/instance/.env
_ENV_FALLBACK := $(BACKEND_DIR)/.env.example
DOCKER_COMPOSE ?= docker compose
DOCKER_ENV_FILE ?= .env.docker
DIST_DIR ?= dist
RELEASE_STAGE_DIR := $(DIST_DIR)/release
RELEASE_SOURCE_STAGE_DIR := $(DIST_DIR)/release-source
RELEASE_OUTER_ZIP := $(DIST_DIR)/release.zip
RELEASE_SOURCE_ZIP_NAME := opsatlas-source.zip

# Read a key from .env (fallback to .env.example).
_env = $(strip $(shell \
	if [ -f "$(_ENV_FILE)" ]; then \
		sed -nE 's/^$(1)=(.*)$$/\1/p' "$(_ENV_FILE)" | head -n1; \
	elif [ -f "$(_ENV_FALLBACK)" ]; then \
		sed -nE 's/^$(1)=(.*)$$/\1/p' "$(_ENV_FALLBACK)" | head -n1; \
	fi))

# Resolved configuration from .env.
_API_PORT      := $(or $(call _env,API_PORT),8000)
_WEB_PORT      := $(or $(call _env,WEB_PORT),3000)
_DEVICE        := $(or $(call _env,FLUTTER_DEVICE),chrome)
_HOST          := $(or $(call _env,FLUTTER_HOST),localhost)
_BUILD_MODE    := $(or $(call _env,FLUTTER_BUILD_MODE),auto)
_RENDERER      := $(or $(call _env,FLUTTER_WEB_RENDERER),auto)

# Flag targets consumed by `opsatlas`.
OPSATLAS_FLAGS := $(filter nochrome seeddb nondev js,$(MAKECMDGOALS))

.PHONY: help cleanup clean refresh deps \
	backend backend-venv backend-deps deps-backend deps-frontend dependencies \
	client-new-venv client-new-server \
	backend-lint backend-test test-backend client-analyze client-test test-frontend tests check \
	install-git-hooks version-sync version-check \
	api api-rev api-migrate seed-db seeddb purge-localization-cache flutter-web \
	opsatlas opsatlas-stop nochrome nondev js \
	docker-check-env docker-up docker-up-seeded docker-down docker-logs docker-initdb docker-seeddb docker-reset-localization \
	release release-clean

# --- help --------------------------------------------------------------------

help:
	@echo "OpsAtlas Makefile — all config from backend/instance/.env"
	@echo ""
	@echo "  make opsatlas [nochrome] [seeddb] [nondev]"
	@echo "  make opsatlas js                   Start backend + pure JS prototype client"
	@echo "  make opsatlas-stop"
	@echo "  make deps-backend                 Create/reuse backend .venv + sync deps"
	@echo "  make dependencies                 Sync backend + frontend deps"
	@echo "  make backend                      Start backend only"
	@echo "  make api                          Start backend only"
	@echo "  make api-rev m=\"message\"           Alembic autogenerate"
	@echo "  make api-migrate                  Alembic upgrade head"
	@echo "  make seed-db                      Drop and reseed database"
	@echo "  make purge-localization-cache     Refresh built-in DB language bundles"
	@echo "  make flutter-web                  Start Flutter web only"
	@echo "  make docker-up                    Build and start the Docker stack"
	@echo "  make docker-up-seeded             Seed Postgres once persistently, then start the Docker stack"
	@echo "  make docker-down                  Stop the Docker stack"
	@echo "  make docker-logs                  Tail Docker stack logs"
	@echo "  make docker-initdb                Run explicit Docker DB bootstrap"
	@echo "  make docker-seeddb                Run one-shot persistent demo seeding in Docker"
	@echo "  make docker-reset-localization    Refresh built-in bundles in Docker"
	@echo "  make release                      Build a minimal Docker-native dist/release.zip bundle"
	@echo "  make tests                        Backend + frontend"
	@echo "  make check                        Alias for tests"
	@echo "  make install-git-hooks            Set core.hooksPath to .githooks"
	@echo "  make version-sync                 Regenerate version files and release notes"
	@echo "  make version-check                Verify version files and release notes are in sync"
	@echo "  make backend-lint                 Ruff backend code and tests"
	@echo "  make backend-test                 Pytest backend suite"
	@echo "  make test-backend                 backend-lint + backend-test"
	@echo "  make client-analyze               Flutter static analysis"
	@echo "  make client-test                  Flutter test suite"
	@echo "  make test-frontend                client-analyze + client-test"
	@echo "  make clean                        Remove caches / build artifacts"
	@echo "  make cleanup                      Alias for clean"
	@echo "  make deps                         Sync backend + frontend deps"
	@echo "  make refresh                      clean + deps"

# --- cleanup -----------------------------------------------------------------

clean:
	@echo "[clean] Removing caches and build artifacts..."
	@find . -type d \( -name "__pycache__" -o -name ".pytest_cache" -o -name ".ruff_cache" -o -name ".mypy_cache" \) -prune -exec rm -rf {} +
	@find . -type f \( -name "*.pyc" -o -name "*.pyo" -o -name "*.pyd" -o -name ".coverage" -o -name ".DS_Store" \) -delete
	@rm -rf "$(CLIENT_DIR)/.dart_tool" "$(CLIENT_DIR)/build"
	@rm -f "$(CLIENT_DIR)/.flutter-plugins" "$(CLIENT_DIR)/.flutter-plugins-dependencies" "$(CLIENT_DIR)/.packages"
	@echo "[clean] Done."

cleanup: clean

refresh: clean dependencies

# --- dependencies ------------------------------------------------------------

backend-venv:
	@set -euo pipefail; \
	if [ -x "$(BACKEND_PYTHON)" ] && "$(BACKEND_PYTHON)" -c 'import sys' >/dev/null 2>&1; then \
		exit 0; \
	fi; \
	if command -v python3 >/dev/null 2>&1; then \
		HOST_PYTHON="python3"; \
	elif command -v python >/dev/null 2>&1; then \
		HOST_PYTHON="python"; \
	else \
		echo "[make] ERROR: python3/python not found in PATH"; \
		exit 1; \
	fi; \
	echo "[backend] Creating virtual environment at $(abspath $(BACKEND_VENV_DIR))..."; \
	"$$HOST_PYTHON" -m venv "$(abspath $(BACKEND_VENV_DIR))"

backend-deps: backend-venv
	@set -euo pipefail; \
	cd "$(BACKEND_DIR)" && \
	"$(BACKEND_PYTHON)" -m pip install --upgrade pip && \
	"$(BACKEND_PYTHON)" -m pip install --upgrade -e ".[dev]"

deps-backend: backend-deps

deps-frontend:
	@echo "[deps-frontend] Running flutter pub get..."
	@cd "$(CLIENT_DIR)" && flutter pub get

dependencies: backend-deps deps-frontend

deps: dependencies

client-new-venv:
	@set -euo pipefail; \
	if [ -x "$(CLIENT_NEW_PYTHON)" ] && "$(CLIENT_NEW_PYTHON)" -c 'import sys' >/dev/null 2>&1; then \
		exit 0; \
	fi; \
	if command -v python3 >/dev/null 2>&1; then \
		HOST_PYTHON="python3"; \
	elif command -v python >/dev/null 2>&1; then \
		HOST_PYTHON="python"; \
	else \
		echo "[client-new] ERROR: python3/python not found in PATH"; \
		exit 1; \
	fi; \
	echo "[client-new] Creating virtual environment at $(abspath $(CLIENT_NEW_VENV_DIR))..."; \
	"$$HOST_PYTHON" -m venv "$(abspath $(CLIENT_NEW_VENV_DIR))"

client-new-server: client-new-venv
	@set -euo pipefail; \
	OPSATLAS_API_BASE_URL="http://localhost:$(_API_PORT)" \
	OPSATLAS_WEB_HOST="$(_HOST)" \
	OPSATLAS_WEB_PORT="$(_WEB_PORT)" \
	"$(CLIENT_NEW_PYTHON)" "$(CLIENT_NEW_DIR)/server.py" --host "$(_HOST)" --port "$(_WEB_PORT)"

# --- versioning --------------------------------------------------------------

install-git-hooks:
	@git config core.hooksPath .githooks
	@chmod +x .githooks/prepare-commit-msg .githooks/commit-msg .githooks/post-commit
	@echo "[versioning] Git hooks enabled from .githooks/"

version-sync:
	@python3 tools/versioning.py sync

version-check:
	@python3 tools/versioning.py verify

# --- docker ------------------------------------------------------------------

docker-check-env:
	@if [ ! -f "$(DOCKER_ENV_FILE)" ]; then \
		echo "[docker] Missing $(DOCKER_ENV_FILE). Copy .env.docker.example first."; \
		exit 1; \
	fi

docker-up: docker-check-env
	@OPSATLAS_ENV_FILE="$(DOCKER_ENV_FILE)" $(DOCKER_COMPOSE) --env-file "$(DOCKER_ENV_FILE)" up --build -d

docker-up-seeded: docker-check-env
	@$(MAKE) --no-print-directory docker-seeddb DOCKER_COMPOSE="$(DOCKER_COMPOSE)" DOCKER_ENV_FILE="$(DOCKER_ENV_FILE)"
	@OPSATLAS_ENV_FILE="$(DOCKER_ENV_FILE)" $(DOCKER_COMPOSE) --env-file "$(DOCKER_ENV_FILE)" up --build -d backend web db filestorage

docker-down: docker-check-env
	@OPSATLAS_ENV_FILE="$(DOCKER_ENV_FILE)" $(DOCKER_COMPOSE) --env-file "$(DOCKER_ENV_FILE)" down

docker-logs: docker-check-env
	@OPSATLAS_ENV_FILE="$(DOCKER_ENV_FILE)" $(DOCKER_COMPOSE) --env-file "$(DOCKER_ENV_FILE)" logs -f --tail=200

docker-initdb: docker-check-env
	@OPSATLAS_ENV_FILE="$(DOCKER_ENV_FILE)" $(DOCKER_COMPOSE) --env-file "$(DOCKER_ENV_FILE)" up -d db filestorage
	@OPSATLAS_ENV_FILE="$(DOCKER_ENV_FILE)" $(DOCKER_COMPOSE) --env-file "$(DOCKER_ENV_FILE)" run --rm backend initdb

docker-seeddb: docker-check-env
	@OPSATLAS_ENV_FILE="$(DOCKER_ENV_FILE)" $(DOCKER_COMPOSE) --env-file "$(DOCKER_ENV_FILE)" up -d db filestorage
	@OPSATLAS_ENV_FILE="$(DOCKER_ENV_FILE)" $(DOCKER_COMPOSE) --env-file "$(DOCKER_ENV_FILE)" run --rm --build seeddb

docker-reset-localization: docker-check-env
	@OPSATLAS_ENV_FILE="$(DOCKER_ENV_FILE)" $(DOCKER_COMPOSE) --env-file "$(DOCKER_ENV_FILE)" up -d db filestorage
	@OPSATLAS_ENV_FILE="$(DOCKER_ENV_FILE)" $(DOCKER_COMPOSE) --env-file "$(DOCKER_ENV_FILE)" run --rm backend reset-localization

# --- release -----------------------------------------------------------------

release-clean:
	@rm -rf "$(RELEASE_STAGE_DIR)" "$(RELEASE_SOURCE_STAGE_DIR)" "$(RELEASE_OUTER_ZIP)"

release: release-clean
	@set -euo pipefail; \
	if ! command -v rsync >/dev/null 2>&1; then \
		echo "[release] ERROR: rsync is required"; \
		exit 1; \
	fi; \
	if ! command -v zip >/dev/null 2>&1; then \
		echo "[release] ERROR: zip is required"; \
		exit 1; \
	fi; \
	cleanup_release_stage() { \
		rm -rf "$(RELEASE_STAGE_DIR)" "$(RELEASE_SOURCE_STAGE_DIR)"; \
	}; \
	trap cleanup_release_stage EXIT; \
	mkdir -p \
		"$(RELEASE_SOURCE_STAGE_DIR)/backend" \
		"$(RELEASE_SOURCE_STAGE_DIR)/client" \
		"$(RELEASE_STAGE_DIR)/backend" \
		"$(RELEASE_STAGE_DIR)/client" \
		"$(RELEASE_STAGE_DIR)/docker/backend" \
		"$(RELEASE_STAGE_DIR)/docker/web" \
		"$(RELEASE_STAGE_DIR)/docker/release"; \
	echo "[release] Staging backend runtime source..."; \
	rsync -a \
		--exclude '.coverage' \
		--exclude '.DS_Store' \
		--exclude '.env' \
		--exclude '.venv/' \
		--exclude '.pytest_cache/' \
		--exclude '.ruff_cache/' \
		--exclude 'OpsAtlas_backend.egg-info/' \
		--exclude 'instance/' \
		--exclude 'tests/' \
		--exclude 'pyrightconfig.json' \
		--exclude '__pycache__/' \
		--exclude '*.pyc' \
		--exclude '*.pyo' \
		"$(BACKEND_DIR)/" "$(RELEASE_SOURCE_STAGE_DIR)/backend/"; \
	echo "[release] Staging frontend runtime source..."; \
	rsync -a \
		--exclude '.dart_tool/' \
		--exclude '.DS_Store' \
		--exclude '.flutter-plugins' \
		--exclude '.flutter-plugins-dependencies' \
		--exclude '.idea/' \
		--exclude '.gitignore' \
		--exclude 'README.md' \
		--exclude 'build/' \
		--exclude 'coverage/' \
		--exclude 'flutter_*.log' \
		--exclude 'ios/' \
		--exclude 'opsatlas_client.iml' \
		--exclude 'test/' \
		"$(CLIENT_DIR)/" "$(RELEASE_SOURCE_STAGE_DIR)/client/"; \
	echo "[release] Copying license material..."; \
	cp LICENSE "$(RELEASE_STAGE_DIR)/LICENSE"; \
	cp REUSE.toml "$(RELEASE_STAGE_DIR)/REUSE.toml"; \
	cp -R LICENSES "$(RELEASE_STAGE_DIR)/LICENSES"; \
	cp LICENSE "$(RELEASE_SOURCE_STAGE_DIR)/LICENSE"; \
	cp REUSE.toml "$(RELEASE_SOURCE_STAGE_DIR)/REUSE.toml"; \
	cp -R LICENSES "$(RELEASE_SOURCE_STAGE_DIR)/LICENSES"; \
	rsync -a "$(RELEASE_SOURCE_STAGE_DIR)/backend/" "$(RELEASE_STAGE_DIR)/backend/"; \
	rsync -a "$(RELEASE_SOURCE_STAGE_DIR)/client/" "$(RELEASE_STAGE_DIR)/client/"; \
	find "$(RELEASE_SOURCE_STAGE_DIR)" -name '.DS_Store' -delete; \
	find "$(RELEASE_STAGE_DIR)" -name '.DS_Store' -delete; \
	echo "[release] Writing nested source archive..."; \
	(cd "$(RELEASE_SOURCE_STAGE_DIR)" && zip -qr "$(abspath $(RELEASE_STAGE_DIR))/$(RELEASE_SOURCE_ZIP_NAME)" backend client LICENSE LICENSES REUSE.toml); \
	echo "[release] Copying root deployment files and usage guide..."; \
	cp docker/release/README.md "$(RELEASE_STAGE_DIR)/USAGE.md"; \
	cp compose.yaml "$(RELEASE_STAGE_DIR)/compose.yaml"; \
	cp docker/release/env.example "$(RELEASE_STAGE_DIR)/.env.example"; \
	cp docker/release/env.docker.example "$(RELEASE_STAGE_DIR)/.env.docker.example"; \
	cp docker/backend/Dockerfile "$(RELEASE_STAGE_DIR)/docker/backend/Dockerfile"; \
	cp docker/web/Dockerfile "$(RELEASE_STAGE_DIR)/docker/web/Dockerfile"; \
	cp docker/web/nginx.conf "$(RELEASE_STAGE_DIR)/docker/web/nginx.conf"; \
	cp docker/release/bootstrap_env.py "$(RELEASE_STAGE_DIR)/docker/release/bootstrap_env.py"; \
	cp .dockerignore "$(RELEASE_STAGE_DIR)/.dockerignore"; \
	find "$(RELEASE_STAGE_DIR)" -name '.DS_Store' -delete; \
	echo "[release] Writing outer release archive..."; \
	(cd "$(RELEASE_STAGE_DIR)" && zip -qr "$(abspath $(RELEASE_OUTER_ZIP))" backend client docker compose.yaml .env.example .env.docker.example .dockerignore "$(RELEASE_SOURCE_ZIP_NAME)" USAGE.md LICENSE LICENSES REUSE.toml); \
	echo "[release] Created $(RELEASE_OUTER_ZIP)"

# --- tests -------------------------------------------------------------------

backend-lint: backend-deps
	@set -euo pipefail; \
	echo "[test-backend] Linting..."; \
	(cd "$(BACKEND_DIR)" && "$(BACKEND_PYTHON)" -m ruff check app scripts tests)

backend-test: backend-deps
	@set -euo pipefail; \
	echo "[test-backend] Running pytest..."; \
	(cd "$(BACKEND_DIR)" && "$(BACKEND_PYTHON)" -m pytest tests)

test-backend: backend-lint backend-test

client-analyze:
	@set -euo pipefail; \
	cd "$(CLIENT_DIR)" && flutter pub get && flutter analyze

client-test:
	@set -euo pipefail; \
	cd "$(CLIENT_DIR)" && flutter pub get && flutter test test

test-frontend: client-analyze client-test

tests:
	@$(MAKE) --no-print-directory test-backend
	@$(MAKE) --no-print-directory test-frontend

check: tests

# --- backend -----------------------------------------------------------------

backend: api

api: backend-deps
	@set -euo pipefail; \
	cd "$(BACKEND_DIR)" && "$(BACKEND_PYTHON)" -m uvicorn app.main:app --reload --port "$(_API_PORT)"

api-rev: backend-deps
	@set -euo pipefail; \
	cd "$(BACKEND_DIR)" && "$(BACKEND_PYTHON)" -m alembic revision --autogenerate -m "$(m)"

api-migrate: backend-deps
	@set -euo pipefail; \
	cd "$(BACKEND_DIR)" && "$(BACKEND_PYTHON)" -m alembic upgrade head

seed-db: backend-deps
	@set -euo pipefail; \
	cd "$(BACKEND_DIR)" && "$(BACKEND_PYTHON)" scripts/seed_db.py --reset

purge-localization-cache: backend-deps
	@set -euo pipefail; \
	cd "$(BACKEND_DIR)" && "$(BACKEND_PYTHON)" scripts/reset_localization_bundles.py

# --- flutter -----------------------------------------------------------------

flutter-web:
	@cd "$(CLIENT_DIR)" && flutter run -d chrome \
		--web-port "$(_WEB_PORT)" \
		$(if $(filter auto,$(_RENDERER)),,--web-renderer "$(_RENDERER)") \
		--dart-define=API_BASE_URL="http://localhost:$(_API_PORT)"

# --- opsatlas (full dev stack) -----------------------------------------------

opsatlas: backend-deps
	@set -euo pipefail; \
	DEVICE="$(_DEVICE)"; HOST="$(_HOST)"; \
	API_PORT="$(_API_PORT)"; WEB_PORT="$(_WEB_PORT)"; \
	BUILD_MODE="$$(printf '%s' '$(_BUILD_MODE)' | tr '[:upper:]' '[:lower:]')"; \
	RENDERER="$$(printf '%s' '$(_RENDERER)' | tr '[:upper:]' '[:lower:]')"; \
	BACKEND_RELOAD=1; SEED_DB=0; JS_CLIENT=0; \
	for flag in $(OPSATLAS_FLAGS); do \
		case "$$flag" in \
			nochrome) DEVICE="web-server" ;; \
			seeddb)   SEED_DB=1 ;; \
			nondev)   BACKEND_RELOAD=0; case "$$BUILD_MODE" in auto|debug) BUILD_MODE="profile" ;; esac ;; \
			js)       JS_CLIENT=1; DEVICE="web-server" ;; \
		esac; \
	done; \
	if [ "$$SEED_DB" = "1" ]; then \
		echo "[opsatlas] Seeding database..."; \
		(cd "$(BACKEND_DIR)" && "$(BACKEND_PYTHON)" scripts/seed_db.py --reset); \
	fi; \
	stop_pid() { \
		local p="$${1:-}"; [ -z "$$p" ] && return; \
		kill -TERM "$$p" 2>/dev/null || true; \
		for _ in {1..10}; do kill -0 "$$p" 2>/dev/null || return 0; sleep 0.2; done; \
		kill -KILL "$$p" 2>/dev/null || true; \
	}; \
	BACKEND_PID=""; \
	trap 'set +e; stop_pid "$$BACKEND_PID"; wait "$$BACKEND_PID" 2>/dev/null || true' EXIT INT TERM; \
	if lsof -nP -iTCP:$$API_PORT -sTCP:LISTEN >/dev/null 2>&1; then \
		for pid in $$(lsof -tiTCP:$$API_PORT -sTCP:LISTEN 2>/dev/null || true); do \
			if ps -o command= -p "$$pid" 2>/dev/null | grep -Eq 'uvicorn.*app\.main:app'; then \
				echo "[opsatlas] Restarting existing backend (pid $$pid)..."; \
				stop_pid "$$pid"; \
			fi; \
		done; \
	fi; \
	if ! lsof -nP -iTCP:$$API_PORT -sTCP:LISTEN >/dev/null 2>&1; then \
		echo "[opsatlas] Starting backend on :$$API_PORT..."; \
		if [ "$$BACKEND_RELOAD" = "1" ]; then \
			(cd "$(BACKEND_DIR)" && exec "$(BACKEND_PYTHON)" -m uvicorn app.main:app --reload --reload-dir app --reload-dir scripts --port "$$API_PORT") & \
		else \
			(cd "$(BACKEND_DIR)" && exec "$(BACKEND_PYTHON)" -m uvicorn app.main:app --port "$$API_PORT") & \
		fi; \
		BACKEND_PID=$$!; \
	else \
		echo "[opsatlas] Port $$API_PORT already in use; keeping existing listener."; \
	fi; \
	if [ "$$JS_CLIENT" = "1" ]; then \
		if [ ! -x "$(CLIENT_NEW_PYTHON)" ] || ! "$(CLIENT_NEW_PYTHON)" -c 'import sys' >/dev/null 2>&1; then \
			if command -v python3 >/dev/null 2>&1; then \
				HOST_PYTHON="python3"; \
			elif command -v python >/dev/null 2>&1; then \
				HOST_PYTHON="python"; \
			else \
				echo "[client-new] ERROR: python3/python not found in PATH"; \
				exit 1; \
			fi; \
			echo "[client-new] Creating virtual environment at $(abspath $(CLIENT_NEW_VENV_DIR))..."; \
			"$$HOST_PYTHON" -m venv "$(abspath $(CLIENT_NEW_VENV_DIR))"; \
		fi; \
		API_PUBLIC_HOST="$$HOST"; \
		if [ "$$API_PUBLIC_HOST" = "0.0.0.0" ]; then API_PUBLIC_HOST="localhost"; fi; \
		API_BASE_URL="http://$$API_PUBLIC_HOST:$$API_PORT"; \
		echo "[opsatlas] Starting pure JS prototype on http://$$HOST:$$WEB_PORT ..."; \
		OPSATLAS_API_BASE_URL="$$API_BASE_URL" \
		OPSATLAS_WEB_HOST="$$HOST" \
		OPSATLAS_WEB_PORT="$$WEB_PORT" \
		"$(CLIENT_NEW_PYTHON)" "$(CLIENT_NEW_DIR)/server.py" --host "$$HOST" --port "$$WEB_PORT"; \
		exit $$?; \
	fi; \
	PKG_CFG="$(CLIENT_DIR)/.dart_tool/package_config.json"; \
	if [ ! -f "$$PKG_CFG" ] || [ "$(CLIENT_DIR)/pubspec.yaml" -nt "$$PKG_CFG" ]; then \
		(cd "$(CLIENT_DIR)" && flutter pub get); \
	fi; \
	if [ ! -f "$(CLIENT_DIR)/web/index.html" ]; then \
		(cd "$(CLIENT_DIR)" && flutter create --platforms=web .); \
	fi; \
	[ "$$BUILD_MODE" = "auto" ] && BUILD_MODE="debug"; \
	API_BASE_URL="http://localhost:$$API_PORT"; \
	FLUTTER_ARGS=(run --no-pub --dart-define=API_BASE_URL="$$API_BASE_URL"); \
	if [ "$$DEVICE" = "web-server" ]; then \
		API_BASE_URL="http://$$HOST:$$API_PORT"; \
		FLUTTER_ARGS=(run --no-pub --dart-define=API_BASE_URL="$$API_BASE_URL"); \
		FLUTTER_ARGS+=(-d web-server --web-hostname "$$HOST" --web-port "$$WEB_PORT"); \
		echo "[opsatlas] Starting Flutter web-server on http://$$HOST:$$WEB_PORT ..."; \
	else \
		FLUTTER_ARGS+=(-d "$$DEVICE" --web-port "$$WEB_PORT"); \
		echo "[opsatlas] Starting Flutter on $$DEVICE..."; \
	fi; \
	case "$$BUILD_MODE" in profile) FLUTTER_ARGS+=(--profile) ;; release) FLUTTER_ARGS+=(--release) ;; esac; \
	[ "$$RENDERER" != "auto" ] && FLUTTER_ARGS+=(--web-renderer "$$RENDERER"); \
	(cd "$(CLIENT_DIR)" && flutter "$${FLUTTER_ARGS[@]}")

# --- opsatlas-stop -----------------------------------------------------------

opsatlas-stop:
	@echo "[opsatlas-stop] Stopping services on :$(_API_PORT) and :$(_WEB_PORT)..."
	@for port in "$(_API_PORT)" "$(_WEB_PORT)"; do \
		pids=$$(lsof -tiTCP:$$port -sTCP:LISTEN 2>/dev/null || true); \
		if [ -n "$$pids" ]; then \
			echo "[opsatlas-stop] Killing listeners on :$$port ($$pids)"; \
			kill $$pids 2>/dev/null || true; \
		else \
			echo "[opsatlas-stop] No listener on :$$port"; \
		fi; \
	done
	@sleep 0.5
	@for port in "$(_API_PORT)" "$(_WEB_PORT)"; do \
		pids=$$(lsof -tiTCP:$$port -sTCP:LISTEN 2>/dev/null || true); \
		if [ -n "$$pids" ]; then \
			echo "[opsatlas-stop] Force killing on :$$port ($$pids)"; \
			kill -9 $$pids 2>/dev/null || true; \
		fi; \
	done

# --- flag targets (no-op when used with opsatlas) ----------------------------

nochrome nondev js:
	@:

seeddb:
	@if [ -z "$(filter opsatlas,$(MAKECMDGOALS))" ]; then \
		$(MAKE) --no-print-directory seed-db; \
	fi
