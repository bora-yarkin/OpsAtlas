#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Bora Yarkın
# SPDX-License-Identifier: GPL-3.0-only

"""Synchronize OpsAtlas versions and generated release notes from commit intent."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import textwrap
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Literal

import tomllib

ManagedBump = Literal["breaking", "feature", "patch", "skip"]
GENERATED_COPYRIGHT_LABEL = "SPDX-FileCopyrightText"
GENERATED_LICENSE_LABEL = "SPDX-License-Identifier"
GENERATED_LICENSE_ID = "GPL-3.0-only"

CONVENTIONAL_SUBJECT_RE = re.compile(
    r"^(?P<type>build|chore|ci|docs|feat|fix|perf|refactor|style|test)"
    r"(?:\([^)]+\))?(?P<breaking>!)?: (?P<description>.+)$"
)
BREAKING_FOOTER_RE = re.compile(r"^BREAKING[ -]CHANGE:\s+", re.MULTILINE)
CONTEXT_FILE_NAME = "opsatlas-versioning-context.json"
POST_COMMIT_GUARD_ENV = "OPSATLAS_VERSIONING_POST_COMMIT"
HELP_TEXT = textwrap.dedent(
    """
    OpsAtlas automated versioning expects Conventional Commit subjects:

      feat: add a new capability
      fix: correct a bug
      chore: update tooling
      feat!: remove an old API

    Use `!` or a `BREAKING CHANGE:` footer to trigger a major-version bump.
    """
).strip()


class VersioningError(RuntimeError):
    """Raised when automated versioning cannot safely continue."""


@dataclass(frozen=True)
class ManagedVersion:
    """Repository version state shared by backend, frontend, and changelog."""

    major: int
    minor: int
    patch: int
    build: int

    @property
    def semver(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"

    @property
    def client(self) -> str:
        return f"{self.semver}+{self.build}"

    def bump(self, kind: ManagedBump) -> "ManagedVersion":
        if kind == "breaking":
            return ManagedVersion(self.major + 1, 0, 0, self.build + 1)
        if kind == "feature":
            return ManagedVersion(self.major, self.minor + 1, 0, self.build + 1)
        if kind == "patch":
            return ManagedVersion(self.major, self.minor, self.patch + 1, self.build + 1)
        return self

    @classmethod
    def parse(cls, version: str, build: int) -> "ManagedVersion":
        parts = version.split(".")
        if len(parts) != 3 or any(not part.isdigit() for part in parts):
            raise VersioningError(f"Unsupported semantic version '{version}'")
        return cls(int(parts[0]), int(parts[1]), int(parts[2]), build)


@dataclass(frozen=True)
class VersioningConfig:
    """Static bootstrap information for deterministic version replay."""

    bootstrap_commit: str
    base_version: ManagedVersion
    changelog_start_marker: str
    changelog_end_marker: str


@dataclass(frozen=True)
class CommitClassification:
    """Semantic meaning extracted from a commit message."""

    bump: ManagedBump
    changelog_section: str
    summary: str


@dataclass(frozen=True)
class CommitRecord:
    """Committed or pending change that should participate in release generation."""

    message: str
    committed_on: str


@dataclass(frozen=True)
class RenderedState:
    """Fully rendered repository state for the chosen commit horizon."""

    version: ManagedVersion
    changelog: str
    backend_pyproject: str
    client_pubspec: str
    backend_uv_lock: str
    backend_build_info: str


@dataclass(frozen=True)
class ReleaseEntry:
    """Single generated release entry ready for changelog and GitHub publishing."""

    version: ManagedVersion
    released_on: str
    notes: str


@dataclass(frozen=True)
class HookContext:
    """Git hook metadata captured during prepare-commit-msg."""

    source: str | None
    commit_sha: str | None


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def versioning_context_path(root: Path) -> Path:
    git_dir = git_output(root, "rev-parse", "--git-dir")
    return (root / git_dir / CONTEXT_FILE_NAME).resolve()


def git_output(root: Path, *args: str) -> str:
    completed = subprocess.run(
        ["git", *args],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip()


def git_maybe_output(root: Path, *args: str) -> str:
    completed = subprocess.run(
        ["git", *args],
        cwd=root,
        check=False,
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip()


def load_config(root: Path) -> VersioningConfig:
    config_path = root / ".opsatlas-versioning.toml"
    payload = tomllib.loads(config_path.read_text(encoding="utf-8"))
    settings = payload["versioning"]
    return VersioningConfig(
        bootstrap_commit=str(settings["bootstrap_commit"]),
        base_version=ManagedVersion.parse(str(settings["base_version"]), int(settings["base_build"])),
        changelog_start_marker=str(settings["changelog_start_marker"]),
        changelog_end_marker=str(settings["changelog_end_marker"]),
    )


def read_hook_context(root: Path) -> HookContext:
    path = versioning_context_path(root)
    if not path.exists():
        return HookContext(source=None, commit_sha=None)
    payload = json.loads(path.read_text(encoding="utf-8"))
    return HookContext(
        source=payload.get("source"),
        commit_sha=payload.get("commit_sha"),
    )


def write_hook_context(root: Path, source: str | None, commit_sha: str | None) -> None:
    path = versioning_context_path(root)
    path.write_text(
        json.dumps({"source": source, "commit_sha": commit_sha}, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def clear_hook_context(root: Path) -> None:
    path = versioning_context_path(root)
    if path.exists():
        path.unlink()


def normalize_summary(raw: str) -> str:
    value = raw.strip().rstrip(".")
    if not value:
        raise VersioningError("Commit summary cannot be empty")
    return value[:1].upper() + value[1:] + "."


def classify_commit_message(message: str) -> CommitClassification:
    lines = [line.rstrip() for line in message.splitlines()]
    subject = next((line.strip() for line in lines if line.strip()), "")
    if not subject:
        raise VersioningError("Commit message subject cannot be empty")

    if subject.startswith("Merge "):
        return CommitClassification(bump="skip", changelog_section="Changed", summary=normalize_summary(subject))

    if subject.startswith("Revert "):
        return CommitClassification(bump="patch", changelog_section="Changed", summary=normalize_summary(subject))

    match = CONVENTIONAL_SUBJECT_RE.match(subject)
    if match is None:
        raise VersioningError(HELP_TEXT)

    commit_type = match.group("type")
    breaking = bool(match.group("breaking")) or bool(BREAKING_FOOTER_RE.search(message))
    description = normalize_summary(match.group("description"))

    if breaking:
        return CommitClassification(bump="breaking", changelog_section="Breaking", summary=description)
    if commit_type == "feat":
        return CommitClassification(bump="feature", changelog_section="Added", summary=description)
    if commit_type == "fix":
        return CommitClassification(bump="patch", changelog_section="Fixed", summary=description)
    return CommitClassification(bump="patch", changelog_section="Changed", summary=description)


def split_changelog_sections(changelog: str, start_marker: str, end_marker: str) -> tuple[str, str]:
    if start_marker not in changelog or end_marker not in changelog:
        raise VersioningError("CHANGELOG.md is missing automated versioning markers")
    before, _, tail = changelog.partition(start_marker)
    _, _, after = tail.partition(end_marker)
    return before.rstrip(), after.lstrip("\n")


def generated_changelog_body(changelog: str, start_marker: str, end_marker: str) -> str:
    if start_marker not in changelog or end_marker not in changelog:
        raise VersioningError("CHANGELOG.md is missing automated versioning markers")
    _, _, tail = changelog.partition(start_marker)
    body, _, _ = tail.partition(end_marker)
    return body.strip()


def render_generated_changelog_block(
    entries: list[tuple[ManagedVersion, CommitClassification, str]],
    start_marker: str,
    end_marker: str,
) -> str:
    lines = [start_marker]
    if entries:
        lines.append("")
        for version, classification, released_on in reversed(entries):
            lines.extend(
                [
                    f"## [{version.semver}] - {released_on}",
                    "",
                    f"### {classification.changelog_section}",
                    "",
                    f"- {classification.summary}",
                    "",
                ]
            )
    lines.append(end_marker)
    return "\n".join(lines).rstrip() + "\n"


def generated_release_entries(
    changelog: str,
    start_marker: str,
    end_marker: str,
) -> list[ReleaseEntry]:
    body = generated_changelog_body(changelog, start_marker, end_marker)
    if not body:
        return []

    header_re = re.compile(r"^## \[(?P<version>\d+\.\d+\.\d+)\] - (?P<released_on>\d{4}-\d{2}-\d{2})$", re.MULTILINE)
    matches = list(header_re.finditer(body))
    entries: list[ReleaseEntry] = []
    for index, match in enumerate(matches):
        next_start = matches[index + 1].start() if index + 1 < len(matches) else len(body)
        section_body = body[match.end() : next_start].strip()
        notes_lines = [f"Released on {match.group('released_on')}."]
        if section_body:
            notes_lines.extend(["", section_body])
        entries.append(
            ReleaseEntry(
                version=ManagedVersion.parse(match.group("version"), 0),
                released_on=match.group("released_on"),
                notes="\n".join(notes_lines).rstrip() + "\n",
            )
        )
    return entries


def release_entry_for_version(
    changelog: str,
    version: ManagedVersion,
    start_marker: str,
    end_marker: str,
) -> ReleaseEntry:
    for entry in generated_release_entries(changelog, start_marker, end_marker):
        if entry.version.semver == version.semver:
            return entry
    raise VersioningError(f"No generated release notes found for version {version.semver}")


def replace_exact(pattern: str, replacement: str, content: str, label: str) -> str:
    updated, count = re.subn(pattern, replacement, content, count=1, flags=re.MULTILINE)
    if count != 1:
        raise VersioningError(f"Could not update {label}")
    return updated


def render_build_info(version: ManagedVersion) -> str:
    return (
        f"# {GENERATED_COPYRIGHT_LABEL}: 2026 Bora Yarkın\n"
        f"# {GENERATED_LICENSE_LABEL}: {GENERATED_LICENSE_ID}\n\n"
        "\"\"\"Generated repository release metadata consumed by runtime health surfaces.\"\"\"\n\n"
        f'APP_VERSION = "{version.semver}"\n'
        f"APP_BUILD = {version.build}\n"
        f'APP_RELEASE = "{version.client}"\n'
    )


def parse_commit_history_output(raw: str) -> list[CommitRecord]:
    """Parse git-log output emitted by commit_history into normalized records."""
    records: list[CommitRecord] = []
    for chunk in raw.split("\x1e"):
        normalized_chunk = chunk.strip()
        if not normalized_chunk:
            continue
        committed_on, message = normalized_chunk.split("\x1f", 1)
        records.append(CommitRecord(message=message.strip(), committed_on=committed_on.strip()[:10]))
    return records


def commit_history(root: Path, config: VersioningConfig, until_ref: str) -> list[CommitRecord]:
    if until_ref == config.bootstrap_commit:
        return []
    raw = git_maybe_output(
        root,
        "log",
        "--reverse",
        "--format=%cI%x1f%B%x1e",
        f"{config.bootstrap_commit}..{until_ref}",
    )
    return parse_commit_history_output(raw)


def first_parent(commit_sha: str, root: Path) -> str | None:
    parents_line = git_output(root, "rev-list", "--parents", "-n", "1", commit_sha)
    parts = parents_line.split()
    if len(parts) < 2:
        return None
    return parts[1]


def version_horizon(root: Path, config: VersioningConfig, context: HookContext | None) -> str:
    if context and context.source == "commit" and context.commit_sha:
        parent = first_parent(context.commit_sha, root)
        return parent or config.bootstrap_commit
    return "HEAD"


def replay_releases(
    root: Path,
    config: VersioningConfig,
    *,
    context: HookContext | None = None,
    pending_message: str | None = None,
) -> tuple[ManagedVersion, list[tuple[ManagedVersion, CommitClassification, str]]]:
    horizon = version_horizon(root, config, context)
    version = config.base_version
    entries: list[tuple[ManagedVersion, CommitClassification, str]] = []

    for record in commit_history(root, config, horizon):
        classification = classify_commit_message(record.message)
        version = version.bump(classification.bump)
        if classification.bump != "skip":
            entries.append((version, classification, record.committed_on))

    if pending_message is not None:
        classification = classify_commit_message(pending_message)
        version = version.bump(classification.bump)
        if classification.bump != "skip":
            entries.append((version, classification, date.today().isoformat()))

    return version, entries


def render_state(root: Path, config: VersioningConfig, *, context: HookContext | None = None, pending_message: str | None = None) -> RenderedState:
    version, entries = replay_releases(root, config, context=context, pending_message=pending_message)
    changelog_path = root / "CHANGELOG.md"
    changelog_before, changelog_after = split_changelog_sections(
        changelog_path.read_text(encoding="utf-8"),
        config.changelog_start_marker,
        config.changelog_end_marker,
    )
    generated_block = render_generated_changelog_block(entries, config.changelog_start_marker, config.changelog_end_marker)
    changelog = f"{changelog_before}\n\n{generated_block}\n{changelog_after}".rstrip() + "\n"

    backend_pyproject = replace_exact(
        r'(?m)^version = "[^"]+"$',
        f'version = "{version.semver}"',
        (root / "backend/pyproject.toml").read_text(encoding="utf-8"),
        "backend/pyproject.toml",
    )
    client_pubspec = replace_exact(
        r"(?m)^version: .+$",
        f"version: {version.client}",
        (root / "client/pubspec.yaml").read_text(encoding="utf-8"),
        "client/pubspec.yaml",
    )
    backend_uv_lock = replace_exact(
        r'(\[\[package\]\]\nname = "opsatlas-backend"\nversion = ")[^"]+(")',
        rf'\g<1>{version.semver}\2',
        (root / "backend/uv.lock").read_text(encoding="utf-8"),
        "backend/uv.lock",
    )

    return RenderedState(
        version=version,
        changelog=changelog,
        backend_pyproject=backend_pyproject,
        client_pubspec=client_pubspec,
        backend_uv_lock=backend_uv_lock,
        backend_build_info=render_build_info(version),
    )


def write_state(root: Path, state: RenderedState) -> None:
    managed_files = managed_file_contents(root, state)
    for path, content in managed_files.items():
        if path.read_text(encoding="utf-8") != content:
            path.write_text(content, encoding="utf-8")


def managed_file_contents(root: Path, state: RenderedState) -> dict[Path, str]:
    return {
        root / "CHANGELOG.md": state.changelog,
        root / "backend/pyproject.toml": state.backend_pyproject,
        root / "client/pubspec.yaml": state.client_pubspec,
        root / "backend/uv.lock": state.backend_uv_lock,
        root / "backend/app/core/build_info.py": state.backend_build_info,
    }


def managed_file_mismatches(root: Path, state: RenderedState) -> list[str]:
    mismatches: list[str] = []
    for path, expected_content in managed_file_contents(root, state).items():
        if path.read_text(encoding="utf-8") != expected_content:
            mismatches.append(str(path.relative_to(root)))
    return mismatches


def stage_managed_files(root: Path) -> None:
    subprocess.run(
        [
            "git",
            "add",
            "CHANGELOG.md",
            "backend/pyproject.toml",
            "backend/uv.lock",
            "backend/app/core/build_info.py",
            "client/pubspec.yaml",
        ],
        cwd=root,
        check=True,
    )


def verify_state(root: Path, state: RenderedState) -> int:
    mismatches = managed_file_mismatches(root, state)
    if not mismatches:
        return 0

    print("Automated version metadata is out of sync in:", file=sys.stderr)
    for item in mismatches:
        print(f"  - {item}", file=sys.stderr)
    print("Run `make version-sync` or install the repo Git hooks.", file=sys.stderr)
    return 1


def command_prepare_commit_msg(args: argparse.Namespace) -> int:
    root = repo_root()
    write_hook_context(root, args.source, args.commit_sha)
    return 0


def command_commit_msg(args: argparse.Namespace) -> int:
    root = repo_root()
    try:
        classify_commit_message(Path(args.message_file).read_text(encoding="utf-8"))
    except VersioningError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    finally:
        clear_hook_context(root)
    return 0


def command_post_commit(_: argparse.Namespace) -> int:
    if os.environ.get(POST_COMMIT_GUARD_ENV) == "1":
        return 0

    root = repo_root()
    state = render_state(root, load_config(root))
    if not managed_file_mismatches(root, state):
        return 0

    write_state(root, state)
    stage_managed_files(root)
    env = os.environ.copy()
    env[POST_COMMIT_GUARD_ENV] = "1"
    subprocess.run(
        ["git", "commit", "--amend", "--no-edit", "--no-verify"],
        cwd=root,
        check=True,
        env=env,
    )
    return 0


def command_sync(_: argparse.Namespace) -> int:
    root = repo_root()
    state = render_state(root, load_config(root))
    write_state(root, state)
    return 0


def command_verify(_: argparse.Namespace) -> int:
    root = repo_root()
    state = render_state(root, load_config(root))
    return verify_state(root, state)


def command_release_metadata(_: argparse.Namespace) -> int:
    root = repo_root()
    config = load_config(root)
    state = render_state(root, config)
    release_entry = release_entry_for_version(
        state.changelog,
        state.version,
        config.changelog_start_marker,
        config.changelog_end_marker,
    )
    payload = {
        "version": state.version.semver,
        "build": state.version.build,
        "client_version": state.version.client,
        "tag": state.version.semver,
        "title": state.version.semver,
        "released_on": release_entry.released_on,
        "notes": release_entry.notes,
    }
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare_parser = subparsers.add_parser("prepare-commit-msg")
    prepare_parser.add_argument("--message-file", required=True)
    prepare_parser.add_argument("--source")
    prepare_parser.add_argument("--commit-sha")
    prepare_parser.set_defaults(func=command_prepare_commit_msg)

    commit_parser = subparsers.add_parser("commit-msg")
    commit_parser.add_argument("--message-file", required=True)
    commit_parser.set_defaults(func=command_commit_msg)

    post_commit_parser = subparsers.add_parser("post-commit")
    post_commit_parser.set_defaults(func=command_post_commit)

    sync_parser = subparsers.add_parser("sync")
    sync_parser.set_defaults(func=command_sync)

    verify_parser = subparsers.add_parser("verify")
    verify_parser.set_defaults(func=command_verify)

    release_metadata_parser = subparsers.add_parser("release-metadata")
    release_metadata_parser.set_defaults(func=command_release_metadata)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
