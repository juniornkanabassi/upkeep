// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

enum DriverUpdates {
  static func check(_ bundle: App.Bundle) async throws -> App.Update {
    if bundle.bundleIdentifier == "com.rogueamoeba.ARK.driver", let tool = bundle.companionToolURL {
      guard let number = DriverDiscovery.arkVersion(at: tool) else {
        throw DriverSourceUnavailable(note: "ARK's installer could not be read. Check again.")
      }
      let version = Version(versionNumber: number, buildNumber: nil)
      return App.Update(app: bundle, remoteVersion: version, minimumOSVersion: nil,
        source: .driver, date: nil, releaseNotes: nil,
        updateAction: .vendorTool { app in
          UpdateQueue.shared.addOperation(ARKUpdateOperation(app: app, tool: tool, version: version))
        })
    }
    if let update = try await BlackmagicCatalogue.update(for: bundle) { return update }
    if let hostURL = bundle.hostURL, let host = BundleCollector.collectBundle(at: hostURL) {
      let update = try await UpdateCheckCoordinator.check(host, repository: nil)
      // Discovery gives linked extensions the host version for this comparison.
      return App.Update(app: bundle, remoteVersion: update.remoteVersion, minimumOSVersion: nil,
        source: .driver, date: nil, releaseNotes: nil,
        updateAction: .external(label: "Updates with \(host.name)") { _ in },
        availabilityUnknown: update.availabilityUnknown)
    }
    // Known unsupported driver: expose the installed version without an update action.
    return App.Update(app: bundle, remoteVersion: bundle.version, minimumOSVersion: nil,
      source: .driver, date: nil, releaseNotes: nil,
      updateAction: .external(label: bundle.note ?? "No supported update source") { _ in })
  }
}

struct DriverSourceUnavailable: LocalizedError {
  let note: String
  var errorDescription: String? { note }
}

/// ARK owns its driver transaction. The shared queue verifies the exact installed version
/// afterwards, and serialises every ARK job on one lock. No app replacement is attempted.
final class ARKUpdateOperation: UpdateOperation, @unchecked Sendable {
  typealias Installer = @Sendable (URL) async throws -> Void
  private let tool: URL
  private let install: Installer
  private let usesSystemInstaller: Bool
  override var lockKey: String { "rogue-amoeba-ark" }

  init(app: App.Bundle, tool: URL, version: Version,
       install: Installer? = nil) {
    self.tool = tool
    self.usesSystemInstaller = install == nil
    self.install = install ?? Self.installWithAdministrator
    super.init(bundleIdentifier: app.bundleIdentifier, appIdentifier: app.fileURL)
    expectedVersion = version
    recordedIdentity = app
  }

  override func execute() {
    super.execute()
    Task {
      do {
        if self.usesSystemInstaller,
          self.appIdentifier.standardizedFileURL != URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/ARK.driver") {
          throw DriverSourceUnavailable(note: "ARK's installer only updates the system ARK driver.")
        }
        guard let installed = DriverDiscovery.read(at: self.appIdentifier),
          installed.bundleIdentifier == "com.rogueamoeba.ARK.driver",
          let number = DriverDiscovery.arkVersion(at: self.tool),
          let expected = self.expectedVersion,
          Version(versionNumber: number, buildNumber: nil).comparisonForUpdate(to: expected)
            == .samePrecedence else {
          throw DriverSourceUnavailable(note: "The ARK installer changed. Check for updates again.")
        }
        guard installed.version.comparisonForUpdate(to: expected) == .older else {
          self.finish()
          return
        }
        try self.beginCommit()
        self.progressState = .installing
        try await self.install(self.tool)
        guard let after = DriverDiscovery.read(at: self.appIdentifier),
          after.bundleIdentifier == installed.bundleIdentifier,
          installed.version.comparisonForUpdate(to: after.version) == .older else {
          throw DriverSourceUnavailable(note: "ARK's installed version did not change.")
        }
        try ReplacementTransaction.verifyVersion(installed: after.version,
          previous: installed.version, expected: expected)
        self.finish()
      } catch { self.finish(with: error) }
    }
  }

  static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  static func administratorScript(tool: URL) -> String {
    // The privileged process copies first into a root-owned directory, then validates the
    // copy against Rogue Amoeba's designated identity before executing it. A user-writable
    // source cannot be swapped after validation to execute different code as root.
    let requirement = "anchor apple generic and identifier \"arkinstaller\" and certificate leaf[subject.OU] = \"7266XEXAPM\""
    let command = "set -eu; d=$(/usr/bin/mktemp -d /private/tmp/updater-ark.XXXXXX); "
      + "trap '/bin/rm -rf \"$d\"' EXIT; /bin/cp " + shellQuote(tool.path)
      + " \"$d/arkinstaller\"; /bin/chmod 700 \"$d/arkinstaller\"; "
      + "/usr/bin/codesign --verify --strict --all-architectures -R " + shellQuote(requirement)
      + " \"$d/arkinstaller\"; \"$d/arkinstaller\" install --silent"
    let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "do shell script \"\(escaped)\" with administrator privileges"
  }

  static func installWithAdministrator(_ tool: URL) async throws {
    // One system admin prompt, no password handling, no timeout killing an active installer.
    let log = try ToolProcess.newLog(named: "ark", in: ToolProcess.defaultLogDirectory)
    let status = try await ToolProcess.run(URL(fileURLWithPath: "/usr/bin/osascript"),
      ["-e", administratorScript(tool: tool)], log: log)
    guard status == 0 else {
      throw VendorToolError.failed(reason: "ARK installation was cancelled or failed.", logPath: log.path)
    }
  }
}
