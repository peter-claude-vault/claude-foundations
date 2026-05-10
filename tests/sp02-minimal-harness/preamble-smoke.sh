#!/bin/bash
# tests/sp02-minimal-harness/preamble-smoke.sh — minimal end-to-end smoke for
# SP02 preamble deliverables.
#
# Scope: structural smoke only. Resolves SP02 OQ-1.
#
# Validates the 5 acceptance criteria from
# ~/.claude-plans/81-claude-stem-dogfood-optimization/02-foundation-framing/tasks.md T-10:
#
#   AC1 — Preamble end-to-end smoke runs (this script returns 0 on green).
#   AC2 — All 5 blocks fire in sequence (block files exist at canonical paths,
#         frontmatter declares correct block N of 5 + flow_step 1, render
#         order matches fixtures/expected-render-order.txt).
#   AC3 — Informed-consent gate enforced (Block 4 declares the "no disk write
#         before consent" render contract, lists all 3 pre-reqs verbatim,
#         carries honest-degradation framing).
#   AC4 — Hand-off to step 2 clean (Block 5 explicitly hands off step 1 → 2,
#         names the next 6 steps of the T4 §3.6 7-step flow).
#   AC5 — Hands off to SP08 full-harness scope (this file declares smoke-only
#         scope and points at the SP08 harness contract).
#
# What this smoke test does NOT do (intentionally — those belong to SP06+SP08):
#   - Does not invoke a renderer. The blocks are content; SP06 builds the
#     wizard that consumes them. Until SP06 lands, "render" means "file
#     exists with the right shape."
#   - Does not validate runtime gate enforcement. The Block 4 render contract
#     says "no disk write before consent" — proving that property at runtime
#     requires SP06's wizard. SP06 must ship its own negative-test suite per
#     the contract in block-4-consent.md §Render contract negative tests.
#   - Does not score articulation. The 6-criteria articulation set in
#     mental-model.md §Articulation success criteria is the SP08 dogfood
#     harness target.
#
# Hermetic: read-only validation against repo-canonical paths. No state
# mutation, no network, no temp dirs.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREAMBLE_DIR="$REPO_ROOT/skills/onboarder/preamble"
RESEARCH_DIR="$REPO_ROOT/research/vault-construction"
SETUP_DIR="$RESEARCH_DIR/setup-directions"
FIXTURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/fixtures" && pwd)"

PASS=0
FAIL=0
declare -a FAILURES=()

assert_file_exists() {
    local path="$1"
    local label="$2"
    if [[ -f "$path" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILURES+=("$label: missing file $path")
    fi
}

assert_file_contains() {
    local path="$1"
    local pattern="$2"
    local label="$3"
    if [[ ! -f "$path" ]]; then
        FAIL=$((FAIL + 1))
        FAILURES+=("$label: file does not exist: $path")
        return
    fi
    if grep -q -F "$pattern" "$path"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILURES+=("$label: pattern not found in $path: '$pattern'")
    fi
}

assert_file_matches() {
    local path="$1"
    local pattern="$2"
    local label="$3"
    if [[ ! -f "$path" ]]; then
        FAIL=$((FAIL + 1))
        FAILURES+=("$label: file does not exist: $path")
        return
    fi
    if grep -q -E "$pattern" "$path"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILURES+=("$label: regex not found in $path: '$pattern'")
    fi
}

# AC2 — All 5 preamble blocks present at canonical paths.
BLOCK_1="$PREAMBLE_DIR/block-1-house-metaphor.md"
BLOCK_2="$PREAMBLE_DIR/block-2-architecture.md"
BLOCK_3="$PREAMBLE_DIR/block-3-patterns.md"
BLOCK_4="$PREAMBLE_DIR/block-4-consent.md"
BLOCK_5="$PREAMBLE_DIR/block-5-bridge.md"

assert_file_exists "$BLOCK_1" "AC2 Block 1 file presence"
assert_file_exists "$BLOCK_2" "AC2 Block 2 file presence"
assert_file_exists "$BLOCK_3" "AC2 Block 3 file presence"
assert_file_exists "$BLOCK_4" "AC2 Block 4 file presence"
assert_file_exists "$BLOCK_5" "AC2 Block 5 file presence"

# AC2 — Frontmatter declares block N of 5 + flow_step 1.
assert_file_matches "$BLOCK_1" "^block: 1$" "AC2 Block 1 frontmatter block:1"
assert_file_matches "$BLOCK_2" "^block: 2$" "AC2 Block 2 frontmatter block:2"
assert_file_matches "$BLOCK_3" "^block: 3$" "AC2 Block 3 frontmatter block:3"
assert_file_matches "$BLOCK_4" "^block: 4$" "AC2 Block 4 frontmatter block:4"
assert_file_matches "$BLOCK_5" "^block: 5$" "AC2 Block 5 frontmatter block:5"
for B in "$BLOCK_1" "$BLOCK_2" "$BLOCK_3" "$BLOCK_4" "$BLOCK_5"; do
    assert_file_matches "$B" "^of: 5$" "AC2 $(basename "$B") frontmatter of:5"
    assert_file_matches "$B" "^flow_step: 1$" "AC2 $(basename "$B") frontmatter flow_step:1"
    assert_file_matches "$B" "^mode: personalized-output$" "AC2 $(basename "$B") frontmatter mode"
done

# AC2 — Render order matches the fixture (sequential 1..5 by frontmatter).
EXPECTED_ORDER_FILE="$FIXTURES_DIR/expected-render-order.txt"
if [[ -f "$EXPECTED_ORDER_FILE" ]]; then
    ACTUAL_ORDER=$(for B in "$BLOCK_1" "$BLOCK_2" "$BLOCK_3" "$BLOCK_4" "$BLOCK_5"; do
        basename "$B"
    done)
    EXPECTED_ORDER=$(cat "$EXPECTED_ORDER_FILE")
    if [[ "$ACTUAL_ORDER" == "$EXPECTED_ORDER" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILURES+=("AC2 render order mismatch — expected:\n$EXPECTED_ORDER\nactual:\n$ACTUAL_ORDER")
    fi
else
    FAIL=$((FAIL + 1))
    FAILURES+=("AC2 fixtures/expected-render-order.txt missing")
fi

# AC2 — Block 1 contains the canonical house-metaphor opening (verbatim per packet §5).
assert_file_contains "$BLOCK_1" "Think of this as moving into a new house" "AC2 Block 1 verbatim opening"
assert_file_contains "$BLOCK_1" "autonomously runs work for you when you are not watching" "AC2 Block 1 closing-line orchestration framing"

# AC2 — Block 2 renders the canonical four pillars + directional verbs.
assert_file_contains "$BLOCK_2" "CONNECTORS" "AC2 Block 2 CONNECTORS pillar"
assert_file_contains "$BLOCK_2" "PROCESSING" "AC2 Block 2 PROCESSING pillar"
assert_file_contains "$BLOCK_2" "MEMORY" "AC2 Block 2 MEMORY pillar"
assert_file_contains "$BLOCK_2" "CONTENT" "AC2 Block 2 CONTENT pillar"
assert_file_contains "$BLOCK_2" "builds out" "AC2 Block 2 directional verb builds out"
assert_file_contains "$BLOCK_2" "enables" "AC2 Block 2 directional verb enables"

# AC2 — Block 3 names both UX primitives + cross-refs compliance tiers.
assert_file_contains "$BLOCK_3" "Propose-and-confirm" "AC2 Block 3 propose-and-confirm name"
assert_file_contains "$BLOCK_3" "Soft-mandate" "AC2 Block 3 soft-mandate name"
assert_file_contains "$BLOCK_3" "compliance tiers" "AC2 Block 3 compliance-tier cross-ref"

# AC3 — Block 4 lists all 3 pre-reqs verbatim.
assert_file_contains "$BLOCK_4" "Obsidian" "AC3 Block 4 pre-req: Obsidian"
assert_file_contains "$BLOCK_4" "claude-mem plugin" "AC3 Block 4 pre-req: claude-mem"
assert_file_contains "$BLOCK_4" "GitHub repo for backups" "AC3 Block 4 pre-req: GitHub backup"

# AC3 — Block 4 carries honest-degradation framing.
assert_file_contains "$BLOCK_4" "meaningfully degraded experience and reduced safety net" \
    "AC3 Block 4 honest-degradation phrase verbatim"

# AC3 — Block 4 declares the render contract for SP06.
assert_file_contains "$BLOCK_4" "Render contract for SP06" "AC3 Block 4 render contract section"
assert_file_contains "$BLOCK_4" "Gate fires before any disk write" \
    "AC3 Block 4 contract clause: gate fires before disk write"
assert_file_contains "$BLOCK_4" "Skip path is coherent" \
    "AC3 Block 4 contract clause: skip path coherent"

# AC3 — Block 4 declares ownership (SP02 OWNS, SP06 RENDERS).
assert_file_contains "$BLOCK_4" "SP02 OWNS this gate" "AC3 Block 4 ownership declaration"

# AC3 — Block 4 surfaces personalized-output mode binding.
assert_file_contains "$BLOCK_4" "Personalized-output mode" "AC3 Block 4 personalized-output mode binding"

# AC4 — Block 5 hands off step 1 → step 2.
assert_file_contains "$BLOCK_5" "completed step 1 of the 7-step onboarding flow" \
    "AC4 Block 5 step-1-completed declaration"
assert_file_contains "$BLOCK_5" "File drop" "AC4 Block 5 next-step name"
assert_file_contains "$BLOCK_5" "hands_off_to: SP06" "AC4 Block 5 frontmatter handoff"

# AC4 — Block 5 names the remaining 6 steps so the 7-step flow positioning is explicit.
for STEP_LABEL in "File drop" "Background research" "Onboarding Q&A" \
                  "Background re-synthesis" "Final vault architecture" \
                  "Scaffold execution"; do
    assert_file_contains "$BLOCK_5" "$STEP_LABEL" "AC4 Block 5 step preview: $STEP_LABEL"
done

# Canonical research docs (T-1, T-2 deliverables) present.
assert_file_exists "$RESEARCH_DIR/mental-model.md" "T-1 mental-model.md present"
assert_file_exists "$RESEARCH_DIR/ux-primitives.md" "T-2 ux-primitives.md present"
assert_file_matches "$RESEARCH_DIR/mental-model.md" "^altitude: system$" \
    "T-1 mental-model.md altitude=system"
assert_file_matches "$RESEARCH_DIR/ux-primitives.md" "^altitude: system$" \
    "T-2 ux-primitives.md altitude=system"

# Setup-direction docs (T-8 deliverables) present.
assert_file_exists "$SETUP_DIR/obsidian-setup.md" "T-8 obsidian-setup.md present"
assert_file_exists "$SETUP_DIR/claude-mem-setup.md" "T-8 claude-mem-setup.md present"
assert_file_exists "$SETUP_DIR/github-backup-setup.md" "T-8 github-backup-setup.md present"

# Anti-patterns callouts (T-9 deliverable) present.
assert_file_exists "$PREAMBLE_DIR/anti-patterns.md" "T-9 anti-patterns.md present"
for AP in "This is just a vault setup tool" \
          "Do I need to use all of this" \
          "Why does Claude need a memory layer if I have a vault" \
          "Is this Obsidian's system or Claude's" \
          "What if my work doesn't fit one of the archetypes"; do
    assert_file_contains "$PREAMBLE_DIR/anti-patterns.md" "$AP" "T-9 anti-pattern surfaced: $AP"
done

# AC5 — This file declares smoke-only scope and points at SP08 full-harness.
SELF_PATH="${BASH_SOURCE[0]}"
assert_file_contains "$SELF_PATH" "SP08" "AC5 self-declares SP08 hand-off"
assert_file_contains "$SELF_PATH" "smoke" "AC5 self-declares smoke scope"

# Report.
TOTAL=$((PASS + FAIL))
if [[ $FAIL -eq 0 ]]; then
    printf 'sp02-preamble-smoke: PASS (%d/%d assertions)\n' "$PASS" "$TOTAL"
    exit 0
else
    printf 'sp02-preamble-smoke: FAIL (%d/%d assertions)\n' "$PASS" "$TOTAL" >&2
    printf '\nFailures:\n' >&2
    for F in "${FAILURES[@]}"; do
        printf '  - %s\n' "$F" >&2
    done
    exit 1
fi
