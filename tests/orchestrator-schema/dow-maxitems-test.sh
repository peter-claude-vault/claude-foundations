#!/usr/bin/env bash
# tests/orchestrator-schema/dow-maxitems-test.sh
# Negative test for orchestration-schema.json: schedule.dow must be at most one element.
# The renderer reads dow[0] and the architect plist template carries one Weekday slot;
# a multi-element dow array would silently drop subsequent days. The schema's
# maxItems: 1 constraint catches this at validation time.
#
# Pass criteria:
#   - A single-element dow ([1]) validates clean.
#   - A multi-element dow ([1,2,3,4,5]) is rejected by the validator.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCHEMA="$REPO_ROOT/schemas/orchestration-schema.json"

if [ ! -f "$SCHEMA" ]; then
  echo "FAIL: schema not found at $SCHEMA" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap "rm -rf $WORK" EXIT

# Test fixture: single-element dow (must validate)
cat >"$WORK/single.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "platform": "darwin-launchd",
  "jobs": [
    {
      "id": "test-job",
      "enabled": false,
      "command": "/bin/true",
      "idle_watchdog_sec": 180,
      "schedule": {
        "hour": 6,
        "minute": 0,
        "dow": [1]
      }
    }
  ],
  "tripwires": [],
  "observability": {
    "morning_brief_staleness_h": 24,
    "librarian_staleness_h": 24,
    "sessionstart_banner_staleness_h": 24
  }
}
JSON

# Test fixture: multi-element dow (must FAIL validation)
cat >"$WORK/multi.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "platform": "darwin-launchd",
  "jobs": [
    {
      "id": "test-job",
      "enabled": false,
      "command": "/bin/true",
      "idle_watchdog_sec": 180,
      "schedule": {
        "hour": 6,
        "minute": 0,
        "dow": [1, 2, 3, 4, 5]
      }
    }
  ],
  "tripwires": [],
  "observability": {
    "morning_brief_staleness_h": 24,
    "librarian_staleness_h": 24,
    "sessionstart_banner_staleness_h": 24
  }
}
JSON

# Validation engine selection: prefer ajv if on PATH, fall back to a
# python json-schema check. If neither is available, skip with a warning
# rather than fail (foundation-repo runs hermetically; CI has at least
# python3 + jsonschema).
have_ajv=0
have_python_jsonschema=0
if command -v ajv >/dev/null 2>&1; then
  have_ajv=1
elif command -v python3 >/dev/null 2>&1 && python3 -c "import jsonschema" 2>/dev/null; then
  have_python_jsonschema=1
else
  echo "SKIP: no ajv or python3-jsonschema available" >&2
  exit 0
fi

validate() {
  local instance="$1"
  if [ "$have_ajv" -eq 1 ]; then
    ajv validate -s "$SCHEMA" -d "$instance" --strict=false >/dev/null 2>&1
    return $?
  fi
  python3 - "$SCHEMA" "$instance" <<'PY'
import json, sys
import jsonschema
schema = json.load(open(sys.argv[1]))
instance = json.load(open(sys.argv[2]))
try:
    jsonschema.validate(instance, schema)
    sys.exit(0)
except jsonschema.ValidationError:
    sys.exit(1)
PY
}

fail=0

if validate "$WORK/single.json"; then
  echo "PASS: single-element dow validates clean"
else
  echo "FAIL: single-element dow ([1]) was rejected; should have validated" >&2
  fail=1
fi

if validate "$WORK/multi.json"; then
  echo "FAIL: multi-element dow ([1,2,3,4,5]) was accepted; schema should reject (maxItems: 1)" >&2
  fail=1
else
  echo "PASS: multi-element dow rejected by schema"
fi

exit "$fail"
