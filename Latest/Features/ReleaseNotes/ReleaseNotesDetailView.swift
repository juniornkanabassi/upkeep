//
//  ReleaseNotesDetailView.swift
//  Latest
//
//  Created by ertyoii on 31.05.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-06-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import Combine
import SwiftUI

struct ReleaseNotesDetailView: View {
  @ObservedObject var updatesViewModel: UpdatesListViewModel
  @StateObject private var detailViewModel: ReleaseNotesDetailViewModel
  private let history: UpdateHistoryStore

  init(
    updatesViewModel: UpdatesListViewModel,
    detailViewModel: ReleaseNotesDetailViewModel = ReleaseNotesDetailViewModel(),
    history: UpdateHistoryStore = .shared
  ) {
    self.updatesViewModel = updatesViewModel
    self.history = history
    _detailViewModel = StateObject(wrappedValue: detailViewModel)
  }

  var body: some View {
    ReleaseNotesDetailSurface(
      app: detailViewModel.app,
      contentState: detailViewModel.contentState,
      updating: updatesViewModel.updating,
      overview: DetailOverview(snapshot: updatesViewModel.snapshot), history: history,
      companions: detailViewModel.app.map {
        updatesViewModel.content(ignoringSearch: true).companions(of: $0)
      } ?? [],
      retryNotes: { detailViewModel.retry() },
      uninstall: { updatesViewModel.uninstallTarget = $0 }
    )
    .task(id: updatesViewModel.selectedApp.map(ObjectIdentifier.init)) {
      detailViewModel.display(
        updatesViewModel.selectedApp,
        waitForSelectionToSettle: updatesViewModel.isKeyboardSelection)
    }
    .onReceive(
      NotificationCenter.default.publisher(for: ReleaseNotesSourceCatalog.didRefreshNotification)
    ) { _ in
      // The selected app can remain unchanged after discovery settles. A late
      // catalog activation must still retry its notes with the new cache key.
      detailViewModel.display(
        updatesViewModel.selectedApp,
        waitForSelectionToSettle: updatesViewModel.isKeyboardSelection)
    }
    .transaction { transaction in
      transaction.animation = nil
      transaction.disablesAnimations = true
    }
  }

}

/// What the detail pane shows with no app selected: the state of the whole list.
@MainActor
enum DetailOverview: Equatable {
  case lookingForApps
  case checking
  case offline
  /// Nothing to install; "Everything is up to date" only when the summary says all are current.
  case noUpdates(UpdateStatusSummary)
  /// A search matched nothing; the whole inventory's state is not implied.
  case noMatches(String)
  case chooseApp

  init(snapshot: AppListSnapshot) {
    let apps = snapshot.apps
    if apps.isEmpty {
      self = .lookingForApps
    } else if let query = snapshot.filterQuery, !query.isEmpty {
      // While searching, the overview speaks only about the search, never the whole inventory.
      self = snapshot.sections.isEmpty ? .noMatches(query) : .chooseApp
    } else if snapshot.checkingGeneration != nil {
      self = .checking
    } else if snapshot.sections.contains(where: { $0.apps.contains(where: \.isActionable) }) {
      self = .chooseApp
    } else if !apps.contains(where: { $0.remoteVersion != nil }),
      apps.contains(where: { ($0.error as NSError?)?.domain == NSURLErrorDomain })
    {
      // shortcut: offline is inferred from every check failing with a URL error; switch to
      // NWPathMonitor if checks start failing for other reasons while online.
      self = .offline
    } else {
      self = .noUpdates(UpdateStatusSummary(apps: apps))
    }
  }
}

struct ReleaseNotesDetailSurface: View {
  let app: App?
  let contentState: ReleaseNotesDetailContentState
  var updating: any AppUpdating = AppUpdateService.shared
  var overview = DetailOverview.chooseApp
  var history = UpdateHistoryStore.shared
  var companions: [App] = []
  var retryNotes: (() -> Void)?
  var uninstall: ((App) -> Void)?
  @State private var lastResult: UpdateHistoryEntry?

  init(
    app: App?, contentState: ReleaseNotesDetailContentState,
    updating: any AppUpdating = AppUpdateService.shared,
    overview: DetailOverview = .chooseApp, history: UpdateHistoryStore = .shared,
    companions: [App] = [], retryNotes: (() -> Void)? = nil, uninstall: ((App) -> Void)? = nil
  ) {
    self.app = app
    self.contentState = contentState
    self.updating = updating
    self.overview = overview
    self.history = history
    self.companions = companions
    self.retryNotes = retryNotes
    self.uninstall = uninstall
    _lastResult = State(initialValue: app.flatMap { history.latestEntry(for: $0.fileURL) })
  }

  var body: some View {
    VStack(spacing: 0) {
      if let app {
        ScrollView {
          VStack(alignment: .leading, spacing: Space.md) {
            ReleaseNotesHeaderView(app: app, updating: updating)
            ObservedUpdatePresentation(app: app, updating: updating) { presentation in
              VStack(alignment: .leading, spacing: Space.xl) {
                sections(.top, presentation: presentation)
                // One web view for every selection: unchanged notes keep their page and scroll.
                ReleaseNotesSection(
                  app: app, presentation: presentation, contentState: contentState,
                  retry: retryNotes)
                sections(.bottom, presentation: presentation)
              }
            }
            .padding(.horizontal, VisualMetrics.detailHeaderHorizontalPadding)
          }
          .padding(.vertical, Space.lg)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("detail.scroll")
        DetailFooter(app: app, uninstall: uninstall)
      } else {
        DetailOverviewView(overview: overview)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .textBackgroundColor))
    .onChange(of: app.map(ObjectIdentifier.init)) { _, _ in refreshLastResult() }
    .onReceive(
      NotificationCenter.default.publisher(
        for: UpdateHistoryStore.didRecordNotification, object: history
      )
      .receive(on: DispatchQueue.main)
    ) { _ in refreshLastResult() }
  }

  private func refreshLastResult() {
    lastResult = app.flatMap { history.latestEntry(for: $0.fileURL) }
  }

  private func sections(_ part: AppDetailSections.Part, presentation: UpdateActionPresentation)
    -> some View
  {
    AppDetailSections(
      app: app!, part: part, presentation: presentation, updating: updating,
      lastResult: lastResult, companions: companions
    )
    .id(app.map(ObjectIdentifier.init))
  }
}

struct ReleaseNotesHeaderView: View {
  let app: App
  let updating: any AppUpdating
  // App equality compares identifiers and versions; refreshed metadata/actions need object identity.
  private let appIdentity: ObjectIdentifier
  @State private var icon: NSImage?

  init(app: App, updating: any AppUpdating = AppUpdateService.shared) {
    self.app = app
    self.updating = updating
    appIdentity = ObjectIdentifier(app)
  }

  var body: some View {
    HStack(alignment: .center, spacing: Space.lg) {
      Group {
        if let icon {
          Image(nsImage: icon)
            .resizable()
            .scaledToFit()
        } else {
          Color.clear
        }
      }
      .frame(width: VisualMetrics.detailIconSize, height: VisualMetrics.detailIconSize)
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: Space.xs) {
        Text(app.name)
          .font(.title2.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
          .help(app.name)
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
          Text(versionLine)
            .accessibilityLabel(versionLine.replacingOccurrences(of: "→", with: "to"))
            .font(.body.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(app.sourceName)
            .font(.caption)
            .padding(.horizontal, Space.xs + 2)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityLabel("Checked with \(app.sourceName)")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .layoutPriority(1)

      // Up-to-date apps, helpers and drivers have nothing to do here; the footer has Finder.
      if app.isActionable || !Self.isIdle(updating.state(for: app.identifier)) {
        UpdateActionView(app: app, updating: updating)
          .id(appIdentity)
      }

    }
    .padding(.horizontal, VisualMetrics.detailHeaderHorizontalPadding)
    .frame(minHeight: VisualMetrics.detailHeaderHeight)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("release-notes.header")
    .task(id: IconCache.shared.cacheKey(for: app, pointSize: VisualMetrics.detailIconSize)) {
      icon = IconCache.shared.cachedIcon(for: app, pointSize: VisualMetrics.detailIconSize)
      let loadedIcon = await IconCache.shared.icon(
        for: app, pointSize: VisualMetrics.detailIconSize)
      guard !Task.isCancelled else { return }
      icon = loadedIcon
    }
  }

  private static func isIdle(_ state: UpdateProgressState) -> Bool {
    if case .none = state { return true }
    return false
  }

  private var versionLine: String {
    let current = app.localizedVersionInformation?.rawCurrent ?? ""
    if app.availabilityUnknown { return "\(current) installed" }
    if app.updateAvailable, let new = app.localizedVersionInformation?.rawNew {
      return "\(current) → \(new)"
    }
    return current
  }
}

extension UpdateHistoryEntry {
  /// "Updated 1.0 → 1.1, 2 Nov 2026" for the detail pane's Last update row.
  var displaySummary: String {
    let when = date.formatted(.dateTime.day().month(.abbreviated).year())
    let what: String
    switch outcome {
    case .updated(let from, let to): what = "Updated \(from) → \(to)"
    case .noChange(let reason): what = "Nothing changed" + (reason.map { ": \($0)" } ?? "")
    case .needsPermission(let kind):
      what = kind == "administrator" ? "Needed your password" : "Blocked by App Management"
    case .uninstalled: what = "Uninstalled"
    case .settingChanged(let setting, let on):
      what = (setting == "ignore" ? "Ignore updates " : "Update automatically ") + (on ? "on" : "off")
    case .needsQuit: what = "Not updated: the app didn't quit"
    case .failed(let reason, _): what = "Failed: \(reason)"
    case .handedOff:
      // Only a record that says it opened something may claim so; older records never do.
      if let note = handOff, note.opened {
        what = "Opened \(note.destination)"
      } else if let note = handOff {
        what =
          "Needed \(note.destination): \(note.reason)"
          + (note.blockedByPolicy ? " (not opened from the command line)" : "")
      } else {
        what = "Handed off to its own updater"
      }
    }
    return "\(what), \(when)"
  }
}

private struct DetailOverviewView: View {
  let overview: DetailOverview

  var body: some View {
    Group {
      switch overview {
      case .lookingForApps:
        ContentUnavailableView {
          ProgressView().controlSize(.large)
        } description: {
          Text("Looking for apps on this Mac…")
        }
      case .checking:
        ContentUnavailableView {
          ProgressView().controlSize(.large)
        } description: {
          Text("Checking for updates. Apps with updates appear on the left as they're found.")
        }
      case .offline:
        ContentUnavailableView(
          "Can't Reach Update Servers", systemImage: "wifi.exclamationmark",
          description: Text("Check your internet connection, then click Check for Updates."))
      case .noUpdates(let summary) where summary.isAllCurrent:
        ContentUnavailableView(
          "Everything Is Up to Date", systemImage: "checkmark.circle",
          description: Text(
            summary.current == 1
              ? "Upkeep checked 1 app." : "Upkeep checked \(summary.current) apps."))
      case .noUpdates(let summary):
        ContentUnavailableView(
          "Nothing for Upkeep to Install", systemImage: "info.circle",
          description: Text(summary.text))
      case .noMatches(let query):
        ContentUnavailableView.search(text: query)
      case .chooseApp:
        ContentUnavailableView(
          "No App Selected", systemImage: "square.stack",
          description: Text("Select an app to see what Update will do."))
      }
    }
    .accessibilityIdentifier("detail.overview")
  }
}
