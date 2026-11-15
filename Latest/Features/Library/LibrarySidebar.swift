// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Combine
import SwiftUI

extension EnvironmentValues {
  /// Per-app switches; nil in component tests that don't exercise them.
  @Entry var appPreferences: AppPreferences? = nil
}

/// The window's navigation: To do (Updates, Needs You) and Library (All Apps, Drivers &
/// Extensions, History), with counts, and a summary card while an agent runs an update.
struct LibrarySidebar: View {
  @ObservedObject var viewModel: UpdatesListViewModel

  var body: some View {
    let content = viewModel.content(ignoringSearch: true)
    List(
      selection: Binding(
        get: { viewModel.page }, set: { if let page = $0 { viewModel.page = page } })
    ) {
      Section("To do") {
        row(.updates, count: content.updates.count, emphasised: true)
        row(.needsYou, count: content.needsYouCount, emphasised: true)
      }
      Section("Library") {
        row(.allApps, count: content.allAppsCount)
        row(.drivers, count: content.driverCount)
        row(.history, count: nil)
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom) {
      AgentActivityCard(apps: content.updates, updating: viewModel.updating)
        .padding(Space.sm)
    }
    .accessibilityIdentifier("library.sidebar")
  }

  private func row(_ page: LibraryPage, count: Int?, emphasised: Bool = false) -> some View {
    Label(page.title, systemImage: page.symbol)
      .badge(count.map { Text("\($0)").fontWeight(emphasised && $0 > 0 ? .semibold : .regular) })
      .tag(page)
      .accessibilityIdentifier("library.page.\(page.rawValue)")
  }
}

extension UpdatesListViewModel {
  func content(ignoringSearch: Bool) -> LibraryContent {
    ignoringSearch
      ? LibraryContent(apps: snapshot.apps, query: nil, isUpdating: updating.isUpdating) : content
  }
}

/// "Codex is updating ChatGPT": a short summary of the first update an agent started, with
/// Stop. The detail pane keeps the full steps.
struct AgentActivityCard: View {
  let apps: [App]
  let updating: any AppUpdating
  @ObservedObject private var activity = AgentActivity.shared

  var body: some View {
    if let app = apps.first(where: {
      updating.isUpdating($0)
        && CallerName.isAgent(activity.job(for: $0.fileURL.path)?.starter.caller)
    }),
      let job = activity.job(for: app.fileURL.path)
    {
      ObservedUpdatePresentation(app: app, updating: updating) { presentation in
        VStack(alignment: .leading, spacing: Space.xs) {
          Label(
            "\(CallerName.display(job.starter.caller)) is updating \(app.name)",
            systemImage: "sparkle"
          )
          .font(.headline)
          .labelStyle(.titleAndIcon)
          Text(JobStep.summary(for: app, state: updating.state(for: app.identifier)))
            .font(.callout).foregroundStyle(.secondary)
          ProgressView(value: presentation.fraction)
            .progressViewStyle(.linear)
          HStack(alignment: .center, spacing: Space.sm) {
            if let follower = job.followers.first {
              Text("\(CallerName.display(follower.caller)) is also following this update")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            StopJobButton(app: app, updating: updating)
          }
        }
        .padding(Space.md)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Space.md))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.agentCard")
      }
    }
  }
}

/// Stop works until the replace step; then the old copy is being swapped and stopping could
/// leave the app half replaced, so it is unavailable with the reason in its help tag.
struct StopJobButton: View {
  let app: App
  let updating: any AppUpdating

  var body: some View {
    let stoppable = JobStep.isStoppable(updating.state(for: app.identifier))
    Button {
      updating.cancel(app)
    } label: {
      Label("Stop", systemImage: "stop.circle.fill")
    }
    .buttonStyle(.bordered)
    .buttonBorderShape(.capsule)
    .controlSize(.small)
    .disabled(!stoppable)
    .help(
      stoppable
        ? "Stop this update. Nothing changes."
        : "Stop isn't available while the app is being replaced."
    )
    .accessibilityIdentifier("job.stop")
  }
}

extension UpdateActionPresentation {
  var fraction: Double? {
    if case .progress(let fraction, _, _) = self { return fraction }
    return nil
  }
}

/// The steps of an install, read from the scheduler's state.
@MainActor
enum JobStep {
  static func titles(for app: App) -> [String] {
    [
      "Download and check the signature", "Wait for \(app.name) to quit", "Replace the app",
      "Verify the new version on disk",
    ]
  }

  static func current(_ state: UpdateProgressState) -> Int {
    switch state {
    case .none, .pending, .initializing, .downloading, .extracting, .cancelling, .error: 0
    case .waitingForQuit: 1
    case .installing, .waitingForVendor: 2
    }
  }

  static func detail(step: Int, app: App) -> String? {
    switch step {
    case 1: "\(app.name) asks about unsaved work itself. Stop now and nothing changes"
    case 2:
      "Takes a few seconds. Stop isn't available in this step. The old copy is kept until the new one is verified"
    default: nil
    }
  }

  static func isStoppable(_ state: UpdateProgressState) -> Bool {
    switch state {
    case .installing, .waitingForVendor, .cancelling, .none, .error: false
    case .downloading(_, _, let cancellable), .extracting(_, let cancellable): cancellable
    case .pending, .initializing, .waitingForQuit: true
    }
  }

  static func summary(for app: App, state: UpdateProgressState) -> String {
    switch state {
    case .pending: "Waiting its turn"
    case .waitingForQuit: "Waiting for \(app.name) to quit"
    case .installing: "Replacing the app"
    case .waitingForVendor(let status): status
    case .cancelling: "Stopping"
    default: "Downloading and checking the signature"
    }
  }
}

/// A rounded note with a leading symbol, as used for explanations in lists and the detail.
struct CalloutView<Content: View>: View {
  var symbol = "info.circle"
  var tint: Color = .accentColor
  @ViewBuilder let content: Content

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
      Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
      content
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(Space.md)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Space.md))
    .accessibilityElement(children: .contain)
  }
}
