# Burner API Key Runbook

**Status:** active — SP00 T-11 deliverable.
**Owner:** Sub-plan 00 (Isolation Harness).
**First downstream consumers:** SP03 T-8 (cold-wake probe invokes real `claude -p`); SP07 T-5 (verbal-first extraction synthesis).

---

## Purpose

The `foundations-v2` test surface can, in later sub-plans, invoke the real Anthropic API. That requires an `ANTHROPIC_API_KEY`. This runbook defines the only approved lifecycle for such a key: a **disposable, zero-budget, test-project-scoped** credential that never overlaps with a production key and is injected via the BuildKit secret mount — never via a `-e` env var.

Five phases, each with a verify-command:

1. **Create** — provision a disposable key with a date-stamped label, pinned to a test-only project.
2. **Budget-enforce** — cap the project budget at zero so a leaked key cannot incur spend.
3. **Scope** — confirm the key lives in a project distinct from any production workspace.
4. **Inject** — pass the key into container builds exclusively via BuildKit `--secret`; never env.
5. **Revoke + verify** — rotate per release candidate; verify revocation returns 401/403.

---

## Phase 1 — Create

**Who:** human operator, via the Anthropic console, before any consumer sub-plan dispatches.

**Steps:**

1. Open the Anthropic console → API keys.
2. Select (or create) a **test-only project** distinct from any working project. See Phase 3 for scoping invariants.
3. Create a new key with the label `CLAUDE_FOUNDATIONS_BURNER_<YYYY-MM-DD>`, substituting today's date in ISO form (e.g. `CLAUDE_FOUNDATIONS_BURNER_2026-04-22`).
4. Capture the raw key value ONCE. Write it to a root-owned tmpfs path outside the repository tree:

   ```bash
   umask 077
   printf '%s' '<paste-key-here>' > /tmp/.burner-key
   chmod 600 /tmp/.burner-key
   ```

   `/tmp/.burner-key` is the path the Phase 4 BuildKit `--secret` mount reads. It must never be committed, symlinked into the tree, or referenced by an absolute path outside this runbook.

5. Screenshot the console showing the label and the project assignment. Store the screenshot with the RC tag in the release evidence bundle — outside the repository.

**Verify-command:**

```bash
test -f /tmp/.burner-key && test "$(stat -f %Lp /tmp/.burner-key 2>/dev/null || stat -c %a /tmp/.burner-key)" = "600"
```

Exit 0 means: the burner file exists and is mode 0600. Any other state is a provisioning error — delete and redo.

---

## Phase 2 — Budget-enforce

**Who:** human operator, immediately after Phase 1.

**Invariant:** the test-only project's monthly budget is **zero dollars**. A leaked key, or a runaway test, cannot cause spend. This is enforced in the Anthropic console at the **project** level, not the key level.

**Steps:**

1. Console → project settings → Usage limits → set monthly spend cap to `$0`.
2. Set the per-request hard limit to a small ceiling (e.g. 1000 input tokens) if the console allows — a second layer on top of the project cap.
3. Screenshot the usage-limits panel; store with the RC evidence bundle.

**Verify-command:**

```bash
curl -s -X POST https://api.anthropic.com/v1/messages \
  -H "x-api-key: $(cat /tmp/.burner-key)" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"x"}]}' \
  -o /tmp/.burner-probe.json -w '%{http_code}\n'
```

**Expected outcome at budget-zero:** HTTP `400` or `429` with an `error.type` of `"invalid_request_error"` or `"rate_limit_error"` carrying a message about the project's spend cap. HTTP `200` here means Phase 2 failed — the cap is not in place. Delete and redo from Phase 1.

`jq -r .error.message /tmp/.burner-probe.json` surfaces the console-side cap message for archival.

---

## Phase 3 — Scope

**Invariant:** the burner key lives in a project that contains **no other keys, no production data, and no human-operator credentials**. One project, one key, one purpose.

**Steps:**

1. In the Anthropic console, confirm the burner key is the only key in its project.
2. Confirm the project name does **not** share a prefix or suffix with any working-project name.
3. Record the last-4 of the burner key prefix (e.g. if the key starts with `sk-ant-api03-abcd...`, record `abcd`) in the RC evidence bundle.

**Verify-command:**

```bash
burner_prefix=$(head -c 20 /tmp/.burner-key)
# A working key must never share a prefix with the burner.
# If a working key exists on the host for any reason, confirm its prefix
# does not collide with the burner's.
if [ -f ~/.anthropic/working-key ] && [ "$(head -c 20 ~/.anthropic/working-key)" = "$burner_prefix" ]; then
  echo "COLLISION: burner and working key share a prefix — destroy the burner and re-provision" >&2
  exit 1
fi
echo "scope-ok"
```

`~/.anthropic/working-key` is an illustrative path for host-side key management. If the host stores working credentials elsewhere (macOS Keychain, 1Password, environment), adapt the check to that surface — the invariant is the prefix non-collision, not the path.

---

## Phase 4 — Inject

**Invariant:** the burner key enters the container build via BuildKit's `--secret` mount. **Never via `-e ANTHROPIC_API_KEY=`, never via a `COPY`, never via a Dockerfile `ARG`.**

### Approved pattern

```bash
# Host side (macOS), invoking nerdctl inside Lima:
limactl shell foundations -- bash -lc '
  nerdctl build \
    --secret id=anthropic_api_key,src=/tmp/.burner-key \
    --tag sp0X-consumer:$(git rev-parse --short HEAD) \
    -f docker/Dockerfile.consumer \
    .
'
```

### Inside the Dockerfile

```dockerfile
# Only steps that need the key mount it for that RUN, and the key is not
# persisted into the image layer.
RUN --mount=type=secret,id=anthropic_api_key,mode=0400 \
    ANTHROPIC_API_KEY=$(cat /run/secrets/anthropic_api_key) \
    /opt/claude-code/install.sh
```

### Runtime injection (when a RUNNING container needs the key)

For probes where the key is consumed at `docker run` time (not `build` time), mount the same path into the container as a tmpfs-backed file owned by `tester`:

```bash
nerdctl run --rm \
  --tmpfs /home/tester:uid=1000,gid=1000,mode=1777 \
  --mount type=bind,src=/tmp/.burner-key,dst=/run/secrets/anthropic_api_key,ro \
  --network=bridge \
  sp0X-consumer:<sha> \
  /tests/consumer-entry.sh
```

The container entrypoint reads `/run/secrets/anthropic_api_key` directly; the allowlist in `docker/entrypoint-scrub-env.sh` is the enforcement floor — the key NAME never appears as an env var crossing the scrub.

### Prohibited patterns

The following patterns are forbidden anywhere in `foundations-v2`:

1. `nerdctl run -e ANTHROPIC_API_KEY=...` — env injection survives the scrub only if added to the allowlist, and it will not be. The `docker/entrypoint-scrub-env.sh` allowlist (see `ALLOWED_VARS`) deliberately omits `ANTHROPIC_API_KEY` for this exact reason.
2. `docker run -e ANTHROPIC_API_KEY=...` — same reason.
3. `ENV ANTHROPIC_API_KEY=` in any Dockerfile — bakes the key into the image layer.
4. `COPY .burner-key /...` in any Dockerfile — bakes the key into the image layer.
5. `ARG ANTHROPIC_API_KEY` — surfaces the key in `docker history`.
6. Any reference to a real key value committed to git. Key values are opaque tokens; the layer-4 history scan in `tests/grep-audit.sh` is the backstop — a leaked key in history requires a `git-filter-repo` scrub and a new burner from Phase 1.

**Verify-command (build-time mount is correct):**

```bash
# After a build that should have mounted the secret, confirm the image
# has no trace of the key value in any layer.
image=sp0X-consumer:<sha>
nerdctl image history --no-trunc "$image" | grep -Ei 'ANTHROPIC|sk-ant|burner' && {
  echo "LEAK: image history references the key"; exit 1;
}
nerdctl save "$image" | tar -x -O --wildcards '*/layer.tar' 2>/dev/null \
  | tar -x -O 2>/dev/null | LC_ALL=C grep -a -c "$(head -c 12 /tmp/.burner-key)" \
  | tee /tmp/.burner-leak-count
test "$(cat /tmp/.burner-leak-count)" = "0"
```

Exit 0 means: no layer contains the first 12 characters of the burner key. Any non-zero hit means the `--mount=type=secret` pattern was bypassed — destroy the image, re-provision from Phase 1, and audit the Dockerfile.

---

## Phase 5 — Revoke + verify

**Invariant:** the burner is revoked at the end of every release candidate (RC) cycle. A new burner is provisioned for the next RC. No key outlives its RC.

**Steps:**

1. Anthropic console → API keys → locate `CLAUDE_FOUNDATIONS_BURNER_<YYYY-MM-DD>` → Revoke.
2. Delete the local file:

   ```bash
   shred -u /tmp/.burner-key 2>/dev/null || rm -f /tmp/.burner-key
   ```

3. Archive the key's prefix (last-4 from Phase 3) + revocation timestamp in the RC evidence bundle.

**Verify-command:**

```bash
# Use a saved prefix from Phase 3 to probe the revoked key; a SHELL history
# copy of the key value is acceptable ONLY for this one verify-then-delete call.
curl -s -I -X GET https://api.anthropic.com/v1/messages \
  -H "x-api-key: <prefix>-<rest-from-terminal-paste>" \
  -H "anthropic-version: 2023-06-01" \
  -o /dev/null -w '%{http_code}\n'
```

**Expected:** HTTP `401` or `403`. Anything else — especially `200`, `400`, or `429` — means the revoke did not propagate; retry the console revoke and re-probe until two consecutive probes return 401/403 at least 60 seconds apart.

### SP08 T-9 pre-tag check

Before `foundations-v2` cuts a release tag, SP08 T-9 runs this verify-command against every burner referenced by this RC's evidence bundle. Any burner returning non-401/403 blocks the tag.

---

## Enforcement surface

This runbook is enforced by three existing mechanisms in `foundations-v2`:

- **`docker/entrypoint-scrub-env.sh`** (SP00 T-3) — the `ALLOWED_VARS` allowlist deliberately omits `ANTHROPIC_API_KEY`. Any env-var injection is stripped before the container command runs.
- **`tests/grep-audit.sh`** (SP00 T-7) — layer-4 scans the full git history; any real key value committed to git (even if reverted at HEAD) is a blocker. SP00 T-13 expands layer-1 fixed-string patterns as the exhaustive reference-leak floor.
- **`tests/readiness-gate.sh`** (SP00 T-1, formalized in SP00 T-12) — the 3 invariants (I_HOME, I_USERS, I_UID) run before any test that could consume a burner; a tampered container short-circuits before the key mount is read.

This runbook is the human-facing procedure. The scripts are the machine-facing enforcement. Both must stay aligned.

---

## Cross-references

- `docker/entrypoint-scrub-env.sh` — env scrub allowlist
- `docker/Dockerfile` — `CLAUDE_HOME`, `PLANS_HOME`, `TEST_MODE`, `MOCK_LAUNCHCTL`, `CI` ENV floor
- `tests/grep-audit.sh` — 4-layer reference-leak audit (T-7)
- `tests/readiness-gate.sh` — 3-invariant pre-flight gate (T-1 → T-12)
- `docs/isolation-contract.md` — consumer API for all 11 SP00 primitives (T-12)
