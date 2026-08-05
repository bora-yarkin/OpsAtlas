# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest


def _load_versioning_module():
    root = Path(__file__).resolve().parents[2]
    module_path = root / "tools/versioning.py"
    spec = importlib.util.spec_from_file_location("opsatlas_versioning", module_path)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("opsatlas_versioning", module)
    spec.loader.exec_module(module)
    return module


versioning = _load_versioning_module()


def test_commit_classification_maps_to_expected_bumps() -> None:
    feature = versioning.classify_commit_message("feat: add workflow automation rules")
    patch = versioning.classify_commit_message("fix: prevent incident detail overflow")
    changed = versioning.classify_commit_message("docs: clarify local setup instructions")
    breaking = versioning.classify_commit_message(
        "feat!: remove legacy restore payload\n\nBREAKING CHANGE: old restore payloads no longer load.\n"
    )

    assert feature.bump == "feature"
    assert feature.changelog_section == "Added"
    assert feature.summary == "Add workflow automation rules."

    assert patch.bump == "patch"
    assert patch.changelog_section == "Fixed"
    assert patch.summary == "Prevent incident detail overflow."

    assert changed.bump == "patch"
    assert changed.changelog_section == "Changed"

    assert breaking.bump == "breaking"
    assert breaking.changelog_section == "Breaking"
    assert breaking.summary == "Remove legacy restore payload."


def test_commit_classification_supports_reverts_and_skips_merges() -> None:
    revert = versioning.classify_commit_message('Revert "feat: add task dependencies"')
    merge = versioning.classify_commit_message("Merge branch 'main' into feature/versioning")

    assert revert.bump == "patch"
    assert revert.changelog_section == "Changed"
    assert merge.bump == "skip"


def test_invalid_commit_subjects_are_rejected() -> None:
    with pytest.raises(versioning.VersioningError):
        versioning.classify_commit_message("Add automatic versioning")


def test_version_bumps_reset_lower_components() -> None:
    current = versioning.ManagedVersion.parse("0.1.65", 65)

    assert current.bump("patch") == versioning.ManagedVersion.parse("0.1.66", 66)
    assert current.bump("feature") == versioning.ManagedVersion.parse("0.2.0", 66)
    assert current.bump("breaking") == versioning.ManagedVersion.parse("1.0.0", 66)


def test_generated_changelog_block_renders_latest_release_first() -> None:
    older_version = versioning.ManagedVersion.parse("0.2.0", 66)
    newer_version = versioning.ManagedVersion.parse("0.2.1", 67)
    older = versioning.classify_commit_message("feat: add a universal quick create surface")
    newer = versioning.classify_commit_message("fix: trim duplicate action rows")

    block = versioning.render_generated_changelog_block(
        [
            (older_version, older, "2026-06-24"),
            (newer_version, newer, "2026-06-25"),
        ],
        "<!-- opsatlas-versioning:start -->",
        "<!-- opsatlas-versioning:end -->",
    )

    assert "## [0.2.1] - 2026-06-25" in block
    assert "## [0.2.0] - 2026-06-24" in block
    assert block.index("## [0.2.1] - 2026-06-25") < block.index("## [0.2.0] - 2026-06-24")
    assert "### Fixed" in block
    assert "### Added" in block


def test_render_build_info_exports_runtime_constants() -> None:
    content = versioning.render_build_info(versioning.ManagedVersion.parse("1.4.2", 113))

    assert 'APP_VERSION = "1.4.2"' in content
    assert "APP_BUILD = 113" in content
    assert 'APP_RELEASE = "1.4.2+113"' in content


def test_generated_release_entries_build_github_ready_notes() -> None:
    older_version = versioning.ManagedVersion.parse("0.2.0", 66)
    newer_version = versioning.ManagedVersion.parse("0.2.1", 67)
    older = versioning.classify_commit_message("feat: add a universal quick create surface")
    newer = versioning.classify_commit_message("fix: trim duplicate action rows")

    changelog = versioning.render_generated_changelog_block(
        [
            (older_version, older, "2026-06-24"),
            (newer_version, newer, "2026-06-25"),
        ],
        "<!-- opsatlas-versioning:start -->",
        "<!-- opsatlas-versioning:end -->",
    )

    entries = versioning.generated_release_entries(
        changelog,
        "<!-- opsatlas-versioning:start -->",
        "<!-- opsatlas-versioning:end -->",
    )

    assert [entry.version.semver for entry in entries] == ["0.2.1", "0.2.0"]
    assert entries[0].released_on == "2026-06-25"
    assert entries[0].notes.startswith("Released on 2026-06-25.")
    assert "### Fixed" in entries[0].notes
    assert "- Trim duplicate action rows." in entries[0].notes


def test_release_entry_for_version_returns_matching_generated_section() -> None:
    version = versioning.ManagedVersion.parse("1.0.0", 101)
    classification = versioning.classify_commit_message("feat!: remove legacy restore payload")
    changelog = versioning.render_generated_changelog_block(
        [(version, classification, "2026-06-26")],
        "<!-- opsatlas-versioning:start -->",
        "<!-- opsatlas-versioning:end -->",
    )

    entry = versioning.release_entry_for_version(
        changelog,
        version,
        "<!-- opsatlas-versioning:start -->",
        "<!-- opsatlas-versioning:end -->",
    )

    assert entry.version.semver == "1.0.0"
    assert entry.released_on == "2026-06-26"
    assert "### Breaking" in entry.notes


def test_parse_commit_history_output_strips_record_separating_newlines() -> None:
    raw = (
        "2026-06-24T10:00:00+00:00\x1ffeat: add version automation\x1e\n"
        "2026-06-25T11:30:00+00:00\x1ffix: trim extra workflow warnings\x1e"
    )

    records = versioning.parse_commit_history_output(raw)

    assert records == [
        versioning.CommitRecord(
            message="feat: add version automation",
            committed_on="2026-06-24",
        ),
        versioning.CommitRecord(
            message="fix: trim extra workflow warnings",
            committed_on="2026-06-25",
        ),
    ]


def test_commit_msg_hook_validates_without_mutating_repo(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    message_file = tmp_path / "message.txt"
    message_file.write_text("fix: keep version sync inside the same commit\n", encoding="utf-8")
    cleared: list[Path] = []

    monkeypatch.setattr(versioning, "repo_root", lambda: tmp_path)
    monkeypatch.setattr(versioning, "clear_hook_context", lambda root: cleared.append(root))
    monkeypatch.setattr(versioning, "write_state", lambda *args, **kwargs: pytest.fail("write_state should not run in commit-msg"))
    monkeypatch.setattr(versioning, "stage_managed_files", lambda *args, **kwargs: pytest.fail("stage_managed_files should not run in commit-msg"))

    assert versioning.command_commit_msg(SimpleNamespace(message_file=str(message_file))) == 0
    assert cleared == [tmp_path]


def test_post_commit_hook_amends_same_commit_when_managed_files_drift(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    calls: list[str] = []
    fake_state = object()

    monkeypatch.delenv(versioning.POST_COMMIT_GUARD_ENV, raising=False)
    monkeypatch.setattr(versioning, "repo_root", lambda: tmp_path)
    monkeypatch.setattr(versioning, "load_config", lambda root: object())
    monkeypatch.setattr(versioning, "render_state", lambda root, config: fake_state)
    monkeypatch.setattr(versioning, "managed_file_mismatches", lambda root, state: ["CHANGELOG.md"])
    monkeypatch.setattr(versioning, "write_state", lambda root, state: calls.append("write"))
    monkeypatch.setattr(versioning, "stage_managed_files", lambda root: calls.append("stage"))

    def _fake_run(command: list[str], *, cwd: Path, check: bool, env: dict[str, str]) -> None:
        calls.append("amend")
        assert command == ["git", "commit", "--amend", "--no-edit", "--no-verify"]
        assert cwd == tmp_path
        assert check is True
        assert env[versioning.POST_COMMIT_GUARD_ENV] == "1"

    monkeypatch.setattr(versioning.subprocess, "run", _fake_run)

    assert versioning.command_post_commit(SimpleNamespace()) == 0
    assert calls == ["write", "stage", "amend"]


def test_post_commit_hook_skips_when_guard_is_set(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv(versioning.POST_COMMIT_GUARD_ENV, "1")
    monkeypatch.setattr(versioning, "repo_root", lambda: pytest.fail("repo_root should not be called when guard is active"))

    assert versioning.command_post_commit(SimpleNamespace()) == 0
