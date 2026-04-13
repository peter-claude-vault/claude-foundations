# Plan 02 — Self Dry-Run Results

Three archetypes walked through `/onboard-foundation` end-to-end to verify the question flow, discovery compression, and 20-question budget. Each run records: discovery output → which blocks ran → which questions fired → resulting manifest sections.

---

## Archetype 1 — Consultant ("Example Consultant")

**Simulated environment**
- `$CLAUDE_DIR/settings.json` has MCP servers: `google_calendar`, `gmail`, `slack`, `granola`, `asana`
- `~/Documents/Strategy Vault/.obsidian/` exists with ~2,400 files
- `~/.gitconfig` has `user.name = Example Consultant`, `user.email = consultant@example.com`
- `.zshrc` mentions `brew`

**discovery_context (abbrev.)**
```json
{
  "existing_setup": true,
  "mcp_servers": ["asana","gmail","google_calendar","granola","slack"],
  "vault_candidates": [{"path":"~/Documents/Strategy Vault","file_count":2400,"organizational_hint":"custom"}],
  "git_identity": {"name":"Example Consultant","email":"consultant@example.com"},
  "dev_env": ["brew"]
}
```

**Questions asked (11 total — well under 20):**

Block 1 — Identity
1. "What do you do? Tell me about your role and the kind of work you focus on." → "Management consultant, pharma / biotech commercialization"
2. "What are you actively working on — projects, clients, initiatives?" → 3 engagements
3. "Who do you work with most?" → 4 people (partner, 2 clients, 1 analyst)
4. "Are you with an organization or solo?" → "Example Strategy Partners, 40-person boutique"

Block 2 — Tools (compressed; calendar/messaging/email skipped because MCP discovery is unambiguous)
5. "I see Granola connected — is that your transcription tool?" → confirm
6. "Anything on the project-management side?" → "Asana, I see it's already connected"

Block 3 — Knowledge Management (vault detected)
7. "I found an Obsidian vault at `~/Documents/Strategy Vault` with 2,400 files. Is this your main knowledge base?" → yes
8. "How is it organized? It looks custom — does that match how you think about it?" → "Engagements at the top, then client → workstream"
9. "What works about it? What frustrates you?" → qualitative notes
10. "Anything off-limits — private folders, sensitive material?" → `_Personal/`, `HR/`

Block 4 — Integrations
11. "I can connect to Google Calendar, Gmail, Slack, Granola, Asana. Which are useful, and read-only or read+write for each?" → all active, read on gmail+calendar, read+write on slack+asana+granola

Block 5 — Confirmation → single pass, user confirms.

**Manifest populated**
- `identity.role`, `identity.organization`, `identity.team_structure`, `identity.name/email`
- `tools.calendar`, `tools.messaging`, `tools.email`, `tools.transcription`, `tools.project_management`
- `vault.root`, `vault.organizational_method = "custom"`, `vault.protected_paths`
- `projects.active[]` (3), `people[]` (4)
- `integrations.active[]` (5 channels with permissions)
- `behavioral`, `tags`, `domain` → null (Phase 2/3)

**Budget check:** 11 questions. ✅

---

## Archetype 2 — Developer

**Simulated environment**
- `$CLAUDE_DIR/settings.json` has MCP servers: `slack`, `gmail`, `linear`
- No `.obsidian/` directory anywhere
- `~/.gitconfig` has `user.name = Example Developer`, `user.email = dev@example.com`
- `.zshrc` mentions `brew nvm go docker`

**Questions asked (9 total):**

Block 1
1. Role → "Backend engineer, SaaS"
2. Active work → 2 repos
3. People → 1 tech lead
4. Organization → IC on a distributed team (Q4 fired because `identity.organization` empty)

Block 2
5. Calendar → "Google Calendar" (no MCP for it, asked normally)
6. Messaging → skipped (Slack MCP is unambiguous)
7. Email → skipped (Gmail MCP is unambiguous)
8. Transcription → "None, I don't record meetings" → `null`

Block 3 — no vault detected
9. "Do you keep notes anywhere right now?" → "Not really, just GitHub issues"
10. "Would you like a structured local knowledge base? I can scaffold one." → "No, skip it"

→ `vault = null`. Q11 about scaffold location skipped.

Block 4 — Integrations
11. "I can connect to Slack, Gmail, Linear. Which are useful, read or read+write?" → all read-only, Linear + GitHub added to wishlist.

Block 5 — Confirmation.

**Manifest populated:** matches `examples/developer.json`.

**Budget check:** 11 questions. ✅

---

## Archetype 3 — Greenfield user

**Simulated environment**
- No `$CLAUDE_DIR` exists yet
- No `.obsidian/` directory
- `~/.gitconfig` missing
- `.zshrc` missing

**discovery_context:** all nulls / empty arrays. `existing_setup: false`.

**Questions asked (5 total — minimum viable):**

Block 1
1. Role → "Generalist knowledge worker" (user typed the generic phrase)
2. Active work → "Nothing structured yet, just exploring"
3. People → "Skip" → `people = null`
4. Organization → "Solo" → no team structure

Block 2
5. "Do you use a calendar / messaging / email tool I should know about?" → compressed to one question because all three lack MCP signals → "Not right now"

→ `tools.calendar/messaging/email = null`. Transcription skipped.

Block 3 — no vault, no existing notes
- "Do you keep notes anywhere?" → "No"
- "Want me to scaffold a local knowledge base?" → "Not yet, just experimenting"
→ `vault = null, greenfield = true` deferred.

Block 4 — no integrations available → skipped entirely.

Block 5 — Confirmation.

**Manifest populated:** matches `examples/greenfield.json` (mostly nulls, `identity.role` present).

**Budget check:** 5 questions. ✅ (Edge case: minimum path preserves budget and the interview never forces unused selections.)

---

## Edge cases rehearsed

| Case | Behavior |
|------|----------|
| No calendar, no messaging, no email | Block 2 collapses to a single compressed question; all three accept `null`. |
| No vault and no desire for one | Block 3 exits after two questions, `vault = null`. |
| No tools at all | Interview compresses to Blocks 1 + 5 (~5 questions). |
| Multiple vault candidates | Discovery flags in `conflicts[]`; Block 3 presents a choice — never silent-picks. |
| Existing manifest at `$MANIFEST` | Skill asks replace / merge / abort **before** discovery runs. |
| Validation failure pre-write | Return to Block 5 with the specific error; no partial manifest is written. |

## Question rewrites from the dry-run

- Block 2 Q5 was originally three separate questions (calendar / messaging / email). Merged into a single compressed question when all three lack discovery signals, saving 2 questions in the greenfield path.
- Block 4 Q12 originally asked "which integrations would you like?" without naming them. Rewritten to explicitly enumerate discovered channels — fewer round trips in confirmation.
- Block 1 Q4 originally always fired. Now gated on `identity.organization` being empty after Q1, since Q1 often answers it implicitly.

## Discovery script smoke test

```
$ CLAUDE_HOME=/tmp/test-claude HOME=/tmp/test-home discovery.sh
{ "claude_dir": "/tmp/test-claude", "existing_setup": true,
  "existing_skills": [], "mcp_servers": [], "vault_candidates": [],
  "git_identity": {"name": null, "email": null},
  "dev_env": [], "conflicts": [] }
```

Clean empty environment produces a well-formed, empty discovery_context with no errors. `jq` is the only runtime dependency.

## Status

Plan 02 complete pending downstream cross-verification by Plan 06 (Librarian must successfully consume any of the three archetype manifests).
