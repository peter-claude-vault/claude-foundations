#!/bin/bash
# 7-case synthetic harness — case 04/07.
# Class: fail-soft (exit 1 — assertion failure, test ran to completion).
# Proves runner-shell maps exit 1 → "fail-soft" status.
printf 'case 04: asserting 2+2 == 5\n'
if [ $(( 2 + 2 )) -ne 5 ]; then
  printf 'case 04 FAIL: 2+2 != 5 (soft)\n' >&2
  exit 1
fi
exit 0
