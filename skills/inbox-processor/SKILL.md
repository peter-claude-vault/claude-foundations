---
name: inbox-processor
description: SP13 T-12. Standing background processor that classifies + routes files dropped into the vault `Inbox/` to vault-ready placements while the user works. Single-pass per-item classification (format → heuristic → optional LLM fallback). Transcript shapes route via the T-11 portable meeting-note-ingestor; "doesn't-fit" items remain in `Inbox/` with appended `processor_attempted_at` + `processor_classification: unclassified` frontmatter (no destructive action). Cron-driven via `templates/launchd/inbox-processor.plist.tmpl` (default 15-min poll; configurable via `user-manifest.json#/inbox/poll_interval_minutes`).
disable-model-invocation: true
argument-hint: "--vault-root PATH [--audit-log PATH] [--gate-each-item] [--dry-run]"
---

# inbox-processor

Standing classifier for vault `Inbox/` drops. Picked by cron (default every 15
minutes); processes one batch per tick. One file → one classification → one
routing decision → one audit-log line.

## Personalization tier

**Universal capability** per `docs/personalization-model.md` §1 — the skill body
is identical for every adopter. Personalization comes from the user's
`user-manifest.json` (vault root, configured engagement directories, classifier
heuristics) and from the user's actual Inbox/ contents. The skill does NOT
re-declare the classification framing — see `docs/personalization-model.md`.

## Invocation

Direct (one-shot batch processing, terminal):

```sh
./process.sh --vault-root /path/to/vault
# → enumerates <vault>/Inbox/, classifies each file, routes; appends to audit log.

./process.sh --vault-root /path/to/vault --dry-run
# → emits a routing-decision report to stdout; no file writes.

./process.sh --vault-root /path/to/vault --gate-each-item
# → invokes SP12 3-step gate per item (opt-in; default off).
```

Scheduled (cron, via launchd):

```sh
# One-time install (renders templates/launchd/inbox-processor.plist.tmpl
# from user-manifest.json#/inbox/poll_interval_minutes and bootstraps it):
./install-cron.sh

# Dry-render to inspect the rendered plist without launchctl bootstrap:
./install-cron.sh --dry-run
```

## Flags

| Flag | Default | Meaning |
|---|---|---|
| `--vault-root <path>` | required | Vault root. `<vault>/Inbox/` is enumerated. |
| `--audit-log <path>` | `$CLAUDE_LOG_DIR/inbox-processor-audit.log` | Append-only routing-decision audit log (JSONL). |
| `--gate-each-item` | off | Per-item SP12 3-step-gate preview. Adds friction; off by default per spec L390 (Inbox processor is the autonomous-routing surface). |
| `--dry-run` | off | Emit routing-decision report on stdout; no file writes (no routes, no frontmatter appends, no audit log writes). |
| `--state-file <path>` | `$CLAUDE_HOME/inbox-processor-state.json` | Per-file dedup state (content-hash + last-routed timestamp); gitignored at install. |
| `--ingestor <path>` | `skills/meeting-note-ingestor/ingest.sh` | Override T-11 ingestor entry. |
| `--format-detector <path>` | `onboarding/seed-content/format-detector.sh` | Override T-3 detector. |
| `--meetings-subdir <name>` | `Meetings` | Where transcript-shape routes land under `<vault>/`. |
| `--reference-subdir <name>` | `Reference` | Where reference-shape routes land under `<vault>/`. |

## Classifier (single-pass, three-tier)

Per file in `<vault>/Inbox/`:

1. **Format-tier (extension-first via T-3).** `format-detector.sh` resolves
   format. Transcript shapes (`otter-vtt`, `zoom-transcript`, `word`+transcript
   filename, `*.granola.json`, `granola-*.json`) → route as `meeting`.
2. **Heuristic-tier.** For non-transcript markdown/plaintext: check filename
   slug + first 50 lines for project-shape signals (frontmatter `type:` field
   present + matches known canonical types from `vault-schema.json`; tag
   `#engagement/*` or `#project/*` present; H1 + multi-section bias).
   Reference shapes have `#reference` tag, README naming, or notes/cheatsheet
   shape.
3. **LLM fallback (opt-in).** If format + heuristic are inconclusive AND
   `ANTHROPIC_API_KEY` is set AND `--gate-each-item` is OFF (gate-mode prefers
   user disposition over LLM): single-pass classify
   `project | reference | meeting | unclassified`. Inconclusive output OR
   `ANTHROPIC_API_KEY` unset → fall through to step 4. The LLM call is the
   only place this skill consumes API budget; the cron interval is the
   throttle.
4. **Unclassified disposition.** "Doesn't fit any classifier": leave the file
   in `<vault>/Inbox/`, append two frontmatter fields atomically —
   `processor_attempted_at: <UTC ISO-8601>`, `processor_classification: unclassified`.
   No file rename, no relocation, no body mutation. User manually triages
   later. The next tick re-reads the same file but skips re-classification when
   `processor_attempted_at` is already present (idempotent).

## Routing targets

| Classification | Target | Notes |
|---|---|---|
| `meeting` | `<vault>/<meetings-subdir>/<YYYY-MM-DD>-<slug>.md` | Routed via T-11 ingestor; output carries SP12 provenance frontmatter (`generated_by: sp13-t11/1`). |
| `reference` | `<vault>/<reference-subdir>/<basename>.md` | Frontmatter `disposition: reference`; tag `#reference`; SP12 provenance frontmatter (`generated_by: sp13-t12/1`). |
| `project` | `<vault>/Inbox/` (left in-place, frontmatter only) | Project-shaped items REQUIRE user disposition (folder, engagement linkage); the processor refuses to scaffold project trees autonomously. Frontmatter appended: `processor_classification: project`, `processor_suggestion: "review for /seed-projects retrofit"`. |
| `unclassified` | `<vault>/Inbox/` (left in-place, frontmatter only) | See step 4 above. |

Project-shape items deliberately stay in `Inbox/` because autonomous project
scaffolding is the responsibility of `/seed-projects` (T-8) which is gated +
user-supervised. The standing processor is opt-in autonomy for the safe
classes (meeting / reference).

## Per-tick state + dedup

`--state-file` (default `$CLAUDE_HOME/inbox-processor-state.json`) records:

```json
{
  "version": "sp13-t12/1",
  "items": {
    "<sha256-of-file-content>": {
      "first_seen": "<UTC ISO-8601>",
      "last_attempt": "<UTC ISO-8601>",
      "last_classification": "meeting|reference|project|unclassified",
      "last_route": "<absolute path or 'in-place'>"
    }
  }
}
```

Re-running on an unchanged file is a no-op (state cache hit; skip
classification). When file content changes, sha256 changes → re-classified
on next tick. The state file is gitignored at install.

## Audit log

Append-only JSONL at `--audit-log` path (default
`$CLAUDE_LOG_DIR/inbox-processor-audit.log`). One line per tick, one entry
per file processed:

```json
{"ts":"2026-05-04T12:34:56Z","file":"Inbox/foo.md","sha":"<sha256>","classification":"meeting","route":"Meetings/2026-05-04-foo.md","gate":false,"tier":"format"}
```

`tier` is one of `format` / `heuristic` / `llm` / `state-cache` /
`unclassified-frontmatter`. The audit log is rotated externally (e.g.
`librarian` log-archive capability); this skill writes only.

## Output Contract

**Files written:**
- Per `meeting` route: one structured note at `<vault>/<meetings-subdir>/<YYYY-MM-DD>-<slug>.md`
  via T-11 ingestor (provenance frontmatter `sp13-t11/1`).
- Per `reference` route: one normalized markdown at `<vault>/<reference-subdir>/<basename>.md`
  with provenance frontmatter `sp13-t12/1`.
- Per `unclassified` or `project`: zero relocations; appends two frontmatter
  fields to the existing Inbox/ file (atomic via tmpfile + mv).
- One audit-log JSONL line per file processed.
- One state-file JSON write per tick (atomic via tmpfile + mv).

**Schema-types:**
- All generated artifact frontmatter validates against
  `schemas/provenance-frontmatter-schema.json` (Draft-07, SP12 T-2 contract).
- State file structure documented above (sp13-t12/1 in-skill schema; not a
  separate Draft-07 file because the structure is a per-skill cache, not a
  cross-tool contract).

**Pre-write validation:**
- `--vault-root` exists + is a directory.
- `<vault>/Inbox/` exists OR processor exits 0 with no-work log line (not an
  error: cron firing on a vault without an Inbox/ should be silent).
- T-3 format-detector + T-11 ingestor paths resolvable.
- `pf-lib` (SP12 T-2) sourceable.
- Gate-mode preconditions: SP12 3-step-gate library exists at `lib/three-step-gate.sh`.
- For each candidate write: parent directory mkdir-p; tmpfile + atomic
  rename pattern; never partial.
- For unclassified frontmatter append: read existing file, parse + amend
  frontmatter, write to tmpfile, atomic mv. If parse fails → log + skip
  (never destructive).

**Failure mode:** **Block and log.** Per-file errors log to audit-log + stderr
and proceed to the next file (one bad file does not halt the batch). Tick-
level errors (vault missing, state file unreadable, lock contention) exit
non-zero. The cron wrapper (`orchestrator/cron-wrappers/inbox-processor-cron.sh`)
preserves non-zero exit for launchd to detect.

## Architecture decisions (T-12)

### Cron over SessionStart hook

Recommended: cron via `launchd` `StartInterval`. Configurable via
`user-manifest.json#/inbox/poll_interval_minutes` (default 15). Rationale
(per `state/T-12-build-decision.md`):
- Time-driven autonomy is what the spec calls for ("background skill that
  classifies + routes files dropped into vault `Inbox/` while user works",
  spec L383). SessionStart is event-driven and would only fire when the
  user starts a new claude session — defeats the autonomous-while-user-
  works property.
- Cron interval is the implicit throttle on the optional LLM-fallback tier.
  SessionStart bursts could spike API budget on long Inbox/ backlogs.
- Existing repo precedent (librarian, architect) is `launchd` plist; cron
  wrapper at `orchestrator/cron-wrappers/inbox-processor-cron.sh` follows the
  established pattern.
- SessionStart variant remains a v2.x option (event-driven users prefer
  immediate feedback). Not shipped in T-12.

### Plist template path: `templates/launchd/inbox-processor.plist.tmpl`

Spec L390 wrote `~/Code/claude-foundations-v2/launchd/com.inbox-processor.plist.template`,
but the established repo convention is `templates/launchd/<name>.plist.tmpl`
(see `templates/launchd/librarian.plist.tmpl` + `architect.plist.tmpl`).
T-12 follows the established convention; deviation recorded in
`state/T-12-build-decision.md` §path-deviation. The `install.sh` Step 10
auto-ships all `templates/launchd/*.tmpl` so no installer change required.

### `render-launchd.sh` extension for `interval_sec` schedule

`render-launchd.sh` L147-150 explicitly invites a `StartInterval` extension
("interval_sec is forward-compat work for a future StartInterval template").
T-12 lands the extension as a job-specific branch:
- `inbox-processor` job skips the orchestration.json schedule lookup
  entirely (env-var-driven via `INBOX_POLL_INTERVAL_SEC`); `librarian` and
  `architect` keep their existing `StartCalendarInterval` path verbatim.
- This avoids requiring a foundation-repo top-level `orchestration.json`
  for the inbox-processor specifically (T-12 ships nothing to that file).
- The wrapper `install-cron.sh` reads user-manifest, computes
  `INBOX_POLL_INTERVAL_SEC = poll_interval_minutes * 60`, exports it, and
  invokes `render-launchd.sh inbox-processor` (production-mode bootstrap)
  or `render-launchd.sh --dry-run inbox-processor` (preview).

### Project-shape items left in Inbox/

The processor classifies project-shape items but DOES NOT scaffold project
trees. Project scaffolding is `/seed-projects` (T-8) — gated, user-
supervised, multi-file. The standing processor is opt-in autonomy for safe
classes (meeting / reference / unclassified frontmatter-append). Project
items get a `processor_classification: project` frontmatter hint + remain in
Inbox/ for the user to triage via `/seed-projects --retrofit-existing`
(T-13) or by hand. This boundary is intentional and matches spec L391-392
("`Doesn't fit any classifier` disposition: leaves the file in `Inbox/` with
appended frontmatter ... no destructive action; user manually triages").

### LLM fallback is opt-in via env var presence

The classifier's third tier (LLM single-pass classify) fires only when
`ANTHROPIC_API_KEY` is set in the cron's environment. `launchd` plists
inherit a minimal env (HOME + PATH + CLAUDE_HOME + CLAUDE_LOG_DIR + TZ);
the user opts into LLM fallback by adding `ANTHROPIC_API_KEY` to the plist's
`EnvironmentVariables` block (or by exporting it before invoking
`install-cron.sh`). Default cron environment has no API key → no API spend.
Tests run with `ANTHROPIC_API_KEY` unset to keep them hermetic.

## Dependencies

- `lib/provenance-frontmatter.sh` (SP12 T-2) — sourced for `pf_emit`.
- `onboarding/seed-content/format-detector.sh` (SP13 T-3) — invoked for format detection.
- `skills/meeting-note-ingestor/ingest.sh` (SP13 T-11) — invoked for transcript-shape routing.
- `lib/three-step-gate.sh` (SP12 T-1) — sourced ONLY when `--gate-each-item`.
- `installer/render-launchd.sh` — invoked by `install-cron.sh` for plist render + bootstrap.
- `templates/launchd/inbox-processor.plist.tmpl` — the launchd plist template.
- `orchestrator/cron-wrappers/inbox-processor-cron.sh` — the cron entry-point invoked by launchd.

## R-55 + test isolation

This skill performs zero `~/.claude/` writes during normal operation (state
file lives at `$CLAUDE_HOME/inbox-processor-state.json` which IS under
`~/.claude/` for adopters whose `CLAUDE_HOME=$HOME/.claude` — but the test
harness uses `$CLAUDE_HOME=/tmp/sp13-t12-test-$$` per
`feedback_test_isolation_for_hooks_state` so tests never touch live state).
Hermetic tests live at `onboarding/tests/sp13-inbox-processor-test.sh`.
R-55 G1 override-log delta is asserted == 0 by the test orchestrator.

## Limitations + non-goals

- **No autonomous project scaffolding.** Project-shape items get a
  classification hint but stay in Inbox/. /seed-projects (T-8) +
  /adopt --retrofit-existing (T-13) handle project tree creation.
- **No multi-batch corpus reasoning.** The standing processor classifies one
  file at a time; the heavier TnT-LLM iterative refinement (T-5) is reserved
  for `/onboard --seed-content`'s initial-corpus pass.
- **No re-cluster on incremental drop.** Every file is classified
  independently against vault-schema-defined types; no cross-file
  relationship inference. Per spec §"Deferred to SP13.x or later v2.x".
- **No vault-side cleanup.** If a previous tick wrote a file to `Meetings/`
  and the user then deletes the original Inbox/ file before the next tick,
  the routed file remains; the processor doesn't reverse routes.
- **No re-routing on user edit.** Once a file leaves Inbox/, the processor
  forgets it. User-driven moves of routed files are a librarian concern.
- **No connectors.** Multi-source pulls (Notion / Evernote / Slack) are
  out of scope; this skill processes the local filesystem `Inbox/` only.
