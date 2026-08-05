# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Business logic for backup snapshot generation, inspection, and retrieval."""

from __future__ import annotations

from dataclasses import dataclass, field
from threading import RLock
from time import time
from typing import Literal
from uuid import uuid4

NodeType = Literal["folder", "file"]


@dataclass(slots=True)
class Snapshot:
    id: str
    mode: str
    created_at_ms: int
    nodes_by_path: dict[str, NodeType] = field(default_factory=dict)
    file_content_by_path: dict[str, str] = field(default_factory=dict)


class BackupService:
    def __init__(self) -> None:
        self._snapshots: dict[str, Snapshot] = {}
        self._lock = RLock()

    def list_snapshots(self) -> dict[str, list[dict[str, object]]]:
        with self._lock:
            snapshots = [
                {
                    "id": snapshot.id,
                    "mode": snapshot.mode,
                    "created_at_ms": snapshot.created_at_ms,
                }
                for snapshot in self._snapshots.values()
            ]
        snapshots.sort(key=lambda row: int(row["created_at_ms"]), reverse=True)
        return {"snapshots": snapshots}

    def create_snapshot(self, mode: str) -> dict[str, object]:
        normalized_mode = (mode or "full").strip() or "full"
        snapshot = Snapshot(
            id=str(uuid4()),
            mode=normalized_mode,
            created_at_ms=int(time() * 1000),
        )
        self._seed_demo_snapshot(snapshot)
        with self._lock:
            self._snapshots[snapshot.id] = snapshot
        return {
            "id": snapshot.id,
            "mode": snapshot.mode,
            "created_at_ms": snapshot.created_at_ms,
        }

    def tree(self, snapshot_id: str, path: str = "/") -> dict[str, object]:
        normalized_path = self._normalize_path(path)
        with self._lock:
            snapshot = self._snapshots.get(snapshot_id)
            children = (
                self._list_children(snapshot, normalized_path)
                if snapshot is not None
                else []
            )
        return {
            "snapshot_id": snapshot_id,
            "path": normalized_path,
            "children": children,
        }

    def node(self, snapshot_id: str, path: str) -> dict[str, object]:
        normalized_path = self._normalize_path(path)
        with self._lock:
            snapshot = self._snapshots.get(snapshot_id)
            if snapshot is None:
                return {"error": "snapshot_not_found"}
            node_type = snapshot.nodes_by_path.get(normalized_path)
            if node_type is None:
                return {"error": "node_not_found"}
            if node_type == "file":
                return {
                    "path": normalized_path,
                    "type": "file",
                    "content": snapshot.file_content_by_path.get(normalized_path, ""),
                }
        return {"path": normalized_path, "type": "folder"}

    def _list_children(
        self,
        snapshot: Snapshot,
        path: str,
    ) -> list[dict[str, object]]:
        children: list[dict[str, object]] = []
        prefix = "/" if path == "/" else f"{path}/"
        for node_path, node_type in snapshot.nodes_by_path.items():
            if node_path == path or not node_path.startswith(prefix):
                continue
            remainder = node_path[len(prefix) :]
            if not remainder or "/" in remainder:
                continue
            children.append(
                {
                    "path": node_path,
                    "name": remainder,
                    "type": node_type,
                },
            )
        children.sort(key=lambda row: str(row["name"]).lower())
        return children

    def _seed_demo_snapshot(self, snapshot: Snapshot) -> None:
        self._add_folder(snapshot, "/")
        self._add_folder(snapshot, "/spaces")
        self._add_folder(snapshot, "/spaces/demo")
        self._add_folder(snapshot, "/spaces/demo/kb")
        self._add_folder(snapshot, "/spaces/demo/kb/docs")
        self._add_folder(snapshot, "/spaces/demo/sops")
        self._add_folder(snapshot, "/spaces/demo/incidents")
        self._add_file(
            snapshot,
            "/spaces/demo/kb/docs/welcome.json",
            '{"title":"Welcome","content_md":"# Hello"}',
        )
        self._add_file(
            snapshot,
            "/spaces/demo/sops/restart-service.json",
            '{"title":"Restart Service","steps":[{"order":1,"title":"Check status"}]}',
        )
        self._add_file(
            snapshot,
            "/spaces/demo/incidents/INC-1.json",
            '{"title":"Demo Incident","status":"resolved"}',
        )
        self._add_file(
            snapshot,
            "/manifest.json",
            f'{{"snapshot":"{snapshot.id}","mode":"{snapshot.mode}"}}',
        )

    def _add_folder(self, snapshot: Snapshot, path: str) -> None:
        snapshot.nodes_by_path[self._normalize_path(path)] = "folder"

    def _add_file(self, snapshot: Snapshot, path: str, content: str) -> None:
        normalized_path = self._normalize_path(path)
        snapshot.nodes_by_path[normalized_path] = "file"
        snapshot.file_content_by_path[normalized_path] = content

    def _normalize_path(self, path: str | None) -> str:
        if path is None:
            return "/"
        stripped = path.strip()
        if not stripped:
            return "/"
        with_leading = stripped if stripped.startswith("/") else f"/{stripped}"
        compact = "/".join(segment for segment in with_leading.split("/") if segment)
        if not compact:
            return "/"
        return f"/{compact}"


backup_service = BackupService()
