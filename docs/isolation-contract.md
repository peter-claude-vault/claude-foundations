# Isolation Contract (STUB)

**Status:** stub — full consumer API lands in SP00 T-12.
**Owner:** Sub-plan 00 (Isolation Harness).

This file is the single canonical consumer API for SP00's 11 primitives. T-9 lands the skeleton; T-12 formalizes the 10-invariant list, per-primitive invocation signatures, and the bypass-detection grep-audit rule.

## What this file will cover (T-12 scope)

- 11 primitives × first-consumer × invocation signature
- 10 invariants (I1..I10) enumerated
- Bypass detection: grep-audit flags any direct `nerdctl run` / `docker run` / `limactl shell` that skips `tests/runner-shell.sh`
- Readiness gate (T-1) as the ONLY approved test entrypoint

## T-9 deliverable: sandbox-exec + macOS smoke driver

### Components

- `tests/dogfood.sb` — sandbox profile skeleton (Primitive P4)
- `tests/macos-smoke-driver.sh` — driver that sources P9 (`$DOGFOOD_ROOT`) and runs caller cmd under `sandbox-exec`

### Invocation

```bash
. tests/dogfood-root-helper.sh
tests/macos-smoke-driver.sh <cmd> [args...]
```

The driver:
1. Verifies `$DOGFOOD_ROOT` is set (from sourced P9 helper) and the profile file is present.
2. Pre-flights the `.sb` via `sandbox-exec -f <profile> -D DOGFOOD_ROOT=... /usr/bin/true` (fails-open guard: a malformed or too-tight profile aborts at `/usr/bin/true` before the caller's cmd runs).
3. Exec's the caller cmd under `HOME=$DOGFOOD_ROOT sandbox-exec -f tests/dogfood.sb -D DOGFOOD_ROOT=... <cmd>`.

### TCC (Full Disk Access) interaction — known host quirk

On a fresh macOS host, the **first** `sandbox-exec` invocation may trigger a Transparency / Consent / Control (TCC) prompt requesting Full Disk Access for the invoking terminal (or for `sandbox-exec` itself). This is a user-visible dialog; CI environments must either:

1. Pre-grant TCC Full Disk Access to the CI runner binary (GitHub Actions macOS runners already have a broad TCC policy via the provisioning profile — no prompt expected).
2. OR run the driver first in a warm-up step that surfaces the prompt, then dismiss manually before the real test run.

If a prompt fires inside a non-interactive shell (CI log artifacts show `sandbox-exec` hung on stdin), the runner deadlocks. `tests/runner-shell.sh` (T-10) MUST set a wall-clock timeout around `sandbox-exec` invocations to avoid this silent hang mode. T-12 formalizes the timeout contract.

### First downstream consumer

SP03 T-14 — macOS real-launchd smoke. That task exec's the installer's `launchctl bootstrap` leg under `tests/macos-smoke-driver.sh`, catches any unauthorized writes outside `$DOGFOOD_ROOT`, and verifies the plist-lint (T-8) + lifecycle-assertion stack fires before real launchd touches the host.

### Not in T-9 scope

- Per-syscall `mach-lookup` allowlist (T-12)
- Network-specific deny diagnostics (T-12)
- Bypass-detection grep-audit rule (T-12)
- Full 10-invariant enumeration (T-12)
- 11-primitive × first-consumer matrix (T-12)
