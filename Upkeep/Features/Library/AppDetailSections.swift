// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import Combine
import SwiftUI

/// The detail pane under the header: what is happening or why nothing can, the running job's
/// steps, release notes, the two switches, companions and the facts.
struct AppDetailSections: View {
  /// Above the release notes, or below them.
  enum Part { case top, bottom }

  let app: App
  let part: Part
  let presentation: UpdateActionPresentation
  let updating: any AppUpdating
  let lastResult: UpdateHistoryEntry?
  let companions: [App]
  @ObservedObject private var activity = AgentActivity.shared
  @Environment(\.appPreferences) private var preferences

  private var isRunning: Bool { presentation.isRunning }

  var body: some View {
    VStack(alignment: .leading, spacing: Space.xl) {
      if part == .bottom {
        optionsSection
        if !companions.isEmpty { companionsSection }
        detailsSection
      } else if isRunning {
        jobSection
      } else if let explanation {
        CalloutView(symbol: explanationSymbol, tint: explanationTint) {
          VStack(alignment: .leading, spacing: Space.sm) {
            Text(explanation).textSelection(.enabled)
            if case .failed = presentation,
              let permission = UpdateActionViewModel.missingPermission(for: app, updating: updating)
            {
              Button("Open \(permission.title) Settings") {
                MacApplicationWorkspace.shared.open(permission.settingsURL)
              }
              .controlSize(.small)
              .accessibilityLabel("Open System Settings for \(permission.title)")
            }
          }
        }
        .accessibilityIdentifier("detail.summary")
      }
      if part == .top, let lastResult {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
          Text("Last result").foregroundStyle(.secondary)
          Text(lastResult.displaySummary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          "Last result: " + lastResult.displaySummary.replacingOccurrences(of: "→", with: "to")
        )
        .accessibilityIdentifier("detail.lastResult")
      }
    }
  }

  // MARK: Explanation

  /// Nothing to explain for a plain installable update; everything else says why.
  private var explanation: String? {
    if case .failed(let reason) = presentation {
      return "The last attempt didn't finish. \(reason)"
    }
    if app.isIgnored {
      return "Updates are ignored, so \(app.name) stays out of Updates and Needs You."
    }
    if app.updateStatus == .ready || app.updateStatus == .current { return nil }
    if app.updateStatus == .elsewhere, app.capability == .handOff, !app.relaunchesToUpdate {
      let place = app.externalUpdaterName ?? app.name
      return "Upkeep can see this update but can't install it. "
        + (place == app.name
          ? "\(app.name) installs its own updates, so Upkeep opens \(app.name) and you finish there."
          : "Upkeep opens \(place) and you finish there.")
    }
    return app.updateExplanation
  }

  private var explanationSymbol: String {
    if case .failed = presentation { return "exclamationmark.triangle.fill" }
    return "info.circle"
  }

  private var explanationTint: Color {
    if case .failed = presentation { return Color(nsColor: .systemOrange) }
    return .accentColor
  }

  // MARK: Running job

  private var jobSection: some View {
    let state = updating.state(for: app.identifier)
    let job = activity.job(for: app.fileURL.path)
    let current = JobStep.current(state)
    return VStack(alignment: .leading, spacing: Space.md) {
      Text(
        job.map {
          "\(CallerName.display($0.starter.caller)) started this at \($0.starter.date.formatted(date: .omitted, time: .shortened))"
        } ?? "Updating now"
      )
      .font(.headline)
      VStack(alignment: .leading, spacing: Space.md) {
        ForEach(Array(JobStep.titles(for: app).enumerated()), id: \.offset) { index, title in
          HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Group {
              if index < current {
                Image(systemName: "checkmark.circle").foregroundStyle(Color(nsColor: .systemGreen))
              } else if index == current {
                ProgressView().controlSize(.mini)
              } else {
                Image(systemName: "circle").foregroundStyle(.secondary)
              }
            }
            .frame(width: Space.lg)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              Text(title).fontWeight(index == current ? .semibold : .regular)
              if index == current || index == 2, let detail = JobStep.detail(step: index, app: app)
              {
                Text(detail).font(.callout).foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityValue(
            index < current ? "Done" : index == current ? "In progress" : "To come")
        }
      }
      .padding(Space.lg)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(RoundedRectangle(cornerRadius: Space.md).strokeBorder(.quaternary))
      ForEach(job?.followers ?? [], id: \.caller) { follower in
        CalloutView(symbol: "sparkle") {
          Text(
            "\(CallerName.display(follower.caller)) asked for the same update at \(follower.date.formatted(date: .omitted, time: .shortened)) and will get this result."
          )
        }
      }
    }
    .accessibilityIdentifier("detail.job")
  }

  // MARK: Options

  private var optionsSection: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Text("Options").font(.headline)
      VStack(spacing: 0) {
        optionRow(
          .autoUpdate, title: "Update automatically",
          detail: AllAppsTable.unavailableReason(.autoUpdate, app: app).map {
            "Not available. \($0)"
          }
            ?? "Upkeep installs new versions while the app is closed. Off by default")
        Divider()
        optionRow(
          .ignore, title: "Ignore updates",
          detail:
            "Leaves it out of Updates, Needs You and the menu bar, and turns automatic updates off")
      }
      .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Space.md))
      .overlay(RoundedRectangle(cornerRadius: Space.md).strokeBorder(.quaternary))
    }
    .accessibilityIdentifier("detail.options")
  }

  private func optionRow(_ setting: AppPreferences.Setting, title: String, detail: String)
    -> some View
  {
    let unavailable = preferences == nil || AllAppsTable.unavailableReason(setting, app: app) != nil
    return HStack(alignment: .center, spacing: Space.md) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(detail).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let change = preferences?.change(setting, for: app), CallerName.isAgent(change.caller) {
          HStack(spacing: Space.xs) {
            Image(systemName: "sparkle").accessibilityHidden(true)
            Text(
              "Turned \(change.on ? "on" : "off") by \(CallerName.display(change.caller)) at \(change.date.formatted(date: .omitted, time: .shortened))."
            )
            Button("Undo") { preferences?.undo(setting, for: app) }.buttonStyle(.link)
          }
          .font(.callout).foregroundStyle(.secondary)
          .padding(.top, Space.xs)
          .accessibilityElement(children: .combine)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Toggle(
        isOn: Binding(
          get: { preferences?.value(setting, for: app) ?? false },
          set: { try? preferences?.set(setting, $0, for: app, caller: "gui") })
      ) { Text(title) }
      .toggleStyle(.switch)
      .labelsHidden()
      .disabled(unavailable)
    }
    .padding(.horizontal, Space.lg)
    .padding(.vertical, Space.md)
  }

  // MARK: Companions and details

  private var companionsSection: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Text(app.bundle.kind == .driver ? "Comes with this driver" : "Comes with this app").font(
        .headline)
      VStack(spacing: 0) {
        ForEach(Array(companions.enumerated()), id: \.offset) { index, companion in
          if index > 0 { Divider() }
          HStack(spacing: Space.md) {
            AppIconView(app: companion, size: 24)
            VStack(alignment: .leading, spacing: 2) {
              Text(companion.name)
              if let note = companion.bundle.kind == .driver ? companion.bundle.note : nil {
                Text(note).font(.callout).foregroundStyle(.secondary)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(companion.localizedVersionInformation?.rawCurrent ?? "")
              .foregroundStyle(.secondary).monospacedDigit()
          }
          .padding(.horizontal, Space.lg)
          .padding(.vertical, Space.md)
          .accessibilityElement(children: .combine)
        }
      }
      .overlay(RoundedRectangle(cornerRadius: Space.md).strokeBorder(.quaternary))
    }
  }

  private var detailsSection: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Text("Details").font(.headline)
      Grid(
        alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.lg, verticalSpacing: Space.sm
      ) {
        // Drivers say where each version came from (screen 09).
        let current = app.localizedVersionInformation?.rawCurrent ?? "Unknown"
        row(
          "Installed",
          app.bundle.kind == .driver ? "\(current), \(app.installedProvenance)" : current)
        if app.availabilityUnknown {
          row("Available", "Unknown, only \(app.externalUpdaterName ?? "the vendor") knows")
        } else if app.updateAvailable, let new = app.localizedVersionInformation?.rawNew {
          row("Available", app.availableProvenance.map { "\(new), \($0)" } ?? new)
        } else if case .needsNewerMacOS(let macOS) = app.updateStatus,
          let new = app.localizedVersionInformation?.rawNew
        {
          row("Available", "\(new), needs macOS \(macOS)")
        }
        if app.bundle.kind != .driver {
          row("Checked with", app.isUpkeepItself ? "Not yet available" : app.sourceName)
        }
        if app.updateAvailable {
          row(
            "Installed by",
            app.capability.isAutomatic ? "Upkeep" : app.externalUpdaterName ?? "\(app.name) itself")
        }
        row("Location", (app.fileURL.path as NSString).abbreviatingWithTildeInPath)
      }

    }
    .accessibilityIdentifier("detail.info")
  }

  private func row(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
      Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}

/// Pinned below the scrolling detail: removal on the left, Finder on the right.
struct DetailFooter: View {
  let app: App
  let uninstall: ((App) -> Void)?

  var body: some View {
    VStack(spacing: 0) {
      Divider()
      HStack {
        if let uninstall, app.bundle.kind == .app, app.bundle.parent == nil, !app.isUpkeepItself {
          Button("Uninstall \(app.name)…", role: .destructive) { uninstall(app) }
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: .systemRed))
            .accessibilityIdentifier("detail.uninstall")
        }
        Spacer()
        Button("Show in Finder") { MacApplicationWorkspace.shared.revealInFinder([app.fileURL]) }
          .buttonStyle(.plain)
          .foregroundStyle(Color.accentColor)
      }
      .padding(.horizontal, VisualMetrics.detailHeaderHorizontalPadding)
      .padding(.vertical, Space.md)
    }
    .background(Color(nsColor: .textBackgroundColor))
  }
}

extension UpdateActionPresentation {
  var isRunning: Bool {
    switch self {
    case .waiting, .progress, .retryTermination: true
    case .update, .open, .failed: false
    }
  }
}

/// What's new. The web view stays mounted (zero height when there is no text), so moving
/// between apps with the same notes keeps the page, and new notes reload in place.
struct ReleaseNotesSection: View {
  let app: App
  let presentation: UpdateActionPresentation
  let contentState: ReleaseNotesDetailContentState
  let retry: (() -> Void)?

  private var text: ReleaseNotesContent? {
    if case .text(let text) = contentState { return text }
    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      if text != nil || app.updateAvailable || app.availabilityUnknown {
        Text("What's new").font(.headline)
      }
      ReleaseNotesWebView(text: text)
        .frame(height: text == nil ? 0 : 260)
        .clipShape(RoundedRectangle(cornerRadius: Space.sm))
        .opacity(text == nil ? 0 : 1)
        .allowsHitTesting(text != nil)
        .accessibilityHidden(text == nil)
      if text == nil, app.updateAvailable || app.availabilityUnknown {
        switch contentState {
        case .loading:
          ProgressView().controlSize(.small).accessibilityLabel("Loading Release Notes")
        case .message, .text:
          HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            if presentation.isRunning {
              Text("Notes load again once the update finishes.").foregroundStyle(.secondary)
            } else if app.availabilityUnknown || app.capability == .handOff {
              Text("No release notes came with this check.").foregroundStyle(.secondary)
            } else {
              Text("Couldn't load release notes just now.").foregroundStyle(.secondary)
              if let retry { Button("Retry", action: retry).buttonStyle(.link) }
            }
          }
        }
      }
    }
    .accessibilityIdentifier("detail.notes")
  }
}

extension App {
  /// Where a driver's installed version was read.
  /// Where a driver's installed version was read: the app discovery took it from, or the
  /// driver bundle itself.
  var installedProvenance: String {
    guard let source = bundle.versionSource else { return "from the driver on this Mac" }
    return "from \(source.deletingPathExtension().lastPathComponent) on this Mac"
  }

  /// Where a driver's available version came from, or nil when there is no source.
  var availableProvenance: String? {
    guard bundle.kind == .driver else { return nil }
    if let tool = bundle.companionToolURL {
      // …/SoundSource.app/Contents/Resources/arkinstaller
      let app = tool.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
      return "from the ARK installer inside \(app.deletingPathExtension().lastPathComponent)"
    }
    if bundle.vendor == "Blackmagic Design" {
      let date =
        upkeepUpdateDate.map { ", \($0.formatted(.dateTime.day().month(.abbreviated).year()))" }
        ?? ""
      return "from Blackmagic's online download list" + date
    }
    if let host = bundle.hostURL {
      return "from \(host.deletingPathExtension().lastPathComponent)'s own update check"
    }
    return nil
  }
}
