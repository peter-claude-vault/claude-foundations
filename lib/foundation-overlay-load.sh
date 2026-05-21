#!/usr/bin/env bash
# lib/foundation-overlay-load.sh — SP16 spike union-load primitive.
#
# Reads ~/.claude/governance/foundation-master.json + overlay-master.json,
# performs R-52 collision tiebreaker check (overlay wins on collision IFF
# shadowing entry carries _override_reason OR top-level override_reasons
# dict entry), emits deep-merged JSON to stdout for hook consumption.
#
# Per Plan 81 SP16 (2026-05-21) — de-risk SP17 broad union-read retrofit by
# prototyping the helper API + R-52 enforcement at single-branch scope.
#
# R-52 contract verbatim (governance/_index.json:183-195):
#   When adopter Layer-3 overlay and foundation canonical both declare the
#   same rule ID / archetype enum value / extensible entry kind: adopter
#   Layer-3 SHADOWS foundation (adopter wins). Adopter MUST carry
#   `_override_reason` (free-text, mandatory) on every shadowing entry.
#   Per-write `--force-override` flag bypasses DENY for a single write.
#
# Shape-bridge (operator decision 2026-05-21): the helper accepts EITHER
# (a) per-entry `_override_reason` field on the shadowing overlay entry
# (per ADR-0006 verbatim) OR (b) top-level `override_reasons.<pillar>.<key>`
# dict entry (per /govern register skill body convention at
# register/SKILL.md:98,112,301). Either presence satisfies R-52.
#
# SP16 spike scope: R-52 collision detection is implemented for the
# .frontmatter.types pillar only (aligned with T-3 R-32 type-DENY retrofit).
# SP17 generalizes to all pillars per the scope packet recommendation.
#
# bash 3.2 compatible (no `declare -A`, no `mapfile`, no `${var,,}`).
# No file locks (read-only helper; mutate-side library handles locks).

set -u

# ---- Defaults ---------------------------------------------------------------

FOUNDATION_PATH="${FOUNDATION_MASTER_PATH:-$HOME/.claude/governance/foundation-master.json}"
OVERLAY_PATH="${OVERLAY_MASTER_PATH:-$HOME/.claude/governance/overlay-master.json}"
QUERY=""
FORCE_OVERRIDE=0

# ---- Usage ------------------------------------------------------------------

usage() {
  cat <<EOF
foundation-overlay-load.sh — SP16 union-load helper with R-52 enforcement.

Usage:
  foundation-overlay-load.sh \\
      [--foundation-path <path>] \\
      [--overlay-path <path>] \\
      [--query <jq-filter>] \\
      [--force-override]

Args:
  --foundation-path  Foundation bundle path. Default: \$FOUNDATION_MASTER_PATH
                     or ~/.claude/governance/foundation-master.json.
  --overlay-path     Overlay path. Default: \$OVERLAY_MASTER_PATH or
                     ~/.claude/governance/overlay-master.json.
  --query            Optional jq filter applied to union JSON before stdout
                     emission. Default: emit full union.
  --force-override   Skip R-52 collision DENY for this invocation. Per ADR-0006:
                     no persistent disable; flag must be added per write.

Exit codes:
  0  Success (union emitted; or fail-closed degraded fallback).
  1  R-52 violation — overlay shadows foundation without _override_reason.
  2  Usage error.
  3  Foundation read/parse error.
  5  Deep-merge failed (jq error).

Stderr:
  - R-52 DENY message (when exit 1)
  - Fail-closed warning (when overlay is invalid JSON; still exits 0)
  - Diagnostic messages

R-52 shape-bridge:
  Helper checks for override-reason in either shape:
    (a) Per-entry: \$overlay.frontmatter.types.<slug>._override_reason
    (b) Top-level: \$overlay.override_reasons.frontmatter.types.<slug>
  Either presence permits the shadow; absence of both DENIES.
EOF
}

# ---- Arg parse --------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --foundation-path) FOUNDATION_PATH="$2"; shift 2 ;;
    --overlay-path)    OVERLAY_PATH="$2"; shift 2 ;;
    --query)           QUERY="$2"; shift 2 ;;
    --force-override)  FORCE_OVERRIDE=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) printf 'foundation-overlay-load.sh: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---- Read foundation (required) ---------------------------------------------

if [ ! -r "$FOUNDATION_PATH" ]; then
  printf 'foundation-overlay-load.sh: foundation not readable: %s\n' "$FOUNDATION_PATH" >&2
  exit 3
fi
FOUNDATION_JSON=$(cat "$FOUNDATION_PATH")
if ! printf '%s' "$FOUNDATION_JSON" | jq empty >/dev/null 2>&1; then
  printf 'foundation-overlay-load.sh: foundation not valid JSON: %s\n' "$FOUNDATION_PATH" >&2
  exit 3
fi

# ---- Read overlay (optional; fail-closed on parse failure) ------------------

OVERLAY_JSON='{}'
if [ -r "$OVERLAY_PATH" ]; then
  OVERLAY_RAW=$(cat "$OVERLAY_PATH")
  if printf '%s' "$OVERLAY_RAW" | jq empty >/dev/null 2>&1; then
    OVERLAY_JSON="$OVERLAY_RAW"
  else
    printf 'foundation-overlay-load.sh: overlay invalid JSON at %s; falling back to foundation-only view (degraded but safe).\n' "$OVERLAY_PATH" >&2
    OVERLAY_JSON='{}'
  fi
fi

# ---- R-52 collision check ---------------------------------------------------
# Spike scope: .frontmatter.types pillar only (aligned with R-32 type-DENY
# retrofit). SP17 generalizes.

if [ "$FORCE_OVERRIDE" != "1" ]; then
  # Collect overlay type slugs that ALSO exist in foundation (collision set).
  # Exclude _description meta key.
  COLLISIONS=$(printf '%s' "$OVERLAY_JSON" | jq -r --argjson f "$FOUNDATION_JSON" '
    (.frontmatter.types // {}) | keys[]?
    | select(. != "_description")
    | select($f.frontmatter.types[.] != null)
  ' 2>/dev/null)

  DENIED_KEYS=""
  if [ -n "$COLLISIONS" ]; then
    while IFS= read -r ck; do
      [ -z "$ck" ] && continue
      # Shape-bridge: per-entry _override_reason OR top-level override_reasons
      HAS_REASON=$(printf '%s' "$OVERLAY_JSON" | jq -r --arg k "$ck" '
        (
          (.frontmatter.types[$k]
           | if type == "object" then ._override_reason else null end
          ) // null
        ) != null
        or
        (
          (.override_reasons.frontmatter.types[$k] // null) != null
        )
      ' 2>/dev/null)
      if [ "$HAS_REASON" != "true" ]; then
        DENIED_KEYS="${DENIED_KEYS}  - frontmatter.types.${ck}\n"
      fi
    done <<EOF
$COLLISIONS
EOF
  fi

  if [ -n "$DENIED_KEYS" ]; then
    {
      printf 'foundation-overlay-load.sh: R-52 violation — overlay shadows foundation entries without _override_reason:\n'
      printf '%b' "$DENIED_KEYS"
      printf 'To resolve, either:\n'
      printf '  (a) add per-entry _override_reason: "<text>" to the shadowing overlay entry, OR\n'
      printf '  (b) add top-level override_reasons.frontmatter.types.<slug>: "<text>" to the overlay, OR\n'
      printf '  (c) pass --force-override for single-invocation bypass (per-write; no persistent disable per ADR-0006).\n'
    } >&2
    exit 1
  fi
fi

# ---- Deep-merge: overlay wins per R-52 --------------------------------------

UNION_JSON=$(printf '%s' "$FOUNDATION_JSON" | jq --argjson o "$OVERLAY_JSON" '. * $o' 2>/dev/null)
if [ -z "$UNION_JSON" ]; then
  printf 'foundation-overlay-load.sh: deep-merge failed\n' >&2
  exit 5
fi

# ---- Emit ------------------------------------------------------------------

if [ -n "$QUERY" ]; then
  printf '%s' "$UNION_JSON" | jq "$QUERY"
else
  printf '%s' "$UNION_JSON" | jq '.'
fi
