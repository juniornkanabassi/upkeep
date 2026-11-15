// Fork contributions © 2026 ertyoii.
// Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import Combine
import SwiftUI

/// Native selection, keyboard navigation, scrolling and context-menu targeting.
struct UpdatesScrollList: View {
  @ObservedObject var viewModel: UpdatesListViewModel
  let focus: FocusState<SidebarFocus?>.Binding
  @Environment(\.controlActiveState) private var controlActiveState

  static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    formatter.doesRelativeDateFormatting = true
    return formatter
  }()

  var body: some View {
    List(
      selection: Binding(
        get: { viewModel.selectedAppIDs },
        set: { viewModel.select($0, isKeyboardSelection: NSApp.currentEvent?.type == .keyDown) }
      )
    ) {
      if let note = PageNote.top(viewModel) { note }
      ForEach(viewModel.pageSections) { group in
        Section {
          ForEach(group.apps, id: \.identifier) { app in
            UpdateRowView(
              app: app, selection: UpdateRowSelection(style: selectionStyle(for: app)),
              date: Self.dateFormatter.string(from: app.updateDate),
              updating: viewModel.updating
            )
            .frame(minHeight: VisualMetrics.appRowHeight)
            .tag(app.identifier)
            .accessibilityIdentifier("updates.app.\(app.identifier)")
          }
        } header: {
          UpdateSectionHeaderView(section: group.section)
        }
      }
      if let note = PageNote.bottom(viewModel) { note }
    }
    .listStyle(.sidebar)
    .background(SidebarScrollConfiguration())
    .focused(focus, equals: .list)
    .contextMenu(forSelectionType: App.Bundle.Identifier.self) { identifiers in
      let apps = viewModel.apps(for: identifiers)
      if apps.count == 1, let app = apps.first {
        UpdatesRowMenu(app: app, viewModel: viewModel)
      } else if !apps.isEmpty {
        Button("Update Selected Apps") { viewModel.updateSelection(identifiers) }
          .disabled(viewModel.automaticUpdateCandidates(identifiers).isEmpty)
        Button("Ignore Selected Apps") {
          apps.forEach { viewModel.setIgnored(true, for: $0) }
        }
        Button("Don't Ignore Selected Apps") {
          apps.forEach { viewModel.setIgnored(false, for: $0) }
        }
      }
    }
    .overlay {
      if viewModel.pageSections.isEmpty {
        PageEmptyView(viewModel: viewModel)
      }
    }
    .accessibilityIdentifier("updates.list")
    .accessibilityLabel("Apps")
  }

  private func selectionStyle(for app: App) -> UpdateRowSelection.Style {
    guard viewModel.selectedAppIDs.contains(app.identifier) else { return .unselected }
    return controlActiveState != .inactive && focus.wrappedValue == .list ? .active : .inactive
  }
}

private struct UpdatesRowMenu: View {
  let app: App
  let viewModel: UpdatesListViewModel

  var body: some View {
    Button {
      viewModel.update(app)
    } label: {
      Label(SidebarUpdateActionTitle.text(for: app), systemImage: "square.and.arrow.down")
    }.disabled(!app.isActionable || viewModel.updating.isUpdating(app))
    AppSettingsMenuItems(app: app, viewModel: viewModel)
    Divider()
    Button {
      viewModel.open(app)
    } label: {
      Label(
        NSLocalizedString("OpenAction", comment: "Open app"), systemImage: "arrow.up.forward.app")
    }
    Button {
      viewModel.revealInFinder(app)
    } label: {
      Label(NSLocalizedString("RevealAction", comment: "Reveal app"), systemImage: "finder")
    }
    if app.bundle.kind == .app, app.bundle.parent == nil {
      Divider()
      Button("Uninstall \(app.name)…") { viewModel.uninstallTarget = app }
    }
  }
}

/// Update Automatically and Ignore Updates, the same switches as the detail pane. A setting
/// that can't apply is shown disabled with the reason, never hidden.
struct AppSettingsMenuItems: View {
  let app: App
  @ObservedObject var viewModel: UpdatesListViewModel
  @Environment(\.appPreferences) private var preferences

  var body: some View {
    if let preferences {
      Toggle(
        AppPreferences.canAutoUpdate(app) ? "Update Automatically" : "Update Automatically (not available)",
        isOn: Binding(
          get: { preferences.autoUpdates(app) },
          set: { try? preferences.set(.autoUpdate, $0, for: app, caller: "gui") })
      )
      .disabled(!AppPreferences.canAutoUpdate(app) || app.isIgnored)
      Toggle(
        "Ignore Updates",
        isOn: Binding(
          get: { app.isIgnored },
          set: { try? preferences.set(.ignore, $0, for: app, caller: "gui") }))
    } else {
      Toggle(
        "Ignore Updates",
        isOn: Binding(get: { app.isIgnored }, set: { viewModel.setIgnored($0, for: app) }))
    }
  }
}

/// The line above or below a list page that says what is left out and where it went.
@MainActor
private enum PageNote {
  static func top(_ viewModel: UpdatesListViewModel) -> AnyView? {
    guard viewModel.page == .needsYou else { return nil }
    let missing = viewModel.content.uncheckable
    guard !missing.isEmpty else { return nil }
    let examples = missing.prefix(2).map(\.name).joined(separator: " and ")
    return AnyView(
      CalloutView(symbol: "info.circle") {
        Text(
          "Only items with a next step. \(LibraryContent.count(missing.count, "app")) can't be checked at all, such as \(examples). "
        )
          + Text("[Show them in All Apps](upkeep://all-apps)")
      }
      .environment(\.openURL, OpenURLAction { _ in
        viewModel.page = .allApps
        return .handled
      })
      .listRowSeparator(.hidden)
      .selectionDisabled())
  }

  static func bottom(_ viewModel: UpdatesListViewModel) -> AnyView? {
    guard viewModel.page == .updates, !viewModel.pageSections.isEmpty else {
      if viewModel.page == .drivers, viewModel.content.hiddenAppleDrivers > 0 {
        let count = viewModel.content.hiddenAppleDrivers
        return AnyView(
          Text(
            "No update source means checking the maker's website. \(count) Apple driver\(count == 1 ? " is" : "s are") hidden because \(count == 1 ? "it updates" : "they update") with macOS."
          )
          .font(.callout).foregroundStyle(.secondary)
          .listRowSeparator(.hidden).selectionDisabled())
      }
      return nil
    }
    let waiting = viewModel.content.needsYouCount
    guard waiting > 0 else { return nil }
    return AnyView(
      (Text("That is everything Upkeep can install itself. ")
        + Text("[\(LibraryContent.count(waiting, "item")) in Needs You](upkeep://needs-you)")
        + Text(" need\(waiting == 1 ? "s" : "") a step from you."))
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.openURL, OpenURLAction { _ in
          viewModel.page = .needsYou
          return .handled
        })
        .padding(.top, Space.sm)
        .listRowSeparator(.hidden)
        .selectionDisabled())
  }
}

/// A page with nothing in it says why and offers the next place to look.
private struct PageEmptyView: View {
  @ObservedObject var viewModel: UpdatesListViewModel

  var body: some View {
    if !viewModel.searchQuery.isEmpty {
      ContentUnavailableView {
        Label("No Results for “\(viewModel.searchQuery)”", systemImage: "magnifyingglass")
      } description: {
        Text("Nothing in \(viewModel.page.title) matches.")
      } actions: {
        Button("Search All Apps") { viewModel.page = .allApps }
        Button("Clear Search") { viewModel.setSearchQuery("") }
      }
    } else if viewModel.snapshot.apps.isEmpty || viewModel.snapshot.checkingGeneration != nil {
      ContentUnavailableView {
        ProgressView().controlSize(.large)
      } description: {
        Text("Checking for updates…")
      }
    } else if viewModel.page == .updates {
      let waiting = viewModel.content.needsYouCount
      ContentUnavailableView {
        Label("No Updates Upkeep Can Install", systemImage: "checkmark.circle")
      } description: {
        Text(waiting == 0 ? "Everything Upkeep can check is up to date." : "\(LibraryContent.count(waiting, "item")) need a step from you.")
      } actions: {
        if waiting > 0 { Button("Review \(LibraryContent.count(waiting, "Item"))") { viewModel.page = .needsYou } }
      }
    } else {
      ContentUnavailableView(
        "Nothing Needs You", systemImage: "checkmark.circle",
        description: Text("No update is waiting for a step from you."))
    }
  }
}
