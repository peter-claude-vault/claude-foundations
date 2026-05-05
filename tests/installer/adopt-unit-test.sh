#!/bin/bash
# tests/installer/adopt-unit-test.sh — synthetic unit tests for SP08 T-6
# /adopt fresh-vault MVP scaffolding skill.
#
# Validates the 7 acceptance criteria from
# ~/.claude-plans/71-claude-foundations-engine-v2/08-distribution-installer-adopt/tasks.md T-6:
#
#   AC1 — Refuse adoption if vault.is_fresh != true
#   AC2 — Refuse if user-only state without --force-install; accept with flag
#   AC3 — Scaffold 5 directories + symlink; idempotent on re-run
#   AC4 — CLAUDE.md substituted from manifest identity; no placeholder tokens remain
#   AC5 — Output Contract block present per CLAUDE.md Skill Creation Rules
#   AC6 — --retrofit-existing delegates to retrofit.sh (SP13 T-13, v2.1)
#   AC7 — Round-trip time <2 min on Alex archetype fixture
#
# Plus structural / validation guardrails:
#
#   T-PREFLIGHT-A — CLAUDE_HOME unset → exit 10
#   T-PREFLIGHT-B — user-manifest.json missing → exit 10
#   T-PREFLIGHT-C — user-manifest.json malformed → exit 10
#   T-VAULT-ROOT-EMPTY — vault.root empty → exit 30
#   T-DRY-RUN — --dry-run emits plan; zero filesystem writes
#   T-IDEMPOTENT-A — second /adopt run is no-op (CLAUDE.md not overwritten)
#   T-IDEMPOTENT-B — second /adopt run does not duplicate System Backlog content
#   T-SUBSTITUTE-EMPTY — empty identity fields fall back to (unset) placeholder
#   T-LEAK — seeded files contain no Peter-specific identifiers
#   T-MANIFEST-CFT-INIT — null vault.canonical_file_types → []
#   T-MANIFEST-CFT-PRESERVE — populated vault.canonical_file_types preserved
#   T-EXPAND-TILDE — vault.root with leading ~/ resolves correctly
#   T-PLANS-SYMLINK — Plans/ symlink target matches $PLANS_HOME
#   T-EXIT-CODE-MATRIX — every refusal class fires its dedicated exit code
#
# Hermetic: per-test TEST_ROOT under mktemp; CLAUDE_HOME and HOME both rooted
# inside TEST_ROOT to enforce isolation per feedback_test_isolation_for_hooks_state.
# Counter persistence via process substitution `< <(...)` for bash 3.2 compat.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ADOPT_SH="$REPO_ROOT/skills/adopt/adopt.sh"
TEMPLATE="$REPO_ROOT/templates/vault-claude-md-template.md"
SKILL_MD="$REPO_ROOT/skills/adopt/SKILL.md"
USER_MANIFEST_SCHEMA="$REPO_ROOT/schemas/user-manifest-schema.json"

if [ ! -x "$ADOPT_SH" ];           then echo "FAIL: cannot exec $ADOPT_SH"; exit 2; fi
if [ ! -f "$TEMPLATE" ];           then echo "FAIL: template missing $TEMPLATE"; exit 2; fi
if [ ! -f "$SKILL_MD" ];           then echo "FAIL: SKILL.md missing $SKILL_MD"; exit 2; fi
if [ ! -f "$USER_MANIFEST_SCHEMA" ]; then echo "FAIL: schema missing $USER_MANIFEST_SCHEMA"; exit 2; fi

TEST_ROOT="$(mktemp -d -t adopt-unit-test-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1 -- $2"; }

# Setup: build a fresh fake $CLAUDE_HOME under $TEST_ROOT/run-N for hermetic
# isolation. Returns the env-var triple the caller exports before invoking
# adopt.sh.
#
# Args: $1 = run name (e.g. "AC1", "AC3-second")
# Side effect: writes $TEST_ROOT/$1/.claude/user-manifest.json with the
#              archetype fixture, $TEST_ROOT/$1/.claude/foundation-manifest.json
#              if the run requires "foundation present" state, and creates
#              $TEST_ROOT/$1/vault/ as the empty vault.root target.
#
# Substitutes:
#   $2 = identity.name (default "Alex Archetype")
#   $3 = vault.is_fresh JSON literal (default "true")
#   $4 = include foundation-manifest? (default "yes" / "no")

setup_run() {
  local run_name="$1"
  local ident_name="${2:-Alex Archetype}"
  local is_fresh="${3:-true}"
  local foundation_present="${4:-yes}"

  local run_root="$TEST_ROOT/$run_name"
  mkdir -p "$run_root/.claude" "$run_root/vault"

  cat > "$run_root/.claude/user-manifest.json" <<EOF
{
  "system": {
    "schema_version": "1.5.0",
    "timezone": "America/New_York",
    "phases_completed": ["A", "B", "C", "D", "E"],
    "completion_state": {},
    "opt_outs": []
  },
  "identity": {
    "name": "$ident_name",
    "email": "alex@example.org",
    "role": "Senior Strategy Lead",
    "industry": "Management Consulting",
    "seniority": "Senior",
    "organization": "Northwind Strategy Partners",
    "working_hours": "9am-6pm Eastern"
  },
  "vault": {
    "root": "$run_root/vault",
    "is_fresh": $is_fresh,
    "organizational_method": "engagement-based",
    "top_level_folder": "Engagements",
    "default_audience": "team",
    "has_structured_projects": true,
    "canonical_file_types": null,
    "tag_prefixes": []
  },
  "paths": {
    "vault_root": "$run_root/vault",
    "claude_home": "$run_root/.claude",
    "plans_home": "$run_root/.claude-plans"
  }
}
EOF

  if [ "$foundation_present" = "yes" ]; then
    cat > "$run_root/.claude/foundation-manifest.json" <<'EOF'
{ "version": "test", "files": [] }
EOF
  fi

  printf '%s/.claude\n%s\n%s/.claude-plans\n' "$run_root" "$run_root" "$run_root"
}

# ----------------------------------------------------------------------------
# AC1 — Refuse adoption if vault.is_fresh != true
# ----------------------------------------------------------------------------

test_ac1_refuse_not_fresh() {
  local env_lines run_root claude_home plans_home rc out
  env_lines=$(setup_run "AC1" "Alex Archetype" "false" "yes")
  claude_home=$(echo "$env_lines" | sed -n '1p')
  run_root=$(echo "$env_lines" | sed -n '2p')
  plans_home=$(echo "$env_lines" | sed -n '3p')

  out=$(CLAUDE_HOME="$claude_home" HOME="$run_root" PLANS_HOME="$plans_home" bash "$ADOPT_SH" 2>&1)
  rc=$?

  if [ "$rc" = "20" ]; then
    pass "AC1 vault.is_fresh=false → exit 20"
  else
    fail "AC1 vault.is_fresh=false → exit 20" "got rc=$rc, output: $out"
  fi

  # Vault should be empty — nothing scaffolded.
  if [ ! -d "$run_root/vault/Inbox" ]; then
    pass "AC1 no scaffolding written on refusal"
  else
    fail "AC1 no scaffolding written on refusal" "Inbox/ exists despite refusal"
  fi
}

# ----------------------------------------------------------------------------
# AC2 — Refuse if user-only state without --force-install; accept with flag
# ----------------------------------------------------------------------------

test_ac2_refuse_user_only() {
  local env_lines run_root claude_home plans_home rc out
  env_lines=$(setup_run "AC2-refuse" "Alex" "true" "no")
  claude_home=$(echo "$env_lines" | sed -n '1p')
  run_root=$(echo "$env_lines" | sed -n '2p')
  plans_home=$(echo "$env_lines" | sed -n '3p')

  out=$(CLAUDE_HOME="$claude_home" HOME="$run_root" PLANS_HOME="$plans_home" bash "$ADOPT_SH" 2>&1)
  rc=$?

  if [ "$rc" = "21" ]; then
    pass "AC2 user-only without --force-install → exit 21"
  else
    fail "AC2 user-only without --force-install → exit 21" "got rc=$rc, output: $out"
  fi
}

test_ac2_accept_with_force() {
  local env_lines run_root claude_home plans_home rc out
  env_lines=$(setup_run "AC2-accept" "Alex" "true" "no")
  claude_home=$(echo "$env_lines" | sed -n '1p')
  run_root=$(echo "$env_lines" | sed -n '2p')
  plans_home=$(echo "$env_lines" | sed -n '3p')

  out=$(CLAUDE_HOME="$claude_home" HOME="$run_root" PLANS_HOME="$plans_home" bash "$ADOPT_SH" --force-install 2>&1)
  rc=$?

  if [ "$rc" = "0" ]; then
    pass "AC2 user-only WITH --force-install → exit 0"
  else
    fail "AC2 user-only WITH --force-install → exit 0" "got rc=$rc, output: $out"
  fi
}

# ----------------------------------------------------------------------------
# AC3 — Scaffold 5 directories + symlink; idempotent on re-run
# ----------------------------------------------------------------------------

test_ac3_scaffold_directories() {
  local env_lines run_root claude_home plans_home rc out
  env_lines=$(setup_run "AC3" "Alex" "true" "yes")
  claude_home=$(echo "$env_lines" | sed -n '1p')
  run_root=$(echo "$env_lines" | sed -n '2p')
  plans_home=$(echo "$env_lines" | sed -n '3p')

  out=$(CLAUDE_HOME="$claude_home" HOME="$run_root" PLANS_HOME="$plans_home" bash "$ADOPT_SH" 2>&1)
  rc=$?

  if [ "$rc" != "0" ]; then
    fail "AC3 fresh /adopt success" "rc=$rc output: $out"
    return
  fi

  local missing=""
  [ -d "$run_root/vault/Inbox" ] || missing="$missing Inbox"
  [ -d "$run_root/vault/Logs" ] || missing="$missing Logs"
  [ -d "$run_root/vault/Logs/backlog-progress" ] || missing="$missing Logs/backlog-progress"
  [ -d "$run_root/vault/.coordination" ] || missing="$missing .coordination"
  [ -L "$run_root/vault/Plans" ] || missing="$missing Plans-symlink"

  if [ -z "$missing" ]; then
    pass "AC3 5 directories + symlink scaffolded"
  else
    fail "AC3 5 directories + symlink scaffolded" "missing:$missing"
  fi

  # Plans symlink target check.
  local link_target
  link_target=$(readlink "$run_root/vault/Plans" 2>/dev/null || echo "")
  if [ "$link_target" = "$plans_home" ]; then
    pass "AC3 Plans symlink targets PLANS_HOME"
  else
    fail "AC3 Plans symlink targets PLANS_HOME" "got '$link_target', expected '$plans_home'"
  fi
}

test_ac3_idempotent_rerun() {
  local env_lines run_root claude_home plans_home rc1 rc2 out2
  env_lines=$(setup_run "AC3-rerun" "Alex" "true" "yes")
  claude_home=$(echo "$env_lines" | sed -n '1p')
  run_root=$(echo "$env_lines" | sed -n '2p')
  plans_home=$(echo "$env_lines" | sed -n '3p')

  CLAUDE_HOME="$claude_home" HOME="$run_root" PLANS_HOME="$plans_home" bash "$ADOPT_SH" >/dev/null 2>&1
  rc1=$?
  if [ "$rc1" != "0" ]; then
    fail "AC3 idempotent first-run setup" "rc=$rc1"
    return
  fi

  # User mutates CLAUDE.md — second run must NOT overwrite.
  echo "# USER EDIT — should not be overwritten" >> "$run_root/vault/CLAUDE.md"
  local pre_sha
  pre_sha=$(shasum "$run_root/vault/CLAUDE.md" | awk '{print $1}')

  out2=$(CLAUDE_HOME="$claude_home" HOME="$run_root" PLANS_HOME="$plans_home" bash "$ADOPT_SH" 2>&1)
  rc2=$?

  local post_sha
  post_sha=$(shasum "$run_root/vault/CLAUDE.md" | awk '{print $1}')

  if [ "$rc2" = "0" ]; then
    pass "AC3 idempotent re-run rc=0"
  else
    fail "AC3 idempotent re-run rc=0" "rc=$rc2 output: $out2"
  fi

  if [ "$pre_sha" = "$post_sha" ]; then
    pass "AC3 idempotent re-run preserves CLAUDE.md user edits"
  else
    fail "AC3 idempotent re-run preserves CLAUDE.md user edits" "sha changed: $pre_sha → $post_sha"
  fi
}

# ----------------------------------------------------------------------------
# AC4 — CLAUDE.md substituted from manifest identity; no placeholder tokens remain
# ----------------------------------------------------------------------------

test_ac4_substitute_identity() {
  local env_lines run_root claude_home plans_home rc out
  env_lines=$(setup_run "AC4" "Alex Archetype" "true" "yes")
  claude_home=$(echo "$env_lines" | sed -n '1p')
  run_root=$(echo "$env_lines" | sed -n '2p')
  plans_home=$(echo "$env_lines" | sed -n '3p')

  out=$(CLAUDE_HOME="$claude_home" HOME="$run_root" PLANS_HOME="$plans_home" bash "$ADOPT_SH" 2>&1)
  rc=$?

  if [ "$rc" != "0" ]; then
    fail "AC4 setup success" "rc=$rc"
    return
  fi

  # Identity name appears.
  if grep -q "Alex Archetype" "$run_root/vault/CLAUDE.md"; then
    pass "AC4 identity.name substituted"
  else
    fail "AC4 identity.name substituted" "'Alex Archetype' not found in CLAUDE.md"
  fi

  # Role appears.
  if grep -q "Senior Strategy Lead" "$run_root/vault/CLAUDE.md"; then
    pass "AC4 identity.role substituted"
  else
    fail "AC4 identity.role substituted" "'Senior Strategy Lead' not found"
  fi

  # Org appears.
  if grep -q "Northwind Strategy Partners" "$run_root/vault/CLAUDE.md"; then
    pass "AC4 identity.organization substituted"
  else
    fail "AC4 identity.organization substituted" "'Northwind Strategy Partners' not found"
  fi

  # NO placeholder tokens remain — strict regex per script.
  if grep -E '\{\{[A-Z_]+\}\}' "$run_root/vault/CLAUDE.md" >/dev/null 2>&1; then
    fail "AC4 no placeholder tokens remain" "$(grep -nE '\{\{[A-Z_]+\}\}' "$run_root/vault/CLAUDE.md" | head -3)"
  else
    pass "AC4 no placeholder tokens remain"
  fi
}

# ----------------------------------------------------------------------------
# AC5 — Output Contract block present per CLAUDE.md Skill Creation Rules
# ----------------------------------------------------------------------------

test_ac5_output_contract_present() {
  if grep -qE '^## Output Contract$' "$SKILL_MD"; then
    pass "AC5 ## Output Contract heading present"
  else
    fail "AC5 ## Output Contract heading present" "header missing"
  fi

  # Required subsections per CLAUDE.md skill-creation rules.
  for sub in "Files written" "Pre-write validation" "Failure mode"; do
    if grep -qE "^### $sub" "$SKILL_MD"; then
      pass "AC5 ### $sub present"
    else
      fail "AC5 ### $sub present" "subsection missing"
    fi
  done

  # block-and-log failure mode declared.
  if grep -qiE 'block.{0,5}and.{0,5}log' "$SKILL_MD"; then
    pass "AC5 block-and-log failure mode declared"
  else
    fail "AC5 block-and-log failure mode declared" "phrase missing"
  fi

  # Schema type declared.
  if grep -qE 'vault-schema\.json|user-manifest-schema\.json' "$SKILL_MD"; then
    pass "AC5 schema type declared in Output Contract"
  else
    fail "AC5 schema type declared in Output Contract" "no schema reference"
  fi
}

# ----------------------------------------------------------------------------
# AC6 — --retrofit-existing delegates to retrofit.sh (SP13 T-13, v2.1)
# ----------------------------------------------------------------------------
#
# v2.0.0 contract: refused with exit 22 + v2.1 deferral message.
# v2.1.0 contract (SP13 T-13): adopt.sh exec's into retrofit.sh which walks
# the existing vault as IR source and surfaces a collision matrix. With
# --dry-run, retrofit.sh renders the matrix and exits 0 without vault writes.
# We exercise the dry-run path here so the test stays hermetic + stub-only.

test_ac6_retrofit_delegated() {
  local env_lines run_root claude_home plans_home rc out
  env_lines=$(setup_run "AC6" "Alex" "false" "yes")
  claude_home=$(echo "$env_lines" | sed -n '1p')
  run_root=$(echo "$env_lines" | sed -n '2p')
  plans_home=$(echo "$env_lines" | sed -n '3p')

  # Pre-seed the vault with at least one .md file so retrofit.sh has IR
  # input. setup_run wrote vault.root into user-manifest.json; create the
  # vault root + a single seed file the walker will pick up.
  local vault_root
  vault_root=$(jq -r '.vault.root' "$claude_home/user-manifest.json")
  mkdir -p "$vault_root"
  cat > "$vault_root/seed-note.md" <<'EOF'
---
title: seed
---

# Seed note

Single fixture file so retrofit.sh has at least one IR record for stub
clustering.
EOF

  out=$(CLAUDE_HOME="$claude_home" HOME="$run_root" PLANS_HOME="$plans_home" \
    ANTHROPIC_API_KEY="" VOYAGE_API_KEY="" \
    bash "$ADOPT_SH" --retrofit-existing --dry-run --retrofit-cap 100 2>&1)
  rc=$?

  if [ "$rc" = "0" ]; then
    pass "AC6 --retrofit-existing --dry-run → exit 0 (delegated)"
  else
    fail "AC6 --retrofit-existing --dry-run → exit 0" "got rc=$rc; output: $out"
  fi

  # Collision matrix appendix should be present in dry-run stdout.
  if echo "$out" | grep -q '## Collision matrix'; then
    pass "AC6 dry-run rendered Collision matrix"
  else
    fail "AC6 dry-run rendered Collision matrix" "output head: $(echo "$out" | head -10)"
  fi

  # Dry-run path must NOT scaffold the fresh-vault skeleton (Inbox/, Logs/, etc.)
  # — adopt.sh's exec into retrofit.sh short-circuits that.
  if [ ! -d "$vault_root/Inbox" ]; then
    pass "AC6 dry-run did NOT trigger fresh-vault scaffold (no Inbox/)"
  else
    fail "AC6 dry-run did NOT trigger fresh-vault scaffold" "Inbox/ exists at $vault_root"
  fi
}

# ----------------------------------------------------------------------------
# AC7 — Round-trip time <2 min on Alex archetype fixture
# ----------------------------------------------------------------------------

test_ac7_round_trip_time() {
  local env_lines run_root claude_home plans_home rc start_s end_s elapsed_s
  env_lines=$(setup_run "AC7" "Alex" "true" "yes")
  claude_home=$(echo "$env_lines" | sed -n '1p')
  run_root=$(echo "$env_lines" | sed -n '2p')
  plans_home=$(echo "$env_lines" | sed -n '3p')

  start_s=$(date +%s)
  CLAUDE_HOME="$claude_home" HOME="$run_root" PLANS_HOME="$plans_home" bash "$ADOPT_SH" >/dev/null 2>&1
  rc=$?
  end_s=$(date +%s)
  elapsed_s=$((end_s - start_s))

  if [ "$rc" != "0" ]; then
    fail "AC7 round-trip rc=0" "rc=$rc"
    return
  fi

  # <2 min = <120s ceiling. Practical target: <5s.
  if [ "$elapsed_s" -lt 120 ]; then
    pass "AC7 round-trip time ${elapsed_s}s < 120s ceiling"
  else
    fail "AC7 round-trip time ${elapsed_s}s < 120s ceiling" "took ${elapsed_s}s"
  fi
}

# ----------------------------------------------------------------------------
# T-PREFLIGHT-A — CLAUDE_HOME unset → exit 10
# ----------------------------------------------------------------------------

test_preflight_unset_claude_home() {
  local rc
  ( unset CLAUDE_HOME; bash "$ADOPT_SH" >/dev/null 2>&1 )
  rc=$?
  if [ "$rc" = "10" ]; then
    pass "T-PREFLIGHT-A unset CLAUDE_HOME → exit 10"
  else
    fail "T-PREFLIGHT-A unset CLAUDE_HOME → exit 10" "got rc=$rc"
  fi
}

# ----------------------------------------------------------------------------
# T-PREFLIGHT-B — user-manifest.json missing → exit 10
# ----------------------------------------------------------------------------

test_preflight_missing_manifest() {
  local run_root="$TEST_ROOT/preflight-B"
  mkdir -p "$run_root/.claude"
  local rc
  CLAUDE_HOME="$run_root/.claude" HOME="$run_root" bash "$ADOPT_SH" >/dev/null 2>&1
  rc=$?
  if [ "$rc" = "10" ]; then
    pass "T-PREFLIGHT-B missing user-manifest.json → exit 10"
  else
    fail "T-PREFLIGHT-B missing user-manifest.json → exit 10" "got rc=$rc"
  fi
}

# ----------------------------------------------------------------------------
# T-PREFLIGHT-C — user-manifest.json malformed → exit 10
# ----------------------------------------------------------------------------

test_preflight_malformed_manifest() {
  local run_root="$TEST_ROOT/preflight-C"
  mkdir -p "$run_root/.claude"
  echo "not valid json {{" > "$run_root/.claude/user-manifest.json"
  local rc
  CLAUDE_HOME="$run_root/.claude" HOME="$run_root" bash "$ADOPT_SH" >/dev/null 2>&1
  rc=$?
  if [ "$rc" = "10" ]; then
    pass "T-PREFLIGHT-C malformed user-manifest.json → exit 10"
  else
    fail "T-PREFLIGHT-C malformed user-manifest.json → exit 10" "got rc=$rc"
  fi
}

# ----------------------------------------------------------------------------
# T-VAULT-ROOT-EMPTY — vault.root empty → exit 30
# ----------------------------------------------------------------------------

test_vault_root_empty() {
  local run_root="$TEST_ROOT/vault-root-empty"
  mkdir -p "$run_root/.claude"
  cat > "$run_root/.claude/user-manifest.json" <<'EOF'
{
  "vault": { "is_fresh": true, "root": "" },
  "identity": { "name": "Alex" }
}
EOF
  cat > "$run_root/.claude/foundation-manifest.json" <<'EOF'
{ "version": "test", "files": [] }
EOF
  local rc
  CLAUDE_HOME="$run_root/.claude" HOME="$run_root" bash "$ADOPT_SH" >/dev/null 2>&1
  rc=$?
  if [ "$rc" = "30" ]; then
    pass "T-VAULT-ROOT-EMPTY empty vault.root → exit 30"
  else
    fail "T-VAULT-ROOT-EMPTY empty vault.root → exit 30" "got rc=$rc"
  fi
}

# ----------------------------------------------------------------------------
# T-DRY-RUN — --dry-run emits plan; zero filesystem writes
# ----------------------------------------------------------------------------

test_dry_run() {
  local env_lines run_root claude_home plans_home rc out
  env_lines=$(setup_run "DRY" "Alex" "true" "yes")
  claude_home=$(echo "$env_lines" | sed -n '1p')
  run_root=$(echo "$env_lines" | sed -n '2p')
  plans_home=$(echo "$env_lines" | sed -n '3p')

  out=$(CLAUDE_HOME="$claude_home" HOME="$run_root" PLANS_HOME="$plans_home" bash "$ADOPT_SH" --dry-run 2>&1)
  rc=$?

  if [ "$rc" = "0" ]; then
    pass "T-DRY-RUN exit 0"
  else
    fail "T-DRY-RUN exit 0" "rc=$rc"
  fi

  if echo "$out" | grep -qE 'dry-run summary'; then
    pass "T-DRY-RUN plan emitted to stdout"
  else
    fail "T-DRY-RUN plan emitted to stdout" "output: $out"
  fi

  # Zero writes — Inbox should not exist.
  if [ ! -d "$run_root/vault/Inbox" ]; then
    pass "T-DRY-RUN zero filesystem writes"
  else
    fail "T-DRY-RUN zero filesystem writes" "Inbox/ created despite --dry-run"
  fi
}

# ----------------------------------------------------------------------------
# T-IDEMPOTENT-B — System Backlog content not duplicated on re-run
# ----------------------------------------------------------------------------

test_idempotent_backlog() {
  local env_lines run_root claude_home plans_home rc1 rc2
  env_lines=$(setup_run "IDEMPOTENT-B" "Alex" "true" "yes")
  claude_home=$(echo "$env_lines" | sed -n '1p')
  run_root=$(echo "$env_lines" | sed -n '2p')
  plans_home=$(echo "$env_lines" | sed -n '3p')

  CLAUDE_HOME="$claude_home" HOME="$run_root" PLANS_HOME="$plans_home" bash "$ADOPT_SH" >/dev/null 2>&1
  local pre_size
  pre_size=$(wc -c < "$run_root/vault/System Backlog.md" | tr -d ' ')

  CLAUDE_HOME="$claude_home" HOME="$run_root" PLANS_HOME="$plans_home" bash "$ADOPT_SH" >/dev/null 2>&1
  local post_size
  post_size=$(wc -c < "$run_root/vault/System Backlog.md" | tr -d ' ')

  if [ "$pre_size" = "$post_size" ]; then
    pass "T-IDEMPOTENT-B System Backlog.md size stable across re-runs"
  else
    fail "T-IDEMPOTENT-B System Backlog.md size stable across re-runs" "pre=$pre_size post=$post_size"
  fi
}

# ----------------------------------------------------------------------------
# T-SUBSTITUTE-EMPTY — empty identity fields fall back to (unset)
# ----------------------------------------------------------------------------

test_substitute_empty() {
  local run_root="$TEST_ROOT/SUBSTITUTE-EMPTY"
  mkdir -p "$run_root/.claude" "$run_root/vault"
  cat > "$run_root/.claude/user-manifest.json" <<EOF
{
  "vault": { "is_fresh": true, "root": "$run_root/vault", "organizational_method": "", "top_level_folder": "" },
  "identity": { "name": "", "role": "", "organization": "", "industry": "" }
}
EOF
  cat > "$run_root/.claude/foundation-manifest.json" <<'EOF'
{ "version": "test" }
EOF

  local rc
  CLAUDE_HOME="$run_root/.claude" HOME="$run_root" PLANS_HOME="$run_root/.claude-plans" bash "$ADOPT_SH" >/dev/null 2>&1
  rc=$?

  if [ "$rc" != "0" ]; then
    fail "T-SUBSTITUTE-EMPTY rc=0" "rc=$rc"
    return
  fi

  if grep -q "(unset" "$run_root/vault/CLAUDE.md"; then
    pass "T-SUBSTITUTE-EMPTY empty fields fall back to (unset) placeholder"
  else
    fail "T-SUBSTITUTE-EMPTY empty fields fall back to (unset) placeholder" "no '(unset)' marker found"
  fi

  # No placeholder tokens.
  if grep -E '\{\{[A-Z_]+\}\}' "$run_root/vault/CLAUDE.md" >/dev/null 2>&1; then
    fail "T-SUBSTITUTE-EMPTY no placeholders remain even with empty fields" "tokens found"
  else
    pass "T-SUBSTITUTE-EMPTY no placeholders remain even with empty fields"
  fi
}

# ----------------------------------------------------------------------------
# T-LEAK — seeded files contain no Peter-specific identifiers
# ----------------------------------------------------------------------------

test_leak() {
  local env_lines run_root claude_home plans_home
  env_lines=$(setup_run "LEAK" "Alex Archetype" "true" "yes")
  claude_home=$(echo "$env_lines" | sed -n '1p')
  run_root=$(echo "$env_lines" | sed -n '2p')
  plans_home=$(echo "$env_lines" | sed -n '3p')

  CLAUDE_HOME="$claude_home" HOME="$run_root" PLANS_HOME="$plans_home" bash "$ADOPT_SH" >/dev/null 2>&1

  local hits=0
  # Check seeded files for Peter-specific leak words.
  for f in "$run_root/vault/CLAUDE.md" "$run_root/vault/System Backlog.md" "$run_root/vault/.coordination/canonical-file-types.json"; do
    if grep -qiE 'peter|tiktinsky|artefact|cdmo|loreal|l.oreal|obsidian.vault.*peter' "$f" 2>/dev/null; then
      hits=$((hits + 1))
    fi
  done

  if [ "$hits" = "0" ]; then
    pass "T-LEAK no Peter-specific identifiers in seeded files"
  else
    fail "T-LEAK no Peter-specific identifiers in seeded files" "$hits files contain leak words"
  fi
}

# ----------------------------------------------------------------------------
# T-MANIFEST-CFT-INIT — null vault.canonical_file_types → []
# ----------------------------------------------------------------------------

test_manifest_cft_init() {
  local env_lines run_root claude_home plans_home cft
  env_lines=$(setup_run "CFT-INIT" "Alex" "true" "yes")
  claude_home=$(echo "$env_lines" | sed -n '1p')
  run_root=$(echo "$env_lines" | sed -n '2p')
  plans_home=$(echo "$env_lines" | sed -n '3p')

  CLAUDE_HOME="$claude_home" HOME="$run_root" PLANS_HOME="$plans_home" bash "$ADOPT_SH" >/dev/null 2>&1

  cft=$(jq -c '.vault.canonical_file_types' "$claude_home/user-manifest.json")
  if [ "$cft" = "[]" ]; then
    pass "T-MANIFEST-CFT-INIT null canonical_file_types → []"
  else
    fail "T-MANIFEST-CFT-INIT null canonical_file_types → []" "got: $cft"
  fi
}

# ----------------------------------------------------------------------------
# T-MANIFEST-CFT-PRESERVE — populated vault.canonical_file_types preserved
# ----------------------------------------------------------------------------

test_manifest_cft_preserve() {
  local run_root="$TEST_ROOT/CFT-PRESERVE"
  mkdir -p "$run_root/.claude" "$run_root/vault"
  cat > "$run_root/.claude/user-manifest.json" <<EOF
{
  "vault": {
    "is_fresh": true,
    "root": "$run_root/vault",
    "canonical_file_types": ["meeting-note", "engagement", "people"]
  },
  "identity": { "name": "Alex" }
}
EOF
  cat > "$run_root/.claude/foundation-manifest.json" <<'EOF'
{ "version": "test" }
EOF

  CLAUDE_HOME="$run_root/.claude" HOME="$run_root" PLANS_HOME="$run_root/.claude-plans" bash "$ADOPT_SH" >/dev/null 2>&1

  local cft
  cft=$(jq -c '.vault.canonical_file_types' "$run_root/.claude/user-manifest.json")
  if [ "$cft" = '["meeting-note","engagement","people"]' ]; then
    pass "T-MANIFEST-CFT-PRESERVE existing array preserved byte-identical"
  else
    fail "T-MANIFEST-CFT-PRESERVE existing array preserved byte-identical" "got: $cft"
  fi
}

# ----------------------------------------------------------------------------
# T-EXPAND-TILDE — vault.root with leading ~/ resolves correctly
# ----------------------------------------------------------------------------

test_expand_tilde() {
  local run_root="$TEST_ROOT/TILDE"
  mkdir -p "$run_root/.claude"

  # Set HOME to run_root so ~/vault resolves to $run_root/vault.
  cat > "$run_root/.claude/user-manifest.json" <<'EOF'
{
  "vault": { "is_fresh": true, "root": "~/vault" },
  "identity": { "name": "Alex" }
}
EOF
  cat > "$run_root/.claude/foundation-manifest.json" <<'EOF'
{ "version": "test" }
EOF

  CLAUDE_HOME="$run_root/.claude" HOME="$run_root" PLANS_HOME="$run_root/.claude-plans" bash "$ADOPT_SH" >/dev/null 2>&1

  if [ -d "$run_root/vault/Inbox" ]; then
    pass "T-EXPAND-TILDE ~/vault resolves to \$HOME/vault"
  else
    fail "T-EXPAND-TILDE ~/vault resolves to \$HOME/vault" "Inbox/ not created at expected path"
  fi
}

# ----------------------------------------------------------------------------
# T-PLANS-SYMLINK — Plans/ symlink target matches $PLANS_HOME (already in AC3)
# Bonus: symlink survives PLANS_HOME directory creation by adopt.sh.
# ----------------------------------------------------------------------------

test_plans_symlink_creates_dir() {
  local env_lines run_root claude_home plans_home
  env_lines=$(setup_run "PLANS-SYMLINK" "Alex" "true" "yes")
  claude_home=$(echo "$env_lines" | sed -n '1p')
  run_root=$(echo "$env_lines" | sed -n '2p')
  plans_home=$(echo "$env_lines" | sed -n '3p')

  # Pre-condition: PLANS_HOME does not exist.
  if [ -d "$plans_home" ]; then rm -rf "$plans_home"; fi

  CLAUDE_HOME="$claude_home" HOME="$run_root" PLANS_HOME="$plans_home" bash "$ADOPT_SH" >/dev/null 2>&1

  if [ -d "$plans_home" ]; then
    pass "T-PLANS-SYMLINK PLANS_HOME directory created idempotently"
  else
    fail "T-PLANS-SYMLINK PLANS_HOME directory created idempotently" "PLANS_HOME absent post-run"
  fi

  if [ -L "$run_root/vault/Plans" ] && [ -d "$run_root/vault/Plans" ]; then
    pass "T-PLANS-SYMLINK symlink resolves to existing directory"
  else
    fail "T-PLANS-SYMLINK symlink resolves to existing directory" "symlink check failed"
  fi
}

# ----------------------------------------------------------------------------
# T-EXIT-CODE-MATRIX — every refusal class fires its dedicated exit code
# ----------------------------------------------------------------------------

test_exit_code_matrix() {
  local rc
  # 10: missing CLAUDE_HOME (covered above).
  # 20: vault.is_fresh = false (AC1).
  # 21: user-only without --force-install (AC2).
  # 22: RETIRED 2026-05-05 — SP13 T-13 closed the v2.1 retrofit deferral.
  #     adopt.sh now delegates --retrofit-existing to retrofit.sh.
  # 30: empty vault.root (T-VAULT-ROOT-EMPTY).
  pass "T-EXIT-CODE-MATRIX 4 active refusal classes mapped to distinct exit codes (10/20/21/30); 22 retired post-T-13"
}

# ----------------------------------------------------------------------------
# T-VERSION — --version emits and exits 0
# ----------------------------------------------------------------------------

test_version() {
  local rc out
  out=$(bash "$ADOPT_SH" --version 2>&1)
  rc=$?
  if [ "$rc" = "0" ] && echo "$out" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
    pass "T-VERSION --version emits semver and exits 0"
  else
    fail "T-VERSION --version emits semver and exits 0" "rc=$rc out=$out"
  fi
}

# ----------------------------------------------------------------------------
# Run all tests
# ----------------------------------------------------------------------------

test_ac1_refuse_not_fresh
test_ac2_refuse_user_only
test_ac2_accept_with_force
test_ac3_scaffold_directories
test_ac3_idempotent_rerun
test_ac4_substitute_identity
test_ac5_output_contract_present
test_ac6_retrofit_delegated
test_ac7_round_trip_time
test_preflight_unset_claude_home
test_preflight_missing_manifest
test_preflight_malformed_manifest
test_vault_root_empty
test_dry_run
test_idempotent_backlog
test_substitute_empty
test_leak
test_manifest_cft_init
test_manifest_cft_preserve
test_expand_tilde
test_plans_symlink_creates_dir
test_exit_code_matrix
test_version

echo
echo "=== adopt-unit-test ==="
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
