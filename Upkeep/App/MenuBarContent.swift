// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import Combine
import SwiftUI

/// The menu bar item's state: the waiting updates and what Update All would do.
@MainActor
final class MenuBarViewModel: ObservableObject {
  nonisolated static let showsItemKey = "ShowsMenuBarItem"

  /// Known available updates only: unknown Adobe versions never inflate the badge.
  @Published private(set) var updates = [App]()
  /// The sidebar's actionable sections, including apps that must be checked in their vendor.
  @Published private(set) var updateSections = [AppListSnapshot.SectionContent]()
  /// What the last check found, for the line shown when nothing is waiting.
  @Published private(set) var summary = UpdateStatusSummary()
  /// How many apps Update All would start now (the window's toolbar shows it too).
  @Published private(set) var updateAllCount = 0
  /// Apps with a job in the scheduler, whoever started it.
  @Published private(set) var running = [App]()
  /// Items in Needs You, for the menu's link to it.
  @Published private(set) var needsYouCount = 0
  var canUpdateAll: Bool { updateAllCount > 0 }

  private let appProvider: any AppProviding
  private let settings: any AppListSettingsProviding
  private let updateAllCandidates: () -> [App]
  private let isUpdating: (App) -> Bool
  private var apps = [App]()
  private var observations = [Task<Void, Never>]()
  private var observers = [NSObjectProtocol]()
  private var manualPreference: ManualAppStorePreferenceObserver?

  init(
    appProvider: any AppProviding,
    settings: any AppListSettingsProviding,
    updateAllCandidates: @escaping () -> [App],
    isUpdating: @escaping (App) -> Bool = { _ in false }
  ) {
    self.isUpdating = isUpdating
    self.appProvider = appProvider
    self.settings = settings
    self.updateAllCandidates = updateAllCandidates
  }

  nonisolated static var showsItem: Bool {
    UserDefaults.standard.object(forKey: showsItemKey) as? Bool ?? true
  }

  /// Recomputes on new app lists, on preference changes and whenever a job starts or ends
  /// (cancelled and declined ones too), so the menu never needs a manual refresh.
  func startObserving() {
    guard observations.isEmpty else { return }
    observations = [
      Task { [weak self, appProvider] in
        for await update in appProvider.updates() {
          guard !Task.isCancelled, let self else { break }
          self.refresh(with: update.apps)
        }
      },
      Task { [weak self, settings] in
        for await _ in settings.updates() {
          guard !Task.isCancelled, let self else { break }
          self.refresh()
        }
      },
    ]
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: .upkeepUpdateQueueDidChange, object: nil, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.refresh() }
      }
    ]
    manualPreference = ManualAppStorePreferenceObserver { [weak self] in self?.refresh() }
  }

  func stopObserving() {
    observations.forEach { $0.cancel() }
    observations.removeAll()
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    manualPreference = nil
  }

  func refresh(with apps: [App]? = nil) {
    if let apps { self.apps = apps }
    updates = UpdateNotificationController.waitingUpdates(
      in: self.apps, includeExternal: settings.includeAppsWithLimitedSupport)
    let snapshot = AppListSnapshot(withApps: self.apps, filterQuery: nil, settings: settings)
    updateSections = snapshot.sections.filter { group in
      group.apps.contains { !$0.isIgnored && $0.isActionable }
    }
    updateAllCount = updateAllCandidates().count
    running = self.apps.filter(isUpdating)
    needsYouCount = LibraryContent(apps: self.apps, query: nil).needsYouCount
    summary = UpdateStatusSummary(apps: self.apps)
  }
}

/// Opens the main window from places without a SwiftUI environment (notifications, menu).
@MainActor
enum MainWindow {
  static var openWindow: OpenWindowAction?

  static func show() {
    NSApp.activate()
    openWindow?(id: "main")
  }
}

/// Keeps the scene's `openWindow` action for `MainWindow`.
struct MainWindowOpenerCapture: ViewModifier {
  @Environment(\.openWindow) private var openWindow

  func body(content: Content) -> some View {
    content.onAppear { MainWindow.openWindow = openWindow }
  }
}

/// A status item draws only plain images and text, so the label stays one image or one
/// image-and-title Label, with no stacks or modifiers that could leave it empty. While a job
/// runs the icon is the busy glyph.
struct MenuBarLabel: View {
  @ObservedObject var model: MenuBarViewModel

  var body: some View {
    let count = model.updates.count
    if !model.running.isEmpty {
      Image(systemName: "arrow.triangle.2.circlepath")
        .accessibilityLabel(
          model.running.count == 1
            ? "Upkeep, 1 update running" : "Upkeep, \(model.running.count) updates running")
    } else if count == 0 {
      Image("MenuBarIcon", label: Text("Upkeep"))
    } else {
      Label {
        Text("\(count)")
      } icon: {
        Image(
          "MenuBarIcon",
          label: Text(
            count == 1 ? "Upkeep, 1 update available" : "Upkeep, \(count) updates available"))
      }
      .labelStyle(.titleAndIcon)
    }
  }
}

/// The menu bar window: a header saying what is happening, one row per running job (with the
/// callers attached to it and Stop), the updates waiting, a link to Needs You, then commands.
struct MenuBarContentView: View {
  @ObservedObject var model: MenuBarViewModel
  @ObservedObject var checking: UpdateCheckingService
  var updating: any AppUpdating = AppUpdateService.shared
  let select: (App) -> Void
  var showPage: (LibraryPage) -> Void = { _ in }
  @ObservedObject private var activity = AgentActivity.shared
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      VStack(alignment: .leading, spacing: 2) {
        Text(Self.headline(model: model, checking: checking.isRunning)).font(.headline)
        if !subline.isEmpty { Text(subline).font(.callout).foregroundStyle(.secondary) }
      }
      .padding(.horizontal, Space.sm)
      if !model.running.isEmpty || !waiting.isEmpty { Divider() }
      ForEach(model.running, id: \.identifier) { app in jobRow(app) }
      ForEach(waiting.prefix(6), id: \.identifier) { app in
        menuButton("\(app.name)  \(app.versionSummary)") {
          select(app)
          MainWindow.show()
        }
      }
      if model.updateAllCount > 0 {
        menuButton("Update All (\(model.updateAllCount))") { checking.updateAll() }
          .accessibilityHint("Installs every update Upkeep can install itself")
      }
      if model.needsYouCount > 0 {
        Divider()
        Button {
          showPage(.needsYou)
          MainWindow.show()
        } label: {
          HStack {
            Label(
              model.needsYouCount == 1
                ? "1 item needs you" : "\(model.needsYouCount) items need you",
              systemImage: "exclamationmark.circle"
            )
            .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
      }
      Divider()
      menuButton("Check Now", shortcut: "⌘R") { checking.checkForUpdates() }
        .disabled(checking.isRunning)
        .keyboardShortcut("r")
      menuButton("Open Upkeep") { MainWindow.show() }
      menuButton("Settings…", shortcut: "⌘,") { openSettings() }
      menuButton("Quit Upkeep", shortcut: "⌘Q") { NSApp.terminate(nil) }
        .keyboardShortcut("q")
    }
    .padding(Space.sm)
    .frame(width: 380)
    .modifier(MainWindowOpenerCapture())
    .accessibilityIdentifier("menuBar.content")
  }

  /// Waiting updates that are not already running.
  private var waiting: [App] {
    model.updates.filter { app in
      app.capability.isAutomatic && !model.running.contains { $0.identifier == app.identifier }
    }
  }

  static func headline(model: MenuBarViewModel, checking: Bool) -> String {
    if !model.running.isEmpty {
      return model.running.count == 1
        ? "1 update running" : "\(model.running.count) updates running"
    }
    if checking { return "Checking for updates…" }
    if model.updateAllCount > 0 {
      return model.updateAllCount == 1 ? "1 update ready" : "\(model.updateAllCount) updates ready"
    }
    return model.summary.isAllCurrent ? "Everything is up to date" : "No updates Upkeep can install"
  }

  private var subline: String {
    let checked = checking.lastFinished.map {
      "Checked \($0.formatted(.relative(presentation: .named)))"
    }
    let rest =
      model.running.isEmpty || model.updateAllCount > 0 ? nil : "Nothing else Upkeep can install."
    return [rest, checked].compactMap { $0 }.joined(separator: " ")
  }

  private func jobRow(_ app: App) -> some View {
    let job = activity.job(for: app.fileURL.path)
    let callers = [
      job.map { CallerName.display($0.starter.caller) },
      job?.followers.first.map { "\(CallerName.display($0.caller)) also waiting on it" },
    ].compactMap { $0 }.joined(separator: " · ")
    return ObservedUpdatePresentation(app: app, updating: updating) { presentation in
      HStack(alignment: .center, spacing: Space.sm) {
        AppIconView(app: app, size: 28)
        VStack(alignment: .leading, spacing: 2) {
          Text(app.name).font(.headline)
          if !callers.isEmpty { Text(callers).font(.callout).foregroundStyle(.secondary) }
          Text(JobStep.summary(for: app, state: updating.state(for: app.identifier)))
            .font(.callout).foregroundStyle(.secondary)
          ProgressView(value: presentation.fraction).progressViewStyle(.linear)
        }
        StopJobButton(app: app, updating: updating)
      }
      .padding(.horizontal, Space.sm)
      .accessibilityElement(children: .contain)
    }
  }

  private func menuButton(_ title: String, shortcut: String? = nil, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      HStack {
        Text(title).foregroundStyle(.primary)
        Spacer()
        if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(MenuRowStyle())
  }
}

/// Menu-like rows: full width, highlighted on hover.
private struct MenuRowStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HoverRow(configuration: configuration)
  }

  private struct HoverRow: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
      configuration.label
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(
          hovering && isEnabled ? Color.accentColor.opacity(0.18) : .clear,
          in: RoundedRectangle(cornerRadius: Space.sm)
        )
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }
  }
}

/// With the menu bar item showing, closing the last window leaves Upkeep running there.
final class UpkeepAppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    !MenuBarViewModel.showsItem
  }
}
