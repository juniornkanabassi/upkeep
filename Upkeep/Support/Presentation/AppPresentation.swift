//
//  AppPresentation.swift
//  Latest
//
//  Presentation adapters for domain values.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-09-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import AppKit

extension App {
  /// Localized version information suitable for display in the interface.
  struct DisplayableVersionInformation {
    private(set) var rawCurrent: String
    private(set) var rawNew: String?

    var current: String {
      String(
        format: NSLocalizedString(
          "LocalVersionFormat",
          comment:
            "The current version of a locally installed app. The placeholder %@ is the version number."
        ),
        rawCurrent
      )
    }

    var new: String? {
      rawNew.map { version in
        String(
          format: NSLocalizedString(
            "RemoteVersionFormat",
            comment:
              "The most recent version available for an app. The placeholder %@ is the version number."
          ),
          version
        )
      }
    }

    func combined(includeNew: Bool) -> String {
      if let rawNew, includeNew, rawCurrent != rawNew {
        return String(
          format: NSLocalizedString(
            "CombinedVersionFormat",
            comment:
              "The current and available version numbers. The first placeholder is current; the second is available."
          ),
          rawCurrent,
          rawNew
        )
      }

      return String(
        format: NSLocalizedString(
          "SingleCombinedVersionFormat",
          comment: "The current version number."
        ),
        rawCurrent
      )
    }
  }

  var localizedVersionInformation: DisplayableVersionInformation? {
    let currentVersion = version
    let newVersion = remoteVersion
    var information: DisplayableVersionInformation?

    if let current = currentVersion.versionNumber, let new = newVersion?.versionNumber {
      information = DisplayableVersionInformation(rawCurrent: current, rawNew: new)

      if updateAvailable,
        current == new,
        let currentBuild = currentVersion.buildNumber,
        let newBuild = newVersion?.buildNumber
      {
        information = DisplayableVersionInformation(
          rawCurrent: "\(current) (\(currentBuild))",
          rawNew: "\(new) (\(newBuild))"
        )
      }
    } else if let current = currentVersion.buildNumber, let new = newVersion?.buildNumber {
      information = DisplayableVersionInformation(rawCurrent: current, rawNew: new)
    } else if let current = currentVersion.versionNumber ?? currentVersion.buildNumber {
      information = DisplayableVersionInformation(rawCurrent: current, rawNew: nil)
    }

    return information
  }

}

/// Plain-language descriptions of what Update does for an app, shared by the list, the detail
/// pane and the menu bar. They read the capability; they never decide it.
@MainActor
extension App {
  /// The second line of a row and the menu bar: versions, or why there is none.
  var versionSummary: String {
    if let parent = bundle.parent { return "Updates with \(parent)" }
    if availabilityUnknown, let vendor = externalUpdaterName { return "Check in \(vendor)" }
    guard let versions = localizedVersionInformation else { return "" }
    if updateAvailable, let new = versions.rawNew { return "\(versions.rawCurrent) → \(new)" }
    return versions.rawCurrent
  }

  /// The row's third line when nothing is running: where the update happens, in a few words.
  var routeShortDescription: String {
    if let parent = bundle.parent { return "Updates with \(parent)" }
    if bundle.kind == .driver && capability == .unsupported {
      return bundle.note ?? "No supported update source"
    }
    if isUpkeepItself { return "This app" }
    if isIgnored { return "Ignored" }
    if isSourcePending { return "Checking…" }
    if isActionable {
      switch capability {
      case .install, .vendorTool: return sourceName
      case .handOff, .unsupported: break
      }
      if relaunchesToUpdate {
        return SidebarUpdateActionTitle.isRunning(self) ? "Relaunch to apply" : "Open to apply"
      }
      if availabilityUnknown { return "Opens \(externalUpdaterName ?? "its vendor's app")" }
      if externalUpdaterName == HomebrewCheckerOperation.handOffLabel {
        return "Opens Terminal with the brew command"
      }
      if externalUpdaterName == name { return "Updates from inside the app" }
      return "Opens \(externalUpdaterName ?? "another app")"
    }
    switch updateStatus {
    case .current: return "Up to date"
    case .needsNewerMacOS(let macOS): return "Newer version needs macOS \(macOS)"
    case .ready, .elsewhere, .checkInVendor, .checking, .unknown: break
    }
    if error != nil { return "Couldn't check" }
    if remoteVersion == nil { return "No update source found" }
    return "Versions can't be compared"
  }

  /// One sentence above the release notes saying exactly what clicking the button does.
  var updateExplanation: String {
    if let error, bundle.kind == .driver { return error.localizedDescription }
    if let parent = bundle.parent { return "Updates with \(parent)." }
    if bundle.kind == .driver, capability == .unsupported {
      return bundle.note ?? "No supported update source."
    }
    if bundle.kind == .driver, capability == .vendorTool {
      return
        "Update runs ARK's installer with one macOS administrator prompt, then checks the driver version on disk. Audio apps may briefly lose sound."
    }
    if isUpkeepItself { return "This is Upkeep. It can't update itself yet." }
    if isSourcePending { return "Checking for updates…" }
    if isActionable {
      let new = remoteVersion?.versionNumber.map { " \($0)" } ?? ""
      switch capability {
      case .install:
        return
          "Update downloads version\(new) and installs it here. Upkeep keeps the old copy until it has checked the new version on disk."
      case .vendorTool:
        return
          "Update runs the developer's own updater, then Upkeep checks the new version on disk."
      case .handOff, .unsupported: break
      }
      if relaunchesToUpdate {
        return SidebarUpdateActionTitle.isRunning(self)
          ? "Relaunching \(name) applies an update if \(name) has downloaded one."
          : "Opening \(name) applies an update if it has downloaded one."
      }
      if availabilityUnknown {
        return
          "\(externalUpdaterName ?? "The vendor") doesn't tell other apps whether an update is waiting. Open it to check and update there."
      }
      if externalUpdaterName == HomebrewCheckerOperation.handOffLabel {
        return
          "Upkeep can't run this one itself. It copies the brew upgrade command and opens Terminal: paste it and press Return."
      }
      if externalUpdaterName == name {
        return "\(name) updates itself. Open it and use its own update command."
      }
      return
        "Upkeep can't install this one itself. Open \(externalUpdaterName ?? "the updater") and finish the update there."
    }
    switch updateStatus {
    case .current: return "You have the latest version."
    case .needsNewerMacOS(let macOS):
      let new = remoteVersion?.versionNumber.map { "Version \($0)" } ?? "A newer version"
      return
        "\(new) is available but needs macOS \(macOS) or later, so Upkeep won't offer it on this Mac."
    case .ready, .elsewhere, .checkInVendor, .checking, .unknown: break
    }
    if let error { return "Upkeep couldn't check this app: \(error.localizedDescription)" }
    if remoteVersion == nil {
      return "Upkeep can't find an update source for this app. Check the app or its website."
    }
    return
      "Upkeep can't compare the installed version with the latest one, so it doesn't know whether this app is up to date."
  }

  /// Who provides the version information, for "Updates via".
  var sourceName: String {
    switch source {
    case .driver:
      bundle.bundleIdentifier == "com.rogueamoeba.ARK.driver" && capability == .vendorTool
        ? "ARK installer" : bundle.parent ?? "No independent update source"
    case .sparkle: "Own updater"
    case .appStore: "App Store"
    case .homebrew: "Homebrew"
    case .directDownload: "Maker's website"
    case .vendor:
      capability == .vendorTool ? "Developer's updater" : externalUpdaterName ?? "Developer"
    case .none: "Unknown"
    }
  }
}

/// What a finished check found when nothing is waiting to install, so "Everything is up to
/// date" is said only when every checked app was verified current (window and menu bar).
struct UpdateStatusSummary: Equatable {
  var current = 0
  /// Updates Upkeep installs itself (Ready to Update).
  var ready = 0
  /// No source, a failed check, or versions that can't be compared.
  var couldNotCheck = 0
  /// Newer versions that need a newer macOS than this Mac runs.
  var needsNewerMacOS = 0
  /// Updates Upkeep would open elsewhere (shown or hidden in the list).
  var elsewhere = 0
  /// Availability only the vendor's app knows (Adobe).
  var checkInVendor = 0
  var vendor: String?

  var isAllCurrent: Bool {
    ready == 0 && couldNotCheck == 0 && needsNewerMacOS == 0 && elsewhere == 0
      && checkInVendor == 0
  }

  /// "12 up to date · 2 couldn't be checked · 3 check in Creative Cloud".
  var text: String {
    [
      ready > 0 ? "\(ready) ready to update" : nil,
      "\(current) up to date",
      needsNewerMacOS > 0 ? "\(needsNewerMacOS) need a newer macOS" : nil,
      couldNotCheck > 0 ? "\(couldNotCheck) couldn't be checked" : nil,
      elsewhere > 0 ? "\(elsewhere) to update elsewhere" : nil,
      checkInVendor > 0 ? "\(checkInVendor) check in \(vendor ?? "the vendor's app")" : nil,
    ].compactMap { $0 }.joined(separator: " · ")
  }
}

extension UpdateStatusSummary {
  @MainActor
  init(apps: [App]) {
    for app in apps
    where !app.isIgnored && !app.isUpkeepItself && app.bundle.parent == nil
      && !(app.bundle.kind == .driver && app.capability == .unsupported)
    {
      switch app.updateStatus {
      case .checking: break
      case .ready: ready += 1
      case .elsewhere: elsewhere += 1
      case .checkInVendor:
        checkInVendor += 1
        vendor = vendor ?? app.externalUpdaterName
      case .needsNewerMacOS: needsNewerMacOS += 1
      case .current: current += 1
      case .unknown: couldNotCheck += 1
      }
    }
  }
}
