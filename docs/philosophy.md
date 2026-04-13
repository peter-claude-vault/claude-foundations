# Design Philosophy

Three commitments shape every piece of this repo.

## 1. The manifest is the source of truth

`user-manifest.json` is the single document that defines who the user is, what tools they use, where their vault lives, and how autonomous the system should be. Every skill and hook resolves its configuration from the manifest at runtime. There are no hardcoded paths, no per-user forks, no "copy this file and edit line 42."

This is the difference between a templating engine and a personalization engine. Templates produce identical outputs for everyone who runs them. A personalization engine asks questions, observes the environment, and produces a document that downstream skills read to adapt their behavior.

## 2. Cold-start design

Every skill and hook in this repo was designed from research and first principles — not from a snapshot of any one user's working directory. The research inputs are cited in each SKILL.md's "Design sources" section:

- `02-ARCHITECTURE-SPEC.md` — Onboarder / Advisor / Builder / Librarian layering
- `04-DESIGN-DECISIONS.md` — phased onboarding, manifest ownership, Output Contracts
- `03-EXTERNAL-RESEARCH.md` — competitive landscape, Motivational Interviewing framing, greenfield vs. adoption paths

No personal data, session logs, or pre-existing manifests were used as inputs. The skill must work for a stranger.

## 3. Output Contracts on every vault write

Any skill that writes to the managed vault declares an Output Contract: the files it will write, the schema those files must validate against, the pre-write validation steps, and a failure mode of `block and log`. Skills without Output Contracts are treated as incomplete and will not pass the hook set.

This is not opt-in. The `post-tool-use.sh` hook enforces it on every write, and the Librarian retroactively audits vault content against the contracts declared by the skills that produced it. "Write and hope" is never a valid failure mode.

## Why this shape

Hardcoded systems are fast to write and impossible to share. Manifest-driven systems take more thought up front but let a single skill set work for a consultant, a developer, or a greenfield user with zero forking. The Output Contract system exists because the alternative — skills that silently corrupt the vault when their assumptions drift — is the failure mode that kills long-lived knowledge bases.

The engine is built to be boring in the good way: predictable, auditable, and safe to extend.
