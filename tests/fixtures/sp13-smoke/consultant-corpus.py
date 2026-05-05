#!/usr/bin/env python3
"""consultant-corpus.py — SP13 T-14 smoke-test fixture synthesizer.

Emits a 50-file synthetic consultant corpus into a target directory. The
corpus stresses every disposition path the SP13 pipeline must service:

    24 project content files across 3 detectable clusters (alpha / beta / gamma)
        — keyword-coherent paragraphs that density-cluster cleanly under
          stub embeddings (MD5 term-frequency).
     8 meeting fragments (6 .md + 2 .vtt)
        — timestamp + speaker markers; meeting-keyword density routes to
          type=meeting in propose-taxonomy stub.
     9 reference docs (8 .md + 1 .markdown)
        — methodology / regulation / framework keywords; type=reference.
     9 unclassifiable items (6 .md + 3 .txt)
        — keyword-sparse, heterogeneous; routes to type=unclassified.

Total: 50 files. Format mix covers .md / .markdown / .txt / .vtt — all
recognized by Stage 1 format-detector.sh.

The corpus deliberately avoids real-world entity names. Everything is
synthetic; safe to commit + re-render.

Usage:
    python3 consultant-corpus.py --out-dir <path>
"""

import argparse
import os
import sys
import textwrap


PROJECT_ALPHA_KEYWORDS = "alpha engagement strategy growth analytics"
PROJECT_BETA_KEYWORDS = "beta launch readiness rollout enterprise"
PROJECT_GAMMA_KEYWORDS = "gamma research benchmark protocol evaluation"

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

GAMMA_BODY = textwrap.dedent("""\
    The {label} research workstream evaluates benchmark protocols against
    target corpora. Gamma research evaluation runs benchmark protocols
    against multiple corpora. Research benchmark protocols for gamma cover
    evaluation rubrics. Gamma's evaluation protocol benchmarks research
    outputs. Benchmark research for gamma evaluates protocol fidelity.
    Evaluation protocols for gamma research are tracked in the benchmark
    log. Research evaluation for gamma covers benchmark protocol drift.
""")


MEETING_BODIES = [
    textwrap.dedent("""\
        [10:00] Speaker A: Let's open the standup. Status updates around the
        meeting cadence and the meeting recording schedule.
        [10:02] Speaker B: Recording is on. Meeting agenda is the standup
        rotation.
        [10:05] Speaker A: Standup decisions for next meeting include the
        meeting-recording archive policy.
    """),
    textwrap.dedent("""\
        [14:00] Speaker C: Welcome to the steering meeting. Meeting minutes
        will be circulated. Recording is on.
        [14:05] Speaker D: Discussion notes on engagement priorities. Meeting
        agenda includes the standup readout and meeting cadence review.
    """),
    textwrap.dedent("""\
        [09:30] Speaker A: Weekly check-in meeting. Recording on; meeting
        minutes after.
        [09:34] Speaker B: Status review for the engagement steering call.
        Meeting cadence is weekly. Recording archive maintained.
    """),
    textwrap.dedent("""\
        [16:00] Speaker D: Client check-in meeting. Meeting recording is on.
        [16:03] Speaker A: Walking through deliverables. Meeting minutes will
        capture the agreed actions. Standup cadence covered.
    """),
    textwrap.dedent("""\
        [11:00] Speaker B: Project standup meeting. Recording on; meeting
        agenda is the rolling status review across active engagements.
        [11:05] Speaker C: Meeting minutes will reflect open standup items.
    """),
    textwrap.dedent("""\
        [13:00] Speaker A: Engagement review meeting. Recording on; meeting
        agenda anchors next steps for the steering call.
        [13:04] Speaker D: Meeting minutes capture the steering decisions.
    """),
]

VTT_BODIES = [
    textwrap.dedent("""\
        WEBVTT

        NOTE
        Recorded standup meeting.

        1
        00:00:00.000 --> 00:00:06.000
        Speaker A: Welcome to the standup meeting. Recording is on.

        2
        00:00:06.000 --> 00:00:14.000
        Speaker B: Status updates across the steering meeting cadence.
    """),
    textwrap.dedent("""\
        WEBVTT

        NOTE
        Engagement steering meeting.

        1
        00:00:00.000 --> 00:00:08.000
        Speaker C: Steering meeting agenda. Recording on.

        2
        00:00:08.000 --> 00:00:18.000
        Speaker D: Meeting minutes capture standup readouts and cadence.
    """),
]


REFERENCE_BODIES = [
    textwrap.dedent("""\
        Methodology reference. Standard methodology framework for consulting
        engagements; methodology covers governance, regulatory framework,
        compliance reference, and policy framework. Reference framework
        adopted across engagements.
    """),
    textwrap.dedent("""\
        Regulatory framework reference. Methodology covers regulatory
        compliance framework. Regulation reference for industry standards
        practitioners. Framework reference document; policy reference
        framework adopted.
    """),
    textwrap.dedent("""\
        Compliance framework reference. Methodology framework reference
        covering policy compliance, regulatory reference, and governance
        framework. Industry-standard reference policy framework.
    """),
    textwrap.dedent("""\
        Governance framework reference. Methodology reference framework
        across consulting engagements. Reference covers governance policy,
        compliance framework reference, regulatory reference standards.
    """),
    textwrap.dedent("""\
        Policy reference framework. Methodology framework adopted for
        consulting reference; policy reference covers compliance, regulatory
        framework reference, governance methodology.
    """),
    textwrap.dedent("""\
        Industry framework reference document. Methodology framework
        reference for industry consulting. Compliance reference framework
        across industry policy, regulatory framework, governance reference.
    """),
    textwrap.dedent("""\
        Reference framework methodology. Industry framework methodology
        reference; compliance methodology reference framework; regulatory
        framework reference policy across consulting engagements.
    """),
    textwrap.dedent("""\
        Regulatory reference framework. Industry methodology framework
        reference; policy framework reference covering compliance reference,
        governance reference, regulatory methodology framework.
    """),
    textwrap.dedent("""\
        Methodology framework reference adopted. Compliance reference
        framework for consulting industry; regulatory framework reference
        policy; governance methodology framework reference document.
    """),
]


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
]


def _write(path: str, body: str) -> None:
    """Write body to path, creating parent dirs as needed."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(body)


def emit_corpus(out_dir: str) -> int:
    """Emit the 50-file fixture into out_dir. Returns total file count."""
    n = 0

    # 24 project content files: 8 per cluster (alpha / beta / gamma).
    project_specs = [
        ("alpha", PROJECT_ALPHA_KEYWORDS, ALPHA_BODY),
        ("beta", PROJECT_BETA_KEYWORDS, BETA_BODY),
        ("gamma", PROJECT_GAMMA_KEYWORDS, GAMMA_BODY),
    ]
    for label, _kw, body_template in project_specs:
        for i in range(1, 9):  # 8 per project
            path = os.path.join(out_dir, f"{label}-engagement-{i}.md")
            heading = f"{label.capitalize()} engagement note {i}"
            body = f"# {heading}\n\n" + body_template.format(label=label)
            _write(path, body)
            n += 1

    # 8 meeting fragments: 6 .md + 2 .vtt.
    for i, body in enumerate(MEETING_BODIES, start=1):
        path = os.path.join(out_dir, f"meeting-fragment-{i}.md")
        body_full = f"# Meeting fragment {i}\n\n{body}"
        _write(path, body_full)
        n += 1
    for i, body in enumerate(VTT_BODIES, start=1):
        path = os.path.join(out_dir, f"meeting-recording-{i}.vtt")
        _write(path, body)
        n += 1

    # 9 reference docs: 8 .md + 1 .markdown.
    for i, body in enumerate(REFERENCE_BODIES[:8], start=1):
        path = os.path.join(out_dir, "reference", f"reference-doc-{i}.md")
        body_full = f"# Reference doc {i}\n\n{body}"
        _write(path, body_full)
        n += 1
    body = REFERENCE_BODIES[8]
    path = os.path.join(out_dir, "reference", "reference-doc-9.markdown")
    _write(path, f"# Reference doc 9\n\n{body}")
    n += 1

    # 9 unclassifiable items: 6 .md + 3 .txt.
    for i, body in enumerate(UNCLASSIFIED_BODIES[:6], start=1):
        path = os.path.join(out_dir, f"loose-note-{i}.md")
        _write(path, f"# Loose note {i}\n\n{body}\n")
        n += 1
    for i, body in enumerate(UNCLASSIFIED_BODIES[6:], start=7):
        path = os.path.join(out_dir, f"loose-note-{i}.txt")
        _write(path, f"{body}\n")
        n += 1

    return n


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out-dir", required=True, help="target directory")
    args = ap.parse_args()
    out_dir = os.path.abspath(args.out_dir)
    os.makedirs(out_dir, exist_ok=True)
    n = emit_corpus(out_dir)
    print(f"emitted {n} files under {out_dir}")
    if n != 50:
        print(f"WARN: expected 50 files; emitted {n}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
