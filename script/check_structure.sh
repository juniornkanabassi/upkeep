#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Fail before checks: commands in conditionals/process substitutions can fail
# without triggering set -e, otherwise a missing rg silently bypasses the gate.
for tool in rg xcrun plutil; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

# Old identity is permitted only where migration needs to recognise it.
if rg -n 'com\.juniornkanabassi\.Updater|UPDATER_' Upkeep UpkeepCLI Tests script .github docs README.md AGENTS.md REVIEW.md build.sh Upkeep.xcodeproj UpdateInstaller \
  -g '!Identity-migration.md' -g '!UpkeepReleaseNotes.json' \
  -g '!UpkeepIdentityMigration.swift' -g '!InstallHelperTest.swift' -g '!test_install.py' -g '!UpdateInstallHelper.swift' -g '!project.pbxproj' \
  -g '!com.juniornkanabassi.Updater.helper*.plist' -g '!install.sh' -g '!check_structure.sh'; then
  echo "Old Updater identity reintroduced outside migration code/history" >&2
  exit 1
fi

if rg -n 'UPDATER_' install.sh Upkeep/Support/UpkeepIdentityMigration.swift Upkeep/Platform/InstallHelper/UpdateInstallHelper.swift Upkeep.xcodeproj/project.pbxproj Tests/Updating/InstallHelperTest.swift script/tests/test_install.py; then
  echo "Old environment prefix reintroduced in installer" >&2
  exit 1
fi

required_roots=(
  Upkeep/App
  Upkeep/Features
  Upkeep/Domain
  Upkeep/Services
  Upkeep/Platform
  Upkeep/Support
)

for root in "${required_roots[@]}"; do
  if [[ ! -d "$root" ]]; then
    echo "Missing architecture root: $root" >&2
    exit 1
  fi
done

legacy_roots=(
  Upkeep/Model
  Upkeep/SwiftUI
  "Upkeep/View Model"
  Upkeep/Interface
  Upkeep/Utilities
)

for root in "${legacy_roots[@]}"; do
  if [[ -d "$root" ]] && [[ -n "$(find "$root" -type f -name '*.swift' -print -quit)" ]]; then
    echo "Swift source reintroduced under legacy root: $root" >&2
    exit 1
  fi
done

while IFS= read -r -d '' file; do
  if [[ -f "$file" ]] && [[ ! -s "$file" ]]; then
    echo "Tracked file is empty: $file" >&2
    exit 1
  fi
done < <(git ls-files -z)

while IFS= read -r source; do
  line_count="$(wc -l < "$source" | tr -d ' ')"
  if (( line_count > 1500 )); then
    echo "Swift file exceeds the 1,500-line architecture ceiling: $source ($line_count lines)" >&2
    exit 1
  fi
done < <(rg --files Upkeep Tests -g '*.swift')

if rg -n 'NSWorkspace\.shared\.(open|activateFileViewer)|NSApplication\.shared' Upkeep/Domain; then
  echo "Domain source contains a direct macOS side effect" >&2
  exit 1
fi

if rg -n '^import (AppKit|Cocoa|SwiftUI)$' Upkeep/Domain; then
  echo "Domain source imports a presentation framework" >&2
  exit 1
fi

if rg -n 'LOCAL_.*FIXTURE|localUATFixture' Upkeep/App/UpkeepApplication.swift; then
  echo "The runnable app must not replace live discovery with a local fixture" >&2
  exit 1
fi

# Compile Domain by itself. This catches any service or feature dependency,
# including extension-mediated dependencies that an import regex cannot detect.
domain_sources=()
while IFS= read -r source; do domain_sources+=("$source"); done < <(rg --files Upkeep/Domain -g '*.swift')
mkdir -p build/DomainModuleCache
xcrun swiftc -typecheck -parse-as-library -module-name UpkeepDomain \
  -swift-version 6 -strict-concurrency=complete -target "$(uname -m)-apple-macos26.0" \
  -module-cache-path "$ROOT_DIR/build/DomainModuleCache" "${domain_sources[@]}"

if rg -n '\b(UpdateQueue|UpdateOperation)\b' Upkeep/Features Upkeep/App; then
  echo "Features must use the injected AppUpdating boundary" >&2
  exit 1
fi

resolved="Upkeep.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
[[ -f "$resolved" ]] || { echo "Missing pinned Swift package resolution: $resolved" >&2; exit 1; }
if git check-ignore -q "$resolved"; then
  echo "Package.resolved must be available to fresh checkouts, not ignored" >&2
  exit 1
fi
plutil -lint Upkeep.xcodeproj/project.pbxproj >/dev/null
git diff --check

echo "Architecture and repository structure checks passed."
