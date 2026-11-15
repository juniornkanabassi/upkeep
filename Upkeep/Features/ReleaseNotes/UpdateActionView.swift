//
//  UpdateActionView.swift
//  Latest
//
//  Created by ertyoii on 19.07.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-01.
//  Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import Combine
import SwiftUI

@MainActor
final class UpdateActionViewModel: ObservableObject {
  let app: App
  @Published private(set) var presentation: UpdateActionPresentation

  private var observationTask: Task<Void, Never>?
  private let workspace: any ApplicationWorkspace
  private let updating: any AppUpdating

  init(
    app: App,
    workspace: any ApplicationWorkspace = MacApplicationWorkspace.shared,
    updating: any AppUpdating = AppUpdateService.shared
  ) {
    self.app = app
    self.workspace = workspace
    self.updating = updating
    let feed = updating.stateChanges(for: app.identifier)
    _presentation = Published(
      initialValue: .make(
        for: app,
        progressState: feed.current
      ))
    observationTask = Task { [weak self] in
      for await state in feed.changes {
        guard !Task.isCancelled, let self else { break }
        let next = UpdateActionPresentation.make(for: app, progressState: state)
        if self.presentation != next { self.presentation = next }
      }
    }
  }

  deinit {
    observationTask?.cancel()
  }

  func performAction() {
    switch presentation {
    case .update, .failed:
      updating.update(app)
    case .open:
      workspace.openApplication(at: app.fileURL)
    case .progress(_, _, let cancellable):
      if cancellable { updating.cancel(app) }
    case .retryTermination:
      updating.retryTermination(app)
    case .waiting:
      break
    }
  }

  /// A failure recorded as `needsPermission` that a System Settings pane can fix.
  static func missingPermission(for app: App, updating: any AppUpdating) -> PermissionKind? {
    guard case .error(let error) = updating.state(for: app.identifier),
      case .needsPermission(let kind)? = (error as? UpdateOutcomeError)?.outcome
    else { return nil }
    return PermissionKind(outcomeKind: kind)
  }
}

struct UpdateActionView: View {
  @StateObject private var viewModel: UpdateActionViewModel

  init(
    app: App,
    workspace: any ApplicationWorkspace = MacApplicationWorkspace.shared,
    updating: any AppUpdating = AppUpdateService.shared
  ) {
    _viewModel = StateObject(
      wrappedValue: UpdateActionViewModel(app: app, workspace: workspace, updating: updating))
  }

  var body: some View {
    UpdateActionSurface(
      app: viewModel.app,
      presentation: viewModel.presentation,
      performAction: viewModel.performAction
    )
  }
}

/// Stateless rendering for the update action. Keeping queue observation and side effects
/// outside this view keeps action routing separate from presentation.
struct UpdateActionSurface: View {
  let app: App
  let presentation: UpdateActionPresentation
  let performAction: () -> Void

  var body: some View {
    UpdateActionControl(app: app, presentation: presentation, performAction: performAction)
      .frame(height: VisualMetrics.detailIconSize)
  }
}

@MainActor
enum UpdateActionVisualStyle {
  static let progressDiameter: CGFloat = 20
  static let progressLineWidth: CGFloat = 2.5
}

/// The button names exactly what happens: "Update" only when Upkeep installs it itself,
/// otherwise the place it opens ("Open App Store", "Relaunch Chrome").
private struct UpdateActionControl: View {
  let app: App
  let presentation: UpdateActionPresentation
  let performAction: () -> Void

  @ViewBuilder
  var body: some View {
    switch presentation {
    case .update:
      if app.capability.isAutomatic {
        Button(SidebarUpdateActionTitle.text(for: app), action: performAction)
          .buttonStyle(.borderedProminent)
          .modifier(HeaderButtonMetrics())
          .accessibilityLabel("Update \(app.name)")
          .accessibilityIdentifier("update.action")
      } else {
        Button(SidebarUpdateActionTitle.text(for: app), action: performAction)
          .buttonStyle(.bordered)
          .modifier(HeaderButtonMetrics())
          .help(app.updateExplanation)
          .accessibilityIdentifier("update.action")
      }
    case .open:
      if !app.isUpkeepItself {
        Button(
          NSLocalizedString("OpenAction", comment: "Action to open an app"), action: performAction
        )
        .buttonStyle(.bordered)
        .modifier(HeaderButtonMetrics())
        .accessibilityLabel("Open \(app.name)")
      }
    case .retryTermination:
      Button("Retry Quit", action: performAction)
        .buttonStyle(.bordered)
        .modifier(HeaderButtonMetrics())
        .help("Save your work, then retry quitting \(app.name) to finish the update.")
        .accessibilityLabel("Retry quitting \(app.name)")
        .accessibilityIdentifier("update.retry-termination")
    case .waiting(let status):
      UpdateActionIndeterminateIndicator()
        .help(status)
        .accessibilityLabel(status)
    case .progress(_, let status, let cancellable):
      StopCapsule(
        enabled: cancellable, identifier: "update.progress", status: status,
        controlSize: .regular, action: performAction)
    case .failed:
      Button("Retry", action: performAction)
        .buttonStyle(.bordered)
        .modifier(HeaderButtonMetrics())
        .help("Retry updating \(app.name).")
        .accessibilityLabel("Retry updating \(app.name)")
        .accessibilityIdentifier("update.retry")
    }
  }
}

private struct HeaderButtonMetrics: ViewModifier {
  func body(content: Content) -> some View {
    content.controlSize(.large).buttonBorderShape(.capsule).fixedSize()
  }
}

private struct UpdateActionIndeterminateIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(paused: reduceMotion)) { context in
      Circle()
        .trim(from: 0, to: 0.75)
        .stroke(
          Color(nsColor: .tertiaryLabelColor),
          style: StrokeStyle(
            lineWidth: UpdateActionVisualStyle.progressLineWidth,
            lineCap: .round
          )
        )
        .rotationEffect(
          .degrees(
            reduceMotion
              ? 90 : context.date.timeIntervalSinceReferenceDate * 360
          ))
    }
    .frame(
      width: UpdateActionVisualStyle.progressDiameter,
      height: UpdateActionVisualStyle.progressDiameter
    )
  }
}
