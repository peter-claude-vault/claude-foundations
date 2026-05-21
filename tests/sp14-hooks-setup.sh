#!/usr/bin/env bash
# tests/sp14-hooks-setup.sh
#
# SP14 T-18 — Hook fixture common setup library.
# Sourced by sp14-hooks-*.sh fixture scripts. Provides:
#   - TEMPROOT setup + HOME jail (idempotent per-fixture)
#   - jailed-HOME assertion (whitelists /tmp/* and /var/folders/* per macOS mktemp behavior)
#   - hook-substrate staging (foundation-repo hooks/ + lib/registry.sh +
#     librarian/lib/plan-path.sh + governance/) into $HOME/.claude/
#   - PreToolUse JSON input builders (build_write_payload / build_edit_payload /
#     build_askuserquestion_payload) — emit on stdout for piping into hooks
#   - assertion helpers: emit_pass / emit_fail / assert_rc / assert_contains /
#     assert_not_contains / fixture_summary
#
# Per-fixture usage:
#   source "$(dirname "$0")/sp14-hooks-setup.sh"
#   setup_jailed_home
#   stage_substrate
#   ...build payload + invoke + assert...
#   fixture_summary  # exits 0/1
#
# bash 3.2 compatible. No -e (callers manage failures via emit_fail).

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
# Preserve the real HOME so we can copy registry.sh from live FS only if the
# foundation-repo copy is missing. (Foundation-repo has lib/registry.sh per
# Plan 81 SP13; live is fallback for older snapshots.)
REAL_HOME="$HOME"

PASS=0
FAIL=0
FAILED_CHECKS=""

emit_pass() {
  printf '  PASS: %s\n' "$1"
  PASS=$((PASS + 1))
}

emit_fail() {
  printf '  FAIL: %s\n' "$1"
  FAIL=$((FAIL + 1))
  FAILED_CHECKS="${FAILED_CHECKS}
    - $1"
}

# --- HOME jail ---------------------------------------------------------------
setup_jailed_home() {
  TEMPROOT="$(mktemp -d 2>/dev/null)"
  if [ -z "$TEMPROOT" ] || [ ! -d "$TEMPROOT" ]; then
    printf 'FATAL: mktemp -d failed\n' >&2
    exit 2
  fi
  # macOS mktemp returns /var/folders/...; Linux returns /tmp/...
  case "$TEMPROOT" in
    /tmp/*|/var/folders/*|/private/tmp/*|/private/var/folders/*) ;;
    *)
      printf 'FATAL: TEMPROOT not in safe prefix: %s\n' "$TEMPROOT" >&2
      exit 2
      ;;
  esac
  # Trap cleanup — note: callers also exit explicitly via fixture_summary.
  trap 'rm -rf "$TEMPROOT"' EXIT INT TERM

  export HOME="$TEMPROOT"
  export VAULT_ROOT="$TEMPROOT/vault"
  export PLANS_DIR="$TEMPROOT/plans"
  # Telemetry redirect for DQP fixtures.
  export DQ_EVENTS_PATH="$TEMPROOT/dq-events.jsonl"
  export HOOKS_STATE_OVERRIDE="$TEMPROOT/.claude/hooks/state"
  # Avoid pulling Peter's real CLAUDE_SESSION_ID.
  export CLAUDE_SESSION_ID="sp14-fixture-$$"

  # Jail assertion AFTER export — defensive against caller mis-wiring.
  case "$HOME" in
    /tmp/*|/var/folders/*|/private/tmp/*|/private/var/folders/*) ;;
    *)
      printf 'FATAL: HOME not jailed: %s\n' "$HOME" >&2
      exit 2
      ;;
  esac

  mkdir -p "$HOME/.claude/hooks/lib" "$HOME/.claude/hooks/state" \
           "$HOME/.claude/hooks/schemas" \
           "$HOME/.claude/skills/librarian/lib" \
           "$HOME/.claude/governance/file-type-contracts" \
           "$VAULT_ROOT" "$PLANS_DIR" \
           "$HOME/Desktop/artefact-daily-logs"
}

# --- Stage substrate ---------------------------------------------------------
# Copies foundation-repo hooks tree + lib/registry.sh + librarian plan-path.sh +
# governance/ into the jailed HOME. ALSO mirrors the foundation-repo governance
# into $HOME/Code/claude-stem/governance/ — Branch #2 + Branch #3 hardcode that
# path. (Substrate behavior; do not change.)
stage_substrate() {
  # 1. Hooks tree (binaries + lib + schemas)
  cp -R "$FOUNDATION_REPO/hooks/." "$HOME/.claude/hooks/" 2>/dev/null

  # 1b. SP17a T-3: stage lib/foundation-overlay-load.sh into hooks/lib/ to
  #     mirror install.sh Step 3 layout (lib/*.sh → hooks/lib/). Branch #1
  #     Class A/C + Branch #2 now consume the union view via this helper;
  #     substrate-without-helper degenerates union to BUNDLE_JSON and Branch
  #     #1 Class C falsely flags overlay-extended types as unknown.
  if [ -f "$FOUNDATION_REPO/lib/foundation-overlay-load.sh" ]; then
    cp "$FOUNDATION_REPO/lib/foundation-overlay-load.sh" \
       "$HOME/.claude/hooks/lib/foundation-overlay-load.sh" 2>/dev/null
    chmod +x "$HOME/.claude/hooks/lib/foundation-overlay-load.sh" 2>/dev/null || true
  fi

  # 2. registry.sh — substrate sources $HOME/.claude/hooks/lib/registry.sh
  #    Foundation-repo has lib/registry.sh but it depends on _manifest_get
  #    (defined in foundation-repo lib/paths.sh, NOT hooks/lib/paths.sh —
  #    SP13 split). The live $HOME/.claude/hooks/lib/registry.sh is the
  #    install-target shape, sources the simpler hooks/lib/paths.sh. Prefer
  #    live to match install-resolved runtime; fall back to foundation-repo.
  if [ -f "$REAL_HOME/.claude/hooks/lib/registry.sh" ]; then
    cp "$REAL_HOME/.claude/hooks/lib/registry.sh" "$HOME/.claude/hooks/lib/registry.sh"
  elif [ -f "$FOUNDATION_REPO/lib/registry.sh" ]; then
    cp "$FOUNDATION_REPO/lib/registry.sh" "$HOME/.claude/hooks/lib/registry.sh"
  else
    printf 'FATAL: registry.sh not found in live HOME or foundation-repo\n' >&2
    exit 2
  fi

  # 3. plan-path.sh (pre-write-guard.sh sources it; foundation-repo authoritative)
  if [ -f "$FOUNDATION_REPO/skills/librarian/lib/plan-path.sh" ]; then
    cp "$FOUNDATION_REPO/skills/librarian/lib/plan-path.sh" \
       "$HOME/.claude/skills/librarian/lib/plan-path.sh"
  elif [ -f "$REAL_HOME/.claude/skills/librarian/lib/plan-path.sh" ]; then
    cp "$REAL_HOME/.claude/skills/librarian/lib/plan-path.sh" \
       "$HOME/.claude/skills/librarian/lib/plan-path.sh"
  else
    printf 'FATAL: plan-path.sh not found\n' >&2
    exit 2
  fi

  # 4. Governance — TWO locations because Branch #2 + #3 hardcode
  #    $HOME/Code/claude-stem/governance/...  AND  $HOME/.claude/governance/...
  #    is the install-time target. Stage both.
  cp -R "$FOUNDATION_REPO/governance/." "$HOME/.claude/governance/" 2>/dev/null
  mkdir -p "$HOME/Code/claude-stem/governance/file-type-contracts"
  cp -R "$FOUNDATION_REPO/governance/." "$HOME/Code/claude-stem/governance/" 2>/dev/null

  # 5. Disable G1 live-guard for fixtures — make it non-executable so the
  #    G1 block falls through (pre-write-guard.sh checks -x). Fixtures
  #    exercise SP14 branches downstream of G1.
  chmod -x "$HOME/.claude/hooks/lib/live-guard.sh" 2>/dev/null || true

  # 6. Ensure exec bits on substrate
  chmod +x "$HOME/.claude/hooks/pre-write-guard.sh" "$HOME/.claude/hooks/pre-asq-guard.sh" 2>/dev/null || true

  # 7. Stage an overlay-master.json that registers `vault-writer` as a known
  #    file-type so Branch #1 Class C does not intercept Vault Writers/*.md
  #    writes (those are owned by Branch #3 which validates the writer-
  #    reference frontmatter contract). foundation-master.json does NOT yet
  #    ship vault-writer in frontmatter.types (deferred to SP15 foundation-
  #    master regen per spec.md Scope (out)); the overlay fills that gap for
  #    fixture-time so Branch #3 can fire without Class C short-circuit.
  cat > "$HOME/.claude/governance/overlay-master.json" <<'JSON'
{
  "frontmatter": {
    "types": {
      "vault-writer": {}
    }
  }
}
JSON
}

# --- Payload builders --------------------------------------------------------
# All emit JSON to stdout. Caller pipes into hook.

build_write_payload() {
  # args: file_path content
  local fp="$1" ct="$2"
  jq -n --arg fp "$fp" --arg ct "$ct" \
    '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":$ct}}'
}

build_edit_payload() {
  # args: file_path old_string new_string
  local fp="$1" os="$2" ns="$3"
  jq -n --arg fp "$fp" --arg os "$os" --arg ns "$ns" \
    '{"tool_name":"Edit","tool_input":{"file_path":$fp,"old_string":$os,"new_string":$ns,"replace_all":false}}'
}

build_askuserquestion_payload() {
  # args: JSON string of the questions array (e.g., '[{"question":"...","options":[...]}]')
  local questions_json="$1"
  jq -n --argjson q "$questions_json" \
    '{"tool_name":"AskUserQuestion","tool_input":{"questions":$q}}'
}

# --- Assertion helpers -------------------------------------------------------
assert_rc() {
  # args: label expected actual
  local label="$1" exp="$2" act="$3"
  if [ "$act" = "$exp" ]; then
    emit_pass "$label (rc=$act)"
  else
    emit_fail "$label: expected rc=$exp, got rc=$act"
  fi
}

assert_contains() {
  # args: label haystack needle
  local label="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    emit_pass "$label"
  else
    emit_fail "$label: substring not found: $needle"
    # debug: print first 300 chars of haystack
    printf '       haystack(0..400)=%s\n' "$(printf '%s' "$hay" | head -c 400)" >&2
  fi
}

assert_not_contains() {
  # args: label haystack needle
  local label="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    emit_fail "$label: substring unexpectedly present: $needle"
    printf '       haystack(0..400)=%s\n' "$(printf '%s' "$hay" | head -c 400)" >&2
  else
    emit_pass "$label"
  fi
}

assert_empty_stdout() {
  # args: label stdout
  local label="$1" s="$2"
  if [ -z "$s" ]; then
    emit_pass "$label"
  else
    emit_fail "$label: stdout not empty"
    printf '       stdout=%s\n' "$(printf '%s' "$s" | head -c 200)" >&2
  fi
}

fixture_summary() {
  printf '\n  === %d PASS, %d FAIL ===\n' "$PASS" "$FAIL"
  if [ "$FAIL" -ne 0 ]; then
    printf '%s\n' "$FAILED_CHECKS"
    exit 1
  fi
  exit 0
}

# --- Invocation wrapper ------------------------------------------------------
# Pipes a JSON payload to a hook and captures stdout + rc.
# Usage: out_var=$(run_hook hook_name payload)
run_hook() {
  # args: hook_basename payload
  local hook="$1" payload="$2"
  printf '%s' "$payload" | bash "$HOME/.claude/hooks/$hook"
}
