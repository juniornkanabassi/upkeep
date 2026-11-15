// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Synchronization
import XCTest

@testable import Latest

/// Per-app automatic updates, setting credits and attached callers. Fixture apps only live in
/// memory under a temporary path; nothing is installed, and the defaults suite is removed.
@MainActor
final class AutoUpdateTest: XCTestCase {
  private var defaults: UserDefaults!
  private var suite = ""
  private var historyURL: URL!
  private var ignored = Set<String>()

  override func setUp() async throws {
    suite = "AutoUpdateTest.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
    historyURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("auto-\(UUID().uuidString).jsonl")
    ignored = []
  }

  override func tearDown() async throws {
    defaults.removeTestPersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: historyURL)
  }

  private func app(_ name: String, install: Bool = true, ignored: Bool = false) -> App {
    let bundle = App.Bundle(
      version: Version(versionNumber: "1.0", buildNumber: nil), name: name,
      bundleIdentifier: "test.auto.\(name)",
      fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
        "AutoFixtures/\(name).app"),
      source: .sparkle, modificationDate: Date(timeIntervalSince1970: 0))
    let action: App.Update.Action =
      install ? .builtIn { _ in } : .external(label: "Its Store") { _ in }
    let update = App.Update(
      app: bundle, remoteVersion: Version(versionNumber: "1.1", buildNumber: nil),
      minimumOSVersion: nil, source: .sparkle, date: nil, releaseNotes: nil, updateAction: action)
    return App(bundle: bundle, update: .success(update), isIgnored: ignored)
  }

  private func preferences(history: UpdateHistoryStore? = nil) -> AppPreferences {
    AppPreferences(
      defaults: defaults,
      setIgnoredState: { [unowned self] on, app in
        if on { ignored.insert(app.bundleIdentifier) } else { ignored.remove(app.bundleIdentifier) }
      }, history: history)
  }

  func testAutoUpdateIsOffByDefaultAndOnlyForAppsUpkeepInstalls() throws {
    let prefs = preferences()
    let chatGPT = app("ChatGPT")
    XCTAssertFalse(prefs.autoUpdates(chatGPT), "off by default")
    try prefs.set(.autoUpdate, true, for: chatGPT, caller: "gui")
    XCTAssertTrue(prefs.autoUpdates(chatGPT))
    XCTAssertEqual(
      defaults.stringArray(forKey: AppPreferences.autoUpdateKey), [chatGPT.fileURL.path])

    let tailscale = app("Tailscale", install: false)
    XCTAssertThrowsError(try prefs.set(.autoUpdate, true, for: tailscale, caller: "gui"))
    XCTAssertFalse(prefs.autoUpdates(tailscale))
  }

  func testIgnoringTurnsAutomaticUpdatesOffAndRecordsTheCaller() throws {
    let history = UpdateHistoryStore(fileURL: historyURL)
    let prefs = preferences(history: history)
    let blender = app("Blender")
    try prefs.set(.autoUpdate, true, for: blender, caller: "gui")
    try prefs.set(.ignore, true, for: blender, caller: "mcp-claude-code-1234")
    XCTAssertTrue(ignored.contains(blender.bundleIdentifier))
    XCTAssertFalse(prefs.autoUpdatePaths.contains(blender.fileURL.path), "ignore turns auto off")

    let change = try XCTUnwrap(prefs.change(.ignore, for: blender))
    XCTAssertEqual(CallerName.display(change.caller), "Claude")
    XCTAssertTrue(change.on)
    XCTAssertFalse(change.previous)
    // An ignored app cannot be switched to automatic updates.
    XCTAssertThrowsError(
      try prefs.set(.autoUpdate, true, for: blender.with(ignoredState: true), caller: "gui"))

    let latest = try XCTUnwrap(history.entries(limit: 1).first)
    XCTAssertEqual(latest.outcome, .settingChanged(setting: "ignore", on: true))
    XCTAssertEqual(latest.caller, "mcp-claude-code-1234")
    XCTAssertNil(
      history.latestEntry(for: blender.fileURL), "setting changes never become a row's result")

    prefs.undo(.ignore, for: blender.with(ignoredState: true))
    XCTAssertFalse(ignored.contains(blender.bundleIdentifier), "Undo puts the old value back")
    XCTAssertNil(prefs.change(.ignore, for: blender))
  }

  func testCandidatesSkipRunningIgnoredAndSwitchedOffApps() throws {
    let prefs = preferences()
    let on = app("On")
    let running = app("Running")
    let off = app("Off")
    try prefs.set(.autoUpdate, true, for: on, caller: "gui")
    try prefs.set(.autoUpdate, true, for: running, caller: "gui")
    let ignoredCopy = app("Ignored")
    try prefs.set(.autoUpdate, true, for: ignoredCopy, caller: "gui")
    let candidates = prefs.autoUpdateCandidates(
      in: [on, running, off, ignoredCopy.with(ignoredState: true)], eligible: { $0 },
      isRunning: { $0 == running.fileURL })
    XCTAssertEqual(candidates.map(\.name), ["On"])
  }

  func testAutomaticUpdatesGoThroughTheSchedulerEntryPointAndNameUpkeep() {
    let updating = RecordingUpdating()
    let activity = AgentActivity()
    let service = UpdateCheckingService(
      coordinator: StubCoordinator(), appStoreUpdateService: ReadyAppStore(), updating: updating)
    let started = service.updateAutomatically(
      [app("One"), app("Store", install: false)], activity: activity)
    XCTAssertEqual(started.map(\.name), ["One"], "hand-offs never update automatically")
    XCTAssertEqual(updating.bulk, [true], "same bulk path as Update All")
    XCTAssertEqual(activity.job(for: app("One").fileURL.path)?.starter.caller, "upkeep")
  }

  func testAttachedCallersAreNamedInTheRecordedOutcome() {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("Attach-\(UUID()).app")
      .path
    AgentActivity.shared.started(path, by: "mcp-codex-mcp-client-1")
    AgentActivity.shared.attach(path, caller: "mcp-claude-code-2")
    AgentActivity.shared.attach(path, caller: "mcp-claude-code-2")
    AgentActivity.shared.attach(path, caller: "mcp-codex-mcp-client-1")
    let bundle = App.Bundle(
      version: Version(versionNumber: "1.1", buildNumber: nil), name: "Attach",
      bundleIdentifier: "test.attach", fileURL: URL(fileURLWithPath: path), source: .sparkle,
      modificationDate: Date())
    let history = UpdateHistoryStore(fileURL: historyURL)
    history.record(
      UpdateHistoryEntry(before: bundle, after: bundle, outcome: .updated(from: "1.0", to: "1.1")))
    let entry = history.latestEntry(for: bundle.fileURL)
    XCTAssertEqual(CallerName.display(entry?.caller), "Codex")
    XCTAssertEqual(entry?.followers, ["mcp-claude-code-2"], "listed once, starter not repeated")
    XCTAssertNil(AgentActivity.shared.job(for: path), "the finished job is cleared")
  }

  func testConfigureSetsAutoUpdateWithTheCaller() async throws {
    var apps = [app("Auto"), app("Handoff", install: false)]
    let prefs = AppPreferences(
      defaults: defaults,
      setIgnoredState: { on, target in
        apps = apps.map {
          $0.bundleIdentifier == target.bundleIdentifier ? $0.with(ignoredState: on) : $0
        }
      }, history: nil)
    let service = ControlService(
      .init(
        apps: { apps }, isChecking: { false }, initialCheckFinished: { true }, startCheck: { _ in },
        updateAllCandidates: { [] }, updateAll: {}, updating: RecordingUpdating(), history: nil,
        preferences: prefs))
    let on = await service.handle(
      ControlRequest(
        command: "set", args: ["target": apps[0].fileURL.path, "auto": "on"], caller: "mcp-codex-1")
    )
    XCTAssertTrue(on.ok, on.message ?? "")
    XCTAssertEqual(on.data?["autoUpdate"], .bool(true))
    XCTAssertEqual(prefs.change(.autoUpdate, for: apps[0])?.caller, "mcp-codex-1")

    let both = await service.handle(
      ControlRequest(
        command: "set", args: ["target": apps[0].bundleIdentifier, "ignore": "on"], caller: "cli-1")
    )
    XCTAssertEqual(both.data?["autoUpdate"], .bool(false), "ignore turned auto off")

    let refused = await service.handle(
      ControlRequest(
        command: "set", args: ["target": apps[1].fileURL.path, "auto": "on"], caller: "cli-1"))
    XCTAssertFalse(refused.ok)
    let usage = await service.handle(
      ControlRequest(command: "set", args: ["target": apps[0].fileURL.path], caller: "cli-1"))
    XCTAssertEqual(usage.code, "usage")
  }
}

// MARK: - Automatic jobs re-check before acting (review 1)

extension AutoUpdateTest {
  private func probe(_ name: String) -> ProbeOperation {
    ProbeOperation(
      bundleIdentifier: "test.auto.\(name)",
      appIdentifier: FileManager.default.temporaryDirectory.appendingPathComponent(
        "Probe-\(name)-\(UUID()).app"))
  }

  private func waitUntilFinished(_ operation: Operation) async {
    for _ in 0..<200 where !operation.isFinished { try? await Task.sleep(for: .milliseconds(10)) }
  }

  func testAutomaticJobThatIsNoLongerEligibleNeverStarts() async {
    let queue = UpdateQueue(history: UpdateHistoryStore(fileURL: historyURL))
    let stale = probe("Stale")
    let fresh = probe("Fresh")
    AutomaticUpdatePolicy.$current.withValue(AutomaticUpdatePolicy { false }) {
      _ = queue.submit(stale)
    }
    AutomaticUpdatePolicy.$current.withValue(AutomaticUpdatePolicy { true }) {
      _ = queue.submit(fresh)
    }
    await waitUntilFinished(stale)
    await waitUntilFinished(fresh)
    XCTAssertFalse(stale.executed, "opened, ignored or switched off since it was queued")
    XCTAssertTrue(stale.isCancelled)
    XCTAssertTrue(fresh.executed)
    XCTAssertNotNil(fresh.automaticPolicy, "the policy stays on the job")
  }

  func testAutomaticLifecycleDeclinesARunningAppWithoutAsking() async {
    final class Flags: @unchecked Sendable {
      var asked = false, terminated = false, installed = false
    }
    let flags = Flags()
    let lifecycle = AppLifecycle(
      runningApps: { _ in [.init(terminate: { flags.terminated = true }, isTerminated: { false })]
      },
      confirmQuit: { _ in
        flags.asked = true
        return true
      }, reopen: { _ in })
    let automatic = lifecycle.automatic(AutomaticUpdatePolicy { true })
    do {
      try await automatic.withApplicationClosed(at: URL(fileURLWithPath: "/tmp/X.app"), name: "X") {
        flags.installed = true
      }
      XCTFail("an automatic job must not quit a running app")
    } catch {}
    XCTAssertFalse(flags.asked, "no quit prompt for automatic updates")
    XCTAssertFalse(flags.terminated)
    XCTAssertFalse(flags.installed)
    // Ineligible right before installing (ignored or switched off) stops even when closed.
    let closed = AppLifecycle(
      runningApps: { _ in [] }, confirmQuit: { _ in true }, reopen: { _ in }
    )
    .automatic(AutomaticUpdatePolicy { false })
    do {
      _ = try await closed.quit(at: URL(fileURLWithPath: "/tmp/X.app"), name: "X")
      XCTFail("ineligible job must stop")
    } catch {}
  }

  func testSwitchingOffWithdrawsOnlyAutomaticJobs() async throws {
    let queue = UpdateQueue(history: UpdateHistoryStore(fileURL: historyURL))
    queue.isSuspended = true
    let automatic = probe("Auto")
    let asked = probe("Asked")
    AutomaticUpdatePolicy.$current.withValue(AutomaticUpdatePolicy { true }) {
      _ = queue.submit(automatic)
    }
    _ = queue.submit(asked)
    XCTAssertTrue(queue.withdrawAutomaticJob(for: automatic.appIdentifier))
    XCTAssertFalse(queue.withdrawAutomaticJob(for: asked.appIdentifier), "a requested job stays")
    XCTAssertTrue(automatic.isCancelled)
    XCTAssertFalse(asked.isCancelled)
    queue.isSuspended = false
    await waitUntilFinished(asked)
    XCTAssertTrue(asked.executed)
    XCTAssertFalse(automatic.executed)

    let prefs = preferences()
    var withdrawn = [String]()
    prefs.withdrawAutomatic = { withdrawn.append($0.name) }
    let chrome = app("Chrome")
    let notion = app("Notion")
    try prefs.set(.autoUpdate, true, for: chrome, caller: "gui")
    try prefs.set(.autoUpdate, true, for: notion, caller: "gui")
    let policy = prefs.policy(for: notion, isIgnored: { false }, isRunning: { _ in false })
    XCTAssertTrue(policy.stillEligible())
    try prefs.set(.ignore, true, for: chrome, caller: "gui")
    try prefs.set(.autoUpdate, false, for: notion, caller: "gui")
    XCTAssertEqual(withdrawn, ["Chrome", "Notion"])
    XCTAssertFalse(policy.stillEligible(), "switched off after queueing")
    XCTAssertFalse(
      prefs.policy(for: chrome, isIgnored: { true }, isRunning: { _ in false }).stillEligible())
  }
}

private final class ProbeOperation: UpdateOperation, @unchecked Sendable {
  private let ran = Mutex(false)
  var executed: Bool { ran.withLock { $0 } }
  override func execute() {
    ran.withLock { $0 = true }
    finish()
  }
}

private final class RecordingUpdating: AppUpdating, @unchecked Sendable {
  var bulk = [Bool]()
  func isUpdating(_ app: App) -> Bool { false }
  func update(_ app: App, isBulkUpdate: Bool) { bulk.append(isBulkUpdate) }
  func cancel(_ app: App) {}
  @MainActor func retryTermination(_ app: App) {}
  func state(for identifier: App.Bundle.Identifier) -> UpdateProgressState { .none }
  @MainActor func states(for identifier: App.Bundle.Identifier) -> AsyncStream<UpdateProgressState>
  {
    AsyncStream { $0.finish() }
  }
  @MainActor func stateChanges(for identifier: App.Bundle.Identifier) -> UpdateStateFeed {
    (.none, states(for: identifier))
  }
}

@MainActor
private final class StubCoordinator: UpdateCheckCoordinating {
  let appProvider: any AppProviding = AppDataStore(userDefaults: UserDefaults())  // never written
  var progressDelegate: (any UpdateCheckProgressReporting)?
  var checkCompletion: (@MainActor (UpdateCheckCompletion) -> Void)?
  func run(hardRefresh: Bool, origin: UpdateCheckOrigin) {}
}

@MainActor
private final class ReadyAppStore: AppStoreUpdateServicing {
  var alwaysUsesManualUpdates = false
  func verifyAvailability() throws(InstallHelperError) {}
}
