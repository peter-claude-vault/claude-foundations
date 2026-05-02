#!/bin/bash
# tests/e2e-scenario.sh
#
# T-7a in-container scenario script. Runs INSIDE sp00-isolation Lima
# container. Source-repo is staged at /source-repo by the host-side driver
# (tests/e2e-lima-dogfood.sh) via tar pipe; this scenario reads from it,
# performs install → adopt → librarian-cron-fire → uninstall → grep-audit,
# emits per-phase exit codes to /results/phases.json, and tar-pipes
# /results to stdout for host-side capture.
#
# Onboarder Section A-E flow is NOT exercised in T-7a — pre-stages
# user-manifest.json fixture (Alex archetype) per the SP01 dogfood
# pattern. Real onboarder via Claude Code in image is deferred to T-7b
# CFF-S87-1.
#
# R-23 bash 3.2 compat.

set -uo pipefail
mkdir -p /results
SOURCE=/home/tester/source-repo
TEST_HOME=/home/tester
CLAUDE_HOME=$TEST_HOME/.claude
PLANS_HOME=$TEST_HOME/.claude-plans

# --- Pre-stage user-manifest.json fixture (Alex archetype) ---
mkdir -p "$CLAUDE_HOME"
cat > "$CLAUDE_HOME/user-manifest.json" <<MANIFEST
{
  "system": {
    "schema_version": "1.5.0",
    "timezone": "America/New_York",
    "phases_completed": ["A","B","C","D","E"],
    "completion_state": {},
    "opt_outs": []
  },
  "identity": {
    "name": "Alex Archetype",
    "email": "alex@example.org",
    "role": "Senior Strategy Lead",
    "industry": "Management Consulting",
    "seniority": "Senior",
    "organization": "Northwind Strategy Partners",
    "working_hours": "9am-6pm Eastern"
  },
  "vault": {
    "root": "$TEST_HOME/vault",
    "is_fresh": true,
    "organizational_method": "engagement-based",
    "top_level_folder": "Engagements",
    "default_audience": "team",
    "has_structured_projects": true,
    "canonical_file_types": null,
    "tag_prefixes": []
  },
  "paths": {
    "vault_root": "$TEST_HOME/vault",
    "claude_home": "$CLAUDE_HOME",
    "plans_home": "$PLANS_HOME"
  }
}
MANIFEST
mkdir -p "$TEST_HOME/vault"

# --- Phase 2: install.sh ---
{
  echo "=== install.sh ==="
  CLAUDE_HOME="$CLAUDE_HOME" PLANS_HOME="$PLANS_HOME" \
    SOURCE_REPO="$SOURCE" \
    bash "$SOURCE/install.sh" --apply --force-install 2>&1
  rc=$?
  echo "INSTALL_RC=$rc"
} > /results/install.log 2>&1
INSTALL_RC=$(grep -E '^INSTALL_RC=' /results/install.log | cut -d= -f2)

# --- Phase 3: adopt.sh ---
{
  echo "=== adopt.sh ==="
  CLAUDE_HOME="$CLAUDE_HOME" PLANS_HOME="$PLANS_HOME" HOME="$TEST_HOME" \
    bash "$SOURCE/skills/adopt/adopt.sh" --force-install 2>&1
  rc=$?
  echo "ADOPT_RC=$rc"
} > /results/adopt.log 2>&1
ADOPT_RC=$(grep -E '^ADOPT_RC=' /results/adopt.log | cut -d= -f2)

# --- Phase 4: librarian-cron simulated fire (mock-launchctl) ---
{
  echo "=== librarian-cron simulated fire ==="
  PLIST=""
  for cand in \
    "$CLAUDE_HOME/Library/LaunchAgents/com.claude-foundations.librarian.plist" \
    "$TEST_HOME/Library/LaunchAgents/com.claude-foundations.librarian.plist"; do
    [ -f "$cand" ] && { PLIST="$cand"; break; }
  done
  if [ -z "$PLIST" ]; then
    echo "(no librarian plist found post-install; falling back to template)"
    PLIST="$SOURCE/templates/launchd/librarian.plist.tmpl"
  fi
  echo "plist: $PLIST"
  launchctl bootstrap gui/1000 "$PLIST" 2>&1
  rc=$?
  echo "CRON_BOOT_RC=$rc"
  echo "--- launchctl-trace.ndjson ---"
  if [ -s /results/launchctl-trace.ndjson ]; then
    cat /results/launchctl-trace.ndjson
    echo "TRACE_BYTES=$(wc -c < /results/launchctl-trace.ndjson)"
  else
    echo "TRACE_BYTES=0"
  fi
} > /results/cron.log 2>&1
CRON_BOOT_RC=$(grep -E '^CRON_BOOT_RC=' /results/cron.log | cut -d= -f2)
TRACE_BYTES=$(grep -E '^TRACE_BYTES=' /results/cron.log | tail -1 | cut -d= -f2)

# --- Phase 5: uninstall.sh --full ---
{
  echo "=== uninstall.sh --full ==="
  echo "--- pre-uninstall inventory ---"
  ls -la "$CLAUDE_HOME/" 2>&1 | head -30
  echo "--- running uninstall.sh --full ---"
  CLAUDE_HOME="$CLAUDE_HOME" PLANS_HOME="$PLANS_HOME" HOME="$TEST_HOME" \
    LAUNCHCTL_BIN=/usr/local/bin/launchctl \
    bash "$SOURCE/uninstall.sh" --full 2>&1
  rc=$?
  echo "UNINSTALL_RC=$rc"
  echo "--- post-uninstall residue (foundation files) ---"
  surv=0
  for entry in hooks skills schemas onboarding orchestrator templates plugins installer logs settings.json settings.local.json foundation-manifest.json; do
    if [ -e "$CLAUDE_HOME/$entry" ]; then
      echo "RESIDUE: $entry"
      surv=$((surv+1))
    fi
  done
  echo "RESIDUE_COUNT=$surv"
} > /results/uninstall.log 2>&1
UNINSTALL_RC=$(grep -E '^UNINSTALL_RC=' /results/uninstall.log | cut -d= -f2)
RESIDUE_COUNT=$(grep -E '^RESIDUE_COUNT=' /results/uninstall.log | cut -d= -f2)

# --- Phase 6: SP00 grep-audit on /results ---
{
  echo "=== grep-audit /results ==="
  cd /
  GREP_AUDIT_SKIP_LAYER4=1 bash "$SOURCE/tests/grep-audit.sh" results 2>&1
} > /results/grep-audit.log 2>&1
GA_LAST=$(tail -n 1 /results/grep-audit.log)
GA_HITS=$(printf '%s' "$GA_LAST" | grep -oE '"hits_total":[0-9]+' | cut -d: -f2)

# --- Emit phases.json ---
cat > /results/phases.json <<JSON
{
  "schema": "e2e-lima-dogfood-phases.v1",
  "completed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "install_rc": ${INSTALL_RC:-null},
  "adopt_rc": ${ADOPT_RC:-null},
  "cron_boot_rc": ${CRON_BOOT_RC:-null},
  "cron_trace_bytes": ${TRACE_BYTES:-0},
  "uninstall_rc": ${UNINSTALL_RC:-null},
  "uninstall_residue_count": ${RESIDUE_COUNT:-99},
  "grep_audit_hits_total": ${GA_HITS:-99},
  "grep_audit_last_line": "$(printf '%s' "$GA_LAST" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}
JSON

# --- tar /results to stdout for host-side capture ---
cd /results && tar -c .
