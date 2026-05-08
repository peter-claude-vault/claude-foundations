#!/bin/bash
# active-gates-rebuild.sh — librarian capability (Plan 80/81 SP01 T-8 stub
# with T-3.5 --plans-root contract honored).
#
# Walks plan-tree manifests; extracts live_mutation_scope blocks where
# enabled=true; emits a flat active-gates.json read-replica consumed by
# live-guard.sh fast-path. Compile-time scope-overlap detection (T-8 full)
# rejects regen if two plans claim overlapping scope_paths (per Agent 2's
# k8s/VS Code lesson — never punt scope conflict to runtime in security gate).
#
# T-3.5 contract (this build):
#   --plans-root <path>  Override $HOME/.claude-plans walk root. PEER to
#                        live-guard.sh's PLANS_ROOT_OVERRIDE env var (must
#                        produce symmetric resolution; SP08 fixture
#                        `manifest_mechanism_extensibility` and
#                        `live_guard_root_resolution_determinism` assert
#                        this contract structurally — no coincidental pass).
#   --output <path>      Override default output path (~/.claude/state/active-gates.json).
#   --schema-version <v> Force schema_version field; default 1.
#
# Output shape:
#   {
#     schema_version: 1,
#     regenerated_at: "<iso8601>",
#     regenerated_by: "active-gates-rebuild.sh",
#     plans_root: "<resolved>",
#     scope_overlap_check: "passed" | "FAILED" | "deferred-to-T-8",
#     gates: [<live_mutation_scope-with-plan_id>, ...]
#   }
#
# T-8 deferred work:
#   - Strict scope-overlap detection across enabled gates (currently emits
#     "deferred-to-T-8"; runtime conflict resolution remains in live-guard's
#     first-match-wins ordering until T-8 promotes to compile-time fail).
#   - Sub-plan UNION merging (inherits_from): scope_paths/exempt_paths/
#     launchd_labels/g2_commit_denylist UNION with master.
#   - Schema validation against gate-config-schema.json + plan-manifest-schema.json.
#   - mtime-stale-vs-manifest cache invalidation contract.

set -uo pipefail

# === Arg parsing ==========================================================
PLANS_ROOT="${PLANS_ROOT_OVERRIDE:-${PLANS_DIR:-$HOME/.claude-plans}}"
OUTPUT_PATH=""
SCHEMA_VERSION=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plans-root)
      PLANS_ROOT="$2"; shift 2 ;;
    --output)
      OUTPUT_PATH="$2"; shift 2 ;;
    --schema-version)
      SCHEMA_VERSION="$2"; shift 2 ;;
    -h|--help)
      sed -n 's/^# \{0,1\}//p' "$0" | head -40
      exit 0 ;;
    *)
      echo "active-gates-rebuild: unknown arg: $1" >&2
      exit 2 ;;
  esac
done

# Resolve default output path AFTER plans-root so test-overrides land somewhere
# sensible. Default: $HOME/.claude/state/active-gates.json.
if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="${ACTIVE_GATES_PATH:-$HOME/.claude/state/active-gates.json}"
fi

OUTPUT_DIR=$(dirname "$OUTPUT_PATH")
mkdir -p "$OUTPUT_DIR" 2>/dev/null || true

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# === Walk plan manifests, collect enabled gates ===========================
GATES_JSON='[]'

if [[ -d "$PLANS_ROOT" ]]; then
  for manifest in "$PLANS_ROOT"/*/manifest.json; do
    [[ -e "$manifest" ]] || continue
    plan_slug=$(basename "$(dirname "$manifest")")

    gate=$(jq -c --arg plan_id "$plan_slug" '
      select((.live_mutation_scope.enabled // false) == true)
      | .live_mutation_scope + {plan_id: $plan_id}
    ' "$manifest" 2>/dev/null || echo "")

    [[ -z "$gate" ]] && continue
    GATES_JSON=$(echo "$GATES_JSON" | jq -c --argjson g "$gate" '. + [$g]')
  done

  # T-8 will scan sub-plan manifests at ~/.claude-plans/<plan>/<NN-*>/manifest.json
  # and UNION-merge into parent's gate. Stub here walks only top-level for now.
fi

# === Compile-time scope-overlap detection (T-8 strict; deferred here) =====
# T-8 will implement: for each pair of enabled gates, compute
# scope_paths intersection; non-empty intersection = drift finding; regen FAILS.
# Stub returns "deferred-to-T-8" — runtime gate evaluation in live-guard.sh
# uses first-match-wins ordering as interim fallback.
SCOPE_OVERLAP_CHECK="deferred-to-T-8"

# === Emit read-replica ===================================================
jq -n \
  --argjson schema_version "$SCHEMA_VERSION" \
  --arg ts "$TS" \
  --arg plans_root "$PLANS_ROOT" \
  --arg overlap "$SCOPE_OVERLAP_CHECK" \
  --argjson gates "$GATES_JSON" \
  '{
    schema_version: $schema_version,
    regenerated_at: $ts,
    regenerated_by: "active-gates-rebuild.sh",
    plans_root: $plans_root,
    scope_overlap_check: $overlap,
    gates: $gates
  }' > "$OUTPUT_PATH"

echo "active-gates-rebuild: wrote $OUTPUT_PATH (plans_root=$PLANS_ROOT, gates=$(echo "$GATES_JSON" | jq -r 'length'))"
exit 0
