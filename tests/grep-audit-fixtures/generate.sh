#!/bin/bash
# tests/grep-audit-fixtures/generate.sh
#
# Regenerates fixture-layer2-nfkc.txt and fixture-layer3-base64.txt. Run
# after any change to the pattern list.
#
# Layer 1 (raw) and Layer 4 (git history) fixtures are handled differently:
#   - Layer 1: fixture-layer1-raw.txt is hand-written (ASCII, git-safe).
#   - Layer 4: fixture-layer4-history is generated per-invocation inside an
#              isolated throwaway repo under $DOGFOOD_ROOT by the unit test.

set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Layer 2: mathematical-bold "petertiktinsky" (matches literal.txt) ---
python3 - "${SCRIPT_DIR}/fixture-layer2-nfkc.txt" <<'PY'
import sys
out = sys.argv[1]
# Mathematical Bold Small Letters start at U+1D41A ('a'). Remap each ASCII
# lowercase letter to its bold equivalent. NFKC maps back to ASCII, so the
# full "petertiktinsky" string reappears after normalization and hits the
# literal pattern list.
def bold(s: str) -> str:
    OFFSET = 0x1D41A - ord('a')
    return ''.join(chr(ord(c) + OFFSET) if 'a' <= c <= 'z' else c for c in s)
bold_id = bold("petertiktinsky")
with open(out, "w", encoding="utf-8") as fh:
    fh.write("Layer 2 fixture: Unicode mathematical-bold obfuscation.\n\n")
    fh.write("Obfuscated identifier below; raw-layer scan misses it.\n")
    fh.write("NFKC-normalized scan matches the literal pattern list.\n\n")
    fh.write(bold_id + "\n")
PY

# --- Layer 3: base64-encoded literal ---
python3 - "${SCRIPT_DIR}/fixture-layer3-base64.txt" <<'PY'
import sys, base64
out = sys.argv[1]
payload = b"the identifier petertiktinsky appears inside this decoded blob"
# Pad to > 40 chars of raw base64 so our blob_re matches.
# Actual encoded length: len(payload) * 4 // 3 rounded up. 62 chars -> ~84.
b64 = base64.b64encode(payload).decode("ascii")
with open(out, "w", encoding="utf-8") as fh:
    fh.write("Layer 3 fixture: base64-encoded leak.\n\n")
    fh.write("Encoded blob (Layer 1/2 miss; Layer 3 decode catches):\n")
    fh.write(b64 + "\n")
PY

printf 'generated: %s/fixture-layer2-nfkc.txt\n' "$SCRIPT_DIR"
printf 'generated: %s/fixture-layer3-base64.txt\n' "$SCRIPT_DIR"
