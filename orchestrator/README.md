# orchestrator/

Cron-wrapper plumbing for scheduled jobs. Every launchd-fired job in the system runs through a wrapper script in this directory rather than calling the underlying skill directly.

## Why a wrapper layer

The wrappers solve four problems that a raw `launchd` plist doesn't:

1. **Logging.** Each wrapper writes a dated log to `~/.claude/logs/<job>-YYYY-MM-DD.log`. The logging convention is consistent across jobs so the librarian can scan them and surface failures.
2. **Idle watchdog.** Long-running jobs (most of them invoke `claude -p` against the Anthropic API) can hang on cold-start. The watchdog kills any wrapper that produces no log output for N minutes.
3. **Concurrency lock.** A second invocation of the same job while the first is still running is rejected via `lockf`.
4. **Cold-wake warm-up.** macOS wakes from sleep slowly. Some wrappers run a small probe call before the real work to amortize the first-call latency.

## What's here

| Path | Role |
|---|---|
| `cron-wrappers/` | One wrapper per scheduled job (e.g. `librarian-cron.sh`, `architect-cron.sh`, `connector-runtime-cron.sh`). |
| `idle-watchdog.sh` | The 180-second-no-output kill helper sourced by every wrapper. |
| `cron-health.sh` | Reads recent log files, summarizes job freshness and exit codes. Produces the banner `cron-health-banner.sh` shows on `SessionStart`. |

## How a job fires end-to-end

```
launchd plist (StartCalendarInterval)
  → orchestrator/cron-wrappers/<job>.sh
    → lockf re-exec (no double invocation)
    → cold-wake probe (one quick call)
    → real work (e.g. claude -p /architect)
    → idle-watchdog runs in parallel; kills if stalled
  → log lands at ~/.claude/logs/<job>-YYYY-MM-DD.log
  → next SessionStart, cron-health-banner reads logs and surfaces status
```

## Authoring a new cron wrapper

1. Drop the shell wrapper in `cron-wrappers/`. Source `idle-watchdog.sh`, lockf-reexec at the top, write logs to the canonical path.
2. Drop a plist template in `templates/launchd/<job>.plist.tmpl`.
3. Add a `jobs[]` entry to `orchestration.json` (or your manifest equivalent).
4. Re-run `installer/render-all-launchd.sh`.

`pre-write-guard.sh` will refuse any wrapper that uses bash 4+ syntax (`declare -A`, `${var,,}`, `readarray`, `{a..b..n}`) — these silently fail under macOS's shipped `/bin/bash` 3.2.

## See also

- [`installer/README.md`](../installer/README.md) — plist rendering.
- [`templates/README.md`](../templates/README.md) — plist templates.
- [`docs/installer.md`](../docs/installer.md) — the install flow that lays this directory down.
