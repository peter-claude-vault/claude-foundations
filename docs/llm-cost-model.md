---
title: LLM Cost Model — Auto-Authoring Onboarding
audience: adopters, onboarder authors
status: shipped
shipped_in: SP12 T-3
---

# LLM Cost Model

The Plan 71 onboarder's auto-authoring layer (SP12 Group B) invokes an LLM on
five of the seven Tier-1 surfaces. The other two are deterministic
(template-based with field substitution; no LLM call). This document declares
the per-surface token estimates, the model assumptions, and the resulting
cost range surfaced to the user at the start of `/onboard`.

The cost-transparency block in `onboarding/ux/section-a.sh` reads from this
document — when these estimates change, the surfaced range changes
automatically once the section-a copy is rebuilt.

## Surface inventory

The seven Tier-1 surfaces and their LLM-vs-deterministic classification (per
the SP12 spec L116-122):

| # | Surface | Mode | Why |
|---|---|---|---|
| 1 | `~/.claude/CLAUDE.md` (composed prose) | LLM | Personal sections (communication style, working patterns, feedback preferences) are composed from interview answers; deterministic substitution would not produce real prose. |
| 2 | `~/.claude/projects/<user>/memory/` seeds (3-5 files) | LLM | Each seed file's body is composed from interview answers using LLM-driven prose synthesis; only the index lines are deterministic. |
| 3 | Vault `CLAUDE.md` (RDT + tag taxonomy + pre-write checklist) | LLM | The routing decision tree is composed conditional on declared organizational method; some sections (tag taxonomy header, pre-write checklist boilerplate) are deterministic, but the RDT itself is LLM-composed. |
| 4 | `_tag_prefixes[]` | Deterministic | Archetype-keyed table lookup. Consultant -> `engagement/`, `project/`, `scope/`. Researcher -> `topic/`, `paper/`, `dataset/`. No LLM call. |
| 5 | `doc-dependencies.json` | Deterministic | Cascade entry templates indexed by declared structure flags. No LLM call. |
| 6 | `frontmatter-enforce` per-capability config | Deterministic | Manifest-field substitution + alias map. No LLM call. |
| 9 | Architect prior-seed concerns + research topics | LLM | Composed from declared `identity.industry` + interview architect-concerns answers; industry-specific phrasing requires composition, not lookup. |

## Token estimates

Per-surface input + output token estimates, derived from interview-fixture
runs against the SP01 voice-capture transcripts:

| Surface | Input tokens (prompt + interview context) | Output tokens (composed artifact) | Total |
|---|---|---|---|
| #1 claude-home CLAUDE.md | ~4,500 | ~2,800 | ~7,300 |
| #2 memory seeds (3-5 files) | ~3,200 (shared context across files) | ~3,500 (cumulative) | ~6,700 |
| #3 vault CLAUDE.md | ~3,800 | ~2,400 | ~6,200 |
| #9 architect prior-seed | ~2,400 | ~1,200 | ~3,600 |
| **LLM total** | **~13,900** | **~9,900** | **~23,800** |

Surfaces #4 / #5 / #6 contribute zero LLM tokens.

## Model + pricing assumptions

The cost range surfaced in section-a assumes Anthropic API pricing as of
2026-05-03 for the model the onboarder targets. The block prints a range
because actual cost varies with interview transcript length (Section A's
discovery card is short; Section C/D voice-capture transcripts can range
from 1,500 to 6,000 tokens depending on user verbosity).

Default range surfaced:

- **With auto-authoring (full Tier-1 LLM surfaces):** $5-15
- **Without auto-authoring (deterministic surfaces only):** $1-3

The lower bound assumes a terse user (short transcripts, default-accept on
discovery card). The upper bound assumes a verbose user (long transcripts +
multiple correction passes through the three-step gate `[e]dit` step,
which re-runs the LLM pass on the edited input).

When pricing changes, update the range in `onboarding/ux/section-a.sh`
(search for `LLM_COST_RANGE_DISPLAY=`) and update the underlying token
math in this doc.

## Why surface this at onboarding start

Per the recalibration record §"Mandatory architectural guardrails" #5: the
auto-authoring layer can 3-5x onboarding cost vs a deterministic-only run.
Surfacing the range at the start protects user trust — the user explicitly
proceeds knowing what the run will cost. A user who sees "$5-15" up front
and types `[Y]es` has chosen the trade. A user who sees nothing and reads a
"this onboarding cost $12" message after the fact has been surprised, which
breaks trust on a tool whose value proposition is "do the writing the
competitors leave to you."

## Skipping the LLM surfaces

A `--skip-llm` flag on `/onboard` (deferred to v2.1 — not in SP12 scope)
will let the user opt into deterministic-only surfaces. For SP12, the
surfaced range communicates the option implicitly ("$1-3 without
auto-authoring") even though the flag isn't yet wired.

## Where this is consumed

- `onboarding/ux/section-a.sh` — the cost-transparency block at the top of
  the interactive flow. Block renders the surface inventory + range +
  Continue prompt before any auto-authoring fires.
- `_audit-2026-05-03/10-recalibration-decision-record.md` §"Mandatory
  architectural guardrails" #5 — the authoritative requirement.
