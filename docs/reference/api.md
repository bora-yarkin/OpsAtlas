<!-- SPDX-FileCopyrightText: 2026 Bora Yarkın -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Backend API Reference

This is the human-maintained API guide for the main OpsAtlas backend surfaces.
It complements the router code and OpenAPI output by explaining the purpose of
the endpoint families, the expected workflow, and the most important routes to
read first.

## Common Patterns

- Authentication:
  Most routes require an authenticated user resolved by `get_current_user`.
  Session-aware flows use an access JWT plus refresh/session cookies.
- Authorization:
  Routers usually enforce coarse role checks, while services enforce deeper
  workflow rules and invariants.
- Localization:
  KB, SOP, incident, task, and space responses may be post-processed through
  localization services before being returned.
- Audit and analytics:
  Sensitive auth/admin changes and user-facing activity flows often emit audit
  or analytics events from services rather than routers.

## `/auth`

Purpose: account authentication, session lifecycle, MFA, and per-user settings.

Key routes:

- `POST /auth/login`
  Password login. May return a live token bundle, `onboarding_required`, or MFA requirements.
- `POST /auth/refresh`
  Rotates the refresh token and returns a fresh access token for the same session.
- `POST /auth/onboarding/complete`
  Converts a temporary onboarding password into a permanent one.
- `POST /auth/onboarding/token/complete`
  Completes onboarding from an invite token.
- `GET /auth/me`
  Returns the authenticated user's core profile.
- `PATCH /auth/me`
  Updates the authenticated user's name/email.
- `POST /auth/me/password`
  Changes the current password and revokes every session.
- `POST /auth/logout`
  Clears cookies and revokes the current session when possible.
- `GET /auth/me/sessions`
  Lists active or revoked sessions for account management.
- `POST /auth/me/sessions/{session_id}/revoke`
  Revokes a single session.
- `POST /auth/me/sessions/revoke-others`
  Revokes every session except the current one.
- `GET /auth/me/mfa/status`
  Shows whether MFA is enabled, required, and verified for the current session.
- `POST /auth/me/mfa/setup`
  Starts TOTP enrollment.
- `POST /auth/me/mfa/enable`
  Verifies the enrollment code and enables MFA.
- `POST /auth/me/mfa/disable`
  Disables MFA and revokes sessions.
- `POST /auth/me/mfa/verify`
  Upgrades the active session to MFA-verified.
- `GET /auth/session/policy`
  Returns session-duration options and warning-window settings.
- `GET /auth/me/session-status`
  Returns live expiry information for the active session.
- `GET|PATCH /auth/me/notification-preferences`
  Stores per-user activity digest settings.
- `GET|PATCH /auth/me/dashboard-preferences`
  Stores selected space, widget order, and feed read markers.

Code to read:

- `app/core/auth/security.py`
- `app/core/auth/policy.py`
- `app/modules/auth/router.py`
- `app/modules/auth/service.py`

## `/spaces`

Purpose: top-level space discovery and membership data.

Key routes:

- `GET /spaces`
  Lists spaces the user can see, including counts used by the dashboard.
- `POST /spaces`
  Creates a new space.
- `GET /spaces/{space_id}/members`
  Returns basic membership data.
- `GET /spaces/{space_id}/members/detailed`
  Returns richer member information for editors and assignment UIs.

## `/kb`

Purpose: knowledge base folders, documents, search, review workflow, and comments.

Key routes:

- `GET /kb/spaces/{space_id}/folders`
  Returns either a tree slice or a flat folder list for KB navigation.
- `POST /kb/folders`
  Creates a folder in a space.
- `GET /kb/spaces/{space_id}/docs`
  Lists docs with folder, tag, trash, stale-review, and publication filters.
- `GET /kb/spaces/{space_id}/search`
  Runs ranked KB search.
- `GET /kb/spaces/{space_id}/search-suggestions`
  Returns autosuggest values for the search box.
- `GET /kb/spaces/{space_id}/review-summary`
  Returns stale-review and review-assignment summary data.
- `GET|PUT /kb/spaces/{space_id}/policy`
  Reads or updates KB space policy, synonyms, lexicon, and relevance settings.
- `GET /kb/docs/{doc_id}/detail`
  Returns full doc detail for editing and review screens.
- `POST /kb/docs`
  Creates a document.
- `PUT /kb/docs/{doc_id}`
  Updates the main doc body and workflow fields.
- `PATCH /kb/docs/{doc_id}/meta`
  Updates metadata without rewriting the full content payload.
- `POST /kb/docs/{doc_id}/publish`
  Publishes a draft.
- `GET /kb/docs/{doc_id}/versions`
  Returns version history.
- `GET /kb/docs/{doc_id}/diff`
  Returns diff material for version comparisons.
- `GET|POST /kb/docs/{doc_id}/comments`
  Lists or creates review/discussion comments.

## `/sop`

Purpose: standard operating procedure authoring, approvals, schedules, and run execution.

Key routes:

- `GET /sop/spaces/{space_id}/sops`
  Lists SOPs visible in a space.
- `GET /sop/sops/{sop_id}/detail`
  Returns full SOP detail including steps and approval state.
- `POST /sop/sops`
  Creates an SOP shell.
- `PUT /sop/sops/{sop_id}`
  Updates the title, slug, and overview.
- `PUT /sop/sops/{sop_id}/meta`
  Updates reviewer, review due date, and approval requirements.
- `PUT /sop/sops/{sop_id}/steps`
  Replaces the SOP step list.
- `POST /sop/sops/{sop_id}/approve`
  Records an approval.
- `PUT /sop/sops/{sop_id}/approval-stages`
  Reconfigures staged approval flow.
- `PUT /sop/sops/{sop_id}/run-schedules`
  Persists recurring run schedules.
- `POST /sop/sops/{sop_id}/runs`
  Starts a live SOP run.
- `PUT /sop/runs/{run_id}/steps/{run_step_id}`
  Updates execution state for a single run step.
- `POST /sop/runs/{run_id}/complete`
  Completes a run.
- `GET /sop/runs/{run_id}/audit`
  Returns structured run audit data.
- `GET /sop/runs/{run_id}/audit.csv`
  Exports run audit as CSV.
- `GET /sop/runs/{run_id}/audit.pdf`
  Exports run audit as PDF.
- `POST /sop/runs/{run_id}/steps/{run_step_id}/follow-up`
  Creates a follow-up incident from a run step.
- `POST /sop/runs/{run_id}/steps/{run_step_id}/task`
  Creates a follow-up task from a run step.

## `/incidents`

Purpose: incident records, templates, timelines, action items, impacts, status updates, and exports.

Key routes:

- `GET /incidents/spaces/{space_id}`
  Lists incidents in a space.
- `GET /incidents/spaces/{space_id}/analytics`
  Returns incident rollups for the space dashboard.
- `GET|POST /incidents/spaces/{space_id}/templates`
  Lists or creates space-scoped incident templates.
- `PUT|DELETE /incidents/templates/{template_id}`
  Updates or deletes a template.
- `POST /incidents`
  Creates a new incident.
- `GET /incidents/{incident_id}`
  Returns the full incident detail payload.
- `PUT /incidents/{incident_id}`
  Updates main incident state, including status and summary.
- `PUT /incidents/{incident_id}/meta`
  Updates postmortem content and related metadata.
- `PUT /incidents/{incident_id}/profile`
  Updates structured profile fields.
- `POST /incidents/{incident_id}/timeline`
  Adds a timeline event.
- `POST /incidents/{incident_id}/action-items`
  Creates an incident action item.
- `POST /incidents/{incident_id}/action-items/{action_item_id}/task`
  Turns an action item into a task.
- `GET|POST /incidents/{incident_id}/impacts`
  Lists or creates impacted-service entries.
- `GET|POST /incidents/{incident_id}/status-updates`
  Lists or creates status updates.
- `GET /incidents/{incident_id}/reminders`
  Returns reminder state for unresolved action items.
- `GET /incidents/{incident_id}/report`
  Returns the structured incident report payload.
- `GET /incidents/{incident_id}/report.csv`
  Exports the incident report as CSV.
- `GET /incidents/{incident_id}/report.pdf`
  Exports the incident report as PDF.
- `GET /incidents/{incident_id}/postmortem.pdf`
  Exports the postmortem as PDF.

## `/tasks`

Purpose: track standalone work and work derived from incidents or SOP runs.

Key routes:

- `GET /tasks/my`
  Returns tasks assigned to the current user.
- `GET /tasks/spaces/{space_id}`
  Returns tasks for a space.
- `POST /tasks`
  Creates a task.
- `PUT /tasks/{task_id}`
  Updates assignment and status fields.
- `GET /tasks/sop/{sop_id}`
  Lists tasks linked to an SOP.
- `GET|POST /tasks/{task_id}/comments`
  Lists or creates task comments.

## `/analytics`

Purpose: activity ingestion and reporting for dashboard and space-level insights.

Key routes:

- `POST /analytics/events`
  Stores an activity event.
- `GET /analytics/feed`
  Returns the activity feed used by the dashboard and space views.
- `GET /analytics/spaces/{space_id}/top/{entity_type}`
  Returns top entities for one content type.
- `GET /analytics/spaces/{space_id}/search-quality`
  Returns search quality rollups.
- `GET /analytics/spaces/{space_id}/trends`
  Returns time-series trend points.
- `GET /analytics/spaces/{space_id}/export`
  Exports analytics events.

## `/admin`

Purpose: privileged user provisioning, org management, branding, roles, and policy administration.

Key routes:

- `POST|PUT /admin/users...`
  User provisioning and profile updates.
- `POST /admin/users/{user_id}/invite`
  Generates onboarding credentials or links.
- `POST /admin/users/{user_id}/password-reset`
  Forces a password reset/onboarding flow.
- `POST /admin/users/{user_id}/activate`
  Reactivates a user.
- `POST /admin/users/{user_id}/deactivate`
  Deactivates a user.
- `POST|PUT|DELETE /admin/spaces...`
  Administrative space lifecycle management.
- `POST|PUT|DELETE /admin/custom-roles...`
  Custom role management.
- `GET|POST|PUT|DELETE /admin/org/...`
  Organization graph, role impact simulation, item links, integrity checks, import/export.
- `GET|PUT /admin/customization`
  Branding draft state.
- `POST /admin/customization/publish`
  Publishes branding changes.
- `GET|PATCH /admin/session-policy`
  Reads or updates session policy defaults.

## `/media`

Purpose: uploads, attachments, metadata editing, usage tracking, and signed delivery.

Key routes:

- `POST /media/upload`
  Uploads a new asset.
- `GET /media/policy`
  Returns the client upload policy.
- `GET /media`
  Lists assets.
- `GET /media/page`
  Paginated media listing.
- `GET /media/attachments`
  Lists assets attached to an entity.
- `POST /media/{asset_id}/attachments`
  Attaches an asset to an entity.
- `PATCH /media/{asset_id}/meta`
  Updates asset metadata.
- `GET /media/{asset_id}/usage`
  Returns usage references.
- `GET /media/{asset_id}/signed-url`
  Returns a temporary access URL.
- `GET /media/{asset_id}/file`
  Streams the file.

## `/localization`

Purpose: runtime language bundles, translation management, and per-user language preferences.

Key routes:

- `GET /localization/runtime`
  Returns the runtime bundle used by the client.
- `GET|PATCH /localization/preferences/me`
  Reads or updates the current user's locale preferences.
- `GET|PATCH /localization/catalog`
  Reads or updates localization catalog metadata.
- `GET /localization/bundles/export`
  Exports language bundles.
- `POST /localization/bundles/import`
  Imports language bundles and validation results.
- `GET|PATCH /localization/ai-settings`
  Reads or updates translation-generation settings.
- `POST /localization/translations/retranslate`
  Requeues existing translations.
- `POST /localization/translations/translate-missing`
  Generates translations for missing strings.
- `GET|POST /localization/translations/queue`
  Reads or processes the translation queue.

## `/ai`

Purpose: AI-assisted writing and summarization helpers.

Key routes:

- `GET /ai/status`
  Returns AI configuration or availability.
- `POST /ai/summarize`
  Summarizes freeform text.
- `POST /ai/suggest/doc-metadata`
  Suggests KB metadata.
- `POST /ai/draft/incident-postmortem`
  Drafts incident postmortem content.

## `/admin/backups`

Purpose: inspect and manage backup snapshots.

Key routes:

- `GET /admin/backups/snapshots`
  Lists snapshots.
- `POST /admin/backups/snapshots`
  Creates a new snapshot.
- `GET /admin/backups/snapshots/{snapshot_id}/tree`
  Browses a snapshot path as a tree.
- `GET /admin/backups/snapshots/{snapshot_id}/node`
  Reads one snapshot node.
