<!-- SPDX-FileCopyrightText: 2026 Bora Yarkın -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Contributing

Thanks for helping improve OpsAtlas.

OpsAtlas is still pre-1.0, so the project optimizes for clear, focused
changes over large speculative refactors. Small fixes, documentation
improvements, tests, and carefully scoped features are all welcome.

Shipped work belongs in [CHANGELOG.md](../CHANGELOG.md). Forward-looking work
belongs in [docs/project/roadmap.md](../docs/project/roadmap.md). Open
maintenance debt belongs in
[docs/project/codebase-audit.md](../docs/project/codebase-audit.md).

Commits are versioned automatically. Use Conventional Commit subjects such as
`feat:`, `fix:`, `docs:`, `refactor:`, or `chore:`. Use `!` or a
`BREAKING CHANGE:` footer when the change should bump the major version.

## Before You Start

- Read the [README](../README.md) for local setup and project structure.
- Read the [GitHub security automation guide](../docs/development/github-security.md)
  before changing CodeQL, dependency review, or code scanning behavior.
- Read the [Code of Conduct](CODE_OF_CONDUCT.md) before participating.
- Read the [Security Policy](SECURITY.md) before reporting security
  issues. Do not file public issues for vulnerabilities.

## Development Setup

### Backend

```bash
make test-backend
```

Any backend-related Make target auto-creates `backend/.venv` when needed and
syncs backend dependencies.

### Frontend

```bash
make deps-frontend
```

### Full Local Stack

```bash
make opsatlas
```

## Validation

Run the checks relevant to your change before opening a pull request:

```bash
make tests
```

`make check` is an alias to the same command.

## Pull Request Guidelines

- Keep each pull request focused on one logical change.
- Include tests when you add or change behavior.
- Update docs when setup, commands, UX, or project policy changes.
- Move implemented roadmap-style notes into `CHANGELOG.md` instead of leaving
  them in planning docs.
- Add screenshots or short screen recordings for visible UI changes when
  they help reviewers.
- Mention any follow-up work, tradeoffs, or known gaps in the PR description.

## Commit And Review Hygiene

- Prefer clear commit messages that describe the user-facing or engineering
  intent of the change.
- Avoid bundling unrelated cleanup into functional changes.
- Be explicit about migrations, config changes, or compatibility risks.

## Reporting Bugs

Use the GitHub issue templates when possible. A good bug report includes:

- what you expected to happen
- what actually happened
- exact reproduction steps
- environment details such as browser, OS, Python, or Flutter versions
- logs, screenshots, or traces when relevant

## Proposing Features

Feature requests are most useful when they explain:

- the user or operator problem
- why the current behavior is insufficient
- the rough shape of the proposed solution
- any alternatives you already considered

## Licensing

By intentionally submitting a contribution for inclusion in this repository,
you agree that your contribution may be distributed under the project's
`GPL-3.0-only` license.
