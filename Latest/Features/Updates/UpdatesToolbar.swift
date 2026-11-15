//
//  UpdatesToolbar.swift
//  Latest
//
//  Structural split from the original implementation.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-29.
//  Licensed under GPL-3.0; see LICENSE.md.

import SwiftUI

/// Observe scan progress at the toolbar boundary, without invalidating the app list.
struct UpdatesToolbar: ToolbarContent {
  @ObservedObject var service: UpdateCheckingService
  /// The same count the menu bar's Update All uses: exactly the apps Update All would start.
  @ObservedObject var summary: MenuBarViewModel
  /// Update All is the page's primary action only on Updates.
  var prominent = true
  let reload: () -> Void
  let updateAll: () -> Void

  var body: some ToolbarContent {
    ToolbarSpacer(.flexible, placement: .primaryAction)
    ToolbarItem(placement: .primaryAction) {
      ToolbarUpdateProgressView(
        presentation: ToolbarProgressPresentation(
          isRunning: service.isRunning, fraction: service.progressFraction))
    }
    // Passive scan status stays outside the refresh action's glass group.
    .sharedBackgroundVisibility(.hidden)
    ToolbarItem(placement: .primaryAction) {
      RefreshToolbarButton(isEnabled: !service.isRunning, action: reload)
    }
    ToolbarItem(placement: .primaryAction) {
      UpdateAllToolbarButton(
        count: summary.updateAllCount, running: summary.running.count, prominent: prominent,
        action: updateAll)
    }
  }
}

/// The window's one primary action. It names its count so it is clear what will happen;
/// apps under Needs You are never touched by it.
struct UpdateAllToolbarButton: View {
  let count: Int
  var running = 0
  var prominent = true
  let action: () -> Void

  /// Never "(0)": with nothing to start it says what is running, or plain Update All.
  static func title(count: Int, running: Int) -> String {
    if count > 0 { return "Update All (\(count))" }
    if running > 0 { return running == 1 ? "1 update running" : "\(running) updates running" }
    return "Update All"
  }

  var body: some View {
    Button(action: action) {
      Text(Self.title(count: count, running: running))
        .padding(.horizontal, Space.xs)
    }
    .modifier(ProminentWhen(prominent: prominent && count > 0))
    .disabled(count == 0)
    .help(
      count == 0
        ? (running > 0 ? "Upkeep is installing. Nothing else is waiting that it can install." : "Nothing Upkeep can install by itself right now.")
        : "Installs the \(count == 1 ? "update" : "\(count) updates") under Updates. Items in Needs You are left alone."
    )
    .accessibilityIdentifier("toolbar.updateAll")
    .accessibilityLabel(count == 1 ? "Update 1 app" : "Update all \(count) apps")
  }
}

struct RefreshToolbarButton: View {
  let isEnabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("Check for Updates", systemImage: "arrow.clockwise")
    }
    .labelStyle(.iconOnly)
    .help(
      NSLocalizedString(
        "CheckForUpdatesToolbarItemToolTip",
        comment: "Tool tip of a toolbar button that checks for updates"
      )
    )
    .disabled(!isEnabled)
    .accessibilityIdentifier("toolbar.refresh")
    .accessibilityLabel("Check for Updates")
  }
}

struct ToolbarUpdateProgressView: View {
  let presentation: ToolbarProgressPresentation

  @ViewBuilder
  var body: some View {
    switch presentation {
    case .hidden:
      EmptyView()
    case .determinate(let fraction):
      ProgressView(value: fraction)
        .progressViewStyle(.linear)
        .toolbarProgressFrame()
        .accessibilityLabel("Checking for updates")
    }
  }
}

extension View {
  fileprivate func toolbarProgressFrame() -> some View {
    frame(width: ToolbarProgressMetrics.width)
      .padding(.leading, ToolbarProgressMetrics.leadingPadding)
      .padding(.trailing, ToolbarProgressMetrics.trailingPadding)
  }
}

private struct ProminentWhen: ViewModifier {
  let prominent: Bool
  func body(content: Content) -> some View {
    if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
  }
}
