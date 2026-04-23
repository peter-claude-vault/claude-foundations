#!/bin/bash
# docker/entrypoint-scrub-env.sh
#
# SP00 T-3 — container ENTRYPOINT env-var allowlist gate.
#
# Threat model: a test invocation may inherit host-derived credentials or
# configuration (ANTHROPIC_API_KEY, SSH_AUTH_SOCK, KEYCHAIN_*, AWS_*, OP_*,
# CLAUDE_CODE_*, arbitrary *_TOKEN / *_SECRET vars) that would contaminate
# the isolation envelope. The Dockerfile's MOCK_LAUNCHCTL and TEST_MODE are
# also forgeable from the host side. This script is the single choke point
# where those are stripped before the Claude Code surface sees them.
#
# Design: deny-default. `env -i` clears the entire environment; we then
# reintroduce only:
#   1. A hardcoded safe PATH.
#   2. HOME + USER re-derived from /etc/passwd (NOT from env). This defeats
#      the April-13 vector where an adversary rewrites $HOME to redirect
#      os.path.expanduser("~") — Python's pwd.getpwuid() consults passwd
#      when $HOME is unset, and our Dockerfile's tester:1000:1000::/home/tester
#      line is the floor.
#   3. The allowlisted foundation-test env vars, preserving their values from
#      the original environment if (and only if) they were set.
#
# Allowlist (the ONLY vars that survive the scrub, besides PATH/HOME/USER):
#   CLAUDE_HOME            — resolved installer directory (SP08)
#   PLANS_HOME             — resolved plans directory
#   TEST_MODE              — signals test-harness context to hooks
#   MOCK_LAUNCHCTL         — short-circuits real launchctl to tests/mock-launchctl.sh
#   CI                     — suppresses interactive prompts
#   DOGFOOD_ROOT           — per-test mktemp -d root (SP00 T-6)
#   FOUNDATION_TEST_MODE   — enables pre-write-guard foundation branch (SP00 T-4)
#
# Anything not in this list is gone. No denylist. No escape hatch. If a future
# sub-plan needs a new env var, it lands here with a documented consumer.
#
# After the scrub, exec hands off to the container's CMD (default is
# /tests/readiness-gate.sh per Dockerfile). `exec env -i ... "$@"` replaces
# this process with env, which execs the final command — no lingering shell.
#
# R-23: bash 3.2 compat (macOS factory bash is the floor; Linux bash 5.x is
# fine either way). Uses indirect expansion `${!var+set}` + bash arrays,
# both available in 3.2.

set -u

# Single source of truth for the allowlist. Keep alphabetical for audit.
ALLOWED_VARS='
  CI
  CLAUDE_HOME
  DOGFOOD_ROOT
  FOUNDATION_TEST_MODE
  MOCK_LAUNCHCTL
  PLANS_HOME
  TEST_MODE
'

# Safe defaults derived from /etc/passwd, not from environment.
# getent is present on Ubuntu 24.04 and most distros; fall back to awk on
# /etc/passwd directly if getent is ever missing (static-linked containers).
uid=$(id -u)
if command -v getent >/dev/null 2>&1; then
  passwd_line=$(getent passwd "$uid")
else
  passwd_line=$(awk -F: -v u="$uid" '$3==u {print; exit}' /etc/passwd)
fi
if [ -z "$passwd_line" ]; then
  printf 'entrypoint-scrub-env: /etc/passwd has no entry for uid=%s — container tamper?\n' "$uid" >&2
  exit 2
fi
user_val=$(printf '%s' "$passwd_line" | cut -d: -f1)
home_val=$(printf '%s' "$passwd_line" | cut -d: -f6)

if [ -z "$user_val" ] || [ -z "$home_val" ]; then
  printf 'entrypoint-scrub-env: /etc/passwd entry for uid=%s is malformed\n' "$uid" >&2
  exit 2
fi

# Build the env -i argument list. Bash array — R-23 supports this.
declare -a envargs=()
envargs+=("HOME=$home_val")
envargs+=("USER=$user_val")
envargs+=("LOGNAME=$user_val")
# Minimum PATH for bash/coreutils/python3/nerdctl-run targets. No ~/bin, no
# /tmp/ injections, no dev paths.
envargs+=("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")

# Preserve allowlisted vars from the original (pre-scrub) environment.
# Indirect expansion requires a word, not a possibly-whitespace-padded string
# — strip the ALLOWED_VARS heredoc layout here.
for var in $ALLOWED_VARS; do
  # ${!var+set} is indirect expansion: expand $var to a name, then test if
  # THAT name is set. bash 3.2 supports this.
  if [ "${!var+set}" = 'set' ]; then
    envargs+=("$var=${!var}")
  fi
done

# Require at least one argument — the downstream command. If someone
# overrode both ENTRYPOINT and CMD to empty, that's a misconfiguration.
if [ "$#" -eq 0 ]; then
  printf 'entrypoint-scrub-env: no command to exec (CMD empty and no args); refusing to run empty container\n' >&2
  exit 2
fi

# `exec env -i` replaces this shell with `env`, which strips every var not
# in envargs and then execs "$@". End state: the container's command runs
# with exactly PATH/HOME/USER/LOGNAME plus the set-subset of ALLOWED_VARS.
exec env -i "${envargs[@]}" "$@"
