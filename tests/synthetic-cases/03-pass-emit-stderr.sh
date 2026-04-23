#!/bin/bash
# 7-case synthetic harness — case 03/07.
# Class: pass.
# Proves runner-shell merges stderr into /results/<case>.log alongside stdout.
printf 'case 03 stdout line\n'
printf 'case 03 stderr line\n' >&2
exit 0
