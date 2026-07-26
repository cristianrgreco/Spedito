import Foundation

public struct CodexRPCError: Error, Equatable, LocalizedError, Sendable {
  public let code: Int
  public let message: String
  public let data: JSONValue?

  public init(code: Int, message: String, data: JSONValue? = nil) {
    self.code = code
    self.message = message
    self.data = data
  }

  public var errorDescription: String? {
    "Codex App Server error \(code): \(message)"
  }

  public var isThreadNotFound: Bool {
    code == -32600 && message.localizedCaseInsensitiveContains("thread not found")
  }
}

public enum CodexTransportError: Error, Equatable, LocalizedError, Sendable {
  case alreadyStarted
  case notStarted
  case processExited(Int32)
  case invalidMessage(String)
  case requestTimedOut(String)
  case writeFailed(String)

  public var errorDescription: String? {
    switch self {
    case .alreadyStarted: "The Codex App Server transport is already running."
    case .notStarted: "The Codex App Server transport is not running."
    case .processExited(let status): "Codex App Server exited with status \(status)."
    case .invalidMessage(let detail): "Codex App Server sent an invalid message: \(detail)"
    case .requestTimedOut(let method): "Codex App Server did not answer \(method) in time."
    case .writeFailed(let detail): "Could not write to Codex App Server: \(detail)"
    }
  }
}

public struct CodexNotification: Equatable, Sendable {
  public let method: String
  public let params: JSONValue

  public init(method: String, params: JSONValue) {
    self.method = method
    self.params = params
  }
}

public struct CodexServerRequest: Equatable, Sendable {
  public let id: JSONValue
  public let method: String
  public let params: JSONValue

  public init(id: JSONValue, method: String, params: JSONValue) {
    self.id = id
    self.method = method
    self.params = params
  }
}

public enum CodexInboundMessage: Equatable, Sendable {
  case notification(CodexNotification)
  case request(CodexServerRequest)
}

public protocol CodexRPCTransport: Sendable {
  func start() async throws
  func request(method: String, params: JSONValue) async throws -> JSONValue
  func request(
    method: String,
    params: JSONValue,
    responseTimeout: Duration
  ) async throws -> JSONValue
  func notify(method: String, params: JSONValue) async throws
  func respond(id: JSONValue, result: JSONValue) async throws
  func respondError(id: JSONValue, error: CodexRPCError) async throws
  func inboundMessages() async -> AsyncStream<CodexInboundMessage>
  func stop() async
}

extension CodexRPCTransport {
  public func request(
    method: String,
    params: JSONValue,
    responseTimeout: Duration
  ) async throws -> JSONValue {
    try await request(method: method, params: params)
  }

  public func respond(id: JSONValue, result: JSONValue) async throws {
    throw CodexTransportError.writeFailed(
      "This transport cannot answer Codex App Server requests."
    )
  }

  public func respondError(id: JSONValue, error: CodexRPCError) async throws {
    throw CodexTransportError.writeFailed(
      "This transport cannot reject Codex App Server requests."
    )
  }
}

public actor CodexJSONLTransport: CodexRPCTransport {
  public struct Configuration: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let currentDirectoryURL: URL?
    public let environmentOverrides: [String: String]
    public let requestTimeout: Duration

    public init(
      executableURL: URL,
      arguments: [String] = CodexPermissionProfiles.appServerArguments,
      currentDirectoryURL: URL? = nil,
      environmentOverrides: [String: String] = [:],
      requestTimeout: Duration = .seconds(15)
    ) {
      self.executableURL = executableURL
      self.arguments = arguments
      self.currentDirectoryURL = currentDirectoryURL
      self.environmentOverrides = environmentOverrides
      self.requestTimeout = requestTimeout
    }
  }

  private struct PendingRequest {
    let method: String
    let continuation: CheckedContinuation<JSONValue, any Error>
    let timeout: Task<Void, Never>
  }

  private let configuration: Configuration
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let stream: AsyncStream<CodexInboundMessage>
  private let streamContinuation: AsyncStream<CodexInboundMessage>.Continuation
  private var process: Process?
  private var inputHandle: FileHandle?
  private var outputHandle: FileHandle?
  private var errorHandle: FileHandle?
  private var outputChunkContinuation: AsyncStream<Data>.Continuation?
  private var errorChunkContinuation: AsyncStream<Data>.Continuation?
  private var outputReadTask: Task<Void, Never>?
  private var errorReadTask: Task<Void, Never>?
  private var outputBuffer = Data()
  private var errorBuffer = Data()
  private var nextRequestID: Int64 = 1
  private var pending: [Int64: PendingRequest] = [:]
  private var processGeneration: UUID?
  private var processExitStatus: Int32?
  private var outputDidReachEOF = false

  public init(configuration: Configuration) {
    self.configuration = configuration
    let pair = AsyncStream<CodexInboundMessage>.makeStream()
    stream = pair.stream
    streamContinuation = pair.continuation
  }

  public func start() throws {
    guard process == nil else { throw CodexTransportError.alreadyStarted }

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errorPipe = Pipe()
    let generation = UUID()
    let outputChunks = AsyncStream<Data>.makeStream()
    let errorChunks = AsyncStream<Data>.makeStream()
    process.executableURL = configuration.executableURL
    process.arguments = configuration.arguments
    process.currentDirectoryURL = configuration.currentDirectoryURL
    if !configuration.environmentOverrides.isEmpty {
      process.environment = ProcessInfo.processInfo.environment.merging(
        configuration.environmentOverrides
      ) { _, configuredValue in
        configuredValue
      }
    }
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errorPipe

    output.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      outputChunks.continuation.yield(data)
      if data.isEmpty {
        outputChunks.continuation.finish()
      }
    }
    errorPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      errorChunks.continuation.yield(data)
      if data.isEmpty {
        errorChunks.continuation.finish()
      }
    }
    process.terminationHandler = { [weak self] process in
      Task {
        await self?.processDidExit(
          status: process.terminationStatus,
          generation: generation
        )
      }
    }

    do {
      try process.run()
    } catch let runtimeError {
      output.fileHandleForReading.readabilityHandler = nil
      errorPipe.fileHandleForReading.readabilityHandler = nil
      outputChunks.continuation.finish()
      errorChunks.continuation.finish()
      throw CodexTransportError.writeFailed(runtimeError.localizedDescription)
    }

    processGeneration = generation
    processExitStatus = nil
    outputDidReachEOF = false
    self.process = process
    inputHandle = input.fileHandleForWriting
    outputHandle = output.fileHandleForReading
    errorHandle = errorPipe.fileHandleForReading
    outputChunkContinuation = outputChunks.continuation
    errorChunkContinuation = errorChunks.continuation
    outputReadTask = Task { [weak self, stream = outputChunks.stream] in
      for await data in stream {
        await self?.receiveOutput(data)
      }
    }
    errorReadTask = Task { [weak self, stream = errorChunks.stream] in
      for await data in stream {
        await self?.receiveError(data)
      }
    }
  }

  public func request(method: String, params: JSONValue) async throws -> JSONValue {
    try await performRequest(
      method: method,
      params: params,
      responseTimeout: configuration.requestTimeout
    )
  }

  public func request(
    method: String,
    params: JSONValue,
    responseTimeout: Duration
  ) async throws -> JSONValue {
    try await performRequest(
      method: method,
      params: params,
      responseTimeout: responseTimeout
    )
  }

  private func performRequest(
    method: String,
    params: JSONValue,
    responseTimeout: Duration
  ) async throws -> JSONValue {
    guard process?.isRunning == true else { throw CodexTransportError.notStarted }
    let id = nextRequestID
    nextRequestID += 1

    return try await withCheckedThrowingContinuation { continuation in
      let timeout = Task { [weak self] in
        do {
          try await Task.sleep(for: responseTimeout)
        } catch {
          return
        }
        await self?.requestDidTimeOut(id: id)
      }
      pending[id] = PendingRequest(method: method, continuation: continuation, timeout: timeout)

      do {
        try send(
          .object([
            "id": .integer(id),
            "method": .string(method),
            "params": params,
          ])
        )
      } catch {
        pending.removeValue(forKey: id)?.timeout.cancel()
        continuation.resume(throwing: error)
      }
    }
  }

  public func notify(method: String, params: JSONValue) throws {
    guard process?.isRunning == true else { throw CodexTransportError.notStarted }
    try send(
      .object([
        "method": .string(method),
        "params": params,
      ])
    )
  }

  public func respond(id: JSONValue, result: JSONValue) throws {
    guard process?.isRunning == true else { throw CodexTransportError.notStarted }
    try send(
      .object([
        "id": id,
        "result": result,
      ])
    )
  }

  public func respondError(id: JSONValue, error: CodexRPCError) throws {
    guard process?.isRunning == true else { throw CodexTransportError.notStarted }
    var payload: [String: JSONValue] = [
      "code": .integer(Int64(error.code)),
      "message": .string(error.message),
    ]
    if let data = error.data {
      payload["data"] = data
    }
    try send(
      .object([
        "id": id,
        "error": .object(payload),
      ])
    )
  }

  public func inboundMessages() -> AsyncStream<CodexInboundMessage> {
    stream
  }

  public func stop() {
    guard let process else { return }
    processGeneration = nil
    outputHandle?.readabilityHandler = nil
    errorHandle?.readabilityHandler = nil
    outputChunkContinuation?.finish()
    errorChunkContinuation?.finish()
    outputReadTask?.cancel()
    errorReadTask?.cancel()
    try? inputHandle?.close()
    if process.isRunning {
      process.terminate()
    }
    failPending(with: CodexTransportError.processExited(-1))
    self.process = nil
    inputHandle = nil
    outputHandle = nil
    errorHandle = nil
    outputChunkContinuation = nil
    errorChunkContinuation = nil
    outputReadTask = nil
    errorReadTask = nil
    outputBuffer.removeAll(keepingCapacity: false)
    errorBuffer.removeAll(keepingCapacity: false)
    processExitStatus = nil
    outputDidReachEOF = false
  }

  private func send(_ value: JSONValue) throws {
    guard let inputHandle else { throw CodexTransportError.notStarted }
    do {
      var data = try encoder.encode(value)
      data.append(0x0A)
      try inputHandle.write(contentsOf: data)
    } catch {
      throw CodexTransportError.writeFailed(error.localizedDescription)
    }
  }

  private func receiveOutput(_ data: Data) {
    if data.isEmpty {
      outputHandle?.readabilityHandler = nil
      outputDidReachEOF = true
      failPendingAfterProcessExitIfReady()
      return
    }
    outputBuffer.append(data)

    while let newline = outputBuffer.firstIndex(of: 0x0A) {
      let line = outputBuffer[..<newline]
      outputBuffer.removeSubrange(...newline)
      guard !line.isEmpty else { continue }
      receiveLine(Data(line))
    }
  }

  private func receiveError(_ data: Data) {
    if data.isEmpty {
      errorHandle?.readabilityHandler = nil
      return
    }
    errorBuffer.append(data)
    if errorBuffer.count > 32_768 {
      errorBuffer.removeFirst(errorBuffer.count - 32_768)
    }
  }

  private func receiveLine(_ data: Data) {
    let message: JSONValue
    do {
      message = try decoder.decode(JSONValue.self, from: data)
    } catch {
      failPending(with: CodexTransportError.invalidMessage(error.localizedDescription))
      return
    }

    guard case .object(let object) = message else {
      failPending(with: CodexTransportError.invalidMessage("Expected an object"))
      return
    }

    if let responseID = object["id"]?.integerValue,
      object["result"] != nil || object["error"] != nil
    {
      guard let request = pending.removeValue(forKey: responseID) else { return }
      request.timeout.cancel()
      if let result = object["result"] {
        request.continuation.resume(returning: result)
      } else if let error = object["error"] {
        request.continuation.resume(throwing: decodeRPCError(error))
      }
      return
    }

    guard let method = object["method"]?.stringValue else {
      failPending(with: CodexTransportError.invalidMessage("Missing method"))
      return
    }
    let params = object["params"] ?? .object([:])
    if let id = object["id"] {
      streamContinuation.yield(.request(CodexServerRequest(id: id, method: method, params: params)))
    } else {
      streamContinuation.yield(.notification(CodexNotification(method: method, params: params)))
    }
  }

  private func decodeRPCError(_ value: JSONValue) -> CodexRPCError {
    CodexRPCError(
      code: Int(value["code"]?.integerValue ?? -32_000),
      message: value["message"]?.stringValue ?? "Unknown App Server error",
      data: value["data"]
    )
  }

  private func requestDidTimeOut(id: Int64) {
    guard let request = pending.removeValue(forKey: id) else { return }
    request.continuation.resume(throwing: CodexTransportError.requestTimedOut(request.method))
  }

  private func processDidExit(status: Int32, generation: UUID) {
    guard processGeneration == generation else { return }
    processExitStatus = status
    failPendingAfterProcessExitIfReady()
  }

  private func failPendingAfterProcessExitIfReady() {
    guard outputDidReachEOF, let processExitStatus else { return }
    failPending(with: CodexTransportError.processExited(processExitStatus))
  }

  private func failPending(with error: any Error) {
    let requests = pending.values
    pending.removeAll()
    for request in requests {
      request.timeout.cancel()
      request.continuation.resume(throwing: error)
    }
  }
}
