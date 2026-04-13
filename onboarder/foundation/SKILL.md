---
name: onboard-foundation
description: Phase 1 onboarding — discovery scan + conversational identity interview that produces the first user-manifest.json. Use when a user runs `/onboard-foundation` on a fresh install or wants to re-run Phase 1 to refresh their manifest.
---

# /onboard-foundation — Phase 1 Onboarder

Produce the user's first `user-manifest.json` through automated environment discovery followed by a short, conversational interview. This is the entry point to the personalization engine: everything downstream (hooks, Librarian, Advisor/Builder) reads the manifest this skill creates.

## When to invoke

- On a fresh install immediately after `install.sh` completes.
- When a user wants to re-run the foundation phase (e.g., they changed jobs, moved their vault, or want to start over). The skill detects an existing manifest and asks whether to replace, merge, or abort.

## Environment convention

All paths resolve relative to `$HOME/.claude`, which is where Claude Code reads its configuration. The skill's supporting assets live at fixed locations:

```
CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"
MANIFEST="$CLAUDE_DIR/user-manifest.json"
SCHEMA="$CLAUDE_DIR/manifest/schema.json"
VALIDATOR="$CLAUDE_DIR/manifest/validate-manifest.sh"
DISCOVERY="$CLAUDE_DIR/skills/onboard-foundation/discovery.sh"
```

Every filesystem write the skill performs targets `$CLAUDE_DIR` or a path the user explicitly confirmed. The skill never writes outside those locations.

Isolated test environments use a `HOME` override (e.g. `HOME=/tmp/fresh-claude claude`) — `$HOME/.claude` continues to resolve the same way, just pointing at a throwaway root.

## Execution directive

When invoked, **start the interview immediately**. Do not:

- Ask the user to confirm the skill name or setup.
- Surface "context you already see" (existing global CLAUDE.md, other skills, MCP servers) as a reason to abort or redirect.
- Suggest `/adopt` or any alternative skill before running the interview.
- Present a list of blockers before Part A.

Run Part A (discovery) silently, then present the summary, then begin Part B question 1. The whole point of this skill is to run cold. If a user invokes it, they want it to run — even if ambient signals suggest a mature setup. Surface those signals inside the discovery summary, not as blockers.

## Flow

### Part A — Automated Discovery (silent)

Run `onboarder/foundation/discovery.sh` before asking any questions. The discovery engine scans read-only and produces a `discovery_context` object summarizing what it found. It never modifies the user's filesystem.

Scan targets and the manifest fields each one pre-populates are documented in `discovery.md`. Summary:

| Source | Populates |
|--------|-----------|
| `$CLAUDE_DIR/settings.json` | `integrations.active[]`, `system.existing_setup` |
| `$CLAUDE_DIR/skills/*/SKILL.md` | `system.existing_skills[]` |
| `~/Documents/*/.obsidian/` | `vault.root`, `vault.organizational_method` (hint) |
| `~/.gitconfig` | `identity.name`, `identity.email` |
| Shell profile (`$HOME/.zshrc` or `$HOME/.bashrc`) | `tools.development_environment[]` |

Present the discovery summary to the user in plain language before the interview begins:

> "Here's what I found on your system: [list]. I'll confirm each of these as we go — let me know if anything looks wrong."

### Part B — Conversational Interview

**Under 20 questions. Motivational-Interviewing frame. Skip any question discovery already answered with high confidence.**

**Opening response-shape guidance (print verbatim before Q1):**

> "A few ground rules before we start. You can answer any of these questions by typing, or — if it's easier — record yourself talking for a minute or two and drop the transcript in. Raw context is more valuable to me than polished answers, so dump don't polish. If a question doesn't apply to you, say so and we'll move on. I'll reflect each answer back in one sentence so you can correct me before I lock it in."

#### Block 1 — Identity (3–4 questions)

1. **Top-down framing.** "Start broad: what do you do, who do you do it for, and what does a typical week look like? A few examples of the shape I'm looking for:
   - *Consultant:* 'I run client engagements in life sciences. Most weeks I'm juggling two or three active projects, each with a sponsor, a core team, and a board review cycle.'
   - *Designer:* 'I lead product design at a Series B startup. My week is half IC work in Figma, half design reviews and cross-functional alignment.'
   - *Engineer:* 'I'm a backend engineer on a payments team. Typical week is tickets, code review, an on-call rotation, and one or two design discussions.'
   Yours doesn't have to sound like any of these — I'm trying to understand the shape of your work, not fit it into a template." → `identity.role`, `identity.industry`, `identity.organization`, `identity.team_structure`
2. "What are you actively working on right now — projects, clients, initiatives, whatever takes your time?" → `projects.active[]`
3. **People scaffolding.** "Who do you work with most? There's no wrong format here — a few things that tend to work:
   - Paste the 'to/cc' line from a few recent email threads.
   - Paste a client list, org chart, or team directory.
   - Just dump names as bullets with a line of context each.
   Anyone recurring — team members, clients, stakeholders, a manager — is worth capturing." → `people[]`
4. (Only if `identity.organization` is empty and not discovered) "Are you with an organization, or solo? If there's a team, how is it structured?" → `identity.organization`, `identity.team_structure`

#### Block 2 — Tool Ecosystem (3 questions using hybrid gating)

The goal here is *not* to list every app on your machine. It is to capture which tools matter to your work and — critically — what constraints apply to each. Constraints come in two flavors:

- **`org-restricted`** — your IT department blocks native integration, but Claude may still suggest web-based workarounds (web MCP, browser automation, manual export).
- **`user-excluded`** — you do not want Claude to touch this tool under any circumstances. This is a hard filter. Advisor/Builder will never suggest it, even as a workaround.

Ask these three in order and build the `tools[]` array as you go.

5. **Tool inventory.** "Walk me through the tools you use most for work — calendar, email, messaging, note-taking, project management, development environment, anything else. Just list them; we'll talk about access in the next two questions." → provisionally populate `tools[]` with `name`, `category`, `integration_mode: "native"`, `constraint_type: "none"`.

6. **Org-restricted gate.** "Are any of those tools locked down by your employer or a client — things where you have the account but IT doesn't allow API access, automation, or MCP connections? I can still suggest workarounds for these (web-based flows, manual export, browser automation), but I need to know which ones they are." → for each named tool, set `constraint_type: "org-restricted"` and update `integration_mode` to `"web-mcp"`, `"manual"`, or `"blocked"` based on what's actually feasible. Capture *why* in `notes`.

7. **User-excluded boundary.** "Are there any tools you don't want me touching at all — not even as a workaround? Personal banking, health apps, a private journal, an employer's system you'd rather keep manual. Anything I should treat as off-limits forever." → for each named tool, set `constraint_type: "user-excluded"` and `integration_mode: "manual"` or `"blocked"`. Write a short `notes` line captioning the boundary ("User boundary — do not connect"). **These are immutable: the Librarian must never overwrite them, and Advisor/Builder must never propose workarounds.**

#### Block 3 — Knowledge Management (3–4 questions)

Obsidian is an install prerequisite, so a vault always exists by the time this block runs. Either discovery found one, or the user needs to create one now. The skill does not branch on "no vault" — it branches on "which vault."

8. "I found an Obsidian vault at [path] with [N] files. Is this your main knowledge base, or should I use a different one?" → `vault.path`, `vault.name` (use the parent directory name if the user doesn't give one explicitly). If the user points to a different vault, confirm the new path exists before proceeding.
9. "How is it organized? It looks like [detected pattern]. Does that match how you think about it — or is it more of a work-in-progress?" → `vault.organizational_method`, and set `vault.greenfield = true` if the vault is essentially empty.
10. "What works about it? What frustrates you?" → qualitative notes (stored in `vault.discovered_conventions.notes` for Phase 2/3 and Librarian).
11. "Anything in there that should be off-limits to me — private folders, sensitive material, client work under NDA?" → `vault.protected_paths[]`.

#### Block 4 — Integrations (conditional, 0–3 questions)

12. (Only if any tool from Block 2 has a matching integration channel) "Based on what you've told me, I can connect to [list]. Which of these would be useful?" → `integrations.active[]`
13. (For each selected) "Should I just read from [tool], or read and write?" → `integrations.active[].permissions`
14. "Anything else you'd want me to eventually work with?" → `integrations.wishlist[]`

#### Block 5 — Confirmation (1 question)

15. Present a human-readable summary grouped by section (not raw JSON). Flag which fields came from discovery vs. the interview. "Anything wrong or missing?" — collect corrections, apply, re-present until the user confirms.

### Part C — Manifest Generation Pipeline

1. Merge `discovery_context` defaults with interview answers; interview wins on conflict.
2. Populate Phase 1 sections: `system`, `identity`, `tools`, `vault`, `projects`, `people`, `integrations`. Leave `behavioral`, `tags`, `domain` as `null` (Phases 2/3 will fill these).
3. Set `system.phases_completed = ["foundation"]`, `system.schema_version = "1.0"`, `system.created_date` = today, `system.manifest_location = "$MANIFEST"`.
4. **Validate against `$CLAUDE_DIR/manifest/schema.json`.** Use `$CLAUDE_DIR/manifest/validate-manifest.sh <candidate-file>`. If validation fails, do NOT write — display the validation error, return to the confirmation step, and re-collect affected answers.
5. On successful validation, write to `$MANIFEST`.
6. Print the next-step message: `Run /librarian scan to bootstrap your vault, or /personalize to evaluate public skills against your manifest.`

### Part D — Vault Scaffolding (greenfield only)

If `vault.greenfield == true`:

1. Create the directory the user named in Block 3.
2. Generate a starter `CLAUDE.md` at the vault root from `identity`, `tools`, and `projects`.
3. Create `_index.md` stubs for `Inbox/`, `Projects/`, `Reference/`, `Archive/`.
4. Do nothing further — Plan 09 (`/adopt`) handles deep structural work later.

If an existing vault was detected, **never modify it.** Set `vault.root` and metadata only. Hand off to `/adopt` for structural mapping.

## Output Contract

```
Files written:
  - $HOME/.claude/user-manifest.json
  - (greenfield only) $vault_root/CLAUDE.md
  - (greenfield only) $vault_root/{Inbox,Projects,Reference,Archive}/_index.md

Schema type: user-manifest ($HOME/.claude/manifest/schema.json)

Pre-write validation:
  1. Run $HOME/.claude/manifest/validate-manifest.sh against a temp file containing the candidate manifest.
  2. Confirm system.phases_completed includes "foundation".
  3. Confirm identity.role is non-empty.
  4. Confirm no write target escapes $HOME/.claude or $vault_root.

Failure mode: block and log.
  - If validation fails, print the specific error, return to the confirmation step, and do not write.
  - If the vault write path would escape $vault_root, abort the entire skill and log to stderr.
  - Never write a partial or invalid manifest.
```

## Edge cases

- **No calendar / no messaging / no email:** Blocks 2 and 4 collapse — the skill accepts `null` for each unused tool, never forces a selection.
- **No vault detected but Obsidian installed:** Prompt the user to create or select a vault in Obsidian, then re-run `/onboard-foundation`. Do not proceed with a null vault — the schema now requires `vault.path` and `vault.name`.
- **No tools at all:** The interview compresses to Blocks 1 + 5 (≈5 questions). Budget is preserved.
- **Existing manifest at `$MANIFEST`:** Ask whether to replace, merge, or abort before running discovery. Never silently overwrite.
- **`$HOME/.claude/` does not exist:** Create it. The installer normally creates it, but a bare `HOME` override may leave the directory absent.

## Design sources (cold-start)

This skill was designed from first principles against:
- `02-ARCHITECTURE-SPEC.md` (Onboarder Phase 1 two-part design)
- `04-DESIGN-DECISIONS.md` (phased onboarding as separate skills; manifest ownership handoff)
- `03-EXTERNAL-RESEARCH.md` (OpenPaw wizard UX, obsidian-claude-pkm `/onboard` + `/adopt`, `/init` philosophy, Motivational Interviewing framing)

No personal data, session captures, or pre-existing manifests were used as inputs. The skill must work for a stranger.
