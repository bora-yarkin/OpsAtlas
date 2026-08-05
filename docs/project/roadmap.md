<!-- SPDX-FileCopyrightText: 2026 Bora Yarkın -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Project Roadmap

This file is the forward-looking feature roadmap for OpsAtlas.

- Features are ordered from the smallest likely implementation surface to the
  largest.
- Backup and restore work stays last because it must absorb schema and entity
  changes introduced by earlier roadmap items.
- Implemented work belongs in [CHANGELOG.md](../../CHANGELOG.md).
- Open maintenance debt belongs in [Codebase audit](codebase-audit.md).

## Clearer Primary Actions And Less Control Noise

- Frontend: audit `client/lib/features/spaces/`, `client/lib/features/tasks/`,
  `client/lib/features/analytics/`, `client/lib/features/account/`, and
  `client/lib/features/admin/media/` for duplicated edit, create, and overflow
  actions.
- Shared UI: standardize one obvious primary action row in `client/lib/app/`
  shell widgets and shared card, form, and detail-screen components.
- Product rule: keep history, metadata, and destructive/admin actions behind
  menus or secondary panels so content remains the dominant element on screen.

## Human Readable Activity And History

- Backend: continue enriching feed and audit payloads in
  `backend/app/modules/analytics/` and entity services with actor names, entity
  titles, readable verbs, and concise summaries.
- Frontend: use those summaries across dashboard, space activity, task history,
  SOP runs, and incident detail instead of raw URLs, UUIDs, or low-level event
  codes.
- UX: keep activity secondary by default on content-heavy screens and expose it
  through explicit buttons, drawers, or side panels.

## Faster Filters, Links, And Date Shortcuts

- Frontend: add reusable quick-filter chips such as assigned to me, unread,
  overdue, due today, updated today, and needs approval in dashboard, task, and
  space list surfaces.
- Frontend: expose consistent copy-link and copy-ID actions for docs, SOPs,
  incidents, tasks, runs, and admin entities.
- Shared forms: add date shortcuts such as today, tomorrow, next week, and end
  of month across task, incident, and SOP due-date fields.

## Remembered Context And Resume State

- Frontend: persist last tab, sort order, active filters, folder expansion,
  detail state, and last-opened content in shared preference helpers under
  `client/lib/core/`.
- Backend: extend durable user-preference storage where settings must travel
  across devices, likely through auth or account preference endpoints.
- UX: restore users near where they left off without making navigation feel
  hidden or sticky in surprising ways.

## Better Empty States And Parent Context

- Frontend: replace dead-end empty states in `client/lib/features/dashboard/`,
  `client/lib/features/spaces/`, `client/lib/features/tasks/`, and
  `client/lib/features/analytics/` with action-first guidance and quick-create
  affordances.
- Frontend: add consistent breadcrumbs, parent labels, and back-context cues in
  KB folders, SOP detail, incident detail, and task drill-down screens.
- Navigation: keep mobile and desktop behavior aligned with the current
  full-screen mobile navigation model.

## Personal Organization And Watch States

- Frontend: add pinned spaces, favorites, recent items, and configurable
  landing preferences in dashboard and account settings.
- Backend: add follow and watch models plus APIs for docs, SOPs, incidents,
  tasks, and spaces in the related modules.
- Notifications: wire watch state into mentions, updates, reminders, and
  approval delivery instead of creating a second parallel subscription system.

## Attachment And Media Ergonomics

- Frontend: expand paste-to-upload, drag-and-drop, mobile camera upload, and
  inline attachment previews in KB, SOP, incident, and task flows.
- Backend: harden attachment metadata, limits, and lookup behavior in
  `backend/app/modules/media/` so one component set can be reused everywhere.
- Admin: keep `client/lib/features/admin/media/` as the shared asset control
  plane instead of scattering asset management across unrelated screens.

## UI Regression And Layout Coverage

- Frontend: expand `client/test/` beyond route smoke tests with focused screen
  coverage for navigation, overflows, assertion failures, and common mobile and
  desktop breakpoints.
- Tooling: capture Flutter framework errors, render overflows, and layout
  warnings as test failures in local runs and CI.
- CI: keep web-focused UI verification fast enough to run by default while
  allowing heavier route sweeps and golden-style checks where they add value.

## Command Palette Expansion

- Frontend: extend the command palette and shell launcher in `client/lib/app/`
  and `client/lib/core/navigation/` so users can open entities, switch spaces,
  create content, and jump to saved views.
- Backend: add quick-search and action endpoints only where current list and
  search APIs are not enough.
- UX: maintain parity between keyboard-triggered desktop flows and mobile-safe
  launcher entry points.

## Notifications And Attention Management

- Frontend: evolve notifications into a first-class panel with categories,
  unread filters, batch actions, mute, and snooze behavior.
- Backend: normalize notification types across mentions, approvals,
  assignments, due reminders, and incident updates.
- Product rule: clearly separate informational notices from work that requires
  action so later inbox features can build on the same model.

## Saved Views And Cross Screen Query State

- Backend: add persisted saved-view definitions for tasks, incidents, KB lists,
  SOP queues, analytics filters, and cross-space search.
- Frontend: create one shared saved-view picker and editor used by dashboard,
  tasks, analytics, and space workspace surfaces.
- Data model: define a reusable filter schema instead of per-feature ad hoc
  JSON payloads.

## Accessibility, Responsive Layout, And Cross Browser Polish

- Frontend: keep auditing `client/lib/app/` and feature screens for keyboard
  access, focus behavior, readable contrast, responsive density, and browser
  quirks.
- QA: test desktop and mobile layouts with narrow-height cases so sticky
  headers, drawers, and detail screens do not steal too much content area.
- Product rule: every new screen pattern should prove itself on both touch and
  pointer-driven layouts instead of assuming desktop-first behavior.

## Localization Ergonomics

- Backend: keep `backend/app/modules/localization/` focused on stable runtime
  bundle generation, missing-key visibility, and safe update paths.
- Frontend: remove hard-coded copy where possible and keep screen-level strings
  organized so large workflow surfaces remain translatable.
- Tooling: add tests and documentation around translation fallbacks, key naming,
  and safe bundle reset or migration behavior.

## Inline Editing And Unified Editors

- Frontend: keep replacing fragmented modal-heavy editors with full-screen or
  inline flows in `client/lib/features/spaces/` and `client/lib/features/tasks/`.
- Shared components: standardize title, tags, assignee, due date, state, folder
  placement, and metadata editors so KB, SOP, incident, and task surfaces
  behave predictably.
- Product rule: reading and editing content should come first; history, audit,
  and rarely used controls should stay collapsed until requested.

## Context Side Panels And Related Entity Navigation

- Frontend: add reusable side panels and drawers for metadata, people,
  attachments, related entities, and history in detail screens that do not need
  full route changes.
- Navigation: preserve full-screen behavior on mobile while desktop can use
  split views or side sheets where they add density without confusion.
- Backend: expose related-entity summaries efficiently so side panels do not
  require a large burst of independent requests.

## Drafts And Autosave

- Frontend: add local and server-backed drafts for KB docs, incident updates,
  postmortems, SOP editing, and task editing.
- Backend: introduce draft persistence, conflict handling, recovery state, and
  last-edited metadata in the relevant content modules.
- UX: make the distinction between draft state and published or live state
  explicit and recover interrupted work after refresh or device changes.

## Universal Quick Create

- Frontend: add a single quick-create surface that can create tasks, incidents,
  SOP runs, KB docs, folders, reminders, attachments, and invites from
  anywhere.
- Backend: ensure minimal create endpoints return enough summary data for
  immediate optimistic UI insertion and post-create navigation.
- Navigation: wire quick create into dashboard, shell, command palette, and
  mobile navigation surfaces.

## Bulk Operations And Import Export

- Frontend: add multi-select patterns to tasks, KB lists, SOP lists, and
  incident lists for assign, move, tag, close, and request-review actions.
- Backend: add safe bulk mutation endpoints with permission checks, audit
  events, and partial-failure reporting.
- Data portability: add structured import and export flows for tasks, users,
  KB content, SOPs, incidents, and space-level audit-friendly bundles.

## Analytics And Admin Review Maturity

- Backend: expand analytics summaries, trends, and entity-level rollups so the
  platform answers operational questions instead of only showing raw counts.
- Frontend: improve `client/lib/features/analytics/` and admin review surfaces
  with clearer filters, better defaults, and drill-downs into actionable items.
- Admin: mature organization-level access review, audit, and approval workflows
  instead of hiding them in scattered one-off screens.

## Service And Screen Modularization

- Backend: split oversized services, routers, and schema files into smaller
  focused modules so features stop depending on multi-thousand-line files.
- Frontend: keep breaking large screens in `client/lib/features/spaces/`,
  `client/lib/features/tasks/`, and `client/lib/app/` into smaller widgets,
  controllers, and shared view models.
- Maintenance goal: make new feature work cheaper by reducing merge pressure,
  hidden coupling, and brittle screen-level state.

## Task Workflow Expansion

- Backend: extend `backend/app/modules/tasks/` with recurring tasks, subtasks,
  dependencies, blocked-by links, and stronger provenance back to incidents,
  SOPs, and docs.
- Frontend: redesign task list and detail surfaces in
  `client/lib/features/tasks/` so hierarchy, blockers, recurrence, and
  ownership are visible without turning the screen into a control wall.
- UX: support both personal task management and cross-team operational
  follow-through.

## SOP Execution Maturity

- Backend: extend `backend/app/modules/sop/` with pause and resume, handoff,
  required evidence, explicit skip reasons, and step signoff semantics.
- Frontend: simplify SOP authoring, reading, and run-execution screens in
  `client/lib/features/spaces/` so each mode is visually distinct but still
  consistent with the rest of the workspace.
- Audit: keep the execution trail available without letting it dominate the
  primary content surface.

## Incident Timeline And Response Maturity

- Frontend: keep incident detail in one operational timeline where status
  changes, reminders, comments, action items, and postmortem state share the
  same model.
- Backend: normalize incident events in `backend/app/modules/incidents/` so the
  frontend does not have to compose multiple conflicting timelines.
- Response model: add severity matrices, stakeholder updates, communication
  logs, impact tracking, and closure-linked postmortem action tracking.

## Review And Approval System

- Backend: add a shared approval engine that can be reused by KB publishing,
  SOP changes, postmortems, high-risk admin actions, and other gated workflows.
- Frontend: build one approval interaction pattern reused across spaces, tasks,
  and admin instead of separate custom review widgets for each module.
- Notifications: integrate approvals with reminders, inbox items, and
  escalation rules rather than handling them as isolated alerts.

## Cross Space Search Workspace

- Backend: expand search endpoints across KB, SOP, incident, task, and media
  modules to support grouped results, saved searches, subscriptions, and better
  ranking signals.
- Frontend: build a dedicated search workspace instead of relying only on local
  search bars embedded in each surface.
- Analytics: reuse search telemetry to surface no-result patterns, suggestion
  adoption, and content gaps.

## Linked Operations Graph

- Backend: add first-class relationship tables and services so docs, SOPs,
  incidents, tasks, people, and media can reference one another with typed
  links and backlinks.
- Frontend: render used-by, related-to, depends-on, and created-from surfaces
  across detail views.
- Product rule: linked context should be navigable without forcing users to
  memorize folder trees or tab paths.

## Cross Space Work Inbox

- Backend: create a normalized actionable-item feed that aggregates
  assignments, approvals, review requests, mentions, due reminders, and
  incident action items across modules.
- Frontend: add a dedicated inbox surface in the shell and dashboard with
  triage, filtering, snoozing, and direct-action workflows.
- Integration: the inbox should reuse notifications, watch state, approvals,
  and automation rules rather than inventing a disconnected data model.

## Templates And Playbook Packs

- Backend: add template models and pack import/export for KB docs, SOPs,
  incident playbooks, task bundles, and onboarding kits.
- Frontend: make templates available from quick create, space setup, and admin
  surfaces.
- Product rule: templates should capture structure, defaults, and linked
  context rather than only prefilled text.

## Workflow Automation Rules

- Backend: introduce a rules engine that can react to events such as incident
  creation, status changes, due-date thresholds, approval decisions, or new
  assignments.
- Frontend: add an admin-friendly automation builder with triggers, conditions,
  actions, previews, and run history.
- Integrations: automation should be able to create tasks, send notifications,
  attach SOPs, schedule reminders, assign owners, and apply templates without
  custom code.

## Database Migrations And Upgrade Safe Deployments

- Backend: move the data model toward explicit migrations and repeatable upgrade
  paths instead of relying on implicit schema drift handling.
- Deployment: define safe rules for upgrading seeded SQLite instances and
  PostgreSQL deployments without breaking operator data.
- Testing: add migration and upgrade coverage that exercises realistic version
  jumps before releases ship.

## Published Container Image Releases

- Release engineering: move from source-built release bundles toward tagged and
  published backend and frontend container images.
- CI/CD: extend GitHub workflows so version tags, changelog entries, tests, and
  container publishing follow one predictable release path.
- Docs: keep deployment guidance aligned with the real release artifact instead
  of assuming repository-source deployment forever.

## Native Android Packaging

- Client: add a supported Android target only after the web workflows, touch
  navigation, auth bootstrap, uploads, and notifications are stable enough to
  justify device packaging.
- Product: keep the app generalized so self-hosted users can enter their
  company domain during first-run setup instead of shipping per-deployment
  mobile builds.
- Release: document how Android distribution fits beside the web-first release
  model without bloating server deployment bundles.

## Desktop Native Distribution

- Client: evaluate macOS, Windows, and Linux packaging only after the web shell
  and navigation patterns feel stable enough to preserve in a desktop wrapper.
- UX: define which workflows genuinely improve on desktop-native packaging
  rather than assuming every web screen should become a desktop app.
- Release: keep desktop artifacts optional so they do not complicate the
  primary self-hosted deployment story.

## Backup And Restore Platform

- Backend: replace the current `backend/app/modules/backup/` prototype with a
  separate backup-database flow, likely a minimal SQLite schema that stores
  per-item JSON snapshots together with item UUID, parent UUID, child linkage,
  item type, timestamps, and restore metadata.
- Storage: keep backup SQLite data and uploaded file-storage assets portable
  together so they can be zipped, moved, and rsynced to cold storage.
- Product rule: remove per-item version history, soft delete, trash recovery,
  disable-as-recovery behavior, and similar recovery UI from normal feature
  surfaces; keep the normal lifecycle simple and rely on delete plus backup
  restore.
- Frontend: turn `client/lib/features/admin/backups/` into the main
  operator-facing restore surface for previewing historical items, selecting
  items to recover, running selective restores, and performing full-instance
  restore.
- Setup flow: on first setup, allow uploading a backup zip that contains the
  backup SQLite file and the file-storage directory so a self-hosted instance
  can restore from a local snapshot bundle.
- Planning constraint: keep this item last in the roadmap and update it any
  time earlier roadmap work changes entity shape, relationships, or stored
  files.
