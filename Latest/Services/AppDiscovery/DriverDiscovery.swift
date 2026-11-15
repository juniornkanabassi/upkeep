// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

/// Reads installed bundles only. Discovery never executes a driver or vendor tool.
enum DriverDiscovery {
  static let extensions: Set<String> = ["driver", "kext", "dext", "systemextension"]

  static func collect(apps: [App.Bundle], library: URL = URL(fileURLWithPath: "/Library"))
    -> [App.Bundle]
  {
    let roots = ["Audio/Plug-Ins/HAL", "Extensions"]
    var urls = Set<URL>()
    for root in roots {
      let enumerator = FileManager.default.enumerator(
        at: library.appendingPathComponent(root), includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])
      while let url = enumerator?.nextObject() as? URL {
        if extensions.contains(url.pathExtension) {
          urls.insert(url)
          enumerator?.skipDescendants()
        }
      }
    }
    let database = library.appendingPathComponent("SystemExtensions/db.plist")
    if let data = try? Data(contentsOf: database),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      let entries = plist["extensions"] as? [[String: Any]] {
      for entry in entries where entry["state"] as? String == "activated_enabled" {
        guard let staged = entry["stagedBundleURL"] as? [String: Any],
          let relative = staged["relative"] as? String, let url = URL(string: relative),
          url.isFileURL, url.standardizedFileURL.path.hasPrefix(
            library.appendingPathComponent("SystemExtensions").standardizedFileURL.path + "/")
        else { continue }
        urls.insert(url)
      }
    }
    // Identify active copies by the matching extension shipped inside their host.
    var hosts = [String: App.Bundle]()
    for app in apps {
      let root = app.fileURL.appendingPathComponent("Contents/Library/SystemExtensions")
      for url in (try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil)) ?? [] {
        if let id = info(at: url)?["CFBundleIdentifier"] as? String { hosts[id] = app }
      }
    }
    let ark = newestARK(in: apps)
    let desktopVideo = apps.first { $0.bundleIdentifier == "com.blackmagic-design.desktopvideo.utility" }
    return urls.sorted { $0.path < $1.path }.compactMap { url in
      guard let raw = read(at: url) else { return nil }
      let host = hosts[raw.bundleIdentifier]
      let blackmagic = [
        "com.blackmagicdesign.audio.BlackmagicAudio", "com.blackmagic-design.BlackmagicIO.DExt",
        "com.blackmagic-design.desktopvideo.Network.DExt",
        "com.blackmagic-design.desktopvideo.BlackmagicCameraExtension",
      ].contains(raw.bundleIdentifier)
      let isARK = raw.bundleIdentifier == "com.rogueamoeba.ARK.driver"
      let parent = blackmagic ? "Blackmagic Desktop Video" : host?.name
      let note = parent.map { "Updates with \($0)" }
        ?? (isARK ? "A macOS administrator prompt is required. Audio apps may briefly lose sound during installation."
          : url.pathExtension == "kext" ? "Legacy kernel extension; no supported update source."
          : raw.bundleIdentifier.hasPrefix("com.apple.") ? "Updates with macOS" : "No update source")
      return App.Bundle(
        version: blackmagic ? (desktopVideo?.version ?? raw.version) : (host?.version ?? raw.version), name: raw.name, bundleIdentifier: raw.bundleIdentifier,
        fileURL: url, source: .driver, kind: .driver, parent: parent,
        vendor: raw.vendor, note: note, hostURL: host?.fileURL,
        companionToolURL: isARK ? ark?.tool : nil, companionVersion: isARK ? ark?.version : nil)
    }
  }

  static func info(at url: URL) -> [String: Any]? {
    for path in ["Contents/Info.plist", "Info.plist"] {
      if let data = try? Data(contentsOf: url.appendingPathComponent(path)),
        let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
          as? [String: Any] { return info }
    }
    return nil
  }

  static func read(at url: URL) -> App.Bundle? {
    guard extensions.contains(url.pathExtension), let info = info(at: url),
      let id = info["CFBundleIdentifier"] as? String else { return nil }
    let version = Version(versionNumber: info["CFBundleShortVersionString"] as? String,
      buildNumber: info["CFBundleVersion"] as? String)
    guard !version.isEmpty else { return nil }
    let vendor = (id.hasPrefix("com.rogueamoeba.") ? "Rogue Amoeba"
        : id.lowercased().contains("blackmagic") ? "Blackmagic Design"
        : id.hasPrefix("com.apple.") ? "Apple" : id.split(separator: ".").prefix(2).joined(separator: "."))
    return App.Bundle(version: version,
      name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
        ?? url.deletingPathExtension().lastPathComponent,
      bundleIdentifier: id, fileURL: url, source: .driver, kind: .driver, vendor: vendor)
  }

  struct ARK: Sendable { let tool: URL; let version: String }

  static func newestARK(in apps: [App.Bundle]) -> ARK? {
    var newest: ARK?
    for app in apps where app.bundleIdentifier.hasPrefix("com.rogueamoeba.") {
      let tool = app.fileURL.appendingPathComponent("Contents/Resources/arkinstaller")
      guard let version = arkVersion(at: tool) else { continue }
      if newest == nil || Version(versionNumber: newest!.version, buildNumber: nil)
        .comparisonForUpdate(to: Version(versionNumber: version, buildNumber: nil)) == .older {
        newest = ARK(tool: tool, version: version)
      }
    }
    return newest
  }

  /// arkinstaller embeds an XML Info.plist in __TEXT,__info_plist in each Mach-O slice.
  /// Accept only matching, consistent arkinstaller plists, never arbitrary version strings.
  static func arkVersion(at tool: URL) -> String? {
    guard let size = try? tool.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= 64 * 1_024 * 1_024,
      let data = try? Data(contentsOf: tool, options: .mappedIfSafe) else { return nil }
    var offset = 0
    var versions = Set<String>()
    while offset < data.count,
      let start = data.range(of: Data("<?xml".utf8), in: offset..<data.count),
      let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.count) {
      offset = end.upperBound
      guard end.upperBound - start.lowerBound <= 128 * 1_024,
        let info = try? PropertyListSerialization.propertyList(
          from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
        info["CFBundleExecutable"] as? String == "arkinstaller",
        let version = info["CFBundleShortVersionString"] as? String,
        version.range(of: #"^\d+(\.\d+)+$"#, options: .regularExpression) != nil else { continue }
      versions.insert(version)
    }
    return versions.count == 1 ? versions.first : nil
  }
}

/// Known companion families, plus helpers in an outer app or a named product folder.
enum CompanionGrouping {
  static func parent(at url: URL, identifier: String) -> String? {
    let components = url.pathComponents
    if let outer = components.dropLast().last(where: { $0.hasSuffix(".app") }) {
      return String(outer.dropLast(4))
    }
    let name = url.deletingPathExtension().lastPathComponent
    if components.contains("Blackmagic ATEM Switchers"),
      ["SwitcherMediaPool", "SwitcherPanel", "SwitcherRecord", "SwitcherStreaming"].contains(name) {
      return "Blackmagic ATEM Switchers"
    }
    if ["Uninstall Resolve", "Blackmagic Remote Monitor", "Fairlight Studio Utility",
        "Blackmagic Proxy Generator Lite"].contains(name) { return "DaVinci Resolve" }
    if ["Uninstall DeckLink", "Media Player Setup"].contains(name) {
      return "Blackmagic Desktop Video"
    }
    if ["Creative Cloud Uninstaller", "Adobe Creative Cloud Diagnostics"].contains(name) {
      return "Adobe Creative Cloud"
    }
    if identifier.hasPrefix("com.google.drivefs.shortcuts.") { return "Google Drive" }
    if name == "DisplayLinkUserAgent" { return "DisplayLink Manager" }
    if name == "Claude Code URL Handler" { return "Claude Code" }
    return nil
  }
}
