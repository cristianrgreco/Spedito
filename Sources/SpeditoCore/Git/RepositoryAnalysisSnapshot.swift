import CryptoKit
import Foundation

public struct RepositorySourcePathPolicy: Sendable {
  public init() {}

  public func allows(_ entry: GitRepositoryTreeEntry) -> Bool {
    guard entry.objectType == "blob", entry.mode == "100644" || entry.mode == "100755" else {
      return false
    }
    let components = entry.collisionKey.split(separator: "/").map(String.init)
    guard !components.isEmpty else { return false }
    for component in components {
      if component == ".git" || component == ".spedito" { return false }
      if component == ".env" || component.hasPrefix(".env.") || component == ".envrc" {
        return false
      }
      if component == ".secrets" || component == "secrets" || component == "credentials" {
        return false
      }
      if component == ".git-credentials" || component == ".netrc"
        || component == "id_rsa" || component == "id_ed25519"
      {
        return false
      }
      let pathExtension = URL(fileURLWithPath: component).pathExtension.lowercased()
      if ["pem", "key", "p12", "pfx"].contains(pathExtension) { return false }
    }
    return true
  }

  /// Checks a cited evidence path against the sanitized snapshot and returns the citation with
  /// its line range bounded to the file.
  ///
  /// A path outside the snapshot stays a hard failure: it means the analysis reached beyond the
  /// evidence it was given. A line range is only a pointer into a file the analyzer was already
  /// shown in full, so a range that runs past the end of an available file is narrowed to what
  /// the file contains rather than discarding the whole analysis.
  public func normalized(
    evidence: RepositoryEvidence,
    snapshotURL: URL,
    allowedPaths: Set<String>
  ) throws -> RepositoryEvidence {
    guard allowedPaths.contains(evidence.path),
      !evidence.path.hasPrefix("/"),
      !evidence.path.split(separator: "/").contains("..")
    else {
      throw RepositoryAnalysisSnapshotError.invalidEvidence(evidence.path)
    }
    guard (evidence.startLine == nil) == (evidence.endLine == nil) else {
      throw RepositoryAnalysisSnapshotError.invalidEvidence(evidence.path)
    }
    guard let startLine = evidence.startLine, let endLine = evidence.endLine else {
      return evidence
    }
    guard startLine > 0, endLine >= startLine else {
      throw RepositoryAnalysisSnapshotError.invalidEvidence(evidence.path)
    }
    let data = try Data(contentsOf: snapshotURL.appendingPathComponent(evidence.path))
    guard let text = String(data: data, encoding: .utf8) else {
      throw RepositoryAnalysisSnapshotError.invalidEvidence(evidence.path)
    }
    let lineCount = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
    guard startLine <= lineCount else {
      return RepositoryEvidence(path: evidence.path)
    }
    return RepositoryEvidence(
      path: evidence.path,
      startLine: startLine,
      endLine: min(endLine, lineCount)
    )
  }
}

public struct RepositoryAnalysisSnapshot: Equatable, Sendable {
  public let url: URL
  public let analyzedSHA: String
  public let allowedPaths: [String]
  public let integrityDigest: String

  public init(url: URL, analyzedSHA: String, allowedPaths: [String], integrityDigest: String) {
    self.url = url
    self.analyzedSHA = analyzedSHA
    self.allowedPaths = allowedPaths
    self.integrityDigest = integrityDigest
  }
}

public enum RepositoryAnalysisSnapshotError: Error, Equatable, LocalizedError, Sendable {
  case invalidDestination
  case invalidEvidence(String)
  case integrityFailure

  public var errorDescription: String? {
    switch self {
    case .invalidDestination:
      "Spedito couldn't prepare a safe repository analysis workspace."
    case .invalidEvidence(let path):
      "Repository knowledge cited unavailable evidence at \(path)."
    case .integrityFailure:
      "The repository analysis snapshot did not pass its integrity check."
    }
  }
}

private struct RepositoryAnalysisSnapshotMarker: Codable, Equatable {
  struct FileRecord: Codable, Equatable {
    let path: String
    let digest: String
  }

  let analyzedSHA: String
  let integrityDigest: String
  let files: [FileRecord]
}

extension GitWorkspaceManager {
  public func prepareRepositoryAnalysisSnapshot(
    repositoryURL: URL,
    sha: String,
    destinationURL: URL,
    policy: RepositorySourcePathPolicy = RepositorySourcePathPolicy()
  ) throws -> RepositoryAnalysisSnapshot {
    guard UUID(uuidString: destinationURL.lastPathComponent) != nil else {
      throw RepositoryAnalysisSnapshotError.invalidDestination
    }
    let fileManager = FileManager.default
    let parentURL = destinationURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

    if fileManager.fileExists(atPath: destinationURL.path) {
      if let snapshot = try? Self.validateSnapshot(at: destinationURL, expectedSHA: sha) {
        return snapshot
      }
      try Self.removeOwnedSnapshot(at: destinationURL, fileManager: fileManager)
    }

    let stagingURL = parentURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
    do {
      let tree = try repositoryTreeEntries(at: repositoryURL, sha: sha)
      let entries = tree.entries.filter(policy.allows).sorted { $0.collisionKey < $1.collisionKey }
      var records: [RepositoryAnalysisSnapshotMarker.FileRecord] = []
      for entry in entries {
        let data = try repositoryBlobData(at: repositoryURL, objectSHA: entry.objectSHA)
        let fileURL = stagingURL.appendingPathComponent(entry.path)
        try fileManager.createDirectory(
          at: fileURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: fileURL.path)
        records.append(.init(path: entry.path, digest: Self.sha256(data)))
      }
      records.sort { $0.path < $1.path }
      let integrityDigest = Self.snapshotDigest(sha: sha, records: records)
      let marker = RepositoryAnalysisSnapshotMarker(
        analyzedSHA: sha,
        integrityDigest: integrityDigest,
        files: records
      )
      let markerURL = stagingURL.appendingPathComponent(".snapshot-complete.json")
      let markerData = try JSONEncoder().encode(marker)
      try markerData.write(to: markerURL, options: .atomic)
      let markerHandle = try FileHandle(forWritingTo: markerURL)
      try markerHandle.synchronize()
      try markerHandle.close()
      try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: markerURL.path)
      try fileManager.moveItem(at: stagingURL, to: destinationURL)
      try Self.makeDirectoriesReadOnly(at: destinationURL, fileManager: fileManager)
      return try Self.validateSnapshot(at: destinationURL, expectedSHA: sha)
    } catch {
      try? Self.removeOwnedSnapshot(at: stagingURL, fileManager: fileManager)
      try? Self.removeOwnedSnapshot(at: destinationURL, fileManager: fileManager)
      throw error
    }
  }

  public nonisolated static func cleanupRepositoryAnalysisSnapshots(
    rootURL: URL,
    retaining retainedIDs: Set<UUID> = [],
    fileManager: FileManager = .default
  ) throws {
    guard fileManager.fileExists(atPath: rootURL.path) else { return }
    let children = try fileManager.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    for child in children {
      guard let id = UUID(uuidString: child.lastPathComponent), !retainedIDs.contains(id) else {
        continue
      }
      try removeOwnedSnapshot(at: child, fileManager: fileManager)
    }
  }

  public nonisolated static func removeRepositoryAnalysisSnapshot(
    at url: URL,
    fileManager: FileManager = .default
  ) throws {
    try removeOwnedSnapshot(at: url, fileManager: fileManager)
  }

  private nonisolated static func validateSnapshot(
    at url: URL,
    expectedSHA: String
  ) throws -> RepositoryAnalysisSnapshot {
    let markerURL = url.appendingPathComponent(".snapshot-complete.json")
    let marker = try JSONDecoder().decode(
      RepositoryAnalysisSnapshotMarker.self,
      from: Data(contentsOf: markerURL)
    )
    guard marker.analyzedSHA == expectedSHA else {
      throw RepositoryAnalysisSnapshotError.integrityFailure
    }
    let fileManager = FileManager.default
    var actualPaths: [String] = []
    for record in marker.files {
      let fileURL = url.appendingPathComponent(record.path)
      let values = try fileURL.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw RepositoryAnalysisSnapshotError.integrityFailure
      }

      let data = try Data(contentsOf: fileURL)
      guard sha256(data) == record.digest else {
        throw RepositoryAnalysisSnapshotError.integrityFailure
      }
      actualPaths.append(record.path)
    }
    let enumerator = fileManager.enumerator(
      at: url,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    var enumeratedFiles: [String] = []
    let rootPath = url.resolvingSymlinksInPath().path
    while let fileURL = enumerator?.nextObject() as? URL {
      let values = try fileURL.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey,
      ])
      guard values.isSymbolicLink != true else {
        throw RepositoryAnalysisSnapshotError.integrityFailure
      }
      if values.isRegularFile == true, fileURL.lastPathComponent != ".snapshot-complete.json" {
        let filePath = fileURL.resolvingSymlinksInPath().path
        enumeratedFiles.append(
          String(filePath.dropFirst(rootPath.count + 1))
            .precomposedStringWithCanonicalMapping
        )
      }
    }
    guard enumeratedFiles.sorted() == actualPaths.sorted(),
      snapshotDigest(sha: expectedSHA, records: marker.files) == marker.integrityDigest
    else {
      throw RepositoryAnalysisSnapshotError.integrityFailure
    }
    return RepositoryAnalysisSnapshot(
      url: url,
      analyzedSHA: expectedSHA,
      allowedPaths: actualPaths.sorted(),
      integrityDigest: marker.integrityDigest
    )
  }

  private nonisolated static func snapshotDigest(
    sha: String,
    records: [RepositoryAnalysisSnapshotMarker.FileRecord]
  ) -> String {
    var data = Data(sha.utf8)
    for record in records.sorted(by: { $0.path < $1.path }) {
      data.append(0)
      data.append(contentsOf: record.path.utf8)
      data.append(0)
      data.append(contentsOf: record.digest.utf8)
    }
    return sha256(data)
  }

  private nonisolated static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private nonisolated static func makeDirectoriesReadOnly(
    at rootURL: URL,
    fileManager: FileManager
  ) throws {
    let enumerator = fileManager.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey]
    )
    var directories: [URL] = [rootURL]
    while let url = enumerator?.nextObject() as? URL {
      if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
        directories.append(url)
      }
    }
    for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
      try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    }
  }

  private nonisolated static func removeOwnedSnapshot(
    at url: URL,
    fileManager: FileManager
  ) throws {
    guard UUID(uuidString: url.lastPathComponent) != nil else {
      throw RepositoryAnalysisSnapshotError.invalidDestination
    }
    guard fileManager.fileExists(atPath: url.path) else { return }
    let enumerator = fileManager.enumerator(
      at: url,
      includingPropertiesForKeys: [.isDirectoryKey]
    )
    var directories: [URL] = [url]
    while let child = enumerator?.nextObject() as? URL {
      if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
        directories.append(child)
      }
    }
    for directory in directories {
      try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    try fileManager.removeItem(at: url)
  }
}
