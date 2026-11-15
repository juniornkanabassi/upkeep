# Upkeep 0.12.0 identity migration

The app, CLI, helper, project, schemes, module, test plans, data paths and environment
variables now use Upkeep. Version 0.12.0 is build 23. The old CLI alias is no longer installed.
Upstream credits, copyright headers, historical release notes and vendor API names stay intact.

## Data and settings

Before constructing production services, launch moves `~/Library/Application Support/Updater`
to `~/Library/Application Support/Upkeep` if only the old directory exists. It copies the old
preferences into the new bundle domain, preserving existing new keys, excluding window/frame
and test keys, then removes the old preferences. The migration is recorded in history.

If journals remain, it keeps using the old data directory and lets normal recovery honour the
original paths and writer locks. Relaunch after recovery settles to finish migration. If both
data directories exist, startup stops and keeps both rather than merging or overwriting them.
`UPKEEP_HOME` bypasses live migration for isolated test runs.

## Helper registration

The helper is an SMAppService daemon inside the app bundle, not an SMJobBless installation.
Old daemon plists remain packaged solely so the service can be unregistered. Both sides of
new helper communication require the new identity and the existing Apple signing team.

The old helper authenticates the old app identity. A new app cannot normally obtain its idle
reply. Migration therefore fails closed if an old registered helper cannot prove it is idle;
it does not terminate an unknown installation. The installer has a fallback: with no pending
old journals and no package installer running, one system administrator prompt boots out the
two exact old launchd labels and removes the two exact legacy helper files, only if present.
It verifies the labels are gone before replacing the app. This needs a signed live migration
check by the lead before rollout. Apple documents that unregister terminates a running daemon:
https://developer.apple.com/documentation/servicemanagement/smappservice/unregister()

## Lead's live steps (not performed in this worktree)

1. Wait for every old-app update and recovery job to settle. Save a backup of the old settings
   domain and application-support folder. Do not remove pending journals.
2. Keep the old signed app available until replacement. The installer retires the two old
   helper labels only with no pending journals or active package installer; approve the
   system administrator prompt if legacy registration/files exist. If it refuses, finish
   recovery using the old app. Do not delete journals or kill an unknown installation.
3. Build with `UPKEEP_BUILD_DIR` inside the reviewed checkout and run `install.sh` only under
   the separate replacement authorisation. The script accepts the previous app identity at
   the destination, verifies the new signed copy, then removes a verified old Updater.app.
4. Launch Upkeep, confirm migration history, ignored apps, automatic-update policy, locations
   and appearance. If recovery was pending, wait for settlement and relaunch.
5. Grant App Management, notifications and the new helper approval again. Verify a harmless
   authenticated helper health round trip before any real app update.
6. Update any `UPDATER_*` automation to `UPKEEP_*` and replace the old MCP configuration with
   `upkeep mcp`. Confirm the installed version is 0.12.0 (23) and its running bundle path.

No live apps, settings, helper registrations or /Applications files were changed during development.
