#!/usr/bin/env bash
# pdf.sh — SP13 T-3 PDF parser. Uses pdftotext when available; otherwise
# emits a graceful-degrade marker.
set -u
[ $# -eq 1 ] || { echo "pdf.sh: usage: pdf.sh <PATH>" >&2; exit 2; }
in="$1"
if command -v pdftotext >/dev/null 2>&1; then
  pdftotext "$in" - 2>/dev/null || \
    printf '[binary content not extracted: pdftotext parse error]\n'
else
  printf '[binary content not extracted: pdftotext unavailable]\n'
fi
