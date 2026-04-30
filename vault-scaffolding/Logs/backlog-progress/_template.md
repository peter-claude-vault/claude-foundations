---
type: log
log-type: backlog-progress
parent_plan: <slug>
title: "<Project Title> — Progress Log"
date: <date>
timestamp: <timestamp>
created: <date>
updated: <date>
tags:
  - "#log/backlog-progress"
---

# <Project Title> — Progress Log

Satellite for backlog row `<Project Title>` (Plan `<slug>`). Append-only session history per sentinel pattern (R-29/R-30/R-31). The `System Backlog.md` row carries only a current-state pointer to this file; full reasoning, decisions, and per-session deltas live here.

## Plan Shape

One paragraph describing the project's scope, the sub-plans (if any), and the release waves or phases. Replace this paragraph with project-specific content on first session-close.

## Key Context

- Trigger or origin (what surfaced this project on the backlog).
- Decisions locked at scaffolding time (architecture, dependencies, scope guardrails).
- Cross-references to upstream plans, prior research, or related backlog rows.

## Session Log

### <date> — Session N — <session-headline>

- One-line bullet summary of what shipped this session.
- Files modified: `<path>` (commit `<sha>`), `<path>` (commit `<sha>`).
- AC ticked: `[T-N AC #M]`.
- Carry-forward flags: `<short-flag>` (reconcile at `<gate>`).
- Next up: `<task-id>` — `<one-line-scope>`.
