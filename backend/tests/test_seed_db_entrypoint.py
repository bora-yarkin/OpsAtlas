# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

from scripts import seed_db


class _DummySessionContext:
    def __init__(self, session: object) -> None:
        self._session = session

    def __enter__(self) -> object:
        return self._session

    def __exit__(self, exc_type, exc, tb) -> None:
        return None


def test_main_skips_seeding_when_demo_dataset_already_exists(monkeypatch, capsys) -> None:
    session = object()
    calls: list[str] = []

    monkeypatch.setattr(seed_db.sys, "argv", ["seed_db.py"])
    monkeypatch.setattr(seed_db, "init_db", lambda: calls.append("init"))
    monkeypatch.setattr(seed_db, "SessionLocal", lambda: _DummySessionContext(session))
    monkeypatch.setattr(seed_db, "seed_dataset_present", lambda db: db is session)
    monkeypatch.setattr(seed_db, "seed_all", lambda db: calls.append("seed"))

    seed_db.main()

    assert calls == ["init"]
    assert "Seed data already present; skipping demo seed." in capsys.readouterr().out


def test_main_honors_reset_flag_even_when_demo_dataset_exists(monkeypatch, capsys) -> None:
    session = object()
    calls: list[str] = []

    class _EmptyInspector:
        def get_table_names(self) -> list[str]:
            return []

    monkeypatch.setattr(seed_db.sys, "argv", ["seed_db.py", "--reset"])
    monkeypatch.setattr(seed_db, "inspect", lambda _: _EmptyInspector())
    monkeypatch.setattr(seed_db, "init_db", lambda: calls.append("init"))
    monkeypatch.setattr(seed_db, "SessionLocal", lambda: _DummySessionContext(session))
    monkeypatch.setattr(seed_db, "seed_dataset_present", lambda db: True)
    monkeypatch.setattr(seed_db, "seed_all", lambda db: calls.append("seed"))

    seed_db.main()

    assert calls == ["init", "seed"]
    assert "skipping demo seed" not in capsys.readouterr().out.lower()
