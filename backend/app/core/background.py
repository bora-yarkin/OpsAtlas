# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Background maintenance loop entrypoints for periodic backend housekeeping."""

from __future__ import annotations

import asyncio
from contextlib import suppress

from app.core.config import settings
from app.core.db import SessionLocal
from app.modules.incidents import service as incidents_service
from app.modules.kb import service as kb_service
from app.modules.localization import service as localization_service
from app.modules.media import service as media_service
from app.modules.tasks import service as tasks_service

_STARTUP_GRACE_SECONDS = 10


def _run_maintenance_cycle() -> None:
    with SessionLocal() as db:
        kb_service.run_all_due_purge_jobs(db)
        kb_service.run_all_due_relevance_benchmark_jobs(db)
        tasks_service.process_due_sop_execution_reminders(db)
        incidents_service.process_overdue_action_item_reminders(db)
        media_service.cleanup_expired_assets(db)
        localization_service.process_due_translation_jobs(db)


async def _wait_or_stop(stop_event: asyncio.Event, timeout_seconds: int) -> bool:
    try:
        await asyncio.wait_for(stop_event.wait(), timeout=timeout_seconds)
        return True
    except asyncio.TimeoutError:
        return False


async def maintenance_loop(stop_event: asyncio.Event) -> None:
    interval_seconds = max(30, settings.maintenance_interval_seconds)
    if await _wait_or_stop(stop_event, min(_STARTUP_GRACE_SECONDS, interval_seconds)):
        return

    while not stop_event.is_set():
        try:
            await asyncio.to_thread(_run_maintenance_cycle)
        except Exception:
            # Maintenance should never take the whole API down. Fail closed and
            # retry on the next interval.
            pass

        if await _wait_or_stop(stop_event, interval_seconds):
            return


async def stop_maintenance_loop(task: asyncio.Task[None] | None, stop_event: asyncio.Event | None) -> None:
    if stop_event is not None:
        stop_event.set()
    if task is None:
        return
    task.cancel()
    with suppress(asyncio.CancelledError):
        await task
