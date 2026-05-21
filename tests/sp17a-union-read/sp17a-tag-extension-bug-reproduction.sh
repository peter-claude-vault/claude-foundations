#!/usr/bin/env bash
# SP17a T-1 — Q1 bug end-to-end reproduction (tag-extension variant; AC-1)
#
# Scope: demonstrate that pre-write-guard.sh R-32 TAXONOMY tag-prefix DENY
# (currently sourced from $GATE_R47_PREFIX_REGEX at hook startup, loaded
# from $BUNDLE_JSON.tagging.taxonomy.dimension_prefixes — foundation-only)
# ignores adopter overlay extensions to tag dimensions. Adopter registers
# a new tag dimension (e.g., #client/*) via overlay-master.json → vault
# write with that tag → DENY because hook never reads overlay.
#
# Surprise #3 (per SP16 scope packet): packet 06's reproduction recipe
# was designed for this branch (R-32-TAXONOMY at the tag-prefix conformance
# DENY), but SP16 spike retargeted to R-32 TYPE-allowlist. SP17a closes the
# original target via this script.
#
# Modes:
#   --state current   (default) — asserts R-32 TAXONOMY DENY fires (bug present)
#                                  exit 0 on bug confirmed; exit 1 otherwise
#   --state fixed                — asserts R-32 TAXONOMY DENY does NOT fire (bug closed)
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
SP17a T-1 bug reproduction (tag-extension variant).

Usage:
  $0 [--state current|fixed]

Modes:
  current  Assert R-32 TAXONOMY tag-prefix DENY fires (bug reproduced).
  fixed    Assert R-32 TAXONOMY DENY does NOT fire (bug closed).

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

TEMPROOT="$(mktemp -d -t sp17a-tagext-repro.XXXXXX)" || { printf 'FATAL: mktemp failed\n' >&2; exit 2; }
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

# Stage fixtures: foundation copy + hand-crafted overlay registering a new
# tag dimension "client" via .tagging.taxonomy.dimension_prefixes.
cp "$FOUNDATION_SRC" "$FIX_GOV/foundation-master.json"

# Overlay-master.json registers "client" as a new dimension prefix. Carries
# top-level override_reasons dict to document the extension intent (the
# tagging slice doesn't collide with foundation .frontmatter.types — R-52
# applies to entity-level collisions; dimension array extensions are
# additive in semantics but REPLACE in current mutation library — see SP16
# Surprise #4 / T-7 per-leaf merge-strategy planning).
#
# To keep current-state vs fixed-state isolation testable WITHOUT relying
# on T-7's per-leaf UNION merge, overlay declares the FULL post-extension
# set ["status","log","client"] so deep-merge (REPLACE on arrays) yields
# the same union semantics — mirrors what a future overlay-master-mutate.sh
# per-leaf UNION leaf would produce.
cat > "$FIX_GOV/overlay-master.json" <<'JSON'
{
  "tagging": {
    "taxonomy": {
      "dimension_prefixes": ["status", "log", "client"],
      "user_facing_dimensions": ["client"]
    }
  },
  "override_reasons": {
    "tagging": {
      "taxonomy.dimension_prefixes": "spike fixture — adopter-extended tag dimension for SP17a union-read verification"
    }
  }
}
JSON

# ---- Build hook input payload -----------------------------------------------

# Path uses 'Archive/' which IS a foundation system folder per
# pre-write-guard.sh:L838 — Branch #1 Class A advisory skips; the hook
# proceeds to R-32 TAXONOMY tag-conformance DENY (SP16 Surprise #4 lesson).
WRITE_PATH="$FIX_VAULT/Archive/Adopter/client-acme-brief.md"
mkdir -p "$(dirname "$WRITE_PATH")"

# tool_input.content has frontmatter declaring the adopter-extended tag
# #client/acme — this prefix is in overlay's dimension_prefixes but NOT
# in foundation's. Type 'reference' is a foundation type (no R-32 UNKNOWN
# TYPE side effect). Required fields for reference: type, updated, tags.
read -r -d '' WRITE_CONTENT <<'MD' || true
---
type: reference
updated: 2026-05-21
tags:
  - "#client/acme"
---
# Acme Client Reference

Spike fixture content for SP17a tag-extension bug reproduction.
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
  CLAUDE_SESSION_ID="sp17a-tagext-repro" \
  bash "$HOOK" >"$HOOK_STDOUT" 2>"$HOOK_STDERR"
HOOK_RC=$?
set -e

# ---- Assertion --------------------------------------------------------------

# The R-32 TAXONOMY DENY emits "Tags not matching taxonomy prefixes" into
# the hook's JSON output (Tier 2 message at pre-write-guard.sh:L1446).
DENY_MARKER="Tags not matching taxonomy prefixes"
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
      printf '=== SP17a T-1 [state=current] BUG REPRODUCED ===\n'
      printf 'hook rc=%s; R-32 TAXONOMY DENY fired against overlay-extended tag prefix "#client/"\n' "$HOOK_RC"
      printf 'Adopter overlay carries .tagging.taxonomy.dimension_prefixes including "client" — hook ignored it (reads foundation only via $GATE_R47_PREFIX_REGEX).\n'
      PASS=1
    else
      printf '=== SP17a T-1 [state=current] FAILED TO REPRODUCE ===\n'
      printf 'hook rc=%s; R-32 TAXONOMY DENY did not fire as expected.\n' "$HOOK_RC"
      printf 'Possible causes: hook already retrofitted, foundation already declares "client" dimension, or fixture broken.\n'
      echo '--- stdout ---'; cat "$HOOK_STDOUT"
      echo '--- stderr ---'; cat "$HOOK_STDERR"
      FAIL=1
    fi
    ;;
  fixed)
    if [ "$DENY_FIRED" = "0" ]; then
      printf '=== SP17a T-1 [state=fixed] BUG CLOSED ===\n'
      printf 'hook rc=%s; R-32 TAXONOMY DENY did NOT fire; overlay-extended tag prefix "#client/" accepted via union-read.\n' "$HOOK_RC"
      PASS=1
    else
      printf '=== SP17a T-1 [state=fixed] FIX VERIFICATION FAILED ===\n'
      printf 'hook rc=%s; R-32 TAXONOMY DENY still fires after retrofit. Helper or branch wiring broken.\n' "$HOOK_RC"
      echo '--- stdout ---'; cat "$HOOK_STDOUT"
      echo '--- stderr ---'; cat "$HOOK_STDERR"
      FAIL=1
    fi
    ;;
esac

# Capture golden output on first successful current-state reproduction.
GOLDEN_DIR="$FOUNDATION_REPO/tests/sp17a-union-read/fixtures"
if [ "$STATE" = "current" ] && [ "$PASS" = "1" ]; then
  GOLDEN="$GOLDEN_DIR/bug-reproduction-current-tag-extension.golden"
  if [ ! -f "$GOLDEN" ]; then
    mkdir -p "$GOLDEN_DIR"
    {
      printf 'SP17a T-1 tag-extension bug-reproduction current-state output (captured %s)\n' "$(date -u +%FT%TZ)"
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
