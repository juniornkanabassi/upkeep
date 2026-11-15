// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Combine
import Foundation
import Synchronization

/// Who asked for each running update. One job per app: a second identical request attaches to
/// the running job as a follower and gets the same result. History takes the names when the job
/// records its outcome, so the window, menu bar and history all say who started what.
final class AgentActivity: ObservableObject, Sendable {
  static let shared = AgentActivity()

  struct Request: Equatable, Sendable {
    /// The raw control caller (`mcp-claude-code-…`, `cli-123`, `upkeep`, `gui`).
    let caller: String
    let date: Date
  }

  struct Job: Equatable, Sendable {
    let starter: Request
    var followers: [Request] = []
  }

  private let jobs = Mutex<[String: Job]>([:])

  func started(_ path: String, by caller: String, at date: Date = Date()) {
    jobs.withLock { $0[path] = Job(starter: Request(caller: caller, date: date)) }
    changed()
  }

  /// A request for an app that is already updating. The starter and repeat callers are not
  /// listed twice.
  func attach(_ path: String, caller: String, at date: Date = Date()) {
    jobs.withLock { jobs in
      var job = jobs[path] ?? Job(starter: Request(caller: "gui", date: date))
      guard job.starter.caller != caller, !job.followers.contains(where: { $0.caller == caller })
      else { return }
      job.followers.append(Request(caller: caller, date: date))
      jobs[path] = job
    }
    changed()
  }

  func job(for path: String) -> Job? { jobs.withLock { $0[path] } }

  /// Removes and returns the callers of a job that has just recorded its outcome.
  func finish(_ path: String) -> Job? {
    let job = jobs.withLock { $0.removeValue(forKey: path) }
    if job != nil { changed() }
    return job
  }

  private func changed() {
    DispatchQueue.main.async { self.objectWillChange.send() }
  }
}

/// Plain names for control callers, shared by the window, menu bar and history.
enum CallerName {
  /// The person at the window: their first name, as History shows "Junior, 14:20".
  static var person: String {
    NSFullUserName().split(separator: " ").first.map(String.init) ?? "You"
  }

  static func display(_ caller: String?) -> String {
    guard let caller, caller != "gui" else { return person }
    let lower = caller.lowercased()
    if lower.contains("claude") { return "Claude" }
    if lower.contains("codex") { return "Codex" }
    if lower == "upkeep" { return "Upkeep" }
    if lower.hasPrefix("cli") { return "The command line" }
    return "An agent"
  }

  /// Agents are anyone but the person at the window and Upkeep's own automatic updates.
  static func isAgent(_ caller: String?) -> Bool {
    guard let caller else { return false }
    return caller != "gui" && caller.lowercased() != "upkeep"
  }
}
