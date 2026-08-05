<!-- SPDX-FileCopyrightText: 2026 Bora Yarkin -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Domain And Data Model

OpsAtlas keeps operational knowledge, repeatable procedures, incidents, and
follow-up tasks in one workspace model.

## Core Concepts

| Concept | Meaning |
| --- | --- |
| Organization | Admin-managed people, roles, units, and brand settings |
| Space | A workspace boundary for KB docs, SOPs, incidents, tasks, and members |
| Knowledge Base | Documents organized by folders, tags, review status, and comments |
| SOP | A repeatable procedure with steps, runs, schedules, and evidence |
| Incident | A live or historical operational event with status, actions, reminders, and postmortem |
| Task | Follow-through work that can stand alone or link to SOPs/incidents |
| Media Asset | Uploaded files attached to supported entities through signed access |
| Analytics Event | User activity and search telemetry used for dashboards and quality views |

## Ownership Boundaries

Spaces are the primary collaboration boundary. Most operational content belongs
to a space and should enforce space membership before exposing data.

Admin and account data are global. They should not depend on a selected space
unless the endpoint explicitly scopes the operation to one.

Media assets attach to an entity through `entity_type` and `entity_id`. Upload
policy and signed URL handling live in the media module so feature modules do
not duplicate storage rules.

## Content Relationships

Knowledge base documents are reference material. They may have comments,
versions, reviewer suggestions, tags, and folder membership.

SOPs are executable procedures. SOP runs and run steps capture whether a
procedure was followed, by whom, when, and with what evidence.

Incidents are timeline-driven operational records. Status updates, reminders,
action items, and postmortems should remain visible as part of the same
incident story rather than being split across unrelated timelines.

Tasks are follow-through records. They may link back to SOP runs or incidents,
but they still need independent status, assignee, due-date, and comment
behavior.

## Permission Model

The common shape is:

1. Authenticate the user.
2. Resolve the organization or space boundary.
3. Check role or membership.
4. Apply feature-specific capability rules.
5. Perform the read or write.

Prefer existing service helpers for permission decisions. Duplicating role
checks inside route handlers makes the behavior harder to audit.

## Audit And History

OpsAtlas favors keeping operational history instead of overwriting it silently.
Good write paths should make it possible to answer:

- Who changed this?
- When did it change?
- What object did it affect?
- Was the change part of a space, SOP, incident, task, or global admin action?

When adding new writes, consider whether the analytics feed, status history, or
activity log should receive an event.

## Test Data

`scripts/seed_db.py` creates demo data that exercises the major relationships.
Tests should use isolated fixtures and `test.db`, not the seeded developer
database.
