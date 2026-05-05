#!/usr/bin/env python3
"""corpus.py — SP13 T-15 unclassified-pile UX-validation fixture synthesizer.

Emits a 20-file synthetic consultant corpus into a target directory in one
of three variants, controlled by --variant. The variants stress the
unclassified-pile gate's three behavioral cases:

    --variant a   ~10 unclassifiable items + 10 project content (2 clusters
                  of 5). Drives the high-unclassified path: gate FIRES and
                  the user-facing copy must explain disposition options.

    --variant b   1 unclassifiable item + 19 project content (2 clusters of
                  ~10). Drives the single-item edge case: gate FIRES but
                  the copy must read naturally for n=1 (NOT plural-only).

    --variant c   0 unclassifiable items + 20 project content. Drives the
                  silent-skip path: gate must NOT render the call-out at
                  all; pipeline proceeds to Stage 3.

Every variant emits exactly 20 files. Format mix is identical to T-14's
fixture (markdown + plaintext) so format-detector + ir-builder behavior
is held constant — only the unclassified-density signal varies.

The corpus deliberately avoids real-world entity names; everything is
synthetic and safe to commit + re-render.

Usage:
    python3 corpus.py --variant a --out-dir <path>
"""

import argparse
import os
import sys
import textwrap


PROJECT_ALPHA_KEYWORDS = "alpha engagement strategy growth analytics"
PROJECT_BETA_KEYWORDS = "beta launch readiness rollout enterprise"

ALPHA_BODY = textwrap.dedent("""\
    The {label} engagement work centers on growth analytics for the regional
    market. Strategy alignment focuses on customer expansion. Stakeholder
    interviews surface engagement priorities; the alpha team's growth
    analytics workstream owns Q3 deliverables. Engagement governance for
    alpha runs weekly. Strategy decisions for the alpha account flow through
    the alpha steering committee. Growth analytics for the alpha portfolio
    drive prioritization. Alpha's customer growth metrics anchor the
    quarterly review.
""")

BETA_BODY = textwrap.dedent("""\
    The {label} launch readiness workstream coordinates rollout activities
    across enterprise channels. Beta launch milestones include pilot
    deployment, enterprise customer onboarding, and channel readiness.
    Enterprise rollout for the beta product requires beta-readiness gating.
    Rollout planning for beta covers enterprise pilot windows. Beta's
    enterprise launch sequence enforces rollout gates. Launch readiness
    reviews for beta cover enterprise rollout dependencies. Beta enterprise
    rollout depends on launch readiness sign-off.
""")


UNCLASSIFIED_BODIES = [
    "Random thought captured between calls. Will figure out where this goes later.",
    "Quick scratch note. Misc fragment of an idea half-typed before lunch.",
    "Loose observation. Not sure if this belongs to any active workstream.",
    "Personal todo dump. Mixed bag of unrelated reminders typed in a hurry.",
    "Brain dump from the airport. Disconnected items, no clear theme.",
    "End-of-day notes. Stray thoughts before logging off; no project tag.",
    "Drafty paragraph. Trying out phrasing for something I might write later.",
    "Captured snippet from a podcast. Reference unclear; might delete.",
    "One-off observation. No engagement, no reference, no meeting context.",
    "Stream-of-consciousness fragment. Half-formed; revisit when fresh.",
]


def _write(path: str, body: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(body)


def _emit_project_block(out_dir, label, body_template, count, start_idx=1):
    for i in range(start_idx, start_idx + count):
        path = os.path.join(out_dir, f"{label}-engagement-{i}.md")
        heading = f"{label.capitalize()} engagement note {i}"
        body = f"# {heading}\n\n" + body_template.format(label=label)
        _write(path, body)


def _emit_unclassified(out_dir, count):
    for i in range(1, count + 1):
        body = UNCLASSIFIED_BODIES[(i - 1) % len(UNCLASSIFIED_BODIES)]
        path = os.path.join(out_dir, f"loose-note-{i}.md")
        _write(path, f"# Loose note {i}\n\n{body}\n")


def emit_variant_a(out_dir):
    """High-unclassified: 10 project + 10 unclassifiable. 2 clusters of 5."""
    _emit_project_block(out_dir, "alpha", ALPHA_BODY, count=5)
    _emit_project_block(out_dir, "beta", BETA_BODY, count=5)
    _emit_unclassified(out_dir, count=10)


def emit_variant_b(out_dir):
    """Low-unclassified: 19 project + 1 unclassifiable. 2 clusters of ~10."""
    _emit_project_block(out_dir, "alpha", ALPHA_BODY, count=10)
    _emit_project_block(out_dir, "beta", BETA_BODY, count=9)
    _emit_unclassified(out_dir, count=1)


def emit_variant_c(out_dir):
    """Zero-unclassified: 20 project. 2 clusters of 10."""
    _emit_project_block(out_dir, "alpha", ALPHA_BODY, count=10)
    _emit_project_block(out_dir, "beta", BETA_BODY, count=10)


VARIANT_EMITTERS = {
    "a": emit_variant_a,
    "b": emit_variant_b,
    "c": emit_variant_c,
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--variant", required=True, choices=["a", "b", "c"])
    ap.add_argument("--out-dir", required=True, help="target directory")
    args = ap.parse_args()
    out_dir = os.path.abspath(args.out_dir)
    os.makedirs(out_dir, exist_ok=True)
    VARIANT_EMITTERS[args.variant](out_dir)
    n = sum(1 for _root, _dirs, files in os.walk(out_dir) for _f in files)
    print(f"variant={args.variant} emitted {n} files under {out_dir}")
    if n != 20:
        print(f"WARN: expected 20 files; emitted {n}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
