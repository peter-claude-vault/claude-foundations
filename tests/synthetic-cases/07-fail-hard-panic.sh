#!/bin/bash
# 7-case synthetic harness — case 07/07.
# Class: fail-hard (exit 3 — higher fail-hard code; runner aggregates via
# max() so this should become the runner's aggregate_exit).
printf 'case 07: simulated panic; aborting early\n' >&2
exit 3
