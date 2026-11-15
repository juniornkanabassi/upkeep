// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

enum BlackmagicCatalogue {
  static let downloadPage = URL(string: "https://www.blackmagicdesign.com/support/")!

  static func product(for bundle: App.Bundle) -> String? {
    if bundle.bundleIdentifier == "com.blackmagic-design.DaVinciResolve"
      || bundle.bundleIdentifier == "com.blackmagic-design.DaVinciResolveStudio" {
      return "davinci-resolve"
    }
    if bundle.bundleIdentifier == "com.blackmagic-design.desktopvideo.utility"
      || bundle.name == "Desktop Video Setup" || bundle.parent == "Blackmagic Desktop Video" {
      return "desktop-video"
    }
    return nil
  }

  static func version(from data: Data) throws -> Version {
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let mac = json?["mac"] as? [String: Any],
      let major = mac["major"] as? Int, let minor = mac["minor"] as? Int,
      let patch = mac["releaseNum"] as? Int, major >= 0, minor >= 0, patch >= 0 else {
      throw LatestError.updateInfoUnavailable
    }
    return Version(versionNumber: "\(major).\(minor).\(patch)",
      buildNumber: nil)
  }

  static func update(for bundle: App.Bundle) async throws -> App.Update? {
    guard let product = product(for: bundle) else { return nil }
    var request = URLRequest(url: URL(string:
      "https://www.blackmagicdesign.com/api/support/latest-stable-version/\(product)/mac")!)
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw LatestError.updateInfoUnavailable
    }
    return App.Update(app: bundle, remoteVersion: try version(from: data),
      minimumOSVersion: nil, source: .vendor, date: nil, releaseNotes: nil,
      updateAction: .external(label: "Blackmagic downloads") { _ in
        Task { @MainActor in MacApplicationWorkspace.shared.open(downloadPage) }
      })
  }
}
