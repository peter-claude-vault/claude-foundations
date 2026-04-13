# Manifest Handoff Protocol

The critical seam where `user-manifest.json` ownership transfers from the Onboarder to the Librarian.

## Ownership timeline

```
t=0   /onboard-foundation runs              → Onboarder owns manifest
t=1   Onboarder writes $MANIFEST            → last write by Onboarder
t=2   /librarian scan runs for the first time
t=3   Librarian detects handoff state       → takes ownership
t=4   Librarian bootstraps and enriches     → Librarian owns manifest
tN    /onboard-behavioral runs              → Onboarder re-enters for Phase 2
tN+1  Librarian detects new phase + yields  → merges, resumes ownership
```

## Handoff state detection

The Librarian identifies a handoff candidate by checking:

```bash
jq -e '
  (.system.phases_completed | length > 0) and
  (.system.librarian_last_update == null)
' "$MANIFEST"
```

If true, the next Librarian action is a bootstrap scan, not a normal scan.

## Source attribution contract

Every field mutation carries a `source` marker. The canonical values:

| Source | Who writes it | Precedence |
|--------|---------------|------------|
| `onboarder` | Any Onboarder phase skill | Highest for fields it populates |
| `user-edit` | The user, by hand | Always wins on conflict |
| `librarian-scan` | Librarian bootstrap / maintenance | Lowest — never overrides the others |

The Librarian refuses any write that would change a field where the current `source` is not `librarian-scan`.

## Non-destructive enrichment

The Librarian's manifest writes are additive:

- Add new keys under a section: allowed.
- Update a key the Librarian previously wrote: allowed.
- Update a key written by the Onboarder or user: **refused**, logged as a Judgment-tier drift.

This preserves the user's intent and the Onboarder's interview answers across long periods of Librarian activity.

## Immutable fields (Librarian cannot touch)

Regardless of `source`, the Librarian treats these as absolutely immutable:

- **`tools[].constraint_type == "user-excluded"`** — a user-declared boundary. The Librarian cannot modify, remove, or downgrade these entries, and must not propagate information derived from them into other manifest fields. Only the user (via `user-edit`) or a fresh `/onboard-foundation` run may change them.
- **`tools[].constraint_type == "org-restricted"`** — the Librarian may observe drift (e.g., new MCP connectivity) and surface it as a Judgment-tier finding, but never silently downgrades the constraint. Downgrades require explicit user confirmation.
- **`vault.protected_paths[]`** — additive only. New protections may be proposed; existing ones may never be removed by the Librarian.

These rules exist because Advisor/Builder depends on them: `user-excluded` is a hard filter on recommendations, and if the Librarian could silently mutate constraint state the hard filter would leak.

## Phase 2 / Phase 3 re-entry

When a later Onboarder phase runs, it writes new fields with `source: "onboarder"` and updates `system.phases_completed`. On the next Librarian run, the Librarian:

1. Detects the new phase entry.
2. Replays its scan for any newly-available fields (e.g., `tags`, `domain.routing_rules`).
3. Merges non-conflicting discoveries.
4. Surfaces conflicts as Judgment-tier recommendations.

The handoff is never one-way — it's a rotation of stewardship between phases.
