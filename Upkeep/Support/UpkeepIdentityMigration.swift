// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

/// Old names are confined here so existing installations can cross the identity boundary.
enum UpkeepIdentityMigration {
  static let oldDomain = "com.juniornkanabassi.Updater"
  static let newDomain = "com.juniornkanabassi.Upkeep"
  static let oldFolder = "Updater"
  static let completionKey = "UpkeepIdentityMigrationCompleted"

  static func root(in support: URL) -> URL {
    let old = support.appendingPathComponent(oldFolder)
    let new = support.appendingPathComponent("Upkeep")
    // Do not relocate backup paths while an interrupted installer may still use them.
    if FileManager.default.fileExists(atPath: new.path),
      (try? FileManager.default.contentsOfDirectory(atPath: old.path).isEmpty) == true
    {
      return new
    }
    return FileManager.default.fileExists(atPath: old.path) ? old : new
  }

  /// Returns true once, when old state was migrated. Pending journals stay at their original
  /// paths and are honoured by normal recovery before a later launch completes migration.
  static func migrate(
    support: URL, defaults: UserDefaults = .standard,
    oldDomain: String = oldDomain, newDomain: String = newDomain
  ) throws -> Bool {
    let manager = FileManager.default
    let old = support.appendingPathComponent(oldFolder)
    let new = support.appendingPathComponent("Upkeep")
    let oldExists = manager.fileExists(atPath: old.path)
    var pending = false
    if oldExists {
      if manager.fileExists(atPath: new.path) {
        guard try manager.contentsOfDirectory(atPath: old.path).isEmpty else {
          throw NSError(
            domain: newDomain, code: 1,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Both Upkeep and its old data folder exist. Both were kept. Updates are paused. Resolve the duplicate data folders and relaunch Upkeep."
            ])
        }
      } else {
        let journals = old.appendingPathComponent("transactions")
        if manager.fileExists(atPath: journals.path),
          try manager.contentsOfDirectory(atPath: journals.path).contains(where: {
            $0.hasSuffix(".json")
          })
        {
          pending = true
        }
        if !pending { try manager.moveItem(at: old, to: new) }
      }
    }
    let previous = defaults.persistentDomain(forName: oldDomain) ?? [:]
    var current = defaults.persistentDomain(forName: newDomain) ?? [:]
    guard !previous.isEmpty || (oldExists && current[completionKey] as? Bool != true) else {
      return false
    }
    for (key, value) in previous where current[key] == nil {
      let lower = key.lowercased()
      if !lower.hasPrefix("nswindow") && !lower.hasPrefix("nsframe")
        && !lower.contains("upkeep-test-") && !lower.contains("updater-test-")
      {
        current[key] = value
      }
    }
    if !pending { current[completionKey] = true }
    defaults.setPersistentDomain(current, forName: newDomain)
    guard defaults.synchronize() else {
      throw NSError(
        domain: newDomain, code: 2,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Upkeep could not save the migrated settings. The old settings were kept."
        ])
    }
    if pending { return false }
    defaults.removePersistentDomain(forName: oldDomain)
    return true
  }
}
