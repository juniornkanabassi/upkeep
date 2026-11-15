// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

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

  func confirm() async {
    guard let service, !ticked.isEmpty else { return }
    phase = .working
    note = nil
    do {
      // A fresh token each time: tokens are single use, and the plan is checked again.
      let plan = try preview(service)
      let keep = Set(
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
        // The password request was cancelled or refused: nothing moved.
        note =
          needsPassword
          ? "Nothing was removed, because the password request was cancelled. Untick Background helper to remove the rest without your password."
          : (outcomes.first?.message ?? "Nothing was removed.")
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
    let helperNeedsPassword = items.contains { ($0.kind == .launchAgent || $0.kind == .system) && $0.needsAdmin }
    return [
      make("app", "The app", "Moves to the Bin") { $0.kind == .app },
      make("cache", "Caches", "Temporary files and website data the app can make again. Moves to the Bin") {
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
      make("personal", "Your settings and history", "Documents, history and data the app saved. Kept unless you tick it") {
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
            : "Nothing moves until you click Move to Bin. If \(model.app.name) is open, quit it first.")
        ScrollView {
          VStack(alignment: .leading, spacing: Space.md) {
            if let note = model.note {
              CalloutView(symbol: "exclamationmark.triangle.fill", tint: Color(nsColor: .systemOrange)) {
                Text(note)
              }
            }
            if model.phase == .loading { ProgressView().frame(maxWidth: .infinity) }
            ForEach(model.groups) { group in groupCard(group) }
            Label("The app and your files can be put back from the Bin.", systemImage: "info.circle")
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

  private func header(subtitle: String) -> some View {
    HStack(alignment: .top, spacing: Space.lg) {
      AppIconView(app: model.app, size: 48)
      VStack(alignment: .leading, spacing: Space.xs) {
        Text("Uninstall \(model.app.name)?").font(.title3.weight(.semibold))
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
            set: { if $0 { model.expanded.insert(group.id) } else { model.expanded.remove(group.id) } })
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
    let moved = outcomes.filter(\.removed)
    return VStack(alignment: .leading, spacing: 0) {
      header(
        subtitle: failed.isEmpty
          ? "\(LibraryContent.count(moved.count, "item")) moved to the Bin. They can be put back from there."
          : "\(LibraryContent.count(moved.count, "item")) moved to the Bin. \(LibraryContent.count(failed.count, "item")) stayed where \(failed.count == 1 ? "it was" : "they were").")
      ScrollView {
        VStack(alignment: .leading, spacing: Space.sm) {
          ForEach(outcomes) { outcome in
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
              Image(systemName: outcome.removed ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(outcome.removed ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
              VStack(alignment: .leading, spacing: 2) {
                Text((outcome.path as NSString).abbreviatingWithTildeInPath)
                  .font(.callout.monospaced()).fixedSize(horizontal: false, vertical: true)
                if let message = outcome.message, !outcome.removed {
                  Text(message).font(.callout).foregroundStyle(.secondary)
                }
              }
            }
            .accessibilityElement(children: .combine)
          }
        }
        .padding(.horizontal, Space.xxl)
      }
      footer {
        Spacer()
        Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
      }
    }
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
