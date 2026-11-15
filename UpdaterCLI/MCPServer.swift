// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.
import Foundation
import CoreFoundation

/// Newline-delimited stdio transport; updates remain owned by the app after a call is cancelled.
final class MCPServer: @unchecked Sendable {
  private let lock = NSLock()
  private let pending = DispatchGroup()
  private var tasks: [String: Task<Void, Never>] = [:]
  private let caller = "mcp-" + UUID().uuidString

  static let instructions = "Updater manages installed Mac apps. Check, list, update, then use status with wait for jobs. A running app may need a person's quit confirmation; needsQuit is not a reason to retry automatically. Hand-offs open another app only when explicitly requested. Uninstall previews never delete; uninstall confirmation requires the user's approval of the exact plan. Cancelling a call stops waiting, not an update already accepted by the app."

  static var tools: [[String: Any]] {
    commands.map { command in
      let name = command.name == "set" ? "configure" : command.name
      var properties: [String: Any] = [:]
      for param in command.params {
        let key = param.name == "job" ? "jobId" : param.name == "updates" ? "updatesOnly" : param.name == "full" ? "fields" : param.name == "ignore" ? "ignored" : param.name
        var schema: [String: Any] = ["type": param.kind == .integer ? "integer" : param.kind == .switchFlag || key == "ignored" ? "boolean" : "string", "description": param.help]
        if let values = param.values, key != "ignored" { schema["enum"] = values }
        if key == "fields" { schema = ["type": "string", "enum": ["compact", "full"]] }
        if let minimum = param.minimum { schema["minimum"] = minimum }
        if let maximum = param.maximum { schema["maximum"] = maximum }
        properties[key] = schema
      }
      let readOnly = ["list", "status", "history", "uninstall_preview"].contains(name)
      return ["name": name, "description": command.summary,
        "inputSchema": ["type": "object", "properties": properties,
          "required": command.params.filter(\.required).map { $0.name == "ignore" ? "ignored" : $0.name }, "additionalProperties": false],
        "outputSchema": ["type": "object", "properties": ["ok": ["type": "boolean"], "data": ["type": "object"], "code": ["type": "string"], "message": ["type": "string"], "version": ["type": "integer"]], "required": ["ok", "version"]],
        "annotations": ["readOnlyHint": readOnly, "destructiveHint": name == "update", "idempotentHint": true, "openWorldHint": ["update", "check"].contains(name)]]
    }
  }

  static func run() {
    let server = MCPServer()
    while let line = readLine() { server.receive(line) }
    server.pending.wait()
  }

  private func send(_ object: [String: Any]) {
    lock.withLock {
      guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) else { return }
      FileHandle.standardOutput.write(data + Data([10]))
    }
  }

  private func receive(_ line: String) {
    guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
      request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
      send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Invalid JSON-RPC request"]]); return
    }
    let params = request["params"] as? [String: Any] ?? [:]
    if method == "notifications/cancelled" {
      if let id = params["requestId"] { lock.withLock { tasks[String(describing: id)]?.cancel() } }
      return
    }
    guard let id = request["id"], id is String || id is NSNumber else { return }
    func result(_ value: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": value]) }
    switch method {
    case "initialize":
      let version = params["protocolVersion"] as? String
      result(["protocolVersion": version == "2025-06-18" ? "2025-06-18" : "2025-11-25", "capabilities": ["tools": [:]], "serverInfo": ["name": "updater", "version": "1"], "instructions": Self.instructions])
    case "ping": result([:])
    case "tools/list": result(["tools": Self.tools])
    case "tools/call":
      guard let name = params["name"] as? String, let tool = Self.tools.first(where: { $0["name"] as? String == name }) else {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Unknown tool"]]); return
      }
      let schema = tool["inputSchema"] as! [String: Any]
      let arguments = params["arguments"] as? [String: Any] ?? [:]
      if (params["arguments"] != nil && !(params["arguments"] is [String: Any])) || !Self.valid(arguments, schema: schema) {
        result(Self.toolResult(.failure("invalid_arguments", "Arguments do not match the tool's inputSchema."))); return
      }
      var args: [String: String] = [:]
      for (key, value) in arguments {
        let wire = key == "jobId" ? "job" : key == "updatesOnly" ? "updates" : key == "fields" ? "full" : key == "ignored" ? "ignore" : key
        if key == "fields" { args[wire] = (value as? String == "full") ? "1" : "0" }
        else if key == "ignored" { args[wire] = (value as? Bool == true) ? "on" : "off" }
        else { args[wire] = String(describing: value) }
      }
      let requestID = String(describing: id)
      let rpcID = (try! JSONSerialization.data(withJSONObject: [id], options: [.fragmentsAllowed]))
      let control = ControlRequest(id: requestID, command: name == "configure" ? "set" : name, args: args, caller: caller)
      pending.enter()
      // Register under the lock before the task can complete or cancellation can arrive.
      lock.withLock {
        tasks[requestID] = Task.detached { [self] in
          defer { lock.withLock { tasks[requestID] = nil }; pending.leave() }
          let response: ControlResponse
          do { response = try ControlClient.send(control, to: ControlPaths.socket, timeout: 55) }
          catch let error as ControlError {
            if error.code == "app_not_running", ProcessInfo.processInfo.environment["UPDATER_HOME"] == nil {
              do { response = try launchAndSend(control, timeout: 55) }
              catch let launchError as ControlError { response = .failure(launchError.code, launchError.message) }
              catch { response = .failure("failed", String(describing: error)) }
            } else { response = .failure(error.code, error.message) }
          }
          catch { response = .failure("failed", String(describing: error)) }
          guard !Task.isCancelled else { return }
          let id = (try! JSONSerialization.jsonObject(with: rpcID) as! [Any])[0]
          send(["jsonrpc": "2.0", "id": id, "result": Self.toolResult(response)])
        }
      }
    default: send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
    }
  }

  private static func valid(_ arguments: [String: Any], schema: [String: Any]) -> Bool {
    let properties = schema["properties"] as! [String: [String: Any]]
    guard (schema["required"] as! [String]).allSatisfy({ arguments[$0] != nil }) else { return false }
    for (key, value) in arguments {
      guard let property = properties[key] else { return false }
      switch property["type"] as? String {
      case "boolean": guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return false }
      case "integer":
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue else { return false }
        if let min = property["minimum"] as? Int, n.doubleValue < Double(min) { return false }
        if let max = property["maximum"] as? Int, n.doubleValue > Double(max) { return false }
      default:
        guard let s = value as? String, !s.isEmpty else { return false }
        if let values = property["enum"] as? [String], !values.contains(s) { return false }
      }
    }
    return true
  }

  private static func toolResult(_ response: ControlResponse) -> [String: Any] {
    let data = try! JSONEncoder().encode(response)
    return ["structuredContent": try! JSONSerialization.jsonObject(with: data), "isError": !response.ok,
      "content": [["type": "text", "text": response.message ?? (response.ok ? "Request completed." : "Request failed.")]]]
  }
}
