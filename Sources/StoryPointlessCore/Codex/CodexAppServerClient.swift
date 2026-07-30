import Foundation

public struct CodexConnectionInfo: Equatable, Sendable {
  public let userAgent: String
  public let codexHome: String
  public let platformFamily: String
  public let platformOS: String

  public init(userAgent: String, codexHome: String, platformFamily: String, platformOS: String) {
    self.userAgent = userAgent
    self.codexHome = codexHome
    self.platformFamily = platformFamily
    self.platformOS = platformOS
  }
}

public struct CodexReasoningEffortOption: Identifiable, Equatable, Sendable {
  public let id: String
  public let description: String

  public init(id: String, description: String) {
    self.id = id
    self.description = description
  }
}

public struct CodexModelOption: Identifiable, Equatable, Sendable {
  public let id: String
  public let model: String
  public let displayName: String
  public let description: String
  public let isDefault: Bool
  public let defaultReasoningEffort: String
  public let supportedReasoningEfforts: [CodexReasoningEffortOption]

  public init(
    id: String,
    model: String,
    displayName: String,
    description: String,
    isDefault: Bool,
    defaultReasoningEffort: String,
    supportedReasoningEfforts: [CodexReasoningEffortOption]
  ) {
    self.id = id
    self.model = model
    self.displayName = displayName
    self.description = description
    self.isDefault = isDefault
    self.defaultReasoningEffort = defaultReasoningEffort
    self.supportedReasoningEfforts = supportedReasoningEfforts
  }
}

public enum CodexClientError: Error, Equatable, LocalizedError, Sendable {
  case alreadyConnected
  case notConnected
  case invalidInitializeResponse
  case invalidThreadResponse
  case invalidTurnResponse
  case turnFailed(String)
  case turnEndedWithoutOutput
  case turnTimedOut(seconds: Int)
  case unsupportedPlatform(String)

  public var errorDescription: String? {
    switch self {
    case .alreadyConnected: "Codex App Server is already connected."
    case .notConnected: "Codex App Server is not connected."
    case .invalidInitializeResponse: "Codex App Server returned an invalid handshake."
    case .invalidThreadResponse: "Codex App Server returned an invalid thread."
    case .invalidTurnResponse: "Codex App Server returned an invalid turn."
    case .turnFailed(let message): "The Codex turn failed: \(message)"
    case .turnEndedWithoutOutput: "The Codex turn finished without a proposal."
    case .turnTimedOut(let seconds):
      "The Codex turn did not finish within \(seconds) seconds."
    case .unsupportedPlatform(let platform):
      "This StoryPointless build cannot use a Codex runtime for \(platform)."
    }
  }
}

public actor CodexAppServerClient: CodexManagedCommandExecuting {
  private struct ManagedCommandState {
    var standardOutput = ""
    var standardError = ""
    var result: CodexManagedCommandResult?
    var errorMessage: String?
  }

  private let transport: any CodexRPCTransport
  private var connectionInfo: CodexConnectionInfo?
  private var inboundRoutingTask: Task<Void, Never>?
  private var inboundSubscribers: [
    UUID: AsyncStream<CodexInboundMessage>.Continuation
  ] = [:]
  private var recentInboundMessages: [CodexInboundMessage] = []
  private var managedCommandStates: [String: ManagedCommandState] = [:]
  private var managedCommandTasks: [String: Task<Void, Never>] = [:]
  private var pendingApprovalTurns: [String: Set<String>] = [:]

  public init(transport: any CodexRPCTransport) {
    self.transport = transport
  }

  public func connect() async throws -> CodexConnectionInfo {
    guard connectionInfo == nil else { throw CodexClientError.alreadyConnected }
    try await transport.start()
    startInboundRouting()

    do {
      let response = try await transport.request(
        method: "initialize",
        params: .object([
          "clientInfo": .object([
            "name": .string("storypointless"),
            "title": .string("StoryPointless"),
            "version": .string("0.1.0"),
          ]),
          "capabilities": .object([
            "experimentalApi": .bool(true)
          ]),
        ])
      )
      let info = try decodeConnectionInfo(response)
      guard info.platformOS == "macos" else {
        throw CodexClientError.unsupportedPlatform(info.platformOS)
      }
      try await transport.notify(method: "initialized", params: .object([:]))
      connectionInfo = info
      return info
    } catch {
      stopInboundRouting()
      await transport.stop()
      throw error
    }
  }

  public func inboundMessages(
    replayRecent: Bool = true
  ) -> AsyncStream<CodexInboundMessage> {
    subscribeToInboundMessages(replayRecent: replayRecent)
  }

  public func readRateLimits() async throws -> JSONValue {
    try await transport.request(method: "account/rateLimits/read", params: .object([:]))
  }

  public func listModels() async throws -> [CodexModelOption] {
    guard connectionInfo != nil else { throw CodexClientError.notConnected }
    var models: [CodexModelOption] = []
    var cursor: String?

    repeat {
      var params: [String: JSONValue] = [
        "includeHidden": .bool(false),
        "limit": .integer(100),
      ]
      if let cursor { params["cursor"] = .string(cursor) }
      let response = try await transport.request(method: "model/list", params: .object(params))
      for value in response["data"]?.arrayValue ?? [] {
        guard
          value["hidden"]?.boolValue != true,
          let id = value["id"]?.stringValue,
          let model = value["model"]?.stringValue,
          let displayName = value["displayName"]?.stringValue,
          let description = value["description"]?.stringValue,
          let isDefault = value["isDefault"]?.boolValue,
          let defaultEffort = value["defaultReasoningEffort"]?.stringValue
        else { continue }
        let efforts = (value["supportedReasoningEfforts"]?.arrayValue ?? []).compactMap {
          option -> CodexReasoningEffortOption? in
          guard
            let effort = option["reasoningEffort"]?.stringValue,
            let description = option["description"]?.stringValue
          else { return nil }
          return CodexReasoningEffortOption(id: effort, description: description)
        }
        models.append(
          CodexModelOption(
            id: id,
            model: model,
            displayName: displayName,
            description: description,
            isDefault: isDefault,
            defaultReasoningEffort: defaultEffort,
            supportedReasoningEfforts: efforts
          )
        )
      }
      cursor = response["nextCursor"]?.stringValue
    } while cursor != nil

    return models
  }

  public func startReadOnlyThread(
    workingDirectory: URL,
    developerInstructions: String,
    model: String? = nil,
    allowsApprovals: Bool = false,
    readOnlyProductDirectory: URL? = nil
  ) async throws -> String {
    guard connectionInfo != nil else { throw CodexClientError.notConnected }
    var params: [String: JSONValue] = [
      "approvalPolicy": .string(allowsApprovals ? "on-request" : "never"),
      "cwd": .string(workingDirectory.path),
      "developerInstructions": .string(developerInstructions),
      "ephemeral": .bool(false),
      "permissions": .string(CodexPermissionProfiles.readOnly),
      "personality": .string("pragmatic"),
      "runtimeWorkspaceRoots": .array(
        ([workingDirectory] + (readOnlyProductDirectory.map { [$0] } ?? []))
          .map { .string($0.standardizedFileURL.path) }
      ),
      "serviceName": .string("StoryPointless"),
    ]
    if let model, model != "default" {
      params["model"] = .string(model)
    }

    let response = try await transport.request(method: "thread/start", params: .object(params))
    guard let threadID = response["thread"]?["id"]?.stringValue else {
      throw CodexClientError.invalidThreadResponse
    }
    return threadID
  }

  public func startWorkspaceThread(
    workingDirectory: URL,
    developerInstructions: String,
    model: String? = nil,
    readOnlyGitDirectory: URL? = nil,
    readOnlyProductDirectory: URL? = nil
  ) async throws -> String {
    guard connectionInfo != nil else { throw CodexClientError.notConnected }
    let productDirectory =
      readOnlyProductDirectory
      ?? readOnlyGitDirectory?
        .deletingLastPathComponent()
        .appendingPathComponent(
          ProductStoreRegistry.controlDirectoryName,
          isDirectory: true
        )
    var params: [String: JSONValue] = [
      "approvalPolicy": .string("on-request"),
      "cwd": .string(workingDirectory.path),
      "developerInstructions": .string(developerInstructions),
      "ephemeral": .bool(false),
      "permissions": .string(CodexPermissionProfiles.delivery),
      "personality": .string("pragmatic"),
      "runtimeWorkspaceRoots": .array([
        .string(workingDirectory.standardizedFileURL.path)
      ]),
      "serviceName": .string("StoryPointless"),
    ]
    if let readOnlyGitDirectory {
      params["config"] = CodexPermissionProfiles.deliveryThreadConfiguration(
        readOnlyGitDirectory: readOnlyGitDirectory,
        readOnlyProductDirectory: productDirectory
      )
    }
    if let model, model != "default" {
      params["model"] = .string(model)
    }

    let response = try await transport.request(method: "thread/start", params: .object(params))
    guard let threadID = response["thread"]?["id"]?.stringValue else {
      throw CodexClientError.invalidThreadResponse
    }
    return threadID
  }

  public func resumeReadOnlyThread(
    threadID: String,
    workingDirectory: URL,
    developerInstructions: String,
    model: String? = nil,
    allowsApprovals: Bool = false,
    readOnlyProductDirectory: URL? = nil
  ) async throws -> String {
    var params: [String: JSONValue] = [
      "approvalPolicy": .string(allowsApprovals ? "on-request" : "never"),
      "cwd": .string(workingDirectory.path),
      "developerInstructions": .string(developerInstructions),
      "permissions": .string(CodexPermissionProfiles.readOnly),
      "personality": .string("pragmatic"),
      "runtimeWorkspaceRoots": .array(
        ([workingDirectory] + (readOnlyProductDirectory.map { [$0] } ?? []))
          .map { .string($0.standardizedFileURL.path) }
      ),
      "threadId": .string(threadID),
    ]
    if let model, model != "default" {
      params["model"] = .string(model)
    }
    return try await resumeThread(params: params)
  }

  public func resumeWorkspaceThread(
    threadID: String,
    workingDirectory: URL,
    developerInstructions: String,
    model: String? = nil,
    readOnlyGitDirectory: URL? = nil,
    readOnlyProductDirectory: URL? = nil
  ) async throws -> String {
    let productDirectory =
      readOnlyProductDirectory
      ?? readOnlyGitDirectory?
        .deletingLastPathComponent()
        .appendingPathComponent(
          ProductStoreRegistry.controlDirectoryName,
          isDirectory: true
        )
    var params: [String: JSONValue] = [
      "approvalPolicy": .string("on-request"),
      "cwd": .string(workingDirectory.path),
      "developerInstructions": .string(developerInstructions),
      "permissions": .string(CodexPermissionProfiles.delivery),
      "personality": .string("pragmatic"),
      "runtimeWorkspaceRoots": .array([
        .string(workingDirectory.standardizedFileURL.path)
      ]),
      "threadId": .string(threadID),
    ]
    if let readOnlyGitDirectory {
      params["config"] = CodexPermissionProfiles.deliveryThreadConfiguration(
        readOnlyGitDirectory: readOnlyGitDirectory,
        readOnlyProductDirectory: productDirectory
      )
    }
    if let model, model != "default" {
      params["model"] = .string(model)
    }
    return try await resumeThread(params: params)
  }

  private func resumeThread(params: [String: JSONValue]) async throws -> String {
    guard connectionInfo != nil else { throw CodexClientError.notConnected }
    let response = try await transport.request(
      method: "thread/resume",
      params: .object(params)
    )
    guard let threadID = response["thread"]?["id"]?.stringValue else {
      throw CodexClientError.invalidThreadResponse
    }
    return threadID
  }

  public func startStructuredTurn(
    threadID: String,
    prompt: String,
    effort: String,
    outputSchema: JSONValue,
    runtimeWorkspaceRoots: [URL] = []
  ) async throws -> String {
    guard connectionInfo != nil else { throw CodexClientError.notConnected }
    var params: [String: JSONValue] = [
      "effort": .string(effort),
      "input": .array([
        .object([
          "text": .string(prompt),
          "type": .string("text"),
        ])
      ]),
      "outputSchema": outputSchema,
      "summary": .string("concise"),
      "threadId": .string(threadID),
    ]
    // Turns deliberately inherit the profile materialized by thread start/resume.
    // Reselecting a named process profile here would discard dynamic per-thread
    // grants such as the active product's exact read-only Git directory.
    if !runtimeWorkspaceRoots.isEmpty {
      params["runtimeWorkspaceRoots"] = .array(
        runtimeWorkspaceRoots.map {
          .string($0.standardizedFileURL.path)
        }
      )
    }
    let response = try await transport.request(
      method: "turn/start",
      params: .object(params)
    )
    guard let turnID = response["turn"]?["id"]?.stringValue else {
      throw CodexClientError.invalidTurnResponse
    }
    return turnID
  }

  public func waitForFinalAgentMessage(
    threadID: String,
    turnID: String,
    timeout: Duration = .seconds(75),
    reconciliationInterval: Duration = .seconds(2)
  ) async throws -> String {
    guard connectionInfo != nil else { throw CodexClientError.notConnected }
    let messages = subscribeToInboundMessages(replayRecent: true)
    let timeoutSeconds = max(1, Int(timeout.components.seconds))
    // The durable turn timestamp can precede the turn/start response by several
    // seconds while the App Server persists the turn. Keep a narrow allowance so
    // reconciliation accepts that turn without replaying an older conversation turn.
    let waitStartedAt = Date().addingTimeInterval(-30)
    do {
      return try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
          var streamedAgentMessage = ""
          var completedAgentMessage: String?
          for await message in messages {
            try Task.checkCancellation()
            guard case .notification(let notification) = message else { continue }
            guard notification.params["threadId"]?.stringValue == threadID else { continue }

            if notification.method == "item/agentMessage/delta",
              notification.params["turnId"]?.stringValue == turnID,
              let delta = notification.params["delta"]?.stringValue
            {
              streamedAgentMessage += delta
            }

            if notification.method == "item/completed",
              notification.params["turnId"]?.stringValue == turnID,
              notification.params["item"]?["type"]?.stringValue == "agentMessage",
              notification.params["item"]?["phase"]?.stringValue == "final_answer",
              let text = notification.params["item"]?["text"]?.stringValue
            {
              // A final-answer item can arrive before turn/completed. Starting a
              // validation-repair turn in that gap can strand the new submission
              // behind the turn that is still closing, so retain the text until
              // the matching turn reaches a terminal state.
              completedAgentMessage = text
            }

            if notification.method == "turn/completed",
              notification.params["turn"]?["id"]?.stringValue == turnID
            {
              let status = notification.params["turn"]?["status"]?.stringValue
              if status == "failed" {
                let message =
                  notification.params["turn"]?["error"]?["message"]?.stringValue
                  ?? "Unknown failure"
                throw CodexClientError.turnFailed(message)
              }
              let completedItems = notification.params["turn"]?["items"]?.arrayValue ?? []
              if let text = Self.terminalAgentMessage(in: completedItems) {
                return text
              }
              if let completedAgentMessage {
                return completedAgentMessage
              }
              if
                !streamedAgentMessage.isEmpty,
                !completedItems.contains(where: {
                  $0["type"]?.stringValue == "agentMessage"
                })
              {
                return streamedAgentMessage
              }
              throw CodexClientError.turnEndedWithoutOutput
            }
          }
          throw CodexClientError.turnEndedWithoutOutput
        }
        group.addTask { [self] in
          while !Task.isCancelled {
            try await Task.sleep(for: reconciliationInterval)
            do {
              if let result = try await completedTurnResponse(
                threadID: threadID,
                turnID: turnID
              ) {
                return result
              }
              if let result = try await latestCompletedAgentMessage(
                threadID: threadID,
                notBefore: waitStartedAt
              ) {
                return result
              }
            } catch let error as CodexClientError {
              throw error
            } catch {
              // Notifications remain the primary path. A transient or older-runtime
              // thread/read failure must not end a healthy turn.
            }
          }
          throw CancellationError()
        }
        group.addTask { [self] in
          var remaining = Self.seconds(in: timeout)
          while remaining > 0 {
            let slice = min(remaining, 0.25)
            try await Task.sleep(for: .milliseconds(Int64(max(1, slice * 1_000))))
            if !(await isAwaitingApproval(threadID: threadID, turnID: turnID)) {
              remaining -= slice
            }
          }
          throw CodexClientError.turnTimedOut(seconds: timeoutSeconds)
        }
        guard let result = try await group.next() else {
          throw CodexClientError.turnEndedWithoutOutput
        }
        group.cancelAll()
        return result
      }
    } catch CodexClientError.turnTimedOut(let seconds) {
      if let recovered = try? await completedTurnResponse(
        threadID: threadID,
        turnID: turnID
      ) {
        return recovered
      }
      if let recovered = try? await latestCompletedAgentMessage(
        threadID: threadID,
        notBefore: waitStartedAt
      ) {
        return recovered
      }
      try? await interruptTurn(threadID: threadID, turnID: turnID)
      throw CodexClientError.turnTimedOut(seconds: seconds)
    }
  }

  private func completedTurnResponse(
    threadID: String,
    turnID: String
  ) async throws -> String? {
    let response = try await transport.request(
      method: "thread/read",
      params: .object([
        "threadId": .string(threadID),
        "includeTurns": .bool(true),
      ])
    )
    guard
      let turn = response["thread"]?["turns"]?.arrayValue?.first(where: {
        $0["id"]?.stringValue == turnID
      }),
      let status = turn["status"]?.stringValue
    else { return nil }

    switch status {
    case "completed":
      let items = turn["items"]?.arrayValue ?? []
      guard let text = Self.terminalAgentMessage(in: items) else {
        throw CodexClientError.turnEndedWithoutOutput
      }
      return text
    case "failed":
      throw CodexClientError.turnFailed(
        turn["error"]?["message"]?.stringValue ?? "Unknown failure"
      )
    case "interrupted":
      throw CodexClientError.turnFailed("The Codex turn was interrupted.")
    default:
      return nil
    }
  }

  public func completedAgentMessage(
    threadID: String,
    turnID: String
  ) async throws -> String? {
    guard connectionInfo != nil else { throw CodexClientError.notConnected }
    return try await completedTurnResponse(threadID: threadID, turnID: turnID)
  }

  public func latestCompletedAgentMessage(
    threadID: String,
    notBefore: Date? = nil
  ) async throws -> String? {
    guard connectionInfo != nil else { throw CodexClientError.notConnected }
    let response = try await transport.request(
      method: "thread/read",
      params: .object([
        "threadId": .string(threadID),
        "includeTurns": .bool(true),
      ])
    )
    guard let latestTurn = response["thread"]?["turns"]?.arrayValue?.last else {
      return nil
    }
    guard latestTurn["status"]?.stringValue == "completed" else {
      return nil
    }
    if let notBefore {
      guard let startedAt = latestTurn["startedAt"]?.integerValue else {
        return nil
      }
      if Date(timeIntervalSince1970: TimeInterval(startedAt)) < notBefore {
        return nil
      }
    }
    let items = latestTurn["items"]?.arrayValue ?? []
    return Self.terminalAgentMessage(in: items)
  }

  public func interruptTurn(threadID: String, turnID: String) async throws {
    guard connectionInfo != nil else { throw CodexClientError.notConnected }
    _ = try await transport.request(
      method: "turn/interrupt",
      params: .object([
        "threadId": .string(threadID),
        "turnId": .string(turnID),
      ])
    )
  }

  public func runManagedCommand(
    _ request: CodexManagedCommandRequest
  ) async throws -> CodexManagedCommandResult {
    guard connectionInfo != nil else { throw CodexClientError.notConnected }
    let responseTimeout = Duration.seconds(Double((request.timeoutSeconds ?? 900) + 15))
    let response = try await transport.request(
      method: "command/exec",
      params: commandExecParams(
        request,
        processID: nil,
        streamsOutput: false
      ),
      responseTimeout: responseTimeout
    )
    return decodeManagedCommandResult(response)
  }

  public func startManagedCommand(
    _ request: CodexManagedCommandRequest
  ) async throws -> String {
    guard connectionInfo != nil else { throw CodexClientError.notConnected }
    let processID = UUID().uuidString.lowercased()
    managedCommandStates[processID] = ManagedCommandState()
    let transport = self.transport
    let params = commandExecParams(
      request,
      processID: processID,
      streamsOutput: true
    )
    managedCommandTasks[processID] = Task { [weak self] in
      do {
        let response = try await transport.request(
          method: "command/exec",
          params: params,
          responseTimeout: .seconds(604_800)
        )
        await self?.managedCommandDidExit(
          processID: processID,
          response: response
        )
      } catch {
        await self?.managedCommandDidFail(
          processID: processID,
          message: error.localizedDescription
        )
      }
    }
    return processID
  }

  public func managedCommandSnapshot(
    processID: String
  ) -> CodexManagedCommandSnapshot? {
    guard let state = managedCommandStates[processID] else { return nil }
    if let result = state.result {
      return .exited(result)
    }
    if let errorMessage = state.errorMessage {
      return .failed(errorMessage)
    }
    return .running(
      standardOutput: state.standardOutput,
      standardError: state.standardError
    )
  }

  public func terminateManagedCommand(processID: String) async {
    guard managedCommandStates[processID] != nil else { return }
    _ = try? await transport.request(
      method: "command/exec/terminate",
      params: .object([
        "processId": .string(processID)
      ])
    )
  }

  public nonisolated static func approvalPresentation(
    for request: CodexServerRequest
  ) throws -> CodexApprovalPresentation {
    guard
      let threadID = request.params["threadId"]?.stringValue,
      let turnID = request.params["turnId"]?.stringValue
    else {
      throw CodexApprovalError.malformedRequest("missing thread or turn identifier")
    }
    let reason = request.params["reason"]?.stringValue
    let kind: CodexApprovalRequestKind
    let title: String
    let detail: String
    switch request.method {
    case "item/commandExecution/requestApproval":
      kind = .command
      title = "Allow this command?"
      let command = request.params["command"]?.stringValue
        ?? "Codex requested a local command."
      if
        let additionalPermissions = request.params["additionalPermissions"],
        additionalPermissions != .null
      {
        detail = [
          command,
          "Additional access for this command:",
          permissionDetail(additionalPermissions),
        ].joined(separator: "\n\n")
      } else {
        detail = command
      }
    case "item/permissions/requestApproval":
      kind = .permissions
      title = "Allow additional access?"
      detail = permissionDetail(request.params["permissions"])
    case "item/fileChange/requestApproval":
      kind = .fileChange
      title = "Allow this file change?"
      detail = request.params["reason"]?.stringValue
        ?? "Codex requested a file change outside its current access."
    default:
      throw CodexApprovalError.unsupportedRequest(request.method)
    }
    return CodexApprovalPresentation(
      kind: kind,
      threadID: threadID,
      turnID: turnID,
      title: title,
      detail: detail,
      reason: reason,
      signature: approvalSignature(method: request.method, params: request.params),
      productGrantSignature: productGrantSignature(
        method: request.method,
        params: request.params
      )
    )
  }

  public nonisolated static func productGrantSignature(
    for request: CodexServerRequest,
    ticketWorkspaceRoot: URL?
  ) throws -> String? {
    let presentation = try approvalPresentation(for: request)
    guard let signature = presentation.productGrantSignature else { return nil }
    guard presentation.kind == .command else { return signature }
    guard let ticketWorkspaceRoot else { return nil }
    guard let requestedCWD = request.params["cwd"]?.stringValue else {
      return signature
    }

    let workspaceURL = ticketWorkspaceRoot
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let requestedURL = URL(fileURLWithPath: requestedCWD)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let workspacePath = workspaceURL.path
    let requestedPath = requestedURL.path
    guard
      requestedPath == workspacePath
        || requestedPath.hasPrefix(workspacePath + "/")
    else {
      return nil
    }
    return signature
  }

  public func resolveApprovalRequest(
    _ request: CodexServerRequest,
    allow: Bool
  ) async throws {
    let result: JSONValue
    switch request.method {
    case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
      result = .object([
        "decision": .string(allow ? "accept" : "decline")
      ])
    case "item/permissions/requestApproval":
      result = .object([
        "permissions": allow
          ? (request.params["permissions"] ?? .object([:]))
          : .object([:]),
        "scope": .string("turn"),
      ])
    default:
      throw CodexApprovalError.unsupportedRequest(request.method)
    }
    try await transport.respond(id: request.id, result: result)
    removePendingApproval(request)
  }

  public func rejectUnsupportedServerRequest(_ request: CodexServerRequest) async {
    try? await transport.respondError(
      id: request.id,
      error: CodexRPCError(
        code: -32_601,
        message: "StoryPointless does not support this requested client action."
      )
    )
    removePendingApproval(request)
  }

  public func disconnect() async {
    for task in managedCommandTasks.values {
      task.cancel()
    }
    managedCommandTasks.removeAll()
    managedCommandStates.removeAll()
    pendingApprovalTurns.removeAll()
    stopInboundRouting()
    await transport.stop()
    connectionInfo = nil
  }

  private func startInboundRouting() {
    guard inboundRoutingTask == nil else { return }
    let transport = self.transport
    inboundRoutingTask = Task { [weak self] in
      let messages = await transport.inboundMessages()
      for await message in messages {
        guard !Task.isCancelled else { return }
        await self?.routeInboundMessage(message)
      }
    }
  }

  private func stopInboundRouting() {
    inboundRoutingTask?.cancel()
    inboundRoutingTask = nil
    for continuation in inboundSubscribers.values {
      continuation.finish()
    }
    inboundSubscribers.removeAll()
    recentInboundMessages.removeAll()
  }

  private func routeInboundMessage(_ message: CodexInboundMessage) {
    if case .request(let request) = message, Self.isApprovalMethod(request.method) {
      let key = Self.approvalTurnKey(params: request.params)
      pendingApprovalTurns[key, default: []].insert(Self.requestKey(request.id))
    }
    if case .notification(let notification) = message,
      notification.method == "command/exec/outputDelta",
      let processID = notification.params["processId"]?.stringValue,
      let encoded = notification.params["deltaBase64"]?.stringValue,
      let data = Data(base64Encoded: encoded)
    {
      let text = String(decoding: data, as: UTF8.self)
      if notification.params["stream"]?.stringValue == "stderr" {
        managedCommandStates[processID]?.standardError += text
      } else {
        managedCommandStates[processID]?.standardOutput += text
      }
    }
    recentInboundMessages.append(message)
    if recentInboundMessages.count > 500 {
      recentInboundMessages.removeFirst(recentInboundMessages.count - 500)
    }
    for continuation in inboundSubscribers.values {
      continuation.yield(message)
    }
  }

  private func subscribeToInboundMessages(
    replayRecent: Bool
  ) -> AsyncStream<CodexInboundMessage> {
    let subscriberID = UUID()
    return AsyncStream { continuation in
      inboundSubscribers[subscriberID] = continuation
      if replayRecent {
        for message in recentInboundMessages {
          continuation.yield(message)
        }
      }
      continuation.onTermination = { [weak self] _ in
        Task {
          await self?.removeInboundSubscriber(subscriberID)
        }
      }
    }
  }

  private func removeInboundSubscriber(_ id: UUID) {
    inboundSubscribers.removeValue(forKey: id)
  }

  private func decodeConnectionInfo(_ response: JSONValue) throws -> CodexConnectionInfo {
    guard
      let userAgent = response["userAgent"]?.stringValue,
      let codexHome = response["codexHome"]?.stringValue,
      let platformFamily = response["platformFamily"]?.stringValue,
      let platformOS = response["platformOs"]?.stringValue
    else {
      throw CodexClientError.invalidInitializeResponse
    }
    return CodexConnectionInfo(
      userAgent: userAgent,
      codexHome: codexHome,
      platformFamily: platformFamily,
      platformOS: platformOS
    )
  }

  private func commandExecParams(
    _ request: CodexManagedCommandRequest,
    processID: String?,
    streamsOutput: Bool
  ) -> JSONValue {
    var params: [String: JSONValue] = [
      "command": .array(request.command.map(JSONValue.string)),
      "cwd": .string(request.workingDirectory.path),
      "env": .object(request.environment.mapValues(JSONValue.string)),
      "outputBytesCap": .integer(Int64(request.outputBytesCap)),
      "permissionProfile": .string(request.permissionProfile),
      "streamStdoutStderr": .bool(streamsOutput),
    ]
    if let processID {
      params["processId"] = .string(processID)
    }
    if let timeoutSeconds = request.timeoutSeconds {
      params["timeoutMs"] = .integer(Int64(timeoutSeconds * 1_000))
    } else {
      params["disableTimeout"] = .bool(true)
    }
    return .object(params)
  }

  private func decodeManagedCommandResult(
    _ response: JSONValue
  ) -> CodexManagedCommandResult {
    CodexManagedCommandResult(
      exitCode: Int(response["exitCode"]?.integerValue ?? -1),
      standardOutput: response["stdout"]?.stringValue ?? "",
      standardError: response["stderr"]?.stringValue ?? ""
    )
  }

  private func managedCommandDidExit(processID: String, response: JSONValue) {
    guard var state = managedCommandStates[processID] else { return }
    let buffered = decodeManagedCommandResult(response)
    state.result = CodexManagedCommandResult(
      exitCode: buffered.exitCode,
      standardOutput: state.standardOutput + buffered.standardOutput,
      standardError: state.standardError + buffered.standardError
    )
    managedCommandStates[processID] = state
    managedCommandTasks.removeValue(forKey: processID)
  }

  private func managedCommandDidFail(processID: String, message: String) {
    managedCommandStates[processID]?.errorMessage = message
    managedCommandTasks.removeValue(forKey: processID)
  }

  private func isAwaitingApproval(threadID: String, turnID: String) -> Bool {
    !(pendingApprovalTurns["\(threadID)|\(turnID)"] ?? []).isEmpty
  }

  private func removePendingApproval(_ request: CodexServerRequest) {
    let key = Self.approvalTurnKey(params: request.params)
    pendingApprovalTurns[key]?.remove(Self.requestKey(request.id))
    if pendingApprovalTurns[key]?.isEmpty == true {
      pendingApprovalTurns.removeValue(forKey: key)
    }
  }

  private nonisolated static func isApprovalMethod(_ method: String) -> Bool {
    method == "item/commandExecution/requestApproval"
      || method == "item/permissions/requestApproval"
      || method == "item/fileChange/requestApproval"
  }

  private nonisolated static func approvalTurnKey(params: JSONValue) -> String {
    "\(params["threadId"]?.stringValue ?? "")|\(params["turnId"]?.stringValue ?? "")"
  }

  private nonisolated static func requestKey(_ id: JSONValue) -> String {
    if let value = id.stringValue { return value }
    if let value = id.integerValue { return String(value) }
    return String(describing: id)
  }

  private nonisolated static func approvalSignature(
    method: String,
    params: JSONValue
  ) -> String {
    let relevant: JSONValue
    switch method {
    case "item/commandExecution/requestApproval":
      relevant = .object([
        "command": params["command"] ?? .null,
        "cwd": params["cwd"] ?? .null,
        "additionalPermissions": params["additionalPermissions"] ?? .null,
      ])
    case "item/permissions/requestApproval":
      relevant = params["permissions"] ?? .object([:])
    default:
      relevant = .object([
        "reason": params["reason"] ?? .null
      ])
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(relevant)) ?? Data()
    return "\(method)|\(String(decoding: data, as: UTF8.self))"
  }

  private nonisolated static func productGrantSignature(
    method: String,
    params: JSONValue
  ) -> String? {
    let relevant: JSONValue
    switch method {
    case "item/commandExecution/requestApproval":
      relevant = .object([
        "command": params["command"] ?? .null,
        "additionalPermissions": params["additionalPermissions"] ?? .null,
      ])
    case "item/permissions/requestApproval":
      relevant = params["permissions"] ?? .object([:])
    default:
      return nil
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(relevant)) ?? Data()
    return "\(method)|\(String(decoding: data, as: UTF8.self))"
  }

  private nonisolated static func permissionDetail(_ value: JSONValue?) -> String {
    guard let value else { return "Codex requested access outside the ticket workspace." }
    var parts: [String] = []
    if value["network"]?["enabled"]?.boolValue == true {
      parts.append("Network access")
    }
    let entries = value["fileSystem"]?["entries"]?.arrayValue ?? []
    for entry in entries.prefix(4) {
      let access = entry["access"]?.stringValue ?? "access"
      let path = entry["path"]?["path"]?.stringValue
        ?? entry["path"]?["pattern"]?.stringValue
        ?? entry["path"]?["value"]?["kind"]?.stringValue
        ?? "an additional location"
      parts.append("\(access.capitalized) \(path)")
    }
    return parts.isEmpty
      ? "Codex requested access outside the ticket workspace."
      : parts.joined(separator: "\n")
  }

  private nonisolated static func seconds(in duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds)
      + Double(components.attoseconds) / 1_000_000_000_000_000_000
  }

  private nonisolated static func terminalAgentMessage(
    in items: [JSONValue]
  ) -> String? {
    let messages = items.reversed().filter {
      $0["type"]?.stringValue == "agentMessage"
        && !($0["text"]?.stringValue ?? "").isEmpty
    }
    let finalAnswer = messages.first {
      $0["phase"]?.stringValue == "final_answer"
    }
    let legacyFinalAnswer = messages.first {
      $0["phase"] == nil
    }
    return (finalAnswer ?? legacyFinalAnswer)?["text"]?.stringValue
  }
}
