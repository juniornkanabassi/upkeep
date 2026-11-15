// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation
import SQLite3

/// Adobe apps are updated by the Creative Cloud app. Its package database (pim.db) shows
/// Creative Cloud is installed and managing packages. Which versions Creative Cloud has offered
/// comes from its Apps panel preferences (`seenUpdate` products such as `PPRO_27.0`): an app
/// below the newest offered version has an update, an app at or above it is current, exactly
/// as Creative Cloud reports. Without that record the app hands off with availability unknown.
/// RemoteUpdateManager is deferred; see PLAN.md, Round 3.
struct AdobeCreativeCloud: Sendable {
  var database = URL(
    fileURLWithPath: "/Library/Application Support/Adobe/Adobe Desktop Common/pim.db")
  var app = URL(
    fileURLWithPath: "/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app")
  /// Current installs keep the app under Utilities; "/Applications/Adobe Creative Cloud" holds
  /// only an alias to it.
  /// Creative Cloud's Apps panel preferences; nil (tests, no Creative Cloud sign-in) keeps
  /// availability unknown.
  var appsPanelPrefs: URL? = nil
  /// Opens Creative Cloud; injectable so tests open nothing.
  var open: @MainActor @Sendable (URL) -> Void = {
    MacApplicationWorkspace.shared.openApplication(at: $0)
  }
  static let live = AdobeCreativeCloud(
    app: [
      "/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app",
      "/Applications/Adobe Creative Cloud/Adobe Creative Cloud.app",
    ].map(URL.init(fileURLWithPath:)).first { FileManager.default.fileExists(atPath: $0.path) }
      ?? URL(fileURLWithPath: "/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app"),
    appsPanelPrefs: newestAppsPanelPrefs(
      in: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/Adobe/OOBE"))
  )

  /// The signed-in user's `com.adobe.accc.apps.<user>.prefs`, newest first if several.
  static func newestAppsPanelPrefs(in folder: URL) -> URL? {
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return
      files
      .filter {
        $0.lastPathComponent.hasPrefix("com.adobe.accc.apps.")
          && $0.pathExtension == "prefs" && !$0.lastPathComponent.hasSuffix(".default.prefs")
      }
      .max {
        let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (a ?? .distantPast) < (b ?? .distantPast)
      }
  }

  /// Creative Cloud's product code for the apps it updates; nil for anything else.
  static func productCode(for bundleIdentifier: String) -> String? {
    let codes: [(prefix: String, code: String)] = [
      ("com.adobe.PremierePro", "PPRO"), ("com.adobe.AfterEffects", "AEFT"),
      ("com.adobe.ame.application", "AME"), ("com.adobe.Audition", "AUDT"),
      ("com.adobe.Photoshop", "PHSP"), ("com.adobe.lightroomCC", "LRCC"),
      ("com.adobe.illustrator", "ILST"), ("com.adobe.InDesign", "IDSN"),
      ("com.adobe.bridge", "KBRG"), ("com.adobe.CCXProcess", "CCXP"),
      ("com.adobe.uxp.devtools", "UXPD"),
    ]
    return codes.first { bundleIdentifier.lowercased().hasPrefix($0.prefix.lowercased()) }?.code
  }

  /// The newest version Creative Cloud has offered for this app, or nil when its record says
  /// nothing reliable. Yearly apps ("Adobe Photoshop 2027") only take offers in their own major
  /// version: next year's release is a separate app. Beta apps read the beta channel.
  /// The record is a history of offers, so it only proves "current" while Creative Cloud keeps
  /// writing it (within `freshness`); an older record still proves a newer offer exists.
  func offeredVersion(for bundle: App.Bundle, now: Date = Date()) -> Version? {
    guard let appsPanelPrefs, var code = Self.productCode(for: bundle.bundleIdentifier),
      let text = try? String(contentsOf: appsPanelPrefs, encoding: .utf8)
    else { return nil }
    let path = bundle.fileURL.path
    if path.range(of: "beta", options: .caseInsensitive) != nil { code += "BETA" }
    let installed = bundle.version.versionNumber ?? ""
    let yearly = path.range(of: #" 20\d\d( \(Beta\))?(/|\.app)"#, options: .regularExpression) != nil
    let major = installed.split(separator: ".").first.map(String.init)
    let offers = Self.offeredVersions(of: code, in: text).filter {
      !yearly || $0.split(separator: ".").first.map(String.init) == major
    }
    guard
      let newest = offers.map({ Version(versionNumber: $0, buildNumber: nil) })
        .max(by: { $0.comparisonForUpdate(to: $1) == .older })
    else { return nil }
    if bundle.version.comparisonForUpdate(to: newest) == .older { return newest }
    // FileManager, not URL resource values: a URL caches its values for the life of the check.
    let written =
      (try? FileManager.default.attributesOfItem(atPath: appsPanelPrefs.path))?[.modificationDate]
      as? Date ?? .distantPast
    // Current: report the installed version itself, since an offer without a build number
    // cannot be compared with an installed build (Lightroom 10.0 showed "cannot be compared").
    return now.timeIntervalSince(written) < Self.freshness ? bundle.version : nil
  }

  /// Creative Cloud rewrites its Apps panel record each time it refreshes (several times a
  /// day while it runs); older than this, "no newer offer" is no longer evidence.
  static let freshness: TimeInterval = 3 * 24 * 60 * 60

  /// `sapVersion="PPRO_27.0" seenUpdate="true"` entries; the prefs escape the inner XML.
  static func offeredVersions(of code: String, in prefs: String) -> [String] {
    let pattern = #"sapVersion=(?:"|&quot;)"# + code + #"_([0-9][0-9.]*)(?:"|&quot;) seenUpdate=(?:"|&quot;)true"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(prefs.startIndex..., in: prefs)
    return regex.matches(in: prefs, range: range).compactMap {
      Range($0.range(at: 1), in: prefs).map { String(prefs[$0]) }
    }
  }

  func manages(_ bundle: App.Bundle) -> Bool {
    bundle.bundleIdentifier.hasPrefix("com.adobe.")
      // Creative Cloud's own components update themselves.
      && !bundle.fileURL.path.hasPrefix(app.deletingLastPathComponent().path + "/")
      && !bundle.bundleIdentifier.hasPrefix("com.adobe.acc")
      && FileManager.default.fileExists(atPath: app.path) && packageCount() > 0
  }

  /// Creative Cloud's own app and Core Sync (`com.adobe.acc*`), which it keeps current itself.
  func updatesItself(_ bundle: App.Bundle) -> Bool {
    bundle.bundleIdentifier.hasPrefix("com.adobe.acc")
      && FileManager.default.fileExists(atPath: app.path)
  }

  /// Reads a copy of pim.db, opened read-only, so Creative Cloud's own file is never locked
  /// or written.
  func packageCount() -> Int {
    let copy = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pim-\(UUID().uuidString).db")
    guard (try? FileManager.default.copyItem(at: database, to: copy)) != nil else { return 0 }
    defer { try? FileManager.default.removeItem(at: copy) }
    var db: OpaquePointer?
    guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      sqlite3_close(db)
      return 0
    }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(db, "SELECT count(*) FROM package_installation_info", -1, &statement, nil)
        == SQLITE_OK
    else { return 0 }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
  }
}
