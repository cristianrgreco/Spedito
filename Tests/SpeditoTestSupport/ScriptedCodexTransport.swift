import Foundation
import SpeditoCore

public actor ScriptedCodexTransport: CodexRPCTransport {
  public struct Response: Sendable {
    public let method: String
    fileprivate let outcome: Result<JSONValue, CodexRPCError>

    public init(method: String, result: JSONValue) {
      self.method = method
      outcome = .success(result)
    }

    public init(method: String, error: CodexRPCError) {
      self.method = method
      outcome = .failure(error)
    }
  }

  public struct Request: Sendable {
    public let method: String
    public let params: JSONValue
  }

  private struct RequestWaiter {
    let count: Int
    let continuation: CheckedContinuation<Void, Never>
  }

  private var responses: [Response]
  private var requests: [Request] = []
  private var notifications: [Request] = []
  private var requestWaitersByMethod: [String: [RequestWaiter]] = [:]
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
    resumeRequestWaiters(for: method)
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
    return try response.outcome.get()
  }

  public func notify(method: String, params: JSONValue) {
    notifications.append(Request(method: method, params: params))
  }

  public func inboundMessages() -> AsyncStream<CodexInboundMessage> {
    inboundStream
  }

  public func emit(_ message: CodexInboundMessage) {
    inboundContinuation.yield(message)
  }

  public func waitForRequest(_ method: String, count: Int = 1) async {
    guard requests.lazy.filter({ $0.method == method }).count < count else { return }
    await withCheckedContinuation { continuation in
      requestWaitersByMethod[method, default: []].append(
        RequestWaiter(count: count, continuation: continuation)
      )
    }
  }

  public func stop() {
    for waiters in requestWaitersByMethod.values {
      for waiter in waiters {
        waiter.continuation.resume()
      }
    }
    requestWaitersByMethod.removeAll()
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

  private func resumeRequestWaiters(for method: String) {
    guard let waiters = requestWaitersByMethod[method] else { return }
    let requestCount = requests.lazy.filter { $0.method == method }.count
    var pending: [RequestWaiter] = []
    for waiter in waiters {
      if requestCount >= waiter.count {
        waiter.continuation.resume()
      } else {
        pending.append(waiter)
      }
    }
    if pending.isEmpty {
      requestWaitersByMethod.removeValue(forKey: method)
    } else {
      requestWaitersByMethod[method] = pending
    }
  }
}
