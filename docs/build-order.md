# Build Order

The MVP shipped in this order:

1. **Plan 01 — Manifest Schema & Validator.** `manifest/schema.json`, `manifest/validate-manifest.sh`, three archetype examples (`consultant.json`, `developer.json`, `greenfield.json`). Everything downstream depends on this contract.
2. **Plan 02 — `/onboard-foundation`.** Conversational Phase 1 onboarder plus a read-only discovery engine. Validated against all three archetypes via self-dry-runs in `onboarder/foundation/dry-run.md`.
3. **Plan 05 — Generic hook set.** `pre-tool-use`, `post-tool-use`, `session-start`, `user-prompt-submit`, `pre-compact`, `stop`. All hooks source `hooks/lib/manifest.sh`, exit 0 gracefully when the manifest is missing, and read configuration from `$CLAUDE_MANIFEST`.
4. **Plan 06 — `/librarian`.** Generic Librarian skill, manifest handoff protocol, Output Contract documentation. Takes ownership of the manifest from the Onboarder and enforces contracts on every vault write.
5. **Plan 10 (minimal) — Installer & docs.** `install.sh` copies skills/hooks into `$CLAUDE_HOME` and merges the hook set into `settings.json`. `README.md`, `LICENSE`, `docs/philosophy.md`, `docs/build-order.md`.

Plans 03, 04, 07, 08, and 09 are deferred post-MVP. See the master spec in the authoring repo for their scope.
