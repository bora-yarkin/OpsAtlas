<!-- SPDX-FileCopyrightText: 2026 Bora Yarkın -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Versioning

OpsAtlas uses synchronized semantic versioning with an automated changelog:

```text
MAJOR.MINOR.PATCH
```

## Rules

- Breaking changes increment `MAJOR` and reset `MINOR` and `PATCH`.
- `feat:` commits increment `MINOR` and reset `PATCH`.
- Other allowed commit types such as `fix:`, `docs:`, `refactor:`, `test:`,
  `build:`, `ci:`, `style:`, `perf:`, and `chore:` increment `PATCH`.
- The backend package version, frontend semantic version, backend runtime build
  info, and generated changelog stay synchronized automatically.
- Flutter build metadata (`+N`) increments on every synchronized commit and is
  treated as the monotonic release counter.

## Commit Format

OpsAtlas versioning is driven by Conventional Commit subjects:

```text
feat: add cross-space work inbox filters
fix: prevent task detail overflow on narrow desktop layouts
refactor: split incident detail timeline widgets
feat!: remove the legacy recovery endpoint
```

To flag a breaking change, either:

1. Add `!` after the commit type, such as `feat!:`.
2. Add a `BREAKING CHANGE:` footer to the commit body.

Merge commits are ignored by the automation. `Revert "..."` commits are treated
as patch-level changes.

## Automation

The repository keeps its hook implementations under `.githooks/` and its
deterministic replay settings in `.opsatlas-versioning.toml`.

One-time local setup:

```bash
make install-git-hooks
```

Useful commands:

```bash
make version-sync
make version-check
```

- `make version-sync` regenerates the backend version, frontend version,
  backend runtime build info, and the automated section of `CHANGELOG.md`.
- `make version-check` fails if tracked version files drift from the commit
  history that should have produced them.
- Local Git hooks validate Conventional Commit subjects first, then immediately
  auto-amend the just-created commit with synchronized version files. This keeps
  VS Code Source Control and Sync flows to a single commit and a single push.
- Keep the top `Unreleased` section in `CHANGELOG.md` current for working-tree
  changes that have not been committed yet; committed history is regenerated in
  the automated block below it.

## Documentation Ownership

- `CHANGELOG.md` records implemented, shipped work in chronological order.
- `docs/project/roadmap.md` tracks forward-looking feature work only.
  Implemented items should be removed from the roadmap once shipped.
- `docs/project/codebase-audit.md` tracks open maintenance debt only. Resolved
  findings should be removed instead of kept as history.

## Release Discipline

Moving forward, each published release should do all of the following:

1. Keep automated version files in sync with commit history.
2. Keep the generated release notes in `CHANGELOG.md` intact.
3. Create a Git tag for the release version.
4. Publish `dist/release.zip` or container images that match that tag.

GitHub release automation now runs from the final release job inside
`.github/workflows/ci.yml`. `.github/workflows/release.yml` remains as a
manual republish fallback for trusted maintenance use.

Successful pushes to `main`:

- verify synchronized version metadata again before publishing
- build `dist/release.zip`
- read the exact matching release notes from the generated changelog section
- create or update a GitHub release whose tag and title match the repo version
- attach the deployment bundle as the release asset
