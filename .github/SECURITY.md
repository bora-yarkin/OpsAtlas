<!-- SPDX-FileCopyrightText: 2026 Bora Yarkın -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Security Policy

OpsAtlas is maintained as an actively changing pre-1.0 project. We welcome responsible disclosure of security issues that could affect the application, its dependencies, or its delivery pipeline.

## Supported Versions

Security fixes are currently applied to the active development line only.

| Version / branch | Supported |
| --- | --- |
| `main` | Yes |
| Feature branches, local snapshots, and older commits | No |

If you discover a vulnerability in an older snapshot, please verify it against the latest `main` branch before reporting it.

## Reporting A Vulnerability

Please do not open a public GitHub issue, discussion, or pull request for suspected security vulnerabilities.

Preferred reporting path:

1. Use GitHub's private vulnerability reporting flow from the repository Security tab when it is available.
2. If private reporting is not enabled, contact the maintainer through an existing private channel associated with the repository owner profile and share the report confidentially.

Include as much of the following as you can:

- affected component or area, such as `backend/`, `client/`, dependencies, or GitHub Actions
- impact and what an attacker could do
- clear reproduction steps or a proof of concept
- required configuration, permissions, or user role
- any logs, screenshots, request samples, or remediation ideas that help validate the issue

## Automated Security Controls

OpsAtlas continuously runs automated repository security checks, including:

- dependency and vulnerability scanning (`pip-audit`, OSV Scanner)
- static analysis (`bandit`, `ruff`, CodeQL)
- secret scanning (Gitleaks)
- dynamic smoke validation against the running app surface
- pull-request dependency change review
- OpenSSF Scorecard reporting

Workflow definitions are tracked in `.github/workflows/` and are intended to
run on pull requests and protected branches.

## What To Expect

We aim to:

- acknowledge reports within 3 business days
- triage and assess severity as quickly as possible
- keep reporters updated when more investigation time is needed
- credit reporters for valid findings unless they prefer to remain anonymous

Please allow reasonable time for investigation and remediation before any public disclosure.

## In Scope

Examples of issues that are especially helpful to report:

- authentication, session, MFA, or authorization bypasses
- privilege escalation or cross-tenant data exposure
- injection flaws, XSS, SSRF, path traversal, or remote code execution
- unsafe file upload handling or malware scanning bypass
- secret exposure, token leakage, or cryptographic misuse
- exploitable dependency or supply chain issues, including CI/CD and GitHub Actions weaknesses

## Good-Faith Research

We support coordinated, good-faith security research. Please avoid privacy violations, destructive testing, service disruption, or access to data that is not your own while validating a finding.
