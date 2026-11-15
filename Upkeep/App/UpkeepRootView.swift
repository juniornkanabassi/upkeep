//
//  UpkeepRootView.swift
//  Latest
//
//  Structural split from the original implementation.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-29.
//  Licensed under GPL-3.0; see LICENSE.md.

import Combine
import SwiftUI

struct UpkeepRootView: View {
  let environment: AppEnvironment
  private let detailViewModel: ReleaseNotesDetailViewModel
  private let history: UpdateHistoryStore
  @StateObject private var receipt: UpdateReceiptModel

  @FocusState private var focus: SidebarFocus?
  @ObservedObject private var updatesViewModel: UpdatesListViewModel
  @ObservedObject private var checking: UpdateCheckingService
  @ObservedObject private var searchFocusController: SearchFocusController
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  /// Below this width the window uses the compact layout of screens 12 and 13.
  static let compactWidth: CGFloat = 1100
  @State private var compact = false
  init(
    environment: AppEnvironment,
    detailViewModel: ReleaseNotesDetailViewModel = ReleaseNotesDetailViewModel(),
    history: UpdateHistoryStore = .shared,
    receipt: UpdateReceiptModel? = nil
  ) {
    self.environment = environment
    self.detailViewModel = detailViewModel
    self.history = history
    _receipt = StateObject(wrappedValue: receipt ?? UpdateReceiptModel(history: history))
    _updatesViewModel = ObservedObject(wrappedValue: environment.updatesListViewModel)
    _checking = ObservedObject(wrappedValue: environment.updateCheckingService)
    _searchFocusController = ObservedObject(wrappedValue: environment.searchFocusController)
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      LibrarySidebar(viewModel: updatesViewModel)
        .navigationSplitViewColumnWidth(min: 200, ideal: VisualMetrics.sidebarIdealWidth, max: 320)
    } detail: {
      UpdatesSidebarView(
        viewModel: updatesViewModel, searchFocusController: environment.searchFocusController
      ) { focus in
        VStack(spacing: 0) {
          if let message = receipt.message {
            UpdateReceiptBanner(message: message, dismiss: receipt.dismiss)
          }
          page(focus: focus)
        }
      }
      .navigationTitle(updatesViewModel.page.title)
      .navigationSubtitle(subtitle)
    }
    .environment(\.windowFocus, $focus)
    .environment(\.appPreferences, environment.preferences)
    .environment(\.compactLayout, compact)
    // Narrow windows hide the sidebar (its toolbar button brings it back) and row buttons.
    .onGeometryChange(for: Bool.self) {
      $0.size.width < Self.compactWidth
    } action: { narrow in
      compact = narrow
      columnVisibility = narrow ? .detailOnly : .all
    }
    .onChange(of: searchFocusController.request) { _, request in
      if request != nil { columnVisibility = .all }
    }
    .onAppear {
      if searchFocusController.hasPendingRequest { columnVisibility = .all }
    }
    .modifier(UpdateInstallHelperPresentation())
    .toolbar {
      UpdatesToolbar(
        service: environment.updateCheckingService, summary: environment.menuBar,
        prominent: updatesViewModel.page == .updates,
        reload: { environment.commands.reload() },
        updateAll: { environment.commands.updateAll() })
    }
    .sheet(item: $updatesViewModel.uninstallTarget) { app in
      UninstallSheet(
        model: UninstallSheetModel(app: app, service: environment.uninstall),
        dismiss: { updatesViewModel.uninstallTarget = nil })
    }
  }

  @ViewBuilder
  private func page(focus: FocusState<SidebarFocus?>.Binding) -> some View {
    if updatesViewModel.page == .history {
      HistoryPage(
        history: history, apps: updatesViewModel.snapshot.apps, query: updatesViewModel.searchQuery)
    } else {
      GeometryReader { geometry in
        HStack(spacing: 0) {
          Group {
            if updatesViewModel.page == .allApps {
              AllAppsTable(viewModel: updatesViewModel)
            } else {
              UpdatesScrollList(viewModel: updatesViewModel, focus: focus)
            }
          }
          .frame(width: Self.listWidth(page: updatesViewModel.page, total: geometry.size.width))
          Divider()
          ReleaseNotesDetailView(
            updatesViewModel: updatesViewModel, detailViewModel: detailViewModel, history: history)
        }
      }
    }
  }

  /// The list keeps a readable width; the detail takes the rest.
  static func listWidth(page: LibraryPage, total: CGFloat) -> CGFloat {
    let share: CGFloat = page == .allApps ? 0.62 : 0.46
    return min(max(total * share, 300), max(total - 300, 300))
  }

  private var subtitle: String {
    let content = updatesViewModel.content(ignoringSearch: true)
    switch updatesViewModel.page {
    case .updates:
      return environment.updateCheckingService.lastFinished.map {
        "Checked \($0.formatted(.relative(presentation: .named)))"
      } ?? "Not checked yet"
    case .needsYou:
      return "Items with a next step. Apps that can't be checked at all stay in All Apps"
    case .allApps:
      return
        "\(LibraryContent.count(content.allAppsCount, "app")). \(LibraryContent.count(content.helperCount, "helper")) sit inside the app or folder they came with"
    case .drivers:
      return "Found on this Mac. New versions come from each maker's download list or Homebrew"
    case .history: return "Updates, settings and removals, newest first"
    }
  }
}

/// Receipts follow verified history events, independently of list selection or filtering.
@MainActor
final class UpdateReceiptModel: ObservableObject {
  @Published private(set) var count = 0
  @Published private(set) var latest: UpdateHistoryEntry?
  private var observation: AnyCancellable?

  init(history: UpdateHistoryStore) {
    observation = NotificationCenter.default.publisher(
      for: UpdateHistoryStore.didRecordNotification, object: history
    )
    // Hop to main first: history posts from the update's background thread, and this closure
    // is main-actor isolated, so running it there crashed Upkeep after every such update.
    .receive(on: DispatchQueue.main)
    .compactMap { $0.userInfo?[UpdateHistoryStore.entryKey] as? UpdateHistoryEntry }
    .sink { [weak self] entry in
      guard case .updated = entry.outcome, let self else { return }
      self.count += 1
      if let latest = self.latest, latest.date > entry.date { return }
      self.latest = entry
    }
  }

  var message: String? {
    guard let latest, case .updated(_, let version) = latest.outcome else { return nil }
    let name = URL(fileURLWithPath: latest.appPath).deletingPathExtension().lastPathComponent
    let result = "Updated \(name) to \(version)."
    return count == 1 ? result : "\(count) updates completed. \(result)"
  }

  func dismiss() {
    count = 0
    latest = nil
  }
}

struct UpdateReceiptBanner: View {
  let message: String
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
      Label(message, systemImage: "checkmark.circle")
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .frame(width: Space.xxl, height: Space.xxl)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Dismiss update confirmation")
      .accessibilityLabel("Dismiss update confirmation")
      .accessibilityIdentifier("updates.receipt.dismiss")
    }
    .font(.callout)
    .padding(.horizontal, VisualMetrics.detailHeaderHorizontalPadding)
    .padding(.vertical, Space.md)
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("updates.receipt")
    Divider()
  }
}
