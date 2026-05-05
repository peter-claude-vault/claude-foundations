#!/bin/bash
# capability-registry-parity — Audit capability-registry.json against SKILL.md
# headings + on-disk capability scripts. Mechanical-tier; Monday cron.
#
# Landed: Plan 71 SP04 T-9 (2026-04-29). Closes ENFORCEMENT gap "registry
# drift between SKILL.md tables, on-disk scripts, and capability-registry.json
# silently degrades dispatcher invariants." See SP04 spec.md L65/L78/L267/L312.
#
# Audits 4 drift classes per T-9 ACs (SP04 tasks.md L283-286):
#   (a) SKILL.md `## Capability: <name>` headings ↔ registry keys (strict bijection)
#       → registry-parity-bijection-drift
#   (b) Every shipped entry's `script` field points to an existing file
#       (contract-reserved entries excluded — those are documented stubs
#       awaiting implementation)
#       → registry-parity-script-missing
#   (c) Registry `schema_version` matches the current expected value (1)
#       → registry-parity-schema-version-drift
#   (d) Every capability with `emits_findings: true` declares
#       `writes_manifest_subtree` (string or null — key MUST be present)
#       → registry-parity-emits-missing-subtree-field
#
# Usage:
#   capability-registry-parity.sh                 # check (default)
#   capability-registry-parity.sh --check         # explicit
#   capability-registry-parity.sh --dry-run       # summary only, no findings
#
# Env overrides (testing):
#   LIBRARIAN_ROOT_OVERRIDE   — relocate librarian/ root for fixture tests
#   FINDINGS_OUTPUT           — append findings here instead of stdout
#   EXPECTED_SCHEMA_VERSION   — override expected schema_version (default: 1)
#
# Exit codes:
#   0 — capability ran (drift findings emitted as JSON; non-zero finding count
#       does NOT change exit). Report-only per cron-log-architecture pattern.
#   2 — unknown flag
#
# Where it fires:
#   - `/librarian capability-registry-parity` (ad-hoc)
#   - `/librarian librarian-full` (every full scan)
#   - `librarian session-close` Step 2 (drift sweep block)
#   - Monday cron (cron_block: monday) per registry entry
#
# Bash 3.2 clean per R-23.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"

# Derive librarian root from script location; allow override for tests.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBRARIAN_ROOT_DEFAULT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBRARIAN_ROOT="${LIBRARIAN_ROOT_OVERRIDE:-$LIBRARIAN_ROOT_DEFAULT}"

REGISTRY="$LIBRARIAN_ROOT/capability-registry.json"
SKILL_MD="$LIBRARIAN_ROOT/SKILL.md"
CAPABILITIES_DIR="$LIBRARIAN_ROOT/capabilities"

EXPECTED_SCHEMA_VERSION="${EXPECTED_SCHEMA_VERSION:-1}"

# shellcheck source=/dev/null
source "$CLAUDE_HOME_RES/skills/librarian/lib/findings.sh" 2>/dev/null \
  || source "$LIBRARIAN_ROOT/lib/findings.sh"

MODE="check"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)   MODE="check"; shift ;;
    --dry-run) MODE="dry-run"; shift ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "capability-registry-parity: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$REGISTRY" ]]; then
  echo "## Capability Registry Parity (skipped)"
  echo ""
  echo "- registry not found: $REGISTRY"
  exit 0
fi

if ! jq empty "$REGISTRY" >/dev/null 2>&1; then
  if [[ "$MODE" != "dry-run" ]]; then
    emit_finding "registry-parity-invalid-json" "$REGISTRY" \
      "level" "error" \
      "detail" "jq parse failed"
  fi
  echo "## Capability Registry Parity (1 drift)"
  echo ""
  echo "- registry-parity-invalid-json: $REGISTRY"
  exit 0
fi

DRIFT_BIJECTION=0
DRIFT_SCRIPT=0
DRIFT_SCHEMA_VERSION=0
DRIFT_SUBTREE_FIELD=0
REPORT_LINES=""

# ---------------------------------------------------------------------------
# Class (c): schema_version drift
# ---------------------------------------------------------------------------
ACTUAL_SCHEMA=$(jq -r '.schema_version // "missing"' "$REGISTRY")
if [[ "$ACTUAL_SCHEMA" != "$EXPECTED_SCHEMA_VERSION" ]]; then
  DRIFT_SCHEMA_VERSION=$((DRIFT_SCHEMA_VERSION + 1))
  if [[ "$MODE" != "dry-run" ]]; then
    emit_finding "registry-parity-schema-version-drift" "$REGISTRY" \
      "level" "error" \
      "expected" "$EXPECTED_SCHEMA_VERSION" \
      "actual" "$ACTUAL_SCHEMA"
  fi
  REPORT_LINES="${REPORT_LINES}- registry-parity-schema-version-drift: expected=$EXPECTED_SCHEMA_VERSION actual=$ACTUAL_SCHEMA"$'\n'
fi

# ---------------------------------------------------------------------------
# Class (b): script-missing on shipped entries
# ---------------------------------------------------------------------------
while IFS=$'\t' read -r name script; do
  [[ -z "$name" ]] && continue
  if [[ ! -f "$LIBRARIAN_ROOT/$script" ]]; then
    DRIFT_SCRIPT=$((DRIFT_SCRIPT + 1))
    if [[ "$MODE" != "dry-run" ]]; then
      emit_finding "registry-parity-script-missing" "$name" \
        "level" "error" \
        "script" "$script" \
        "expected_path" "$LIBRARIAN_ROOT/$script"
    fi
    REPORT_LINES="${REPORT_LINES}- registry-parity-script-missing: $name → $script"$'\n'
  fi
done < <(jq -r '.capabilities | to_entries[] | select(.value.implementation_status != "spec-only") | [.key, .value.script] | @tsv' "$REGISTRY")

# ---------------------------------------------------------------------------
# Class (d): emits_findings without writes_manifest_subtree key
# (Key MUST be present per ENFORCEMENT-MAP; value may be string or null.)
# ---------------------------------------------------------------------------
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  DRIFT_SUBTREE_FIELD=$((DRIFT_SUBTREE_FIELD + 1))
  if [[ "$MODE" != "dry-run" ]]; then
    emit_finding "registry-parity-emits-missing-subtree-field" "$name" \
      "level" "error" \
      "detail" "emits_findings:true but writes_manifest_subtree key absent"
  fi
  REPORT_LINES="${REPORT_LINES}- registry-parity-emits-missing-subtree-field: $name"$'\n'
done < <(jq -r '.capabilities | to_entries[] | select(.value.emits_findings == true) | select(.value | has("writes_manifest_subtree") | not) | .key' "$REGISTRY")

# ---------------------------------------------------------------------------
# Class (a): SKILL.md ↔ registry strict bijection
# ---------------------------------------------------------------------------
if [[ ! -f "$SKILL_MD" ]]; then
  DRIFT_BIJECTION=$((DRIFT_BIJECTION + 1))
  if [[ "$MODE" != "dry-run" ]]; then
    emit_finding "registry-parity-skill-md-missing" "$SKILL_MD" \
      "level" "error"
  fi
  REPORT_LINES="${REPORT_LINES}- registry-parity-skill-md-missing: $SKILL_MD"$'\n'
else
  REG_KEYS_FILE=$(mktemp -t reg-keys-XXXXXX)
  SKILL_KEYS_FILE=$(mktemp -t skill-keys-XXXXXX)
  trap 'rm -f "$REG_KEYS_FILE" "$SKILL_KEYS_FILE"' EXIT

  jq -r '.capabilities | keys[]' "$REGISTRY" | sort -u > "$REG_KEYS_FILE"
  grep -E "^## Capability: " "$SKILL_MD" | sed 's/^## Capability: //' | sort -u > "$SKILL_KEYS_FILE"

  # Headings present in SKILL.md but missing from registry.
  while IFS= read -r heading; do
    [[ -z "$heading" ]] && continue
    DRIFT_BIJECTION=$((DRIFT_BIJECTION + 1))
    if [[ "$MODE" != "dry-run" ]]; then
      emit_finding "registry-parity-bijection-drift" "$heading" \
        "level" "error" \
        "direction" "skill-md-without-registry-entry"
    fi
    REPORT_LINES="${REPORT_LINES}- registry-parity-bijection-drift: $heading (SKILL.md heading without registry entry)"$'\n'
  done < <(comm -23 "$SKILL_KEYS_FILE" "$REG_KEYS_FILE")

  # Registry keys missing from SKILL.md.
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    DRIFT_BIJECTION=$((DRIFT_BIJECTION + 1))
    if [[ "$MODE" != "dry-run" ]]; then
      emit_finding "registry-parity-bijection-drift" "$key" \
        "level" "error" \
        "direction" "registry-entry-without-skill-md-heading"
    fi
    REPORT_LINES="${REPORT_LINES}- registry-parity-bijection-drift: $key (registry entry without SKILL.md heading)"$'\n'
  done < <(comm -13 "$SKILL_KEYS_FILE" "$REG_KEYS_FILE")
fi

TOTAL=$((DRIFT_BIJECTION + DRIFT_SCRIPT + DRIFT_SCHEMA_VERSION + DRIFT_SUBTREE_FIELD))
printf "## Capability Registry Parity (%d drift: bijection=%d script=%d schema-version=%d subtree-field=%d)\n\n" \
  "$TOTAL" "$DRIFT_BIJECTION" "$DRIFT_SCRIPT" "$DRIFT_SCHEMA_VERSION" "$DRIFT_SUBTREE_FIELD"
if [[ -n "$REPORT_LINES" ]]; then
  printf '%s' "$REPORT_LINES"
else
  echo "- No drift detected."
fi
