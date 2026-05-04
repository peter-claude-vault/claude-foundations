#!/usr/bin/env bash
# plaintext.sh — SP13 T-3 plaintext parser. Pass-through.
set -u
[ $# -eq 1 ] || { echo "plaintext.sh: usage: plaintext.sh <PATH>" >&2; exit 2; }
cat "$1"
