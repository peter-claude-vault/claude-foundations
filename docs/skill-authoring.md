# Authoring New Skills

A skill that ships with the Claude Foundations engine must meet four requirements.

## 1. Frontmatter

Every `SKILL.md` starts with YAML frontmatter:

```markdown
---
name: skill-name
description: One sentence. What it does, when to invoke it. This text is how the model decides whether to call your skill.
---
```

## 2. Environment convention

If the skill touches `$CLAUDE_HOME` or the vault, resolve paths through the standard convention at the top of the skill:

```
CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"
MANIFEST="${CLAUDE_MANIFEST:-$CLAUDE_DIR/user-manifest.json}"
```

Never write outside `$CLAUDE_DIR` or the vault root declared in `manifest.vault.root`.

## 3. Output Contract (mandatory for vault writers)

If the skill writes to the managed vault, include an Output Contract section (see `docs/output-contracts.md` for the full spec):

```markdown
## Output Contract

Files written:
  - <paths>

Schema type: <schema name>

Pre-write validation:
  1. <mechanical check>
  2. <...>

Failure mode: block and log.
  - <consequences>
```

Skills without Output Contracts are incomplete and will be blocked by the hook set.

## 4. Cold-start design sources

Cite the research inputs that shaped the skill. This keeps the engine honest and makes it possible to audit whether a skill was designed from principle or borrowed from one user's private setup.

```markdown
## Design sources (cold-start)

- 02-ARCHITECTURE-SPEC.md (section X)
- 04-DESIGN-DECISIONS.md (decision Y)
```

## Validation before shipping

Before marking a skill built:

1. Run `manifest/validate-manifest.sh` against every example manifest the skill will consume.
2. Dry-run the skill against at least the three archetypes (consultant, developer, greenfield).
3. Verify the hook set still exits 0 on a missing manifest after your skill is installed.
4. `grep` the skill for hardcoded absolute paths — there should be none.
