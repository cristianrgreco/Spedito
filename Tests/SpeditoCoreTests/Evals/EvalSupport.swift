import Foundation
import SpeditoCore

/// Configuration for one eval run, read from the environment so
/// `scripts/evals.sh` can parameterize a run without code changes.
struct EvalConfiguration: Sendable {
  let models: [String]
  let efforts: [String]
  let repetitions: Int
  let scenarioFilter: [String]
  let judgeModel: String
  let judgeEffort: String
  let skipsJudge: Bool
  let runsRootURL: URL
  let codexOverridePath: String?

  static func fromEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> EvalConfiguration {
    let fallbackModel = environment["SPEDITO_EVAL_MODEL"] ?? "gpt-5.6-terra"
    let models = (environment["SPEDITO_EVAL_MODELS"] ?? fallbackModel)
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    let efforts = (environment["SPEDITO_EVAL_EFFORTS"] ?? "medium,high")
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    let repetitions = max(1, Int(environment["SPEDITO_EVAL_REPS"] ?? "") ?? 1)
    let scenarioFilter = (environment["SPEDITO_EVAL_SCENARIOS"] ?? "")
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    let runsRootURL =
      environment["SPEDITO_EVAL_RUNS"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
      } ?? EvalPaths.repositoryRootURL.appendingPathComponent(".eval-runs", isDirectory: true)
    return EvalConfiguration(
      models: models.isEmpty ? [fallbackModel] : models,
      efforts: efforts.isEmpty ? ["medium", "high"] : efforts,
      repetitions: repetitions,
      scenarioFilter: scenarioFilter,
      judgeModel: environment["SPEDITO_EVAL_JUDGE_MODEL"] ?? fallbackModel,
      judgeEffort: environment["SPEDITO_EVAL_JUDGE_EFFORT"] ?? "high",
      skipsJudge: environment["SPEDITO_EVAL_SKIP_JUDGE"] == "1",
      runsRootURL: runsRootURL,
      codexOverridePath: environment["SPEDITO_EVAL_CODEX"]
    )
  }
}

enum EvalPaths {
  /// Tests/SpeditoCoreTests/Evals/EvalSupport.swift → repository root.
  static var repositoryRootURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

enum EvalRuntimeError: Error, LocalizedError {
  case codexNotFound([String])
  case modelNotAvailable(String, available: [String])

  var errorDescription: String? {
    switch self {
    case .codexNotFound(let paths):
      "No usable Codex runtime was found. Tried: \(paths.joined(separator: ", ")). "
        + "Set SPEDITO_EVAL_CODEX to a Codex executable."
    case .modelNotAvailable(let model, let available):
      "The Codex runtime does not offer model \(model). "
        + "Available: \(available.joined(separator: ", "))."
    }
  }
}

enum EvalRetry {
  /// Retries a turn that failed only because the selected model was
  /// momentarily at capacity. Any other failure propagates immediately.
  static func withCapacityRetry<T: Sendable>(
    attempts: Int = 3,
    pause: Duration = .seconds(20),
    _ operation: () async throws -> T
  ) async throws -> T {
    var attempt = 1
    while true {
      do {
        return try await operation()
      } catch let error as CodexClientError {
        guard
          case .turnFailed(let message) = error,
          message.localizedCaseInsensitiveContains("at capacity"),
          attempt < attempts
        else { throw error }
        print("  model at capacity; retrying (\(attempt + 1)/\(attempts))…")
        try await Task.sleep(for: pause)
        attempt += 1
      }
    }
  }
}

enum EvalCodexRuntime {
  /// Resolves a Codex executable the same way the app does: the official
  /// Codex application first, then a PATH-installed binary, with an explicit
  /// override for unusual setups.
  static func resolveExecutable(overridePath: String?) throws -> CodexRuntimeDescriptor {
    var candidates: [CodexRuntimeCandidate] = []
    if let overridePath {
      candidates.append(
        CodexRuntimeCandidate(
          executableURL: URL(fileURLWithPath: overridePath),
          source: .custom
        )
      )
    }
    candidates.append(
      CodexRuntimeCandidate(
        executableURL: URL(
          fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"
        ),
        source: .officialApplication
      )
    )
    candidates.append(
      CodexRuntimeCandidate(
        executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
        source: .custom
      )
    )
    do {
      return try CodexRuntimeResolver().resolve(candidates: candidates)
    } catch {
      throw EvalRuntimeError.codexNotFound(candidates.map(\.executableURL.path))
    }
  }

  static func makeClient(descriptor: CodexRuntimeDescriptor) -> CodexAppServerClient {
    let transport = CodexJSONLTransport(
      configuration: .init(
        executableURL: descriptor.executableURL,
        environmentOverrides: CodexPermissionProfiles.agentProcessEnvironment,
        environmentMode: .replace
      )
    )
    return CodexAppServerClient(transport: transport)
  }
}

/// A temporary root owning every Git fixture an eval run needs: the shared
/// generic product repository, review candidate checkouts, and sanitized
/// analysis snapshots.
struct EvalFixtureWorkspace {
  let rootURL: URL
  let sharedRepository: EvalFixtureRepository

  static let sharedRepositoryFiles: [String: String] = [
    "README.md": """
      # Ledgerline

      A small invoicing tool for freelancers: create invoices, track payment
      status, and keep client records in one place.

      ## Development

      Ledgerline is a Node.js 22 project. `npm test` runs the test suite with
      the built-in Node test runner (tests live in `tests/*.test.js`). There is
      no build step and no server; the modules under `src/` are used directly.
      """,
    "package.json": """
      {
        "name": "ledgerline",
        "private": true,
        "type": "module",
        "scripts": {
          "test": "node --test"
        }
      }
      """,
    "src/invoices.js": """
      export function invoiceTotal(lines) {
        return lines.reduce((total, line) => total + line.amount, 0)
      }
      """,
    "src/summary.js": """
      import { invoiceTotal } from "./invoices.js"

      export function invoiceSummaryLine(invoice) {
        const total = invoiceTotal(invoice.lines)
        return `${invoice.number} — £${total.toFixed(2)} — ${invoice.status}`
      }
      """,
    "tests/invoices.test.js": """
      import test from "node:test"
      import assert from "node:assert/strict"
      import { invoiceTotal } from "../src/invoices.js"

      test("totals the line amounts", () => {
        assert.equal(invoiceTotal([{ amount: 40 }, { amount: 2.5 }]), 42.5)
      })

      test("an empty invoice totals zero", () => {
        assert.equal(invoiceTotal([]), 0)
      })
      """,
  ]

  static func make() throws -> EvalFixtureWorkspace {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("spedito-evals", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let sharedRepository = try EvalFixtureRepository.create(
      at: rootURL.appendingPathComponent("shared", isDirectory: true),
      files: sharedRepositoryFiles
    )
    return EvalFixtureWorkspace(rootURL: rootURL, sharedRepository: sharedRepository)
  }

  func makeRepository(name: String, files: [String: String]) throws -> EvalFixtureRepository {
    try EvalFixtureRepository.create(
      at: rootURL.appendingPathComponent(name, isDirectory: true),
      files: files
    )
  }

  func prepareAnalysisSnapshot(
    of repository: EvalFixtureRepository
  ) async throws -> RepositoryAnalysisSnapshot {
    let manager = GitWorkspaceManager()
    let destinationURL = rootURL
      .appendingPathComponent("snapshots", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return try await manager.prepareRepositoryAnalysisSnapshot(
      repositoryURL: repository.rootURL,
      sha: try repository.headSHA(),
      destinationURL: destinationURL
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

/// One local Git repository built from literal file contents, with the small
/// set of operations the fixtures need: commit further states and pin a
/// detached checkout the way production pins candidate review workspaces.
struct EvalFixtureRepository {
  let rootURL: URL

  static func create(at rootURL: URL, files: [String: String]) throws -> EvalFixtureRepository {
    let repository = EvalFixtureRepository(rootURL: rootURL)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try repository.git(["init", "--quiet"])
    try repository.write(files: files)
    _ = try repository.commitAll(message: "Initial fixture")
    return repository
  }

  func write(files: [String: String]) throws {
    for (path, contents) in files {
      let fileURL = rootURL.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
  }

  func commitAll(message: String) throws -> String {
    try git(["add", "."])
    try git(["commit", "--quiet", "-m", message])
    return try headSHA()
  }

  /// Adds a linked worktree on a new ticket branch, the isolation production
  /// delivery runs use.
  func addWorktree(at worktreeURL: URL, branch: String) throws {
    try git(["worktree", "add", "--quiet", "-b", branch, worktreeURL.path])
  }

  static func resetWorktree(at worktreeURL: URL, to baseSHA: String) throws {
    let repository = EvalFixtureRepository(rootURL: worktreeURL)
    try repository.git(["reset", "--hard", "--quiet", baseSHA])
    try repository.git(["clean", "-fdq"])
  }

  static func statusPorcelain(at worktreeURL: URL) throws -> String {
    let repository = EvalFixtureRepository(rootURL: worktreeURL)
    return try repository.git(["status", "--porcelain"])
  }

  static func headSHA(at worktreeURL: URL) throws -> String {
    let repository = EvalFixtureRepository(rootURL: worktreeURL)
    return try repository.git(["rev-parse", "HEAD"])
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func diff(at worktreeURL: URL, from baseSHA: String) throws -> String {
    let repository = EvalFixtureRepository(rootURL: worktreeURL)
    return try repository.git(["diff", "\(baseSHA)..HEAD"])
  }

  /// Runs the fixture project's Node test suite in a worktree and reports
  /// whether it passed, with trailing output for evidence.
  static func runNodeTests(at worktreeURL: URL) -> (passed: Bool, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", "--test"]
    process.currentDirectoryURL = worktreeURL
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
    } catch {
      return (false, "node could not be launched: \(error.localizedDescription)")
    }
    let output = String(
      decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )
    process.waitUntilExit()
    return (process.terminationStatus == 0, String(output.suffix(2_000)))
  }

  func headSHA() throws -> String {
    try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func checkoutDetached(_ sha: String) throws {
    try git(["checkout", "--quiet", "--detach", sha])
  }

  @discardableResult
  private func git(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments =
      ["-c", "user.name=Spedito Evals", "-c", "user.email=evals@spedito.local"] + arguments
    process.currentDirectoryURL = rootURL
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = environment
    let errorPipe = Pipe()
    let outputPipe = Pipe()
    process.standardError = errorPipe
    process.standardOutput = outputPipe
    try process.run()
    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let detail = String(
        decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
      )
      throw NSError(
        domain: "EvalFixtureRepository",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "git \(arguments.first ?? "") failed: \(detail)"]
      )
    }
    return String(decoding: output, as: UTF8.self)
  }
}

/// Plays a cautious product owner for delivery cells: approves command
/// approvals inside the fixture workspace and read-or-execute permission
/// grants, declines network access and writes outside the fixture root, and
/// rejects anything it does not recognize so a turn can never hang on an
/// unanswered request.
actor EvalApprovalResponder {
  private let client: CodexAppServerClient
  private let workspaceRootURL: URL
  private var task: Task<Void, Never>?
  private(set) var decisions: [String] = []

  init(client: CodexAppServerClient, workspaceRootURL: URL) {
    self.client = client
    self.workspaceRootURL = workspaceRootURL.standardizedFileURL
  }

  func start() async {
    guard task == nil else { return }
    let messages = await client.inboundMessages(replayRecent: false)
    task = Task { [weak self] in
      for await message in messages {
        guard case .request(let request) = message else { continue }
        await self?.respond(to: request)
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }

  private func respond(to request: CodexServerRequest) async {
    switch request.method {
    case "item/commandExecution/requestApproval":
      let cwd = request.params["cwd"]?.stringValue
      let insideWorkspace = cwd.map { isInsideWorkspace($0) } ?? true
      let commandAllowed = insideWorkspace
        && permissionsAllowed(request.params["additionalPermissions"])
      record(request.method, allowed: commandAllowed, detail: cwd ?? "no cwd")
      try? await client.resolveApprovalRequest(request, allow: commandAllowed)
    case "item/permissions/requestApproval":
      let allowed = permissionsAllowed(request.params["permissions"])
      record(request.method, allowed: allowed, detail: "")
      try? await client.resolveApprovalRequest(request, allow: allowed)
    default:
      record(request.method, allowed: false, detail: "unsupported")
      await client.rejectUnsupportedServerRequest(request)
    }
  }

  /// Missing or null permission payloads are fine; network access and writes
  /// outside the fixture root are not.
  private func permissionsAllowed(_ permissions: JSONValue?) -> Bool {
    guard let permissions, permissions != .null else { return true }
    if permissions["network"]?["enabled"]?.boolValue == true {
      return false
    }
    for entry in permissions["fileSystem"]?["entries"]?.arrayValue ?? [] {
      let access = entry["access"]?.stringValue ?? "write"
      if access == "read" || access == "execute" { continue }
      let path =
        entry["path"]?["path"]?.stringValue
        ?? entry["path"]?["pattern"]?.stringValue
      guard let path, isInsideWorkspace(path) else { return false }
    }
    return true
  }

  private func isInsideWorkspace(_ path: String) -> Bool {
    let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
    let root = workspaceRootURL.path
    return normalized == root || normalized.hasPrefix(root + "/")
  }

  private func record(_ method: String, allowed: Bool, detail: String) {
    let entry = "\(method): \(allowed ? "approved" : "declined") \(detail)"
    decisions.append(entry)
    print("  approval — \(entry)")
  }
}

/// The on-disk bundle for one run: results.json is rewritten after every
/// cell so an interrupted run still leaves scoreable evidence.
struct EvalRunBundle {
  let bundleURL: URL
  private let encoder: JSONEncoder

  init(runsRootURL: URL) throws {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    bundleURL = runsRootURL.appendingPathComponent(
      formatter.string(from: Date()),
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
  }

  func write(metadata: EvalRunMetadata) throws {
    try encoder.encode(metadata).write(
      to: bundleURL.appendingPathComponent("metadata.json")
    )
  }

  func write(records: [EvalCellRecord]) throws {
    try encoder.encode(records).write(
      to: bundleURL.appendingPathComponent("results.json")
    )
  }

  func write(report: String) throws {
    try report.write(
      to: bundleURL.appendingPathComponent("report.md"),
      atomically: true,
      encoding: .utf8
    )
  }
}
