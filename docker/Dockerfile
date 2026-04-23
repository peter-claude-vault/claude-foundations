# syntax=docker/dockerfile:1.7
#
# Claude Foundations Engine v2 — SP00 isolation image.
#
# Built INSIDE the Lima VM (docker/build.sh handles the source transfer).
# The host never invokes `docker build` directly; Docker runs only within
# the Lima kernel boundary where `mounts: []` already removes /Users.
#
# Key invariants established here:
#   - tester user with uid 1000 is the ONLY unprivileged user; /etc/passwd
#     remap makes os.path.expanduser("~/.claude") resolve to
#     /home/tester/.claude regardless of any HOME= env trick.
#   - /home/tester is tmpfs at runtime (passed via `docker run --tmpfs`
#     in docker/build.sh and tests/runner-shell.sh).
#   - ENV MOCK_LAUNCHCTL=1 + TEST_MODE=1 baked in; SP03/SP07 consume these.
#   - Entrypoint is docker/entrypoint-scrub-env.sh (T-3) — strips every
#     env var not on the explicit allowlist before handing off to CMD.

FROM ubuntu:24.04

# Pin tooling versions where we can; apt repositories drift but the set of
# packages we depend on is small enough to audit by hand.
ENV DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8

# --- System tooling ---
# bash (R-23 target), jq (capability scripts), git (plan/snapshot helpers),
# python3 + pip (grep-audit layers 2/3, plist-lint via plistlib), curl,
# ca-certs, rsync, openssh-client (scp exfil). plutil is macOS-only; we use
# a Python-plistlib shim in tests/plist-lint.sh instead.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        jq \
        openssh-client \
        python3 \
        python3-pip \
        rsync \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# jsonschema via pip (Ubuntu python3-jsonschema is old). Break-system-packages
# is intentional — this is an isolated test image, not a user workstation.
RUN pip3 install --no-cache-dir --break-system-packages \
        jsonschema==4.22.0

# --- The tester user ---
# uid 1000 is the ONLY numeric identity inside this image. /etc/passwd remap
# establishes the HOME floor; $HOME env cannot override os.path.expanduser.
# --shell /bin/bash because R-23 scripts depend on bash (not /bin/sh).
RUN useradd --create-home --uid 1000 --shell /bin/bash tester \
 && chown -R tester:tester /home/tester

# --- Claude Code install ---
# Placeholder. The real install happens in a later sub-plan (SP08 installer).
# For SP00 dogfood the image does not need Claude Code installed; downstream
# consumers that need it (SP03 cold-wake probe, SP07 voice extraction) add
# the install step in their own build-args before running. Documenting the
# hook here so the substitution surface is visible.
# ARG CLAUDE_CODE_SHA=<pinned-sha>
# RUN curl -fsSL <pinned-url> -o /tmp/cc.tgz \
#   && (echo "${CLAUDE_CODE_SHA}  /tmp/cc.tgz" | sha256sum -c -) \
#   && tar -xzf /tmp/cc.tgz -C /usr/local

# --- Environment floor ---
# CLAUDE_HOME and PLANS_HOME are the explicit identifiers downstream code
# consumes; they resolve inside /home/tester via the passwd remap. TEST_MODE
# and MOCK_LAUNCHCTL signal to hooks and orchestration code that this is not
# a production Claude Code session. CI=1 suppresses interactive prompts.
ENV CLAUDE_HOME=/home/tester/.claude \
    PLANS_HOME=/home/tester/.claude-plans \
    TEST_MODE=1 \
    MOCK_LAUNCHCTL=1 \
    CI=1

# --- SP00 test surface ---
# The entire /tests tree is copied in at a fixed path so tests/runner-shell.sh
# finds its peers deterministically. Runtime code is READ-ONLY (chown root);
# $DOGFOOD_ROOT (mktemp -d under /tmp/) is the ONLY writable subtree.
# Ownership is intentional: tester executes but cannot modify the harness.
COPY --chown=root:root tests/                 /tests/
COPY --chown=root:root docker/entrypoint-scrub-env.sh /entrypoint.sh
RUN chmod 0755 /tests/*.sh /entrypoint.sh \
 && ln -s /tests/grep-audit-patterns /etc/grep-audit-patterns

# --- MOCK_LAUNCHCTL wiring ---
# Short-circuit the real launchctl binary (which doesn't exist on Linux)
# to the mock stub. SP03/SP07 tests invoke `launchctl bootstrap` and must
# route through the mock to record traces in /results/launchctl-trace.ndjson.
RUN ln -s /tests/mock-launchctl.sh /usr/local/bin/launchctl

USER tester
WORKDIR /home/tester

# /results is the exfil surface: JSON summaries, ndjson traces, audit logs.
# Created as tester-owned so tests can write without sudo; scp retrieves
# the tree to the host (not bind-mounted — see lima/foundations.yaml).
RUN mkdir -p /home/tester/.claude \
             /home/tester/.claude-plans \
             /results

ENTRYPOINT ["/entrypoint.sh"]
# Default CMD runs the readiness gate alone — any invocation without an
# explicit CMD proves the isolation invariants hold or exits 2 loudly.
CMD ["/tests/readiness-gate.sh"]
