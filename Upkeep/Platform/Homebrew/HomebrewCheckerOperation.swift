//
//  HomebrewCheckerOperation.swift
//  Latest
//
//  Created by Max Langer on 12.03.22.
//  Copyright © 2022 Max Langer. All rights reserved.
//

import AppKit

/// Async update checking via Homebrew. The historical type name is retained to
/// avoid needless source churn, but checking is no longer an Operation.
final class HomebrewCheckerOperation: Sendable {

  private let bundle: App.Bundle
  private let repository: UpdateRepository?
  private let homebrew: Homebrew?
  private let catalogueCheck: CatalogueInstallCheck

  init(
    with bundle: App.Bundle, repository: UpdateRepository?, homebrew: Homebrew? = .shared,
    catalogueCheck: CatalogueInstallCheck = .live
  ) {
    self.catalogueCheck = catalogueCheck
    self.bundle = bundle
    self.repository = repository
    self.homebrew = homebrew
  }

  /// A cask owns the app only if its installed app artifact is exactly this bundle. Then
  /// brew is the update route, whatever other source the bundle has; Upkeep runs it only
  /// when the upgrade provably stays on this copy, and otherwise hands off with the command.
  static func ownedUpdate(
    for bundle: App.Bundle, homebrew: Homebrew?, scope: HomebrewScope = .live
  ) async -> App.Update? {
    guard let homebrew, let cask = try? await homebrew.owningCask(of: bundle.fileURL) else {
      return nil
    }
    let current = (try? await homebrew.outdatedVersion(of: cask.token)) ?? nil
    let remote = current.map(VersionParser.parse(combinedVersionNumber:)) ?? bundle.version
    let action: App.Update.Action
    // `version :latest` casks cannot be checked against a version afterwards.
    if current != "latest", scope.installs(cask, at: bundle.fileURL) {
      // Cask versions can carry a build suffix the bundle lacks; check the version number.
      let expected = Version(versionNumber: remote.versionNumber, buildNumber: nil)
      action = .builtIn { app in
        UpdateQueue.shared.addOperation(
          HomebrewUpgradeOperation(app: app, token: cask.token, expectedVersion: expected))
      }
    } else {
      // Anything outside the allow list (admin steps, scripts, several apps, hooks reaching
      // other copies, :latest): brew runs in a Rex tab where the person can answer any
      // password prompt, or without Rex the command is copied and Terminal opens.
      let token = cask.token
      action = .external(label: handOffLabel) { _ in
        Task { @MainActor in
          if RexTerminal.isAvailable {
            RexTerminal.upgrade(token)
            return
          }
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(adminCommand(for: token), forType: .string)
          MacApplicationWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
      }
    }
    return App.Update(
      app: bundle, remoteVersion: remote, minimumOSVersion: nil, source: .homebrew, date: nil,
      releaseNotes: ReleaseNotesSourceCatalog.releaseNotes(for: bundle, remoteVersion: remote),
      updateAction: action)
  }

  /// Shown as "Open Terminal (brew command copied)", or "Rex" when brew runs there.
  static var handOffLabel: String {
    RexTerminal.isAvailable ? "Rex" : "Terminal (brew command copied)"
  }

  static func adminCommand(for token: String) -> String { "brew upgrade --cask \(token)" }

  func check() async throws -> App.Update {
    try Task.checkCancellation()
    if bundle.bundleIdentifier == "md.obsidian" {
      return try await ObsidianUpdate.check(bundle)
    }
    if bundle.bundleIdentifier == "com.zed-industries.delta" {
      let source = AppDownloadSource.delta
      let release = try await source.release()
      return App.Update(
        app: bundle, remoteVersion: release.version, minimumOSVersion: nil,
        source: .directDownload, date: nil,
        releaseNotes: .changelog(
          urls: [URL(string: "https://delta.dev/docs/whats-in-the-latest")!],
          versionPrefix: release.version.versionNumber, allowsLatestFallback: true,
          fallbackHTML: nil),
        updateAction: .builtIn { app in
          UpdateQueue.shared.addOperation(AppDownloadUpdateOperation(app: app, source: source))
        })
    }
    if let owned = await Self.ownedUpdate(for: bundle, homebrew: homebrew) { return owned }
    guard let repository else {
      throw UpkeepError.updateInfoUnavailable
    }

    // The cask chosen by identity (and channel) comes first; its version, release and action
    // are what the row shows. Name matching is only the fallback route (R5B, REV-007).
    let candidates = await repository.caskTokens(withBundleIdentifier: bundle.bundleIdentifier)
    let identityToken = try? CatalogueInstall.token(for: bundle, candidates: candidates)
    var identityEntry: UpdateRepository.Entry?
    if let identityToken {
      identityEntry = await repository.entry(token: identityToken, for: bundle)
    }
    var fallbackEntry: UpdateRepository.Entry?
    if identityEntry == nil { fallbackEntry = await repository.entry(for: bundle) }
    guard let entry = identityEntry ?? fallbackEntry else {
      throw UpkeepError.updateInfoUnavailable
    }
    try Task.checkCancellation()
    let version = entry.version
    let releaseNotes =
      ReleaseNotesSourceCatalog.releaseNotes(
        for: bundle,
        remoteVersion: version,
        allowNameFallback: false
      ) ?? entry.releaseNotes
    // Round 5b: install from the catalogue only when identity, shape and scope all hold.
    var plan: (token: String, release: AppDownloadRelease)?
    if identityEntry != nil {
      plan = await catalogueCheck.plan(
        for: bundle, candidateTokens: candidates, matchedToken: entry.token,
        catalogueVersion: version)
    }
    let action: App.Update.Action
    if let plan {
      let job = CatalogueJob(token: plan.token, minimumVersion: version, check: catalogueCheck)
      action = .builtIn { app in
        UpdateQueue.shared.addOperation(AppDownloadUpdateOperation(app: app, catalogue: job))
      }
    } else {
      action = .external(label: bundle.name) { app in
        Task { @MainActor in MacApplicationWorkspace.shared.openApplication(at: app.fileURL) }
      }
    }
    return App.Update(
      app: bundle,
      remoteVersion: version,
      minimumOSVersion: entry.minimumOSVersion,
      source: plan == nil ? .homebrew : .directDownload,
      date: nil,
      releaseNotes: releaseNotes,
      updateAction: action
    )
  }
}

/// Runs brew upgrades Upkeep cannot do itself in a background tab of Junior's Rex session
/// `agents`, so no command has to be pasted. Upgrades asked for together share one tab and
/// one brew run (one password prompt, no brew lock contention).
@MainActor
enum RexTerminal {
  nonisolated static let session = "agents"
  nonisolated static let executable: URL? = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return ["\(home)/.local/bin/rex", "/opt/homebrew/bin/rex", "/usr/local/bin/rex"]
      .first { FileManager.default.isExecutableFile(atPath: $0) }
      .map(URL.init(fileURLWithPath:))
  }()
  nonisolated static var isAvailable: Bool { executable != nil }

  private static var pending: [String] = []

  static func upgrade(_ token: String) {
    if !pending.contains(token) { pending.append(token) }
    guard pending.count == 1 else { return }
    // Update All submits every app in one main-actor pass; collect them into one brew run.
    DispatchQueue.main.async {
      let tokens = pending
      pending = []
      run(tokens)
    }
  }

  nonisolated static func arguments(for tokens: [String], sessionExists: Bool) -> [String] {
    let label = tokens.count == 1 ? "brew \(tokens[0])" : "brew upgrade"
    let brew = Homebrew.locate()?.path ?? "brew"
    let command = ["--keep-open", "--", brew, "upgrade", "--cask"] + tokens
    return sessionExists
      ? ["window", "new", "-s", session, label, "--focus=false"] + command
      : ["new", session, "--window", label] + command
  }

  private static func run(_ tokens: [String]) {
    guard let executable, !tokens.isEmpty else { return }
    Task.detached {
      let list = (try? output(executable, ["ls", "--json"])) ?? ""
      let exists = list.contains("\"label\": \"\(session)\"")
      _ = try? output(executable, arguments(for: tokens, sessionExists: exists))
    }
  }

  nonisolated private static func output(_ executable: URL, _ arguments: [String]) throws
    -> String
  {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }
}

extension App {
  /// A brew upgrade Upkeep starts in Rex: one click, so Update All includes it.
  var upgradesInRex: Bool {
    RexTerminal.isAvailable && externalUpdaterName == HomebrewCheckerOperation.handOffLabel
  }
}
