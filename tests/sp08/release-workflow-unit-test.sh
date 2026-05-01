#!/bin/bash
# tests/sp08/release-workflow-unit-test.sh — Plan 71 SP08 T-5 L3 (S72)
#
# Hermetic shape-tests for the L3 signing flow:
#   T1 (3) — release.yml exists + parseable + correct top-level shape
#   T2 (4) — release.yml trigger pattern (v* in, v*-rc* out, no other
#            triggers, single-job verify-attestation only)
#   T3 (4) — release.yml permissions match Sigstore-verify needs
#            (contents/attestations/actions read; NO id-token write)
#   T4 (5) — release.yml steps exercise the four-stage gate (locate run /
#            download artifact / verify attestation / field-gate jq parse /
#            release-eligible signal)
#   T5 (5) — macos-smoke.yml has L3 signing additions (id-token write +
#            attestations write + attest-build-provenance step + correct
#            subject-path + if: success() guard)
#
# Total: 21 asserts. Bash 3.2 clean (R-23). Hermetic — uses only grep/sed/
# awk on the workflow YAML; no network, no actual GHA invocation.
#
# Plan 71 R-55 — these tests target foundation-repo, NOT live ~/.claude/.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_YML="$REPO_ROOT/.github/workflows/release.yml"
MACOS_SMOKE_YML="$REPO_ROOT/.github/workflows/macos-smoke.yml"

PASS=0
FAIL=0
FAILED_ASSERTS=""

assert() {
  local label="$1"
  local condition_rc="$2"
  if [ "$condition_rc" = "0" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_ASSERTS="$FAILED_ASSERTS\n  - $label"
    printf 'FAIL: %s\n' "$label" >&2
  fi
}

# Helper: assert a literal substring is present in a file
grep_lit() {
  local file="$1" pat="$2"
  grep -F -q -- "$pat" "$file"
}

# Helper: assert a regex matches in a file
grep_re() {
  local file="$1" pat="$2"
  grep -E -q -- "$pat" "$file"
}

printf '=== release-workflow-unit-test ===\n'

# ---- T1: release.yml exists + parseable + correct top-level shape -------
[ -f "$RELEASE_YML" ]; assert 'T1.1 release.yml exists at .github/workflows/release.yml' $?
grep_re "$RELEASE_YML" '^name:[[:space:]]+release$'; assert 'T1.2 release.yml has top-level name: release' $?
grep_re "$RELEASE_YML" '^jobs:'; assert 'T1.3 release.yml has jobs: section' $?

# ---- T2: trigger pattern correct (v* in, v*-rc* out, no other triggers) -
# Extract everything between 'on:' and 'permissions:'
TRIG_BLOCK=$(awk '/^on:/{flag=1; next} /^permissions:/{flag=0} flag' "$RELEASE_YML")

printf '%s\n' "$TRIG_BLOCK" | grep -F -q "'v*'"; \
  assert "T2.1 release.yml triggers on 'v*' tag pattern" $?
printf '%s\n' "$TRIG_BLOCK" | grep -F -q "'!v*-rc*'"; \
  assert "T2.2 release.yml excludes '!v*-rc*' (rc tags fire macos-smoke)" $?
printf '%s\n' "$TRIG_BLOCK" | grep -E -q '^[[:space:]]+branches:'; \
  TRIG_HAS_BRANCHES=$?
[ "$TRIG_HAS_BRANCHES" != "0" ]; \
  assert 'T2.3 release.yml has NO push: branches: trigger (tags-only)' $?
printf '%s\n' "$TRIG_BLOCK" | grep -E -q '^[[:space:]]*workflow_dispatch:'; \
  TRIG_HAS_DISPATCH=$?
[ "$TRIG_HAS_DISPATCH" != "0" ]; \
  assert 'T2.4 release.yml has NO workflow_dispatch (auto-fire only on tag push)' $?

# ---- T3: permissions match Sigstore-verify needs ------------------------
# Extract permissions block: from 'permissions:' to next top-level key
PERM_BLOCK=$(awk '/^permissions:/{flag=1; next} /^[a-z]+:/{flag=0} flag' "$RELEASE_YML")

printf '%s\n' "$PERM_BLOCK" | grep -E -q '^[[:space:]]+contents:[[:space:]]+read'; \
  assert 'T3.1 release.yml permissions: contents: read' $?
printf '%s\n' "$PERM_BLOCK" | grep -E -q '^[[:space:]]+attestations:[[:space:]]+read'; \
  assert 'T3.2 release.yml permissions: attestations: read (gh attestation verify)' $?
printf '%s\n' "$PERM_BLOCK" | grep -E -q '^[[:space:]]+actions:[[:space:]]+read'; \
  assert 'T3.3 release.yml permissions: actions: read (gh run download)' $?

# release.yml VERIFIES — it must NOT have id-token: write (that's macos-smoke's job)
printf '%s\n' "$PERM_BLOCK" | grep -E -q 'id-token:[[:space:]]+write'; \
  HAS_OIDC_WRITE=$?
[ "$HAS_OIDC_WRITE" != "0" ]; \
  assert 'T3.4 release.yml has NO id-token: write (verifier-only, not signer)' $?

# ---- T4: workflow steps exercise the four-stage gate --------------------
grep_lit "$RELEASE_YML" 'gh run list'; \
  assert 'T4.1 release.yml has gh run list step (locate macos-smoke run by SHA)' $?
grep_lit "$RELEASE_YML" 'gh run download'; \
  assert 'T4.2 release.yml has gh run download step (artifact retrieval)' $?
grep_lit "$RELEASE_YML" 'gh attestation verify'; \
  assert 'T4.3 release.yml has gh attestation verify step (Sigstore signature check)' $?
grep_lit "$RELEASE_YML" 'jq -r'; \
  assert 'T4.4 release.yml has jq -r field extraction (field-gate parse)' $?
# Field-gate must check all three required fields
grep_lit "$RELEASE_YML" '.smoke_exit' && \
  grep_lit "$RELEASE_YML" '.foundation_sha' && \
  grep_lit "$RELEASE_YML" '.generated_at'; \
  assert 'T4.5 release.yml field-gate covers smoke_exit + foundation_sha + generated_at' $?

# ---- T5: macos-smoke.yml has L3 signing additions -----------------------
[ -f "$MACOS_SMOKE_YML" ]; SMOKE_EXISTS=$?
if [ "$SMOKE_EXISTS" != "0" ]; then
  FAIL=$((FAIL + 5))
  FAILED_ASSERTS="$FAILED_ASSERTS\n  - T5.* macos-smoke.yml missing — cannot verify L3 additions"
  printf 'FAIL: macos-smoke.yml missing — skipping T5 assertions\n' >&2
else
  # Extract permissions block from macos-smoke.yml
  SMOKE_PERM=$(awk '/^permissions:/{flag=1; next} /^[a-z]+:/{flag=0} flag' "$MACOS_SMOKE_YML")

  printf '%s\n' "$SMOKE_PERM" | grep -E -q '^[[:space:]]+id-token:[[:space:]]+write'; \
    assert 'T5.1 macos-smoke.yml permissions: id-token: write (OIDC for Sigstore)' $?
  printf '%s\n' "$SMOKE_PERM" | grep -E -q '^[[:space:]]+attestations:[[:space:]]+write'; \
    assert 'T5.2 macos-smoke.yml permissions: attestations: write (registry post)' $?
  grep_lit "$MACOS_SMOKE_YML" 'actions/attest-build-provenance@v2'; \
    assert 'T5.3 macos-smoke.yml uses actions/attest-build-provenance@v2' $?
  # subject-path must reference the JSON in $RUNNER_TEMP/smoke-out
  grep_re "$MACOS_SMOKE_YML" 'subject-path:[[:space:]]*\$\{\{[[:space:]]*runner\.temp[[:space:]]*\}\}/smoke-out/macos-smoke-passed\.json'; \
    assert 'T5.4 macos-smoke.yml attestation subject-path points at smoke-out/macos-smoke-passed.json' $?
  # The signing step must be guarded by if: success() so failure paths
  # do NOT produce an attestation (otherwise release.yml would accept
  # signatures over failed runs)
  awk '
    /Sign macos-smoke-passed\.json via Sigstore/ {found=1}
    found && /^[[:space:]]+if:[[:space:]]+success\(\)/ {hit=1; exit}
    found && /uses:[[:space:]]+actions\/attest-build-provenance/ {exit}
    END {exit (hit ? 0 : 1)}
  ' "$MACOS_SMOKE_YML"; \
    assert 'T5.5 macos-smoke.yml signing step is guarded by if: success() (no sig over failed run)' $?
fi

# ---- Summary ------------------------------------------------------------
printf '\n== Summary ==\n'
printf 'pass=%d fail=%d total=%d\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
if [ "$FAIL" != "0" ]; then
  printf 'RESULT: red\n'
  printf 'Failed assertions:%b\n' "$FAILED_ASSERTS" >&2
  exit 1
fi
printf 'RESULT: green\n'
exit 0
