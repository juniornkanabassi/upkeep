// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.
// Exact-path discovery adapted from tw93/Mole 1.72.0, lib/core/app_protection.sh
// (GPL-3.0-or-later). Group/UUID containers use stricter metadata ownership checks.
import CryptoKit
import Darwin
import Foundation

struct UninstallItem: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable { case app, data, cache, prefs, launchAgent, system }
  let path: String
  let root: String
  let size: Int64
  let kind: Kind
  let personalData: Bool
  let needsAdmin: Bool
  let inode: UInt64
  let device: UInt64
  let modified: Int64
  let changed: Int64
  let identityHash: String?
  var selected: Bool
}

struct UninstallPlan: Codable, Sendable {
  let appPath: String
  let bundleIdentifier: String
  let items: [UninstallItem]
  let siblingCopies: Bool
  let withData: Bool
}

struct UninstallPlanner: Sendable {
  let home: URL
  let systemLibrary: URL
  var uid: uid_t = getuid()
  let copies: @Sendable (String) throws -> Set<String>
  let isRunning: @MainActor @Sendable (URL) -> Bool

  static func identifier(at app: URL) throws -> String {
    let info = try dictionary(app.appendingPathComponent("Contents/Info.plist"))
    guard let id = info["CFBundleIdentifier"] as? String,
      id.range(of: #"^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+$"#, options: .regularExpression) != nil
    else { throw ControlError("unsafe_app", "The app has no valid bundle identifier.") }
    return id
  }

  static func dictionary(_ file: URL) throws -> [String: Any] {
    guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any] else {
      throw ControlError("unsafe_metadata", "Invalid property list at \(file.path).")
    }
    return value
  }

  @MainActor
  func plan(app: URL, withData: Bool) throws -> UninstallPlan {
    let id = try Self.identifier(at: app)
    guard app.pathExtension == "app", !app.path.hasPrefix("/System/"),
      !(id.hasPrefix("com.apple.") && app.path.hasPrefix("/Applications/")),
      id != "com.juniornkanabassi.Updater",
      !app.path.hasPrefix("/Applications/JuniorOS Apps/") else {
      throw ControlError("protected_app", "Updater and protected system or JuniorOS apps cannot be uninstalled.")
    }
    guard !isRunning(app) else { throw ControlError("app_running", "Quit the app before previewing its removal.") }
    let siblings = try copies(id).contains { URL(fileURLWithPath: $0).path != app.path }
    var found: [UninstallItem] = []
    func add(_ path: URL, root: URL, kind: UninstallItem.Kind, personal: Bool = false) {
      guard let item = try? snapshot(path, root: root, kind: kind, personal: personal, selected: !personal || withData) else { return }
      found.append(item)
    }
    guard let bundle = try? snapshot(app, root: app.deletingLastPathComponent(), kind: .app, personal: false, selected: true) else {
      throw ControlError("unsafe_app", "The app path is missing, unreadable or contains a symbolic link.")
    }
    found.append(bundle)
    // Shared preferences/data belong to the remaining copy, even when a path selected this one.
    if !siblings {
      let library = home.appendingPathComponent("Library")
      let keyed: [(String, String, UninstallItem.Kind, Bool)] = [
        ("Application Support", id, .data, true), ("Caches", id, .cache, false),
        ("Logs", id, .cache, false), ("Saved Application State", id + ".savedState", .cache, false),
        ("Containers", id, .data, true), ("WebKit", id, .cache, false),
        ("WebKit/com.apple.WebKit.WebContent", id, .cache, false),
        ("HTTPStorages", id, .cache, false), ("HTTPStorages", id + ".binarycookies", .cache, false),
        ("Cookies", id + ".binarycookies", .cache, false), ("Application Scripts", id, .data, true),
        ("Autosave Information", id, .data, true), ("SyncedPreferences", id + ".plist", .prefs, false),
        ("Preferences", id, .prefs, false), ("Preferences", id + ".plist", .prefs, false),
        ("LaunchAgents", id + ".plist", .launchAgent, false),
        ("Caches/com.plausiblelabs.crashreporter.data", id, .cache, false),
        ("Caches/com.crashlytics.data", id, .cache, false), ("Caches", id + ".ShipIt", .cache, false),
        ("Caches/com.apple.nsurlsessiond/Downloads", id, .cache, false),
        ("Application Support/com.bugsnag.Bugsnag", id, .data, true)
      ]
      for (directory, leaf, kind, personal) in keyed {
        let root = library.appendingPathComponent(directory)
        add(root.appendingPathComponent(leaf), root: root, kind: kind, personal: personal)
      }
      let byHost = library.appendingPathComponent("Preferences/ByHost")
      for file in children(byHost) where file.lastPathComponent.hasPrefix(id + ".") && file.pathExtension == "plist" {
        add(file, root: byHost, kind: .prefs)
      }
      // Container names alone do not prove ownership, including group.<id> and UUID names.
      for directory in ["Containers", "Group Containers"] {
        let root = library.appendingPathComponent(directory)
        for container in children(root) {
          let metadata = container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
          if let info = try? Self.dictionary(metadata), Self.metadata(info, names: id) {
            add(container, root: root, kind: .data, personal: true)
          }
        }
      }
      let name = app.deletingPathExtension().lastPathComponent
      let common: Set<String> = Set("music notes photos finder safari preview calendar contacts messages reminders clock weather stocks books news podcasts voice files store system helper agent daemon service update sync backup cloud manager monitor server client worker runner launcher driver plugin extension widget utility electron".split(separator: " ").map(String.init))
      let safeName = name.count >= 3 && !common.contains(name.lowercased()) && !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      if safeName {
        let variants = Set([name, name.lowercased(), name.replacingOccurrences(of: " ", with: ""), name.replacingOccurrences(of: " ", with: "_"), name.replacingOccurrences(of: " ", with: "-")])
        for variant in variants {
          for (directory, suffix, kind, personal) in [("Application Support", "", UninstallItem.Kind.data, true), ("Caches", "", .cache, false), ("Logs", "", .cache, false), ("Preferences", ".plist", .prefs, false), ("Saved Application State", ".savedState", .cache, false), ("Caches/SentryCrash", "", .cache, false), ("Caches/KSCrash", "", .cache, false)] {
            let root = library.appendingPathComponent(directory)
            add(root.appendingPathComponent(variant + suffix), root: root, kind: kind, personal: personal)
          }
        }
        for directory in ["Logs/DiagnosticReports", "Application Support/CrashReporter"] {
          let root = library.appendingPathComponent(directory)
          for file in children(root) where file.lastPathComponent.hasPrefix(name + "_") && ["crash", "ips", "plist"].contains(file.pathExtension) {
            add(file, root: root, kind: .cache)
          }
        }
      }
      for (directory, suffix, kind, personal) in [("Application Support", "", UninstallItem.Kind.data, true), ("Caches", "", .cache, false), ("Preferences", ".plist", .prefs, false), ("Receipts", ".bom", .system, false), ("Receipts", ".plist", .system, false), ("LaunchAgents", ".plist", .launchAgent, false), ("LaunchDaemons", ".plist", .launchAgent, false), ("PrivilegedHelperTools", "", .system, false)] {
        let root = systemLibrary.appendingPathComponent(directory)
        add(root.appendingPathComponent(id + suffix), root: root, kind: kind, personal: personal)
      }
    }
    // A parent move already includes children. Never move a descendant a second time.
    var unique: [UninstallItem] = []
    for item in found.sorted(by: { $0.path.count < $1.path.count }) {
      if !unique.contains(where: { item.path == $0.path || item.path.hasPrefix($0.path + "/") }) { unique.append(item) }
    }
    return UninstallPlan(appPath: app.path, bundleIdentifier: id, items: unique, siblingCopies: siblings, withData: withData)
  }

  static func metadata(_ object: Any, names id: String) -> Bool {
    if let string = object as? String { return string == id }
    if let array = object as? [Any] { return array.contains { metadata($0, names: id) } }
    if let dictionary = object as? [String: Any] { return dictionary.values.contains { metadata($0, names: id) } }
    return false
  }

  private func children(_ root: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
  }

  /// lstat every component: a symlink in a parent must not broaden an exact-path rule.
  static func safePath(_ path: URL, under root: URL) -> Bool {
    let path = path.path
    let root = root.path
    guard path.hasPrefix(root + "/") else { return false }
    var current = ""
    for part in path.split(separator: "/") {
      current += "/" + part
      var info = stat()
      guard lstat(current, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { return false }
    }
    return true
  }

  func snapshot(_ path: URL, root: URL, kind: UninstallItem.Kind, personal: Bool, selected: Bool) throws -> UninstallItem {
    guard Self.safePath(path, under: root) else { throw ControlError("path_changed", "Unsafe or missing path: \(path.path)") }
    var info = stat()
    guard lstat(path.path, &info) == 0 else { throw POSIXError(.ENOENT) }
    let parent = path.deletingLastPathComponent()
    let needsAdmin = info.st_uid != uid || !FileManager.default.isWritableFile(atPath: parent.path)
    var size = Int64(info.st_size)
    if info.st_mode & S_IFMT == S_IFDIR, let walk = FileManager.default.enumerator(at: path, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsPackageDescendants]) {
      for case let file as URL in walk { size += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    let identityHash: String? = kind == .app ? try Data(contentsOf: path.appendingPathComponent("Contents/Info.plist")).sha256 : nil
    return UninstallItem(path: path.path, root: root.path, size: size, kind: kind, personalData: personal, needsAdmin: needsAdmin, inode: UInt64(info.st_ino), device: UInt64(info.st_dev), modified: Int64(info.st_mtimespec.tv_sec), changed: Int64(info.st_ctimespec.tv_sec), identityHash: identityHash, selected: selected)
  }

  func validate(_ item: UninstallItem) throws {
    let fresh = try snapshot(URL(fileURLWithPath: item.path), root: URL(fileURLWithPath: item.root), kind: item.kind, personal: item.personalData, selected: item.selected)
    guard fresh.inode == item.inode, fresh.device == item.device, fresh.modified == item.modified, fresh.changed == item.changed, fresh.identityHash == item.identityHash else {
      throw ControlError("path_changed", "The previewed item changed: \(item.path)")
    }
  }
}

private extension Data {
  var sha256: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}
