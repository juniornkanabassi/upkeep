# Upkeep rename validation

Revision d9a62c3, branch rename-upkeep, 15 November 2026.

## Changes

- Renamed the source tree, Xcode project, schemes, test plans, test targets, Swift module,
  CLI target, helper binary, signing identities, daemon labels, storage paths and environment
  variables to Upkeep. CLI module is explicitly UpkeepCLI to avoid a case-insensitive collision
  between the upkeep executable and Upkeep app module.
- Version 0.12.0, build 23, with version-matched release notes.
- Startup migration copies settings and moves the data folder. Existing new settings win;
  window/frame and recorded test-window keys are excluded. Pending JSON journals keep their
  original paths for recovery. A nonempty old folder beside a new folder pauses updates and
  reports the conflict in CLI status; an empty old folder permits the new folder.
- Installer accepts the previous bundle identity, preserves the old app until verification,
  stops on pending old journals, and conditionally retires exact old helper labels/files through
  one macOS administrator prompt. Disposable installs never invoke that cleanup.
- Removed the old updater CLI alias. Updated repository scripts, CI and documentation.
- Added identity recurrence checks and migration/legacy-helper tests.

## Final checks

| Check | Result |
| --- | --- |
| `UPKEEP_BUILD_DIR=$PWD/build/clean ./script/test.sh` | PASS, 53 tests, 0 failures |
| `UPKEEP_BUILD_DIR=$PWD/build/clean ./script/test.sh --integration` | PASS, 520 tests, 5 skipped, 0 failures |
| `UPKEEP_BUILD_DIR=$PWD/build/clean ./script/test.sh --ui` | PASS, 29 tests, 21 skipped, 0 failures |
| Script regressions run by each lane | PASS, 34 tests |
| Architecture, identity recurrence, grid checks | PASS |
| `zsh -n install.sh build.sh`, `git diff --check` | PASS |
| Signed live helper migration, real data migration, installed bundle verification | NOT RUN, deliberately outside this worktree's permission boundary |
| Release build, installation, publishing/push, benchmarks, independent review | NOT RUN |

Skipped UI tests report the existing inactive-window/transparent-window limitations. No visible
window or real app update was requested. Test evidence is under `build/evidence/` and the xcresult
bundles under `build/clean/`. Earlier failed runs found renamed vendor symbols, a stale module
collision, historical-note/JSON-key expectations and two fixture assertions; final runs pass.

## Retained names

Latest remains in upstream credit text, copyright/file headers and historical release notes.
Updater remains in migration recognition code, installer exact-label cleanup,
legacy-install fixtures, historical notes and generic/vendor APIs such as Sparkle's SPUUpdater.
The data schema key allowsLatestFallback and vendor release URLs retain their actual meaning.
These are not active fork identities. Only the current daemon plist is packaged.
The new helper never accepts the old app identity.

## Live migration handoff and limits

Follow `docs/Identity-migration.md` for the exact ordered procedure. The lead must verify the
signed migration before rollout, especially Background Task Management behaviour when retiring
an old SMAppService registration from the new identity. The installer checks exact launchd labels;
no global BTM reset is used. Runtime helper registration and health checks use only the new
identity. The verified staged installer owns retirement of the old labels.

Keep both old/new data folders if startup reports a collision and reconcile deliberately. Pending
journals must settle through the previous app before replacement; direct first-launch migration
also honours their paths and defers the move until a later launch. Permission grants are new for
App Management, notifications and the helper.

No real applications, user data, defaults domains or helper registrations were migrated, removed
or updated in this task. Nothing was installed or pushed. The worktree is ready for lead review,
not a claim of live migration approval.
