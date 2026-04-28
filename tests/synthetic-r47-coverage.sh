#!/usr/bin/env bash
# synthetic-r47-coverage.sh — SP02 T-10 commit 3.
#
# INAPPLICABILITY STUB. Foundation pre-write-guard.sh dropped both R-47 (tag
# presence advisory) and R-32 tag-prefix DENY in T-4. Both depended on the
# adopter-specific tag taxonomy (eight hashtag prefixes documented in
# DROPPED-RULES.md) that foundation has no generic equivalent for.
#
# Foundation R-32 retained: type-allowlist DENY only (covered by
# tests/pre-write-guard-r-rules.sh test 10).
#
# This stub preserves the brief's deliverable name + slot, exits 0, and
# documents where the dropped semantics live.
#
# References:
#   - hooks/DROPPED-RULES.md §"Peter-workflow-specific" (R-47..R-49)
#   - hooks/pre-write-guard.sh L24 (R-rule enumeration; no R-47 line)
#   - tests/pre-write-guard-r-rules.sh test 10 (R-32 type-allowlist DENY,
#     which IS in scope)
#
# Bash 3.2 compatible (R-23).

set -u

cat <<'EOF'
synthetic-r47-coverage.sh — INAPPLICABILITY STUB

R-47 (tag presence advisory) and R-32 tag-prefix DENY were dropped from
foundation pre-write-guard.sh in SP02 T-4 — both depend on an adopter-
specific tag taxonomy that foundation does not generalize.

Foundation retains R-32 type-allowlist DENY; that path is covered by
tests/pre-write-guard-r-rules.sh test 10.

See hooks/DROPPED-RULES.md §"Peter-workflow-specific" for the full rationale.
EOF

exit 0
