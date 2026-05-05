# schemas/

Every JSON schema in this directory is a contract between the producer of an artifact and its readers. Schemas are validated at write time by `post-write-verify.sh`, `bootstrap-schemas.sh`, and friends — they are not advisory documentation.

`install.sh` copies this directory into the target user's `$CLAUDE_HOME/schemas/`. Runtime hooks read from `$SCHEMAS_DIR`, which defaults to `$CLAUDE_HOME/schemas` (resolved by `lib/paths.sh`). Editing here means editing the distribution source — the next install will pick the change up.

## Inventory

| Schema | What it gates | Validated at |
|---|---|---|
| `vault-schema.json` | Frontmatter required/optional fields per canonical vault type. The single source of truth for which `type:` values are legal and what each one must carry. | Pre-write (R-32 type allowlist), post-write (frontmatter check), librarian drift sweep. |
| `plans-schema.json` | Plan-tree shape: `NN-` prefix, status header, sub-plan execution-order numbering, `parent_plan:` on depth-≥3 files. | Pre-write (R-27 plan naming + status), librarian plan-index. |
| `plan-manifest-schema.json` | Per-plan `manifest.json` shape (status enum, AC counts, sub-plan list). Read replica of the plan tree for fast index queries. | Plan-manifest writers (`/new-plan`, librarian close-out). |
| `librarian-manifest-schema.json` | Librarian runtime state: inventory, cross-reference graph, tag census, scan timestamps, drift findings, architect recommendations, rename history. | Librarian capabilities; consumed by `/architect`. |
| `user-manifest-schema.json` | Identity + config shape (`user-manifest.json`). Required: `identity`, `vault`, `paths`, `system`, `behavioral`, `architect`, `projects`, `tools`, `people`, `orchestration`. Optional: `hooks`, `schema`, `plans`, `dashboard`, `brief_repos`, `crons`. | `/onboard --finalize` (`bootstrap-schemas.sh`); every hook that reads identity. |
| `orchestration-schema.json` | Per-user autonomous-job config: launchd plists, cron schedules, tripwires, observability surfaces. | `/onboard` Section D + initial-job-setup flow; `installer/render-launchd.sh`. |
| `provenance-frontmatter-schema.json` | The `provenance:` frontmatter block emitted by auto-authoring skills (PRD seeding, context seeding). Records source items, generation time, last-user-edit timestamp. | Seed-content skills before write; survivorship checks before regeneration. |
| `connectors-runtime-schema.json` | Connector-pipeline runtime state: per-connector last-fetched cursor, ingest counts, error history. | Connector cron wrappers; `/morning-brief`. |
| `connector-pipeline-template-schema.json` | Per-connector template shape (Granola, Calendar, Gmail, etc.). Declares cron cadence, inbox subdirectory, transform script, retention. | `/onboard` connector wizard; installer at adopt time. |

## Contract

- **Additive evolution.** Adding a new vault type, a new manifest section, a new connector field is a same-PR change to the schema and to every consumer that reads it. The pre-write guard's R-32 (type allowlist) treats unknown `type:` values as a hard deny — schema-first, write-second.
- **Per-schema versioning.** Every schema carries a `schema_version` field at the top level. Consumers may pin a minor-version range; the installer refuses to copy a schema whose major version is newer than the live consumer expects.
- **Hand-edit-friendly.** Every schema is small, pretty-printed JSON. Read it, edit it, validate it (`jq -e . schemas/*.json`), commit it.

## Validation

```bash
# All schemas parse as JSON
jq -e . schemas/*.json

# vault-schema.json round-trip — every key except meta is a valid type
jq -r 'keys[] | select(. != "schema_version" and . != "_tag_prefixes")' \
  schemas/vault-schema.json
```

For the change-procedure when extending vault-schema, see [`docs/adding-a-vault-file-type.md`](../docs/adding-a-vault-file-type.md).
