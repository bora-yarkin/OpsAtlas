<!-- SPDX-FileCopyrightText: 2026 Bora Yarkın -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# GitHub Security Automation

OpsAtlas uses two different GitHub workflows for repository validation and
security reporting:

- `.github/workflows/ci.yml` for product CI, tests, dependency auditing, and
  DAST smoke checks
- `.github/workflows/github-native.yml` for GitHub-native security features
  such as Dependency Review, CodeQL, and OpenSSF Scorecard

## Supported CodeQL Setup

The supported CodeQL setup for this repository is the committed advanced
workflow in `.github/workflows/github-native.yml`.

Repository-managed CodeQL currently scans:

- `python` for the FastAPI backend
- `actions` for GitHub Actions workflow security

The Flutter iOS host project under `client/ios/` is a developer-only target.
It is intentionally excluded from the committed CodeQL workflow because it is
not part of the supported release bundle and it requires Flutter-generated
native files before Xcode can build it.

## GitHub Settings To Use

In GitHub, open:

`Repository -> Security -> Code scanning`

Then make sure:

1. Code scanning is enabled for the repository.
2. GitHub **default setup** is disabled.
3. The repository relies on the committed advanced workflow instead.

Why this matters:

- GitHub default setup auto-detects the developer-only iOS host project.
- That causes extra `ruby` and `swift` CodeQL jobs to be generated.
- Those jobs fail before analysis because the default setup does not run the
  Flutter generation steps required by `client/ios/Podfile` and Xcode package
  resolution.
- The failures show up as configuration noise rather than useful security
  results.

## Reading Results

For each run:

- Product CI uploads combined logs and test artifacts.
- GitHub Native Security uploads CodeQL SARIF artifacts per scanned language.
- If code scanning is enabled in GitHub, CodeQL alerts also appear under the
  repository's code scanning UI.

The intended outcome is:

- Python and GitHub Actions scans produce real findings or a clean pass.
- Unsupported Ruby/Swift configuration noise disappears once default setup is
  turned off.

## When CodeQL Still Fails

Use this order:

1. Check the workflow run summary in GitHub Actions.
2. Download the uploaded CodeQL SARIF artifact for the failing language.
3. Confirm the run came from `.github/workflows/github-native.yml` and not from
   GitHub's default setup.
4. If the failing run is named `CodeQL Setup` and includes unexpected
   `ruby` or `swift` jobs, the repository is still using default setup.
