# installer/

Helpers that render `launchd` plists from `orchestration.json` and bootout existing plists during install/uninstall. Consumed by `install.sh`, `uninstall.sh`, and the `/connectors` wizard.

| File | Role |
|---|---|
| `render-launchd.sh` | Renders one plist from a template. Reads schedule (calendar or interval shape) from `orchestration.json`, substitutes env vars via an allowlist, lints with `plutil`, atomically moves the result into `~/Library/LaunchAgents/`, and (in production mode) `launchctl bootout` + `launchctl bootstrap`s the resulting label. |
| `render-all-launchd.sh` | Iterates every job declared in `orchestration.json#/jobs[]` and invokes `render-launchd.sh` per job. Skips jobs without a matching template and skips `connector-runtime` (the connector wizard handles that one per-connector). |
| `bootout-launchd.sh` | Boots out and removes every `com.claude-stem.*` plist. Reads each plist's `Label` via `plutil` before removing the file, so a label that has drifted outside the namespace is refused. |
| `disable-daemon.sh` | Per-label disable helper. Idempotent — already-inactive bootout codes (3, 36, 113) are treated as no-op. Refuses any label outside `com.claude-stem.*`. |

The plist templates the renderer consumes live in [`templates/launchd/`](../templates/).

## When you'd touch this directory

- Adding a new scheduled job: drop a `.plist.tmpl` into `templates/launchd/`, add a job entry to `orchestration.json`, and `render-all-launchd.sh` picks it up.
- Debugging why a job isn't firing: `launchctl print gui/$UID/com.claude-stem.<job>` is the macOS source of truth; the renderer's job is to get the plist on disk and bootstrapped.

See [`docs/installer.md`](../docs/installer.md) for the full installer reference and [`templates/README.md`](../templates/README.md) for the plist-template inventory.
