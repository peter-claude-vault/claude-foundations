#!/bin/bash
# 7-case synthetic harness — case 05/07.
# Class: fail-soft (exit 1 — second soft failure confirms runner doesn't
# short-circuit after the first fail-soft).
printf 'case 05: expected=foo got=bar\n' >&2
exit 1
