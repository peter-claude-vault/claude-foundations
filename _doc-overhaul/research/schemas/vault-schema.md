---
superseded_at: 2026-05-16
superseded_by: governance/frontmatter-rules.json (type registry) + governance/tagging-rules.json (tag taxonomy) + governance/foundation-master.json (composed bundle)
note: vault-schema.json dissolved in SP13 Session 5–9. This research doc is historical record only.
---

> **SUPERSEDED (2026-05-16)** — `vault-schema.json` is dissolved. The type registry lives in `governance/frontmatter-rules.json#types`; the tag taxonomy lives in `governance/tagging-rules.json#taxonomy`; both are composed into `governance/foundation-master.json` (the runtime bundle). See `foundation-governance-target-state.md` §A for the canonical architecture. This document is preserved as historical research record only.

# vault-schema.json

**One-sentence definition:** The frontmatter contract for every canonical file type in a user's vault — declares which YAML keys are required and which are optional, keyed by `type`.

**Problem it solves:** Vaults accumulate heterogeneous notes (meeting notes, daily logs, PRDs, project files, references). Without a schema, frontmatter drifts silently — daily notes lose `processed`, meeting notes lose attendees, references lose `updated` — and downstream tools (graph view, librarian, dashboards) break in non-obvious ways. This schema is the single source of truth that pre-write hooks, post-write verifiers, and drift sweeps all consult to gate writes and surface drift.

**Top-level shape:** Top-level keys are canonical type names (`meeting-note`, `daily-note`, `project`, `prd`, `context`, `engagement`, `reference`, `index`, `briefing`, `archive`, `ideation-brief`, etc. — 21 types in v1.0.0). Each type maps to an object with `required` (array of frontmatter field names that MUST be present) and `optional` (array of fields the type may carry but doesn't have to). Two meta keys: `schema_version` (currently `"1.0.0"`) and `_tag_prefixes` (reserved, currently empty array).

The schema is intentionally additive: adding a new type = appending a key. Adding a new required field to an existing type = a coordinated change with the hooks that enforce R-32. The `type` allowlist is whatever keys exist at the top level minus the meta keys.

**Who writes it:** Hand-authored. Lives in the foundation-repo at `schemas/vault-schema.json`. `install.sh` Step 9 copies it into `$CLAUDE_HOME/schemas/`. It is one of the three "sanctioned schemas" that stays in the live install (vs. being moved foundation-repo-only).

**Who reads it:**
- `hooks/pre-write-guard.sh` — R-32 type allowlist (DENY) + R-40 plan-artifact frontmatter check
- `hooks/post-write-verify.sh` — frontmatter shape verification on PostToolUse
- `hooks/stop-drift-scan.sh` — vault-wide drift sweep on Stop hook
- `skills/librarian/capabilities/sanctioned-schema-drift-detect.sh` — verifies live copy is byte-identical to foundation source
- `skills/librarian` capabilities `drift-sweep`, `frontmatter-enforce`, `placement-validate`
- `skills/backlog-research`, `skills/seed-projects`, `skills/meeting-note-ingestor` — write-side validation against the relevant type before emitting frontmatter

**Concrete example:**
```json
{
  "schema_version": "1.0.0",
  "meeting-note": {
    "required": ["type", "date", "meeting_title", "attendees", "tags", "processed", "updated"],
    "optional": ["engagement", "project", "previous_instance", "granola_id", "granola_ids", "granola_url"]
  },
  "daily-note": {
    "required": ["date", "day", "processed", "tags"],
    "optional": []
  },
  "project": {
    "required": ["engagement", "project", "owner", "status", "updated", "tags"],
    "optional": []
  },
  "ideation-brief": {
    "required": ["type", "title", "created", "updated"],
    "optional": ["status", "tags", "parent_plan", "backlog_item"]
  },
  "_tag_prefixes": []
}
```

**Notes for doc rewrite:** The schema's contents are Peter-shaped (engagement/project/people types). For a docs rewrite, lean on the *contract* (type-keyed required/optional split) rather than the specific types. The 21 types in v1.0.0 are the foundation seed; users add new types by editing this file lockstep with the hook that enforces R-32. Worth flagging that R-32 (DENY unknown type) is the hard gate — adding a type to a write WITHOUT first updating the schema fails at PreToolUse.
