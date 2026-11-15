// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.
import XCTest
import Darwin
@testable import Latest

@MainActor
final class UninstallTest: XCTestCase {
  private func fixture(name: String = "Example", id: String = "com.example.clean") throws -> (URL, URL, UninstallPlanner) {
    let temporary = try disposableDirectory()
    let resolved = realpath(temporary.path, nil)!
    defer { free(resolved) }
    let root = URL(fileURLWithPath: String(cString: resolved))
    let app = try FixtureApp.make(in: root, name: name, identifier: id, version: "1", signed: false)
    let planner = UninstallPlanner(home: root.appendingPathComponent("home"), systemLibrary: root.appendingPathComponent("Library"), copies: { _ in [app.path] }, isRunning: { _ in false })
    return (root, app, planner)
  }

  private func file(_ path: URL, data: Data = Data("fixture".utf8)) throws {
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: path)
  }

  func testExactPathsPersonalDataAndByHostBoundary() throws {
    let (_, app, planner) = try fixture()
    let lib = planner.home.appendingPathComponent("Library")
    for path in ["Caches/com.example.clean", "Application Support/com.example.clean", "Preferences/ByHost/com.example.clean.ABC.plist", "Preferences/ByHost/com.example.cleaner.ABC.plist", "Caches/unrelated"] { try file(lib.appendingPathComponent(path)) }
    let plan = try planner.plan(app: app, withData: false)
    XCTAssertEqual(plan.items.count, 4)
    XCTAssertEqual(plan.items.first { $0.personalData }?.selected, false)
    XCTAssertFalse(plan.items.contains { $0.path.contains("cleaner") })
    XCTAssertTrue(try planner.plan(app: app, withData: true).items.allSatisfy(\.selected))
  }

  func testContainersRequireExactMetadataNotSubstring() throws {
    let (_, app, planner) = try fixture()
    let root = planner.home.appendingPathComponent("Library/Group Containers")
    for (leaf, id) in [("owned", "com.example.clean"), ("com.example.clean.fake", "com.example.other"), ("substring", "com.example.clean.extension")] {
      let data = try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": id], format: .xml, options: 0)
      try file(root.appendingPathComponent(leaf + "/.com.apple.containermanagerd.metadata.plist"), data: data)
    }
    let plan = try planner.plan(app: app, withData: false)
    XCTAssertEqual(plan.items.filter(\.personalData).count, 1)
    XCTAssertTrue(plan.items.contains { $0.path.hasSuffix("/owned") })
  }

  func testCreatorAndGroupIdentityNeverClaimContainerEvenAtExactPath() throws {
    let (_, app, planner) = try fixture()
    for directory in ["Containers", "Group Containers"] {
      for (leaf, metadata) in [
        ("com.example.clean", ["MCMMetadataIdentifier": "group.shared", "MCMMetadataCreator": "com.example.clean"]),
        ("creator-only", ["MCMMetadataCreator": "com.example.clean"]),
        ("nested", ["Nested": ["MCMMetadataIdentifier": "com.example.clean"]]),
        ("exclusive", ["MCMMetadataIdentifier": "com.example.clean"])
      ] as [(String, [String: Any])] {
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try file(planner.home.appendingPathComponent("Library/" + directory + "/" + leaf + "/.com.apple.containermanagerd.metadata.plist"), data: data)
      }
    }
    let plan = try planner.plan(app: app, withData: true)
    XCTAssertEqual(plan.items.filter(\.personalData).count, 2)
    XCTAssertTrue(plan.items.filter(\.personalData).allSatisfy { $0.path.hasSuffix("/exclusive") })
  }

  func testProtectedIdentitiesOutsideApplications() throws {
    for id in ["com.juniornkanabassi.VideoPrompter", "com.apple.Example"] {
      let (_, app, planner) = try fixture(id: id)
      XCTAssertThrowsError(try planner.plan(app: app, withData: true)) {
        XCTAssertEqual(($0 as? ControlError)?.code, "protected_app")
      }
    }
    let (root, app, original) = try fixture()
    var planner = original
    planner.isAppleSigned = { _ in true }
    XCTAssertThrowsError(try planner.plan(app: app, withData: true))
    // Preserve Apple's signature in a disposable copy, without touching a real app.
    let signed = root.appendingPathComponent("apple-binary")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: signed)
    XCTAssertTrue(UninstallPlanner.appleSigned(signed))
    XCTAssertFalse(UninstallPlanner.appleSigned(app))
  }

  func testRunningAfterLaunchAgentUnloadPreventsMove() async throws {
    let (root, app, original) = try fixture()
    try file(original.home.appendingPathComponent("Library/LaunchAgents/com.example.clean.plist"))
    var running = false
    let planner = UninstallPlanner(home: original.home, systemLibrary: original.systemLibrary,
      copies: { _ in [app.path] }, isRunning: { _ in running })
    var moved = 0
    let service = UninstallService(planner: planner, history: nil, logURL: root.appendingPathComponent("log"),
      trash: { _ in moved += 1 }, removeAdmin: { _, _ in XCTFail() }, bootout: { _, _ in running = true })
    let token = try XCTUnwrap(service.preview(app: app, withData: false, caller: "test")["token"]?.stringValue)
    let result = try await service.confirm(token: token, app: nil, withData: nil, caller: "test")
    XCTAssertEqual(moved, 0)
    XCTAssertEqual(result["ok"], .bool(false))
    XCTAssertTrue(result["results"]!.arrayValue!.allSatisfy { $0.objectValue?["status"] == "failed" })
  }

  func testPrivilegedShellRechecksRunningAfterPromptAndBeforeEachMove() throws {
    for startsAfterFirstMove in [false, true] {
      let (root, app, planner) = try fixture()
      let cache = planner.home.appendingPathComponent("Library/Caches/com.example.clean")
      try file(cache)
      let plan = try planner.plan(app: app, withData: false)
      let trash = root.appendingPathComponent("trash")
      try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
      let running = root.appendingPathComponent("running")
      let ps = root.appendingPathComponent("ps")
      try file(ps, data: Data(("#!/bin/sh\nif [ -f '" + running.path + "' ]; then printf '%s\\n' '" + app.path + "/Contents/MacOS/Example'; fi\n").utf8))
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ps.path)
      let mv = root.appendingPathComponent("mv")
      try file(mv, data: Data(("#!/bin/sh\n/bin/mv \"$@\"\n/usr/bin/touch '" + running.path + "'\n").utf8))
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mv.path)
      if !startsAfterFirstMove { try file(running) }
      let shell = UninstallService.administratorShell(plan.items.filter(\.selected), target: app, trash: trash)
        .replacingOccurrences(of: "/bin/ps", with: ps.path)
        .replacingOccurrences(of: "/bin/mv", with: mv.path)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", shell]
      try process.run(); process.waitUntilExit()
      XCTAssertNotEqual(process.terminationStatus, 0)
      XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
      XCTAssertEqual(FileManager.default.fileExists(atPath: cache.path), !startsAfterFirstMove)
    }
  }

  func testAdministratorFailureRetainsPartialItemDetails() async throws {
    for removedCount in 0...2 {
      let (root, app, original) = try fixture()
      try file(original.home.appendingPathComponent("Library/Caches/com.example.clean"))
      var planner = original
      planner.uid = getuid() + 1 // Mark only disposable fixtures as administrator-owned.
      let service = UninstallService(planner: planner, history: nil, logURL: root.appendingPathComponent("log"),
        trash: { _ in XCTFail() }, removeAdmin: { items, target in
          XCTAssertEqual(target.path, app.path)
          for (index, item) in items.sorted(by: { $0.kind != .app && $1.kind == .app }).prefix(removedCount).enumerated() {
            try FileManager.default.moveItem(atPath: item.path, toPath: root.appendingPathComponent("moved-\(index)").path)
          }
          throw CancellationError()
        })
      let token = try XCTUnwrap(service.preview(app: app, withData: false, caller: "test")["token"]?.stringValue)
      let outcome = try await service.confirm(token: token, app: nil, withData: nil, caller: "test")
      XCTAssertEqual(outcome["ok"], .bool(false))
      let results = try XCTUnwrap(outcome["results"]?.arrayValue)
      XCTAssertEqual(results.count, 2)
      XCTAssertEqual(results.filter { $0.objectValue?["status"] == "removed" }.count, removedCount)
      XCTAssertEqual(FileManager.default.fileExists(atPath: app.path), removedCount < 2)
    }
  }

  func testCommonNamesNeverClaimNameDerivedData() throws {
    let (_, app, planner) = try fixture(name: "Music")
    try file(planner.home.appendingPathComponent("Library/Application Support/Music"))
    XCTAssertEqual(try planner.plan(app: app, withData: true).items.count, 1)
  }

  func testSiblingNarrowsToAppAndRunningProtectedAppsRefused() throws {
    let (_, app, planner) = try fixture()
    var siblings = planner
    siblings = UninstallPlanner(home: planner.home, systemLibrary: planner.systemLibrary, copies: { _ in [app.path, "/elsewhere/Example.app"] }, isRunning: { _ in false })
    try file(planner.home.appendingPathComponent("Library/Caches/com.example.clean"))
    let plan = try siblings.plan(app: app, withData: true)
    XCTAssertTrue(plan.siblingCopies)
    XCTAssertEqual(plan.items.count, 1)
    let running = UninstallPlanner(home: planner.home, systemLibrary: planner.systemLibrary, copies: { _ in [] }, isRunning: { _ in true })
    XCTAssertThrowsError(try running.plan(app: app, withData: false))
    let (_, own, ownPlanner) = try fixture(id: "com.juniornkanabassi.Updater")
    XCTAssertThrowsError(try ownPlanner.plan(app: own, withData: true))
  }

  func testSymlinkAndReplacedInodeAreRefused() throws {
    let (root, app, planner) = try fixture()
    let cache = planner.home.appendingPathComponent("Library/Caches")
    try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: root)
    try file(root.appendingPathComponent("com.example.clean"))
    let plan = try planner.plan(app: app, withData: true)
    XCTAssertEqual(plan.items.count, 1)
    let item = try XCTUnwrap(plan.items.first)
    try FileManager.default.moveItem(at: app, to: root.appendingPathComponent("old.app"))
    _ = try FixtureApp.make(in: root, name: "Example", identifier: "com.example.clean", version: "1", signed: false)
    XCTAssertThrowsError(try planner.validate(item))
  }

  func testTokenBindingExpiryAndSingleUseTrashHistory() async throws {
    let (root, app, planner) = try fixture()
    let trash = root.appendingPathComponent("fake-trash")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let history = UpdateHistoryStore(fileURL: root.appendingPathComponent("history"))
    let service = UninstallService(planner: planner, history: history, logURL: root.appendingPathComponent("uninstall.log"), trash: {
      try FileManager.default.moveItem(at: $0, to: trash.appendingPathComponent($0.lastPathComponent))
    }, removeAdmin: { _, _ in XCTFail("fixture must not request admin") }, bootout: { _, _ in })
    let token = try XCTUnwrap(service.preview(app: app, withData: false, caller: "owner")["token"]?.stringValue)
    do { _ = try await service.confirm(token: token, app: nil, withData: nil, caller: "other"); XCTFail("caller") } catch {}
    let result = try await service.confirm(token: token, app: app, withData: false, caller: "owner")
    XCTAssertEqual(result["results"]?.arrayValue?.first?.objectValue?["status"], "removed")
    XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
    XCTAssertEqual(history.entries(limit: 1).first?.outcome, .uninstalled)
    XCTAssertTrue(try String(contentsOf: service.logURL, encoding: .utf8).contains("TRASHED"))
    do { _ = try await service.confirm(token: token, app: nil, withData: nil, caller: "owner"); XCTFail("single use") } catch {}
    _ = try FixtureApp.make(in: root, name: "Example", identifier: "com.example.clean", version: "1", signed: false)
    let expired = try XCTUnwrap(service.preview(app: app, withData: false, caller: "owner")["token"]?.stringValue)
    service.now = { Date().addingTimeInterval(601) }
    do { _ = try await service.confirm(token: expired, app: nil, withData: nil, caller: "owner"); XCTFail("expiry") } catch {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
  }

  func testChangedPathPreventsEveryRemovalAndSelectionCannotExpand() async throws {
    let (root, app, planner) = try fixture()
    let cache = planner.home.appendingPathComponent("Library/Caches/com.example.clean")
    try file(cache)
    var moved = 0
    let service = UninstallService(planner: planner, history: nil, logURL: root.appendingPathComponent("log"), trash: { _ in moved += 1 }, removeAdmin: { _, _ in XCTFail() }, bootout: { _, _ in })
    let token = try XCTUnwrap(service.preview(app: app, withData: false, caller: "owner")["token"]?.stringValue)
    do { _ = try await service.confirm(token: token, app: nil, withData: true, caller: "owner"); XCTFail("selection") } catch {}
    try FileManager.default.moveItem(at: cache, to: root.appendingPathComponent("old-cache"))
    try file(cache)
    do { _ = try await service.confirm(token: token, app: nil, withData: false, caller: "owner"); XCTFail("inode") } catch {}
    XCTAssertEqual(moved, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
  }
}
