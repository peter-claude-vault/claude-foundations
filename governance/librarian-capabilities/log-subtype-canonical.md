---
type: reference
description: Hook + librarian capability contract for the log-subtype-canonical discipline. Write-time DENY on near-match drift in system-utility dimensions plus audit-time detection of unregistered subtypes drifting into the vault.
provides:
  - log-subtype-canonical-capability
  - log-subtype-hook-contract
  - r-05-enforcement
updated: 2026-05-13
tags: ["#scope/reference"]
---

# Hook + librarian capability — log-subtype-canonical

**Status:** specified (hook + librarian implementation deferred to a downstream sub-plan)
**Pillar consumer:** tagging (R-05) — system-utility dimension canonical-tag-per-routine discipline
**Source rules:** `governance/tagging-rules.json` R-05 + `governance/log-subtype-registry.json`

## Purpose

System-utility tag dimensions (`#log/*`, `#status/*`) are exempt from the 25-tag cap on user-facing dimensions, but they require a different discipline: **stable, canonical tag values per routine activity.** Without enforcement, LLM stochasticity fragments the operational subtype space within weeks — two runs of the same routine emit `#log/backlog-hygiene` vs `#log/backlog-cleanup` vs `#log/backlog-audit`, the operator's graph-view filter splits routine activity across variant spellings, and `Logs/` cross-reference queries return inconsistent result sets.

The log-subtype-registry is the structural answer: every routine activity registers its canonical tag value at first emission; the pre-write-guard hook DENIES near-match drift at write-time; the librarian capability surfaces unregistered subtypes drifting into the vault at audit-time.

## Two-layer enforcement

This contract specifies both layers:

**Layer 1 — Write-time hook (pre-write-guard.sh tag-validation branch).** Consults the registry on every system-utility tag write; DENIES near-match drift; routes genuinely-new subtypes through the registration prompt.

**Layer 2 — Audit-time librarian capability (log-subtype-canonical).** Walks the vault at session-close / weekly cron; surfaces unregistered subtypes + drift findings.

The two layers compose: the hook catches drift at the moment of write; the audit catches drift that lands through bypass scenarios (manual filesystem writes, registry-version mismatches, foundation-upgrade lag).

## Hook contract (Layer 1; pre-write-guard.sh tag-validation branch)

### Input

- File path being written (any file with frontmatter `tags:` field containing `#log/*` or `#status/*` tags).
- File's full `tags:` array.
- The runtime registry at `$CLAUDE_HOME/governance/log-subtype-registry.json` + adopter overlay at `$CLAUDE_HOME/governance/log_subtype_registry_overlay.json` (if present).

### Algorithm

For each `#log/<value>` or `#status/<value>` tag in the file's `tags:` array:

1. **Exact match.** If `<value>` matches a registered canonical subtype (foundation + overlay union), ALLOW the write through this branch.
2. **Near-match detection.** Compute Levenshtein distance and substring-containment against every registered subtype.
   - If `levenshtein(value, canonical) <= 2` for any registered `canonical` → near-match.
   - OR if `canonical` is a substring of `value` or `value` is a substring of `canonical` → near-match.
3. **Near-match DENY.** Surface the closest registered match and DENY the write with: `[R-05 NEAR-MATCH] tag '#<dim>/<value>' near-matches registered '#<dim>/<canonical>' (registered by <owner_skill | owner_cron>). Did you mean #<dim>/<canonical>? If genuinely new, register via /register-log-subtype before writing.`
4. **Genuinely new (no near-match).** Route through the **T-38 governance-authoring hook** (which absorbs the prior "Hook A" registration-prompt pattern from earlier design — see plan-tree Session-02b-hooks-spec.md §A): prompt the operator to register the new subtype + owner; on confirm, append to the adopter's Layer 3 overlay at `log_subtype_registry_overlay.json` and proceed with the write; on cancel, DENY.

### Output

`{verdict: "allow" | "deny" | "require-registration", tag, suggested_canonical, owner_hint, registry_path, audit_log_entry}`

### Failure mode

`block and log` on registry-schema-malformed or registry-unreadable. The hook does not silently allow writes when its enforcement input is malformed; it logs the failure to the hook audit log + DENIES the write with a "registry-unreadable" finding.

## Librarian capability contract (Layer 2; log-subtype-canonical)

### Output Contract

**Files written:**
- Findings emitted to stdout (NDJSON; `librarian-finding` schema) and mirrored to `librarian-manifest.json` `drift_findings.log_subtype_canonical[]` via `manifest_set`. No vault file writes; no registry writes.

**Schema each is gated by:**
- NDJSON output validates against `librarian-finding-schema.json`.
- Manifest subtree validates against `librarian-manifest-schema.json` `drift_findings.log_subtype_canonical`.

**Pre-write validation steps:**
- Read `governance/log-subtype-registry.json` + adopter overlay; compute the union canonical set.
- Walk every file with `#log/*` or `#status/*` tag.

**Failure mode:**
- `block and log` on registry-schema-malformed or finding-output-schema-malformed.

### Finding categories

| Category | Severity | Trigger | Findings payload |
|---|---|---|---|
| `log-subtype-unregistered` | warning | Vault carries a `#log/*` or `#status/*` tag with no exact match in the registry union | `{file_path, dimension, tag_value, suggested_canonical (if near-match), detected_at, first_seen}` |
| `log-subtype-near-match-drift` | warning | Two or more registered subtypes are within Levenshtein 2 of each other (near-duplicates in the registry itself) | `{dimension, conflicting_subtypes[], registry_paths[], detected_at, first_seen}` |
| `log-subtype-owner-orphan` | info | A registered subtype has no `owner_skill` AND no `owner_cron` AND has not been written in >90 days | `{dimension, subtype, last_seen, detected_at, first_seen}` |

Severity `warning` findings count against the librarian's session-close summary; `info` findings surface but do not block close-out.

**Layer-3 overlay collisions are NOT an audit-time finding category** (per R-52 Session 15 revision): collisions between adopter overlay and foundation canonical on log-subtype values are caught at write-time by the Layer-1 hook (the near-match + registration-prompt flow above already covers the collision case at the moment the adopter writes the overlay). Audit-time backstop is unnecessary because there is no path for a colliding overlay to land without passing through the write-time hook.

### Invocation modes

| Mode | Trigger | Output |
|---|---|---|
| Weekly cron | Aligned with the `com.logs-audit` cadence; runs every 7 days | Manifest-mirrored findings + stdout NDJSON |
| On-demand | `/librarian govern` invocation mode or direct CLI invocation | Same outputs; operator chooses the moment |

## Skill-side declaration contract

Every skill, cron, or capability that emits log files MUST declare its canonical log-subtype in its SKILL.md frontmatter (or in the launchd plist comment header for cron wrappers):

```yaml
---
name: backlog-hygiene
description: Scans System Backlog for stale items …
log_subtype: backlog-hygiene
---
```

The declaration is immutable across runs — once a skill registers `log_subtype: backlog-hygiene`, every subsequent emission MUST use that exact tag value. Foundation-repo's `skills/*/SKILL.md` templates include the declaration as a required-field block; adopter skills inherit the discipline from the template scaffold.

For cron wrappers (no SKILL.md), the declaration lives as a comment header at the top of the wrapper shell script:

```bash
#!/bin/bash
# log_subtype: digest-run
# owner_cron: com.digest-run
…
```

The skill-declaration is the source-of-truth for the registry's `owner_skill` / `owner_cron` fields. R-37 lockstep requires registry updates to match the skill declaration on emission.

## R-37 lockstep coupled surfaces

- `governance/log-subtype-registry.json` (this registry)
- `governance/tagging-rules.json` R-05 (the canonical rule consuming the registry)
- `governance/librarian-capabilities/log-subtype-canonical.md` (this contract)
- `governance/tagging-rules.json#taxonomy.system_utility_dimensions` (SP13 T-4 absorbed from dissolved schemas/vault-schema.json `_tag_prefixes_meta system_utility_dimensions`)
- `onboarding/scaffold/vault-architecture/Vault Architecture - Tagging.md §System-utility dimension exemption` (narrative spoke)
- `hooks/pre-write-guard.sh tag-validation branch` (runtime hook)

Adding a new system-utility dimension (beyond `#log/*` and `#status/*`) requires R-37 atomic lockstep across all six surfaces. Adding a new subtype within an existing dimension is a registry-only change (foundation-repo path) or Layer 3 overlay change (adopter path) — no schema, no rule registry, no narrative spoke update required for subtype additions.

## Implementation hand-off

The contract is specified here; a downstream implementation sub-plan delivers:

- **Hook implementation** at `~/.claude/hooks/pre-write-guard.sh` tag-validation branch extension. Reads the registry at hook fire; consults near-match algorithm; emits DENY or registration-prompt verdict. bash 3.2 compatible per CONTRIBUTING.md.
- **Librarian capability implementation** at `~/.claude/skills/librarian/capabilities/log-subtype-canonical.sh`. Atomic writes; survivorship; Output Contract section per CONTRIBUTING.md.
- **Registration flow** is delivered by the **T-38 governance-authoring hook** (which absorbs the prior "Hook A" pattern from Session-02b-hooks-spec.md §A and extends it across all governance-authoring trigger conditions — new folder, new file type, unknown archetype, lifecycle-close events, unknown log-subtype). T-38 hook handles the interactive prompt + commit to Layer 3 overlay path; this contract does not need a separate `/register-log-subtype` skill — the unified hook covers it.

## References

- Companion rule: `governance/tagging-rules.json` R-05
- Companion registry: `governance/log-subtype-registry.json`
- Design rationale: ADR-0004 (system-utility dimension exemption)
- Layer-3 collision tiebreaker: ADR-0006 (R-52) — write-time DENY in pre-write-guard.sh; this contract's Layer-1 hook is the relevant write-time enforcement surface for log-subtype collisions
- Unified registration flow: T-38 governance-authoring hook (absorbs Session-02b "Hook A" pattern; SP03 plan-tree task entry)
- Narrative spoke: `Vault Architecture - Tagging.md §System-utility dimension exemption`
- Schema: `governance/tagging-rules.json#taxonomy.system_utility_dimensions` (SP13 T-4 absorbed from dissolved schemas/vault-schema.json)
