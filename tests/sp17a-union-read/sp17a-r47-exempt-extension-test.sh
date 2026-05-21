#!/usr/bin/env bash
# SP17a T-2-narrow — R-47 exempt-path extension union-read test (AC-2)
#
# Scope: demonstrate that pre-write-guard.sh R-47 tag-presence advisory
# (currently sourced from $GATE_R47_EXEMPT_PATHS at hook startup, loaded
# from $BUNDLE_JSON.r47_exempt_paths_composed — foundation-only) ignores
# adopter overlay extensions to the exempt-path set. Adopter registers
# a new exempt path (e.g., Meetings/Adopter-R47-Test/*) via overlay-master.json
# → tag-less vault write at that path → R-47 advisory fires because hook
# never reads overlay.
#
# Mechanical mirror of the SP16/SP17a T-1 retrofit pattern; the only branch
# in T-2's original 4-tuple (R-33, R-39, R-47, R-50) that is genuinely a
# data-source swap rather than a substantive refactor.
#
# Modes:
#   --state current   (default) — asserts R-47 advisory fires (bug present)
#                                  exit 0 on bug confirmed; exit 1 otherwise
#   --state fixed                — asserts R-47 advisory does NOT fire (bug closed)
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
SP17a T-2-narrow R-47 exempt-path extension test.

Usage:
  $0 [--state current|fixed]

Modes:
  current  Assert R-47 tag-presence advisory fires (bug reproduced).
  fixed    Assert R-47 tag-presence advisory does NOT fire (bug closed).

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

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
HOOK="$FOUNDATION_REPO/hooks/pre-write-guard.sh"
FOUNDATION_SRC="$FOUNDATION_REPO/governance/foundation-master.json"

[ -x "$HOOK" ] || { printf 'FATAL: hook not executable: %s\n' "$HOOK" >&2; exit 2; }
[ -r "$FOUNDATION_SRC" ] || { printf 'FATAL: foundation-master source missing: %s\n' "$FOUNDATION_SRC" >&2; exit 2; }

TEMPROOT="$(mktemp -d -t sp17a-r47ext.XXXXXX)" || { printf 'FATAL: mktemp failed\n' >&2; exit 2; }
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

# Stage foundation copy + hand-crafted overlay that extends the R-47
# exempt-paths set with a path under Meetings/ — Meetings is a foundation
# system folder (Branch #1 Class A advisory skips) AND is NOT covered by
# any foundation R-47 exempt-paths glob, so any tag-less write under it
# triggers R-47 advisory in the current state. Overlay adds a deeper-prefix
# exemption to verify the union view propagates to the R-47 walk.
cp "$FOUNDATION_SRC" "$FIX_GOV/foundation-master.json"

# Adopter-declared exempt path is "Meetings/Adopter-R47-Test/*". Overlay
# composes the FULL post-extension set so the deep-merge REPLACE-on-arrays
# semantic at this top-level slot still yields union semantics — matches
# the same pattern used by sp17a-tag-extension-bug-reproduction.sh, and
# the same Surprise #4 / T-7 per-leaf merge-strategy caveat applies.
FOUNDATION_R47=$(jq -c '.r47_exempt_paths_composed // []' "$FIX_GOV/foundation-master.json")
ADOPTER_EXEMPT_PATH="Meetings/Adopter-R47-Test/*"
COMPOSED_R47=$(jq -nc \
  --argjson f "$FOUNDATION_R47" \
  --arg p "$ADOPTER_EXEMPT_PATH" \
  '$f + [$p]')

cat > "$FIX_GOV/overlay-master.json" <<JSON
{
  "r47_exempt_paths_composed": ${COMPOSED_R47}
}
JSON
# r47_exempt_paths_composed is a top-level array slot, not in the R-52
# entity-collision domain (tagging pillar only walks `.rules`). The slot
# is governed by T-7 per-leaf merge strategy (UNION on list-typed leaves),
# not by R-52 collision DENY. No _override_reason needed at this slot.

# ---- Build hook input payload -----------------------------------------------

# tag-LESS file in adopter-extended exempt path. R-47 advisory fires
# when (a) NOT exempt, (b) frontmatter present, (c) tags missing/empty.
# This file satisfies (b)+(c); (a) is the variable under test — foundation-
# only = NOT exempt (advisory fires); union-read = exempt (advisory skipped).
WRITE_PATH="$FIX_VAULT/Meetings/Adopter-R47-Test/opaque-note.md"
mkdir -p "$(dirname "$WRITE_PATH")"

# Use type 'navigation': required fields are {type, engagement, updated}
# (tags is OPTIONAL per foundation-master.json#types.navigation). R-33 case
# statement has no 'navigation' arm — placement advisory is silent. Tier 2
# DENY checks all pass; the hook proceeds to emit accumulated TIER1_MSGS,
# inside which the R-47 advisory text would surface IFF the path is non-
# exempt. Use this isolation to make the R-47 marker testable in stdout.
read -r -d '' WRITE_CONTENT <<'MD' || true
---
type: navigation
engagement: SP17aTestEngagement
updated: 2026-05-21
---
# Adopter R-47 Test Navigation

Spike fixture content for SP17a T-2-narrow R-47 exempt-path extension test.
This file deliberately omits tags; adopter overlay declares the parent
directory exempt from R-47. Foundation-only reads miss the exemption.
MD

HOOK_INPUT=$(jq -nc \
  --arg fp "$WRITE_PATH" \
  --arg content "$WRITE_CONTENT" \
  '{tool_name: "Write", tool_input: {file_path: $fp, content: $content}}')

# ---- Invoke hook under sandbox env -----------------------------------------

HOOK_STDOUT="$TEMPROOT/hook-stdout.txt"
HOOK_STDERR="$TEMPROOT/hook-stderr.txt"

set +e
printf '%s' "$HOOK_INPUT" | \
  VAULT_ROOT="$FIX_VAULT" \
  FOUNDATION_MASTER_PATH="$FIX_GOV/foundation-master.json" \
  OVERLAY_MASTER_PATH="$FIX_GOV/overlay-master.json" \
  HOOKS_STATE_OVERRIDE="$FIX_STATE" \
  CLAUDE_SESSION_ID="sp17a-r47ext-test" \
  bash "$HOOK" >"$HOOK_STDOUT" 2>"$HOOK_STDERR"
HOOK_RC=$?
set -e

# ---- Assertion --------------------------------------------------------------

# R-47 advisory emits "[R-47 TAG PRESENCE]" into the hook's JSON
# additionalContext output (Tier 1 message at pre-write-guard.sh R-47 branch).
ADVISORY_MARKER="[R-47 TAG PRESENCE]"
if grep -qF "$ADVISORY_MARKER" "$HOOK_STDOUT" 2>/dev/null; then
  ADVISORY_FIRED=1
else
  ADVISORY_FIRED=0
fi

PASS=0
FAIL=0
case "$STATE" in
  current)
    if [ "$ADVISORY_FIRED" = "1" ]; then
      printf '=== SP17a T-2-narrow [state=current] BUG REPRODUCED ===\n'
      printf 'hook rc=%s; R-47 advisory fired against overlay-extended exempt path "%s"\n' "$HOOK_RC" "$ADOPTER_EXEMPT_PATH"
      printf 'Adopter overlay carries .r47_exempt_paths_composed including the adopter path — hook ignored it (reads foundation only via $GATE_R47_EXEMPT_PATHS).\n'
      PASS=1
    else
      printf '=== SP17a T-2-narrow [state=current] FAILED TO REPRODUCE ===\n'
      printf 'hook rc=%s; R-47 advisory did not fire as expected.\n' "$HOOK_RC"
      printf 'Possible causes: hook already retrofitted, foundation already declares the adopter path, or fixture broken.\n'
      echo '--- stdout ---'; cat "$HOOK_STDOUT"
      echo '--- stderr ---'; cat "$HOOK_STDERR"
      FAIL=1
    fi
    ;;
  fixed)
    if [ "$ADVISORY_FIRED" = "0" ]; then
      printf '=== SP17a T-2-narrow [state=fixed] BUG CLOSED ===\n'
      printf 'hook rc=%s; R-47 advisory did NOT fire; adopter-extended exempt path "%s" honored via union-read.\n' "$HOOK_RC" "$ADOPTER_EXEMPT_PATH"
      PASS=1
    else
      printf '=== SP17a T-2-narrow [state=fixed] FIX VERIFICATION FAILED ===\n'
      printf 'hook rc=%s; R-47 advisory still fires after retrofit. Helper or branch wiring broken.\n' "$HOOK_RC"
      echo '--- stdout ---'; cat "$HOOK_STDOUT"
      echo '--- stderr ---'; cat "$HOOK_STDERR"
      FAIL=1
    fi
    ;;
esac

# Capture golden output on first successful current-state reproduction.
GOLDEN_DIR="$FOUNDATION_REPO/tests/sp17a-union-read/fixtures"
if [ "$STATE" = "current" ] && [ "$PASS" = "1" ]; then
  GOLDEN="$GOLDEN_DIR/r47-exempt-extension-current.golden"
  if [ ! -f "$GOLDEN" ]; then
    mkdir -p "$GOLDEN_DIR"
    {
      printf 'SP17a T-2-narrow R-47 exempt-path extension current-state output (captured %s)\n' "$(date -u +%FT%TZ)"
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
