// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import Combine
import SwiftUI

/// The window's uninstall flow over the existing UninstallService: a fresh preview, groups the
/// person can untick (personal data unticked), one password prompt before anything moves, and
/// a per-item result.
@MainActor
final class UninstallSheetModel: ObservableObject {
  struct Group: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let items: [UninstallItem]
    let needsAdmin: Bool
    let personal: Bool
    var size: Int64 { items.reduce(0) { $0 + $1.size } }
  }

  struct Outcome: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let removed: Bool
    let message: String?
  }

  enum Phase: Equatable {
    case loading, ready, working
    case result([Outcome])
    case failed(String)
  }

  let app: App
  private let service: UninstallService?
  @Published private(set) var phase = Phase.loading
  @Published private(set) var groups = [Group]()
  @Published var ticked = Set<String>()
  @Published var expanded = Set<String>()
  /// Why the last attempt changed nothing, shown above the groups.
  @Published private(set) var note: String?

  init(app: App, service: UninstallService?) {
    self.app = app
    self.service = service
  }

  /// For snapshots: a prepared plan without touching the disk.
  init(app: App, groups: [Group], phase: Phase = .ready, note: String? = nil) {
    self.app = app
    service = nil
    self.groups = groups
    self.phase = phase
    self.note = note
    ticked = Set(groups.filter { !$0.personal }.map(\.id))
    if note != nil { expanded = Set(groups.filter(\.needsAdmin).map(\.id)) }
  }

  var selectedSize: Int64 { groups.filter { ticked.contains($0.id) }.reduce(0) { $0 + $1.size } }
  var keptSize: Int64 { groups.filter { !ticked.contains($0.id) }.reduce(0) { $0 + $1.size } }
  var needsPassword: Bool { groups.contains { $0.needsAdmin && ticked.contains($0.id) } }

  func load() {
    guard let service else { return }
    do {
      let plan = try preview(service)
      groups = Self.groups(plan.items)
      ticked = Set(groups.filter { !$0.personal }.map(\.id))
      phase = .ready
    } catch {
      phase = .failed(Self.message(error))
    }
  }

  /// `only` narrows the run to these paths (Try Again for items that stayed).
  func confirm(only: Set<String>? = nil) async {
    guard let service, !ticked.isEmpty else { return }
    phase = .working
    note = nil
    do {
      // A fresh token each time: tokens are single use, and the plan is checked again.
      let plan = try preview(service)
      let keep =
        only.map { only in Set(plan.items.map(\.path).filter { !only.contains($0) }) }
        ?? Set(
          Self.groups(plan.items).filter { !ticked.contains($0.id) }.flatMap(\.items).map(\.path))
      let token = plan.token
      let data = try await service.confirm(
        token: token, app: nil, withData: nil, caller: "gui", excluding: keep)
      let outcomes = (data["results"]?.arrayValue ?? []).compactMap(\.objectValue).compactMap {
        result -> Outcome? in
        guard let path = result["path"]?.stringValue, result["status"]?.stringValue != "skipped"
        else { return nil }
        return Outcome(
          path: path, removed: result["status"]?.stringValue == "removed",
          message: result["message"]?.stringValue)
      }
      if !outcomes.isEmpty, !outcomes.contains(where: \.removed) {
        note = Self.note(for: data, outcomes: outcomes, needsPassword: needsPassword)
        expanded.formUnion(groups.filter(\.needsAdmin).map(\.id))
        phase = .ready
        return
      }
      phase = .result(outcomes)
    } catch let error as ControlError where error.code == "busy" {
      note = "\(app.name) is open or updating, so nothing was removed. Quit it, then try again."
      phase = .ready
    } catch {
      note = Self.message(error)
      phase = .ready
    }
  }

  private struct Plan {
    let items: [UninstallItem]
    let token: String
  }

  private func preview(_ service: UninstallService) throws -> Plan {
    let data = try service.preview(app: app.fileURL, withData: true, caller: "gui")
    let encoded = try JSONEncoder().encode(JSONValue.object(data))
    let plan = try JSONDecoder().decode(UninstallPlan.self, from: encoded)
    guard let token = data["token"]?.stringValue else {
      throw ControlError("uninstall_failed", "The preview had no token.")
    }
    return Plan(items: plan.items, token: token)
  }

  /// Why nothing moved: a cancelled password prompt, or the reason the service returned.
  static func note(for data: [String: JSONValue], outcomes: [Outcome], needsPassword: Bool)
    -> String
  {
    if data["authorizationCancelled"] == .bool(true), needsPassword {
      return
        "Nothing was removed, because the password request was cancelled. Untick Background helper to remove the rest without your password."
    }
    return data["message"]?.stringValue ?? outcomes.first?.message ?? "Nothing was removed."
  }

  /// Retrying needs a fresh preview, which needs the app; once it is in the Bin, leftovers
  /// are cleared by hand from Finder.
  var canRetry: Bool { FileManager.default.fileExists(atPath: app.fileURL.path) }

  private static func message(_ error: Error) -> String {
    (error as? ControlError)?.message ?? error.localizedDescription
  }

  /// Plan items grouped as the sheet shows them, in a fixed order.
  static func groups(_ items: [UninstallItem]) -> [Group] {
    func make(_ id: String, _ title: String, _ detail: String, _ test: (UninstallItem) -> Bool)
      -> Group?
    {
      let matching = items.filter(test)
      guard !matching.isEmpty else { return nil }
      return Group(
        id: id, title: title, detail: detail, items: matching,
        needsAdmin: matching.contains(where: \.needsAdmin),
        personal: matching.contains(where: \.personalData))
    }
    let helperNeedsPassword = items.contains {
      ($0.kind == .launchAgent || $0.kind == .system) && $0.needsAdmin
    }
    return [
      make("app", "The app", "Moves to the Bin") { $0.kind == .app },
      make(
        "cache", "Caches",
        "Temporary files the app can make again. Moves to the Bin"
      ) {
        $0.kind == .cache && !$0.personalData
      },
      make(
        "helper", "Background helper",
        helperNeedsPassword
          ? "Stopped and removed for the whole Mac. Needs your password. Its files move to the Bin, but putting them back doesn't restart it"
          : "Stopped and removed. Its files move to the Bin, but putting them back doesn't restart it"
      ) { ($0.kind == .launchAgent || $0.kind == .system) && !$0.personalData },
      make("prefs", "Preferences", "The app's settings files. Moves to the Bin") {
        $0.kind == .prefs && !$0.personalData
      },
      make(
        "personal", "Your settings and history",
        "Sign-ins, website data, documents and history the app saved. Kept unless you tick it"
      ) {
        $0.personalData
      },
    ].compactMap { $0 }
  }
}

struct UninstallSheet: View {
  @ObservedObject var model: UninstallSheetModel
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch model.phase {
      case .result(let outcomes):
        result(outcomes)
      case .failed(let message):
        header(subtitle: message)
        footer {
          Button("Close", action: dismiss).keyboardShortcut(.defaultAction)
        }
      case .loading, .ready, .working:
        header(
          subtitle: model.needsPassword
            ? "Upkeep asks for your Mac password first. If you cancel, nothing changes. If \(model.app.name) is open, quit it first."
            : "Nothing moves until you click Move to Bin. If \(model.app.name) is open, quit it first."
        )
        ScrollView {
          VStack(alignment: .leading, spacing: Space.md) {
            if let note = model.note {
              CalloutView(
                symbol: "exclamationmark.triangle.fill", tint: Color(nsColor: .systemOrange)
              ) {
                Text(note)
              }
            }
            if model.phase == .loading { ProgressView().frame(maxWidth: .infinity) }
            ForEach(model.groups) { group in groupCard(group) }
            Label(
              "The app and your files can be put back from the Bin.", systemImage: "info.circle"
            )
            .foregroundStyle(.secondary)
          }
          .padding(.horizontal, Space.xxl)
          .padding(.bottom, Space.md)
        }
        footer {
          Text(
            "\(Self.size(model.selectedSize)) to the Bin."
              + (model.keptSize > 0 ? " \(Self.size(model.keptSize)) stays." : "")
          )
          .foregroundStyle(.secondary)
          Spacer()
          Button("Move to Bin", role: .destructive) { Task { await model.confirm() } }
            .foregroundStyle(Color(nsColor: .systemRed))
            .disabled(model.ticked.isEmpty || model.phase != .ready)
            .accessibilityIdentifier("uninstall.confirm")
          Button("Cancel", action: dismiss)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("uninstall.cancel")
        }
      }
    }
    .frame(minWidth: 520, idealWidth: 620, maxWidth: 680, minHeight: 360, idealHeight: 560)
    .task { if model.phase == .loading { model.load() } }
  }

  private func header(title: String? = nil, subtitle: String) -> some View {
    HStack(alignment: .top, spacing: Space.lg) {
      AppIconView(app: model.app, size: 48)
      VStack(alignment: .leading, spacing: Space.xs) {
        Text(title ?? "Uninstall \(model.app.name)?").font(.title3.weight(.semibold))
        Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(Space.xxl)
  }

  private func groupCard(_ group: UninstallSheetModel.Group) -> some View {
    HStack(alignment: .center, spacing: Space.md) {
      Toggle(
        isOn: Binding(
          get: { model.ticked.contains(group.id) },
          set: { if $0 { model.ticked.insert(group.id) } else { model.ticked.remove(group.id) } })
      ) { Text(group.title) }
      .toggleStyle(.checkbox)
      .labelsHidden()
      .frame(width: Space.xxl, height: Space.xxl)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: Space.xs) {
          Text(group.title).font(.headline)
          if group.needsAdmin {
            Image(systemName: "lock").accessibilityLabel("Needs your password")
          }
        }
        Text(group.detail).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        DisclosureGroup(
          isExpanded: Binding(
            get: { model.expanded.contains(group.id) },
            set: {
              if $0 { model.expanded.insert(group.id) } else { model.expanded.remove(group.id) }
            })
        ) {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(group.items, id: \.path) { item in
              Text((item.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        } label: {
          Text(group.items.count == 1 ? "Show location" : "Show \(group.items.count) locations")
            .font(.callout).foregroundStyle(Color.accentColor)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(Self.size(group.size))
        .fontWeight(model.ticked.contains(group.id) ? .semibold : .regular)
        .foregroundStyle(model.ticked.contains(group.id) ? .primary : .secondary)
        .monospacedDigit()
    }
    .padding(Space.lg)
    .overlay(RoundedRectangle(cornerRadius: Space.md).strokeBorder(.quaternary))
    .accessibilityElement(children: .contain)
  }

  private func result(_ outcomes: [UninstallSheetModel.Outcome]) -> some View {
    let failed = outcomes.filter { !$0.removed }
    let byPath = Dictionary(outcomes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    return VStack(alignment: .leading, spacing: 0) {
      header(
        title: failed.isEmpty
          ? "\(model.app.name) is uninstalled"
          : "\(model.app.name) is uninstalled, with \(LibraryContent.count(failed.count, "file")) left",
        subtitle: failed.isEmpty
          ? "Everything you chose is in the Bin, and can be put back from there."
          : (failed.first?.message ?? "Some files stayed where they were."))
      ScrollView {
        VStack(spacing: 0) {
          ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
            if index > 0 { Divider() }
            resultRow(group, outcomes: group.items.compactMap { byPath[$0.path] })
          }
        }
        .overlay(RoundedRectangle(cornerRadius: Space.md).strokeBorder(.quaternary))
        .padding(.horizontal, Space.xxl)
        Text("The exact paths are logged in Upkeep's uninstall log.")
          .font(.callout).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Space.xxl).padding(.top, Space.sm)
      }
      footer {
        Button("Show in Bin") {
          NSWorkspace.shared.open(
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
        }
        .buttonStyle(.link)
        Spacer()
        if !failed.isEmpty, model.canRetry {
          Button(failed.count == 1 ? "Try Locked File Again" : "Try \(failed.count) Files Again") {
            Task { await model.confirm(only: Set(failed.map(\.path))) }
          }
        }
        Button("Done", action: dismiss).keyboardShortcut(.defaultAction).buttonStyle(
          .borderedProminent)
      }
    }
  }

  /// One line per group: moved, moved except some, or kept as chosen.
  private func resultRow(
    _ group: UninstallSheetModel.Group, outcomes: [UninstallSheetModel.Outcome]
  )
    -> some View
  {
    let stayed = outcomes.filter { !$0.removed }.count
    let kept = outcomes.isEmpty
    let (symbol, tint, detail): (String, Color, String) =
      kept
      ? ("circle", .secondary, "Kept, as you chose")
      : stayed == 0
        ? (
          "checkmark.circle", Color(nsColor: .systemGreen),
          group.id == "helper"
            ? "Stopped and removed. Its files are in the Bin" : "Moved to the Bin"
        )
        : (
          "exclamationmark.circle", Color(nsColor: .systemOrange),
          stayed == outcomes.count
            ? "Stayed where it was"
            : "Moved to the Bin, except \(LibraryContent.count(stayed, "file"))"
        )
    return HStack(spacing: Space.md) {
      Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(group.title)
        Text(detail).font(.callout).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(Self.size(group.size)).foregroundStyle(.secondary).monospacedDigit()
    }
    .padding(.horizontal, Space.lg)
    .padding(.vertical, Space.sm)
    .accessibilityElement(children: .combine)
  }

  private func footer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: Space.md) { content() }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.lg)
    }
  }

  static func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}
