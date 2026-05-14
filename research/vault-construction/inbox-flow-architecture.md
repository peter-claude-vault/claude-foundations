---
altitude: system
scope: `Inbox/` as the connector-brief surface in vault — human-readable companion docs (one per active connector) describing each connector's identity, mechanism, data flow, cadence, processing rules, destinations, and pointer to where the actual data lives. Connector DATA (JSON / SQLite / binary stores) lives outside vault at `$CLAUDE_HOME/connector-data/<connector-slug>/` by default (adopter-overridable via Layer-3 overlay). The foundation mandates `Inbox/` itself, `Inbox/_index.md` (active-connection enumeration), and `Inbox/<connector>.md` per active connector. Processing rules ship bi-surface: markdown declaration in the connector brief (UNDERSTAND) + JSON overlay at `$CLAUDE_HOME/governance/processing-rules.adopter.json` (APPLY). R-37 lockstep keeps the two surfaces aligned. Destination-overlap is surfaced inside each brief and aggregated at `Inbox/_index.md`. Daily rollover discipline applies to the data store (per-connector retention authored at SP07 Beat 5), not to the briefs.
validity_window: 2026-05-13..2026-11-13
source_dependencies:
  - schema: claude-stem/schemas/vault-schema.json (connector-brief type entry; inbox-archive type entry)
  - companion: ./mandatory-file-lock.md
  - companion: ./vault-construction-principles.md
  - companion: ./frontmatter-design.md
  - companion: ./_index.md-design.md
  - companion: ./claude-md-design.md
  - template: claude-stem/templates/connector-brief-template.md
  - decision: Plan 81 SP03 Session 16 — lock #3 (Inbox shape connector-driven) + lock #11 (processing-rules helper)
  - decision: Plan 81 SP03 Session 18 — Option B reshape ratified (data-out-of-vault; markdown brief in Inbox); JSON-for-APPLY + markdown-for-UNDERSTAND discipline extended to connector layer
last_reviewed: 2026-05-13
canonical_url: https://stem.peter.dev/research/vault-construction/inbox-flow-architecture/
url_stability: locked-from-2026-05-13
---

# Inbox flow architecture — connector briefs in vault, data store outside

## Theme

`Inbox/` in the adopter vault carries human-readable **connector briefs** — one markdown file per active connector describing what the connector is, how it's wired, what it pulls, on what cadence, with what processing rules, into what destinations, and where the actual data lives. The briefs are the user's window into the system's operational data plane. The actual DATA — JSON aggregates, SQLite databases, binary blobs — lives outside the vault at `$CLAUDE_HOME/connector-data/<connector-slug>/` by foundation default, where Claude reads it the same way it reads schemas and governance JSONs.

The discipline that holds the architecture together is the same one that holds CLAUDE.md together (Session 17 ratification): **JSON for what Claude APPLIES; markdown for what humans UNDERSTAND.** Applied to connectors: the data Claude routes and propagates lives in the format and location optimal for that role (JSON / SQLite in `$CLAUDE_HOME`); the documentation of what's wired up lives where humans read it (markdown brief in vault `Inbox/`). The two surfaces stay aligned via R-37 lockstep at write-time and the librarian's `governance-parity-audit` at audit-time.

The architecture rejects two earlier framings. First, **Inbox-as-drop-zone for engagement/project routing** (the pre-Session-16 anti-pattern): user drops file into `Inbox/`, librarian auto-routes to engagement/project, fails at material rate, user loses routing visibility. Replaced by in-session `/ingest` propose-and-confirm (SP05 territory). Second, **Inbox-as-markdown-aggregation-files** (the T-42 v1/v2 framing): connectors write markdown aggregation files into `Inbox/`, dashboards parse markdown, processing rules sit inside markdown bodies. Refuted by operator's live evolution — the markdown files became stale degraded mirrors of the real data layer that lives at `~/artefact-dashboard/data/` (calendar.json, dashboard.db, chat_digests.db) where the dashboard reads from directly. The Session 18 ratification (Option B) codifies this: connectors emit DATA to the data store, BRIEFS describe the flow. Markdown is no longer the data layer; markdown is the documentation layer.

The whole framing was ratified at Plan 81 SP03 Session 18 (2026-05-13) following Session 16 locks #3 + #11. This packet is the canonical surface; downstream consumers (SP04 install.sh scaffold of `$CLAUDE_HOME/connector-data/`; SP05 `/ingest` runtime engine; SP07 connector-wizard Beat 5; the dashboard skill reading from the data store; the `connector-brief-template.md` at foundation-repo `templates/`) bind against it.

## Vision / approach — eight structural commitments

### 1. Inbox is the connector-brief surface; data lives outside vault by default

`Inbox/` carries no data in adopter vaults. It carries one markdown brief per active connector plus a folder-level `_index.md` enumerating active connections. The actual data the connector pulls — calendar event arrays, chat conversation indices, action-item state, dashboard read-replicas — lives outside the vault tree, at `$CLAUDE_HOME/connector-data/<connector-slug>/` by foundation default. The adopter may override the per-connector data-store path via Layer-3 overlay (`$CLAUDE_HOME/governance/connector-data.adopter.json`) to point at an existing data layer (e.g., the reference-deployment adopter's `~/artefact-dashboard/data/`).

The structural commitment: **what every adopter's `Inbox/` carries by foundation mandate is the FOLDER, the `_index.md`, and one BRIEF per active connector — nothing else.**

| Surface | Mandate | Owner | Purpose |
|---|---|---|---|
| `Inbox/` folder | Foundation-named; mandatory at install | SP04 install.sh | Reserved path for connector briefs + index |
| `Inbox/_index.md` | Foundation-mandatory at install; librarian-regenerated | librarian `inbox-index-refresh` capability | Active-connection enumeration + cross-connector destination-overlap surface |
| `Inbox/<connector>.md` brief | Foundation-mandatory once a connector activates | SP07 wizard Beat 5 (at activation); connector skill (status updates) | Human-readable companion: identity, mechanism, what's pulled, cadence, processing rules, destinations, data-store pointer, status |
| `$CLAUDE_HOME/connector-data/<connector-slug>/` | Foundation-default at install; adopter-overridable | SP04 install.sh (creates default dir); SP07 wizard (per-connector subdirs at activation) | Operational data store: JSON aggregates, SQLite databases, binary blobs |

The adopter does NOT rename `Inbox/` — every governance hook, every connector skill, every routing rule keys off the exact path. The path itself is locked; the brief set inside grows as connectors activate.

### 2. The connector-brief template — canonical structure foundation ships

Foundation ships a canonical template at `~/Code/claude-stem/templates/connector-brief-template.md` (Strict-tier; SP04 install.sh seeds it; SP07 wizard consumes it at connector activation; the wizard fills in template variables and writes the result to `Inbox/<connector-slug>.md`). Every brief carries the same shape; consistency makes the briefs scannable across connectors and lets the librarian audit them mechanically.

The required brief structure:

```markdown
---
type: connector-brief
connector: <connector-slug>
status: active | paused | errored | configured
data_location: $CLAUDE_HOME/connector-data/<connector-slug>/<artifact>
last_run: <ISO timestamp>
cadence: "<cron expression>" | on-demand
destinations:
  - <canonical-destination-path>
tags:
  - "#log/connector"
  - "#connector/<connector-slug>"
updated: <ISO date>
---

# <Connector display name>

## What this is
{1-2 sentence connector identity statement}

## Connection mechanism
- Tool / API / MCP: {tool name + version}
- Auth: {OAuth | API key | local-token | none}
- Scope: {what the connector has access to}

## What it pulls
{1-2 paragraph description of the data shape pulled per run. Reference data_location for the structured shape.}

## Cadence
{cron-driven / on-demand / event-driven; specific schedule}

## Processing rules
{Human-readable declaration of routing + dedup + survivorship rules. R-37 lockstep paired with the JSON overlay at $CLAUDE_HOME/governance/processing-rules.adopter.json.}

## Destinations
{Machine-readable list mirroring the frontmatter `destinations:` field, with one-line rationale per destination.}

## Destination overlap
{Auto-populated by librarian capability when other connectors write to the same destination(s). Empty section when no overlap.}

## Data location
{Foundation default: $CLAUDE_HOME/connector-data/<slug>/<artifact>. If adopter overrode the location via Layer-3 overlay, the override path appears here.}

## Status / errors
{Operational notes; updated by connector self-check on each run.}
```

The template is `Strict`-tier per `schemas/vault-schema.json connector-brief` type entry; missing required frontmatter fields cause `pre-write-guard.sh` R-32 DENY. The SP07 wizard authors the brief at activation time and binds the connector's emission contract to the brief's declared `destinations:` and `data_location:` fields. Subsequent connector runs may update `last_run:`, `status:`, and the §Status section; structural fields (mechanism, cadence, destinations, data_location) require explicit operator action through the wizard or a librarian capability to change.

### 3. Connector emission contract — bi-surface (markdown brief + JSON overlay) at SP07 Beat 5

When the adopter activates a connector during SP07's wizard (Beat 5), the wizard authors the **emission contract** across two synchronized surfaces:

| Surface | What it carries | Consumer |
|---|---|---|
| `Inbox/<connector>.md` brief (markdown, in vault) | Human-readable declaration of connection / what's pulled / cadence / processing rules / destinations | Adopter reads to understand the flow; Claude reads when reasoning about what's wired up |
| `$CLAUDE_HOME/governance/connector-emission-rules.adopter.json` (JSON, in $CLAUDE_HOME) | Machine-readable emission shape: schema, field set, parser-significant markers, data-store path | SP05 auto-routing reads to APPLY; librarian parser-validity audit reads to verify schema parity; dashboard parser config reads |

R-37 atomic-lockstep applies when an emission contract changes: the brief markdown + the overlay JSON + the connector's SKILL.md (the canonical schema-with-examples reference) + any downstream auto-routing rule MUST commit atomically. Drift between writer schema (what the connector emits) and reader schema (what `/ingest` expects) is the failure class this commitment preempts.

The foundation seeds reference connectors at `~/Code/claude-stem/skills/connectors/` (gmail-sync / teams-scrape / gchat-scrape / calendar-sync / meeting-processor) as Claude-onboarding reference material; SP07 consumes the references at adopter activation. Adopters operating on different mail / chat / calendar systems author their own connector skills targeting the same overlay-JSON shape; the auto-routing layer consumes uniformly through the per-adopter overlay.

### 4. Auto-routing reads the data store, not the brief

`/ingest` (SP05 runtime engine) reads the connector data store at `data_location:`, not the brief markdown. The brief is documentation for the user; the data is the substrate for routing. This is the structural completion of the JSON-for-APPLY + markdown-for-UNDERSTAND discipline at the connector layer.

Routing rules `/ingest` consults (per adopter installation):
- Engagement / project / topic / cluster taxonomy from the adopter's Layer-3 overlay (loaded from `schemas/vault-schema.json` Layer-1 universal + archetype-overlay Layer-2 + adopter Layer-3 in priority order).
- Adopter processing-rules overlay at `$CLAUDE_HOME/governance/processing-rules.adopter.json` (smart routing destinations + deduplication preferences + survivorship precedence).
- Connector emission-rules overlay at `$CLAUDE_HOME/governance/connector-emission-rules.adopter.json` (per-connector emission schema; `/ingest` validates content against this before propagating).
- Per-cluster `_index.md` navigation when routing into a known user-defined cluster.
- Naming conventions spoke at `Vault Architecture/Vault Architecture - Naming.md`.

The earlier framing imagined `/ingest` walking `Inbox/*.md` aggregation files. That model required markdown to be both human surface AND machine surface — a forced collapse the operator's live evolution refuted (the markdown files went stale; the dashboard moved to JSON/SQLite reads). The reshape unburdens the markdown: it does one job (documentation) and does it well; the data layer does the other job (APPLY substrate) at its own location.

### 5. Hybrid routing — shape signal on data store; engagement/project propose-and-confirm

A complementary skill — `inbox-processor` in the foundation-repo — handles **high-signal shape-routing** at runtime by inspecting the data store. Where the file shape or content type is itself unambiguous routing signal (a `.vtt` transcript routes to `Meetings/`; a daily-note frontmatter routes to `Daily/`; a calendar JSON event with `attendees: []` routes to dashboard view only), shape-routing applies without propose-and-confirm.

Where routing requires adopter context (which engagement? which project? which personal track?), `/ingest` propose-and-confirm applies. The two skills compose without overlap:

| Skill | Routing signal | Pattern |
|---|---|---|
| `inbox-processor` | File shape / content type from the data store metadata | Auto-routes when signal is unambiguous; ambiguous items get `attempted` flag for `/ingest` triage |
| `/ingest` | Adopter vocabulary + context | Propose-and-confirm; 5-15-second cycle; user accepts / redirects / skips |

Both skills read from the data store (`data_location:` of each connector brief), not from the brief markdown.

### 6. Processing rules helper — bi-surface; duplicate-write detection carried forward

Per Session 16 lock #11, processing rules are authored at SP07 Beat 5 (pipeline-design extension). Per Session 18 ratification (Option B), the rules ship bi-surface — markdown brief in vault for UNDERSTAND, JSON overlay in `$CLAUDE_HOME/governance/` for APPLY — with R-37 lockstep. Three rule classes:

| Rule class | What it controls | Markdown surface | JSON surface | Applied at |
|---|---|---|---|---|
| **Smart routing** | Per-connector default destinations downstream of the data store (e.g., "Gmail [MSG] rows → `Tasks.md`"; "Calendar events → dashboard view only") | §Processing rules in connector brief | `$CLAUDE_HOME/governance/processing-rules.adopter.json` smart_routing[] entries | SP05 `/ingest` runtime |
| **Deduplication** | What constitutes "same content" across multiple sources (e.g., a meeting summary referenced in both Gmail and Teams produces ONE task, not two); declares canonical-source preference | §Processing rules in connector brief | `$CLAUDE_HOME/governance/processing-rules.adopter.json` deduplication[] entries | SP05 + reconciler skill at merge time |
| **Survivorship** | When multiple sources emit overlapping content, which version wins (e.g., user edits to `Tasks.md` SURVIVE re-pull; scraper updates to data store do NOT overwrite user edits to canonical destinations) | §Processing rules in connector brief | `$CLAUDE_HOME/governance/processing-rules.adopter.json` survivorship[] entries | SP05 + reconciler skill at write time |

**Carry-forward — duplicate-write pre-write hook.** Operator surfaced (Session 18) a fourth rule-class candidate: a pre-write hook that, at write time when a connector or routing skill is about to write content to a destination, reads the destination's existing content and detects overlap with the incoming content. Disposition options when overlap is detected:
- **Reject** — skip the write entirely (duplicate suppression)
- **Review** — propose-and-confirm with the operator (review-and-decide)
- **Enhance** — merge the incoming content's additional context into the existing entry without creating a duplicate

This is a candidate for SP05 spec (auto-routing-enforcement) or SP09 (governance-architecture); the placement decision is deferred to Task #11 (SP05 spec revisions). The carry-forward is documented here so the connector-brief structure (§Destinations and §Destination overlap) provides the data shape the hook would consume.

### 7. Destination overlap — surfaced in briefs and aggregated at the index

Each connector brief declares its destinations in two places: machine-readable in frontmatter (`destinations:` array) and human-readable in the §Destinations body section. The librarian's `inbox-index-refresh` capability walks all active briefs, computes the cross-connector destination overlap matrix, and emits two outputs:

1. **Per-brief §Destination overlap section** — auto-populated in each connector brief listing every other active connector writing to a shared destination, with a one-line summary of the overlap.
2. **Cross-brief overlap matrix** — surfaced at `Inbox/_index.md` as a table: rows are destinations; columns are connectors; cells indicate write claims. The operator scans the matrix at a glance to understand where multiple connectors converge.

The overlap surface is the data source the duplicate-write hook (§6 carry-forward) consumes when evaluating an incoming write. Surfacing the overlap as a visible artifact in `Inbox/` (rather than buried inside JSON) reflects the discipline that the user OWNS the routing topology: the operator must be able to see, in their own vault, which connectors are converging on which destinations, without spelunking through JSON.

### 8. Daily rollover — applies to data store, not to briefs; Archive parked

Pre-Session-18 framing imagined daily rollover of `Inbox/*.md` aggregation files to `Archive/Inbox/{YYYY-MM-DD}.md` as inbox-archive entries. Under Option B, the briefs in `Inbox/` are STABLE configuration documents (not append-only aggregations); they update when the connector's connection state changes, not daily. Daily rollover semantics therefore apply to the DATA STORE per-connector, not to the briefs in vault.

Per-connector data-store retention is authored at SP07 Beat 5 alongside the emission contract — the wizard asks the adopter how long to retain raw connector output (default: indefinite at the data-store path; rotation/archival is the adopter's choice). The data-store retention discipline lives outside this packet because it depends on Archive architecture decisions the operator parked (Session 18) for separate consideration.

The `inbox-archive` type entry in `schemas/vault-schema.json` remains in the schema for backward compatibility with pre-Session-18 deployments and for any future use where adopters choose to archive markdown surfaces; the foundation no longer mandates inbox-archive rollover at the brief layer.

**Flag for Archive rethink (parked):** the operator parked Archive at Session 18 pending a separate session. Carry-forward items for that session: (a) per-connector data-store retention discipline (what gets archived from `$CLAUDE_HOME/connector-data/<slug>/` and when); (b) backup discipline for `$CLAUDE_HOME/` (vault sync only covers vault tree; if data store lives outside vault, adopter handles its own backup); (c) whether `Archive/` in adopter vault still serves the documented role (cold storage for closed engagements + retired plan trees) or whether it expands/contracts based on the data-store boundary.

## Canonical content

### The Inbox surface, per adopter

Every adopter's `Inbox/` carries:

```
Inbox/
  _index.md                         # mandatory; librarian-regenerated
  <connector-slug>.md               # one per active connector; SP07 wizard-authored at activation
  <connector-slug>.md               # ...
  ...
```

No JSON files. No SQLite. No data aggregation markdown. Just the active-connection index and per-connector briefs.

The reference deployment, after the Option B reshape lands, will carry briefs that look like (illustrative, not foundation-mandated names):

```
Inbox/
  _index.md
  calendar-google.md
  gmail.md
  teams.md
  gchat.md
  meeting-processor.md
```

The corresponding data store at `$CLAUDE_HOME/connector-data/` (or adopter-overridden path):

```
$CLAUDE_HOME/connector-data/
  calendar-google/
    events.json
  gmail/
    digest.json
  teams/
    scrape.db
  gchat/
    scrape.db
  meeting-processor/
    queue.json
```

The adopter sees `Inbox/` in Obsidian's graph view as a clean folder of connector briefs; they navigate the briefs to understand the flow; they never see the underlying data files (which live outside vault by default).

### `Inbox/_index.md` — active-connection enumeration + overlap matrix

Required content shape:

```markdown
---
type: index
scope: Inbox active-connection enumeration + cross-connector destination overlap
tags:
  - "#log/index"
updated: {ISO timestamp}
---

# Inbox — active connections

Last refreshed: {ISO timestamp; updated by librarian inbox-index-refresh capability}

## Connectors

| Connector | Status | Brief | Data location | Last run | Cadence |
|---|---|---|---|---|---|
| {slug} | active / paused / errored | `Inbox/<slug>.md` | `$CLAUDE_HOME/connector-data/<slug>/<artifact>` | {ISO timestamp} | {cron / on-demand} |
| ... | ... | ... | ... | ... | ... |

## Destination overlap matrix

| Destination | Connectors writing |
|---|---|
| `Tasks.md` | {comma-separated list of connector slugs writing to this destination} |
| `Meetings/` | ... |
| ... | ... |

Empty rows are omitted; only destinations with ≥1 active writer surface here.

## Notes

{Operator-facing notes; auto-populated suggestions from librarian capability about flagged overlaps, configuration recommendations, recent errors.}
```

The `_index.md` is machine-regenerated. Manual edits to it SHOULD NOT happen — the source of truth is each connector brief; the index aggregates. Adopter customization belongs in the connector briefs or in the JSON overlays.

### The data store at `$CLAUDE_HOME/connector-data/<slug>/`

Structure mandate: **one subdirectory per active connector slug**, contents per the connector's emission contract. Foundation default; adopter-overridable per-connector via Layer-3 overlay (`$CLAUDE_HOME/governance/connector-data.adopter.json` keys `connector-data.<slug>.path` → absolute path; SP07 wizard reads and writes this at activation/override time).

Reference connector emission shapes (illustrative, owned by each connector's SKILL.md):

| Connector | Default emission artifact | Schema |
|---|---|---|
| `calendar-google` | `events.json` | `{events: [{title, start, end, attendees, location, source}, ...]}` (note: object-wrapped array; bare-array variant once broke the dashboard parser) |
| `gmail` | `digest.json` | Topic-keyed object with `[MSG]`-marked action-item rows |
| `teams` | `scrape.db` | SQLite — per-chat threaded messages + `[MSG]` flag |
| `gchat` | `scrape.db` | SQLite — per-chat threaded messages + `[MSG]` flag |
| `meeting-processor` | `queue.json` | Date-keyed entries linking to canonical meeting notes |

The discipline: **per-connector schemas declared at SP07 setup time, mirrored at the dashboard parser config + the connector's SKILL.md + the adopter Layer-3 overlay, governed by R-37 lockstep on schema evolution.** If a connector writes outside its declared schema, the dashboard parser breaks silently — the schema is the cross-cutting contract that holds the connector / dashboard / auto-routing seam together.

### The bi-surface processing rules

Markdown declaration in each brief — §Processing rules section — carries the rules in human-readable form. JSON overlay at `$CLAUDE_HOME/governance/processing-rules.adopter.json` carries the same rules in machine-readable form for SP05 application:

```json
{
  "smart_routing": [
    {"connector": "calendar-google", "match": {"description_starts_with": "TODO:"}, "destination": "Tasks.md", "rationale": "Calendar TODO action items"}
  ],
  "deduplication": [
    {"connectors": ["gmail", "teams"], "canonical_source": "teams", "match": {"meeting_id_present": true}, "rationale": "Teams meeting summary preferred over email reflection"}
  ],
  "survivorship": [
    {"destination": "Tasks.md", "wins": "user-edits", "rationale": "User edits to canonical destinations survive re-pull"}
  ]
}
```

R-37 lockstep keeps the markdown declaration and the JSON overlay aligned at write-time; the librarian's `processing-rules-parity-audit` capability flags drift at audit-time.

## Anti-patterns

The architecture preempts ten recurring drift classes:

| Anti-pattern | Drift signature | Preempt with |
|---|---|---|
| **Hardcoded N-aggregation-file `Inbox/` lock** | Foundation-side text enumerates a specific markdown file set as universal-mandatory | Only `Inbox/` itself, `Inbox/_index.md`, and per-active-connector `<slug>.md` are foundation-mandated (§1, §2); no fixed file list |
| **Connector emits markdown aggregation files into `Inbox/`** | Connector skill writes `Inbox/Calendar.md` with a topic-based H2 dump of pulled events; dashboard reads markdown; staleness creeps | Option B reshape (§1, §4): data goes to `$CLAUDE_HOME/connector-data/<slug>/<artifact>`; brief markdown documents the flow but is NOT the data |
| **Inbox-as-drop-zone for engagement/project routing** | User drops files; librarian auto-routes to engagement/project; wrong destinations at material rate | In-session `/ingest` with propose-and-confirm (§5); routing decisions explicit |
| **Schema drift between connector and reader** | Connector writes a new field; dashboard parser or `/ingest` doesn't expect it; silent break | R-37 lockstep on the brief + overlay + SKILL.md + parser-config quadruple; schema change MUST commit atomically (§3) |
| **JSON files appearing inside `Inbox/`** | An adopter or skill drops `Inbox/calendar.json` (or similar) into vault directly | `Inbox/` mandate is markdown briefs + `_index.md` ONLY (§1); R-32 pre-write-guard rejects non-brief non-index file types in `Inbox/` |
| **Brief markdown becomes the data layer** | A skill starts writing structured per-event data into the brief's body; the brief drifts from documentation to degraded mirror (the pre-Session-18 pattern) | Brief Strict-tier per `connector-brief` type entry; required structural sections lock the shape; data fields are NOT allowed in body content (§2) |
| **`$CLAUDE_HOME/connector-data/` path drift** | An adopter overrides the data location and forgets to update the brief's `data_location:` field; auto-routing reads the old path | SP07 wizard authors the override + updates the brief in one atomic step; librarian capability audits brief↔overlay parity |
| **Free-form processing rules in brief body** | An operator writes "Gmail action items go wherever they fit" in the brief; the JSON overlay has no corresponding entry; `/ingest` can't apply the rule | R-37 lockstep on §Processing rules ↔ `processing-rules.adopter.json`; the SP07 wizard authors both surfaces simultaneously |
| **Destination overlap silently accumulates** | Three connectors all write to `Tasks.md`; deduplication isn't configured; the same task appears three times | §Destination overlap auto-populated by librarian capability (§7); operator sees the overlap and configures dedup at SP07 wizard or via `/configure-connector` |
| **Dashboard-side cache of vault content** | Dashboard maintains a separate state store synchronized from Inbox markdown; two sources of truth drift | Dashboard reads directly from the data store at `data_location:`; no markdown-as-cache pattern (this is the `feedback_manifests_as_read_replicas` pattern applied with the data store as canonical) |

## Quality bar self-test (6 criteria)

1. **Citation required.** PASS. Companion packets cited (`mandatory-file-lock.md`, `vault-construction-principles.md`, `frontmatter-design.md`, `_index.md-design.md`, `claude-md-design.md`); schema artifact cited (`schemas/vault-schema.json` connector-brief + inbox-archive type entries); foundation template cited (`templates/connector-brief-template.md`); operator-direction Session 16 locks #3 + #11 + Session 18 Option B ratification cited verbatim; `feedback_inbox_connector_driven`, `feedback_propose_and_confirm_pattern`, `feedback_manifests_as_read_replicas`, `feedback_json_for_apply_markdown_for_understand` framing inline; live-state observation (reference-deployment markdown files stale; `~/artefact-dashboard/data/` carries authoritative data) cited as Option B's empirical grounding.

2. **Scope declaration.** PASS. All six packet-only fields in frontmatter; `validity_window` 2026-05-13..2026-11-13; `canonical_url` locked at 2026-05-13; `altitude: system` consistent with foundation-altitude-only discipline.

3. **Articulation test.** PASS. Eight structural commitments enumerate the load-bearing premises with a *why* per commitment. A novice reader exits with: "`Inbox/` carries human-readable connector briefs only; data lives outside vault at `$CLAUDE_HOME/connector-data/<slug>/`; foundation ships a canonical brief template; emission contract is bi-surface (markdown brief + JSON overlay) at SP07 Beat 5; `/ingest` reads the data store; hybrid routing (`inbox-processor` shape + `/ingest` propose-and-confirm); processing rules bi-surface with duplicate-write hook carry-forward; daily rollover applies to the data store, not the briefs; Archive parked for separate session."

4. **Anti-pattern coverage.** PASS. 10-row anti-pattern table covers: hardcoded N-file lock, markdown-aggregation-emission, drop-zone framing, schema drift, JSON-in-Inbox, brief-as-data-layer, data-path drift, free-form processing rules, silent destination overlap, dashboard-cache.

5. **Decision-traceability.** PASS. Session 16 lock #3 (connector-driven shape) + lock #11 (processing-rules helper) + Session 18 Option B ratification (data-out-of-vault; bi-surface) attributed verbatim. Auto-routing rejection enumerated. Pull-based dashboard render named as the architectural alternative to event-queue / sync-worker patterns. Daily rollover decoupling from brief layer named with Archive parking flagged. The T-42 v1 (Peter-instantiation 7-file enumeration) and v2 (connector-driven markdown aggregation) framings both explicitly retired with rationale (live-state empirical signal: markdown files stale; dashboard moved to JSON/SQLite).

6. **Source pointers.** PASS. `source_dependencies:` frontmatter enumerates schema + 5 companion packets + foundation template + 2 decision-authority sessions. Inline references cite paths + companion packets + `feedback_*` framing throughout.

Self-test verdict: 6/6 PASS at v3 rewrite.

## Open questions

- **OQ-IF1** Adopter-specific connector palette beyond gmail / teams / gchat / calendar / meeting-processor (Slack, Discord, SMS, Notion, Linear, Outlook, etc.) — defer to adopter SKILL.md authoring at SP07 Beat 5; foundation seed covers common cases as reference material.
- **OQ-IF2** Inbox/_index.md refresh cadence — librarian cron pass refreshes on demand and at cron cadence; revisit if real-time staleness causes adopter friction.
- **OQ-IF3** Per-connector data-store retention discipline — where does the operator want raw connector output to age out, and to where? Couples to Archive rethink (operator parked Session 18). Defer.
- **OQ-IF4** Processing-rules overlay expressiveness — first version supports declarative rules (per-connector destination + dedup-canonical-source + survivorship-precedence). Expressiveness for adopter conditional logic (e.g., "Gmail [MSG] rows routed to client-X folder when sender domain matches") may need code-level extension at SP05; defer to runtime instrumentation.
- **OQ-IF5** Duplicate-write pre-write hook — placement decision (SP05 vs SP09) deferred to Task #11 (SP05 spec revisions); the operator surfaced this Session 18 as "warrants more consideration."
- **OQ-IF6** Adopter override path for `$CLAUDE_HOME/connector-data/` — foundation default is `$CLAUDE_HOME/connector-data/<slug>/`; adopter overrides per-connector via Layer-3 overlay. Should SP04 install.sh prompt for an installation-wide override at install time (so an adopter with an existing data layer at `~/some-other-path/` doesn't have to override per-connector)? Defer to Task #10 (SP04 spec revisions).
- **OQ-IF7** Migration from T-42 v1/v2 inbox aggregation markdown to v3 connector briefs — for the reference deployment specifically: the stale markdown files at `~/Documents/Obsidian Vault/Inbox/*.md` need a migration path. The migration is live-vault work, not foundation work, and carries the `feedback_no_live_edits_during_foundation_repo_build` constraint. Defer to a separate live-vault session post-SP04 build.

## Closed questions (with disposition)

| Question | Disposition |
|---|---|
| Should connectors emit markdown aggregation files into `Inbox/`? (T-42 v1/v2 framing) | NO — RETIRED Session 18 Option B ratification. Markdown files in `Inbox/` are connector briefs (documentation), not data aggregations. Data lives at `$CLAUDE_HOME/connector-data/<slug>/`. |
| Should JSON files live in `Inbox/` alongside the briefs? (Session 18 Option A) | NO. Vault stays human-navigable; JSON in Obsidian graph is noise. Foundation default keeps data out of vault. Adopter MAY override per-connector if they want vault-sync coverage. |
| Should SQLite databases live in `Inbox/`? | NO — operator rejected inline Session 18. Binary stores are git/Obsidian-unfriendly. |
| Should `Inbox/` lock to a fixed file enumeration? | RETIRED Session 16 lock #3 — connector-driven. Reconfirmed Session 18 (brief set materializes from active connectors). |
| Should auto-routing be revisited with better classifiers? | NO. Failure mode is routing-visibility + workflow-mismatch, not classifier accuracy. Engagement/project routing needs propose-and-confirm. |
| Should the dashboard maintain a database-backed cache of vault content? | NO. Dashboard reads directly from the data store at `data_location:`. Pull-based render. |
| Should processing rules ship as hardcoded foundation defaults or configured at connector setup? | Configured at connector setup (Session 16 lock #11). Bi-surface per Session 18 ratification: markdown brief + JSON overlay. |
| Should `Inbox/*.md` brief files be Strict-tier or Standard-tier? | STRICT (the foundation template binds the structural shape). Body content can carry adopter notes (Standard-tier within the body), but the structural sections (§What this is, §Connection mechanism, §What it pulls, §Cadence, §Processing rules, §Destinations, §Destination overlap, §Data location, §Status / errors) and frontmatter are STRICT. |
| Should daily rollover apply to brief markdown? | NO — briefs are stable config; rollover applies to data store (per-connector retention authored at SP07 Beat 5). Archive parked for separate session. |

## Source pointers

**Companion packets** (canonical content at `claude-stem/research/vault-construction/`):
- [`mandatory-file-lock.md`](./mandatory-file-lock.md) — `Inbox/` mandate scope; system-vs-user folder boundary; per-connector brief mandate
- [`vault-construction-principles.md`](./vault-construction-principles.md) — capture-is-cheap + propose-and-confirm commitments
- [`frontmatter-design.md`](./frontmatter-design.md) — `connector-brief` type entry; `inbox-archive` type entry; system-file frontmatter discipline
- [`_index.md-design.md`](./_index.md-design.md) — `_index.md` mandate scope (including `Inbox/_index.md` foundation-mandatory with overlap matrix)
- [`claude-md-design.md`](./claude-md-design.md) — JSON-for-APPLY + markdown-for-UNDERSTAND discipline (the disciplinary parent of this packet)

**Foundation template** (canonical brief shape at `claude-stem/templates/`):
- [`connector-brief-template.md`](../../templates/connector-brief-template.md) — Strict-tier; SP04 seeds; SP07 wizard consumes at connector activation

**Downstream consumers** (bind against this packet):
- `~/Code/claude-stem/schemas/vault-schema.json` — `connector-brief` type entry (Strict-tier, required structural fields)
- `~/Code/claude-stem/onboarding/scaffold/install.sh` (SP04) — scaffolds `Inbox/` folder + initial `_index.md` + creates `$CLAUDE_HOME/connector-data/` default dir; consumes connector activations from SP07 wizard output
- SP05 auto-routing engine — implements `/ingest` runtime; consumes the adopter Layer-3 overlay + processing-rules overlay + connector-emission-rules overlay
- SP07 connector-wizard Beat 5 — authors per-connector brief + emission-rules overlay + processing-rules overlay entries at activation time; bi-surface R-37 lockstep
- SP08 dogfood-harness verification fixtures — assert `Inbox/_index.md` present + per-active-connector brief present + data-store path reachable + JSON overlay schemas valid; NO assertion of markdown aggregation file content
- Reference-deployment connector skills at `~/Code/claude-stem/skills/connectors/` — Claude-onboarding REFERENCE; not shipped to adopter vault as artifacts
- `inbox-processor` skill (high-signal shape-routing on data store) + `/ingest` skill (propose-and-confirm on engagement/project) — composing routing layer
- Dashboard skill (separate; not foundation) — reads from `data_location:` paths

**Decision-authority sessions**:
- Plan 81 SP03 Session 16 (2026-05-13) — lock #3 connector-driven shape; lock #11 processing-rules helper. Load-bearing for §1, §6.
- Plan 81 SP03 Session 17 (2026-05-13) — JSON-for-APPLY + markdown-for-UNDERSTAND discipline (`feedback_json_for_apply_markdown_for_understand`). Load-bearing for §1, §3, §4, §6 (the entire bi-surface architecture).
- Plan 81 SP03 Session 18 (2026-05-13) — Option B ratification (data-out-of-vault; brief in Inbox); connector-brief template (T-45); destination-overlap surfacing in briefs + at index; duplicate-write pre-write hook carry-forward to SP05/SP09 placement decision. Load-bearing for §1, §2, §7, §8 + the entire Option B reshape.
- Plan 81 SP03 post-SP05 alignment (2026-05-06) — Inbox/ amendment as aggregation surface (not drop zone). Load-bearing for §5.

**Memory cross-references** (live `~/.claude/projects/-Users-petertiktinsky/memory/`):
- `feedback_inbox_connector_driven` — Inbox shape connector-driven contract (foundation framing)
- `feedback_json_for_apply_markdown_for_understand` — bi-surface discipline (load-bearing for the entire Option B reshape)
- `feedback_user_defines_clusters` — system-folder mandates + user-defined cluster shape boundary
- `feedback_propose_and_confirm_pattern` — propose-and-confirm primitive
- `feedback_manifests_as_read_replicas` — pull-based dashboard render pattern; data store as source-of-truth
- `feedback_in_session_over_async_for_user_initiated_work` — `/ingest` synchronous flow vs async queue
- `feedback_dashboard_parser_format` — historical schema-shape discipline
- `feedback_calendar_json_format` — `{events: [...]}` wrapper schema (bare-array incident)
- `feedback_no_live_edits_during_foundation_repo_build` — separation discipline during SP03–SP08 build (load-bearing for OQ-IF7 deferral)
