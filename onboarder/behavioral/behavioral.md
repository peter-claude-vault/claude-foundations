# Behavioral Onboarder — design notes

## Why a separate phase

Phase 1 captures *what exists*: role, tools, vault, projects, people. Those answers are largely observable and stable. Behavioral preferences are different — they are subjective, they shift as users learn what Claude can do, and they benefit from being asked *after* the user has seen Phase 1's discovery summary, because that summary primes an informed answer ("oh, it already found my vault — so I don't need to babysit it every step"). Collapsing behavioral questions into Phase 1 would produce worse answers.

## Motivational-Interviewing frame

Closed questions force premature commitment ("do you want autonomy: low, medium, or high?"). MI opens the frame ("how much runway do you want me to take?") and lets the user describe their preference in their own words. The skill then reflects back the inferred enum value for confirmation. If the user rejects the inferred bucket, the free-text answer is preserved alongside.

## Fields and rationale

| Field | Type | Used by |
|-------|------|---------|
| `autonomy` | enum(low, medium, high) | Hooks (pre-tool-use gate), Librarian (mechanical vs. judgment tier), Advisor (how much to offer vs. wait) |
| `autonomy_exceptions[]` | string[] | pre-tool-use hook (hard gates that stay regardless of global autonomy) |
| `progress_verbosity` | enum | UserPromptSubmit hook (inject verbosity reminder into context) |
| `communication_style` | string | System prompt injection via SessionStart |
| `pushback_preference` | string | System prompt injection |
| `tone_rules[]` | string[] | System prompt injection (e.g., "no emojis", "no 'Great question'") |
| `cadence` | string | Orchestration planners |
| `response_length_preference` | string | System prompt injection |
| `time_rules[]` | string[] | Scheduling skills (quiet hours) |
| `notification_rules[]` | string[] | Stop hook (when to ping user) |
| `blocker_policy` | string | Error handlers across skills |
| `file_placement_policy` | string | Write-tool pre-hooks |
| `diff_preference` | string | Edit-tool pre-hooks |

## Why this shape

- **Autonomy is an enum**, not a scale. Three buckets (low/medium/high) map cleanly onto concrete behaviors: low = gate every side effect, medium = batch and show plan, high = run ahead with cleanup. A numeric scale invites false precision the user can't really specify.
- **Exceptions are separate** from the main autonomy setting because even a "high autonomy" user has red lines (never push to main, never delete outside the current directory). Collapsing them into the main field would lose information.
- **Tone rules are a list**, not a style string. Users give negative rules ("no exclamation points") more readily than positive ones, and lists compose.
- **Cadence and response length are separate** because they answer different questions. A user can want tight loops (short tasks) with long responses (detailed explanations), or long runs with terse reports.

## Integration points

- `session-start.sh` reads `behavioral.communication_style`, `tone_rules`, `response_length_preference` and emits them as a context reminder.
- `pre-tool-use.sh` reads `autonomy_exceptions[]` as hard gates.
- `user-prompt-submit.sh` reads `progress_verbosity` to adjust Claude's self-narration.
- `stop.sh` reads `notification_rules[]` to decide on OS-level notifications.
- Librarian and Advisor read `autonomy` to decide their mechanical/judgment tier split.

## Failure modes covered

- **Missing or invalid manifest**: hard prereq error with clear remediation ("run /onboard-foundation").
- **Partial answers**: nulls allowed, user can re-run to fill gaps.
- **Re-runs**: detect `"behavioral"` in `phases_completed` and ask before replacing.
- **Schema drift**: all writes validated against `manifest/schema.json` before atomic replace. Schema already has a behavioral section with `additionalProperties: true`, so new fields (`autonomy_exceptions`, `tone_rules`, etc.) slot in without schema changes.

## Dry-run consistency

The three dry-run personas (consultant, developer, greenfield) are the same three used by Phase 1's dry-run. Reusing them lets a reviewer trace a single hypothetical user across all three onboarding phases and see the full manifest that results.
