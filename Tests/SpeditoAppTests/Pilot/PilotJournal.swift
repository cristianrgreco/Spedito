import Foundation

/// One durable record of a pilot run.
///
/// The journal is appended synchronously so an interrupted or hung run still
/// leaves a readable trail on disk. Everything the engineer loop needs to
/// triage a finding without rerunning the product lives in the bundle.
final class PilotJournal: @unchecked Sendable {
  enum Kind: String, Codable {
    case runStarted
    case runFinished
    case ownerCommand
    case observation
    case snapshot
    case finding
    case note
  }

  struct Entry: Codable {
    let at: Date
    let elapsedSeconds: Double
    let kind: Kind
    let label: String
    let detail: String?
  }

  struct Finding: Codable {
    enum Category: String, Codable {
      /// A durable-state or workflow rule was violated.
      case functional
      /// The owner had no way forward.
      case deadEnd
      /// Owner-facing text broke a stated product-language or UX convention.
      case convention
      /// Raw technical detail reached the owner.
      case leakedDiagnostic
      /// Something took implausibly long without owner-visible progress.
      case stalled
    }

    let category: Category
    let title: String
    let evidence: String
    /// Where a fix would go, when the harness can tell.
    let locationHint: String?
    let at: Date
  }

  let bundleURL: URL
  let runID: String
  private let startedAt: Date
  private let journalURL: URL
  private let queue = DispatchQueue(label: "pilot.journal")
  private var findings: [Finding] = []

  init(rootURL: URL, briefID: String) throws {
    startedAt = Date()
    let stamp = PilotJournal.stampFormatter.string(from: startedAt)
    runID = "\(stamp)-\(briefID)"
    bundleURL = rootURL.appendingPathComponent(runID, isDirectory: true)
    try FileManager.default.createDirectory(
      at: bundleURL,
      withIntermediateDirectories: true
    )
    journalURL = bundleURL.appendingPathComponent("journal.jsonl")
    FileManager.default.createFile(atPath: journalURL.path, contents: nil)
    // Name the live bundle explicitly. Picking "the newest directory" is wrong
    // while a run is still building, because the previous run's bundle is still
    // the newest and its findings get read as this run's.
    try? Data(bundleURL.path.utf8).write(
      to: rootURL.appendingPathComponent("current-run")
    )
  }

  private static let stampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }()

  func record(_ kind: Kind, _ label: String, detail: String? = nil) {
    let entry = Entry(
      at: Date(),
      elapsedSeconds: Date().timeIntervalSince(startedAt),
      kind: kind,
      label: label,
      detail: detail
    )
    queue.sync {
      guard let line = try? PilotJournal.encoder.encode(entry),
        let handle = try? FileHandle(forWritingTo: journalURL)
      else { return }
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: line)
      try? handle.write(contentsOf: Data("\n".utf8))
    }
    FileHandle.standardError.write(
      Data("[pilot \(Int(entry.elapsedSeconds))s] \(kind.rawValue): \(label)\n".utf8)
    )
  }

  func file(_ finding: Finding) {
    queue.sync { findings.append(finding) }
    record(
      .finding,
      "\(finding.category.rawValue): \(finding.title)",
      detail: finding.evidence
    )
  }

  var currentFindings: [Finding] {
    queue.sync { findings }
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  /// Copies the durable evidence an engineer needs: the product database, every
  /// Codex rollout referenced by the run, and the git state of each workspace.
  func captureEvidence(
    productWorkspacesRootURL: URL,
    codexThreadIDs: Set<String>
  ) {
    let evidenceURL = bundleURL.appendingPathComponent("evidence", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: evidenceURL,
      withIntermediateDirectories: true
    )

    if let workspaces = try? FileManager.default.contentsOfDirectory(
      at: productWorkspacesRootURL,
      includingPropertiesForKeys: nil
    ) {
      for workspace in workspaces {
        let database = workspace
          .appendingPathComponent(".spedito", isDirectory: true)
          .appendingPathComponent("product.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else { continue }
        let destination = evidenceURL.appendingPathComponent(
          "\(workspace.lastPathComponent)-product.sqlite"
        )
        try? FileManager.default.copyItem(at: database, to: destination)
        // SQLite keeps recent commits in the write-ahead log until something
        // checkpoints them, so the database file alone holds whatever was last
        // checkpointed. Run 9 captured a 4KB file with no schema in it, and it
        // was the first run ever to reach a demo. Copying the log beside it lets
        // the evidence database replay everything the run committed.
        for suffix in ["-wal", "-shm"] {
          let sidecar = URL(fileURLWithPath: database.path + suffix)
          guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
          try? FileManager.default.copyItem(
            at: sidecar,
            to: URL(fileURLWithPath: destination.path + suffix)
          )
        }
      }
    }

    copyRollouts(for: codexThreadIDs, into: evidenceURL)
    writeFindingsReport()
  }

  /// Codex writes one rollout per thread under `~/.codex/sessions/<y>/<m>/<d>/`.
  /// The file name embeds the thread identifier Spedito persists on each run.
  private func copyRollouts(for threadIDs: Set<String>, into evidenceURL: URL) {
    guard !threadIDs.isEmpty else { return }
    let sessionsURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/sessions", isDirectory: true)
    guard
      let walker = FileManager.default.enumerator(
        at: sessionsURL,
        includingPropertiesForKeys: nil
      )
    else { return }
    let threadsURL = evidenceURL.appendingPathComponent("codex-threads", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: threadsURL,
      withIntermediateDirectories: true
    )
    for case let fileURL as URL in walker {
      guard fileURL.pathExtension == "jsonl" else { continue }
      let name = fileURL.lastPathComponent
      guard threadIDs.contains(where: { name.contains($0) }) else { continue }
      try? FileManager.default.copyItem(
        at: fileURL,
        to: threadsURL.appendingPathComponent(name)
      )
    }
  }

  func writeFindingsReport() {
    let findings = currentFindings
    var report = "# Pilot run \(runID)\n\n"
    if findings.isEmpty {
      report += "No findings. The owner reached the end of the journey without "
      report += "hitting a dead end, a convention violation, or a stall.\n"
    } else {
      report += "\(findings.count) finding(s).\n\n"
      for (index, finding) in findings.enumerated() {
        report += "## \(index + 1). \(finding.title)\n\n"
        report += "- **Category:** \(finding.category.rawValue)\n"
        if let hint = finding.locationHint {
          report += "- **Likely location:** \(hint)\n"
        }
        report += "- **Observed at:** \(ISO8601DateFormatter().string(from: finding.at))\n\n"
        report += "```\n\(finding.evidence)\n```\n\n"
      }
    }
    try? report.write(
      to: bundleURL.appendingPathComponent("findings.md"),
      atomically: true,
      encoding: .utf8
    )
  }
}
