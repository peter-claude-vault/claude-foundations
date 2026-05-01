# Release Checklist — claude-foundations v2.0.0

This checklist gates `v2.0.0-rc1` and `v2.0.0` tag-cuts. Run through it BEFORE pushing any `v*` or `v*-rc*` tag. The `release.yml` four-stage gate (Sigstore signature verify + JSON field-gate; see Plan 71 SP08 spec §release-attestation) catches CI-side problems automatically; this checklist catches the out-of-band prerequisites that automation cannot verify.

**Critical hazard up front — read before Step 1.** Sigstore attestations are immutable. Once `actions/attest-build-provenance@v2` posts an attestation to GitHub's registry, it is bound to the file's SHA-256 digest **forever** (the underlying Rekor transparency log is append-only by design). Tag deletion does NOT retract the attestation, the workflow run, or the smoke logs. A green smoke against a not-actually-ready binary leaves a permanently valid blessing of that digest with no retraction path. Treat any digest you've ever fired `macos-smoke.yml` against as permanently committed.

## Sequence

### Step 1 — Validate the macos-smoke chain via `workflow_dispatch` (NOT a tag)

Before committing to a `v2.0.0-rc1` tag identity, verify the L1 + L2 + L3 chain end-to-end without producing a tag artifact:

```bash
gh workflow run macos-smoke.yml \
  --repo peter-claude-vault/claude-foundations \
  --ref main
```

Watch the run in the Actions tab. Verify:

- [ ] All steps green (install → render → bootstrap → uninstall lifecycle clean)
- [ ] `macos-smoke-passed.json` artifact uploaded (90d retention)
- [ ] `Sign macos-smoke-passed.json via Sigstore (OIDC)` step succeeded — attestation posted to GitHub's attestation registry indexed by file digest

If the run fails: debug, fix, push, re-run `workflow_dispatch`. Iterate until green without ever cutting an rc-tag. Do NOT advance to Step 5 until at least one `workflow_dispatch` run is green on the SHA you intend to tag.

**Why `workflow_dispatch` first.** A `push: tags: ['v*-rc*']` trigger and a `workflow_dispatch` trigger produce attestations with identical trust models — same OIDC issuer, same workload identity, same Sigstore Fulcio cert. The encoded `workflow_ref` differs (`refs/heads/main` vs `refs/tags/v2.0.0-rc1`), but the cryptographic binding is to the file digest in both cases. Validating via `workflow_dispatch` first means you don't burn an rc-tag identity on a debug iteration.

### Step 2 — Verify SP08 T-7 Lima E2E acceptance (8 ACs)

Per `~/.claude-plans/71-claude-foundations-engine-v2/08-distribution-installer-adopt/tasks.md` T-7. All 8 must be `[x]` before proceeding:

- [ ] **AC #1** SP00 harness-selfcheck green before run (Lima `mounts: []` + readiness-gate fires)
- [ ] **AC #2** Pre-dogfood contract all 7 invariants green (git status clean, rsync snapshot, vault status, file-history mtime, LaunchAgents baseline, harness-selfcheck, SP00 fork-readiness)
- [ ] **AC #3** Install → onboard → `/adopt` → librarian fire all exit 0
- [ ] **AC #4** 24h simulated observation: zero hook DENYs, zero cron failures, zero data loss
- [ ] **AC #5** Uninstall residue = 0 bytes (shasum diff vs pre-install snapshot)
- [ ] **AC #6** SP00 grep-audit 4-layer on `/results` returns zero hits pre-archive
- [ ] **AC #7** Dogfood tarball committed to `dogfood-history/` post-scrub
- [ ] **AC #8** Rollback drill executes cleanly in deliberate-failure variant

### Step 3 — Verify SP07 T-11.5 evidence (audit AR-8 hard-dep on T-8)

Per SP08 spec L316-318: "SP08 T-7 Lima E2E acceptance includes: SP07 T-11.5 macOS-host voice smoke test passed (verified via `state/T-11.5-evidence.md` mtime > SP08 T-7 start mtime). If T-11.5 fails or absent, SP08 T-7 acceptance fails."

- [ ] `state/T-11.5-evidence.md` exists in foundation-repo
- [ ] `state/T-11.5-evidence.md` mtime > SP08 T-7 start mtime (verify via `stat`)
- [ ] Voice smoke test on macOS host passed per evidence file content

### Step 4 — Burner-key revocation audit (T-8 AC #4; spec L245)

For every burner key ID in `burner-keys.registry`:

```bash
curl -H "Authorization: Bearer $CONSOLE_TOKEN" \
  "https://api.anthropic.com/keys/$OLD_BURNER_ID"
```

- [ ] Every historical burner key returns **410 Gone** OR **403 Unauthorized**
- [ ] No historical burner key returns **200 OK** (key still live = release blocked)

Rotation alone leaves the old key exploitable until it expires; revocation via Anthropic console API is the only irreversible termination. The `release.yml` workflow does NOT execute this check (it doesn't have `$CONSOLE_TOKEN`); this is a manual pre-flight.

### Step 5 — Cut the rc-tag (Peter only; spec L302)

Only when Steps 1-4 are all checked:

```bash
cd ~/Code/claude-foundations-v2
git checkout main
git pull --ff-only
git tag -a v2.0.0-rc1 -m "v2.0.0-rc1 — Plan 71 supersedes Plan 38 (711cf6a); April-13 autopsy at docs/april-13-autopsy.md"
git push origin v2.0.0-rc1
```

This fires `macos-smoke.yml` (rc-tag trigger). Watch the run in the Actions tab. The Sigstore attestation it produces becomes the digest blessing under the rc1 identity. **It is permanent and immutable in Rekor.** Do not push this tag unless you are committing to that digest as the rc1 release candidate.

### Step 6 — After macos-smoke.yml green on the rc-tag, cut the v-tag

```bash
git tag -a v2.0.0 -m "v2.0.0 — supersedes v2.0.0-rc1; release notes per docs/release-notes-v2.0.0.md"
git push origin v2.0.0
```

This fires `release.yml` four-stage gate:

1. Locate macos-smoke run for tag SHA
2. Download `macos-smoke-passed.json` artifact
3. `gh attestation verify` (Sigstore signature + workload identity)
4. Field-gate: `smoke_exit == 0`, `foundation_sha == github.sha`, `generated_at < 7d`

Gate exit codes 60-65. Watch the run; if any stage fails, the tag is rejected pre-publish.

### Step 7 — 30-day GA observation (spec L297-300)

- [ ] Zero severity-≥-high incidents during 30-day window
- [ ] Total severity-medium incident count ≤ 2
- [ ] Peter is sole classifier (spec L302) — no agent / automation can flip GA status

**Retraction trigger** (spec L298). Any severity-≥-high incident requires immediate:

```bash
git tag -d v2.0.0-rc1
git push origin :v2.0.0-rc1
# Document in incidents/ with Peter's severity classification
# Ship a new RC after autopsy
```

Note: tag deletion does NOT retract the workflow run, smoke logs, or Sigstore attestation. The attestation persists in Rekor permanently. The retraction removes the ref but not the digest blessing — design downstream verifiers to additionally check ref-existence if that matters for their trust model.

## Hazard notes

- **Sigstore attestation immutability.** The attestation binds to the file's SHA-256 digest, not the tag. Tag retraction is theater for the attestation layer. A `workflow_dispatch` run produces an attestation as permanent as a tag-push run. Plan accordingly: every digest you fire `macos-smoke.yml` against is permanently blessed in Rekor.

- **`GITHUB_TOKEN` recursion gate.** A `push: tags:` workflow does NOT fire from a push made with the in-workflow `${{ secrets.GITHUB_TOKEN }}` (anti-recursion gate). Any other actor — your account, a GitHub App, a PAT — DOES fire it. Plan tag-pushes from your account only; never from automation that uses the workflow-internal token to push tags it expects to trigger downstream.

- **Classification authority.** Per spec L302, Peter is sole classifier for severity-tier incidents during the 30-day GA window. No agent / automation can flip the GA status; no spec section grants release-cut authority to anything other than Peter.

- **Out-of-band prereqs.** Steps 3 (T-11.5 evidence file presence) + 4 (burner-key revocation via console API) cannot be verified by `release.yml` — it has neither filesystem access to plans-dir/vault nor `$CONSOLE_TOKEN`. They are manual pre-flights; this checklist is the audit trail.

## Skill

This checklist is documentation, not a sentinel. Committing it does not trigger anything. Update it whenever a new prereq surfaces from a future SP08 audit; treat it as the authoritative pre-tag-cut runbook.
