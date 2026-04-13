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

All paths resolve via the `CLAUDE_HOME` env var with a fallback:

```
CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"
MANIFEST="$CLAUDE_DIR/user-manifest.json"
```

Every filesystem write the skill performs targets `$CLAUDE_DIR` or a path the user explicitly confirmed. The skill never writes outside those locations.

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

#### Block 1 — Identity (3–4 questions)

1. "What do you do? Tell me about your role and the kind of work you focus on." → `identity.role`, `identity.industry`
2. "What are you actively working on right now — projects, clients, initiatives, whatever takes your time?" → `projects.active[]`
3. "Who do you work with most? Anyone I should know about — team members, clients, stakeholders?" → `people[]`
4. (Only if `identity.organization` is empty and not discovered) "Are you with an organization, or solo? If there's a team, how is it structured?" → `identity.organization`, `identity.team_structure`

#### Block 2 — Tool Ecosystem (3–5 questions, discovery-compressed)

5. "What's your calendar — Google, Outlook, Apple, or something else?" → `tools.calendar`
6. "Where do your work messages live — Slack, Teams, Discord, other?" → `tools.messaging`
7. "And email — Gmail, Outlook, something else?" → `tools.email`
8. (Conditional) If discovery found a transcription tool: "I noticed [tool] on your system — is that what you use for meeting notes?" → `tools.transcription`. Otherwise: "Do you record or transcribe meetings? Which tool?"

Skip any of 5–7 whose answer is already obvious (e.g., MCP server for Google Calendar is connected).

#### Block 3 — Knowledge Management (branching, 3–6 questions)

*If a vault was detected:*

9. "I found an Obsidian vault at [path] with [N] files. Is this your main knowledge base?" → confirm `vault.root`
10. "How is it organized? It looks like [detected pattern]. Does that match how you think about it?" → `vault.organizational_method`
11. "What works about it? What frustrates you?" → qualitative notes (stored in `vault.discovered_conventions.notes` for Phase 2/3 and Librarian)
12. "Anything in there that should be off-limits to me — private folders, sensitive material?" → `vault.protected_paths[]`

*If no vault was detected:*

9. "Do you keep notes or documents anywhere right now — Notion, Apple Notes, plain files, nothing yet?" → discovery follow-up
10. (If "yes, somewhere else") "Would you like to keep using that, or would a structured local knowledge base be useful? I can scaffold one." → sets `vault.greenfield` or leaves `vault` null
11. (If scaffolding wanted) "Where should it live? Default is `~/Documents/knowledge/`." → `vault.root`, `vault.greenfield = true`

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
4. **Validate against `manifest/schema.json`.** Use `manifest/validate-manifest.sh`. If validation fails, do NOT write — display the validation error, return to the confirmation step, and re-collect affected answers.
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
  - $CLAUDE_HOME/.claude/user-manifest.json (or $HOME/.claude/user-manifest.json fallback)
  - (greenfield only) $vault_root/CLAUDE.md
  - (greenfield only) $vault_root/{Inbox,Projects,Reference,Archive}/_index.md

Schema type: user-manifest (manifest/schema.json)

Pre-write validation:
  1. Run manifest/validate-manifest.sh against the candidate manifest.
  2. Confirm system.phases_completed includes "foundation".
  3. Confirm identity.role is non-empty.
  4. Confirm no write target escapes $CLAUDE_HOME or $vault_root.

Failure mode: block and log.
  - If validation fails, print the specific error, return to the confirmation step, and do not write.
  - If the vault write path would escape $vault_root, abort the entire skill and log to stderr.
  - Never write a partial or invalid manifest.
```

## Edge cases

- **No calendar / no messaging / no email:** Blocks 2 and 4 collapse — the skill accepts `null` for each unused tool, never forces a selection.
- **No vault and no desire for one:** `vault = null`. Discovery, hooks, and Librarian all treat `null` vault as "operate against plain files in CWD."
- **No tools at all:** The interview compresses to Blocks 1 + 5 (≈5 questions). Budget is preserved.
- **Existing manifest at `$MANIFEST`:** Ask whether to replace, merge, or abort before running discovery. Never silently overwrite.
- **`$CLAUDE_HOME` points to a directory that does not exist:** Create it. Never assume `~/.claude/` exists.

## Design sources (cold-start)

This skill was designed from first principles against:
- `02-ARCHITECTURE-SPEC.md` (Onboarder Phase 1 two-part design)
- `04-DESIGN-DECISIONS.md` (phased onboarding as separate skills; manifest ownership handoff)
- `03-EXTERNAL-RESEARCH.md` (OpenPaw wizard UX, obsidian-claude-pkm `/onboard` + `/adopt`, `/init` philosophy, Motivational Interviewing framing)

No personal data, session captures, or pre-existing manifests were used as inputs. The skill must work for a stranger.
