#!/bin/bash
# 7-case synthetic harness — case 06/07.
# Class: fail-hard (exit 2 — infrastructure fault at the lowest fail-hard
# boundary; readiness-gate exit 2 semantics).
printf 'case 06: simulated missing tool\n' >&2
exit 2
