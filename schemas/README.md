# schemas — Distribution Source

Foundation-repo distribution-source for all 6 schemas. `install.sh` (SP08 T-1) copies this directory into the target user's `$CLAUDE_HOME/schemas/`. Runtime hooks read from `$SCHEMAS_DIR` which defaults to `$CLAUDE_HOME/schemas` (`lib/paths.sh:23`). Editing here = editing distribution-source; lands in the next install.

## Schema inventory (6 files)

| Schema | Sanctioned in live `~/.claude/`? | Owner sub-plan | Purpose |
|---|---|---|---|
| `vault-schema.json` | YES (canonical) | SP01 T-1 (migrated) | Frontmatter + structural rules for vault files. Load-bearing in 3 live hooks (post-write-verify, frontmatter-enforce, drift-sweep). Mirror here is published-snapshot per Source-of-Truth Contract (SP09 spec §"Source-of-Truth Contract for sanctioned schemas"). |
| `plans-schema.json` | YES (canonical) | SP01 T-1 (migrated) | Plan-tree advisory schema (R-40). Load-bearing in pre-write-guard R-27 + R-40 enforcement. Mirror here is published-snapshot. |
| `plan-manifest-schema.json` | YES (canonical) | SP01 T-6 (rename) | `manifest.json` shape per plan directory. Advisory consumer in live; mirror here is published-snapshot. |
| `librarian-manifest-schema.json` | NO (foundation-repo only post-T-10) | SP01 T-5 / SP04 T-9a runtime writer | Librarian runtime state: inventory, xref graph, tags, scan state, drift findings, architect recommendations, rename history. |
| `user-manifest-schema.json` | NO (foundation-repo only post-T-10; bumped to **1.2.0** per SP09 T-9 fold-in / AR-3) | SP01 T-3 / SP06 13-field consumer | Identity + config manifest (`user-manifest.json` instance). 10 required top-level sections + 6 optional (1.1.0: hooks/schema/plans + vault.root_directories[]; 1.2.0: dashboard/brief_repos/crons + vault.context_documents[]). |
| `orchestration-schema.json` | NO (foundation-repo only post-T-10) | SP01 T-4 / SP03 cron-wrapper consumer | Per-user autonomous job config: launchd plists, cron schedules, tripwires, observability. Populated by onboarding interview; owned by librarian post-seed. |

## Source SHAs (re-fork at SP09 T-9)

Re-forked from live `~/.claude/schemas/` at `~/.claude` HEAD `b04e6f8` (2026-04-28). Per-file source SHAs (live-side, pre-fork):

```
52b29e7911553e1dc4f655d3465f8f406e9d7566a4109a04ff45c117b20a7bb8  librarian-manifest-schema.json
d6c422bbcbb571c7e5b0c97b34a158d4729d5e120c5a4ecedfb52c855e0618d2  orchestration-schema.json
15b5e43725a36987fb70093dffd908d942c6d8780d6951570bb8b6eb83c20a49  plan-manifest-schema.json
78d80090e49b08e65e291968e73e6284bf5de1c2b5fdfac6a93fbba379464aaf  plans-schema.json
58001a2691afea64eb2a8ef2a0eac39f84a659f674e3ccd063e1cbd09f0e7a33  user-manifest-schema.json
4fcae298b3bf137de39d61d06a5b52195c1283459f3b3198b10ba035ff53a4b1  vault-schema.json
```

`user-manifest-schema.json` foundation-repo SHA diverges from source post-T-9 due to the **1.2.0 fold-in** (intentional, per AR-3 atomicity): version const bump + 4 missing F-07 fields + 1 F-08 field added. Foundation-repo post-fold-in SHA: `83175cde164895fcdd7c90fcc5bfc1bf82cecb8355d7f322b3bcfeed24099f40`. The other 5 schemas are byte-identical to live source.

## Post-T-10 distribution rules

- **Sanctioned schemas (vault, plans, plan-manifest):** STAY in live `~/.claude/schemas/` (canonical) AND mirror here (published-snapshot). Drift between the two is a daily librarian finding (SP09 T-12.7 capability `sanctioned-schema-drift-detect.sh` planned).
- **Unsanctioned schemas (librarian-manifest, user-manifest, orchestration):** Live `~/.claude/schemas/` copies REMOVED at SP09 T-10. Foundation-repo here is the only source. SP08 install.sh ships them to a fresh target user's `$CLAUDE_HOME/schemas/`.

## SP06 13-field contract (user-manifest 1.2.0)

The 13 fields enumerated in SP06 (generic-processing-skills) manifest.json:150-164 `manifest_fields_consumed` are all present in foundation-repo `user-manifest-schema.json` v1.2.0:

`vault.root`, `backlog.{index_path,archive_path,progress_dir,clusters[]}`, `dashboard.{enabled,path}`, `paths.{hooks_state,cron_log_dir,plans_root}`, `brief_repos[]`, `crons.groups[]`, `system.timezone`.

Plus `vault.context_documents[]` per SP-06-audit F-08 remediation (default `["CLAUDE.md"]` for new users).
