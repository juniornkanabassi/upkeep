// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

/// The window's sidebar destinations.
enum LibraryPage: String, CaseIterable, Identifiable, Sendable {
  case updates, needsYou, allApps, drivers, history

  var id: String { rawValue }

  var title: String {
    switch self {
    case .updates: "Updates"
    case .needsYou: "Needs You"
    case .allApps: "All Apps"
    case .drivers: "Drivers & Extensions"
    case .history: "History"
    }
  }

  var searchPrompt: String {
    switch self {
    case .updates: "Search Updates"
    case .needsYou: "Search Needs You"
    case .allApps: "Search All Apps"
    case .drivers: "Search Drivers"
    case .history: "Search History"
    }
  }

  var symbol: String {
    switch self {
    case .updates: "arrow.down.circle"
    case .needsYou: "exclamationmark.circle"
    case .allApps: "square.grid.2x2"
    case .drivers: "cpu"
    case .history: "clock"
    }
  }
}

/// What each page lists, decided once from the full app list. Updates holds only what Upkeep
/// installs itself; anything needing a step from the person goes to Needs You.
@MainActor
struct LibraryContent {
  let apps: [App]
  let query: String?
  var isUpdating: (App) -> Bool = { _ in false }

  private var visible: [App] {
    let sorted = apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    guard let query, !query.isEmpty else { return sorted }
    return sorted.filter { $0.name.localizedCaseInsensitiveContains(query) }
  }

  private static func isTopLevelApp(_ app: App) -> Bool {
    app.bundle.kind == .app && app.bundle.parent == nil && !app.isUpdaterItself
  }

  // MARK: Updates

  /// Updates Upkeep can install itself (install or vendorTool capability), not ignored.
  var updates: [App] { visible.filter { !$0.isIgnored && $0.updateStatus == .ready } }

  var updateSections: [AppListSnapshot.SectionContent] {
    let running = updates.filter(isUpdating)
    let waiting = updates.filter { !isUpdating($0) }
    return [
      section("Updating now", running),
      section("Upkeep installs these for you", waiting),
    ].compactMap { $0 }
  }

  // MARK: Needs You

  /// An update another app or page finishes (including drivers with a download page).
  var finishYourself: [App] {
    visible.filter { !$0.isIgnored && $0.bundle.parent == nil && $0.updateStatus == .elsewhere }
  }

  /// Only the vendor's app knows whether an update waits, but it has a next step.
  var couldNotCheckButYouCan: [App] {
    visible.filter { !$0.isIgnored && $0.bundle.parent == nil && $0.updateStatus == .checkInVendor }
  }

  var needsYouSections: [AppListSnapshot.SectionContent] {
    [
      section("Update ready, finish it yourself", finishYourself),
      section("Could not check, but you can", couldNotCheckButYouCan),
    ].compactMap { $0 }
  }

  var needsYouCount: Int { finishYourself.count + couldNotCheckButYouCan.count }

  /// Top-level apps with no next step at all: no source, a failed check, versions that
  /// can't be compared. They stay in All Apps; Needs You links there.
  var uncheckable: [App] {
    apps.filter { Self.isTopLevelApp($0) && !$0.isIgnored && $0.updateStatus == .unknown }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  // MARK: All Apps

  struct Row: Identifiable {
    let id: URL
    let name: String
    let app: App?
    /// "4 apps", "1 extension", "4 helpers".
    let detail: String?
    var children: [Row]?
  }

  static func folderID(_ name: String) -> URL {
    URL(string: "upkeep-folder:" + (name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "folder"))!
  }

  /// Top-level apps, with helpers and extensions grouped under the app or folder they came with.
  var allAppRows: [Row] {
    let all = visible
    let topLevel = all.filter(Self.isTopLevelApp)
    var children = [String: [App]]()
    for app in all where app.bundle.parent != nil && app.bundle.kind == .app {
      children[app.bundle.parent!, default: []].append(app)
    }
    let extensions = Dictionary(grouping: all.filter { $0.bundle.kind == .driver && $0.bundle.hostURL != nil }) {
      $0.bundle.hostURL!.standardizedFileURL.path
    }
    var rows = topLevel.map { app -> Row in
      let helpers = children.removeValue(forKey: app.name) ?? []
      let hosted = extensions[app.fileURL.standardizedFileURL.path] ?? []
      let nested = (helpers + hosted).map { Row(id: $0.identifier, name: $0.name, app: $0, detail: nil) }
      let detail: String? =
        hosted.isEmpty
        ? (helpers.isEmpty ? nil : Self.count(helpers.count, "helper"))
        : Self.count(nested.count, helpers.isEmpty ? "extension" : "item")
      return Row(id: app.identifier, name: app.name, app: app, detail: detail, children: nested.isEmpty ? nil : nested)
    }
    // Helpers whose parent is a folder rather than an app.
    for (folder, apps) in children {
      rows.append(
        Row(
          id: Self.folderID(folder), name: folder, app: nil, detail: Self.count(apps.count, "app"),
          children: apps.map { Row(id: $0.identifier, name: $0.name, app: $0, detail: nil) }))
    }
    return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  var allAppsCount: Int { apps.filter(Self.isTopLevelApp).count }
  var helperCount: Int { apps.filter { $0.bundle.kind == .app && $0.bundle.parent != nil }.count }

  // MARK: Drivers & Extensions

  /// Drivers macOS updates itself are hidden and counted.
  var drivers: [App] { visible.filter { $0.bundle.kind == .driver && !Self.isApple($0) } }
  var hiddenAppleDrivers: Int { apps.filter { $0.bundle.kind == .driver && Self.isApple($0) }.count }
  var driverCount: Int { apps.filter { $0.bundle.kind == .driver && !Self.isApple($0) }.count }

  var driverSections: [AppListSnapshot.SectionContent] {
    let drivers = drivers
    func group(_ title: String, _ test: (App) -> Bool) -> AppListSnapshot.SectionContent? {
      section(title, drivers.filter(test))
    }
    return [
      group("Audio drivers") { $0.fileURL.path.contains("/Audio/Plug-Ins/HAL/") },
      group("Device drivers") {
        !$0.fileURL.path.contains("/Audio/Plug-Ins/HAL/") && $0.bundle.hostURL == nil
          && $0.bundle.parent == nil
      },
      group("System extensions, updated with their app") {
        !$0.fileURL.path.contains("/Audio/Plug-Ins/HAL/") && ($0.bundle.hostURL != nil || $0.bundle.parent != nil)
      },
    ].compactMap { $0 }
  }

  private static func isApple(_ app: App) -> Bool { app.bundleIdentifier.hasPrefix("com.apple.") }

  // MARK: Helpers

  private func section(_ title: String, _ apps: [App]) -> AppListSnapshot.SectionContent? {
    apps.isEmpty
      ? nil : AppListSnapshot.SectionContent(
        section: AppListSnapshot.Section(title: title, numberOfApps: apps.count), apps: apps)
  }

  static func count(_ value: Int, _ noun: String) -> String {
    "\(value) \(noun)\(value == 1 ? "" : "s")"
  }

  /// Items that belong to this app: its helpers and the extensions it hosts.
  func companions(of app: App) -> [App] {
    apps.filter {
      ($0.bundle.parent == app.name && $0.bundle.kind == .app)
        || $0.bundle.hostURL?.standardizedFileURL == app.fileURL.standardizedFileURL
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}

/// The All Apps Status column and the detail's sentence share these words.
@MainActor
enum LibraryStatus {
  enum Tone { case positive, accent, secondary }

  static func text(for app: App) -> (String, Tone) {
    if app.bundle.parent != nil { return ("Updates with its app", .secondary) }
    switch app.updateStatus {
    case .checking: return ("Checking…", .secondary)
    case .ready:
      return ("\(app.remoteVersion?.versionNumber ?? "Update") ready", .accent)
    case .elsewhere:
      if app.relaunchesToUpdate { return ("Relaunch to update", .accent) }
      return ("\(app.remoteVersion?.versionNumber ?? "Update") available", .accent)
    case .checkInVendor: return ("Check in \(app.externalUpdaterName ?? "its app")", .accent)
    case .current: return app.isUpdaterItself ? ("This app", .secondary) : ("Up to date", .positive)
    case .needsNewerMacOS(let macOS): return ("Needs macOS \(macOS)", .secondary)
    case .unknown: return ("Update status unavailable", .secondary)
    }
  }
}
