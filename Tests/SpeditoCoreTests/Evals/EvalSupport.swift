import Foundation
import SpeditoCore

/// Configuration for one eval run, read from the environment so
/// `scripts/evals.sh` can parameterize a run without code changes.
struct EvalConfiguration: Sendable {
  let model: String
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
    let model = environment["SPEDITO_EVAL_MODEL"] ?? "gpt-5.6-terra"
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
      model: model,
      efforts: efforts.isEmpty ? ["medium", "high"] : efforts,
      repetitions: repetitions,
      scenarioFilter: scenarioFilter,
      judgeModel: environment["SPEDITO_EVAL_JUDGE_MODEL"] ?? model,
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

/// A small, generic local Git repository used as the read-only working
/// directory for planning threads. Planning prompts forbid repository
/// inspection, so the contents only need to be a plausible product workspace.
struct EvalFixtureRepository {
  let rootURL: URL

  static func make() throws -> EvalFixtureRepository {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("spedito-evals", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try """
    # Ledgerline

    A small invoicing tool for freelancers: create invoices, track payment
    status, and keep client records in one place.
    """.write(
      to: rootURL.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )
    let sourcesURL = rootURL.appendingPathComponent("src", isDirectory: true)
    try FileManager.default.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
    try """
    export function invoiceTotal(lines) {
      return lines.reduce((total, line) => total + line.amount, 0)
    }
    """.write(
      to: sourcesURL.appendingPathComponent("invoices.js"),
      atomically: true,
      encoding: .utf8
    )
    let repository = EvalFixtureRepository(rootURL: rootURL)
    try repository.git(["init", "--quiet"])
    try repository.git(["add", "."])
    try repository.git(["commit", "--quiet", "-m", "Initial fixture"])
    return repository
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }

  private func git(_ arguments: [String]) throws {
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
    process.standardError = errorPipe
    process.standardOutput = Pipe()
    try process.run()
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
