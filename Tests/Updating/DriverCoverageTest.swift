// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation
import XCTest
@testable import Latest

final class DriverCoverageTest: XCTestCase {
  private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  private func bundle(_ url: URL, id: String, version: String) throws {
    let contents = url.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: [
      "CFBundleIdentifier": id, "CFBundleName": url.deletingPathExtension().lastPathComponent,
      "CFBundleShortVersionString": version,
    ], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
  }

  private func installer(_ url: URL, version: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(fromPropertyList: [
      "CFBundleExecutable": "arkinstaller", "CFBundleShortVersionString": version,
    ], format: .xml, options: 0)
    // Harmless stand-in binary data. Tests inject execution separately.
    try (Data([0xca, 0xfe, 0xba, 0xbe]) + plist).write(to: url)
  }

  func testDiscoversDriversAndAssociatesActiveExtensionWithHost() throws {
    let root = try root()
    let appURL = root.appendingPathComponent("Camera.app")
    try bundle(appURL, id: "com.test.Camera", version: "3.0")
    try bundle(appURL.appendingPathComponent("Contents/Library/SystemExtensions/Camera.systemextension"),
      id: "com.test.Camera.extension", version: "1.1")
    try bundle(root.appendingPathComponent("SystemExtensions/UUID/Camera.systemextension"),
      id: "com.test.Camera.extension", version: "1.1")
    let activeURL = root.appendingPathComponent("SystemExtensions/UUID/Camera.systemextension")
    try bundle(root.appendingPathComponent("SystemExtensions/OLD/Camera.systemextension"),
      id: "com.test.Camera.extension", version: "0.9")
    try PropertyListSerialization.data(fromPropertyList: ["extensions": [
      ["state": "activated_enabled", "stagedBundleURL": ["relative": activeURL.absoluteString]],
      ["state": "terminated_waiting_to_uninstall_on_reboot", "stagedBundleURL":
        ["relative": root.appendingPathComponent("SystemExtensions/OLD/Camera.systemextension").absoluteString]],
    ]], format: .xml, options: 0).write(to: root.appendingPathComponent("SystemExtensions/db.plist"))
    try bundle(root.appendingPathComponent("Extensions/Legacy.kext"), id: "com.test.Legacy", version: "2.0")
    try bundle(root.appendingPathComponent("Audio/Plug-Ins/HAL/Test.driver"), id: "com.test.Audio", version: "4.0")
    let rows = DriverDiscovery.collect(apps: [try XCTUnwrap(BundleCollector.collectBundle(at: appURL))], library: root)
    XCTAssertEqual(rows.count, 3)
    XCTAssertTrue(rows.allSatisfy { $0.kind == .driver })
    let camera = try XCTUnwrap(rows.first { $0.bundleIdentifier == "com.test.Camera.extension" })
    XCTAssertEqual(camera.parent, "Camera")
    XCTAssertEqual(camera.version.versionNumber, "3.0")
    XCTAssertEqual(camera.hostURL, appURL)
    XCTAssertEqual(camera.note, "Updates with Camera")
    XCTAssertTrue(try XCTUnwrap(rows.first { $0.name == "Legacy" }?.note).contains("Legacy"))
  }

  func testNewestARKAndConflictingEmbeddedVersions() throws {
    let root = try root()
    var apps = [App.Bundle]()
    for (name, version) in [("SoundSource", "13.6.0"), ("Loopback", "13.5.6")] {
      let url = root.appendingPathComponent(name + ".app")
      try bundle(url, id: "com.rogueamoeba." + name, version: "1.0")
      try installer(url.appendingPathComponent("Contents/Resources/arkinstaller"), version: version)
      apps.append(try XCTUnwrap(BundleCollector.collectBundle(at: url)))
    }
    XCTAssertEqual(DriverDiscovery.newestARK(in: apps)?.version, "13.6.0")
    let tool = try XCTUnwrap(DriverDiscovery.newestARK(in: apps)?.tool)
    let other = root.appendingPathComponent("other")
    try installer(other, version: "14.0")
    try (Data(contentsOf: tool) + Data(contentsOf: other)).write(to: tool)
    XCTAssertNil(DriverDiscovery.arkVersion(at: tool))
  }

  func testARKQueueVerifiesChangedDriverOnDisk() async throws {
    let root = try root()
    let driver = root.appendingPathComponent("ARK.driver")
    let tool = root.appendingPathComponent("arkinstaller")
    try bundle(driver, id: "com.rogueamoeba.ARK.driver", version: "1.0")
    try installer(tool, version: "2.0")
    let before = try XCTUnwrap(DriverDiscovery.read(at: driver))
    let payload = try PropertyListSerialization.data(fromPropertyList: [
      "CFBundleIdentifier": "com.rogueamoeba.ARK.driver", "CFBundleName": "ARK",
      "CFBundleShortVersionString": "2.0",
    ], format: .xml, options: 0)
    let operation = ARKUpdateOperation(app: before, tool: tool,
      version: Version(versionNumber: "2.0", buildNumber: nil)) { _ in
        try payload.write(to: driver.appendingPathComponent("Contents/Info.plist"))
      }
    let done = expectation(description: "updated")
    operation.completionBlock = { done.fulfill() }
    let queue = UpdateQueue()
    queue.addOperation(operation)
    await fulfillment(of: [done], timeout: 5)
    XCTAssertEqual(operation.resolvedOutcome, .updated(from: "1.0", to: "2.0"))
  }

  func testARKNoChangeAndChangedInstallerFailWithoutFalseSuccess() async throws {
    let root = try root()
    let driver = root.appendingPathComponent("ARK.driver")
    let tool = root.appendingPathComponent("arkinstaller")
    try bundle(driver, id: "com.rogueamoeba.ARK.driver", version: "1.0")
    try installer(tool, version: "2.0")
    for changed in [false, true] {
      if changed { try installer(tool, version: "3.0") }
      let operation = ARKUpdateOperation(app: try XCTUnwrap(DriverDiscovery.read(at: driver)),
        tool: tool, version: Version(versionNumber: "2.0", buildNumber: nil)) { _ in
          if changed { XCTFail("Must not run a changed installer") }
        }
      let done = expectation(description: "failed")
      operation.completionBlock = { done.fulfill() }
      let queue = UpdateQueue()
      queue.addOperation(operation)
      await fulfillment(of: [done], timeout: 5)
      guard case .failed = operation.resolvedOutcome else { return XCTFail("Must fail") }
    }
  }

  func testRealInstallerRefusesNonSystemTargetBeforePrompt() async throws {
    let root = try root()
    let driver = root.appendingPathComponent("ARK.driver")
    try bundle(driver, id: "com.rogueamoeba.ARK.driver", version: "1.0")
    let operation = ARKUpdateOperation(app: try XCTUnwrap(DriverDiscovery.read(at: driver)),
      tool: root.appendingPathComponent("unused"),
      version: Version(versionNumber: "2.0", buildNumber: nil))
    let done = expectation(description: "refused")
    operation.completionBlock = { done.fulfill() }
    let queue = UpdateQueue()
    queue.addOperation(operation)
    await fulfillment(of: [done], timeout: 5)
    XCTAssertTrue(operation.error?.localizedDescription.contains("only updates the system") == true)
  }

  func testAdminScriptQuotesPathAndValidatesPrivilegedCopy() {
    let script = ARKUpdateOperation.administratorScript(tool: URL(fileURLWithPath: "/tmp/a'\"b/arkinstaller"))
    XCTAssertTrue(script.contains("with administrator privileges"))
    XCTAssertTrue(script.contains("7266XEXAPM"))
    XCTAssertTrue(script.contains("codesign --verify --strict --all-architectures"))
    XCTAssertTrue(script.contains("install --silent"))
    XCTAssertFalse(script.contains("sudo"))
    XCTAssertEqual(ARKUpdateOperation.shellQuote("a'b"), "'a'\\''b'")
  }

  func testARKRequirementArgumentExecutesSignedFixture() throws {
    let root = try root()
    let tool = root.appendingPathComponent("arkinstaller")
    let source = root.appendingPathComponent("fixture.c")
    try Data("int main(void) { return 0; }".utf8).write(to: source)
    func run(_ executable: String, _ args: [String]) throws -> Int32 {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = args
      try process.run(); process.waitUntilExit()
      return process.terminationStatus
    }
    XCTAssertEqual(try run("/usr/bin/clang", [source.path, "-o", tool.path]), 0)
    XCTAssertEqual(try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "ark-fixture", tool.path]), 0)
    // Use the production shell with a fixture identity; no admin prompt or driver installation.
    let shell = ARKUpdateOperation.administratorShell(tool: tool, requirement: "identifier \"ark-fixture\"")
    XCTAssertEqual(try run("/bin/sh", ["-c", shell]), 0)
    XCTAssertNotEqual(try run("/bin/sh", ["-c", ARKUpdateOperation.administratorShell(tool: tool)]), 0)
  }

  func testBlackmagicCatalogueParsesVersionAndRejectsMissingFields() throws {
    let version = try BlackmagicCatalogue.version(from: Data(#"{"mac":{"major":16,"minor":5,"releaseNum":0}}"#.utf8))
    XCTAssertEqual(version.versionNumber, "16.5.0")
    let newer = try BlackmagicCatalogue.version(from:
      Data(#"{"mac":{"major":22,"minor":0,"releaseNum":0,"build":3}}"#.utf8))
    XCTAssertEqual(Version(versionNumber: "21.2.0", buildNumber: "21.2.0.0006")
      .comparisonForUpdate(to: newer), .older)
    XCTAssertThrowsError(try BlackmagicCatalogue.version(from: Data(#"{"mac":{"major":16}}"#.utf8)))
  }

  func testHelpersHaveParentAndCannotUpdateIndependently() {
    for (path, id, parent) in [
      ("/tmp/Blackmagic ATEM Switchers/SwitcherPanel.app", "sample", "Blackmagic ATEM Switchers"),
      ("/tmp/DaVinci Resolve/Uninstall Resolve.app", "uninstall", "DaVinci Resolve"),
      ("/tmp/Utilities/Creative Cloud Uninstaller.app", "adobe", "Adobe Creative Cloud"),
      ("/tmp/Google Docs.app", "com.google.drivefs.shortcuts.docs", "Google Drive"),
    ] {
      XCTAssertEqual(CompanionGrouping.parent(at: URL(fileURLWithPath: path), identifier: id), parent)
      let bundle = App.Bundle(version: Version(versionNumber: "1.0", buildNumber: nil),
        name: "Helper", bundleIdentifier: id, fileURL: URL(fileURLWithPath: path), source: .none, parent: parent)
      let update = App.Update(app: bundle, remoteVersion: Version(versionNumber: "2.0", buildNumber: nil),
        minimumOSVersion: nil, source: .vendor, date: nil, releaseNotes: nil, updateAction: .builtIn { _ in })
      let app = App(bundle: bundle, update: .success(update), isIgnored: false)
      XCTAssertEqual(app.capability, .unsupported)
      XCTAssertFalse(app.isActionable)
    }
  }

  @MainActor
  func testUnsupportedDriversAndCompanionsDoNotPolluteSummary() async throws {
    let driver = App.Bundle(version: Version(versionNumber: "1.0", buildNumber: nil),
      name: "Legacy", bundleIdentifier: "com.test.Legacy", fileURL: URL(fileURLWithPath: "/tmp/Legacy.kext"),
      source: .driver, kind: .driver, note: "Legacy kernel extension; no supported update source.")
    let app = App(bundle: driver, update: .success(try await DriverUpdates.check(driver)), isIgnored: false)
    XCTAssertNil(app.error)
    XCTAssertEqual(app.capability, .unsupported)
    XCTAssertEqual(app.updateStatus, .current)
    XCTAssertEqual(UpdateStatusSummary(apps: [app]).couldNotCheck, 0)
    XCTAssertTrue(app.routeShortDescription.contains("Legacy"))
  }

  func testUnreadableARKInstallerFailsCheck() async throws {
    let root = try root()
    let driver = App.Bundle(version: Version(versionNumber: "1.0", buildNumber: nil),
      name: "ARK", bundleIdentifier: "com.rogueamoeba.ARK.driver", fileURL: root.appendingPathComponent("ARK.driver"),
      source: .driver, kind: .driver, companionToolURL: root.appendingPathComponent("missing"))
    do {
      _ = try await DriverUpdates.check(driver)
      XCTFail("Unreadable installer must not claim current")
    } catch { XCTAssertTrue(error.localizedDescription.contains("could not be read")) }
  }

  func testConsentProbeHasTotalTransferDeadline() {
    let configuration = SparkleUpdateCheckerOperation.consentProbeConfiguration()
    XCTAssertEqual(configuration.timeoutIntervalForResource, SparkleUpdateCheckerOperation.checkTimeout)
    XCTAssertEqual(configuration.timeoutIntervalForRequest, SparkleUpdateCheckerOperation.checkTimeout)
  }

  func testHTMLConsentAndXMLFeedAreDistinguished() {
    let url = URL(string: "https://instagram.com/privacy/checks/")!
    XCTAssertTrue(SparkleUpdateCheckerOperation.isWebPage(data: Data(),
      response: URLResponse(url: url, mimeType: "text/html", expectedContentLength: 0, textEncodingName: nil)))
    let response = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
    XCTAssertTrue(SparkleUpdateCheckerOperation.isWebPage(data: Data(" <!DOCTYPE html>".utf8), response: response))
    XCTAssertFalse(SparkleUpdateCheckerOperation.isWebPage(data: Data("<?xml version=\"1.0\"?><rss/>".utf8), response: response))
  }

  /// Screen 09: driver details say where each version came from.
  @MainActor
  func testDriverVersionProvenance() {
    func driver(_ vendor: String?, parent: String? = nil, host: URL? = nil, tool: URL? = nil) -> App {
      let bundle = App.Bundle(
        version: Version(versionNumber: "16.4", buildNumber: nil), name: "Driver",
        bundleIdentifier: "test.driver", fileURL: URL(fileURLWithPath: "/Library/Extensions/D.kext"),
        source: .driver, modificationDate: Date(timeIntervalSince1970: 0), kind: .driver,
        parent: parent, vendor: vendor, hostURL: host, companionToolURL: tool)
      return App(bundle: bundle, update: nil, isIgnored: false)
    }
    let blackmagic = driver("Blackmagic Design", parent: "Blackmagic Desktop Video")
    XCTAssertEqual(blackmagic.installedProvenance, "from the Blackmagic Desktop Video install record on this Mac")
    XCTAssertEqual(blackmagic.availableProvenance, "from Blackmagic's online download list")
    let ark = driver("Rogue Amoeba", tool: URL(fileURLWithPath: "/Applications/SoundSource.app/Contents/Resources/arkinstaller"))
    XCTAssertEqual(ark.availableProvenance, "from the ARK installer inside SoundSource")
    XCTAssertEqual(ark.installedProvenance, "from the driver on this Mac")
    let hosted = driver(nil, host: URL(fileURLWithPath: "/Applications/Camera Hub.app"))
    XCTAssertEqual(hosted.installedProvenance, "from Camera Hub on this Mac")
    XCTAssertNil(driver(nil).availableProvenance, "no update source, nothing claimed")
  }
}
