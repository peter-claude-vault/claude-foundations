#!/usr/bin/env bash
# bootstrap-schemas.sh — SP01 T-10 (Plan 71 SP01 Session 11)
#
# OUTPUT CONTRACT (R-43):
#   Files written (atomic tmp+rename):
#     1. ~/.claude/schemas/plans-schema.json   (STATIC — verified, no transform)
#     2. ~/.claude/user-manifest.json          (POPULATED instance)
#     3. ~/.claude/schemas/vault-schema.json   (PASS-THROUGH — archetype-seed
#                                                merge deferred; q-field-map
#                                                has no direct vault-schema
#                                                target paths)
#     4. ~/.claude/orchestration.json          (POPULATED instance)
#   Audit log (append-only):
#     ~/.claude/onboarding/bootstrap-log.jsonl
#       Per-field record: {ts, run_id, q_id, section_id, path, value,
#                          confidence, source_span}
#     Run terminator: {ts, run_id, status: BOOTSTRAP_COMPLETED|BOOTSTRAP_FAILED}
#
#   Schema-types declared:
#     - plans-schema instance:    JSON Schema (Draft-07) — ajv compile only
#     - user-manifest instance:   ~/.claude/schemas/user-manifest-schema.json
#     - vault-schema instance:    structural — top-level keys + _tag_prefixes
#                                 array shape (vault-schema.json is itself a
#                                 type-registry, not a JSON-Schema doc)
#     - orchestration instance:   ~/.claude/schemas/orchestration-schema.json
#
#   Pre-write validation:
#     For each output: validate populated instance against its schema-type.
#     Validator: `ajv` when on PATH; otherwise jq structural fallback
#     (top-level required keys + JSON parseability).
#
#   Failure mode: BLOCK AND LOG.
#     Any validation/parse/IO failure ⇒ rollback all *.tmp files in this
#     run, append a {status: BOOTSTRAP_FAILED} terminator to the audit log,
#     exit non-zero. Live targets remain untouched (atomic semantics).
#
#   Idempotency:
#     If a target file already exists and bytes match the would-write
#     payload, skip the rename and audit-log a "skip-identical" record.
#     If they differ and --force is NOT supplied, write a side-by-side
#     <target>.new file + emit a unified diff summary on stderr; exit 1.
#     With --force, overwrite the live target atomically.
#
# USAGE:
#   bootstrap-schemas.sh [--force] [--dry-run] [--inputs-dir DIR]
#                        [--schemas-dir DIR] [--ajv-bin PATH]
#                        [--audit-log PATH]
#
#   --force          overwrite differing targets (default: write .new + diff)
#   --dry-run        emit unified diff per output (current vs would-write) +
#                    "no-op (byte-match)" for idempotent targets; performs
#                    ZERO filesystem mutations to live targets or the audit
#                    log (TMPDIR scratch is exempt — outside live targets and
#                    cleaned by EXIT trap). The validator pipeline STILL runs
#                    under --dry-run (deliberate non-bypass: dry-run is for
#                    debugging, not for skipping pre-write validation). Exits
#                    0 on success or no-op; 1 on parse/validate failure (no
#                    audit append); 2 is never emitted under --dry-run.
#   --inputs-dir     where extraction-output-{A..E}.json live
#                    (default: ~/.claude/onboarding)
#   --schemas-dir    where {user-manifest,vault,orchestration,plans}-schema.json live
#                    (default: ~/.claude/schemas)
#   --ajv-bin        path to ajv binary (default: search PATH)
#   --audit-log      JSONL audit log destination
#                    (default: ~/.claude/onboarding/bootstrap-log.jsonl)
#
# CONSTRAINTS (R-23):
#   bash 3.2.57 — no `declare -A`, no `mapfile`/`readarray`, no `${var,,}`.
#   `jq` required on PATH; `ajv` optional.
#
# Critical engine surfaces (per T-9 hand-off contract):
#   C-3 idempotent dedupe on U.system.opt_outs[] before append
#   D-2 mutual exclusion: O.jobs[0].id (string) XOR O.jobs == []
#   D-3 archetype-prefix prepend + comma-join, double-append safe
#   D-4 default "digest" applied when extraction omits notification_style
#   A/E deterministic write paths bypass model invocation entirely
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP01 Session 11
set -u
LC_ALL=C

# --- argument parsing ---
FORCE=0
DRY_RUN=0
INPUTS_DIR="${HOME}/.claude/onboarding"
SCHEMAS_DIR="${HOME}/.claude/schemas"
AUDIT_LOG="${HOME}/.claude/onboarding/bootstrap-log.jsonl"
AJV_BIN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --inputs-dir) INPUTS_DIR="$2"; shift 2 ;;
        --schemas-dir) SCHEMAS_DIR="$2"; shift 2 ;;
        --ajv-bin) AJV_BIN="$2"; shift 2 ;;
        --audit-log) AUDIT_LOG="$2"; shift 2 ;;
        -h|--help) sed -n '2,65p' "$0"; exit 0 ;;
        *) echo "bootstrap-schemas: unknown arg: $1" >&2; exit 2 ;;
    esac
done

# --- preflight ---
command -v jq >/dev/null 2>&1 || { echo "bootstrap-schemas: jq not on PATH" >&2; exit 2; }
[ -d "$INPUTS_DIR" ]   || { echo "bootstrap-schemas: inputs dir not found: $INPUTS_DIR" >&2; exit 2; }
[ -d "$SCHEMAS_DIR" ]  || { echo "bootstrap-schemas: schemas dir not found: $SCHEMAS_DIR" >&2; exit 2; }
[ -f "$INPUTS_DIR/q-field-map.json" ] || { echo "bootstrap-schemas: q-field-map.json missing" >&2; exit 2; }

if [ -z "$AJV_BIN" ] && command -v ajv >/dev/null 2>&1; then
    AJV_BIN="$(command -v ajv)"
fi

# --- run constants ---
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-schemas.XXXXXX")"
WROTE_TMPS=""
EXIT_STATUS=0

# Audit log helpers (append-only). Skip directory creation under --dry-run
# to preserve the zero-mutation contract.
[ "$DRY_RUN" = "1" ] || mkdir -p "$(dirname "$AUDIT_LOG")"

audit_field() {
    # $1=q_id $2=section $3=path $4=value(json) $5=confidence(json) $6=source_span(json)
    [ "$DRY_RUN" = "1" ] && return 0
    jq -nc --arg ts "$RUN_TS" --arg run "$RUN_ID" \
        --arg q "$1" --arg sec "$2" --arg path "$3" \
        --argjson val "$4" --argjson conf "$5" --argjson span "$6" \
        '{ts:$ts,run_id:$run,event:"field",q_id:$q,section_id:$sec,path:$path,value:$val,confidence:$conf,source_span:$span}' \
        >> "$AUDIT_LOG"
}

audit_event() {
    # $1=event $2=msg(string)
    [ "$DRY_RUN" = "1" ] && return 0
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg run "$RUN_ID" \
        --arg ev "$1" --arg msg "$2" \
        '{ts:$ts,run_id:$run,event:$ev,message:$msg}' \
        >> "$AUDIT_LOG"
}

cleanup_and_fail() {
    # Roll back all .tmp files staged in this run.
    if [ -n "$WROTE_TMPS" ]; then
        for t in $WROTE_TMPS; do
            [ -f "$t" ] && rm -f "$t"
        done
    fi
    rm -rf "$TMPDIR_RUN"
    audit_event "BOOTSTRAP_FAILED" "${1:-unspecified}"
    echo "BOOTSTRAP_FAILED: ${1:-unspecified}" >&2
    exit 1
}

trap 'rm -rf "$TMPDIR_RUN" 2>/dev/null' EXIT

# --- validators ---
validate_ajv() {
    # $1=instance $2=schema. Returns 0 on pass, non-zero on fail.
    [ -n "$AJV_BIN" ] || return 99
    "$AJV_BIN" validate -s "$2" -d "$1" --strict=false >/dev/null 2>&1
}

validate_jq_structural() {
    # $1=instance $2=schema. Validates: instance parses; required top-level
    # keys from schema.required[] are present in instance.
    jq -e . "$1" >/dev/null 2>&1 || return 1
    local req
    req="$(jq -r '.required[]? // empty' "$2" 2>/dev/null)"
    [ -z "$req" ] && return 0
    local k
    for k in $req; do
        jq -e --arg k "$k" 'has($k)' "$1" >/dev/null 2>&1 || {
            echo "structural: instance missing required key: $k" >&2
            return 1
        }
    done
    return 0
}

validate_instance() {
    # $1=instance $2=schema $3=label
    if [ -n "$AJV_BIN" ]; then
        validate_ajv "$1" "$2" || {
            echo "validate ($3): ajv FAILED" >&2
            "$AJV_BIN" validate -s "$2" -d "$1" --strict=false 2>&1 | head -20 >&2
            return 1
        }
    else
        validate_jq_structural "$1" "$2" || {
            echo "validate ($3): structural FAILED" >&2
            return 1
        }
    fi
    return 0
}

# --- path conversion ---
# "U.identity.role"        → user-manifest path ".identity.role"
# "O.jobs[0].id"           → orchestration path ".jobs[0].id"
# "U.system.opt_outs[]"    → user-manifest array path ".system.opt_outs"
# Returns: "<target>|<jq_path>|<is_array>"
convert_path() {
    local p="$1"
    local target="" body="" arr=0
    case "$p" in
        U.*) target="user"; body="${p#U.}" ;;
        O.*) target="orch"; body="${p#O.}" ;;
        *)   echo "convert_path: unknown prefix: $p" >&2; return 1 ;;
    esac
    case "$body" in
        *'[]') arr=1; body="${body%'[]'}" ;;
    esac
    # Wrap each token: dotted segments → .seg ; numeric-indexed seg[N] preserved.
    local jp=""
    local IFS=.
    set -- $body
    for tok in "$@"; do
        case "$tok" in
            *'['*']') jp="${jp}.${tok}" ;;
            *)        jp="${jp}.${tok}" ;;
        esac
    done
    echo "${target}|${jp}|${arr}"
}

# --- seed_memories (Plan 71 SP11 T-3) ---
# Routes Section A/C/D outputs from the populated user-manifest into 3-5
# R-45-valid seed memory files under
# ${CLAUDE_HOME:-$HOME/.claude}/projects/<slug>/memory/. Idempotent on SP12
# coordination: if a seed file already exists with different content
# (potentially SP12-authored enrichment), preserve it.
#
# Slug convention: matches install.sh Step 11.6 — $CLAUDE_HOME with / → -
# and leading - stripped.
#
# Output contract:
#   - 0-5 seed *.md files (skips when source field absent)
#   - R-45 frontmatter (name, description, type, last_verified)
#   - Index entries appended to MEMORY.md under appropriate H2 section
#   - Advisory log at <memory_dir>/.r45-advisories.log on validation gaps
#   - audit_event terminator with seed count + advisory count
#
# Failure mode: degrade-open. If memory dir cannot be created, log a
# warning event and return 0; bootstrap proceeds.
seed_memories() {
    [ "$DRY_RUN" = "1" ] && { audit_event "seed_memories" "skipped under --dry-run"; return 0; }

    local mem_base mem_slug mem_dir
    mem_base="${CLAUDE_HOME:-$HOME/.claude}"
    mem_slug="$(printf '%s' "$mem_base" | tr '/' '-' | sed 's/^-//')"
    mem_dir="$mem_base/projects/$mem_slug/memory"

    mkdir -p "$mem_dir" 2>/dev/null || {
        audit_event "warning" "seed_memories: mkdir failed at $mem_dir; skipping"
        return 0
    }

    # Pull identity / behavioral / vault fields from the populated user-manifest tmp
    local name role org autonomy prior_seed vault_root vault_method
    name="$(jq -r '.identity.name // empty' "$USER_TMP" 2>/dev/null)"
    role="$(jq -r '.identity.role // empty' "$USER_TMP" 2>/dev/null)"
    org="$(jq -r '.identity.organization // empty' "$USER_TMP" 2>/dev/null)"
    autonomy="$(jq -r '.behavioral.autonomy // empty' "$USER_TMP" 2>/dev/null)"
    prior_seed="$(jq -r '.architect.prior_seed // empty' "$USER_TMP" 2>/dev/null)"
    vault_root="$(jq -r '.paths.vault_root // .vault.root // empty' "$USER_TMP" 2>/dev/null)"
    vault_method="$(jq -r '.vault.organizational_method // empty' "$USER_TMP" 2>/dev/null)"

    # No identity → no useful seeding
    if [ -z "$name" ]; then
        audit_event "seed_memories" "identity.name absent; no seeding performed"
        return 0
    fi

    # Compute filename-safe slug for $name
    local name_slug
    name_slug="$(printf '%s' "$name" | tr 'A-Z' 'a-z' | tr ' ' '-' | tr -dc 'a-z0-9-' | sed -e 's/^-*//' -e 's/-*$//')"
    [ -z "$name_slug" ] && name_slug="user"

    local seeds_count=0
    local r45_advisories=0
    local advisory_log="$mem_dir/.r45-advisories.log"
    local now_iso="$RUN_TS"
    local now_date
    now_date="$(printf '%s' "$now_iso" | cut -c1-10)"

    # Helper: write seed file with R-45 frontmatter + append index entry
    # $1=path $2=name $3=description $4=type $5=body
    _write_seed() {
        local fp="$1" nm="$2" desc="$3" tp="$4" body="$5"

        # SP12 coordination: preserve existing seed (potentially SP12-authored)
        if [ -f "$fp" ]; then
            audit_event "seed_memories" "skip-existing $fp (SP12-coordination preserve)"
            return 0
        fi

        # Write atomically: tmp → rename
        local tmp="$fp.tmp.$$"
        {
            printf '%s\n' '---'
            printf 'name: %s\n' "$nm"
            printf 'description: %s\n' "$desc"
            printf 'type: %s\n' "$tp"
            printf 'last_verified: %s\n' "$now_date"
            printf '%s\n\n' '---'
            printf '%s\n' "$body"
        } > "$tmp" || {
            audit_event "warning" "seed_memories: write failed at $tmp"
            rm -f "$tmp"
            return 0
        }

        # R-45 advisory: verify all 4 required fields present in frontmatter
        local fm_ok=1
        for fld in name description type last_verified; do
            grep -q "^${fld}: " "$tmp" 2>/dev/null || fm_ok=0
        done
        if [ "$fm_ok" = "0" ]; then
            r45_advisories=$((r45_advisories + 1))
            printf '%s\tR-45 advisory: missing required frontmatter field(s) at %s\n' \
                "$now_iso" "$fp" >> "$advisory_log" 2>/dev/null || true
        fi

        mv "$tmp" "$fp" || {
            audit_event "warning" "seed_memories: rename failed $tmp → $fp"
            rm -f "$tmp"
            return 0
        }

        seeds_count=$((seeds_count + 1))

        # Append index entry to MEMORY.md if present
        local idx="$mem_dir/MEMORY.md"
        local section_h2=""
        case "$tp" in
            user)      section_h2="## User" ;;
            feedback)  section_h2="## Feedback" ;;
            project)   section_h2="## Project" ;;
            reference) section_h2="## Reference" ;;
        esac
        if [ -f "$idx" ] && [ -n "$section_h2" ] && grep -q "^${section_h2}\$" "$idx"; then
            local base="${fp##*/}"
            local entry="- [$nm](memory/$base) — $desc"
            awk -v hdr="$section_h2" -v ent="$entry" '
                {print}
                $0 == hdr { print ent }
            ' "$idx" > "$idx.tmp" && mv "$idx.tmp" "$idx"
        fi
    }

    # --- Seed 1: communication style (from .behavioral.autonomy) ---
    if [ -n "$autonomy" ]; then
        local cs_body
        case "$autonomy" in
            strict)
                cs_body="Operates in **strict-autonomy** mode: confirm before non-trivial actions; prefer ask-then-act over act-then-report. Pause and check before destructive operations or shared-state changes."
                ;;
            balanced)
                cs_body="Operates in **balanced-autonomy** mode: take small reversible actions freely; confirm before destructive operations, shared-state changes, or anything affecting infrastructure beyond the local environment."
                ;;
            permissive)
                cs_body="Operates in **permissive-autonomy** mode: act-then-report. Only confirm before truly irreversible operations (force-push, hard reset, dropped tables, sent communications)."
                ;;
            *)
                cs_body="Autonomy level captured during onboarding: $autonomy."
                ;;
        esac
        _write_seed "$mem_dir/user_${name_slug}_communication_style.md" \
            "${name} working style" \
            "Working-style and autonomy preferences captured during onboarding (Section D)." \
            "user" \
            "$cs_body"
    fi

    # --- Seed 2: priorities (from .architect.prior_seed) ---
    if [ -n "$prior_seed" ]; then
        _write_seed "$mem_dir/user_${name_slug}_priorities.md" \
            "${name} priorities" \
            "Concerns and priorities surfaced during onboarding for architect prior-seeding." \
            "user" \
            "$prior_seed"
    fi

    # --- Seed 3: project / vault (from .paths.vault_root + .vault.organizational_method) ---
    if [ -n "$vault_root" ]; then
        local vault_name vault_body
        vault_name="$(printf '%s' "$vault_root" | sed 's|/$||; s|.*/||' | tr 'A-Z' 'a-z' | tr ' ' '-' | tr -dc 'a-z0-9-' | sed -e 's/^-*//' -e 's/-*$//')"
        [ -z "$vault_name" ] && vault_name="vault"
        vault_body="Vault root: \`$vault_root\`"
        if [ -n "$vault_method" ]; then
            vault_body="${vault_body}

Organizational method: $vault_method"
        fi
        _write_seed "$mem_dir/project_${vault_name}.md" \
            "Vault: ${vault_name}" \
            "Primary vault for ${name}; root path and organizational method captured during onboarding." \
            "project" \
            "$vault_body"
    fi

    # --- Seeds 4-5: feedback heuristics from Section B/C transcripts (cap at 2) ---
    local feedback_added=0
    local sec
    for sec in B C; do
        [ "$feedback_added" -ge 2 ] && break
        local fixture_file="$INPUTS_DIR/extraction-output-${sec}.json"
        [ -f "$fixture_file" ] || continue
        local raw_transcript
        raw_transcript="$(jq -r '.raw_transcript // empty' "$fixture_file" 2>/dev/null)"
        [ -z "$raw_transcript" ] && continue
        # Conservative regex: whole-word match for 1st-person + always|never|must
        local first_match fb_topic
        first_match="$(printf '%s' "$raw_transcript" | grep -ioE '\bI (always|never|must)[^.]{5,120}\.' | head -1)"
        [ -z "$first_match" ] && continue
        # Topic slug from first 40 chars of match
        fb_topic="$(printf '%s' "$first_match" | tr 'A-Z' 'a-z' | tr ' ' '-' | tr -dc 'a-z0-9-' | head -c 40 | sed -e 's/^-*//' -e 's/-*$//')"
        [ -z "$fb_topic" ] && continue
        _write_seed "$mem_dir/feedback_${fb_topic}.md" \
            "Heuristic feedback: ${fb_topic}" \
            "Heuristic-extracted preference pattern from Section ${sec} transcript (operator review encouraged)." \
            "feedback" \
            "Captured pattern: $first_match

Heuristic confidence. Verify against the source transcript and either confirm or remove."
        feedback_added=$((feedback_added + 1))
    done

    audit_event "seed_memories" "wrote ${seeds_count} seed file(s); r45_advisories=${r45_advisories}; mem_dir=$mem_dir"
    return 0
}

# --- skeletons ---
# user-manifest skeleton (10 required sections, all required-keys present, schema_version locked).
# 1.1.0 adds 3 optional top-level sections (hooks/schema/plans) — onboarder populates
# only when relevant; absence is valid and SP02 hooks fall back to Lead 2 §2 defaults.
USER_SKELETON='{
  "identity": {},
  "paths": {},
  "tools": {"messaging": []},
  "vault": {},
  "projects": {"active": []},
  "people": [],
  "behavioral": {"hook_preferences": {}},
  "backlog": {},
  "architect": {},
  "system": {"schema_version": "1.1.0", "opt_outs": []}
}'

# orchestration skeleton — preserve existing live file when present (idempotent
# re-runs preserve operator-edited tripwires/observability).
ORCH_OUT="${HOME}/.claude/orchestration.json"
USER_OUT="${HOME}/.claude/user-manifest.json"
PLANS_OUT="${SCHEMAS_DIR}/plans-schema.json"
VAULT_OUT="${SCHEMAS_DIR}/vault-schema.json"

# --- 1. parse extraction outputs ---
SECTIONS="A B C D E"
for s in $SECTIONS; do
    f="$INPUTS_DIR/extraction-output-${s}.json"
    [ -f "$f" ] || cleanup_and_fail "missing extraction-output-${s}.json at $f"
    jq -e . "$f" >/dev/null 2>&1 || cleanup_and_fail "extraction-output-${s}.json: invalid JSON"
    expected_id="$s"
    actual_id="$(jq -r '.section_id // empty' "$f")"
    [ "$actual_id" = "$expected_id" ] || cleanup_and_fail "extraction-output-${s}.json: section_id='$actual_id' (expected '$expected_id')"
    jq -e '.populated | type == "object"' "$f" >/dev/null 2>&1 || cleanup_and_fail "extraction-output-${s}.json: 'populated' must be object"
done

# --- 2. build populated user-manifest + orchestration in tmp ---
USER_TMP="$TMPDIR_RUN/user-manifest.json"
ORCH_TMP="$TMPDIR_RUN/orchestration.json"
echo "$USER_SKELETON" | jq . > "$USER_TMP"

# Orchestration: start from live skeleton if present, else from spec defaults.
if [ -f "$ORCH_OUT" ]; then
    cp "$ORCH_OUT" "$ORCH_TMP"
else
    cat > "$ORCH_TMP" <<'EOF'
{
  "schema_version": "1.0.0",
  "platform": "darwin-launchd",
  "jobs": [],
  "tripwires": [],
  "observability": {
    "morning_brief_staleness_h": 48,
    "librarian_staleness_h": 24,
    "sessionstart_banner_staleness_h": 24,
    "filename_epoch_parsing": true
  }
}
EOF
fi

# Track D-2 resolution to wire defaults_applied + D-3 conditional + D-4 default.
D2_JOB_ID=""
D2_RESOLVED=0
D3_NEW_VALUE=""
D4_VALUE=""

# Walk each section's populated keys and apply.
for s in $SECTIONS; do
    f="$INPUTS_DIR/extraction-output-${s}.json"
    populated_keys="$(jq -r '.populated | keys[]?' "$f")"
    [ -z "$populated_keys" ] && continue

    # Loop is OK since populated_keys is whitespace-safe (paths have no spaces).
    for path in $populated_keys; do
        value_json="$(jq -c --arg p "$path" '.populated[$p]' "$f")"
        confidence_json="$(jq -c --arg p "$path" '.confidence[$p] // null' "$f")"
        span_json="$(jq -c --arg p "$path" '.source_spans[$p] // null' "$f")"

        # Path normalization: extraction outputs emit paths WITHOUT the
        # cardinality `[]` suffix; q-field-map carries the suffix as
        # cardinality notation. Match either form for q_id lookup, and
        # use the bracket-stripped form for engine dispatch.
        path_bare="${path%'[]'}"

        # Look up q_id whose targets include this path (with or without `[]`).
        # Skip non-object values like `_comment` strings in section_e_binaries.
        q_id="$(jq -r --arg p "$path" --arg pb "$path_bare" '
            ((.direct_qs // {}) + (.checkbox_qs // {}) + (.section_e_binaries // {}))
            | to_entries
            | map(select(.value | type == "object"))
            | map(select((.value.targets // []) | map(.path) | (index($p) != null) or (index($pb) != null) or (index($pb + "[]") != null)))
            | .[0].key // empty
        ' "$INPUTS_DIR/q-field-map.json")"

        # --- C-3 conditional_append (idempotent dedupe) ---
        if [ "$path_bare" = "U.system.opt_outs" ]; then
            # value_json could be: true, "yes"-ish, ["sensitive_isolation"], or null/false → no-op.
            should_append=0
            case "$(echo "$value_json" | jq -r 'type')" in
                array)   echo "$value_json" | jq -e 'index("sensitive_isolation")' >/dev/null 2>&1 && should_append=1 ;;
                boolean) [ "$value_json" = "true" ] && should_append=1 ;;
                string)  case "$value_json" in '"yes"'|'"true"'|'"sensitive"'|'"sensitive_isolation"') should_append=1 ;; esac ;;
            esac
            if [ "$should_append" = "1" ]; then
                jq '.system.opt_outs = ((.system.opt_outs // []) + ["sensitive_isolation"] | unique)' \
                    "$USER_TMP" > "$USER_TMP.s" && mv "$USER_TMP.s" "$USER_TMP"
                audit_field "${q_id:-C-3}" "$s" "$path" '"sensitive_isolation"' "$confidence_json" "$span_json"
            fi
            continue
        fi

        # --- D-2 opt-out shape: O.jobs == [] ---
        if [ "$path_bare" = "O.jobs" ]; then
            v_type="$(echo "$value_json" | jq -r 'type')"
            if [ "$v_type" = "array" ]; then
                jq '.jobs = []' "$ORCH_TMP" > "$ORCH_TMP.s" && mv "$ORCH_TMP.s" "$ORCH_TMP"
                D2_RESOLVED=1
                D2_JOB_ID=""
                audit_field "${q_id:-D-2}" "$s" "$path" '[]' "$confidence_json" "$span_json"
            fi
            continue
        fi

        # --- D-2 mutual exclusion (single-id shape) ---
        if [ "$path_bare" = "O.jobs[0].id" ]; then
            v_type="$(echo "$value_json" | jq -r 'type')"
            if [ "$v_type" = "string" ] && [ "$(echo "$value_json" | jq -r '.')" != "" ]; then
                D2_JOB_ID="$(echo "$value_json" | jq -r '.')"
                D2_RESOLVED=1
                # Pull defaults_applied bundle from q-field-map for this archetype.
                schedule_json="$(jq -c --arg id "$D2_JOB_ID" \
                    '.direct_qs."D-2".defaults_applied."O.jobs[0].schedule"[$id] // {"hour":6,"minute":0}' \
                    "$INPUTS_DIR/q-field-map.json")"
                log_path="${HOME}/.claude/cron-logs/${D2_JOB_ID}.log"
                cmd="${HOME}/.claude/skills/${D2_JOB_ID}/${D2_JOB_ID}.sh"
                jq --arg id "$D2_JOB_ID" --arg lp "$log_path" --arg cmd "$cmd" \
                    --argjson sched "$schedule_json" \
                    '.jobs = [{
                        id: $id,
                        enabled: true,
                        schedule: $sched,
                        command: $cmd,
                        log_path: $lp,
                        idle_watchdog_sec: 180,
                        single_instance: true,
                        cold_wake_probe: true
                    }]' "$ORCH_TMP" > "$ORCH_TMP.s" && mv "$ORCH_TMP.s" "$ORCH_TMP"
                audit_field "${q_id:-D-2}" "$s" "$path" "$value_json" "$confidence_json" "$span_json"
            elif [ "$v_type" = "array" ] || [ "$v_type" = "null" ]; then
                # Empty/null ⇒ user opted out; jobs:[] explicit.
                jq '.jobs = []' "$ORCH_TMP" > "$ORCH_TMP.s" && mv "$ORCH_TMP.s" "$ORCH_TMP"
                D2_RESOLVED=1
                D2_JOB_ID=""
                audit_field "${q_id:-D-2}" "$s" "$path" '[]' "$confidence_json" "$span_json"
            else
                cleanup_and_fail "D-2 mutex: O.jobs[0].id has unexpected type '$v_type' (expected string|array|null)"
            fi
            continue
        fi

        # --- D-3 archetype-prefix prepend + comma-join (deferred; conditional on D-2) ---
        if [ "$path_bare" = "U.architect.prior_seed" ]; then
            D3_NEW_VALUE="$(echo "$value_json" | jq -r 'if type == "string" then . else "" end')"
            # Stash for post-loop apply (need D-2 resolved first).
            audit_field "${q_id:-D-3}" "$s" "$path" "$value_json" "$confidence_json" "$span_json"
            continue
        fi

        # --- D-4 default applied later if absent; if present, take as-is ---
        if [ "$path_bare" = "U.behavioral.hook_preferences.notification_style" ]; then
            D4_VALUE="$(echo "$value_json" | jq -r '. // ""')"
        fi

        # --- generic apply via convert_path (use bracket-stripped form) ---
        conv="$(convert_path "$path_bare")" || cleanup_and_fail "path conversion failed: $path"
        target="$(echo "$conv" | cut -d'|' -f1)"
        jq_path="$(echo "$conv" | cut -d'|' -f2)"
        is_array="$(echo "$conv" | cut -d'|' -f3)"

        case "$target" in
            user) tmp_file="$USER_TMP" ;;
            orch) tmp_file="$ORCH_TMP" ;;
            *)    cleanup_and_fail "unknown target: $target" ;;
        esac

        if [ "$is_array" = "1" ]; then
            # Generic array merge (union).
            v_type="$(echo "$value_json" | jq -r 'type')"
            if [ "$v_type" = "array" ]; then
                jq --argjson v "$value_json" "${jq_path} = ((${jq_path} // []) + \$v | unique)" \
                    "$tmp_file" > "$tmp_file.s" && mv "$tmp_file.s" "$tmp_file"
            elif [ "$v_type" != "null" ]; then
                jq --argjson v "$value_json" "${jq_path} = ((${jq_path} // []) + [\$v] | unique)" \
                    "$tmp_file" > "$tmp_file.s" && mv "$tmp_file.s" "$tmp_file"
            fi
        else
            # Scalar / nested object set.
            jq --argjson v "$value_json" "${jq_path} = \$v" "$tmp_file" > "$tmp_file.s" \
                && mv "$tmp_file.s" "$tmp_file"
        fi
        audit_field "${q_id:-unmapped}" "$s" "$path" "$value_json" "$confidence_json" "$span_json"
    done
done

# --- D-3 post-loop apply: prepend archetype label + comma-join, double-append safe ---
if [ -n "$D3_NEW_VALUE" ] && [ "$D2_RESOLVED" = "1" ] && [ "$D2_JOB_ID" = "architect" ]; then
    current="$(jq -r '.architect.prior_seed // ""' "$USER_TMP")"
    # If already contains the new value (entirely), skip; else comma-join.
    if [ -z "$current" ]; then
        merged="$D3_NEW_VALUE"
    else
        # Tokenize on commas (NOT whitespace) so multi-word concerns like
        # "slow CI" stay intact. Each token is whitespace-trimmed; `grep -Fxq`
        # against old_tokens does an exact-line match.
        old_tokens="$(echo "$current" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        merged="$current"
        # while-read preserves multi-word tokens (no IFS word-split).
        while IFS= read -r tk; do
            tk="$(echo "$tk" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            [ -z "$tk" ] && continue
            if printf '%s\n' "$old_tokens" | grep -Fxq -- "$tk"; then
                continue
            fi
            merged="${merged}, ${tk}"
        done <<EOF_TOKENS
$(echo "$D3_NEW_VALUE" | tr ',' '\n')
EOF_TOKENS
    fi
    jq --arg v "$merged" '.architect.prior_seed = $v' "$USER_TMP" > "$USER_TMP.s" \
        && mv "$USER_TMP.s" "$USER_TMP"
elif [ -n "$D3_NEW_VALUE" ] && [ "$D2_RESOLVED" = "1" ] && [ "$D2_JOB_ID" != "architect" ]; then
    # Off-condition emission: per T-9 contract, OMIT entirely.
    audit_event "warning" "D-3 emitted but D-2 != architect (job_id='$D2_JOB_ID') — omitted per conditional_on rule"
fi

# --- D-4 default ---
if [ -z "$D4_VALUE" ]; then
    default_d4="$(jq -r '.direct_qs."D-4".targets[0].default_value // "digest"' "$INPUTS_DIR/q-field-map.json")"
    jq --arg v "$default_d4" '.behavioral.hook_preferences.notification_style = $v' \
        "$USER_TMP" > "$USER_TMP.s" && mv "$USER_TMP.s" "$USER_TMP"
    audit_event "default_applied" "D-4 notification_style absent ⇒ defaulted to '$default_d4'"
fi

# --- 3. validate populated outputs ---
USER_SCHEMA="$SCHEMAS_DIR/user-manifest-schema.json"
ORCH_SCHEMA="$SCHEMAS_DIR/orchestration-schema.json"

[ -f "$USER_SCHEMA" ] || cleanup_and_fail "missing schema: $USER_SCHEMA"
[ -f "$ORCH_SCHEMA" ] || cleanup_and_fail "missing schema: $ORCH_SCHEMA"
[ -f "$PLANS_OUT" ]  || cleanup_and_fail "missing plans-schema source: $PLANS_OUT"
[ -f "$VAULT_OUT" ]  || cleanup_and_fail "missing vault-schema source: $VAULT_OUT"

validate_instance "$USER_TMP" "$USER_SCHEMA" "user-manifest" || cleanup_and_fail "user-manifest validation failed"
validate_instance "$ORCH_TMP" "$ORCH_SCHEMA" "orchestration" || cleanup_and_fail "orchestration validation failed"

# --- 4. plans-schema static + vault-schema pass-through (stage tmp copies) ---
PLANS_TMP="$TMPDIR_RUN/plans-schema.json"
VAULT_TMP="$TMPDIR_RUN/vault-schema.json"
cp "$PLANS_OUT" "$PLANS_TMP"
cp "$VAULT_OUT" "$VAULT_TMP"

# Sanity: both must be JSON.
jq -e . "$PLANS_TMP" >/dev/null 2>&1 || cleanup_and_fail "plans-schema not valid JSON"
jq -e . "$VAULT_TMP" >/dev/null 2>&1 || cleanup_and_fail "vault-schema not valid JSON"
# Vault-schema structural: must carry _tag_prefixes (array, may be empty) +
# at least one type-key with required[].
jq -e '._tag_prefixes | type == "array"' "$VAULT_TMP" >/dev/null 2>&1 \
    || cleanup_and_fail "vault-schema: _tag_prefixes must be an array"

audit_event "static-copy" "plans-schema verified (no transform)"
audit_event "pass-through" "vault-schema verified (_tag_prefixes archetype-seed merge deferred to T-12 fixtures)"

# --- 5. atomic write per output (idempotent + --force) ---
# Dry-run accounting (counts emitted on summary line at end of run).
DRY_WOULD_WRITE=0
DRY_NO_OP=0

write_atomic() {
    # $1=tmp $2=live $3=label
    local tmp="$1" live="$2" label="$3"

    # Dry-run path: emit informational diff + no-op report. Zero mutations
    # to live targets or audit log. Always returns 0 — ANY_DIFFER is not
    # tracked under dry-run (dry-run is informational, not write-attempting).
    if [ "$DRY_RUN" = "1" ]; then
        if [ -f "$live" ]; then
            if cmp -s "$tmp" "$live"; then
                echo "DRY-RUN: $label — no-op (byte-match) at $live" >&2
                DRY_NO_OP=$((DRY_NO_OP + 1))
            else
                echo "DRY-RUN: $label — would-update at $live (unified diff):" >&2
                diff -u "$live" "$tmp" >&2 || true
                DRY_WOULD_WRITE=$((DRY_WOULD_WRITE + 1))
            fi
        else
            echo "DRY-RUN: $label — would-create at $live (full content as diff vs /dev/null):" >&2
            diff -u /dev/null "$tmp" >&2 || true
            DRY_WOULD_WRITE=$((DRY_WOULD_WRITE + 1))
        fi
        return 0
    fi

    if [ -f "$live" ]; then
        if cmp -s "$tmp" "$live"; then
            audit_event "skip-identical" "$label already matches at $live"
            return 0
        fi
        if [ "$FORCE" != "1" ]; then
            cp "$tmp" "${live}.new"
            echo "DIFF: $label differs at $live (--force to overwrite). Side-by-side staged at ${live}.new" >&2
            diff -u "$live" "$tmp" | head -40 >&2 || true
            audit_event "differs-no-force" "$label differs at $live; .new written, --force to overwrite"
            return 2
        fi
    fi
    # Stage final tmp adjacent to target so rename is atomic on same filesystem.
    local final_tmp="${live}.tmp.${RUN_ID}"
    cp "$tmp" "$final_tmp"
    WROTE_TMPS="$WROTE_TMPS $final_tmp"
    mv "$final_tmp" "$live"
    audit_event "wrote" "$label → $live"
    return 0
}

# Order per spec: plans-schema → user-manifest → vault-schema → orchestration.
ANY_DIFFER=0
write_atomic "$PLANS_TMP" "$PLANS_OUT" "plans-schema" || { rc=$?; [ "$rc" = "2" ] && ANY_DIFFER=1 || cleanup_and_fail "plans-schema write failed"; }
write_atomic "$USER_TMP"  "$USER_OUT"  "user-manifest" || { rc=$?; [ "$rc" = "2" ] && ANY_DIFFER=1 || cleanup_and_fail "user-manifest write failed"; }
write_atomic "$VAULT_TMP" "$VAULT_OUT" "vault-schema" || { rc=$?; [ "$rc" = "2" ] && ANY_DIFFER=1 || cleanup_and_fail "vault-schema write failed"; }
write_atomic "$ORCH_TMP"  "$ORCH_OUT"  "orchestration" || { rc=$?; [ "$rc" = "2" ] && ANY_DIFFER=1 || cleanup_and_fail "orchestration write failed"; }

if [ "$DRY_RUN" = "1" ]; then
    echo "DRY-RUN: complete — ${DRY_WOULD_WRITE} would-write, ${DRY_NO_OP} no-op (byte-match); zero filesystem mutations" >&2
    exit 0
fi

if [ "$ANY_DIFFER" = "1" ]; then
    audit_event "BOOTSTRAP_DIFFER" "one or more targets differ; --force required"
    echo "BOOTSTRAP_DIFFER: rerun with --force to overwrite, or accept .new files manually" >&2
    exit 2
fi

# --- Plan 71 SP11 T-3: route Section A/C/D outputs into seed memory files ---
# Runs after all 4 schema outputs commit; degrade-open on failure.
seed_memories || true

audit_event "BOOTSTRAP_COMPLETED" "run_id=$RUN_ID all 4 outputs written or skipped-identical"
exit 0
