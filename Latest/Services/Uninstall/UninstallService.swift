// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.
import AppKit
import Foundation

@MainActor
final class UninstallService {
  struct Ticket {
    let plan: UninstallPlan
    let caller: String
    let expires: Date
  }
  let planner: UninstallPlanner
  let history: UpdateHistoryStore?
  let logURL: URL
  var now: () -> Date = Date.init
  var isUpdating: (URL) -> Bool
  var trash: (URL) throws -> Void
  var removeAdmin: ([UninstallItem]) async throws -> Void
  var beginExclusive: (URL) throws -> (() -> Void) = { _ in {} }
  var bootout: (URL, Bool) async throws -> Void
  private var tickets: [String: Ticket] = [:]

  init(planner: UninstallPlanner, history: UpdateHistoryStore?, logURL: URL,
       isUpdating: @escaping (URL) -> Bool = { _ in false },
       trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
       removeAdmin: @escaping ([UninstallItem]) async throws -> Void = { try await UninstallService.adminTrash($0) },
       bootout: @escaping (URL, Bool) async throws -> Void = { url, system in
         if !system { try await UninstallService.unload(url) }
       }) {
    self.planner = planner; self.history = history; self.logURL = logURL
    self.isUpdating = isUpdating; self.trash = trash; self.removeAdmin = removeAdmin; self.bootout = bootout
  }

  static func live(updating: any AppUpdating, history: UpdateHistoryStore?) -> UninstallService {
    let originalHome = FileManager.default.homeDirectoryForCurrentUser
    let resolvedHome = realpath(originalHome.path, nil)
    let home = resolvedHome.map { URL(fileURLWithPath: String(cString: $0)) } ?? originalHome
    if let resolvedHome { free(resolvedHome) }
    let service = UninstallService(planner: UninstallPlanner(home: home, systemLibrary: URL(fileURLWithPath: "/Library"),
      copies: { try AppStoreInstallGate.live.walk($0) },
      isRunning: { !AppLifecycle.live.runningApps($0).isEmpty }),
      history: history, logURL: ControlPaths.dataRoot.appendingPathComponent("uninstall.log"),
      isUpdating: { updating.jobID(for: $0) != nil })
    service.beginExclusive = { url in
      guard updating.reserveForUninstall(url) else { throw ControlError("busy", "An update or uninstall already owns this app.") }
      return { updating.releaseAfterUninstall(url) }
    }
    return service
  }

  func preview(app: URL, withData: Bool, caller: String) throws -> [String: JSONValue] {
    guard !isUpdating(app) else { throw ControlError("busy", "An update of this app is still active.") }
    let plan = try planner.plan(app: app, withData: withData)
    tickets = tickets.filter { $0.value.expires > now() }
    guard tickets.count < 128 else { throw ControlError("busy", "Too many outstanding uninstall previews.") }
    let token = UUID().uuidString
    tickets[token] = Ticket(plan: plan, caller: caller, expires: now().addingTimeInterval(600))
    let data = try JSONEncoder().encode(plan)
    var object = try JSONDecoder().decode(JSONValue.self, from: data).objectValue ?? [:]
    object["token"] = .string(token)
    object["expiresIn"] = JSONValue(600)
    return object
  }

  func confirm(token: String, app: URL?, withData: Bool?, caller: String) async throws -> [String: JSONValue] {
    guard let ticket = tickets[token], ticket.caller == caller, ticket.expires > now() else {
      throw ControlError("invalid_token", "The preview token is missing, expired, consumed or belongs to another caller.")
    }
    guard app == nil || app?.path == ticket.plan.appPath,
      withData == nil || withData == ticket.plan.withData else {
      throw ControlError("plan_mismatch", "Confirmation does not match the preview target and data selection.")
    }
    tickets[token] = nil // One attempt only, including failed revalidation.
    let release = try beginExclusive(URL(fileURLWithPath: ticket.plan.appPath))
    defer { release() }
    let target = URL(fileURLWithPath: ticket.plan.appPath)
    guard !isUpdating(target), !planner.isRunning(target) else { throw ControlError("busy", "The app is running or updating; nothing was removed.") }
    guard try UninstallPlanner.identifier(at: target) == ticket.plan.bundleIdentifier else { throw ControlError("path_changed", "The app identity changed.") }
    let current = try planner.plan(app: target, withData: ticket.plan.withData)
    guard current.siblingCopies == ticket.plan.siblingCopies else { throw ControlError("path_changed", "Installed copies changed; preview again.") }
    // Validate the entire selection before the first move, then again immediately per move.
    let selected = ticket.plan.items.filter(\.selected)
    for item in selected { try planner.validate(item) }
    let before = BundleCollector.collectBundle(at: target)
    var results: [[String: JSONValue]] = ticket.plan.items.filter { !$0.selected }.map {
      result($0, "skipped", "Personal data was not selected.")
    }
    let admin = selected.filter(\.needsAdmin)
    // Admin moves come first; cancelling the single prompt cannot remove the app first.
    if !admin.isEmpty {
      do {
        for item in admin { try planner.validate(item) }
        try await removeAdmin(admin)
        for item in admin {
          let gone = !FileManager.default.fileExists(atPath: item.path)
          results.append(result(item, gone ? "removed" : "failed", gone ? nil : "Still present after the administrator operation."))
        }
      } catch {
        for item in admin { results.append(result(item, "failed", error.localizedDescription)) }
        for item in selected.sorted(by: { $0.kind != .app && $1.kind == .app }) where !item.needsAdmin { results.append(result(item, "skipped", "Administrator operation failed or was cancelled.")) }
        try appendLog(results, run: token)
        return ["results": .array(results.map(JSONValue.object))]
      }
    }
    for item in selected.sorted(by: { $0.kind != .app && $1.kind == .app }) where !item.needsAdmin {
      do {
        guard !planner.isRunning(target), !isUpdating(target) else { throw ControlError("busy", "The app started running or updating.") }
        try planner.validate(item)
        let url = URL(fileURLWithPath: item.path)
        if item.kind == .launchAgent { try await bootout(url, false); try planner.validate(item) }
        try trash(url)
        guard !FileManager.default.fileExists(atPath: item.path) else { throw ControlError("trash_failed", "The item is still present.") }
        results.append(result(item, "removed", nil))
      } catch { results.append(result(item, "failed", error.localizedDescription)) }
    }
    try appendLog(results, run: token)
    if let before, results.contains(where: { $0["path"] == .string(target.path) && $0["status"] == "removed" }) {
      history?.record(UpdateHistoryEntry(before: before, after: nil, outcome: .uninstalled))
    }
    return ["results": .array(results.map(JSONValue.object))]
  }

  private func result(_ item: UninstallItem, _ status: String, _ message: String?) -> [String: JSONValue] {
    var value: [String: JSONValue] = ["path": .string(item.path), "status": .string(status)]
    if let message { value["message"] = .string(message) }
    return value
  }

  private func appendLog(_ results: [[String: JSONValue]], run: String) throws {
    let stamp = ISO8601DateFormatter().string(from: now())
    let text = results.map { item in
      let status = item["status"]?.stringValue == "removed" ? "TRASHED" : (item["status"]?.stringValue ?? "failed").uppercased()
      let path = (item["path"]?.stringValue ?? "").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
      return "[\(stamp)] [uninstall run=\(run)] \(status) \(path)\n"
    }.joined()
    try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
    let file = try FileHandle(forWritingTo: logURL)
    defer { try? file.close() }
    try file.seekToEnd(); try file.write(contentsOf: Data(text.utf8)); try file.synchronize()
  }

  private static func unload(_ url: URL) async throws {
    // Missing services are harmless; other launchctl errors keep their files in place.
    let output: String
    do { output = try await InstallerCommand.run("/bin/launchctl", ["bootout", "gui/\(getuid())", url.path]) }
    catch {
      let message = error.localizedDescription
      if message.contains("No such process") || message.contains("Could not find specified service") { return }
      throw error
    }
    _ = output
  }

  /// One system prompt. No passwords, permanent deletion, shell expansion of paths or custom helper trust.
  private static func adminTrash(_ items: [UninstallItem]) async throws {
    let homePath = realpath(FileManager.default.homeDirectoryForCurrentUser.path, nil)
    guard let homePath else { throw ControlError("unsafe_trash", "Cannot resolve the home folder.") }
    defer { free(homePath) }
    let trash = URL(fileURLWithPath: String(cString: homePath)).appendingPathComponent(".Trash")
    if !FileManager.default.fileExists(atPath: trash.path) {
      try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
    }
    guard UninstallPlanner.safePath(trash, under: trash.deletingLastPathComponent()) else { throw ControlError("unsafe_trash", "The Bin path is unsafe.") }
    func q(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    var commands = ["set -eu"]
    for item in items {
      // Recheck identity and each parent in the privileged process as well.
      let expected = "\(item.device):\(item.inode):\(item.modified):\(item.changed)"
      commands.append("[ \"$(/usr/bin/stat -f '%d:%i:%m:%c' \(q(item.path)))\" = \(q(expected)) ]")
      var path = ""
      for part in item.path.split(separator: "/") { path += "/" + part; commands.append("[ ! -L \(q(path)) ]") }
    }
    commands.append("[ ! -L \(q(trash.path)) ]")
    for item in items.sorted(by: { $0.kind != .app && $1.kind == .app }) {
      if item.kind == .launchAgent {
        let domain = item.path.contains("/LaunchDaemons/") ? "system" : "gui/\(getuid())"
        commands.append("/bin/launchctl bootout \(q(domain)) \(q(item.path)) 2>/dev/null || [ $? = 3 ]")
      }
      let destination = trash.appendingPathComponent(UUID().uuidString + "-" + URL(fileURLWithPath: item.path).lastPathComponent).path
      let expected = "\(item.device):\(item.inode):\(item.modified):\(item.changed)"
      commands.append("[ \"$(/usr/bin/stat -f '%d:%i:%m:%c' \(q(item.path)))\" = \(q(expected)) ]")
      if let hash = item.identityHash {
        commands.append("[ \"$(/usr/bin/shasum -a 256 \(q(item.path + "/Contents/Info.plist")) | /usr/bin/cut -d ' ' -f 1)\" = \(q(hash)) ]")
      }
      commands.append("/bin/mv -n \(q(item.path)) \(q(destination))")
    }
    let shell = commands.joined(separator: "\n")
    let literal = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
    _ = try await InstallerCommand.run("/usr/bin/osascript", ["-e", "do shell script \"\(literal)\" with administrator privileges"], cancellable: false)
  }
}
