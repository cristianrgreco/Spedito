import Foundation
import SpeditoCore

public actor ScriptedCodexTransport: CodexRPCTransport {
  public struct Response: Sendable {
    public let method: String
    public let result: JSONValue

    public init(method: String, result: JSONValue) {
      self.method = method
      self.result = result
    }
  }

  public struct Request: Sendable {
    public let method: String
    public let params: JSONValue
  }

  private var responses: [Response]
  private var requests: [Request] = []
  private var notifications: [Request] = []
  private let inboundStream: AsyncStream<CodexInboundMessage>
  private let inboundContinuation: AsyncStream<CodexInboundMessage>.Continuation
  private let scriptedInboundMessages: [CodexInboundMessage]
  private var didStart = false

  public init(
    responses: [Response],
    inboundMessages: [CodexInboundMessage] = []
  ) {
    self.responses = responses
    scriptedInboundMessages = inboundMessages
    let pair = AsyncStream<CodexInboundMessage>.makeStream()
    inboundStream = pair.stream
    inboundContinuation = pair.continuation
  }

  public func start() {
    guard !didStart else { return }
    didStart = true
    for message in scriptedInboundMessages {
      inboundContinuation.yield(message)
    }
  }

  public func request(method: String, params: JSONValue) throws -> JSONValue {
    requests.append(Request(method: method, params: params))
    guard let response = responses.first else {
      throw CodexRPCError(code: -32_601, message: "Unexpected request: \(method)")
    }
    guard response.method == method else {
      throw CodexRPCError(
        code: -32_601,
        message: "Expected \(response.method), received \(method)"
      )
    }
    responses.removeFirst()
    return response.result
  }

  public func notify(method: String, params: JSONValue) {
    notifications.append(Request(method: method, params: params))
  }

  public func inboundMessages() -> AsyncStream<CodexInboundMessage> {
    inboundStream
  }

  public func stop() {
    inboundContinuation.finish()
  }

  public func recordedRequests() -> [Request] {
    requests
  }

  public func recordedNotifications() -> [Request] {
    notifications
  }

  public func remainingResponseCount() -> Int {
    responses.count
  }
}
