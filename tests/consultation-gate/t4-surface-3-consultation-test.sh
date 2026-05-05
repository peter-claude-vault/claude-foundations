#!/usr/bin/env bash
# tests/consultation-gate/t4-surface-3-consultation-test.sh — SP15 T-4 acceptance
#
# Synthetic fixture test verifying SP15 T-4 (Surface-3 vault-CLAUDE.md
# consultation retrofit) acceptance criteria. Hermetic tmpdir per
# `feedback_test_isolation_for_hooks_state`; parallel test vault per
# `feedback_universal_vault_safety` (NEVER touches ~/Documents/Obsidian
# Vault production).
#
# Acceptance criteria covered:
#   AC1 — Audit log shows `consult` action ordered before `generate`
#         for surface-3-vault-claude-md.
#   AC2 — Rationale emits ≥3 PKM/IA citations
#         (Forte / Ahrens / Cowan / Matrixflows).
#   AC3 — 3 archetype fixtures (consultant / researcher / custom) each
#         produce surface-appropriate rationale with no archetype
#         crosstalk.
#   AC4 — User-reject → zero vault file write + audit reject record.
#   AC5 — User-accept → existing 3-step gate fires + surface-3 produces
#         vault CLAUDE.md as before (RDT + Tag Taxonomy + Pre-Write
#         Checklist all present).
#   AC6 — Provenance frontmatter on output carries `consulted_at` +
#         `consultation_response_hash` (T-3 contract).
#   AC7 — R-23 bash 3.2.57 lint clean on the modified scripts.
#
# CONSTRAINTS (R-23): bash 3.2.57; jq required.
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP15 Session 4 (T-4)

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SURFACE="$REPO_ROOT/onboarding/auto-author/surface-3-vault-claude-md.sh"
TEMPLATE="$REPO_ROOT/templates/vault-claude-md-template.md"

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS — %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL — %s\n' "$1" >&2; }

# --- AC7: R-23 lint pass (cheap; runs first so a syntax break aborts early) ---

for f in \
  "$REPO_ROOT/lib/consultation-gate.sh" \
  "$REPO_ROOT/onboarding/auto-author/surface-3-vault-claude-md.sh"; do
  if /bin/bash -n "$f" >/dev/null 2>&1 && bash --posix -n "$f" >/dev/null 2>&1; then
    pass "AC7 R-23 lint clean: $(basename "$f")"
  else
    fail "AC7 R-23 lint FAILED: $f"
    /bin/bash -n "$f" 2>&1 | head -5 >&2
    bash --posix -n "$f" 2>&1 | head -5 >&2
    exit 1
  fi
done

# --- Hermetic test sandbox ---
# CLAUDE_HOME under tmpdir per feedback_test_isolation_for_hooks_state.
# Test vault under tmpdir per feedback_universal_vault_safety. Audit log,
# stage dir, allowlist all isolated.

T4_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/consultation-surface-3-$$.XXXXXX")"
trap 'rm -rf "$T4_TEST_DIR" 2>/dev/null' EXIT INT TERM

export CLAUDE_HOME="$T4_TEST_DIR/claude"
export HOOKS_STATE_OVERRIDE="$CLAUDE_HOME/state"
export AUTO_AUTHOR_LOG="$T4_TEST_DIR/audit.jsonl"
export TG_STAGE_DIR="$T4_TEST_DIR/stage"
export EDITOR=":"
mkdir -p "$CLAUDE_HOME" "$HOOKS_STATE_OVERRIDE" "$TG_STAGE_DIR" \
  "$T4_TEST_DIR/vault-consultant" \
  "$T4_TEST_DIR/vault-researcher" \
  "$T4_TEST_DIR/vault-custom"

# Production allowlist contains surface-3-vault-claude-md so we don't
# need to override CG_ALLOWLIST_PATH; defaults will resolve fine.

# --- Manifest fixtures (one per archetype) ---

write_manifest_consultant() {
  cat > "$1" <<'JSON'
{
  "identity": {
    "name": "Maya Chen",
    "role": "Senior Engagement Manager",
    "industry": "Strategy Consulting",
    "organization": "Aria Strategy Group"
  },
  "vault": {
    "root": "VAULT_ROOT_PLACEHOLDER",
    "organizational_method": "engagement-based",
    "top_level_folder": "Engagements",
    "default_audience": "claude",
    "tag_prefixes": ["engagement/", "client/", "deliverable/"],
    "canonical_file_types": ["meeting-note", "deliverable", "engagement"]
  },
  "paths": {
    "vault_root": "VAULT_ROOT_PLACEHOLDER"
  }
}
JSON
}

write_manifest_researcher() {
  cat > "$1" <<'JSON'
{
  "identity": {
    "name": "Avery Park",
    "role": "Independent Essayist",
    "industry": "Long-form Writing",
    "organization": "(self)"
  },
  "vault": {
    "root": "VAULT_ROOT_PLACEHOLDER",
    "organizational_method": "topic-based",
    "top_level_folder": "Topics",
    "default_audience": "claude",
    "tag_prefixes": ["topic/", "essay/", "source/"],
    "canonical_file_types": ["essay-draft", "source-note", "topic"]
  },
  "paths": {
    "vault_root": "VAULT_ROOT_PLACEHOLDER"
  }
}
JSON
}

write_manifest_custom() {
  cat > "$1" <<'JSON'
{
  "identity": {
    "name": "Jordan Reyes",
    "role": "Field Botanist",
    "industry": "Conservation Research",
    "organization": "Pacific Botanical Survey"
  },
  "vault": {
    "root": "VAULT_ROOT_PLACEHOLDER",
    "organizational_method": "site-survey-keyed",
    "top_level_folder": "Sites",
    "default_audience": "claude",
    "tag_prefixes": ["site/", "species/", "survey/"],
    "canonical_file_types": ["site-record", "survey-log"]
  },
  "paths": {
    "vault_root": "VAULT_ROOT_PLACEHOLDER"
  }
}
JSON
}

substitute_vault_root() {
  # $1=manifest_path $2=vault_root_value
  local m="$1" vr="$2"
  python3 - "$m" "$vr" <<'PY'
import sys, json
m, vr = sys.argv[1], sys.argv[2]
with open(m) as fh:
    data = json.load(fh)
data["vault"]["root"] = vr
data["paths"]["vault_root"] = vr
with open(m, 'w') as fh:
    json.dump(data, fh, indent=2)
PY
}

# --- Per-archetype accept-path test driver ---

run_accept_archetype() {
  # $1=archetype_label $2=manifest_writer_fn $3=vault_dir
  local label="$1" writer="$2" vault="$3"
  local manifest="$T4_TEST_DIR/manifest-${label}.json"
  local target="$vault/CLAUDE.md"
  local stderr_capture="$T4_TEST_DIR/stderr-${label}.log"

  "$writer" "$manifest"
  substitute_vault_root "$manifest" "$vault"

  # Reset audit log per-archetype so AC1 ordering check is unambiguous.
  : > "$AUTO_AUTHOR_LOG"

  bash "$SURFACE" \
    --target "$target" \
    --user-manifest "$manifest" \
    --template "$TEMPLATE" \
    --auto-apply \
    > "$stderr_capture.stdout" 2> "$stderr_capture" \
    || {
      fail "[$label] surface-3 invocation rc=$? — see $stderr_capture"
      return 1
    }

  # AC5: target written + RDT + Tag Taxonomy + Pre-Write Checklist present.
  if [ ! -f "$target" ]; then
    fail "[$label] AC5 target file not written: $target"
    return 1
  fi
  local rdt_ok=0 tag_ok=0 pwc_ok=0
  grep -q '^## Routing Decision Tree' "$target" && rdt_ok=1
  grep -q '^## Tag Taxonomy' "$target" && tag_ok=1
  grep -q '^## Pre-Write Checklist' "$target" && pwc_ok=1
  if [ "$rdt_ok$tag_ok$pwc_ok" = "111" ]; then
    pass "[$label] AC5 — target written with RDT + TagTaxonomy + PreWriteChecklist"
  else
    fail "[$label] AC5 — sections missing (RDT=$rdt_ok TagTax=$tag_ok PreWrite=$pwc_ok)"
  fi

  # AC6: provenance frontmatter carries consulted_at + consultation_response_hash.
  local fm
  fm="$(awk 'BEGIN{s=0} /^---[[:space:]]*$/{s++; if(s==2)exit; next} s==1{print}' "$target")"
  if printf '%s\n' "$fm" | grep -Eq '^consulted_at: "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"$'; then
    pass "[$label] AC6 — consulted_at present + ISO-8601 UTC formatted"
  else
    fail "[$label] AC6 — consulted_at missing/malformed: $(printf '%s\n' "$fm" | grep -i consulted || echo '(no match)')"
  fi
  if printf '%s\n' "$fm" | grep -Eq '^consultation_response_hash: [a-f0-9]{64}$'; then
    pass "[$label] AC6 — consultation_response_hash present + sha256-hex"
  else
    fail "[$label] AC6 — consultation_response_hash missing/malformed: $(printf '%s\n' "$fm" | grep -i consultation || echo '(no match)')"
  fi

  # AC1: audit log shows consult action BEFORE generate for our surface_id.
  local consult_line generate_line
  consult_line="$(grep -n '"action":"consult"' "$AUTO_AUTHOR_LOG" | grep '"surface_id":"surface-3-vault-claude-md"' | head -1 | cut -d: -f1)"
  generate_line="$(grep -n '"action":"generate"' "$AUTO_AUTHOR_LOG" | grep '"surface_id":"surface-3-vault-claude-md"' | head -1 | cut -d: -f1)"
  if [ -n "$consult_line" ] && [ -n "$generate_line" ] && [ "$consult_line" -lt "$generate_line" ]; then
    pass "[$label] AC1 — consult($consult_line) ordered before generate($generate_line)"
  else
    fail "[$label] AC1 — ordering wrong (consult=$consult_line generate=$generate_line)"
  fi

  # AC2: rationale on stderr emits ≥3 PKM/IA citations.
  local cite_count=0
  grep -q 'Forte' "$stderr_capture" && cite_count=$((cite_count + 1))
  grep -q 'Ahrens' "$stderr_capture" && cite_count=$((cite_count + 1))
  grep -q 'Cowan' "$stderr_capture" && cite_count=$((cite_count + 1))
  grep -q 'Matrixflows' "$stderr_capture" && cite_count=$((cite_count + 1))
  if [ "$cite_count" -ge 3 ]; then
    pass "[$label] AC2 — $cite_count/4 PKM/IA citations rendered"
  else
    fail "[$label] AC2 — only $cite_count citations (need ≥3)"
  fi

  # AC3: archetype-specific reasoning, no crosstalk. Each archetype's
  # WHY-THIS-PROPOSAL-FOR-YOU reasoning carries a distinctive single-line
  # marker phrase. The crosstalk check verifies the OTHER archetypes'
  # markers are absent.
  case "$label" in
    consultant)
      if grep -q 'consultant / advisory archetype' "$stderr_capture" \
        && ! grep -q 'research / writing / project-driven archetype' "$stderr_capture" \
        && ! grep -q 'two pre-baked archetypes (Engagements / PARA-equivalent)' "$stderr_capture"; then
        pass "[consultant] AC3 — consultant reasoning present, no crosstalk"
      else
        fail "[consultant] AC3 — archetype crosstalk or missing reasoning"
      fi
      ;;
    researcher)
      if grep -q 'research / writing / project-driven archetype' "$stderr_capture" \
        && ! grep -q 'consultant / advisory archetype' "$stderr_capture" \
        && ! grep -q 'two pre-baked archetypes (Engagements / PARA-equivalent)' "$stderr_capture"; then
        pass "[researcher] AC3 — researcher reasoning present, no crosstalk"
      else
        fail "[researcher] AC3 — archetype crosstalk or missing reasoning"
      fi
      ;;
    custom)
      if grep -q 'two pre-baked archetypes (Engagements / PARA-equivalent)' "$stderr_capture" \
        && ! grep -q 'consultant / advisory archetype' "$stderr_capture" \
        && ! grep -q 'research / writing / project-driven archetype' "$stderr_capture"; then
        pass "[custom] AC3 — custom reasoning present, no crosstalk"
      else
        fail "[custom] AC3 — archetype crosstalk or missing reasoning"
      fi
      ;;
  esac
}

# --- Reject-path test driver (AC4) ---

run_reject_path() {
  local label="reject-consultant"
  local manifest="$T4_TEST_DIR/manifest-${label}.json"
  local vault="$T4_TEST_DIR/vault-${label}"
  local target="$vault/CLAUDE.md"
  local stderr_capture="$T4_TEST_DIR/stderr-${label}.log"

  mkdir -p "$vault"
  write_manifest_consultant "$manifest"
  substitute_vault_root "$manifest" "$vault"

  : > "$AUTO_AUTHOR_LOG"

  printf 'r\n' | bash "$SURFACE" \
    --target "$target" \
    --user-manifest "$manifest" \
    --template "$TEMPLATE" \
    > "$stderr_capture.stdout" 2> "$stderr_capture"
  local rc=$?

  if [ "$rc" = "1" ]; then
    pass "[$label] surface-3 rc=1 on reject (expected)"
  else
    fail "[$label] surface-3 rc=$rc on reject (expected 1) — see $stderr_capture"
  fi

  # AC4: zero vault file write.
  if [ ! -e "$target" ]; then
    pass "[$label] AC4 — target file absent after reject"
  else
    fail "[$label] AC4 — target file written on reject path: $target"
  fi

  # Audit log: reject record present, NO generate/apply records for our surface.
  if grep -q '"action":"consult"' "$AUTO_AUTHOR_LOG" && grep -q '"response":"reject"' "$AUTO_AUTHOR_LOG"; then
    pass "[$label] AC4 — consult/reject record present"
  else
    fail "[$label] AC4 — no consult/reject record in audit log"
  fi
  if grep '"surface_id":"surface-3-vault-claude-md"' "$AUTO_AUTHOR_LOG" | grep -q '"action":"generate"'; then
    fail "[$label] AC4 — generate record present on reject path (BREACH)"
  else
    pass "[$label] AC4 — no generate record on reject path"
  fi
  if grep '"surface_id":"surface-3-vault-claude-md"' "$AUTO_AUTHOR_LOG" | grep -q '"action":"apply"'; then
    fail "[$label] AC4 — apply record present on reject path (BREACH)"
  else
    pass "[$label] AC4 — no apply record on reject path"
  fi
}

# --- Drive ---

printf '\n=== SP15 T-4 acceptance test ===\n'
printf 'sandbox: %s\n' "$T4_TEST_DIR"
printf 'audit:   %s\n\n' "$AUTO_AUTHOR_LOG"

run_accept_archetype "consultant" write_manifest_consultant "$T4_TEST_DIR/vault-consultant"
run_accept_archetype "researcher" write_manifest_researcher "$T4_TEST_DIR/vault-researcher"
run_accept_archetype "custom"     write_manifest_custom     "$T4_TEST_DIR/vault-custom"
run_reject_path

# --- Summary ---

printf '\n=== summary ===\n'
printf 'PASS: %s\n' "$PASS_COUNT"
printf 'FAIL: %s\n' "$FAIL_COUNT"
if [ "$FAIL_COUNT" = "0" ]; then
  printf 'OVERALL: GREEN\n'
  exit 0
else
  printf 'OVERALL: RED\n' >&2
  exit 1
fi
