FROM python:3.14

ENV VIRTUAL_ENV=/srv/opsatlas/backend/.venv \
    PATH="/srv/opsatlas/backend/.venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /srv/opsatlas/backend

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && mv /root/.local/bin/uv /usr/local/bin/uv

COPY backend/ /srv/opsatlas/backend/
RUN uv sync --frozen --no-dev --no-editable

RUN mkdir -p /srv/opsatlas-instance/media_storage/quarantine /srv/opsatlas-instance/backups

EXPOSE 8000

ENTRYPOINT ["/srv/opsatlas/backend/.venv/bin/python", "scripts/container_entrypoint.py"]
CMD ["api"]
