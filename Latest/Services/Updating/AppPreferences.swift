// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import Combine
import Foundation
import Synchronization

/// Per-app switches shared by the window, the CLI and MCP: Update automatically (per copy, by
/// path, off by default) and Ignore updates (the existing per-bundle-id preference). Each
/// change names its caller, so the detail pane can say "Turned on by Claude at 11:05. Undo".
@MainActor
final class AppPreferences: ObservableObject {
  enum Setting: String, Sendable { case autoUpdate, ignore }

  struct Change: Equatable {
    let caller: String
    let date: Date
    let on: Bool
    let previous: Bool
  }

  struct Refusal: Error, Equatable {
    let message: String
  }

  static let autoUpdateKey = "AutoUpdateAppPaths"

  @Published private(set) var autoUpdatePaths: Set<String>
  // shortcut: the "Turned on by" notes live for this launch only; History keeps the record.
  @Published private(set) var changes = [String: Change]()

  /// A copy of the switched-on paths that queued jobs can read from any thread.
  private let mirror = PathMirror()
  /// Cancels a queued automatic job for the app (the scheduler leaves other jobs alone).
  var withdrawAutomatic: (App) -> Void = { _ in }
  private let defaults: UserDefaults
  private let setIgnoredState: (Bool, App) -> Void
  private let history: UpdateHistoryStore?
  var now: () -> Date = Date.init

  init(
    defaults: UserDefaults, setIgnoredState: @escaping (Bool, App) -> Void,
    history: UpdateHistoryStore?
  ) {
    self.defaults = defaults
    self.setIgnoredState = setIgnoredState
    self.history = history
    autoUpdatePaths = Set(defaults.stringArray(forKey: Self.autoUpdateKey) ?? [])
    mirror.paths.withLock { [autoUpdatePaths] in $0 = autoUpdatePaths }
  }

  /// Only apps Upkeep installs itself can update automatically.
  static func canAutoUpdate(_ app: App) -> Bool { app.capability.isAutomatic }

  func autoUpdates(_ app: App) -> Bool {
    Self.canAutoUpdate(app) && !app.isIgnored && autoUpdatePaths.contains(app.fileURL.path)
  }

  func value(_ setting: Setting, for app: App) -> Bool {
    setting == .ignore ? app.isIgnored : autoUpdates(app)
  }

  func change(_ setting: Setting, for app: App) -> Change? {
    changes[Self.key(setting, app)]
  }

  /// `caller` is the raw control caller, or "gui" for the window.
  func set(_ setting: Setting, _ on: Bool, for app: App, caller: String) throws(Refusal) {
    let previous = value(setting, for: app)
    switch setting {
    case .autoUpdate:
      if on, !Self.canAutoUpdate(app) {
        throw Refusal(
          message:
            "\(app.name) can't update automatically: Upkeep doesn't install its updates itself.")
      }
      if on, app.isIgnored {
        throw Refusal(
          message: "\(app.name) is ignored. Stop ignoring it before turning on automatic updates.")
      }
      store(on, path: app.fileURL.path)
    case .ignore:
      setIgnoredState(on, app)
      // Ignoring an app turns its automatic updates off.
      if on, autoUpdatePaths.contains(app.fileURL.path) {
        store(false, path: app.fileURL.path)
        changes[Self.key(.autoUpdate, app)] = nil
      }
    }
    // Switching either off withdraws an automatic job that has not reached its install step.
    if (setting == .ignore && on) || (setting == .autoUpdate && !on) { withdrawAutomatic(app) }
    guard previous != on else { return }
    changes[Self.key(setting, app)] = Change(
      caller: caller, date: now(), on: on, previous: previous)
    var entry = UpdateHistoryEntry(
      before: app.bundle, after: app.bundle,
      outcome: .settingChanged(setting: setting.rawValue, on: on))
    entry.caller = caller
    history?.record(entry)
  }

  /// Puts back the value an agent changed; the window is the caller of the undo.
  func undo(_ setting: Setting, for app: App) {
    guard let change = change(setting, for: app) else { return }
    try? set(setting, change.previous, for: app, caller: "gui")
    changes[Self.key(setting, app)] = nil
  }

  /// After a check: switched-on apps that Update All would also start, and that are not open.
  func autoUpdateCandidates(
    in apps: [App], eligible: ([App]) -> [App], isRunning: (URL) -> Bool
  ) -> [App] {
    eligible(apps.filter(autoUpdates)).filter { !isRunning($0.fileURL) }
  }

  /// What an automatic job re-checks before it starts and right before it installs.
  /// `isIgnored` and `isRunning` must be safe from any thread.
  func policy(
    for app: App, isIgnored: @escaping @Sendable () -> Bool,
    isRunning: @escaping @Sendable (URL) -> Bool = AppPreferences.isRunning
  ) -> AutomaticUpdatePolicy {
    let mirror = mirror, path = app.fileURL.path, url = app.fileURL
    return AutomaticUpdatePolicy {
      mirror.paths.withLock { $0.contains(path) } && !isIgnored() && !isRunning(url)
    }
  }

  nonisolated static func isRunning(_ url: URL) -> Bool {
    NSWorkspace.shared.runningApplications.contains {
      $0.bundleURL?.standardizedFileURL == url.standardizedFileURL
    }
  }

  private func store(_ on: Bool, path: String) {
    if on { autoUpdatePaths.insert(path) } else { autoUpdatePaths.remove(path) }
    mirror.paths.withLock { [autoUpdatePaths] in $0 = autoUpdatePaths }
    defaults.set(autoUpdatePaths.sorted(), forKey: Self.autoUpdateKey)
  }

  private static func key(_ setting: Setting, _ app: App) -> String {
    setting.rawValue + ":" + app.fileURL.path
  }
}

private final class PathMirror: Sendable {
  let paths = Mutex<Set<String>>([])
}
