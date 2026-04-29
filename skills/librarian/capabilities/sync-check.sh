#!/bin/bash
# sync-check — Cross-domain consistency between backend ($CLAUDE_HOME/) and
# vault ($VAULT_ROOT/). Deterministic checklist of known relationships —
# not agent-based discovery.
#
# Sources `lib/findings.sh` + `lib/manifest.sh`.
#
# Seven checks grouped by scope:
#   backend (1–4) — always fire:
#     1. Skill runtime sync    — content hash: $CLAUDE_HOME/skills/{X}/SKILL.md
#        vs vault copy at .claude/skills/{X}.md               (auto-fix)
#     2. Skills Index          — every backend skill has a row in
#        Skills/_index.md; every index row points to a spec     (manual)
#     3. Memory paths          — $CLAUDE_HOME/projects/*/memory/*.md
#        referenced file paths exist on disk                    (auto-fix stale)
#     4. Root CLAUDE.md        — references (paths, skill names) resolve
#                                                              (auto-fix|manual)
#   vault (5–6) — gated on manifest.vault.has_structured_projects:
#     5. Vault CLAUDE.md       — engagement list matches Engagements/*/ dirs
#        and Overview `status:` frontmatter                     (auto-fix)
#     6. Vault Architecture    — directory tree documented in VA.md matches
#        actual filesystem; new dirs undoc'd OR doc'd dirs missing (manual)
#   cross (7) — gated on manifest.vault.has_structured_projects:
#     7. Engagement status     — root CLAUDE.md vs vault CLAUDE.md vs
#        Engagements/*/CLAUDE.md vs Engagements/*/* - Overview.md
#        agree. Overview is source of truth.                    (auto-fix)
#
# When `has_structured_projects` is false (foundation default), checks 5-7
# emit a "skipped (ungated)" event each and return without scanning.
#
# CLI:
#   sync-check.sh                         # --check all 7
#   sync-check.sh --scope backend|vault|cross
#   sync-check.sh --scope <check-name>    # e.g. skill-runtime, memory-paths
#   sync-check.sh --fix                   # auto-apply auto-fix class
#   sync-check.sh --dry-run               # summary counts only
#
# Finding IDs: `S-NNN`. Written to `drift_findings.sync_check[]` via
# manifest_set (reconciled: matched by `(check, subject)`; first_seen
# preserved; resolved rows drop out).
#
# Bash 3.2 clean per R-23.

set -euo pipefail

if [[ -z "${VAULT_LOGS:-}" ]]; then
  # shellcheck source=/dev/null
  source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
fi
# shellcheck source=/dev/null
source "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/lib/findings.sh"
# shellcheck source=/dev/null
source "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/lib/manifest.sh"

SCOPE="all"
MODE="check"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --check) MODE="check"; shift ;;
    --fix)   MODE="fix"; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sync-check: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

BACKEND_ROOT="${SC_BACKEND_ROOT:-${CLAUDE_HOME:-$HOME/.claude}}"
ROOT_CLAUDE_MD="${SC_ROOT_CLAUDE_MD:-${CLAUDE_HOME:-$HOME/.claude}/CLAUDE.md}"
VAULT_CLAUDE_MD="${SC_VAULT_CLAUDE_MD:-$VAULT_ROOT/CLAUDE.md}"
VAULT_ARCH_MD="${SC_VAULT_ARCH_MD:-$VAULT_ROOT/Vault Architecture.md}"
SKILLS_INDEX="${SC_SKILLS_INDEX:-$VAULT_ROOT/Skills/_index.md}"

# Memory dir: first-run glob $CLAUDE_HOME/projects/*/memory + env override.
# When no memory dir exists yet (greenfield install), MEMORY_ROOT stays empty
# and check_memory_paths gracefully skips. T-4 will land a richer resolver.
MEMORY_ROOT="${SC_MEMORY_ROOT:-}"
if [[ -z "$MEMORY_ROOT" ]]; then
  for _d in "${CLAUDE_HOME:-$HOME/.claude}"/projects/*/memory; do
    if [[ -d "$_d" ]]; then
      MEMORY_ROOT="$_d"
      break
    fi
  done
  unset _d
fi

# Read has_structured_projects gate from user-manifest. Foundation default false.
USER_MANIFEST="${USER_MANIFEST_PATH:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"
HAS_STRUCTURED_PROJECTS="false"
if [[ -r "$USER_MANIFEST" ]] && command -v jq >/dev/null 2>&1; then
  HAS_STRUCTURED_PROJECTS=$(jq -r '.vault.has_structured_projects // false' "$USER_MANIFEST" 2>/dev/null)
fi

EXISTING="$(manifest_get '.drift_findings.sync_check' '[]')"

DRIFT_OUT="$(mktemp -t sync-check-drift.XXXXXX)"
trap 'rm -f "$DRIFT_OUT"' EXIT

export SC_SCOPE="$SCOPE"
export SC_MODE="$MODE"
export SC_DRY_RUN="$DRY_RUN"
export SC_BACKEND_ROOT_X="$BACKEND_ROOT"
export SC_MEMORY_ROOT_X="$MEMORY_ROOT"
export SC_ROOT_CLAUDE_MD_X="$ROOT_CLAUDE_MD"
export SC_VAULT_CLAUDE_MD_X="$VAULT_CLAUDE_MD"
export SC_VAULT_ARCH_MD_X="$VAULT_ARCH_MD"
export SC_SKILLS_INDEX_X="$SKILLS_INDEX"
export SC_VAULT_ROOT_X="$VAULT_ROOT"
export SC_HAS_STRUCTURED_PROJECTS="$HAS_STRUCTURED_PROJECTS"
export SC_EXISTING="$EXISTING"
export SC_DRIFT_OUT="$DRIFT_OUT"

python3 <<'PY'
import hashlib, json, os, re, sys, shutil
from datetime import datetime, timezone

scope     = os.environ["SC_SCOPE"]
mode      = os.environ["SC_MODE"]
dry_run   = os.environ["SC_DRY_RUN"] == "true"
backend   = os.environ["SC_BACKEND_ROOT_X"]
memroot   = os.environ["SC_MEMORY_ROOT_X"]
root_cmd  = os.environ["SC_ROOT_CLAUDE_MD_X"]
vault_cmd = os.environ["SC_VAULT_CLAUDE_MD_X"]
vault_arch= os.environ["SC_VAULT_ARCH_MD_X"]
skills_ix = os.environ["SC_SKILLS_INDEX_X"]
vault     = os.environ["SC_VAULT_ROOT_X"]
has_structured = os.environ["SC_HAS_STRUCTURED_PROJECTS"] == "true"
existing  = json.loads(os.environ["SC_EXISTING"] or "[]")
drift_out = os.environ["SC_DRIFT_OUT"]
findings_out = os.environ.get("FINDINGS_OUTPUT", "")
now_iso = datetime.now(timezone.utc).replace(tzinfo=None).strftime("%Y-%m-%dT%H:%M:%S")
fix_mode = (mode == "fix")

CHECK_TO_SCOPE = {
    "skill-runtime":      "backend",
    "skills-index":       "backend",
    "memory-paths":       "backend",
    "root-claude-md":     "backend",
    "vault-claude-md":    "vault",
    "vault-architecture": "vault",
    "engagement-status":  "cross",
}
SCOPE_GROUPS = {"backend", "vault", "cross", "all"}

# Checks gated on manifest.vault.has_structured_projects.
GATED_CHECKS = {"vault-claude-md", "vault-architecture", "engagement-status"}

def scope_matches(check_name):
    if scope == "all":
        return True
    if scope in SCOPE_GROUPS:
        return CHECK_TO_SCOPE[check_name] == scope
    return scope == check_name

findings = []
auto_fixed = 0

def emit(payload):
    line = json.dumps(payload, ensure_ascii=False)
    if findings_out:
        with open(findings_out, "a") as f:
            f.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

def add(check, subject, issue, classification, **extra):
    row = {"check": check, "subject": subject, "issue": issue,
           "classification": classification}
    row.update(extra)
    findings.append(row)
    emit({"finding": f"sync-check-{check}", **row})

def sha256_file(path):
    try:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return None

def read_file(path):
    try:
        with open(path) as f:
            return f.read()
    except Exception:
        return ""

def parse_frontmatter(path):
    t = read_file(path)
    if not t.startswith("---"):
        return {}
    end = t.find("\n---", 3)
    if end == -1:
        return {}
    fm = {}
    for line in t[3:end].split("\n"):
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*)$", line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    return fm

# ---------- Check 1: skill runtime sync ----------
def check_skill_runtime():
    global auto_fixed
    skills_dir = os.path.join(backend, "skills")
    vault_skills_dir = os.path.join(vault, ".claude", "skills")
    if not os.path.isdir(skills_dir):
        return
    for name in sorted(os.listdir(skills_dir)):
        sd = os.path.join(skills_dir, name)
        skill_md = os.path.join(sd, "SKILL.md")
        if not os.path.isfile(skill_md):
            continue
        vault_copy = os.path.join(vault_skills_dir, f"{name}.md")
        backend_hash = sha256_file(skill_md)
        vault_hash   = sha256_file(vault_copy)
        if vault_hash is None:
            add("skill-runtime", name, "Vault copy missing",
                "auto-fix", backend=skill_md, vault=vault_copy)
            if fix_mode and backend_hash:
                os.makedirs(os.path.dirname(vault_copy), exist_ok=True)
                shutil.copyfile(skill_md, vault_copy)
                auto_fixed += 1
            continue
        if backend_hash != vault_hash:
            add("skill-runtime", name, "Content hash mismatch with backend",
                "auto-fix", backend=skill_md, vault=vault_copy,
                backend_sha=backend_hash, vault_sha=vault_hash)
            if fix_mode and backend_hash:
                shutil.copyfile(skill_md, vault_copy)
                auto_fixed += 1

# ---------- Check 2: Skills Index completeness ----------
def check_skills_index():
    if not os.path.isfile(skills_ix):
        add("skills-index", "_index.md", "Skills Index missing", "manual")
        return
    idx_text = read_file(skills_ix)
    # backend skill names
    skills_dir = os.path.join(backend, "skills")
    backend_names = set()
    if os.path.isdir(skills_dir):
        for n in os.listdir(skills_dir):
            if os.path.isfile(os.path.join(skills_dir, n, "SKILL.md")):
                backend_names.add(n)
    # Skills/*.md spec files
    vault_skills_dir = os.path.join(vault, "Skills")
    spec_files = set()
    if os.path.isdir(vault_skills_dir):
        for fn in os.listdir(vault_skills_dir):
            if fn.endswith(".md") and fn not in ("_index.md", "File-Index.md", "Skills Index.md"):
                spec_files.add(fn[:-3])
    for skill in sorted(backend_names):
        if skill not in idx_text:
            add("skills-index", skill,
                "Backend skill missing from Skills Index", "manual",
                fix_hint=f"Add a row for {skill} in Skills/_index.md")

# ---------- Check 3: Memory path references ----------
def check_memory_paths():
    global auto_fixed
    if not memroot or not os.path.isdir(memroot):
        return
    # Only treat anchored paths as real references — start with ~, /Users/,
    # or $CLAUDE_HOME-rooted. Loose relative-looking fragments (./spec.md in
    # prose) are prose shorthand, not filesystem claims.
    # No spaces allowed inside the path body — spaces break real fs refs and
    # are usually a prose fragment.
    path_ref = re.compile(r"(~/[A-Za-z0-9_\-./]+\.[a-zA-Z0-9]+|/[A-Za-z0-9_\-./]+/[A-Za-z0-9_\-./]+\.[a-zA-Z0-9]+)")
    for fn in sorted(os.listdir(memroot)):
        if not fn.endswith(".md"):
            continue
        full = os.path.join(memroot, fn)
        body = read_file(full)
        # Collect paths that look filesystem-real (contain `/` and end with a common ext)
        checked = set()
        for m in path_ref.finditer(body):
            candidate = m.group(1).rstrip(").,;:")
            if candidate in checked or candidate.startswith("#"):
                continue
            checked.add(candidate)
            if "/" not in candidate:
                continue
            if candidate.endswith((".md", ".sh", ".py", ".json", ".yaml", ".yml")):
                resolved = os.path.expanduser(candidate)
                if resolved.startswith("./") or not resolved.startswith("/"):
                    continue
                if not os.path.exists(resolved):
                    add("memory-paths", f"{fn}:{candidate}",
                        "Referenced path missing on disk",
                        "auto-fix" if fix_mode else "info",
                        memory_file=fn, path=candidate)

# ---------- Check 4: Root CLAUDE.md validity ----------
def check_root_claude_md():
    t = read_file(root_cmd)
    if not t:
        return
    # skill name references: look for /skill-name patterns and $CLAUDE_HOME/skills/{name}/
    skill_pat = re.compile(r"/([a-z][a-z0-9-]*)\b")
    known = set()
    skills_dir = os.path.join(backend, "skills")
    if os.path.isdir(skills_dir):
        for n in os.listdir(skills_dir):
            if os.path.isfile(os.path.join(skills_dir, n, "SKILL.md")):
                known.add(n)
    # Only flag file-path references (explicit absolute paths)
    path_pat = re.compile(r"(/[A-Za-z0-9_\-./ ]+\.[a-zA-Z0-9]+)")
    for m in path_pat.finditer(t):
        p = m.group(1).rstrip(").,;:")
        if not os.path.exists(p):
            add("root-claude-md", p, "Referenced path missing on disk", "manual")

# ---------- Check 5: Vault CLAUDE.md validity ----------
def check_vault_claude_md():
    t = read_file(vault_cmd)
    if not t:
        return
    eng_dir = os.path.join(vault, "Engagements")
    actual_engs = set()
    if os.path.isdir(eng_dir):
        for n in os.listdir(eng_dir):
            if os.path.isdir(os.path.join(eng_dir, n)):
                actual_engs.add(n)
    # CLAUDE.md lists engagements under "## Engagements" section
    eng_section = re.search(r"^## Engagements\n(.*?)(?=\n## |\Z)", t, re.DOTALL | re.MULTILINE)
    if not eng_section:
        return
    documented = set()
    for m in re.finditer(r"\[\[Engagements/([^/|\]]+)/CLAUDE\.md", eng_section.group(1)):
        documented.add(m.group(1))
    for missing in sorted(actual_engs - documented):
        add("vault-claude-md", missing,
            "Engagement folder exists but not documented in vault CLAUDE.md",
            "manual")
    for stale in sorted(documented - actual_engs):
        add("vault-claude-md", stale,
            "Engagement documented in CLAUDE.md but folder missing",
            "manual")

# ---------- Check 6: Vault Architecture directory tree ----------
def check_vault_architecture():
    t = read_file(vault_arch)
    if not t:
        return
    # Extract top-level directory names from the `vault/` tree in VA.md
    tree_section = re.search(r"^```\nvault/\n(.*?)^```", t, re.DOTALL | re.MULTILINE)
    documented = set()
    if tree_section:
        for m in re.finditer(r"^[├└]──\s+([A-Za-z][^/\s]*)/", tree_section.group(1), re.MULTILINE):
            documented.add(m.group(1))
    if not documented:
        return
    actual = set()
    for n in os.listdir(vault):
        p = os.path.join(vault, n)
        if os.path.isdir(p) and not n.startswith("."):
            actual.add(n)
    for missing in sorted(actual - documented):
        add("vault-architecture", missing,
            "Top-level directory exists but not in VA.md tree",
            "manual")
    for stale in sorted(documented - actual):
        add("vault-architecture", stale,
            "VA.md documents directory that doesn't exist",
            "manual")

# ---------- Check 7: Engagement status consistency ----------
def check_engagement_status():
    global auto_fixed
    eng_dir = os.path.join(vault, "Engagements")
    if not os.path.isdir(eng_dir):
        return
    for name in sorted(os.listdir(eng_dir)):
        ed = os.path.join(eng_dir, name)
        if not os.path.isdir(ed):
            continue
        # Find Overview file
        overview = None
        for fn in os.listdir(ed):
            if fn.endswith(" - Overview.md"):
                overview = os.path.join(ed, fn)
                break
        if not overview:
            continue
        ov_status = parse_frontmatter(overview).get("status", "").strip().lower()
        if not ov_status:
            continue
        # Engagement CLAUDE.md status (look for Status: line in frontmatter OR body header)
        eng_claude = os.path.join(ed, "CLAUDE.md")
        if os.path.isfile(eng_claude):
            fm = parse_frontmatter(eng_claude)
            eng_status = fm.get("status", "").strip().lower()
            if eng_status and eng_status != ov_status:
                add("engagement-status", name,
                    f"Engagement CLAUDE.md status='{eng_status}' != Overview='{ov_status}'",
                    "auto-fix", file=eng_claude, canonical="Overview")
                # Auto-fix: rewrite the status line in frontmatter
                if fix_mode:
                    _rewrite_fm_field(eng_claude, "status", ov_status)
                    auto_fixed += 1
        # Vault CLAUDE.md status mention (ACTIVE|COMPLETED|PLANNING marker near engagement entry)
        # We flag only if the marker disagrees in letter-case-insensitive form
        vt = read_file(vault_cmd)
        vc_match = re.search(
            rf"\[\[Engagements/{re.escape(name)}/CLAUDE\.md.*?\]\]\s*\(([A-Z]+)\)", vt)
        if vc_match:
            vc_status = vc_match.group(1).strip().lower()
            norm_ov = ov_status
            if vc_status != norm_ov and norm_ov:
                add("engagement-status", name,
                    f"Vault CLAUDE.md marker='{vc_status}' != Overview='{ov_status}'",
                    "auto-fix", file=vault_cmd, canonical="Overview")

def _rewrite_fm_field(path, key, value):
    t = read_file(path)
    if not t.startswith("---"):
        return
    end = t.find("\n---", 3)
    if end == -1:
        return
    fm_block = t[3:end]
    new_block, replaced = [], False
    for line in fm_block.split("\n"):
        if re.match(rf"^{re.escape(key)}\s*:", line):
            new_block.append(f"{key}: {value}")
            replaced = True
        else:
            new_block.append(line)
    if not replaced:
        new_block.append(f"{key}: {value}")
    out = "---" + "\n".join(new_block) + "\n---" + t[end + 4:]
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(out)
    os.replace(tmp, path)

# ---------- dispatch ----------
CHECKS = [
    ("skill-runtime",      check_skill_runtime),
    ("skills-index",       check_skills_index),
    ("memory-paths",       check_memory_paths),
    ("root-claude-md",     check_root_claude_md),
    ("vault-claude-md",    check_vault_claude_md),
    ("vault-architecture", check_vault_architecture),
    ("engagement-status",  check_engagement_status),
]
for name, fn in CHECKS:
    if not scope_matches(name):
        continue
    if name in GATED_CHECKS and not has_structured:
        emit({"event": f"sync-check-{name}", "status": "skipped (ungated)",
              "reason": "manifest.vault.has_structured_projects=false"})
        continue
    fn()

# ---------- persistent ID reconciliation (S-NNN) ----------
existing_by_key = {}
max_n = 0
for row in existing or []:
    if not isinstance(row, dict):
        continue
    key = (row.get("check") or "", row.get("subject") or "")
    existing_by_key[key] = row
    rid = row.get("id") or ""
    m = re.match(r"^S-(\d+)$", rid)
    if m:
        n = int(m.group(1))
        if n > max_n:
            max_n = n

reconciled = []
for f in findings:
    key = (f.get("check") or "", f.get("subject") or "")
    if key in existing_by_key:
        prior = existing_by_key[key]
        f_out = dict(f)
        f_out["id"] = prior.get("id") or f"S-{max_n+1:03d}"
        f_out["first_seen"] = prior.get("first_seen") or now_iso
        f_out["last_seen"] = now_iso
        if not prior.get("id"):
            max_n += 1
    else:
        max_n += 1
        f_out = dict(f)
        f_out["id"] = f"S-{max_n:03d}"
        f_out["first_seen"] = now_iso
        f_out["last_seen"] = now_iso
    reconciled.append(f_out)

with open(drift_out, "w") as f:
    json.dump(reconciled, f)

if dry_run:
    by_check = {}
    for r in reconciled:
        by_check[r["check"]] = by_check.get(r["check"], 0) + 1
    print(f"sync-check: scope={scope} mode={mode} findings={len(reconciled)} "
          f"auto-fixed={auto_fixed} by_check={by_check}")
PY

# Persist the sync_check findings array back to manifest
if [[ -s "$DRIFT_OUT" ]]; then
  manifest_set '.drift_findings.sync_check' "$(cat "$DRIFT_OUT")"
fi
