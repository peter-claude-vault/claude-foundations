# Synthetic Vault Root (T-12 fixture)

This is a known-zero-drift baseline vault for the Plan 71 SP04 T-12 hermetic
test harness at `tests/foundation/librarian-full/`.

Structure intentionally minimal: vault-root markers only, no Engagements/, no
Meetings/, empty Logs/. The driver materializes a fresh copy under
`$DOGFOOD_ROOT/vault/` per invocation.

This file has no frontmatter. The `frontmatter-enforce` capability's
`detect_type()` returns `None` for vault-root non-allowlisted paths, and a
file with no `type:` frontmatter and no inferable type is silently skipped
(see `frontmatter-enforce.sh` L388: "No type inference available, no
frontmatter -> skip silently").

`placement-validate` accepts `CLAUDE.md` at the vault root via
`VAULT_ROOT_ALLOWLIST` (placement-validate.sh L76).
