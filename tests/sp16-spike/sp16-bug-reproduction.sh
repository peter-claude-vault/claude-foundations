#!/usr/bin/env bash
# SP16 T-1 — Q1 bug end-to-end reproduction (AC-1) + post-retrofit verification (AC-3)
#
# Scope: demonstrate that pre-write-guard.sh:L1140-L1170 (R-32 TYPE allowlist
# DENY) reads ONLY foundation-master.json and ignores overlay-master.json
# extensions. Adopter adds a new type via overlay → vault write with that
# type → DENY because hook never reads overlay.
#
# Modes:
#   --state current   (default) — asserts DENY fires (bug present)
#                                  exit 0 on bug confirmed; exit 1 otherwise
#   --state fixed                — asserts DENY does NOT fire (bug closed)
#                                  exit 0 on fix confirmed; exit 1 otherwise
#
# Hard constraints:
#   - ZERO writes to ~/.claude/ paths from this script
#   - All fixture content under $TEMPROOT (mktemp jail)
#   - HOOKS_STATE_OVERRIDE points crash logs into fixture
#   - VAULT_ROOT, FOUNDATION_MASTER_PATH, OVERLAY_MASTER_PATH all env-overridden
#
# bash 3.2 compatible.

set -u

# ---- Arg parse --------------------------------------------------------------

STATE="current"
while [ $# -gt 0 ]; do
  case "$1" in
    --state) STATE="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
SP16 T-1 bug reproduction.

Usage:
  $0 [--state current|fixed]

Modes:
  current  Assert R-32 UNKNOWN TYPE DENY fires (bug reproduced).
  fixed    Assert R-32 UNKNOWN TYPE DENY does NOT fire (bug closed).

Exit codes:
  0   Assertion held (mode-appropriate)
  1   Assertion failed
  2   Setup/IO failure
EOF
      exit 0
      ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "$STATE" in
  current|fixed) ;;
  *) printf 'invalid --state: %s (expected current|fixed)\n' "$STATE" >&2; exit 2 ;;
esac

# ---- Sandbox setup ----------------------------------------------------------

# Resolve repo from script location so tests bind to THIS worktree, not the
# live ~/Code/claude-stem (matches T-5 sp17a-r52-write-time-deny-test.sh).
_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FOUNDATION_REPO="${FOUNDATION_REPO:-$(cd "$_TEST_DIR/../.." && pwd)}"
HOOK="$FOUNDATION_REPO/hooks/pre-write-guard.sh"
LIB_MUTATE="$FOUNDATION_REPO/lib/overlay-master-mutate.sh"
FOUNDATION_SRC="$FOUNDATION_REPO/governance/foundation-master.json"
OVERLAY_SCHEMA="$FOUNDATION_REPO/schemas/overlay-master-schema.json"

[ -x "$HOOK" ] || { printf 'FATAL: hook not executable: %s\n' "$HOOK" >&2; exit 2; }
[ -r "$FOUNDATION_SRC" ] || { printf 'FATAL: foundation-master source missing: %s\n' "$FOUNDATION_SRC" >&2; exit 2; }

TEMPROOT="$(mktemp -d -t sp16-bug-repro.XXXXXX)" || { printf 'FATAL: mktemp failed\n' >&2; exit 2; }
case "$TEMPROOT" in
  /*) ;;
  *) printf 'FATAL: TEMPROOT not absolute: %s\n' "$TEMPROOT" >&2; exit 2 ;;
esac
trap 'rm -rf "$TEMPROOT"' EXIT

FIX_CLAUDE="$TEMPROOT/.claude"
FIX_GOV="$FIX_CLAUDE/governance"
FIX_VAULT="$TEMPROOT/vault"
FIX_STATE="$FIX_CLAUDE/hooks/state"
mkdir -p "$FIX_GOV" "$FIX_VAULT" "$FIX_STATE"

# Confinement assertion: nothing should escape TEMPROOT.
case "$FIX_GOV" in "$TEMPROOT"/*) ;; *) printf 'FATAL: FIX_GOV not jailed\n' >&2; exit 2 ;; esac

# Stage fixtures: foundation copy + hand-crafted overlay with new type slot.
cp "$FOUNDATION_SRC" "$FIX_GOV/foundation-master.json"

# Hand-author overlay-master.json registering a new adopter type "client-brief".
# Shape matches foundation .frontmatter.types (object keyed by type slug).
# Per-entry `_override_reason` is the canonical R-52 shape per ADR-0006
# (SP17a T-5 Decision Point #1 retired the prior shape-bridge top-level dict).
cat > "$FIX_GOV/overlay-master.json" <<'JSON'
{
  "frontmatter": {
    "types": {
      "client-brief": {
        "required": ["type", "title", "tags", "created", "updated"],
        "enums": { "type": ["client-brief"] },
        "_override_reason": "spike fixture — adopter-extended type for SP16 union-read verification"
      }
    }
  }
}
JSON

# ---- Build hook input payload -----------------------------------------------

# Path uses 'Archive/' which IS a foundation system folder per
# pre-write-guard.sh:L838 AND has no folder-specific Branch #3-style
# enforcement (unlike 'Vault Writers/'). The hook proceeds to general
# R-32 type-DENY at L1168.
WRITE_PATH="$FIX_VAULT/Archive/Adopter/client-brief-001.md"
mkdir -p "$(dirname "$WRITE_PATH")"

# tool_input.content has frontmatter declaring type: client-brief — the type
# foundation-master does NOT carry but overlay-master DOES.
read -r -d '' WRITE_CONTENT <<'MD' || true
---
type: client-brief
title: Acme Q3 Brief
tags:
  - "#scope/client"
  - "#status/active"
created: 2026-05-21
updated: 2026-05-21
---
# Acme Q3 Brief

Spike fixture content.
MD

HOOK_INPUT=$(jq -nc \
  --arg fp "$WRITE_PATH" \
  --arg content "$WRITE_CONTENT" \
  '{tool_name: "Write", tool_input: {file_path: $fp, content: $content}}')

# ---- Invoke hook under sandbox env -----------------------------------------

# Override path env vars so the hook reads fixture artifacts, not live ~/.claude/.
# HOOKS_STATE_OVERRIDE redirects crash logs into fixture (per existing override
# at pre-write-guard.sh:L52). VAULT_ROOT overridden via paths.sh sentinel.
HOOK_STDOUT="$TEMPROOT/hook-stdout.txt"
HOOK_STDERR="$TEMPROOT/hook-stderr.txt"

set +e
printf '%s' "$HOOK_INPUT" | \
  VAULT_ROOT="$FIX_VAULT" \
  FOUNDATION_MASTER_PATH="$FIX_GOV/foundation-master.json" \
  OVERLAY_MASTER_PATH="$FIX_GOV/overlay-master.json" \
  HOOKS_STATE_OVERRIDE="$FIX_STATE" \
  CLAUDE_SESSION_ID="sp16-bug-repro" \
  bash "$HOOK" >"$HOOK_STDOUT" 2>"$HOOK_STDERR"
HOOK_RC=$?
set -e

# ---- Assertion --------------------------------------------------------------

# The R-32 UNKNOWN TYPE DENY emits "[R-32 UNKNOWN TYPE]" into the hook's
# JSON output (Tier 2 message). We check for that marker in stdout.
DENY_MARKER="R-32 UNKNOWN TYPE"
if grep -qF "$DENY_MARKER" "$HOOK_STDOUT" 2>/dev/null; then
  DENY_FIRED=1
else
  DENY_FIRED=0
fi

PASS=0
FAIL=0
case "$STATE" in
  current)
    if [ "$DENY_FIRED" = "1" ]; then
      printf '=== SP16 T-1 [state=current] BUG REPRODUCED ===\n'
      printf 'hook rc=%s; R-32 UNKNOWN TYPE DENY fired against overlay-extended type "client-brief"\n' "$HOOK_RC"
      printf 'Adopter overlay carries .frontmatter.types.client-brief — hook ignored it (reads foundation only).\n'
      PASS=1
    else
      printf '=== SP16 T-1 [state=current] FAILED TO REPRODUCE ===\n'
      printf 'hook rc=%s; R-32 UNKNOWN TYPE DENY did not fire as expected.\n' "$HOOK_RC"
      printf 'Possible causes: hook already retrofitted, foundation already declares "client-brief", or fixture broken.\n'
      echo '--- stdout ---'; cat "$HOOK_STDOUT"
      echo '--- stderr ---'; cat "$HOOK_STDERR"
      FAIL=1
    fi
    ;;
  fixed)
    if [ "$DENY_FIRED" = "0" ]; then
      printf '=== SP16 T-1 [state=fixed] BUG CLOSED ===\n'
      printf 'hook rc=%s; R-32 UNKNOWN TYPE DENY did NOT fire; overlay-extended type "client-brief" accepted via union-read.\n' "$HOOK_RC"
      PASS=1
    else
      printf '=== SP16 T-1 [state=fixed] FIX VERIFICATION FAILED ===\n'
      printf 'hook rc=%s; R-32 UNKNOWN TYPE DENY still fires after retrofit. Helper or branch wiring broken.\n' "$HOOK_RC"
      echo '--- stdout ---'; cat "$HOOK_STDOUT"
      echo '--- stderr ---'; cat "$HOOK_STDERR"
      FAIL=1
    fi
    ;;
esac

# Capture golden output on first successful current-state reproduction.
GOLDEN_DIR="$FOUNDATION_REPO/tests/sp16-spike/fixtures"
if [ "$STATE" = "current" ] && [ "$PASS" = "1" ]; then
  GOLDEN="$GOLDEN_DIR/bug-reproduction-current.golden"
  if [ ! -f "$GOLDEN" ]; then
    mkdir -p "$GOLDEN_DIR"
    {
      printf 'SP16 T-1 bug-reproduction current-state output (captured %s)\n' "$(date -u +%FT%TZ)"
      echo ''
      echo '--- hook stdout ---'
      cat "$HOOK_STDOUT"
      echo ''
      echo '--- hook stderr ---'
      cat "$HOOK_STDERR"
      echo ''
      printf 'exit code: %s\n' "$HOOK_RC"
    } > "$GOLDEN"
    printf '\nGolden file captured: %s\n' "$GOLDEN"
  fi
fi

if [ "$FAIL" = "1" ]; then
  exit 1
fi
exit 0
