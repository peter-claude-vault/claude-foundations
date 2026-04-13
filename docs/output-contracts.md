# Output Contracts

An Output Contract is a frontmatter-level declaration in a skill's `SKILL.md` that tells the system exactly what the skill will write, what schema it will conform to, and what happens if validation fails. The Librarian and the `post-tool-use.sh` hook enforce contracts before any vault write is allowed to land.

## Why contracts exist

Skills that write to a managed vault without a contract are a failure mode waiting to happen — they can drop files in the wrong location, skip frontmatter, or corrupt the vault schema. Contracts make the skill's intent machine-checkable and force the author to think about failure up front.

## Contract shape

```markdown
## Output Contract

Files written:
  - <absolute path or glob>
  - <...>

Schema type: <name from vault-schema.json or `user-manifest`>

Pre-write validation:
  1. <step one>
  2. <step two>
  ...

Failure mode: block and log.
  - <what happens when a step fails>
  - <...>
```

## The four required sections

**Files written.** Every path the skill will touch. Globs allowed. Paths outside `$CLAUDE_DIR` or `$vault_root` are rejected by the pre-tool-use hook regardless of contract.

**Schema type.** Points to the JSON Schema that candidate content must validate against. `user-manifest` for manifest writes; vault document types for content writes.

**Pre-write validation.** A numbered list of checks the skill runs before it writes. The checks must be mechanical — something the hook can verify, not just a promise.

**Failure mode.** Must be the literal phrase `block and log`. "Write and hope" is not a valid failure mode.

## Enforcement

1. `pre-tool-use.sh` blocks writes to protected paths and the manifest itself.
2. `post-tool-use.sh` blocks vault markdown writes that lack YAML frontmatter.
3. `/librarian scan` retroactively audits vault content against the contracts declared by the skills that wrote it.
4. `/librarian intake` validates new content before it's allowed into the vault.

A skill without an Output Contract is treated as incomplete. It should not be marked "built" or shipped.

## Example: onboard-foundation

```
Files written:
  - $CLAUDE_HOME/.claude/user-manifest.json
  - (greenfield only) $vault_root/CLAUDE.md
  - (greenfield only) $vault_root/{Inbox,Projects,Reference,Archive}/_index.md

Schema type: user-manifest (manifest/schema.json)

Pre-write validation:
  1. Run manifest/validate-manifest.sh against the candidate manifest.
  2. Confirm system.phases_completed includes "foundation".
  3. Confirm identity.role is non-empty.
  4. Confirm no write target escapes $CLAUDE_HOME or $vault_root.

Failure mode: block and log.
  - If validation fails, print the specific error, return to the confirmation step, and do not write.
  - If a vault write target would escape $vault_root, abort the entire skill and log to stderr.
  - Never write a partial or invalid manifest.
```
