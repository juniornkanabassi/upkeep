#!/bin/zsh
# Installs the built Upkeep.app (formerly Updater) into the central JuniorOS Apps folder, keeping the
# previous copy until the new one verifies. Usage: zsh install.sh [path/to/Upkeep.app]
# The bundle id and defaults suite stay com.juniornkanabassi.Updater, so settings and permissions
# carry over; a verified install then deletes the old Updater.app by its exact path.
# UPDATER_INSTALL_ROOT overrides the destination (use it for disposable test installs only).
# UPDATER_BIN_DIR is where the `upkeep` command (and its `updater` alias) is linked (default ~/.local/bin; a test install
# with UPDATER_INSTALL_ROOT and no UPDATER_BIN_DIR links nothing).
set -euo pipefail
INSTALL_ROOT="${UPDATER_INSTALL_ROOT:-/Applications/JuniorOS Apps}"
SOURCE_APP="${1:-${UPDATER_BUILD_DIR:-/private/tmp/updater-build}/Build/Products/Release/Upkeep.app}"
APP_ID="com.juniornkanabassi.Updater"
DEST="$INSTALL_ROOT/Upkeep.app"
OLD="$INSTALL_ROOT/Updater.app"  # the same app before the rename (0.10.x and earlier)
(( $# <= 1 )) || { print -u2 "Usage: zsh install.sh [path/to/Upkeep.app]"; exit 2; }
[[ -d "$SOURCE_APP" ]] || { print -u2 "No built app at $SOURCE_APP. Run build.sh first."; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")" == "$APP_ID" ]] || { print -u2 "Not an Upkeep build."; exit 1; }
TEAM="M6L2VW4W5Z"
# Junior's Apple-anchored signature on app and helper; an ad-hoc build would break the install helper.
verify_signed() {
  /usr/bin/codesign --verify --deep --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\" and identifier \"$APP_ID\"" "$1" &&
  /usr/bin/codesign --verify --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\" and identifier \"$APP_ID.helper\"" "$1/Contents/Resources/UpdaterInstaller"
}
verify_signed "$SOURCE_APP" || { print -u2 "Source is not signed by team $TEAM. Run build.sh."; exit 1; }
mkdir -p "$INSTALL_ROOT"
[[ ! -L "$DEST" ]] || { print -u2 "Refusing to replace symlink $DEST."; exit 1; }
if [[ -e "$DEST" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null)" == "$APP_ID" ]] || { print -u2 "$DEST is not Upkeep; refusing to replace it."; exit 1; }
fi


# One install at a time for this destination. shlock writes our pid atomically and
# only replaces a lock whose recorded owner is no longer running.
LOCK="$INSTALL_ROOT/.updater-install.lock"
# A lock folder comes from install.sh before 0.8.2 and has no owner to check: never remove it automatically.
[[ -d "$LOCK" ]] && { print -u2 "Found an old-style install lock folder at $LOCK. If no Upkeep install is running, remove it (rmdir) and run again."; exit 1; }
if ! /usr/bin/shlock -f "$LOCK" -p $$; then
  OWNER=$(<"$LOCK" 2>/dev/null)
  # shortcut: macOS shlock detects a dead owner but still refuses to take over; a human clears it (only a hard crash leaves one).
  if [[ -n "$OWNER" ]] && ! kill -0 "$OWNER" 2>/dev/null; then
    print -u2 "An interrupted install left a lock (pid $OWNER is not running). If no Upkeep install is running, run: rm \"$LOCK\" and try again."
  else
    print -u2 "Another Upkeep install is running (pid $OWNER)."
  fi
  exit 1
fi
for old in "$INSTALL_ROOT"/.updater-install.*(N/); do print -u2 "Left from an earlier run (not removed): $old"; done
WORK=$(mktemp -d "$INSTALL_ROOT/.updater-install.XXXXXX")
STAGE="$WORK/Upkeep.app"; BACKUP="$WORK/previous/Upkeep.app"; mkdir "$WORK/previous"
VERIFIED=0
cleanup() {
  # The original lives in BACKUP from the move until the new copy verifies: never delete it before then.
  if [[ -e "$BACKUP" ]] && (( ! VERIFIED )); then
    if [[ ! -e "$DEST" ]] && /bin/mv "$BACKUP" "$DEST"; then
      print -u2 "Interrupted: the previous Upkeep was put back."
    else
      print -u2 "Interrupted: the previous Upkeep is kept at $BACKUP."
      [[ "$(<"$LOCK" 2>/dev/null)" == "$$" ]] && /bin/rm -f "$LOCK"
      return
    fi
  fi
  /bin/rm -rf "$WORK"
  [[ "$(<"$LOCK" 2>/dev/null)" == "$$" ]] && /bin/rm -f "$LOCK"  # release only our own lock
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP PIPE  # signals still run the EXIT cleanup

# Quit a running copy cleanly, new name or old (its own save prompts stay in charge); never kill it.
running() { /usr/bin/pgrep -f "$DEST/Contents/MacOS/Upkeep" > /dev/null || /usr/bin/pgrep -f "$OLD/Contents/MacOS/Updater" > /dev/null; }
if running; then
  /usr/bin/osascript -e "tell application id \"$APP_ID\" to quit" > /dev/null 2>&1 || true
  for _ in {1..30}; do running || break; sleep 0.5; done
  ! running || { print -u2 "Upkeep did not quit. Nothing was changed."; exit 1; }
fi

/usr/bin/ditto "$SOURCE_APP" "$STAGE"
verify_signed "$STAGE"
if [[ -e "$DEST" ]]; then /bin/mv "$DEST" "$BACKUP"; fi
[[ -n "${UPDATER_INSTALL_ROOT:-}" && -n "${UPDATER_INSTALL_TEST_PAUSE:-}" ]] && sleep "$UPDATER_INSTALL_TEST_PAUSE"  # test installs only: window to interrupt mid-replace
if ! /bin/mv "$STAGE" "$DEST"; then print -u2 "Could not install $DEST."; exit 1; fi
if ! verify_signed "$DEST"; then /bin/rm -rf "$DEST"; print -u2 "Installed signature failed to verify."; exit 1; fi
# Delete the verified superseded bundle outright; the Bin would trigger AppCleaner.
VERIFIED=1
[[ ! -e "$BACKUP" ]] || /bin/rm -rf "$BACKUP"
print "Installed Upkeep $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DEST/Contents/Info.plist") at $DEST"

# The renamed app replaces the old Updater.app: once the new copy has verified, delete the old one
# by its exact path (not the Bin, which would set off AppCleaner), and only if it really is this app.
if [[ -e "$OLD" && ! -L "$OLD" ]]; then
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$OLD/Contents/Info.plist" 2>/dev/null)" == "$APP_ID" ]]; then
    /bin/rm -rf "$OLD" && print "Removed the old $OLD."
  else
    print -u2 "$OLD is not this app; leaving it alone."
  fi
fi

# The CLI lives in the app; link it onto PATH as Talk & Read does. `updater` stays as an alias.
if [[ -n "${UPDATER_BIN_DIR:-}" || -z "${UPDATER_INSTALL_ROOT:-}" ]]; then
  BIN_DIR="${UPDATER_BIN_DIR:-$HOME/.local/bin}"
  mkdir -p "$BIN_DIR"
  for name in upkeep updater; do
    LINK="$BIN_DIR/$name"
    if [[ -e "$LINK" && ! -L "$LINK" ]]; then
      print -u2 "$LINK exists and is not a link; leaving it alone."
    else
      ln -sfn "$DEST/Contents/Helpers/upkeep" "$LINK"
      print "Linked $LINK."
    fi
  done
  print "If \`upkeep\` is not found, add $BIN_DIR to PATH."
else
  print "Test install: no CLI link."
fi
print "MCP for Claude Code: claude mcp add -s user upkeep -- \"$DEST/Contents/Helpers/upkeep\" mcp"
print "(If an older 'updater' MCP server is configured, remove it: claude mcp remove -s user updater)"
print 'MCP for Codex (~/.codex/config.toml):'
print '[mcp_servers.upkeep]'
print "command = \"$DEST/Contents/Helpers/upkeep\""
print 'args = ["mcp"]'
print 'tool_timeout_sec = 180'
