import Foundation
import Network
import SpeditoCore

final class StaticWebDemoServer: @unchecked Sendable {
  private final class RequestBuffer: @unchecked Sendable {
    var data = Data()
  }

  private struct Response: Sendable {
    let header: Data
    let body: Data
    let sendsBody: Bool
  }

  private let rootURL: URL
  private let fileManager: FileManager
  private let listener: NWListener
  private let queue = DispatchQueue(label: "io.spedito.static-web-demo")
  private var startContinuation: CheckedContinuation<Int, Error>?
  private var stopped = false

  init(rootURL: URL, fileManager: FileManager = .default) throws {
    self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    self.fileManager = fileManager

    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
  }

  func start() async throws -> Int {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        guard !stopped else {
          continuation.resume(throwing: CancellationError())
          return
        }
        startContinuation = continuation
        listener.stateUpdateHandler = { [weak self] state in
          self?.handle(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
          self?.receiveRequest(on: connection, buffer: RequestBuffer())
        }
        listener.start(queue: queue)
      }
    }
  }

  func stop() {
    queue.async { [self] in
      guard !stopped else { return }
      stopped = true
      listener.cancel()
      finishStart(throwing: CancellationError())
    }
  }

  private func handle(_ state: NWListener.State) {
    switch state {
    case .ready:
      guard let port = listener.port else {
        finishStart(throwing: DemoLauncherError.couldNotAllocatePort)
        return
      }
      finishStart(returning: Int(port.rawValue))
    case .failed:
      finishStart(throwing: DemoLauncherError.couldNotAllocatePort)
    case .cancelled:
      finishStart(throwing: CancellationError())
    case .setup, .waiting:
      break
    @unknown default:
      finishStart(throwing: DemoLauncherError.couldNotAllocatePort)
    }
  }

  private func finishStart(returning port: Int) {
    guard let continuation = startContinuation else { return }
    startContinuation = nil
    continuation.resume(returning: port)
  }

  private func finishStart(throwing error: Error) {
    guard let continuation = startContinuation else { return }
    startContinuation = nil
    continuation.resume(throwing: error)
  }

  private func receiveRequest(on connection: NWConnection, buffer: RequestBuffer) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) {
      [weak self, connection, buffer] content,
      _,
      isComplete,
      error in
      guard let self else {
        connection.cancel()
        return
      }
      if let content {
        buffer.data.append(content)
      }
      if buffer.data.count > 16_384 {
        send(Self.errorResponse(status: 431, reason: "Request Header Fields Too Large"), on: connection)
        return
      }
      if buffer.data.range(of: Data("\r\n\r\n".utf8)) != nil {
        send(response(for: buffer.data), on: connection)
        return
      }
      if isComplete || error != nil {
        connection.cancel()
        return
      }
      receiveRequest(on: connection, buffer: buffer)
    }
  }

  private func response(for requestData: Data) -> Response {
    guard
      let headerBoundary = requestData.range(of: Data("\r\n\r\n".utf8)),
      let header = String(data: requestData[..<headerBoundary.lowerBound], encoding: .utf8),
      let requestLine = header.split(separator: "\r\n", omittingEmptySubsequences: false).first
    else {
      return Self.errorResponse(status: 400, reason: "Bad Request")
    }
    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count == 3 else {
      return Self.errorResponse(status: 400, reason: "Bad Request")
    }
    let method = String(parts[0])
    guard method == "GET" || method == "HEAD" else {
      return Self.errorResponse(status: 405, reason: "Method Not Allowed")
    }

    do {
      let fileURL = try StaticWebResourcePolicy.resolve(
        requestTarget: String(parts[1]),
        in: rootURL,
        fileManager: fileManager
      )
      let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
      let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
      guard byteCount <= StaticWebResourcePolicy.maximumResourceBytes else {
        return Self.errorResponse(status: 413, reason: "Content Too Large")
      }
      let body = try Data(contentsOf: fileURL, options: .mappedIfSafe)
      return Self.response(
        status: 200,
        reason: "OK",
        contentType: StaticWebResourcePolicy.contentType(for: fileURL),
        body: body,
        sendsBody: method == "GET"
      )
    } catch StaticWebResourcePolicy.Error.notFound {
      return Self.errorResponse(status: 404, reason: "Not Found")
    } catch {
      return Self.errorResponse(status: 400, reason: "Bad Request")
    }
  }

  private func send(_ response: Response, on connection: NWConnection) {
    connection.send(content: response.header, completion: .contentProcessed { error in
      guard error == nil, response.sendsBody, !response.body.isEmpty else {
        connection.cancel()
        return
      }
      connection.send(content: response.body, completion: .contentProcessed { _ in
        connection.cancel()
      })
    })
  }

  private static func errorResponse(status: Int, reason: String) -> Response {
    response(
      status: status,
      reason: reason,
      contentType: "text/plain; charset=utf-8",
      body: Data("\(status) \(reason)\n".utf8),
      sendsBody: true
    )
  }

  private static func response(
    status: Int,
    reason: String,
    contentType: String,
    body: Data,
    sendsBody: Bool
  ) -> Response {
    let header = [
      "HTTP/1.1 \(status) \(reason)",
      "Content-Type: \(contentType)",
      "Content-Length: \(body.count)",
      "Cache-Control: no-store",
      """
      Content-Security-Policy: default-src 'self'; base-uri 'none'; connect-src 'none'; \
      form-action 'none'; frame-src 'none'; object-src 'none'; img-src 'self' data:; \
      media-src 'self'; font-src 'self' data:; script-src 'self' 'unsafe-inline'; \
      style-src 'self' 'unsafe-inline'
      """,
      "Referrer-Policy: no-referrer",
      "X-Content-Type-Options: nosniff",
      "Connection: close",
      "",
      "",
    ].joined(separator: "\r\n")
    return Response(header: Data(header.utf8), body: body, sendsBody: sendsBody)
  }
}

enum StaticWebResourcePolicy {
  enum Error: Swift.Error {
    case invalidPath
    case notFound
  }

  static let maximumResourceBytes = 20 * 1_024 * 1_024

  static func resolve(
    requestTarget: String,
    in rootURL: URL,
    fileManager: FileManager = .default
  ) throws -> URL {
    guard
      requestTarget.hasPrefix("/"),
      !requestTarget.hasPrefix("//"),
      let components = URLComponents(string: requestTarget),
      components.scheme == nil,
      components.host == nil,
      let decodedPath = components.percentEncodedPath.removingPercentEncoding,
      !decodedPath.contains("\\"),
      !decodedPath.contains("\0")
    else {
      throw Error.invalidPath
    }

    let pathComponents = decodedPath.split(separator: "/", omittingEmptySubsequences: false)
    guard !pathComponents.contains("."), !pathComponents.contains("..") else {
      throw Error.invalidPath
    }

    var relativePath = String(decodedPath.dropFirst())
    if relativePath.isEmpty || relativePath.hasSuffix("/") {
      relativePath.append("index.html")
    }
    var fileURL: URL
    do {
      fileURL = try DemoLaunchSpecificationValidator.resolveWorkspacePath(
        relativePath,
        in: rootURL
      )
    } catch {
      throw Error.invalidPath
    }

    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
      do {
        fileURL = try DemoLaunchSpecificationValidator.resolveWorkspacePath(
          "\(relativePath)/index.html",
          in: rootURL
        )
      } catch {
        throw Error.invalidPath
      }
    }

    let values: URLResourceValues
    do {
      values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    } catch {
      throw Error.notFound
    }
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw Error.notFound
    }
    return fileURL
  }

  static func contentType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "html", "htm": "text/html; charset=utf-8"
    case "css": "text/css; charset=utf-8"
    case "js", "mjs": "text/javascript; charset=utf-8"
    case "json", "map": "application/json; charset=utf-8"
    case "svg": "image/svg+xml"
    case "png": "image/png"
    case "jpg", "jpeg": "image/jpeg"
    case "gif": "image/gif"
    case "webp": "image/webp"
    case "ico": "image/x-icon"
    case "woff": "font/woff"
    case "woff2": "font/woff2"
    case "ttf": "font/ttf"
    case "txt", "md", "markdown": "text/plain; charset=utf-8"
    default: "application/octet-stream"
    }
  }
}
