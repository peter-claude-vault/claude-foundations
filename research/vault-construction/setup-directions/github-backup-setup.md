---
altitude: system
scope: Setup direction for the GitHub backup repo pre-req — recovery insurance for live-default writes. Soft-mandated; skip path coherent but materially riskier.
validity_window: 2026-05-10..2026-11-10
source_dependencies:
  - Plan 81 SP02 spec.md §Pre-reqs (L137-141)
  - Plan 80 SP02 packet T8 §6 (pre-req table)
  - Plan 79 (vault git-backup cron) — this pre-req is the destination Plan 79 pushes to
  - gh CLI documentation (cli.github.com)
  - GitHub SSH-key documentation (docs.github.com/en/authentication/connecting-to-github-with-ssh)
last_reviewed: 2026-05-10
canonical_url: https://stem.peter.dev/research/vault-construction/setup-directions/github-backup/
url_stability: locked-from-2026-05-10
---

# GitHub repo for backups — recovery insurance for live writes

## Rationale

The system writes live to your vault and `~/.claude/` in default mode. That is the design — the architecture trades dry-run safety for the ability to act on your behalf without ceremony. Automated backup hooks (existing for `~/.claude`; Plan 79 ships the equivalent for the user vault) push to a remote git repo so changes are recoverable.

Without a remote destination, every change is local-only. If the disk fails, if a backup runs while a process is in mid-write, if an automated process makes a destructive change before you notice — local git history is your only recovery and it is on the same disk as the data it would recover.

This is the soft-mandate with the highest skip cost. Obsidian and claude-mem affect features. GitHub backup affects what you can recover when something goes wrong.

## Setup prerequisites

- A GitHub account (free tier sufficient for private repos).
- Authentication on the local machine: either the `gh` CLI authenticated (`gh auth login`) or an SSH key registered with GitHub.
- At least one **private** GitHub repo for vault backup. (Use private — the vault contains your work and likely sensitive notes.)

## Install steps

1. **Create the GitHub account** if you do not have one: <https://github.com/signup>.
2. **Authenticate locally.** Choose one path:
   - **gh CLI:** install from <https://cli.github.com/>, then run `gh auth login` and follow prompts.
   - **SSH key:** generate with `ssh-keygen -t ed25519 -C "your_email@example.com"`, add to `ssh-agent`, then add the public key to GitHub at Settings → SSH and GPG keys → New SSH key. Full instructions: <https://docs.github.com/en/authentication/connecting-to-github-with-ssh>.
3. **Create a private repo for vault backup.** Via gh: `gh repo create <username>/vault-backup --private`. Or via web: <https://github.com/new>, choose **Private**.
4. **Note the repo URL.** Plan 79's vault git-backup cron will configure the push remote during its install; you supply the URL there. If Plan 79 has not landed when you are setting this up, the URL will be consumed when it does.
5. **Confirm `~/.claude/` backups are working** (separate, already-existing automation). Check that recent commits exist in whatever `~/.claude/` backup repo your install configured.

## If skipped

No automated remote backup. Recovery is limited to local git history — which is on the same disk as the data it would recover. Specifically:

- **Disk failure or corruption** wipes both the vault and the recovery history.
- **Bad automated write** (a hook or skill that did the wrong thing) is recoverable only via local git, only if you notice before the next automation runs.
- **Live-default writes carry significantly more risk.** The architecture assumes a recoverable substrate. Skipping the GitHub repo removes the recoverability assumption without removing the live-write behavior.

The skip path is coherent: the system still functions, every other pillar works. The cost is risk. If you skip, consider reducing the scope of automated work (`/onboard --retention-on`, manual confirmation on schedule changes) until you have remote backup configured.

## Source pointers

- Plan 81 SP02 spec.md §Pre-reqs table (L137-141)
- Plan 80 SP02 packet T8 §6 (GitHub backup row)
- Plan 79 (vault git-backup cron) — this pre-req's downstream consumer
- `gh` CLI: <https://cli.github.com/>
- GitHub SSH key setup: <https://docs.github.com/en/authentication/connecting-to-github-with-ssh>
