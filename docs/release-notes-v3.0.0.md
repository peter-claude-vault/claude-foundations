# Claude Stem v3.0.0 — Consolidated 8-Pillar Governance Foundation

**Released:** [PLACEHOLDER — set at T-15b final tag cut]

[PLACEHOLDER — summary paragraph: v3.0.0 ships the consolidated 8-pillar governance bundle composed at release time, the matcher-split hook architecture (Edit|Write + AskUserQuestion), the writer pipeline substrate (writer-reconciler + doc-amender + manifest.sqlite + daily-processing), the two-root state-tier topology (durable second-brain artifacts + ephemeral Claude-runtime), and the System Governance spoke content authored as stable user-owned narrative. SemVer MAJOR per 18 breaking changes (see CHANGELOG.md).]

---

## What's new

### Consolidated 8-pillar governance bundle

[PLACEHOLDER — describe foundation-master.json as release-time-composed bundle, sha256-protected via foundation-manifest. Cite `[[feedback_ship_bundle_dont_build_on_consumer]]`. New pillar 7 fields (`daily_processing_root`, `writer_manifest_path`, `historical_data_warning_default`); new `write_shape` enum on file-type contracts.]

### Writer pipeline substrate

[PLACEHOLDER — describe writer-reconciler runtime (renamed from inbox-processor), daily-processing JSONL step 8.5 + manifest.sqlite step 8.6, doc-amender Bucket-1(b) runner with 3-signal survivorship (operator-edit + amender_paused + reviewed:true), `/amend-accept` triage skill.]

### Two-root state-tier topology

[PLACEHOLDER — describe `$VAULT_WRITER_STATE_ROOT` (durable; XDG-compliant at `~/.local/share/claude-stem/vault-writers/`) + `$CLAUDE_STATE_ROOT` (ephemeral; `~/.local/state/claude-stem/`) + back-compat symlink at `~/.claude/state/` (deprecated; remove in v4). Decision rule: "would this survive a Claude reinstall + harness switch?"]

### System Governance spoke content

[PLACEHOLDER — describe 6 spokes (Frontmatter, Tagging, Naming, Mandatory-Files, Doc-Dependencies, File-Type-Contracts) authored as stable user-owned narrative per Q2.3 reframe. Pointer-to-JSON pattern.]

### Matcher-split hook architecture

[PLACEHOLDER — describe pre-write-guard.sh (Edit|Write) + pre-asq-guard.sh (AskUserQuestion). Decision-Quality Protocol port to AskUserQuestion branch per A50 + L-83.]

### Provenance: manifest.sqlite

[PLACEHOLDER — describe LangChain SQLRecordManager-aligned schema, append-only with logical supersession, WAL mode, indexes on ingestion_date/destination_path/source_id/writer_id. Bootstrapped at install via lib/manifest-record.sh.]

### Doc-dependencies first-class pillar

[PLACEHOLDER — describe doc-deps as own pillar; 3 kinds (registration, hub-spoke, writer-fan-in); va-hub-spoke `propagation_rule` removed entirely per §A63 / L-110..L-113 + `[[feedback_field_before_consumer_risky]]`.]

---

## Breaking changes

See `CHANGELOG.md` v3.0.0 entry for the full 18-item inventory. Headline classes:

- **Vault folder renames** — Inbox/ → Vault Writers/; Archive/ → Logs/Archive/; Vault Architecture/ → System Governance/ (universal)
- **Foundation ship cuts** — Daily/ removed; skills/morning-brief/ removed; System Backlog.md retired from vault root → `~/.claude-plans/_backlog.md`
- **Substrate renames** — vault-scaffolding/ → vault-init/; skills/inbox-processor/ → skills/writer-reconciler/
- **State-tier topology** — `~/.claude/state/` → two-root `$VAULT_WRITER_STATE_ROOT` + `$CLAUDE_STATE_ROOT` (back-compat symlink for one release cycle)
- **Governance pillar count** — 6 → 8 (vault-writers-rules + plans-rules pillars added)
- **Hook matcher split** — DQP block ported from pre-write-guard.sh to new pre-asq-guard.sh
- **Pipeline additions** — doc-amender Bucket-1(b) + manifest.sqlite provenance + daily-processing JSONL + writer-fan-in doc-deps kind

---

## Adopter-side notes

- **Fresh-install only.** v3.0.0 ships without v2-adopter migration tooling per SP13 Session 7 L-93. There is no `--upgrade` flag. v2 adopters perform manual transition (off-ship; one-time; well-understood).
- **Re-run `install.sh`** to land the v3 substrate (9 file-type-contracts + 2 new pillars + 6 schemas + 3 lib helpers + pre-asq-guard.sh + 5 librarian capabilities + /govern register + /doc-amender + writer-reconciler rename + vault-writer templates + two-root state-tier scaffold + manifest.sqlite bootstrap + meeting-processor-state migration).
- **vault-init/ subtree** ships to `~/.claude/vault-init/` (sha256-protected). System Governance/ + Vault Writers/ + file-type-contracts/ reference examples are read-only from foundation; user-cluster authoring happens elsewhere per `[[feedback_user_defines_clusters]]`.
- **State paths.** Existing `~/.claude/state/` continues to resolve via back-compat symlink. Update scripts that hardcode this path to read from `$CLAUDE_STATE_ROOT` instead; symlink removed in v4.

---

## Acknowledgments

[PLACEHOLDER — finalized at T-15b]

---

[PLACEHOLDER NOTE: This skeleton authored 2026-05-20 at SP15 Session 1 per T-11.5 surface. Finalization gated on T-15a substrate complete (rc.1 SHA known) + SP08 dogfood PASS. Released date set at T-15b final tag cut.]
