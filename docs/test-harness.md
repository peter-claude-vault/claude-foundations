# Test Harness

The test harness is a Lima VM with `mounts: []` running rootless containerd. The host filesystem is structurally unreachable from inside the VM. There is one approved entrypoint (`tests/runner-shell.sh`), and that entrypoint runs a three-invariant readiness gate as its first action — if the gate fails, no test cases run.

**Audience:** contributors who want to add tests, or to understand why the harness refuses to run a particular invocation.

---

## 1. The single approved entrypoint

```
tests/runner-shell.sh [cases-dir] [results-dir]
```

The runner-shell runs `tests/readiness-gate.sh` as its first action. If any of the three structural invariants (I_HOME, I_USERS, I_UID — see §3) fails, the runner exits 2 with a diagnostic naming the failing invariant and **no test cases run**. This is the ONLY approved entrypoint for executing acceptance cases.

Direct invocations of `nerdctl run <image> /bin/bash`, `docker run … sh`, `podman run … sh -c '…'`, or `ctr run` with a raw shell as final argv are **contract violations**. `tests/bypass-audit.sh` (wired into `.github/workflows/grep-audit.yml`) flags them as CI failures.

**Why one entrypoint, enforced structurally:** operational safety is physically impossible to bypass, not conventionally discouraged. The readiness gate is the one place where "am I actually inside the isolation envelope?" is proven; any other invocation path skips it. A grep-audit rule is cheaper than an incident review — so the rule exists and gates every PR.

There is **no** `SKIP_READINESS_GATE=1` env flag. There is **no** `--bypass` flag. If a test case needs to run outside the gate, that test case does not belong in this harness.

---

## 2. Primitive inventory

Each row: primitive name, the file that implements it, and the sanctioned invocation signature.

| #  | Primitive                                    | Implementation                                    | Invocation signature                                                                                                                         |
|----|----------------------------------------------|---------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------|
| P1 | Lima VM with `mounts: []`                    | `lima/foundations.yaml`                           | `limactl start foundations` (one-time). All test invocations nest inside `limactl shell foundations -- …`.                                    |
| P2 | Rootless containerd + nerdctl image          | `docker/Dockerfile`, `docker/build.sh`            | `limactl shell foundations -- nerdctl run --rm --tmpfs /home/tester:uid=1000,gid=1000,mode=1777 --network=none <image> /tests/runner-shell.sh` |
| P3 | `/etc/passwd` UID remap (`tester:1000`)      | `docker/Dockerfile` (`useradd -m -u 1000`)        | Implicit — any run under P2 satisfies it. Verified by readiness-gate's I_UID check.                                                           |
| P4 | `sandbox-exec` profile + macOS smoke driver  | `tests/dogfood.sb`, `tests/macos-smoke-driver.sh` | `. tests/dogfood-root-helper.sh && tests/macos-smoke-driver.sh <cmd> [args]` (timeout env: `SANDBOX_EXEC_TIMEOUT`, default 60s)                |
| P5 | `MOCK_LAUNCHCTL=1` stub + plist lint         | `tests/mock-launchctl.sh`, `tests/plist-lint.sh`  | `MOCK_LAUNCHCTL=1` set by Dockerfile ENV; `/usr/local/bin/launchctl` symlinked to `/tests/mock-launchctl.sh`. Consumers call `launchctl …` verbatim. |
| P6 | 4-layer grep-audit CI                        | `tests/grep-audit.sh`, `tests/bypass-audit.sh`    | `tests/grep-audit.sh <tree>` (exit 0 clean, 1 any layer hit); `tests/bypass-audit.sh <tree>` (exit 0 clean, 1 hit). Both fire in CI on every push/PR/release tag. |
| P7 | Pre-write-guard test mode                    | `~/.claude/hooks/pre-write-guard.sh`              | Set `FOUNDATION_TEST_MODE=1` + `DOGFOOD_ROOT=<path>`; hook refuses writes outside the allowlist.                                               |
| P8 | git-snapshot + rollback drill                | `tests/git-snapshot.sh`, `tests/git-revert.sh`, `tests/drill-rollback.sh` | `tests/git-snapshot.sh <label>` → tag + commit anchor; `tests/git-revert.sh <label>` restores; `tests/drill-rollback.sh` rehearses end-to-end before any live migration. |
| P9 | `$DOGFOOD_ROOT` mktemp helper                | `tests/dogfood-root-helper.sh`                    | `. tests/dogfood-root-helper.sh` sources; exports `DOGFOOD_ROOT=$(mktemp -d …)` with trap-on-exit cleanup.                                     |
| P10| Env-allowlist entrypoint                     | `docker/entrypoint-scrub-env.sh`                  | Wired as `ENTRYPOINT ["/entrypoint.sh"]`. Allowlist: `CLAUDE_HOME PLANS_HOME TEST_MODE MOCK_LAUNCHCTL CI DOGFOOD_ROOT FOUNDATION_TEST_MODE`. All others stripped. |
| P11| Burner `ANTHROPIC_API_KEY` runbook           | `docs/burner-key-runbook.md`                      | 5-phase lifecycle (create / budget-enforce / scope / inject / revoke), each with a verify-command. Inject is BuildKit `--secret id=anthropic_api_key,src=…`. |

---

## 3. Structural invariants

Each invariant maps to a physical enforcement mechanism, not a discipline note.

| #   | Invariant                                                                              | Enforced by       | Failure diagnostic                                                                                              |
|-----|----------------------------------------------------------------------------------------|-------------------|-----------------------------------------------------------------------------------------------------------------|
| I1  | No test writes to the host user's live `~/.claude/`                                    | P1, P3            | Lima `mounts: []` → `/Users` ENOENT inside VM; `/etc/passwd` resolves `~` to `/home/tester`. Readiness gate I_USERS + I_HOME. |
| I2  | No test fires a real `launchctl bootstrap` on the host                                 | P5, P4            | Linux container: `launchctl` is a symlink to `tests/mock-launchctl.sh`. macOS smoke: `sandbox-exec` deny-default on `file-write*` outside `$DOGFOOD_ROOT`. |
| I3  | Every distributed artifact passes 4-layer grep-audit before commit and merge           | P6                | `.github/workflows/grep-audit.yml` runs `tests/grep-audit.sh .` on every push/PR; any layer hit → CI red.       |
| I4  | Burner API key is the only Claude credential reachable inside isolation                | P10, P11          | `entrypoint-scrub-env.sh` allowlist omits `ANTHROPIC_API_KEY`; key injected via BuildKit `--secret` only; burner scoped to zero-budget test project. |
| I5  | No identifying strings exfil via `/results`, logs, or tarballs                         | P6                | grep-audit against `/results/` before archive; exfil via scp — no host bind-mount.                              |
| I6  | Live-env mutations are atomic-success-or-full-revert                                   | P7, P8            | `pre-write-guard.sh` with `FOUNDATION_TEST_MODE=1` refuses partial writes; `tests/git-snapshot.sh` + rollback drill rehearsed pre-migration. |
| I7  | `$CLAUDE_HOME` resolved once at installer top; no secondary `$HOME/.claude` refs       | P6                | grep-audit pattern catches stray `$HOME/.claude` literals in source.                                            |
| I8  | Pre-dogfood snapshot exists; rollback is tested                                        | P8                | `tests/drill-rollback.sh` runs as part of self-verify; green attests the snapshot-revert path works.            |
| I9  | Container-boot invariants proven before any test runs                                  | readiness-gate    | `tests/readiness-gate.sh` asserts I_HOME + I_USERS + I_UID; fail → exit 2, runner-shell aborts.                 |
| I10 | External-research network egress cannot leak identifying strings                       | P1, P2, P6        | Lima `userNetwork` NAT + Docker `--network=none` by default; prompt templates audited by grep-audit pre-test.   |

The runtime-detectable subset of I1..I10 — the three the readiness gate checks on every boot — is **I_HOME, I_USERS, I_UID** (§4). The rest are enforced at build time (P6), at migration time (P7 + P8), or by construction (P1 + P10).

---

## 4. The readiness gate (3-invariant contract)

`tests/readiness-gate.sh` is the one place where "this run is actually inside the isolation envelope" is proven. Three invariants, each a single line of shell:

| Invariant | Check                                                                                                     | What a failure means                                                                                   |
|-----------|-----------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------|
| I_HOME    | `$HOME == "/home/tester"`                                                                                  | Env scrub didn't run OR `/etc/passwd` remap is wrong OR caller set `HOME` post-scrub.                  |
| I_USERS   | `! -e /Users` AND `! -e /Volumes`                                                                          | Docker Desktop or podman-machine substituted for Lima (auto-mounts host `/Users`); or Lima config drift re-added mounts. |
| I_UID     | `id -u == 1000` AND `stat %u $HOME == 1000` AND `/etc/passwd` contains `^tester:*:1000:`                   | Running as wrong uid, OR `/etc/passwd` tampered, OR `sudo -H` drift.                                   |

**Exit contract:**
- `exit 0` — all three pass; runner-shell proceeds to case discovery.
- `exit 2` — any invariant fails; runner-shell aborts with a diagnostic naming which invariant tripped.

**Tamper branch:** the I_UID check includes a `grep -qE '^tester:[^:]*:1000:' /etc/passwd` probe. If `/etc/passwd` is mutated to remove the `tester` line (a synthetic tamper), the gate trips with the diagnostic `I_UID /etc/passwd missing 'tester:*:1000:*' line — container tamper detected`. The `tests/readiness-gate-tamper-test.sh` host-side driver proves this branch fires correctly.

**No bypass:** `grep -rIn 'SKIP_READINESS_GATE\|SKIP_GATE\|BYPASS_READINESS' .` in the repo returns zero hits. There is no env-var escape hatch, no CLI flag, no conditional path. The only way to "bypass" the gate is to stop invoking runner-shell — which `tests/bypass-audit.sh` flags as a CI failure.

---

## 5. Bypass detection

`tests/bypass-audit.sh` scans every `.sh` / `.yml` / `.yaml` file under the repo for lines matching:

- `(nerdctl|docker|podman|ctr) run …`
- ending in a raw shell (`bash`, `sh`, `/bin/bash`, `/bin/sh`) as final argv OR containing `bash -c '…'` / `sh -c "…"` at the tail
- excluding comments, lines that also reference `runner-shell`, and files under documentation (`docs/*.md` illustrative examples).

Any hit is a CI blocker. The rule fires in `.github/workflows/grep-audit.yml` alongside the 4-layer reference-leak audit. `tests/bypass-audit-unit-test.sh` seeds 4 positive fixtures (nerdctl/docker/podman/ctr × raw-shell) and 4 negative fixtures (sanctioned runner-shell invocation, `nerdctl build`, comment, markdown); all 8 pass on a clean repo.

Exceptions are rare and documented inline at the call site:

- `tests/readiness-gate-tamper-test.sh` — the synthetic tamper driver calls `nerdctl run … --entrypoint /bin/bash … -c "<script>"`, which is the vector under test. The command string is not a bare shell, so bypass-audit correctly does not flag it.

---

## 6. Sandbox-exec macOS smoke driver

### Invocation

```bash
. tests/dogfood-root-helper.sh
tests/macos-smoke-driver.sh <cmd> [args...]
```

The driver:

1. Verifies `$DOGFOOD_ROOT` is set (from the sourced helper) and points at an existing directory.
2. Canonicalizes `$DOGFOOD_ROOT` via `cd && pwd -P` so the `/var` → `/private/var` symlink does not break `sandbox-exec`'s `-D DOGFOOD_ROOT=…` param matching at enforcement time.
3. Pre-flights the `.sb` profile by running `sandbox-exec -f <profile> -D DOGFOOD_ROOT=… /usr/bin/true` — under a wall-clock timeout (see §6.1). Any non-zero exit aborts before the caller's command runs.
4. Runs the caller's command under `HOME=$DOGFOOD_ROOT sandbox-exec -f tests/dogfood.sb -D DOGFOOD_ROOT=… <cmd> [args]` — also under the timeout. Caller exit is propagated verbatim.

### 6.1 TCC (Full Disk Access) interaction and wall-clock timeout

On a fresh macOS host, the **first** `sandbox-exec` invocation may trigger a TCC (Transparency / Consent / Control) prompt requesting Full Disk Access for the invoking terminal or for `sandbox-exec` itself. In an interactive session the prompt is a visible dialog; in a non-interactive session (CI, `claude -p` dispatch, cron) the dialog cannot surface and the call hangs indefinitely.

`tests/macos-smoke-driver.sh` wraps both `sandbox-exec` invocations in a bash-native `timebox` helper that enforces `SANDBOX_EXEC_TIMEOUT` seconds (default 60). On timeout the driver exits **69** with the diagnostic:

> `pre-flight lint TIMED OUT after Ns — likely TCC Full Disk Access prompt pending. Open System Settings → Privacy & Security → Full Disk Access, grant the invoking terminal (or sandbox-exec), then retry.`

Hosts where Full Disk Access has already been granted once see `sandbox-exec` return in milliseconds and the timeout never fires. CI environments with broad TCC provisioning profiles (GitHub Actions macOS runners) bypass the prompt entirely.

---

## 7. Unreachable-by-construction: host paths

The Lima VM is configured with `mounts: []`. Inside the VM, `/proc/mounts` contains no entries with `^/Users` or `^/Volumes` prefixes — the host macOS filesystem is physically absent from the guest. A test that hardcodes a host-side path (`/Users/<name>/...`) gets `ENOENT` at the VFS layer; there is no silent-fallthrough mode.

The self-verify suite asserts this as invariant I1: `limactl shell foundations -- cat /proc/mounts | grep -E '^/Users|^/Volumes'` returns empty (grep exit 1). Any host-path mount surfacing in this probe is a config-drift failure; the `audit-lima-config-label` job in `.github/workflows/grep-audit.yml` requires an `isolation-config-review` PR label before any `lima/foundations.yaml` mutation can merge — that's the pre-merge enforcement.

---

## 8. Invocation recipes

### 8.1 Run a synthetic test suite

```bash
limactl shell foundations -- bash -lc '
  export XDG_RUNTIME_DIR=/run/user/$(id -u) && \
  nerdctl run --rm \
    --tmpfs /home/tester:uid=1000,gid=1000,mode=1777 \
    --network=none \
    isolation-image:<digest-or-tag> \
    /tests/runner-shell.sh /tests/my-cases
'
```

Exit code is `max(per-case exit)`; `/results/summary.json` captures per-case outcomes. The consumer copies `/results/` back to host via `tests/runner-exfil.sh <target>` (runs inside the container as a subsequent invocation, or via `scp` — never via bind-mount).

### 8.2 Run the macOS real-launchd smoke test

```bash
. tests/dogfood-root-helper.sh   # sets $DOGFOOD_ROOT, traps rm on exit
SANDBOX_EXEC_TIMEOUT=90 \
  tests/macos-smoke-driver.sh /usr/bin/launchctl bootstrap gui/$UID /path/to/plist
```

### 8.3 Inject a burner API key at container run time

```bash
# burner provisioned per docs/burner-key-runbook.md Phase 1; file at /tmp/.burner-key mode 0600
nerdctl run --rm \
  --tmpfs /home/tester:uid=1000,gid=1000,mode=1777 \
  --mount type=bind,src=/tmp/.burner-key,dst=/run/secrets/anthropic_api_key,ro \
  --network=bridge \
  consumer-image:<digest> \
  /tests/runner-shell.sh /tests/my-api-cases
```

The consumer image's test cases read `/run/secrets/anthropic_api_key` directly — the allowlist in `entrypoint-scrub-env.sh` deliberately omits `ANTHROPIC_API_KEY` so there is no env-var path to smuggle a working-project key into an isolated run.

---

## 9. What contributors must do

When adding a test:

1. Invoke `tests/runner-shell.sh` for all acceptance cases (never a bare shell).
2. Source `tests/dogfood-root-helper.sh` before any `sandbox-exec`-based macOS smoke.
3. Follow [`burner-key-runbook.md`](burner-key-runbook.md) for any real-API test.
4. Pass the bypass-audit and grep-audit on every PR. No exceptions; no skip pragmas (none exist).
5. Reference this document for the consumer API.
