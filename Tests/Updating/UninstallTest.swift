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
    }, removeAdmin: { _ in XCTFail("fixture must not request admin") }, bootout: { _, _ in })
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
    let service = UninstallService(planner: planner, history: nil, logURL: root.appendingPathComponent("log"), trash: { _ in moved += 1 }, removeAdmin: { _ in XCTFail() }, bootout: { _, _ in })
    let token = try XCTUnwrap(service.preview(app: app, withData: false, caller: "owner")["token"]?.stringValue)
    do { _ = try await service.confirm(token: token, app: nil, withData: true, caller: "owner"); XCTFail("selection") } catch {}
    try FileManager.default.moveItem(at: cache, to: root.appendingPathComponent("old-cache"))
    try file(cache)
    do { _ = try await service.confirm(token: token, app: nil, withData: false, caller: "owner"); XCTFail("inode") } catch {}
    XCTAssertEqual(moved, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
  }
}
