---
altitude: system
scope: Setup direction for the claude-mem pre-req — memory-layer enabler for Claude Stem. Soft-mandated; skip path coherent (within-session memory only).
validity_window: 2026-05-10..2026-11-10
source_dependencies:
  - Plan 81 SP02 spec.md §Pre-reqs (L137-141)
  - Plan 80 SP02 packet T8 §6 (pre-req table)
  - feedback_keep_claude_mem_running (memory)
  - claude-mem GitHub repo (canonical source)
last_reviewed: 2026-05-10
canonical_url: https://stem.peter.dev/research/vault-construction/setup-directions/claude-mem/
url_stability: locked-from-2026-05-10
---

# claude-mem plugin — memory-layer enabler

## Rationale

Claude's memory layer extends across sessions when claude-mem is running. Without it, Claude only remembers within-session context — every new conversation starts cold, with no recall of your preferences, your past decisions, your project history.

The MEMORY pillar in the system architecture (see [`../mental-model.md`](../mental-model.md)) depends on claude-mem for the cross-session persistence half of its job. The within-session half (Claude's own memory + your manual `~/.claude/CLAUDE.md` rules) works without it. But "remember" loses most of its meaning if it stops at session boundaries.

claude-mem also powers the `mem-search` skill — the way you ask "did we already solve this?" and get an answer drawn from prior conversations.

## Install steps

1. Confirm Claude Code is installed (the CLI tool). claude-mem is a plugin that runs alongside it.
2. Install claude-mem per the instructions at the project's repository (`https://github.com/anthropics/claude-mem` — confirm canonical source at install time; URL is the directional pointer, distribution mechanism may evolve).
3. Verify install: run `claude-mem --version` (or the equivalent plugin-status check claude-mem documents at install time).
4. Confirm the SessionEnd hook is active. `feedback_keep_claude_mem_running` is load-bearing for auto-memory; if claude-mem is installed but the hook is disabled, you get the install without the cross-session benefit.

## If skipped

Memory is limited to within-session context plus whatever you write into `~/.claude/CLAUDE.md` manually. Specifically:

- **No cross-session learned patterns.** Each conversation starts cold; preferences and decisions from yesterday's conversation are not available today unless you wrote them into a CLAUDE.md file.
- **No `mem-search`.** The skill exists but has nothing persistent to search.
- **Manual memory work falls on you.** You become responsible for distilling cross-session context into CLAUDE.md updates yourself.

The skip path is coherent: the system functions, every other pillar works, and you can manage memory manually via CLAUDE.md. The cost is significant token reuse on context you have already provided in past conversations — the architecture works around that, but less efficiently.

## Source pointers

- Plan 81 SP02 spec.md §Pre-reqs table (L137-141)
- Plan 80 SP02 packet T8 §6 (claude-mem row)
- `feedback_keep_claude_mem_running` (memory) — never disable claude-mem SessionEnd hook
- claude-mem repository (confirm canonical URL at install time): <https://github.com/anthropics/claude-mem>
