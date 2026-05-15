---
type: reference
description: Librarian packet-staleness-audit capability contract. Walks system-altitude packets, computes age from `last_reviewed`, surfaces drift findings at early-warning (150d) and overdue (180d) thresholds.
provides:
  - packet-staleness-audit-capability
  - 180-day-staleness-contract
updated: 2026-05-12
tags: ["#scope/reference"]
---

# Librarian capability — packet-staleness-audit

**Status:** specified (implementation deferred to a downstream sub-plan)
**Pillar consumer:** packet `last_reviewed` discipline (frontmatter pillar; `governance/frontmatter-rules.json#packet_only_fields`)
**Source rules:** `governance/frontmatter-rules.json#types.packet.required.last_reviewed`

## Purpose

Surface research-packet staleness before it becomes silent rot. System-altitude packets at `claude-stem/research/vault-construction/` and adopter packets at engagement / topic / initiative altitudes carry a `last_reviewed` ISO date in their YAML frontmatter; this field drives the audit. The capability walks every file with `type: packet`, computes age from `last_reviewed` (NOT from `updated`), and emits findings when the age crosses two thresholds: 150 days (early warning) and 180 days (overdue).

The capability is the audit-time enforcement layer for the packet-staleness contract — without it, packets accumulate documentation debt invisibly. The threshold pair gives operators a 30-day warning window before the contract breaks.

## Output Contract

**Files written:**
- Findings emitted to stdout (NDJSON; `librarian-finding` schema) and mirrored to `librarian-manifest.json` `drift_findings.packet_staleness[]` via `manifest_set`. No vault file writes; no packet file writes.

**Schema each is gated by:**
- NDJSON output validates against `librarian-finding-schema.json`.
- Manifest subtree mirror validates against `librarian-manifest-schema.json` `drift_findings.packet_staleness`.

**Pre-write validation steps:**
- Read the audit scope (configured packet directories — defaults to `research/vault-construction/` for foundation; adopter-configured roots via Layer 3).
- Read each candidate packet's frontmatter; verify `type: packet` AND `last_reviewed` is a valid ISO-8601 date.
- Reject schema-malformed packets with a `packet-frontmatter-malformed` finding rather than silently skipping.

**Failure mode:**
- `block and log` on schema-validation failure of the librarian-finding output schema. Audit run aborts; surfaces the schema mismatch so the operator can fix the capability implementation rather than ingesting malformed findings into the manifest.
- Never `write and hope`.

## Finding categories

| Category | Severity | Trigger | Findings payload |
|---|---|---|---|
| `packet-staleness-early-warning` | info | `now - last_reviewed >= 150 days AND < 180 days` | `{file_path, last_reviewed, age_days, altitude, validity_window, detected_at, first_seen}` |
| `packet-staleness-overdue` | warning | `now - last_reviewed >= 180 days` | `{file_path, last_reviewed, age_days, altitude, validity_window, detected_at, first_seen}` |
| `packet-staleness-validity-window-expired` | warning | `now > validity_window.end_date` | `{file_path, validity_window, age_days_past_window, detected_at, first_seen}` |
| `packet-frontmatter-malformed` | warning | Required `last_reviewed` or `validity_window` field missing / malformed | `{file_path, missing_or_malformed_fields[], detected_at, first_seen}` |

Severity `warning` findings count against the librarian's session-close summary; `info` findings surface but do not block close-out. The early-warning category lets adopters schedule re-review work before the contract breaks rather than triaging in reaction.

## Audit cadence

The capability is designed to run weekly via launchd cron (per the log-archive precedent). Weekly cadence:
- Catches the 30-day early-warning window comfortably (4-5 audit runs before a packet hits 180 days from the warning).
- Aligns with the existing logs-audit-cron weekly cadence so operators get a single weekly audit summary covering staleness + log accumulation.

Operators can run the capability on-demand at session-close via `/librarian packet-staleness-audit` (interactive invocation).

## Altitude-specific cadence (adopter customization)

Per the frontmatter-design packet (commitment 3, packet-only fields section), different packet altitudes have different `last_reviewed` cadences:

| Altitude | `last_reviewed` cadence | Threshold (early / overdue) |
|---|---|---|
| `system` | 180-day cycle | 150d / 180d (default) |
| `topic` | 90-day cycle | 75d / 90d *(seed default; Wave-2 validation target — verify against actual topic-packet usage patterns before locking)* |
| `engagement` | continuous (lifecycle-driven) | exempt from threshold-based audit; surfaced via T-38 governance-authoring hook on lifecycle close events |
| `initiative` | closed-at-plan-close | exempt from threshold-based audit; surfaced via T-38 governance-authoring hook on plan-close events |

Adopters extend the threshold map via Layer 3 overlay-master at `overlay-master.packet_staleness_thresholds` (sibling to foundation pillars post-install per canonical §H; `_path_placeholders.{schemas_root}` resolves to `~/.claude/governance/`). The capability reads the union of foundation + overlay at audit time.

**Lifecycle-close surfacing for `engagement` / `initiative` altitudes is T-38 scope.** The T-38 governance-authoring hook is the mechanism that surfaces packet-staleness for lifecycle-driven altitudes — at engagement archival or plan-close events, the hook fires and runs a propose-and-confirm review pass on any packets at those altitudes. This audit-time capability does not duplicate that check; weekly cron + on-demand invocation covers `system` and `topic` altitudes only.

## Input sources

The capability reads from (in order):

1. **`governance/frontmatter-rules.json`** — `types.packet.required.last_reviewed` (validates the field is contract-required); `packet_only_fields` (full packet field set; dissolved from schemas/vault-schema.json in SP13 T-4).
2. **`overlay-master.packet_staleness_thresholds`** (Layer 3 overlay; optional) — per-altitude threshold extensions / overrides.
3. **`research/vault-construction/*.md`** + adopter packet roots (configured at install time) — every file with `type: packet` is in scope.

## Exemptions

- Files declaring `tier: minimal` — opt-out from validation.
- Packets with `altitude: engagement` or `altitude: initiative` — lifecycle-driven, not threshold-based.
- Adopter-declared per-packet override via `last_reviewed_audit_exempt: true` frontmatter flag (use case: packets pinned to a specific historical state, e.g., archived methodology references).

## R-37 lockstep coupled surfaces

- `governance/frontmatter-rules.json` `types.packet.required.last_reviewed` + `packet_only_fields` (dissolved from schemas/vault-schema.json in SP13 T-4)
- `research/vault-construction/frontmatter-design.md` §Packet-only fields (the canonical narrative on the packet-only field class)
- Adopter Layer 3 `overlay-master.packet_staleness_thresholds` (when present)

Changes to packet frontmatter required-field shape or to the `last_reviewed` semantics trigger R-37 lockstep including this contract spec.

## Implementation hand-off

The capability is specified at this contract; a downstream implementation sub-plan delivers the runtime at `~/.claude/skills/librarian/capabilities/packet-staleness-audit.sh`. Implementation requirements:

- **Atomic writes** — manifest updates via `manifest_set` (atomic temp+rename).
- **Survivorship** — preserve `first_seen` on matched rows across runs; new rows append with next sequence number; resolved rows drop on observing run.
- **Read-only** to packet files.
- **bash 3.2 compatible** — per CONTRIBUTING.md §The bash 3.2 compatibility constraint.
- **Output Contract** — implementation MUST carry an Output Contract section per CONTRIBUTING.md §The Output Contract rule.
- **Date arithmetic discipline** — use `date -j -f` (BSD) for ISO-date parsing; never trust the locale-dependent `date -d`. Compute age in days via Julian-day conversion to avoid month-boundary edge cases.

## Companion: log-archive capability

The packet-staleness audit ships alongside the `log-archive` capability (`skills/librarian/capabilities/log-archive.sh`) ported from the reference deployment. Log-archive rotates `Logs/` files into dated archives; packet-staleness-audit surfaces staleness drift on research artifacts. Both run weekly via the `logs-audit-cron.plist` launchd template (`templates/launchd/`). Adopter install deploys both capabilities + the cron plist together so the audit infrastructure is operational from day 1.

## References

- Packet schema: `governance/frontmatter-rules.json` `types.packet` entry (dissolved from schemas/vault-schema.json in SP13 T-4)
- Research narrative: `research/vault-construction/frontmatter-design.md` §Packet-only fields
- Companion capability: `skills/librarian/capabilities/log-archive.sh`
- Launchd template: `templates/launchd/com.logs-audit.plist.tmpl`
- Librarian-finding schema: `schemas/librarian-finding-schema.json`
- Librarian-manifest schema: `schemas/librarian-manifest-schema.json` (`drift_findings.packet_staleness` subtree)
