# Rename review fixes

All six findings in the 15 November 2026 rename review are addressed.

- ToolProcess and Homebrew logs use the migration-aware data root, including isolated test homes.
- Empty old folders allow the existing new root. Conflicting nonempty folders remain intact; startup logs the conflict and holds updates, and CLI status reports the hold.
- Only JSON journals defer migration or block replacement. Temporary files and .DS_Store do not.
- Only the current daemon plist is packaged. Removed old-identity probes, runtime retirement, single-label registration and its readiness flag. install.sh owns exact-label retirement.
- The installer stages and verifies the new copy before admin work and explains cancellation/failure.
- Settings filtering preserves real preference keys and latest, excluding window/frame and recorded test-window keys.

## Validation

| Check | Result |
| --- | --- |
| ./script/test.sh | PASS, 53 tests, zero failures |
| ./script/test.sh --integration | PASS, 522 tests reported, 5 skipped, zero failures |
| ./script/test.sh --ui | PASS, 29 tests reported, 21 skipped, zero failures |
| Python script regressions, each lane | PASS, 37 tests |
| Architecture, identity, grid checks, zsh syntax, git diff --check | PASS |

Evidence: build/review-unit.log, build/review-integration-clean.log, build/review-ui.log.
The integration/UI result bundles are under build/review-clean/.
The first integration attempt failed to resolve the Upkeep module in reused build products;
a fresh worktree-local derived-data directory passed. The initial unit attempt caught an
architecture-boundary violation, corrected before final validation.

The UI skips are the existing inactive/transparent-window and missing same-host visual-reference
limitations. Live signed helper migration, administrator prompts, real app updates, installation
and publishing were not performed. No open implementation questions remain.
