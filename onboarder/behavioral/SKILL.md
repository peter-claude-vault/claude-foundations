---
name: onboard-behavioral
description: Phase 2 onboarding — a short Motivational-Interviewing-framed interview that captures the user's autonomy preferences, communication style, working cadence, notification rules, and file-handling preferences. Enriches the existing user-manifest.json. Requires Phase 1 (/onboard-foundation) to have completed first.
---

# /onboard-behavioral — Phase 2 Onboarder

Capture *how* the user wants to work with Claude. Phase 1 captured *what* they do (role, tools, vault, projects). Phase 2 captures preferences that shape every subsequent interaction: how autonomous to be, how to phrase responses, when to interrupt vs. batch, and how to handle files.

## Prerequisites

- `$HOME/.claude/user-manifest.json` must exist and be valid.
- `system.phases_completed` must include `"foundation"`.
- If either check fails, the skill prints:
  > "This skill requires Phase 1 to be complete. Run `/onboard-foundation` first, then come back to `/onboard-behavioral`."
  and exits cleanly.

## Environment convention

```
CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"
MANIFEST="$CLAUDE_DIR/user-manifest.json"
VALIDATOR="$CLAUDE_DIR/manifest/validate-manifest.sh"
```

All writes target `$MANIFEST`. Nothing else is touched.

## Execution directive

When invoked, **start the interview immediately**. Do not:

- Ask the user to confirm the skill name.
- Redirect to another skill or ask "are you sure you want this?".
- Pre-summarize what's about to happen before asking question 1.

Run the prerequisite check silently, then, if it passes, go directly into Block 1. If it fails, print the Phase 1 message above and stop.

## Flow

The interview has five short blocks. Target budget: **12–15 questions**. Every question uses a Motivational-Interviewing frame: open-ended where the answer is qualitative, closed where a bounded choice is required. Reflect each answer back in one sentence before moving on.

### Block 1 — Autonomy (2–3 questions)

1. "When you ask me to do something, how much runway do you want me to take? Should I wait for confirmation at every step, batch changes and show you the plan first, or run ahead and clean up after?" → `behavioral.autonomy` ∈ `{low, medium, high}`
2. "Are there categories of action where you always want me to stop and check — for example, deleting files, pushing to git, sending messages?" → `behavioral.autonomy_exceptions[]` (free text)
3. (If autonomy is `high`) "And when I'm running ahead, how loud should I be while I work — silent unless done, one-line progress, or a running narrative?" → `behavioral.progress_verbosity`

### Block 2 — Communication style (3 questions)

4. "When I respond to you, do you prefer terse and direct, structured with headers, or conversational?" → `behavioral.communication_style`
5. "Do you want me to challenge your assumptions and push back, or keep challenges rare and only when something is clearly off?" → `behavioral.pushback_preference`
6. "How do you feel about emojis, exclamation points, and filler phrases like 'Great question'?" → `behavioral.tone_rules[]`

### Block 3 — Cadence and timing (2–3 questions)

7. "How do you prefer to work in a session — short tight loops where I do one thing and wait, or long runs where I complete a whole task and come back?" → `behavioral.cadence`
8. "Is there a point where responses become too long for you? A rule of thumb I should respect?" → `behavioral.response_length_preference`
9. (Optional) "Any time-of-day or day-of-week patterns I should know about — times you want me quiet, times you want more verbose output?" → `behavioral.time_rules[]`

### Block 4 — Notifications and interruptions (2 questions)

10. "When I finish a long-running task, should I notify you somehow, or just let you come find the result?" → `behavioral.notification_rules[]` (one entry)
11. "If I hit a blocker mid-task, do you want me to stop and surface it immediately, or keep trying alternatives until I'm truly stuck?" → `behavioral.blocker_policy`

### Block 5 — File handling (2 questions)

12. "When I create files, do you want them in a standard location I pick, or should I always ask where?" → `behavioral.file_placement_policy`
13. "Do you want me to always show a diff before writing, show it only on large changes, or just write and let you read the result?" → `behavioral.diff_preference`

### Block 6 — Confirmation (1 question)

14. Present a plain-language summary of everything captured, grouped by block. "Anything wrong or missing?" — collect corrections, apply, re-present until confirmed.

## Manifest generation pipeline

1. Load the current manifest. Abort if missing or if `"foundation"` not in `phases_completed`.
2. Build the enriched manifest in memory: set `behavioral.*` from answers, add `"behavioral"` to `system.phases_completed` (unique), update `system.last_updated`.
3. Write the candidate to a temp file.
4. Run the validator. On failure: display the error, return to the confirmation block, do not write.
5. On success: atomic `mv` over `$MANIFEST`.
6. Print: `Phase 2 complete. Run /onboard-domain to capture vocabulary, tags, and routing preferences.`

## Output Contract

```
Files written:
  - $HOME/.claude/user-manifest.json (behavioral section + phases_completed)

Schema type: user-manifest ($HOME/.claude/manifest/schema.json)

Pre-write validation:
  1. Manifest exists and is valid JSON (abort otherwise).
  2. system.phases_completed includes "foundation" (abort otherwise).
  3. Candidate manifest validates against schema.json.
  4. Write target is exactly $MANIFEST; no other path.

Failure mode: block and log.
  - Any validation failure returns to the confirmation block and does not write.
  - The original manifest is never touched until the atomic mv step succeeds.
  - Never write a partial or invalid manifest.
```

## Edge cases

- **User skips a block entirely** ("I don't know yet"): record `null` for those fields and continue. The Librarian can revisit.
- **Re-run against an already-Phase-2 manifest**: detect `"behavioral"` in `phases_completed`, ask whether to replace, merge, or abort. Never silently overwrite.
- **Malformed manifest found on entry**: abort with the same Phase 1 instruction — the prerequisite is a *valid* manifest.
- **User answers with long qualitative text**: store verbatim under the relevant free-text field; do not try to coerce into an enum.

## Design sources (cold-start)

Designed from first principles against:
- `02-ARCHITECTURE-SPEC.md` — Phase 2 Onboarder (`/onboard-behavioral`) section
- `04-DESIGN-DECISIONS.md` — phased onboarding, manifest as shared contract
- `03-EXTERNAL-RESEARCH.md` — Motivational Interviewing framing, short-interview best practices

No personal data, session captures, or pre-existing manifests were used as inputs. The skill must work for a stranger.
