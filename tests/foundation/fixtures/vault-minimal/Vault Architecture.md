# Vault Architecture (T-12 fixture)

Synthetic architecture-of-record document for the hermetic test fixture.
Plain markdown, no frontmatter — `detect_type()` returns `None` and
`frontmatter-enforce` silently skips.

Real vaults populate this document with the canonical placement rules,
file-type taxonomy, and tag prefix allowlist; the synthetic fixture only
needs the file to exist at the vault root so that capability assertions
treating it as the architecture pointer (per `manifest.vault.architecture_doc`
convention) resolve cleanly.
