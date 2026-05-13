---
altitude: system
scope: Inbox/ as scraper-output aggregation surface, NOT as drop zone for routing. The seven canonical aggregation files; the in-session `/ingest` model that replaces the rejected "auto-routing on drop" pattern; the dashboard read-loop; and the operational discipline that keeps Inbox/ legible to both Claude and the user without becoming a slush pile.
validity_window: 2026-05-12..2026-11-12
source_dependencies:
  - schema: claude-stem/schemas/vault-schema.json (inbox-archive type entry)
  - companion: ./vault-construction-principles.md
  - companion: ./frontmatter-design.md
  - companion: ./_index.md-design.md
last_reviewed: 2026-05-12
canonical_url: https://stem.peter.dev/research/vault-construction/inbox-flow-architecture/
url_stability: locked-from-2026-05-12
---

# Inbox flow architecture — aggregation, not routing

## Theme

`Inbox/` is the vault's operational data surface — the place where scrapers, syncs, and capture pipelines write structured aggregations of work happening *outside* the vault. Gmail digests; Teams chat scrolls; GChat conversation summaries; calendar events; meeting transcript queues; pending responses. The files are not loose notes; they're structured aggregations with stable filenames that the dashboard reads from on demand. The discipline is simple and load-bearing: scrapers WRITE in; the dashboard READS out; the user navigates the dashboard, not the Inbox files directly.

The architecture is the answer to a specific anti-pattern the system rejected: **Inbox-as-drop-zone-for-routing.** The original framing imagined the user dragging a file into Inbox/ and Claude auto-routing it to the correct engagement / project. That framing seems clean — drop the file, Claude files it — but it breaks under operational load: the user doesn't *have* loose files to drop most of the time (chat scrolls and email digests are scraped, not dropped); auto-routing produces wrong destinations 10-30% of the time and the corrections cost more than the time saved; the user loses visibility into the routing decision because the file is already moved.

The replacement architecture is **in-session `/ingest`**: when something lands in the vault (whether through scraper aggregation, manual paste, or external import), the user invokes a routing skill that proposes the destination, the user reviews + accepts (propose-and-confirm), the file moves. The routing decision is explicit and reviewable, not implicit and post-hoc. Inbox/ stays as the aggregation surface; `/ingest` is the routing surface. The two functions are decomposed, and the discipline holds.

## Vision / approach — five structural commitments

### 1. Inbox is aggregation, not drop zone

`Inbox/` carries scraper-output aggregation files. Each file has a known shape (date-keyed entries; per-source schema), a known consumer (the dashboard reads from it), and a known cadence (scraper writes on a schedule; dashboard reads on every render). The files are structured artifacts — not slush — and they support multiple downstream consumers without coupling.

The structural commitment: **Inbox/ files are append-friendly aggregations, not destinations.** A meeting note lands in `Inbox/Meetings.md` as an aggregated entry; the *canonical* meeting note lives at `Meetings/2026-05-12 - <title>.md` after the meeting-processor skill runs. A pending response lands in `Inbox/Pending-Responses.md`; the canonical task lands in `Tasks.md` after the reconciler runs. Inbox/ is the staging surface; the canonical destination is downstream.

This commitment has the sharp consequence that **Inbox/ files are not Strict-tier in the same sense as canonical destinations.** They carry their own frontmatter (declared at `schemas/vault-schema.json inbox-archive` for daily-rolled archives plus per-aggregation-file shape for the live files), but they are not the system of record for any specific piece of information — the canonical destination is. Inbox is the *transit layer*.

### 2. Auto-routing on drop is rejected; in-session `/ingest` is the model

The original architecture imagined: user drops file in Inbox/ → librarian watches Inbox/ → librarian auto-routes file to engagement / project / meeting / archive. The pattern is intuitive but operationally brittle. Three specific failures collapse the design:

- **Wrong destination 10-30% of the time.** Routing decisions depend on engagement vocabulary, project context, and adopter preference — none of which the auto-router has reliable signal on. Empirical observation in the reference deployment: routing accuracy was around 70-85% on routine files; failures clustered on cross-engagement files, archived engagements with similar slug patterns, and content the user had not yet categorized.
- **Loss of routing visibility.** Once the file is moved, the user has no record of the routing decision unless the librarian wrote a log entry — and even then, the routing happened post-hoc. The user discovers the wrong destination by missing the file at the expected location.
- **The user doesn't have loose files to drop.** Chat scrolls and email digests come from scrapers, not from user drops. Meeting notes come from Granola via the meeting-processor pipeline, not from user drops. The "drop zone" model assumes a workflow that didn't match observed usage.

The replacement: **in-session `/ingest` invocation.** The user (or a skill on the user's behalf) invokes `/ingest <source-or-file>`; the routing skill reads the content, proposes a destination with a one-line rationale, the user reviews + accepts. If the destination is wrong, the user redirects in the same turn. The routing decision is explicit, reviewable, and corrected before the file moves.

The model maps cleanly to the propose-and-confirm pattern that runs through the rest of the system (`feedback_propose_and_confirm_pattern`). It also keeps Inbox/ as aggregation rather than overloading it as both aggregation and drop zone.

### 3. Seven canonical aggregation files; per-source schemas

The reference deployment uses seven Inbox/ aggregation files. Each carries a per-source schema; the dashboard reads from each in a known shape; the scraper writes in a known shape.

| File | Source / writer | Reader | Schema |
|---|---|---|---|
| `Inbox/Calendar.md` | `calendar-sync` skill (cron-driven) | Dashboard | `{events: [{title, start, end, attendees, location, source}]}` |
| `Inbox/Gmail-Digest.md` | `gmail-sync` skill (cron-driven) | Dashboard + librarian (auto-extract action items) | Topic-based H2 with `[MSG]`-prefixed action-item rows |
| `Inbox/Teams-Digest.md` | `teams-scrape` skill (cron-driven) | Dashboard + librarian | Topic-based H2 per chat with `[MSG]`-prefixed rows |
| `Inbox/GChat-Digest.md` | `gchat-scrape` skill (cron-driven) | Dashboard + librarian | Topic-based H2 per chat with `[MSG]`-prefixed rows |
| `Inbox/Meetings.md` | `meeting-processor` skill (digest-run-driven) | Dashboard | Date-keyed entries linking to canonical `Meetings/` files |
| `Inbox/Pending-Responses.md` | merged from Gmail / Teams / GChat digests | Dashboard (My Action Items section) | Cross-source action-item aggregation |
| `Inbox/Action-Items.md` (optional adopter extension) | `reconcile-day` skill | Dashboard | Cross-source action-item normalization |

The discipline is **per-source schemas, not free-form markdown.** The dashboard's parser is the binding consumer; if a scraper writes outside the schema, the dashboard breaks silently. The schemas are declared at the scraper's SKILL.md + mirrored at the dashboard's parser config; R-37 lockstep applies when schemas evolve.

The adopter-customization seam lives at the scraper layer. Adopters running different mail / chat / calendar systems write their own scraper skills targeting the same aggregation-file schemas; the dashboard consumes uniformly.

### 4. The dashboard read-loop: pull, not push

The dashboard is the user-side surface — a viewer rendering Inbox/ aggregation files into navigable action-item lists, calendar views, and chat summaries. The read-loop is pull-based: the dashboard renders on demand (page load, refresh, or interaction); Inbox/ files are the source-of-truth; the dashboard does not maintain a separate cache or state beyond rendering memo.

The structural commitment: **Inbox/ files are the single source-of-truth for what the dashboard shows.** No dashboard-side database; no synchronization step; no "dashboard data needs to be regenerated." If the user wants the dashboard to reflect a change, the change lands in the corresponding Inbox/ file (via scraper or via `/ingest`), and the next dashboard render picks it up.

This is structurally equivalent to the database read-replica / materialized-view pattern (`feedback_manifests_as_read_replicas`): the canonical store is the markdown file; the dashboard renders a view over it; the view is recomputed on demand. The pull model keeps the architecture simple — no event queues, no sync workers, no consistency-tier compromises — at the cost of slightly stale views between scraper runs. For the operational cadence (chat / email scrapers run hourly; calendar refreshes on demand) the staleness is bounded and acceptable.

### 5. Daily rollover via inbox-archive; cumulative state via canonical destinations

The Inbox/ aggregation files are not append-forever. They roll over daily: at end-of-day (or first-write-of-next-day), the prior day's content moves to `Archive/Inbox/{YYYY-MM-DD}.md` as an inbox-archive entry. The current Inbox/ file resets to the new day. The rollover preserves history (audit trail; backfill; cross-day queries) without growing the live aggregation files unbounded.

The `inbox-archive` type entry in `schemas/vault-schema.json` carries the canonical frontmatter for the daily archives: `type: inbox-archive`, `date`, `day`, `sources`, `created`, `tags`, `updated`. The archive file aggregates all Inbox/ sources for that day into one rolled artifact; the live Inbox/ files start fresh for the new day.

The cumulative-state framing matters: **action items, calendar events, and meeting notes have canonical destinations that DO accumulate.** `Tasks.md` accumulates pending action items across all days. `Meetings/` accumulates one file per meeting indefinitely. `Engagements/<X>/Projects/<Y>/Updates.md` accumulates project updates. Inbox/ is the staging surface for new-from-the-day arrivals; the canonical destinations are the system-of-record for everything that persists.

The reconciler skill (`reconcile-day` in the reference deployment) is the morning bridge between Inbox aggregations and canonical destinations — it walks the prior day's Inbox content and proposes routing to canonical destinations using the `/ingest` propose-and-confirm pattern.

## The seven canonical aggregation files

### `Inbox/Calendar.md` — calendar event aggregation

Written by the calendar-sync skill on adopter-configured cadence (typically every 15-30 minutes during active work hours). Schema: `{events: [...]}` (NOT a bare array — historical-incident: the bare array silently broke the dashboard parser; the wrapper is load-bearing). Per-event fields: `title`, `start`, `end`, `attendees`, `location`, `source`.

The dashboard renders the calendar view directly from this file. Operators editing the calendar (declining events, rescheduling, etc.) do so in the external calendar tool; the calendar-sync skill picks up the change on the next run.

### `Inbox/Gmail-Digest.md`, `Inbox/Teams-Digest.md`, `Inbox/GChat-Digest.md` — chat / email digests

Three parallel files, one per source. Written by the respective scraper skills (`gmail-sync`, `teams-scrape`, `gchat-scrape`) on adopter-configured cadence (hourly typical). Schema: topic-based H2 per chat / thread, with `[MSG]`-prefixed rows for individual messages requiring response.

The `[MSG]` prefix is parser-significant: the dashboard's My Action Items section + the reconciler skill both consume `[MSG]`-prefixed rows. Non-prefixed rows are conversational context; `[MSG]`-prefixed rows are pending responses. The discipline applies uniformly across the three digest files.

Inbox/-aggregated digests are NOT replacements for the underlying chat / email tool — they're search-friendly mirrors that let the dashboard surface pending-response candidates without the user logging into three different tools. The canonical conversation lives in the source tool; the digest is the operational view.

### `Inbox/Meetings.md` — meeting aggregation

Written by the meeting-processor skill (typically invoked via `digest-run`). Schema: date-keyed entries with `[[Meetings/YYYY-MM-DD - <title>]]` wikilinks to canonical meeting notes.

The canonical meeting note lives at `Meetings/YYYY-MM-DD - <title>.md`; the Inbox/Meetings.md entry is the cross-reference index. The dashboard renders meetings from this file plus the upcoming-meetings section from `Inbox/Calendar.md`.

### `Inbox/Pending-Responses.md` — merged action-item aggregation

Written by the reconciler skill (or the per-source scrapers writing through a merge pipeline). Schema: cross-source aggregation of `[MSG]`-prefixed rows from the three chat / email digests, deduplicated, with provenance per row (source: gmail / teams / gchat).

The dashboard's My Action Items section reads from this file primarily. The reconciler routes accepted responses into `Tasks.md` (canonical destination) via the `/ingest` propose-and-confirm pattern; declined responses get logged with their disposition.

### `Inbox/Action-Items.md` — optional adopter extension

Some adopters extend the surface with an `Action-Items.md` aggregation that normalizes action items across sources beyond just pending responses (meeting outcomes, decision follow-ups, etc.). Optional; not required by foundation.

## The `/ingest` routing skill

`/ingest` is the in-session routing skill replacing the rejected auto-routing-on-drop pattern. Invocation modes:

| Invocation | Behavior |
|---|---|
| `/ingest <Inbox/file.md>` | Walk the file's topic / entry list; propose routing destination per topic; user accepts / redirects / skips. |
| `/ingest <external-file-path>` | Read the file; propose vault destination; user accepts / redirects. |
| `/ingest <pasted-content>` | Read pasted content; propose destination + skill-emitted frontmatter; user accepts / redirects. |

In every mode the skill follows the propose-and-confirm pattern: propose with one-line rationale → user reviews → user accepts or redirects → skill executes the move / write. No routing happens without the user-side confirmation. The propose-and-confirm cycle takes 5-15 seconds per item, which empirically beats the cost of correcting wrong auto-routes.

The routing rules `/ingest` consults (per adopter installation):

- Engagement / project / topic taxonomy from `schemas/vault-schema.json _tag_prefixes`
- Adopter customization at `_archetype_enum` and `_path_rules`
- Per-engagement CLAUDE.md navigation tables (when routing into a known engagement)
- The Routing Decision Tree at `Vault Architecture - Structure.md` (or its archetype-equivalent spoke)

## Anti-patterns

| Anti-pattern | What goes wrong | Preempt with |
|---|---|---|
| **Inbox-as-drop-zone-for-routing** | User drops files; librarian auto-routes; 10-30% wrong destinations; user can't see the routing decision. | In-session `/ingest` with propose-and-confirm. Aggregation stays in Inbox; routing is explicit. |
| **Bare-array Calendar.md** | Scraper writes Calendar.md as a bare YAML array instead of `{events: [...]}`. Dashboard parser breaks silently. | `{events: [...]}` wrapper is the schema. The bare-array variant broke the dashboard once; the schema is enforced now. |
| **Free-form digest content** | Scraper writes free-form markdown instead of topic-based H2 + `[MSG]`-prefix rows. Dashboard's action-item extractor misses pending responses. | Per-source schema documented in the scraper's SKILL.md + dashboard parser config. R-37 lockstep on schema changes. |
| **Inbox/ as system-of-record** | User starts editing Inbox/ files directly instead of routing to canonical destinations. Inbox/ accumulates stale state; cross-day queries break. | Inbox/ is the transit layer; canonical destinations accumulate. Reconciler runs at session start to bridge. |
| **Skipping the rollover** | Inbox/ aggregation files grow unbounded; live file becomes a multi-thousand-line slush; dashboard render slows; cross-day queries return wrong results. | Daily rollover to `Archive/Inbox/{YYYY-MM-DD}.md` via the inbox-archive type. Reconciler triggers rollover at first-write-of-day. |
| **Dashboard-side cache** | Dashboard maintains a separate state store synchronized from Inbox/. Two sources of truth drift. | Pull-based render; Inbox/ is the source-of-truth; dashboard recomputes on demand. |
| **Routing without propose-and-confirm** | A skill auto-files without user review on the assumption that "obvious" destinations are safe. Wrong destinations land silently. | Propose-and-confirm is mandatory on every `/ingest` invocation. Even "obvious" destinations get user review; the cost is 5 seconds. |
| **Per-adopter scrapers writing to canonical destinations directly** | An adopter writes a custom scraper that drops content directly in `Tasks.md` or `Meetings/` bypassing the Inbox aggregation step. Loss of audit trail; routing decision invisible. | Custom scrapers MUST write to `Inbox/` aggregation files. `/ingest` is the bridge to canonical destinations. |

## Quality bar self-test (6 criteria)

1. **Citation required.** PASS. Companion packets cited (`vault-construction-principles.md`, `frontmatter-design.md`, `_index.md-design.md`); schema artifact cited (`schemas/vault-schema.json inbox-archive`); `feedback_propose_and_confirm_pattern` + `feedback_manifests_as_read_replicas` framing inline. Historical incident citation (bare-array Calendar.md break) inline.

2. **Scope declaration.** PASS. All six packet-only fields in frontmatter; `validity_window` 2026-05-12..2026-11-12; `canonical_url` locked.

3. **Articulation test.** PASS. Five structural commitments enumerate the load-bearing premises with a *why* per commitment. The auto-routing rejection is named explicitly. A novice reader exits with: "Inbox is the aggregation surface; `/ingest` is the routing surface; dashboard pulls from Inbox; canonical destinations accumulate; daily rollover preserves history without unbounded growth."

4. **Anti-pattern coverage.** PASS. 8-row anti-pattern table covers: drop-zone framing, bare-array Calendar, free-form digest content, Inbox-as-system-of-record, skipping rollover, dashboard-side cache, routing-without-propose-and-confirm, scrapers-bypassing-Inbox.

5. **Decision-traceability.** PASS. Auto-routing rejection enumerated with three specific failure modes + empirical observation. Pull-based dashboard render named as the architectural alternative to event-queue / sync-worker patterns. Daily rollover named as the operational discipline that bounds aggregation file growth.

6. **Source pointers.** PASS. `source_dependencies:` frontmatter enumerates schema + 3 companion packets. Inline references cite schema by path + companion packets by stable filename + `feedback_*` framing.

Self-test verdict: 6/6 PASS at first authoring.

## Open questions

- **OQ-IF1** Adopter-specific scraper-source palette beyond gmail / teams / gchat (Slack, Discord, SMS, etc.) — defer to adopter SKILL.md authoring; the foundation seed covers the common case.
- **OQ-IF2** `Action-Items.md` aggregation contract — currently optional; promote to required if multi-adopter data shows it's universally valuable.
- **OQ-IF3** Inbox/ retention window for daily archives — current discipline is indefinite retention at `Archive/Inbox/{date}.md`; revisit if adopter storage cost surfaces concerns.

## Closed questions (with disposition)

- **CQ-IF1** Should Inbox/ files be Strict-tier or Standard-tier? → **Hybrid: per-file schema is Strict but the contents are operational.** The aggregation files carry per-source schemas (Strict-tier enforcement on scraper writes) but the per-entry content is free-form within the schema (Standard-tier on user edits). The `inbox-archive` daily roll is Strict-tier per the schema entry.
- **CQ-IF2** Should auto-routing be revisited with better classifiers? → **No.** The failure mode is not classifier accuracy — it's loss of routing visibility + workflow mismatch (users don't have loose files to drop). Better classifiers don't address either failure.
- **CQ-IF3** Should the dashboard maintain a database-backed cache? → **No.** Pull-based render is the design. Cache complexity exceeds the staleness cost.

## Source pointers

- Companion packets: `./vault-construction-principles.md` (capture-is-cheap; propose-and-confirm commitment), `./frontmatter-design.md` (`inbox-archive` type entry), `./_index.md-design.md` (Inbox/_index.md if adopter customizes navigation)
- Schema artifact: `schemas/vault-schema.json inbox-archive` type entry
- Operational memory: `feedback_propose_and_confirm_pattern`, `feedback_manifests_as_read_replicas`, `feedback_in_session_over_async_for_user_initiated_work`, `feedback_dashboard_parser_format`, `feedback_calendar_json_format`
- Runtime: scraper skills + dashboard parser + reconciler skill (see adopter installation)
