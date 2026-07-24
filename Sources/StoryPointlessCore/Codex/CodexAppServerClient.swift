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

public actor CodexAppServerClient {
  private let transport: any CodexRPCTransport
  private var connectionInfo: CodexConnectionInfo?
  private var inboundRoutingTask: Task<Void, Never>?
  private var inboundSubscribers: [
    UUID: AsyncStream<CodexInboundMessage>.Continuation
  ] = [:]
  private var recentInboundMessages: [CodexInboundMessage] = []

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
            "experimentalApi": .bool(false)
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
    model: String? = nil
  ) async throws -> String {
    guard connectionInfo != nil else { throw CodexClientError.notConnected }
    var params: [String: JSONValue] = [
      "approvalPolicy": .string("never"),
      "cwd": .string(workingDirectory.path),
      "developerInstructions": .string(developerInstructions),
      "ephemeral": .bool(false),
      "personality": .string("pragmatic"),
      "sandbox": .string("read-only"),
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
    model: String? = nil
  ) async throws -> String {
    guard connectionInfo != nil else { throw CodexClientError.notConnected }
    var params: [String: JSONValue] = [
      "approvalPolicy": .string("never"),
      "cwd": .string(workingDirectory.path),
      "developerInstructions": .string(developerInstructions),
      "ephemeral": .bool(false),
      "personality": .string("pragmatic"),
      "sandbox": .string("workspace-write"),
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

  public func startStructuredTurn(
    threadID: String,
    prompt: String,
    effort: String,
    outputSchema: JSONValue
  ) async throws -> String {
    guard connectionInfo != nil else { throw CodexClientError.notConnected }
    let response = try await transport.request(
      method: "turn/start",
      params: .object([
        "approvalPolicy": .string("never"),
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
      ])
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
              let text = notification.params["item"]?["text"]?.stringValue
            {
              return text
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
              if let text = completedItems.reversed().first(where: {
                $0["type"]?.stringValue == "agentMessage"
                  && !($0["text"]?.stringValue ?? "").isEmpty
              })?["text"]?.stringValue
              {
                return text
              }
              if !streamedAgentMessage.isEmpty {
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
        group.addTask {
          try await Task.sleep(for: timeout)
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
      let finalAnswer = items.reversed().first {
        $0["type"]?.stringValue == "agentMessage"
          && $0["phase"]?.stringValue == "final_answer"
          && !($0["text"]?.stringValue ?? "").isEmpty
      }
      let lastAgentMessage = items.reversed().first {
        $0["type"]?.stringValue == "agentMessage"
          && !($0["text"]?.stringValue ?? "").isEmpty
      }
      guard let text = (finalAnswer ?? lastAgentMessage)?["text"]?.stringValue else {
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
    let finalAnswer = items.reversed().first {
      $0["type"]?.stringValue == "agentMessage"
        && $0["phase"]?.stringValue == "final_answer"
        && !($0["text"]?.stringValue ?? "").isEmpty
    }
    let lastAgentMessage = items.reversed().first {
      $0["type"]?.stringValue == "agentMessage"
        && !($0["text"]?.stringValue ?? "").isEmpty
    }
    return (finalAnswer ?? lastAgentMessage)?["text"]?.stringValue
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

  public func disconnect() async {
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
}
