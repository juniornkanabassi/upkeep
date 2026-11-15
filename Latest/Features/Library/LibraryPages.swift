// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import Combine
import SwiftUI

/// Every app at a glance: Status, Auto-update and Ignore columns, helpers under their parent.
/// A dash is the one sign for "can't", with the reason in its help tag and VoiceOver label.
struct AllAppsTable: View {
  @ObservedObject var viewModel: UpdatesListViewModel
  @Environment(\.appPreferences) private var preferences

  var body: some View {
    Table(
      viewModel.content.allAppRows, children: \.children,
      selection: Binding(
        get: { viewModel.selectedAppIDs },
        set: { viewModel.select($0) })
    ) {
      TableColumn("Name") { row in
        HStack(spacing: Space.sm) {
          AppIconView(app: row.app, size: 20)
          Text(row.name).lineLimit(1)
          if let detail = row.detail {
            Text(detail).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        .accessibilityElement(children: .combine)
      }
      .width(min: 180, ideal: 260)
      TableColumn("Status") { row in
        if let app = row.app {
          let (text, tone) = LibraryStatus.text(for: app)
          Label(text, systemImage: Self.symbol(tone))
            .labelStyle(StatusLabelStyle(showsIcon: tone != .secondary))
            .foregroundStyle(Self.color(tone))
            .lineLimit(1)
        } else {
          Text("Not checked").foregroundStyle(.secondary)
        }
      }
      .width(min: 140, ideal: 190)
      TableColumn("Auto-update") { row in
        setting(.autoUpdate, row: row)
      }
      .width(84)
      .alignment(.center)
      TableColumn("Ignore") { row in
        setting(.ignore, row: row)
      }
      .width(56)
      .alignment(.center)
    }
    .contextMenu(forSelectionType: URL.self) { identifiers in
      if let app = viewModel.apps(for: identifiers).first, identifiers.count == 1 {
        AllAppsRowMenu(app: app, viewModel: viewModel)
      }
    }
    .overlay {
      if viewModel.content.allAppRows.isEmpty, !viewModel.searchQuery.isEmpty {
        ContentUnavailableView.search(text: viewModel.searchQuery)
      }
    }
    .accessibilityIdentifier("library.allApps")
  }

  @ViewBuilder
  private func setting(_ setting: AppPreferences.Setting, row: LibraryContent.Row) -> some View {
    if let app = row.app, let preferences, let reason = Self.unavailableReason(setting, app: app) {
      DashCell(reason: reason)
    } else if let app = row.app, let preferences {
      Toggle(
        isOn: Binding(
          get: { preferences.value(setting, for: app) },
          set: { try? preferences.set(setting, $0, for: app, caller: "gui") })
      ) { EmptyView() }
      .toggleStyle(.checkbox)
      .labelsHidden()
      .frame(width: Space.xxl, height: Space.xxl)
      .accessibilityLabel(setting == .ignore ? "Ignore updates for \(app.name)" : "Update \(app.name) automatically")
    } else {
      DashCell(reason: row.app == nil ? "A folder of apps. Choose an app inside it." : "Settings are unavailable.")
    }
  }

  /// Why a switch can't apply to this app, or nil when it can.
  @MainActor
  static func unavailableReason(_ setting: AppPreferences.Setting, app: App) -> String? {
    if let parent = app.bundle.parent { return "Updates with \(parent), so it follows that app's settings." }
    if app.isUpdaterItself { return "Upkeep can't update itself yet." }
    guard setting == .autoUpdate else { return nil }
    if app.isIgnored { return "Updates are ignored. Stop ignoring \(app.name) to update it automatically." }
    if AppPreferences.canAutoUpdate(app) { return nil }
    if app.isSourcePending { return "Still checking how \(app.name) updates." }
    if app.relaunchesToUpdate || app.externalUpdaterName == app.name {
      return "\(app.name) installs its own updates, so Upkeep can't update it automatically."
    }
    if app.externalUpdaterName == HomebrewCheckerOperation.handOffLabel {
      return "\(app.name)'s update comes as a Homebrew command you run in Terminal."
    }
    if let updater = app.externalUpdaterName {
      return "\(app.name) updates through \(updater), so Upkeep can't update it automatically."
    }
    return "Upkeep has no way to install \(app.name)'s updates itself."
  }

  static func symbol(_ tone: LibraryStatus.Tone) -> String {
    switch tone {
    case .positive: "checkmark.circle"
    case .accent: "arrow.down.circle"
    case .secondary: "circle"
    }
  }

  static func color(_ tone: LibraryStatus.Tone) -> Color {
    switch tone {
    case .positive: Color(nsColor: .systemGreen)
    case .accent: .accentColor
    case .secondary: .secondary
    }
  }
}

private struct StatusLabelStyle: LabelStyle {
  let showsIcon: Bool
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: Space.xs) {
      if showsIcon { configuration.icon }
      configuration.title
    }
  }
}

/// The one sign for "can't": a dash in a full-size hit area, explained on hover and to VoiceOver.
struct DashCell: View {
  let reason: String

  var body: some View {
    Text("–")
      .foregroundStyle(.secondary)
      .frame(width: Space.xxl, height: Space.xxl)
      .contentShape(Rectangle())
      .help(reason)
      .accessibilityLabel("Not available. \(reason)")
  }
}

private struct AllAppsRowMenu: View {
  let app: App
  @ObservedObject var viewModel: UpdatesListViewModel

  var body: some View {
    if app.isActionable {
      Button(SidebarUpdateActionTitle.text(for: app)) { viewModel.update(app) }
        .disabled(viewModel.updating.isUpdating(app))
    } else {
      Button(LibraryStatus.text(for: app).0) {}.disabled(true)
    }
    Divider()
    AppSettingsMenuItems(app: app, viewModel: viewModel)
    Divider()
    Button("Open \(app.name)") { viewModel.open(app) }
    Button("Show in Finder") { viewModel.revealInFinder(app) }
    if app.bundle.parent == nil, !app.isUpdaterItself {
      Divider()
      Button("Uninstall \(app.name)…") { viewModel.uninstallTarget = app }
    }
  }
}

/// An app's icon from the shared cache, or a lettered tile for folders and drivers.
struct AppIconView: View {
  let app: App?
  var name: String? = nil
  let size: CGFloat
  @State private var icon: NSImage?

  var body: some View {
    Group {
      if let icon {
        Image(nsImage: icon).resizable().scaledToFit()
      } else {
        RoundedRectangle(cornerRadius: size * 0.22)
          .fill(.quaternary)
          .overlay(
            Text(String((app?.name ?? name ?? "?").prefix(1)).uppercased())
              .font(.system(size: size * 0.45, weight: .semibold))
              .foregroundStyle(.secondary))
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
    .task(id: app.map { IconCache.shared.cacheKey(for: $0, pointSize: size) }) {
      guard let app, app.bundle.kind == .app else { return }
      icon = IconCache.shared.cachedIcon(for: app, pointSize: size)
      let loaded = await IconCache.shared.icon(for: app, pointSize: size)
      guard !Task.isCancelled else { return }
      icon = loaded
    }
  }
}

// MARK: History

/// Updates, setting changes and removals, newest first, grouped by day. Actor names stay
/// neutral; the status word and icon sit apart from them.
struct HistoryPage: View {
  let history: UpdateHistoryStore
  let apps: [App]
  let query: String
  @State private var entries = [UpdateHistoryEntry]()

  var body: some View {
    let filtered = query.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    List {
      ForEach(Self.days(filtered), id: \.0) { day, entries in
        Section(day) {
          ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            HistoryRow(entry: entry, app: apps.first { $0.fileURL.path == entry.appPath })
          }
        }
      }
    }
    .listStyle(.inset)
    .scrollContentBackground(.hidden)
    .overlay {
      if filtered.isEmpty {
        if query.isEmpty {
          ContentUnavailableView(
            "No History Yet", systemImage: "clock",
            description: Text("Updates, setting changes and removals appear here, newest first."))
        } else {
          ContentUnavailableView.search(text: query)
        }
      }
    }
    .task { entries = history.entries(limit: 500) }
    .onReceive(
      NotificationCenter.default.publisher(for: UpdateHistoryStore.didRecordNotification, object: history)
        .receive(on: DispatchQueue.main)
    ) { _ in entries = history.entries(limit: 500) }
    .accessibilityIdentifier("library.history")
  }

  static func days(_ entries: [UpdateHistoryEntry]) -> [(String, [UpdateHistoryEntry])] {
    let calendar = Calendar.current
    var groups = [(String, [UpdateHistoryEntry])]()
    for entry in entries {
      let title =
        calendar.isDateInToday(entry.date)
        ? "Today"
        : calendar.isDateInYesterday(entry.date)
          ? "Yesterday" : entry.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
      if groups.last?.0 == title { groups[groups.count - 1].1.append(entry) } else { groups.append((title, [entry])) }
    }
    return groups
  }
}

private struct HistoryRow: View {
  let entry: UpdateHistoryEntry
  let app: App?

  var body: some View {
    let presentation = entry.presentation
    HStack(alignment: .top, spacing: Space.md) {
      AppIconView(app: app, name: entry.name, size: 32)
      VStack(alignment: .leading, spacing: 2) {
        Text(presentation.title).font(.headline)
        Text(presentation.detail).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .trailing, spacing: 2) {
        Label(presentation.status, systemImage: presentation.symbol)
          .foregroundStyle(presentation.tint)
        Text("\(CallerName.display(entry.caller)), \(entry.date.formatted(date: .omitted, time: .shortened))")
          .font(.callout).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, Space.xs)
    .accessibilityElement(children: .combine)
  }
}

extension UpdateHistoryEntry {
  var name: String { URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent }

  struct Presentation {
    let title: String
    let detail: String
    let status: String
    let symbol: String
    let tint: Color
  }

  @MainActor
  var presentation: Presentation {
    let done = Color(nsColor: .systemGreen), failed = Color(nsColor: .systemRed)
    let followed = (followers ?? []).map(CallerName.display)
    let satisfied =
      followed.isEmpty
      ? "" : " \(followed.joined(separator: " and "))'s request was satisfied by this update"
    switch outcome {
    case .updated(_, let to):
      return Presentation(
        title: "Updated \(name) to \(to)", detail: "Verified on disk." + satisfied,
        status: "Done", symbol: "checkmark.circle", tint: done)
    case .noChange(let reason):
      return Presentation(
        title: "\(name) was not updated", detail: reason ?? "The version on disk didn't change.",
        status: "No change", symbol: "circle", tint: .secondary)
    case .needsPermission(let kind):
      return Presentation(
        title: "Update of \(name) needed permission",
        detail: kind == "administrator" ? "It needed your password." : "App Management blocked it.",
        status: "Failed", symbol: "xmark.circle", tint: failed)
    case .needsQuit:
      return Presentation(
        title: "Update of \(name) didn't start", detail: "\(name) didn't quit, so nothing changed.",
        status: "Stopped", symbol: "stop.circle", tint: .secondary)
    case .failed(let reason, _):
      return Presentation(
        title: "Update of \(name) failed", detail: reason, status: "Failed",
        symbol: "xmark.circle", tint: failed)
    case .handedOff:
      let destination = handOff?.destination ?? "its own updater"
      return Presentation(
        title: "Opened \(destination) to update \(name)",
        detail: handOff?.opened == false ? (handOff?.reason ?? "") : "Finish the update there.",
        status: handOff?.opened == false ? "Not opened" : "Handed off", symbol: "arrow.up.forward.app",
        tint: .secondary)
    case .uninstalled:
      return Presentation(
        title: "Uninstalled \(name)", detail: "Moved to the Bin.", status: "Done",
        symbol: "checkmark.circle", tint: done)
    case .settingChanged(let setting, let on):
      let what = setting == "ignore" ? (on ? "Ignored \(name) updates" : "Stopped ignoring \(name) updates")
        : (on ? "Turned on automatic updates for \(name)" : "Turned off automatic updates for \(name)")
      let how = CallerName.isAgent(caller) ? "Set through \(CallerName.display(caller)). Undo from \(name)'s details" : "Set in Upkeep"
      return Presentation(title: what, detail: how, status: "Setting changed", symbol: "circle", tint: .secondary)
    }
  }
}
