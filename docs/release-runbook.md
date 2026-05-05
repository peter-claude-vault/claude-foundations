# Release Runbook

Maintainer-only. This runbook gates `v2.0.0-rc1` and `v2.0.0` tag-cuts. Walk it before pushing any `v*` or `v*-rc*` tag. The release workflow's four-stage gate (Sigstore signature verify + JSON field-gate) catches CI-side problems automatically; this runbook catches the out-of-band prerequisites automation cannot verify.

## Read this first — the immutability hazard

Sigstore attestations are immutable. Once `actions/attest-build-provenance@v2` posts an attestation to GitHub's registry, it is bound to the file's SHA-256 digest **forever** — the underlying Rekor transparency log is append-only by design. Tag deletion does NOT retract the attestation, the workflow run, or the smoke logs. A green smoke against a not-actually-ready binary leaves a permanently valid blessing of that digest with no retraction path.

Treat any digest you have ever fired `macos-smoke.yml` against as permanently committed.

## Sequence

### Step 1 — Validate the macOS smoke chain via `workflow_dispatch` (NOT a tag)

Before committing to a `v2.0.0-rc1` tag identity, verify the install / render / bootstrap / uninstall chain end-to-end without producing a tag artifact:

```bash
gh workflow run macos-smoke.yml \
  --repo peter-claude-vault/claude-stem \
  --ref main
```

Watch the run in the Actions tab. Verify:

- [ ] All steps green (install → render → bootstrap → uninstall lifecycle clean)
- [ ] `macos-smoke-passed.json` artifact uploaded (90-day retention)
- [ ] `Sign macos-smoke-passed.json via Sigstore (OIDC)` step succeeded — attestation posted to GitHub's attestation registry indexed by file digest

If the run fails: debug, fix, push, re-run `workflow_dispatch`. Iterate until green without ever cutting an rc-tag. Do NOT advance to Step 5 until at least one `workflow_dispatch` run is green on the SHA you intend to tag.

**Why `workflow_dispatch` first.** A `push: tags: ['v*-rc*']` trigger and a `workflow_dispatch` trigger produce attestations with identical trust models — same OIDC issuer, same workload identity, same Sigstore Fulcio cert. The encoded `workflow_ref` differs (`refs/heads/main` vs `refs/tags/v2.0.0-rc1`), but the cryptographic binding is to the file digest in both cases. Validating via `workflow_dispatch` first means you don't burn an rc-tag identity on a debug iteration.

### Step 2 — Verify Lima end-to-end acceptance

All of the following must be true before proceeding:

- [ ] Pre-dogfood snapshot is clean: git status clean, rsync snapshot taken, vault status clean, file-history mtime captured, LaunchAgents baseline recorded, harness self-check green
- [ ] Install → onboard → `/adopt` → librarian first-fire all exit 0 inside the Lima VM
- [ ] 24-hour simulated observation: zero hook DENYs, zero cron failures, zero data loss
- [ ] Uninstall residue equals zero bytes (`shasum` diff vs pre-install snapshot)
- [ ] Grep-audit on test results returns zero hits across all four layers (raw / NFKC / base64 / git history)
- [ ] Dogfood tarball committed to `dogfood-history/` post-scrub
- [ ] Rollback drill executes cleanly in the deliberate-failure variant

### Step 3 — Verify voice smoke evidence

If the release includes voice / audio onboarding paths, verify the macOS-host voice smoke test passed:

- [ ] A voice-smoke evidence file exists in the foundation repo (path varies by release; conventionally `state/voice-smoke-evidence.md`)
- [ ] Its mtime is later than the start of Step 2's Lima run (verify via `stat`)
- [ ] The evidence file content shows the smoke test passing on a real macOS host

### Step 4 — Burner-key revocation audit

For every burner key ID in `burner-keys.registry`:

```bash
curl -H "Authorization: Bearer $CONSOLE_TOKEN" \
  "https://api.anthropic.com/keys/$OLD_BURNER_ID"
```

- [ ] Every historical burner key returns **410 Gone** OR **403 Unauthorized**
- [ ] No historical burner key returns **200 OK** (key still live = release blocked)

Rotation alone leaves the old key exploitable until it expires; revocation via the Anthropic console API is the only irreversible termination. The `release.yml` workflow does NOT execute this check — it doesn't have `$CONSOLE_TOKEN`. This is a manual pre-flight.

### Step 5 — Cut the rc-tag (maintainer only)

Only when Steps 1–4 are all checked:

```bash
cd ~/Code/claude-stem
git checkout main
git pull --ff-only
git tag -a v2.0.0-rc1 -m "v2.0.0-rc1"
git push origin v2.0.0-rc1
```

This fires `macos-smoke.yml` (rc-tag trigger). Watch the run in the Actions tab. The Sigstore attestation it produces becomes the digest blessing under the rc1 identity. **It is permanent and immutable in Rekor.** Do not push this tag unless you are committing to that digest as the rc1 release candidate.

### Step 6 — After macos-smoke green on the rc-tag, cut the v-tag

```bash
git tag -a v2.0.0 -m "v2.0.0 — see docs/release-notes-v2.0.0.md"
git push origin v2.0.0
```

This fires `release.yml`'s four-stage gate:

1. Locate macos-smoke run for tag SHA
2. Download `macos-smoke-passed.json` artifact
3. `gh attestation verify` (Sigstore signature + workload identity)
4. Field-gate: `smoke_exit == 0`, `foundation_sha == github.sha`, `generated_at < 7d`

Gate exit codes are 60–65. Watch the run; if any stage fails, the tag is rejected pre-publish.

### Step 7 — 30-day GA observation

- [ ] Zero severity-≥-high incidents during the 30-day window
- [ ] Total severity-medium incident count ≤ 2
- [ ] Maintainer is sole classifier — no agent or automation can flip GA status

**Retraction trigger.** Any severity-≥-high incident requires immediate:

```bash
git tag -d v2.0.0-rc1
git push origin :v2.0.0-rc1
# Document in incidents/ with a severity classification
# Ship a new RC after autopsy
```

Tag deletion does NOT retract the workflow run, the smoke logs, or the Sigstore attestation. The attestation persists in Rekor permanently. The retraction removes the ref but not the digest blessing — design downstream verifiers to additionally check ref-existence if that matters for their trust model.

## Hazard notes

- **Sigstore attestation immutability.** The attestation binds to the file's SHA-256 digest, not the tag. Tag retraction is theater for the attestation layer. A `workflow_dispatch` run produces an attestation as permanent as a tag-push run. Plan accordingly: every digest you fire `macos-smoke.yml` against is permanently blessed in Rekor.

- **`GITHUB_TOKEN` recursion gate.** A `push: tags:` workflow does NOT fire from a push made with the in-workflow `${{ secrets.GITHUB_TOKEN }}` (anti-recursion gate). Any other actor — your account, a GitHub App, a PAT — DOES fire it. Plan tag-pushes from your account only; never from automation that uses the workflow-internal token to push tags it expects to trigger downstream.

- **Classification authority.** The maintainer is sole classifier for severity-tier incidents during the 30-day GA window. No agent or automation flips GA status; no part of the release pipeline grants release-cut authority to anything other than the maintainer.

- **Out-of-band prereqs.** Steps 3 (voice-smoke evidence file presence) and 4 (burner-key revocation via console API) cannot be verified by `release.yml` — it has neither filesystem access to the plans tree nor `$CONSOLE_TOKEN`. They are manual pre-flights; this runbook is the audit trail.

## Updates

This runbook is documentation, not a sentinel. Committing it does not trigger anything. Update it whenever a new prereq surfaces from a release-cycle audit; treat it as the authoritative pre-tag-cut checklist.
