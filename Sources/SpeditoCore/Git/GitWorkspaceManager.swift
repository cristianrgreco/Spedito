import Foundation

public enum GitWorkspaceError: Error, LocalizedError, Sendable {
  case commandFailed(arguments: [String], output: String)
  case invalidRepository(String)
  case mergeConflict(worktreePath: String, conflictedFiles: [String], output: String)
  case operationInProgress

  public var errorDescription: String? {
    switch self {
    case .commandFailed(let arguments, let output):
      let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
      return "Git \(arguments.joined(separator: " ")) failed\(detail.isEmpty ? "." : ": \(detail)")"
    case .invalidRepository(let detail):
      return "The product workspace is not ready for isolated delivery: \(detail)"
    case .mergeConflict(_, let conflictedFiles, _):
      return
        "Candidate integration needs conflict resolution in: \(conflictedFiles.joined(separator: ", "))."
    case .operationInProgress:
      return "Another Git operation is already changing this Product workspace. Try again shortly."
    }
  }
}

public struct GitTicketWorkspace: Equatable, Sendable {
  public let url: URL
  public let branchName: String
  public let baseSHA: String

  public init(url: URL, branchName: String, baseSHA: String) {
    self.url = url
    self.branchName = branchName
    self.baseSHA = baseSHA
  }
}

public struct GitCandidateSnapshot: Equatable, Sendable {
  public let branchName: String
  public let baseSHA: String
  public let headSHA: String
  public let commitCount: Int
  public let changedFiles: [String]

  public init(
    branchName: String,
    baseSHA: String,
    headSHA: String,
    commitCount: Int,
    changedFiles: [String]
  ) {
    self.branchName = branchName
    self.baseSHA = baseSHA
    self.headSHA = headSHA
    self.commitCount = commitCount
    self.changedFiles = changedFiles
  }
}

public struct GitIntegrationSnapshot: Equatable, Sendable {
  public let url: URL
  public let integratedSHA: String

  public init(url: URL, integratedSHA: String) {
    self.url = url
    self.integratedSHA = integratedSHA
  }
}

public struct GitBranchSnapshot: Identifiable, Equatable, Sendable {
  public var id: String { name }
  public let name: String
  public let headSHA: String
  public let worktreePath: String?
  public let dirtyFileCount: Int
  public let aheadOfTrunk: Int
  public let behindTrunk: Int
  public let commitSHAs: [String]
  public let lastCommitAt: Date
  public let lastCommitSubject: String

  public init(
    name: String,
    headSHA: String,
    worktreePath: String?,
    dirtyFileCount: Int,
    aheadOfTrunk: Int,
    behindTrunk: Int,
    commitSHAs: [String] = [],
    lastCommitAt: Date,
    lastCommitSubject: String
  ) {
    self.name = name
    self.headSHA = headSHA
    self.worktreePath = worktreePath
    self.dirtyFileCount = dirtyFileCount
    self.aheadOfTrunk = aheadOfTrunk
    self.behindTrunk = behindTrunk
    self.commitSHAs = commitSHAs
    self.lastCommitAt = lastCommitAt
    self.lastCommitSubject = lastCommitSubject
  }
}

public struct GitCommitSummary: Identifiable, Equatable, Sendable {
  public var id: String { sha }
  public let sha: String
  public let parentSHAs: [String]
  public let authorName: String
  public let authorEmail: String
  public let committedAt: Date
  public let references: [String]
  public let subject: String
  public let isOnTrunk: Bool

  public init(
    sha: String,
    parentSHAs: [String],
    authorName: String,
    authorEmail: String,
    committedAt: Date,
    references: [String],
    subject: String,
    isOnTrunk: Bool
  ) {
    self.sha = sha
    self.parentSHAs = parentSHAs
    self.authorName = authorName
    self.authorEmail = authorEmail
    self.committedAt = committedAt
    self.references = references
    self.subject = subject
    self.isOnTrunk = isOnTrunk
  }

  public var shortSHA: String {
    String(sha.prefix(8))
  }
}

public struct GitChangedFile: Identifiable, Equatable, Sendable {
  public var id: String { "\(status):\(path)" }
  public let status: String
  public let path: String

  public init(status: String, path: String) {
    self.status = status
    self.path = path
  }
}

public struct GitCommitDetail: Equatable, Sendable {
  public let commit: GitCommitSummary
  public let files: [GitChangedFile]
  public let unifiedDiff: String
  public let isDiffTruncated: Bool

  public init(
    commit: GitCommitSummary,
    files: [GitChangedFile],
    unifiedDiff: String,
    isDiffTruncated: Bool
  ) {
    self.commit = commit
    self.files = files
    self.unifiedDiff = unifiedDiff
    self.isDiffTruncated = isDiffTruncated
  }
}

public struct GitBranchDetail: Equatable, Sendable {
  public let branch: GitBranchSnapshot
  public let files: [GitChangedFile]
  public let unifiedDiff: String
  public let isDiffTruncated: Bool

  public init(
    branch: GitBranchSnapshot,
    files: [GitChangedFile],
    unifiedDiff: String,
    isDiffTruncated: Bool
  ) {
    self.branch = branch
    self.files = files
    self.unifiedDiff = unifiedDiff
    self.isDiffTruncated = isDiffTruncated
  }
}

public struct GitRepositorySnapshot: Equatable, Sendable {
  public let trunkSHA: String
  public let branches: [GitBranchSnapshot]
  public let commits: [GitCommitSummary]
  public let refreshedAt: Date

  public init(
    trunkSHA: String,
    branches: [GitBranchSnapshot],
    commits: [GitCommitSummary],
    refreshedAt: Date = Date()
  ) {
    self.trunkSHA = trunkSHA
    self.branches = branches
    self.commits = commits
    self.refreshedAt = refreshedAt
  }
}

public struct GitImportedRepository: Equatable, Sendable {
  public static let emptyBranchMarker = "import-empty-default-branch"
  public static let controlCollisionMarker = "import-control-path-collision"

  public let sourceDefaultBranch: String
  public let importedSHA: String

  public init(
    sourceDefaultBranch: String,
    importedSHA: String
  ) {
    self.sourceDefaultBranch = sourceDefaultBranch
    self.importedSHA = importedSHA
  }
}

public struct GitRepositoryTreeEntry: Equatable, Sendable {
  public let mode: String
  public let objectType: String
  public let objectSHA: String
  public let path: String
  public let collisionKey: String

  public init(
    mode: String,
    objectType: String,
    objectSHA: String,
    path: String,
    collisionKey: String
  ) {
    self.mode = mode
    self.objectType = objectType
    self.objectSHA = objectSHA
    self.path = path
    self.collisionKey = collisionKey
  }
}

public struct RepositoryKnowledgeExportResult: Equatable, Sendable {
  public let managedPaths: [String]
  public let touchedPaths: [String]
  public let skippedPaths: [String]
  public let expectedDigests: [String: String]
  public let expectedContents: [String: Data]

  public init(
    managedPaths: [String],
    touchedPaths: [String],
    skippedPaths: [String],
    expectedContents: [String: Data] = [:],
    expectedDigests: [String: String]
  ) {
    self.managedPaths = managedPaths.sorted()
    self.touchedPaths = touchedPaths.sorted()
    self.skippedPaths = skippedPaths.sorted()
    self.expectedDigests = expectedDigests
    self.expectedContents = expectedContents
  }
}

public actor GitWorkspaceManager {
  private let executableURL: URL
  let fileManager: FileManager
  private let commandHomeURL: URL
  @TaskLocal private static var repositoryOperationID: UUID?

  private struct RepositoryOperationWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, Never>
  }

  private var activeRepositoryOperationIDs: [String: UUID] = [:]
  private var repositoryOperationWaiters: [String: [RepositoryOperationWaiter]] = [:]

  public init(
    executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
    fileManager: FileManager = .default
  ) {
    self.executableURL = executableURL
    self.fileManager = fileManager
    commandHomeURL = fileManager.temporaryDirectory.appendingPathComponent(
      "Spedito-Git-\(UUID().uuidString)",
      isDirectory: true
    )
  }

  public func clonePublicRepository(
    from sourceURL: URL,
    to destinationURL: URL,
    credentialConfiguration: GitCredentialSessionConfiguration? = nil,
    timeout: Duration = .seconds(120)
  ) async throws -> GitImportedRepository {
    guard sourceURL.scheme?.lowercased() == "https", sourceURL.host != nil else {
      throw GitWorkspaceError.invalidRepository("import-clone-failed")
    }
    try fileManager.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      throw GitWorkspaceError.invalidRepository("import-clone-failed")
    }

    do {
      let credentialArguments = credentialConfiguration?.gitConfigurationArguments ?? []
      let cloneResult = try await runDataAsync(
        credentialArguments + [
          "-c", "http.followRedirects=false",
          "-c", "filter.lfs.smudge=",
          "-c", "filter.lfs.required=false",
          "clone", "--no-recurse-submodules", "--origin", "origin", "--",
          sourceURL.absoluteString, destinationURL.path,
        ],
        at: destinationURL.deletingLastPathComponent(),
        environmentOverrides: ["GIT_LFS_SKIP_SMUDGE": "1"],
        timeout: timeout
      )
      guard cloneResult.status == 0 else {
        throw GitWorkspaceError.invalidRepository("import-clone-failed")
      }
      try Task.checkCancellation()

      let sourceBranch = try run(["branch", "--show-current"], at: destinationURL)
      guard !sourceBranch.isEmpty,
        let importedSHA = try? run(["rev-parse", "--verify", "HEAD^{commit}"], at: destinationURL),
        !importedSHA.isEmpty
      else {
        throw GitWorkspaceError.invalidRepository(GitImportedRepository.emptyBranchMarker)
      }

      let tree = try repositoryTreeEntries(at: destinationURL, sha: importedSHA)
      if tree.entries.contains(where: {
        $0.collisionKey.split(separator: "/", maxSplits: 1).first == ".spedito"
      }) {
        throw GitWorkspaceError.invalidRepository(GitImportedRepository.controlCollisionMarker)
      }
      guard try repositoryDirtyPaths(at: destinationURL).isEmpty else {
        throw GitWorkspaceError.invalidRepository("import-clone-failed")
      }

      _ = try? run(
        ["remote", "set-head", "origin", sourceBranch],
        at: destinationURL
      )
      _ = try run(["branch", "-m", "trunk"], at: destinationURL)
      try configureIdentity(at: destinationURL)
      try ensureControlDirectoryExcluded(at: destinationURL)
      guard try run(["rev-parse", "trunk"], at: destinationURL) == importedSHA,
        try run(["remote", "get-url", "origin"], at: destinationURL) == sourceURL.absoluteString,
        try repositoryDirtyPaths(at: destinationURL).isEmpty
      else {
        throw GitWorkspaceError.invalidRepository("import-clone-failed")
      }
      return GitImportedRepository(
        sourceDefaultBranch: sourceBranch,
        importedSHA: importedSHA
      )
    } catch {
      try? fileManager.removeItem(at: destinationURL)
      throw error
    }
  }

  public func repositoryTreeEntries(
    at repositoryURL: URL,
    sha: String
  ) throws -> (entries: [GitRepositoryTreeEntry], hasUndecodablePaths: Bool) {
    let result = try runDataAllowingFailure(
      ["ls-tree", "-r", "-z", "--full-tree", sha],
      at: repositoryURL
    )
    guard result.status == 0 else {
      throw GitWorkspaceError.invalidRepository("The repository revision is unavailable.")
    }
    var entries: [GitRepositoryTreeEntry] = []
    var hasUndecodablePaths = false
    for record in result.output.split(separator: 0, omittingEmptySubsequences: true) {
      guard let tab = record.firstIndex(of: 9) else {
        throw GitWorkspaceError.invalidRepository("The repository tree is malformed.")
      }
      let metadata = record[..<tab]
      let pathBytes = record[record.index(after: tab)...]
      guard
        let metadataString = String(bytes: metadata, encoding: .utf8),
        let path = String(bytes: pathBytes, encoding: .utf8)
      else {
        hasUndecodablePaths = true
        continue
      }
      let fields = metadataString.split(separator: " ", omittingEmptySubsequences: true)
      guard fields.count == 3,
        let normalizedPath = validatedRepositoryPath(path)
      else {
        throw GitWorkspaceError.invalidRepository("The repository contains an unsafe path.")
      }
      entries.append(
        GitRepositoryTreeEntry(
          mode: String(fields[0]),
          objectType: String(fields[1]),
          objectSHA: String(fields[2]),
          path: normalizedPath,
          collisionKey: repositoryPathCollisionKey(normalizedPath)
        )
      )
    }
    entries.sort {
      if $0.collisionKey != $1.collisionKey { return $0.collisionKey < $1.collisionKey }
      return $0.path < $1.path
    }
    return (entries, hasUndecodablePaths)
  }

  public func repositoryBlobData(
    at repositoryURL: URL,
    objectSHA: String
  ) throws -> Data {
    let result = try runDataAllowingFailure(
      ["cat-file", "blob", objectSHA],
      at: repositoryURL
    )
    guard result.status == 0 else {
      throw GitWorkspaceError.invalidRepository("A repository source file is unavailable.")
    }
    return result.output
  }

  public func repositoryDirtyPaths(at repositoryURL: URL) throws -> [String] {
    let commands = [
      ["diff", "--name-only", "-z", "--"],
      ["diff", "--cached", "--name-only", "-z", "--"],
      ["ls-files", "--others", "--exclude-standard", "-z", "--"],
    ]
    var paths: Set<String> = []
    for command in commands {
      let result = try runDataAllowingFailure(command, at: repositoryURL)
      guard result.status == 0 else {
        throw GitWorkspaceError.invalidRepository("The repository status is unavailable.")
      }
      for bytes in result.output.split(separator: 0, omittingEmptySubsequences: true) {
        guard
          let decoded = String(bytes: bytes, encoding: .utf8),
          let path = validatedRepositoryPath(decoded)
        else {
          throw GitWorkspaceError.invalidRepository(
            "The repository contains an undecodable changed path."
          )
        }
        paths.insert(path)
      }
    }
    return paths.sorted {
      let lhs = repositoryPathCollisionKey($0)
      let rhs = repositoryPathCollisionKey($1)
      return lhs == rhs ? $0 < $1 : lhs < rhs
    }
  }

  public nonisolated static func repositoryPathCollisionKey(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping
      .split(separator: "/", omittingEmptySubsequences: false)
      .map {
        String($0).folding(
          options: [.caseInsensitive],
          locale: Locale(identifier: "en_US_POSIX")
        )
      }
      .joined(separator: "/")
  }

  private func repositoryPathCollisionKey(_ path: String) -> String {
    Self.repositoryPathCollisionKey(path)
  }

  private func validatedRepositoryPath(_ path: String) -> String? {
    let normalized = path.precomposedStringWithCanonicalMapping
    guard !normalized.isEmpty, !normalized.hasPrefix("/"), !normalized.contains("\\0")
    else { return nil }
    let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { return nil }
    return normalized
  }

  public func ensureControlDirectoryExcluded(at repositoryURL: URL) throws {
    let excludeURL =
      repositoryURL
      .appendingPathComponent(".git", isDirectory: true)
      .appendingPathComponent("info", isDirectory: true)
      .appendingPathComponent("exclude")
    try fileManager.createDirectory(
      at: excludeURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
    guard !existing.split(whereSeparator: \.isNewline).contains("/.spedito/") else {
      return
    }
    let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
    try Data("\(existing)\(separator)/.spedito/\n".utf8).write(
      to: excludeURL,
      options: .atomic
    )
  }
  public func acceptedTrunkSHA(at repositoryURL: URL) throws -> String {
    guard try run(["branch", "--show-current"], at: repositoryURL) == "trunk",
      try repositoryDirtyPaths(at: repositoryURL).isEmpty
    else {
      throw GitWorkspaceError.invalidRepository(
        "The accepted product workspace must be clean and remain on trunk."
      )
    }
    return try run(["rev-parse", "trunk"], at: repositoryURL)
  }

  public func validateRepositoryAnalysisRevision(
    at repositoryURL: URL,
    sha: String,
    evidence: [RepositoryEvidence],
    policy: RepositorySourcePathPolicy = RepositorySourcePathPolicy(),
    requiresCleanWorkspace: Bool = true,
    requiresTrunkRevisionMatch: Bool = true
  ) throws {
    let workspaceIsValid: Bool
    if requiresCleanWorkspace {
      workspaceIsValid = try repositoryDirtyPaths(at: repositoryURL).isEmpty
    } else {
      workspaceIsValid = true
    }
    let isOnTrunk = try run(["branch", "--show-current"], at: repositoryURL) == "trunk"
    let trunkMatchesRevision: Bool
    if requiresTrunkRevisionMatch {
      trunkMatchesRevision = try run(["rev-parse", "trunk"], at: repositoryURL) == sha
    } else {
      trunkMatchesRevision = true
    }
    guard isOnTrunk, trunkMatchesRevision, workspaceIsValid else {
      throw GitWorkspaceError.invalidRepository(
        "Repository knowledge is stale because accepted trunk or its files changed."
      )
    }
    let entries = try repositoryTreeEntries(at: repositoryURL, sha: sha).entries
    let allowedPaths = Set(entries.filter(policy.allows).map(\.path))
    guard evidence.allSatisfy({ allowedPaths.contains($0.path) }) else {
      throw GitWorkspaceError.invalidRepository(
        "Repository knowledge evidence no longer matches the analyzed revision."
      )
    }
  }

  public func repositoryKnowledgeExportDisposition(
    at repositoryURL: URL,
    paths: [String]
  ) throws -> (allowed: [String], skipped: [String]) {
    var allowed: [String] = []
    var skipped: [String] = []
    for path in paths.sorted() {
      let ignored = try runAllowingFailure(
        ["check-ignore", "--quiet", "--no-index", "--", path],
        at: repositoryURL
      )
      if ignored.status == 0 {
        skipped.append(path)
        continue
      }
      guard ignored.status == 1 else {
        throw GitWorkspaceError.invalidRepository("Repository ignore rules could not be checked.")
      }
      let attributes = try runDataAllowingFailure(
        ["check-attr", "-z", "filter", "--", path],
        at: repositoryURL
      )
      guard attributes.status == 0 else {
        throw GitWorkspaceError.invalidRepository(
          "Repository content filters could not be checked."
        )
      }
      let fields = attributes.output.split(separator: 0, omittingEmptySubsequences: false)
      guard fields.count >= 3, let value = String(bytes: fields[2], encoding: .utf8) else {
        throw GitWorkspaceError.invalidRepository(
          "Repository content filters returned an invalid result."
        )
      }
      if value == "unspecified" || value == "unset" || value.isEmpty {
        allowed.append(path)
      } else {
        skipped.append(path)
      }
    }
    return (allowed, skipped)
  }

  public func checkpointRepositoryKnowledge(
    at repositoryURL: URL,
    analyzedSHA: String,
    expectedFiles: [String: Data],
    message: String = "Publish imported product knowledge"
  ) throws -> String {
    guard try run(["branch", "--show-current"], at: repositoryURL) == "trunk",
      try run(["rev-parse", "trunk"], at: repositoryURL) == analyzedSHA
    else {
      throw GitWorkspaceError.invalidRepository(
        "Repository knowledge is stale because accepted trunk changed."
      )
    }
    let expectedPaths = Set(expectedFiles.keys)
    guard Set(try repositoryDirtyPaths(at: repositoryURL)) == expectedPaths else {
      throw GitWorkspaceError.invalidRepository(
        "Repository knowledge files do not match the prepared publication."
      )
    }
    for (path, expectedData) in expectedFiles {
      guard try Data(contentsOf: repositoryURL.appendingPathComponent(path)) == expectedData else {
        throw GitWorkspaceError.invalidRepository(
          "A repository knowledge file changed before publication."
        )
      }
    }
    do {
      if !expectedPaths.isEmpty {
        _ = try run(["add", "--"] + expectedPaths.sorted(), at: repositoryURL)
      }
      let staged = try nulPaths(
        runDataAllowingFailure(
          ["diff", "--cached", "--name-only", "--no-renames", "-z", analyzedSHA, "--"],
          at: repositoryURL
        )
      )
      guard Set(staged) == expectedPaths else {
        throw GitWorkspaceError.invalidRepository(
          "Only prepared repository knowledge files may be committed."
        )
      }
      let treeSHA = try run(["write-tree"], at: repositoryURL)
      let commitSHA = try run(
        ["commit-tree", treeSHA, "-p", analyzedSHA, "-m", message],
        at: repositoryURL
      )
      let metadata = try run(
        ["show", "-s", "--format=%P%x00%an%x00%ae%x00%s", commitSHA],
        at: repositoryURL
      ).split(separator: "\0", omittingEmptySubsequences: false)
      guard metadata.count == 4,
        metadata[0] == analyzedSHA,
        metadata[1] == "Spedito",
        metadata[2] == "spedito@localhost",
        metadata[3] == message
      else {
        throw GitWorkspaceError.invalidRepository(
          "The repository knowledge commit did not pass provenance validation."
        )
      }
      let changed = try nulPaths(
        runDataAllowingFailure(
          ["diff-tree", "--no-commit-id", "--name-only", "--no-renames", "-r", "-z", commitSHA],
          at: repositoryURL
        )
      )
      guard Set(changed) == expectedPaths else {
        throw GitWorkspaceError.invalidRepository(
          "The repository knowledge commit changed unexpected files."
        )
      }
      let committedTree = try repositoryTreeEntries(at: repositoryURL, sha: commitSHA).entries
      let entriesByPath = Dictionary(uniqueKeysWithValues: committedTree.map { ($0.path, $0) })
      for (path, expectedData) in expectedFiles {
        guard
          let entry = entriesByPath[path],
          try repositoryBlobData(at: repositoryURL, objectSHA: entry.objectSHA) == expectedData
        else {
          throw GitWorkspaceError.invalidRepository(
            "The repository knowledge commit contains unexpected content."
          )
        }
      }
      _ = try run(
        ["update-ref", "refs/heads/trunk", commitSHA, analyzedSHA],
        at: repositoryURL
      )
      guard try run(["rev-parse", "trunk"], at: repositoryURL) == commitSHA,
        try repositoryDirtyPaths(at: repositoryURL).isEmpty
      else {
        throw GitWorkspaceError.invalidRepository(
          "The repository knowledge commit could not be activated safely."
        )
      }
      return commitSHA
    } catch {
      if (try? run(["rev-parse", "trunk"], at: repositoryURL)) == analyzedSHA {
        _ = try? run(["reset", "--mixed", analyzedSHA, "--"], at: repositoryURL)
      }
      throw error
    }
  }

  public func recoverRepositoryKnowledgeCheckpoint(
    at repositoryURL: URL,
    analyzedSHA: String,
    expectedFiles: [String: Data],
    message: String = "Publish imported product knowledge"
  ) throws -> String? {
    guard try run(["branch", "--show-current"], at: repositoryURL) == "trunk",
      try repositoryDirtyPaths(at: repositoryURL).isEmpty
    else {
      throw GitWorkspaceError.invalidRepository(
        "The accepted product workspace changed while knowledge was publishing."
      )
    }
    let currentSHA = try run(["rev-parse", "trunk"], at: repositoryURL)
    guard currentSHA != analyzedSHA else { return nil }
    let metadata = try run(
      ["show", "-s", "--format=%P%x00%an%x00%ae%x00%s", currentSHA],
      at: repositoryURL
    ).split(separator: "\0", omittingEmptySubsequences: false)
    guard metadata.count == 4,
      metadata[0] == analyzedSHA,
      metadata[1] == "Spedito",
      metadata[2] == "spedito@localhost",
      metadata[3] == message
    else {
      throw GitWorkspaceError.invalidRepository(
        "Accepted trunk changed after repository analysis."
      )
    }
    let changed = try nulPaths(
      runDataAllowingFailure(
        ["diff-tree", "--no-commit-id", "--name-only", "--no-renames", "-r", "-z", currentSHA],
        at: repositoryURL
      )
    )
    guard Set(changed) == Set(expectedFiles.keys) else {
      throw GitWorkspaceError.invalidRepository(
        "The recovered repository knowledge commit changed unexpected files."
      )
    }
    let committedTree = try repositoryTreeEntries(at: repositoryURL, sha: currentSHA).entries
    let entriesByPath = Dictionary(uniqueKeysWithValues: committedTree.map { ($0.path, $0) })
    for (path, expectedData) in expectedFiles {
      guard
        let entry = entriesByPath[path],
        try repositoryBlobData(at: repositoryURL, objectSHA: entry.objectSHA) == expectedData
      else {
        throw GitWorkspaceError.invalidRepository(
          "The recovered repository knowledge commit contains unexpected content."
        )
      }
    }
    return currentSHA
  }

  private func nulPaths(
    _ result: (status: Int32, output: Data)
  ) throws -> [String] {
    guard result.status == 0 else {
      throw GitWorkspaceError.invalidRepository("Repository paths could not be read.")
    }
    return try result.output.split(separator: 0, omittingEmptySubsequences: true).map {
      guard
        let path = String(bytes: $0, encoding: .utf8),
        let validated = validatedRepositoryPath(path)
      else {
        throw GitWorkspaceError.invalidRepository("A repository path is undecodable.")
      }
      return validated
    }
  }

  @discardableResult
  public func ensureRepository(at repositoryURL: URL) throws -> String {
    try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
    let gitDirectory = repositoryURL.appendingPathComponent(".git", isDirectory: true)
    if !fileManager.fileExists(atPath: gitDirectory.path) {
      _ = try run(["init", "-b", "trunk"], at: repositoryURL)
      try configureIdentity(at: repositoryURL)
      try ensureControlDirectoryExcluded(at: repositoryURL)
      _ = try run(["add", "-A"], at: repositoryURL)
      _ = try run(
        ["commit", "--no-gpg-sign", "--allow-empty", "-m", "Initialize product workspace"],
        at: repositoryURL
      )
    } else {
      try configureIdentity(at: repositoryURL)
      guard (try? run(["rev-parse", "--is-inside-work-tree"], at: repositoryURL)) == "true" else {
        throw GitWorkspaceError.invalidRepository(repositoryURL.path)
      }
      try ensureControlDirectoryExcluded(at: repositoryURL)
      if (try? run(["rev-parse", "--verify", "refs/heads/trunk"], at: repositoryURL)) == nil {
        _ = try run(["branch", "trunk", "HEAD"], at: repositoryURL)
      }
    }
    return try run(["rev-parse", "refs/heads/trunk"], at: repositoryURL)
  }

  @discardableResult
  public func checkpointTrunk(
    at repositoryURL: URL,
    message: String = "Checkpoint product workspace"
  ) throws -> String {
    _ = try ensureRepository(at: repositoryURL)
    let branch = try run(["branch", "--show-current"], at: repositoryURL)
    guard branch == "trunk" else {
      throw GitWorkspaceError.invalidRepository(
        "The accepted product workspace must remain on trunk, but is on \(branch)."
      )
    }
    _ = try run(["add", "-A"], at: repositoryURL)
    let staged = try runAllowingFailure(
      ["diff", "--cached", "--quiet"],
      at: repositoryURL
    )
    if staged.status != 0 {
      _ = try run(["commit", "--no-gpg-sign", "-m", message], at: repositoryURL)
    }
    return try run(["rev-parse", "trunk"], at: repositoryURL)
  }

  public func prepareTicketWorkspace(
    repositoryURL: URL,
    worktreesRootURL: URL,
    ticketKey: String,
    runID: UUID,
    authorName: String
  ) throws -> GitTicketWorkspace {
    let baseSHA = try checkpointTrunk(
      at: repositoryURL,
      message: "Checkpoint before \(ticketKey)"
    )
    try fileManager.createDirectory(at: worktreesRootURL, withIntermediateDirectories: true)
    let normalizedKey = Self.pathComponent(ticketKey)
    let runSuffix = runID.uuidString.lowercased().prefix(8)
    let workspaceURL =
      worktreesRootURL
      .appendingPathComponent("\(normalizedKey)-\(runSuffix)", isDirectory: true)
    var branchName = "ticket/\(ticketKey.uppercased())"
    if (try? run(["rev-parse", "--verify", "refs/heads/\(branchName)"], at: repositoryURL)) != nil {
      branchName += "-\(runSuffix)"
    }
    if fileManager.fileExists(atPath: workspaceURL.path) {
      throw GitWorkspaceError.invalidRepository(
        "The ticket workspace already exists at \(workspaceURL.path)."
      )
    }
    _ = try run(
      ["worktree", "add", "-b", branchName, workspaceURL.path, baseSHA],
      at: repositoryURL
    )
    try configureWorktreeIdentity(at: workspaceURL, authorName: authorName)
    return GitTicketWorkspace(url: workspaceURL, branchName: branchName, baseSHA: baseSHA)
  }

  public func createCandidate(
    ticketWorkspaceURL: URL,
    ticketKey: String,
    version: Int,
    authorName: String,
    summary: String? = nil,
    settlementOperationID: UUID? = nil
  ) throws -> GitCandidateSnapshot {
    let branchName = try run(["branch", "--show-current"], at: ticketWorkspaceURL)
    guard branchName.hasPrefix("ticket/") else {
      throw GitWorkspaceError.invalidRepository(
        "\(ticketWorkspaceURL.path) is not on a ticket branch."
      )
    }
    let baseSHA: String
    if let settlementOperationID {
      let settlementRef =
        "refs/spedito/delivery-settlements/\(settlementOperationID.uuidString.lowercased())"
      if let persistedBase = try? run(["rev-parse", "--verify", settlementRef], at: ticketWorkspaceURL)
      {
        baseSHA = persistedBase
      } else {
        let currentHead = try run(["rev-parse", "HEAD"], at: ticketWorkspaceURL)
        baseSHA = try run(["merge-base", "trunk", currentHead], at: ticketWorkspaceURL)
        _ = try run(["update-ref", settlementRef, baseSHA], at: ticketWorkspaceURL)
      }
    } else {
      let currentHead = try run(["rev-parse", "HEAD"], at: ticketWorkspaceURL)
      baseSHA = try run(["merge-base", "trunk", currentHead], at: ticketWorkspaceURL)
    }
    _ = try run(["add", "-A"], at: ticketWorkspaceURL)
    let trimmedSummary = summary?
      .components(separatedBy: .newlines)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let message =
      if let trimmedSummary, !trimmedSummary.isEmpty {
        "\(ticketKey.uppercased()): \(String(trimmedSummary.prefix(160)))"
      } else {
        "\(ticketKey.uppercased()): candidate v\(version)"
      }
    let stagedChanges = try run(["diff", "--cached", "--name-only"], at: ticketWorkspaceURL)
    if !stagedChanges.isEmpty {
      _ = try run(
        ["commit", "--no-gpg-sign", "-m", message],
        at: ticketWorkspaceURL,
        authorName: authorName
      )
    }
    let headSHA = try run(["rev-parse", "HEAD"], at: ticketWorkspaceURL)
    let commitCountText = try run(
      ["rev-list", "--count", "\(baseSHA)..\(headSHA)"],
      at: ticketWorkspaceURL
    )
    let changedFilesText = try run(
      ["diff", "--name-only", "\(baseSHA)..\(headSHA)"],
      at: ticketWorkspaceURL
    )
    return GitCandidateSnapshot(
      branchName: branchName,
      baseSHA: baseSHA,
      headSHA: headSHA,
      commitCount: Int(commitCountText) ?? 0,
      changedFiles: changedFilesText.split(separator: "\n").map(String.init)
    )
  }

  public func snapshotLocalOutcomeCandidate(
    ticketWorkspaceURL: URL
  ) throws -> GitCandidateSnapshot {
    let branchName = try run(["branch", "--show-current"], at: ticketWorkspaceURL)
    guard branchName.hasPrefix("ticket/") else {
      throw GitWorkspaceError.invalidRepository(
        "\(ticketWorkspaceURL.path) is not on a ticket branch."
      )
    }
    guard try ticketChangePaths(ticketWorkspaceURL: ticketWorkspaceURL).isEmpty else {
      throw GitWorkspaceError.invalidRepository(
        "A local outcome candidate cannot leave repository changes uncommitted."
      )
    }
    let headSHA = try run(["rev-parse", "HEAD"], at: ticketWorkspaceURL)
    let baseSHA = try run(["merge-base", "trunk", headSHA], at: ticketWorkspaceURL)
    let commitCountText = try run(
      ["rev-list", "--count", "\(baseSHA)..\(headSHA)"],
      at: ticketWorkspaceURL
    )
    let commitCount = Int(commitCountText) ?? 0
    guard headSHA == baseSHA, commitCount == 0 else {
      throw GitWorkspaceError.invalidRepository(
        "A repository-free local outcome cannot include ticket commits."
      )
    }
    return GitCandidateSnapshot(
      branchName: branchName,
      baseSHA: baseSHA,
      headSHA: headSHA,
      commitCount: commitCount,
      changedFiles: []
    )
  }

  public func ticketChangePaths(ticketWorkspaceURL: URL) throws -> [String] {
    let headSHA = try run(["rev-parse", "HEAD"], at: ticketWorkspaceURL)
    let baseSHA = try run(["merge-base", "trunk", headSHA], at: ticketWorkspaceURL)
    let committed = try run(
      ["diff", "--name-only", "\(baseSHA)..\(headSHA)"],
      at: ticketWorkspaceURL
    )
    let unstaged = try run(
      ["diff", "--name-only", "HEAD"],
      at: ticketWorkspaceURL
    )
    let staged = try run(
      ["diff", "--name-only", "--cached"],
      at: ticketWorkspaceURL
    )
    let untracked = try run(
      ["ls-files", "--others", "--exclude-standard"],
      at: ticketWorkspaceURL
    )
    return Array(
      Set(
        [committed, unstaged, staged, untracked]
          .flatMap { $0.split(separator: "\n").map(String.init) }
          .filter { !$0.isEmpty }
      )
    ).sorted()
  }

  public func configureAgentIdentity(
    at workspaceURL: URL,
    authorName: String
  ) throws {
    try configureWorktreeIdentity(at: workspaceURL, authorName: authorName)
  }

  public func integrateCandidate(
    repositoryURL: URL,
    integrationsRootURL: URL,
    candidateID: UUID,
    headSHA: String,
    commitMessage: String? = nil,
    reusableIntegratedSHA: String? = nil
  ) throws -> GitIntegrationSnapshot {
    _ = try checkpointTrunk(
      at: repositoryURL,
      message: "Checkpoint before candidate integration"
    )
    try fileManager.createDirectory(at: integrationsRootURL, withIntermediateDirectories: true)
    let integrationURL = integrationsRootURL.appendingPathComponent(
      candidateID.uuidString.lowercased(),
      isDirectory: true
    )
    if fileManager.fileExists(atPath: integrationURL.path) {
      try removeWorktree(repositoryURL: repositoryURL, worktreeURL: integrationURL)
    }
    if reusableIntegratedSHA == headSHA,
      try revision(
        headSHA,
        contains: try run(["rev-parse", "refs/heads/trunk"], at: repositoryURL),
        at: repositoryURL
      )
    {
      _ = try run(
        ["worktree", "add", "--detach", integrationURL.path, headSHA],
        at: repositoryURL
      )
      return GitIntegrationSnapshot(url: integrationURL, integratedSHA: headSHA)
    }
    _ = try run(
      ["worktree", "add", "--detach", integrationURL.path, "trunk"],
      at: repositoryURL
    )
    do {
      var mergeArguments = ["merge", "--no-gpg-sign", "--no-ff"]
      if let commitMessage, !commitMessage.isEmpty {
        mergeArguments += ["-m", commitMessage]
      } else {
        mergeArguments.append("--no-edit")
      }
      mergeArguments.append(headSHA)
      _ = try run(
        mergeArguments,
        at: integrationURL
      )
    } catch {
      let conflictedFiles =
        (try? run(["diff", "--name-only", "--diff-filter=U"], at: integrationURL))?
        .split(separator: "\n")
        .map(String.init) ?? []
      if !conflictedFiles.isEmpty {
        throw GitWorkspaceError.mergeConflict(
          worktreePath: integrationURL.path,
          conflictedFiles: conflictedFiles,
          output: error.localizedDescription
        )
      }
      _ = try? run(["merge", "--abort"], at: integrationURL)
      try? removeWorktree(repositoryURL: repositoryURL, worktreeURL: integrationURL)
      throw error
    }
    return GitIntegrationSnapshot(
      url: integrationURL,
      integratedSHA: try run(["rev-parse", "HEAD"], at: integrationURL)
    )
  }

  public func integrateVerifiedRemote(
    repositoryURL: URL,
    integrationWorkspaceURL: URL,
    observationRef: String,
    expectedRemoteSHA: String,
    candidateHeadSHA: String,
    commitMessage: String = "Integrate verified GitHub changes"
  ) throws -> GitIntegrationSnapshot {
    guard observationRef.hasPrefix("refs/spedito/observations/"),
      try run(["rev-parse", "\(observationRef)^{commit}"], at: repositoryURL)
        == expectedRemoteSHA
    else {
      throw GitWorkspaceError.invalidRepository(
        "The verified GitHub revision is no longer available for ticket integration."
      )
    }
    defer {
      try? deleteRemoteObservationRef(repositoryURL: repositoryURL, ref: observationRef)
    }
    let currentSHA = try run(["rev-parse", "HEAD"], at: integrationWorkspaceURL)
    guard
      try revision(
        currentSHA,
        contains: candidateHeadSHA,
        at: integrationWorkspaceURL
      )
    else {
      throw GitWorkspaceError.invalidRepository(
        "The ticket integration no longer contains its reviewed candidate."
      )
    }
    guard try run(["status", "--porcelain"], at: integrationWorkspaceURL).isEmpty else {
      throw GitWorkspaceError.invalidRepository(
        "The ticket integration contains uncaptured changes."
      )
    }
    if try revision(
      currentSHA,
      contains: expectedRemoteSHA,
      at: integrationWorkspaceURL
    ) {
      return GitIntegrationSnapshot(
        url: integrationWorkspaceURL,
        integratedSHA: currentSHA
      )
    }

    do {
      _ = try run(
        [
          "merge", "--no-gpg-sign", "--no-ff", "-m", commitMessage,
          expectedRemoteSHA,
        ],
        at: integrationWorkspaceURL
      )
    } catch {
      let conflictedFiles =
        (try? run(
          ["diff", "--name-only", "--diff-filter=U"],
          at: integrationWorkspaceURL
        ))?
        .split(separator: "\n")
        .map(String.init) ?? []
      if !conflictedFiles.isEmpty {
        throw GitWorkspaceError.mergeConflict(
          worktreePath: integrationWorkspaceURL.path,
          conflictedFiles: conflictedFiles,
          output: error.localizedDescription
        )
      }
      _ = try? run(["merge", "--abort"], at: integrationWorkspaceURL)
      throw error
    }

    let integratedSHA = try run(["rev-parse", "HEAD"], at: integrationWorkspaceURL)
    guard
      try revision(
        integratedSHA,
        contains: candidateHeadSHA,
        at: integrationWorkspaceURL
      ),
      try revision(
        integratedSHA,
        contains: expectedRemoteSHA,
        at: integrationWorkspaceURL
      )
    else {
      throw GitWorkspaceError.invalidRepository(
        "The ticket integration did not preserve both the ticket and verified GitHub changes."
      )
    }
    return GitIntegrationSnapshot(
      url: integrationWorkspaceURL,
      integratedSHA: integratedSHA
    )
  }

  public func prepareIntegratedWorkspace(
    repositoryURL: URL,
    integrationsRootURL: URL,
    candidateID: UUID,
    candidateHeadSHA: String,
    integratedSHA: String
  ) throws -> GitIntegrationSnapshot {
    try fileManager.createDirectory(at: integrationsRootURL, withIntermediateDirectories: true)
    let integrationURL = integrationsRootURL.appendingPathComponent(
      candidateID.uuidString.lowercased(),
      isDirectory: true
    )

    if fileManager.fileExists(atPath: integrationURL.path) {
      do {
        try validateIntegratedWorkspace(
          integrationURL,
          candidateHeadSHA: candidateHeadSHA,
          integratedSHA: integratedSHA
        )
        return GitIntegrationSnapshot(url: integrationURL, integratedSHA: integratedSHA)
      } catch {
        try removeWorktree(repositoryURL: repositoryURL, worktreeURL: integrationURL)
      }
    } else {
      _ = try? run(["worktree", "prune"], at: repositoryURL)
    }

    _ = try run(
      ["worktree", "add", "--detach", integrationURL.path, integratedSHA],
      at: repositoryURL
    )
    do {
      try validateIntegratedWorkspace(
        integrationURL,
        candidateHeadSHA: candidateHeadSHA,
        integratedSHA: integratedSHA
      )
    } catch {
      try? removeWorktree(repositoryURL: repositoryURL, worktreeURL: integrationURL)
      throw error
    }
    return GitIntegrationSnapshot(url: integrationURL, integratedSHA: integratedSHA)
  }

  public func prepareCandidateReviewWorkspace(
    repositoryURL: URL,
    reviewsRootURL: URL,
    candidateID: UUID,
    candidateHeadSHA: String
  ) throws -> GitIntegrationSnapshot {
    try fileManager.createDirectory(at: reviewsRootURL, withIntermediateDirectories: true)
    let reviewURL = reviewsRootURL.appendingPathComponent(
      candidateID.uuidString.lowercased(),
      isDirectory: true
    )
    if fileManager.fileExists(atPath: reviewURL.path) {
      do {
        try validateIntegratedWorkspace(
          reviewURL,
          candidateHeadSHA: candidateHeadSHA,
          integratedSHA: candidateHeadSHA
        )
        return GitIntegrationSnapshot(
          url: reviewURL,
          integratedSHA: candidateHeadSHA
        )
      } catch {
        try removeWorktree(repositoryURL: repositoryURL, worktreeURL: reviewURL)
      }
    } else {
      _ = try? run(["worktree", "prune"], at: repositoryURL)
    }

    _ = try run(
      ["worktree", "add", "--detach", reviewURL.path, candidateHeadSHA],
      at: repositoryURL
    )
    try validateIntegratedWorkspace(
      reviewURL,
      candidateHeadSHA: candidateHeadSHA,
      integratedSHA: candidateHeadSHA
    )
    return GitIntegrationSnapshot(
      url: reviewURL,
      integratedSHA: candidateHeadSHA
    )
  }

  /// `resetsExistingCheckout` restores a reused preview worktree to a clean
  /// detached checkout before it is handed to demo preparation, so artifacts a
  /// previous preparation could not delete never poison the next attempt. Pass
  /// `false` only while a live demo may still be serving from the worktree.
  public func preparePreviewWorkspace(
    repositoryURL: URL,
    previewsRootURL: URL,
    candidateID: UUID,
    integratedSHA: String,
    resetsExistingCheckout: Bool = true
  ) throws -> URL {
    try fileManager.createDirectory(at: previewsRootURL, withIntermediateDirectories: true)
    let previewURL = previewsRootURL.appendingPathComponent(
      candidateID.uuidString.lowercased(),
      isDirectory: true
    )
    if fileManager.fileExists(atPath: previewURL.path) {
      let currentRevision = try? run(["rev-parse", "HEAD"], at: previewURL)
      if currentRevision == integratedSHA {
        if resetsExistingCheckout {
          _ = try run(["reset", "--hard", integratedSHA], at: previewURL)
          _ = try run(["clean", "-ffdx"], at: previewURL)
        }
        return previewURL
      }
      try removeWorktree(repositoryURL: repositoryURL, worktreeURL: previewURL)
    }
    _ = try run(
      ["worktree", "add", "--detach", previewURL.path, integratedSHA],
      at: repositoryURL
    )
    return previewURL
  }

  public func completeConflictResolution(
    integrationWorkspaceURL: URL,
    candidateHeadSHA: String? = nil
  ) throws -> GitIntegrationSnapshot {
    _ = try run(["add", "-A"], at: integrationWorkspaceURL)
    let stagedCheck = try runAllowingFailure(
      ["diff", "--cached", "--check"],
      at: integrationWorkspaceURL
    )
    guard !stagedCheck.output.contains("leftover conflict marker") else {
      throw GitWorkspaceError.invalidRepository(
        "The resolved integration still contains conflict markers."
      )
    }
    let unmerged = try run(
      ["diff", "--name-only", "--diff-filter=U"],
      at: integrationWorkspaceURL
    )
    guard unmerged.isEmpty else {
      throw GitWorkspaceError.invalidRepository(
        "These paths still contain merge conflicts: \(unmerged.replacingOccurrences(of: "\n", with: ", "))."
      )
    }
    let mergeHead = try runAllowingFailure(
      ["rev-parse", "--quiet", "--verify", "MERGE_HEAD"],
      at: integrationWorkspaceURL
    )
    if mergeHead.status == 0 {
      _ = try run(["commit", "--no-gpg-sign", "--no-edit"], at: integrationWorkspaceURL)
    }
    let integratedSHA = try run(["rev-parse", "HEAD"], at: integrationWorkspaceURL)
    if let candidateHeadSHA {
      let candidateIncluded = try runAllowingFailure(
        ["merge-base", "--is-ancestor", candidateHeadSHA, integratedSHA],
        at: integrationWorkspaceURL
      )
      guard candidateIncluded.status == 0 else {
        throw GitWorkspaceError.invalidRepository(
          "The resolved integration no longer contains the ticket candidate."
        )
      }
    }
    let parents = try run(
      ["rev-list", "--parents", "-n", "1", integratedSHA],
      at: integrationWorkspaceURL
    ).split(separator: " ")
    guard parents.count >= 3 else {
      throw GitWorkspaceError.invalidRepository(
        "The resolved integration is not a merge of trunk and the ticket candidate."
      )
    }
    return GitIntegrationSnapshot(
      url: integrationWorkspaceURL,
      integratedSHA: integratedSHA
    )
  }

  public func conflictResolutionIsReadyToCommit(
    integrationWorkspaceURL: URL
  ) throws -> Bool {
    let mergeHead = try runAllowingFailure(
      ["rev-parse", "--quiet", "--verify", "MERGE_HEAD"],
      at: integrationWorkspaceURL
    )
    guard mergeHead.status == 0 else { return false }
    let unmerged = try run(
      ["diff", "--name-only", "--diff-filter=U"],
      at: integrationWorkspaceURL
    )
    guard unmerged.isEmpty else { return false }
    let stagedCheck = try runAllowingFailure(
      ["diff", "--cached", "--check"],
      at: integrationWorkspaceURL
    )
    return !stagedCheck.output.contains("leftover conflict marker")
  }

  public func revision(
    _ descendantSHA: String,
    contains ancestorSHA: String,
    at repositoryURL: URL
  ) throws -> Bool {
    let ancestry = try runAllowingFailure(
      ["merge-base", "--is-ancestor", ancestorSHA, descendantSHA],
      at: repositoryURL
    )
    switch ancestry.status {
    case 0:
      return true
    case 1:
      return false
    default:
      throw GitWorkspaceError.commandFailed(
        arguments: ["merge-base", "--is-ancestor", ancestorSHA, descendantSHA],
        output: ancestry.output
      )
    }
  }

  public func integratedRevisionContainsCurrentTrunk(
    repositoryURL: URL,
    integratedSHA: String
  ) throws -> Bool {
    let currentTrunk = try run(["rev-parse", "refs/heads/trunk"], at: repositoryURL)
    let ancestry = try runAllowingFailure(
      ["merge-base", "--is-ancestor", currentTrunk, integratedSHA],
      at: repositoryURL
    )
    switch ancestry.status {
    case 0:
      return true
    case 1:
      return false
    default:
      throw GitWorkspaceError.commandFailed(
        arguments: ["merge-base", "--is-ancestor", currentTrunk, integratedSHA],
        output: ancestry.output
      )
    }
  }

  @discardableResult
  public func adoptIntegratedRevision(
    ticketWorkspaceURL: URL,
    candidateHeadSHA: String,
    integratedSHA: String
  ) throws -> String {
    let branchName = try run(["branch", "--show-current"], at: ticketWorkspaceURL)
    guard branchName.hasPrefix("ticket/") else {
      throw GitWorkspaceError.invalidRepository(
        "Only a ticket branch can adopt a reviewed integration revision."
      )
    }
    let status = try run(["status", "--porcelain"], at: ticketWorkspaceURL)
    guard status.isEmpty else {
      throw GitWorkspaceError.invalidRepository(
        "The ticket workspace contains uncaptured changes and cannot adopt the reviewed integration."
      )
    }
    let candidateIncluded = try runAllowingFailure(
      ["merge-base", "--is-ancestor", candidateHeadSHA, integratedSHA],
      at: ticketWorkspaceURL
    )
    switch candidateIncluded.status {
    case 0:
      break
    case 1:
      throw GitWorkspaceError.invalidRepository(
        "The reviewed integration no longer contains the immutable ticket candidate."
      )
    default:
      throw GitWorkspaceError.commandFailed(
        arguments: ["merge-base", "--is-ancestor", candidateHeadSHA, integratedSHA],
        output: candidateIncluded.output
      )
    }

    let currentSHA = try run(["rev-parse", "HEAD"], at: ticketWorkspaceURL)
    if currentSHA == integratedSHA {
      return currentSHA
    }
    guard currentSHA == candidateHeadSHA else {
      throw GitWorkspaceError.invalidRepository(
        "The ticket workspace moved away from both the immutable candidate and its reviewed integration."
      )
    }

    _ = try run(["merge", "--ff-only", integratedSHA], at: ticketWorkspaceURL)
    let adoptedSHA = try run(["rev-parse", "HEAD"], at: ticketWorkspaceURL)
    guard adoptedSHA == integratedSHA else {
      throw GitWorkspaceError.invalidRepository(
        "The ticket workspace did not advance to the reviewed integration."
      )
    }
    let adoptedStatus = try run(["status", "--porcelain"], at: ticketWorkspaceURL)
    guard adoptedStatus.isEmpty else {
      throw GitWorkspaceError.invalidRepository(
        "Advancing the ticket workspace left uncaptured changes."
      )
    }
    return adoptedSHA
  }

  public func promote(
    repositoryURL: URL,
    integratedSHA: String
  ) throws {
    guard try run(["branch", "--show-current"], at: repositoryURL) == "trunk",
      try run(["status", "--porcelain"], at: repositoryURL).isEmpty
    else {
      throw GitWorkspaceError.invalidRepository(
        "The accepted product workspace must be clean and remain on trunk before approval."
      )
    }
    let currentTrunk = try run(["rev-parse", "refs/heads/trunk"], at: repositoryURL)
    guard try run(["rev-parse", "HEAD"], at: repositoryURL) == currentTrunk else {
      throw GitWorkspaceError.invalidRepository(
        "The accepted product workspace is not checked out at the current trunk revision."
      )
    }
    let ancestry = try runAllowingFailure(
      ["merge-base", "--is-ancestor", currentTrunk, integratedSHA],
      at: repositoryURL
    )
    guard ancestry.status == 0 else {
      throw GitWorkspaceError.invalidRepository(
        "The approved candidate is no longer based on the accepted trunk."
      )
    }
    _ = try run(
      ["update-ref", "refs/heads/trunk", integratedSHA, currentTrunk],
      at: repositoryURL
    )
    _ = try run(["reset", "--hard", "trunk"], at: repositoryURL)
  }

  @discardableResult
  public func checkpointWorkspace(
    at workspaceURL: URL,
    message: String
  ) throws -> String {
    _ = try run(["add", "-A"], at: workspaceURL)
    let staged = try runAllowingFailure(
      ["diff", "--cached", "--quiet"],
      at: workspaceURL
    )
    if staged.status != 0 {
      _ = try run(["commit", "--no-gpg-sign", "-m", message], at: workspaceURL)
    }
    return try run(["rev-parse", "HEAD"], at: workspaceURL)
  }

  public func removeWorktree(
    repositoryURL: URL,
    worktreeURL: URL
  ) throws {
    guard fileManager.fileExists(atPath: worktreeURL.path) else {
      _ = try? run(["worktree", "prune"], at: repositoryURL)
      return
    }
    _ = try run(["worktree", "remove", "--force", worktreeURL.path], at: repositoryURL)
    _ = try run(["worktree", "prune"], at: repositoryURL)
  }

  public func removeTicketWorkspace(
    repositoryURL: URL,
    worktreeURL: URL,
    branchName: String
  ) throws {
    try removeWorktree(repositoryURL: repositoryURL, worktreeURL: worktreeURL)
    _ = try? run(["branch", "-D", branchName], at: repositoryURL)
  }

  public func currentSHA(at workspaceURL: URL) throws -> String {
    try run(["rev-parse", "HEAD"], at: workspaceURL)
  }

  public func unmergedFiles(at workspaceURL: URL) throws -> [String] {
    try run(["diff", "--name-only", "--diff-filter=U"], at: workspaceURL)
      .split(separator: "\n")
      .map(String.init)
  }

  public func repositorySnapshot(
    at repositoryURL: URL,
    commitLimit: Int = 200
  ) throws -> GitRepositorySnapshot {
    let trunkSHA = try ensureRepository(at: repositoryURL)
    let worktrees = try parseWorktrees(
      try run(["worktree", "list", "--porcelain"], at: repositoryURL)
    )
    let acceptedSHAs = Set(
      try run(["rev-list", "--max-count=500", "trunk"], at: repositoryURL)
        .split(separator: "\n")
        .map(String.init)
    )
    let branchLines = try run(
      [
        "for-each-ref",
        "--sort=-committerdate",
        "--format=%(refname:short)%1f%(objectname)%1f%(committerdate:unix)%1f%(subject)%1e",
        "refs/heads",
      ],
      at: repositoryURL
    )
    let branches = try records(in: branchLines).compactMap { record -> GitBranchSnapshot? in
      let fields = record.components(separatedBy: Self.fieldSeparator)
      guard fields.count >= 4 else { return nil }
      let name = fields[0]
      guard name != "trunk" else { return nil }
      let worktreePath = worktrees[name]
      let dirtyFileCount: Int
      if let worktreePath {
        dirtyFileCount = try run(
          ["status", "--porcelain"],
          at: URL(fileURLWithPath: worktreePath, isDirectory: true)
        )
        .split(separator: "\n")
        .count
      } else {
        dirtyFileCount = 0
      }
      return GitBranchSnapshot(
        name: name,
        headSHA: fields[1],
        worktreePath: worktreePath,
        dirtyFileCount: dirtyFileCount,
        aheadOfTrunk: Int(
          try run(["rev-list", "--count", "trunk..\(name)"], at: repositoryURL)
        ) ?? 0,
        behindTrunk: Int(
          try run(["rev-list", "--count", "\(name)..trunk"], at: repositoryURL)
        ) ?? 0,
        commitSHAs: try run(["rev-list", "trunk..\(name)"], at: repositoryURL)
          .split(separator: "\n")
          .map(String.init),
        lastCommitAt: Date(timeIntervalSince1970: Double(fields[2]) ?? 0),
        lastCommitSubject: fields[3]
      )
    }
    let log = try run(
      [
        "log", "--all", "--max-count=\(max(1, commitLimit))",
        "--date-order",
        "--pretty=format:%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1e",
      ],
      at: repositoryURL
    )
    let commits = records(in: log).compactMap { record -> GitCommitSummary? in
      let fields = record.components(separatedBy: Self.fieldSeparator)
      guard fields.count >= 7 else { return nil }
      let sha = fields[0]
      return GitCommitSummary(
        sha: sha,
        parentSHAs: fields[1].split(separator: " ").map(String.init),
        authorName: fields[2],
        authorEmail: fields[3],
        committedAt: Date(timeIntervalSince1970: Double(fields[4]) ?? 0),
        references: fields[5]
          .split(separator: ",")
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty },
        subject: fields[6],
        isOnTrunk: acceptedSHAs.contains(sha)
      )
    }
    return GitRepositorySnapshot(
      trunkSHA: trunkSHA,
      branches: branches,
      commits: commits
    )
  }

  public func commitDetail(
    at repositoryURL: URL,
    sha: String,
    maximumDiffCharacters: Int = 250_000
  ) throws -> GitCommitDetail {
    let metadata = try run(
      [
        "show", "-s",
        "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s",
        sha,
      ],
      at: repositoryURL
    ).components(separatedBy: Self.fieldSeparator)
    guard metadata.count >= 7 else {
      throw GitWorkspaceError.invalidRepository("Commit \(sha) could not be read.")
    }
    let accepted =
      try runAllowingFailure(
        ["merge-base", "--is-ancestor", sha, "trunk"],
        at: repositoryURL
      ).status == 0
    let commit = GitCommitSummary(
      sha: metadata[0],
      parentSHAs: metadata[1].split(separator: " ").map(String.init),
      authorName: metadata[2],
      authorEmail: metadata[3],
      committedAt: Date(timeIntervalSince1970: Double(metadata[4]) ?? 0),
      references: metadata[5]
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty },
      subject: metadata[6],
      isOnTrunk: accepted
    )
    let fileArguments: [String]
    let diffArguments: [String]
    if let firstParentSHA = commit.parentSHAs.first {
      // A merge commit represents the ticket as integrated into the accepted trunk. Comparing it
      // with its first parent shows exactly what the integration added, and keeps the file list and
      // displayed diff on the same two-way comparison.
      fileArguments = [
        "diff", "--name-status", "-M", firstParentSHA, sha, "--",
      ]
      diffArguments = [
        "diff", "--no-ext-diff", "--no-color", "--find-renames",
        "--unified=3", firstParentSHA, sha, "--",
      ]
    } else {
      fileArguments = [
        "diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-M", sha,
      ]
      diffArguments = [
        "show", "--format=", "--no-ext-diff", "--no-color", "--find-renames",
        "--unified=3", sha, "--",
      ]
    }
    let files = try run(
      fileArguments,
      at: repositoryURL
    )
    .split(separator: "\n")
    .compactMap { line -> GitChangedFile? in
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count >= 2 else { return nil }
      let status = String(fields[0])
      let path =
        fields.count >= 3
        ? "\(fields[1]) → \(fields[2])"
        : String(fields[1])
      return GitChangedFile(status: status, path: path)
    }
    let boundedDiff = try runBounded(
      diffArguments,
      at: repositoryURL,
      maximumCharacters: maximumDiffCharacters
    )
    return GitCommitDetail(
      commit: commit,
      files: files,
      unifiedDiff: boundedDiff.output,
      isDiffTruncated: boundedDiff.isTruncated
    )
  }

  public func branchDetail(
    at repositoryURL: URL,
    branch: GitBranchSnapshot,
    maximumDiffCharacters: Int = 250_000
  ) throws -> GitBranchDetail {
    let baseSHA = try run(
      ["merge-base", "trunk", branch.name],
      at: repositoryURL
    )
    let workspaceURL =
      branch.worktreePath.map {
        URL(fileURLWithPath: $0, isDirectory: true)
      } ?? repositoryURL
    let target = branch.worktreePath == nil ? branch.name : nil
    var nameStatusArguments = ["diff", "--name-status", "-M", baseSHA]
    var diffArguments = [
      "diff", "--no-ext-diff", "--no-color", "--find-renames",
      "--unified=3", baseSHA,
    ]
    if let target {
      nameStatusArguments.append(target)
      diffArguments.append(target)
    }
    nameStatusArguments.append("--")
    diffArguments.append("--")

    let files = try run(nameStatusArguments, at: workspaceURL)
      .split(separator: "\n")
      .compactMap { line -> GitChangedFile? in
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 2 else { return nil }
        let status = String(fields[0])
        let path =
          fields.count >= 3
          ? "\(fields[1]) → \(fields[2])"
          : String(fields[1])
        return GitChangedFile(status: status, path: path)
      }
    let boundedDiff = try runBounded(
      diffArguments,
      at: workspaceURL,
      maximumCharacters: maximumDiffCharacters
    )
    return GitBranchDetail(
      branch: branch,
      files: files,
      unifiedDiff: boundedDiff.output,
      isDiffTruncated: boundedDiff.isTruncated
    )
  }

  private func validateIntegratedWorkspace(
    _ workspaceURL: URL,
    candidateHeadSHA: String,
    integratedSHA: String
  ) throws {
    let currentSHA = try run(["rev-parse", "HEAD"], at: workspaceURL)
    guard currentSHA == integratedSHA else {
      throw GitWorkspaceError.invalidRepository(
        "The preserved integration workspace no longer matches its reviewed revision."
      )
    }
    let candidateIncluded = try runAllowingFailure(
      ["merge-base", "--is-ancestor", candidateHeadSHA, integratedSHA],
      at: workspaceURL
    )
    guard candidateIncluded.status == 0 else {
      throw GitWorkspaceError.invalidRepository(
        "The preserved integration revision no longer contains the ticket candidate."
      )
    }
    let status = try run(["status", "--porcelain"], at: workspaceURL)
    guard status.isEmpty else {
      throw GitWorkspaceError.invalidRepository(
        "The preserved integration workspace contains unreviewed changes."
      )
    }
  }

  private func configureIdentity(at repositoryURL: URL) throws {
    _ = try run(["config", "user.name", "Spedito"], at: repositoryURL)
    _ = try run(["config", "user.email", "spedito@localhost"], at: repositoryURL)
    _ = try run(["config", "extensions.worktreeConfig", "true"], at: repositoryURL)
  }

  private func configureWorktreeIdentity(
    at workspaceURL: URL,
    authorName: String
  ) throws {
    _ = try run(["config", "--worktree", "user.name", authorName], at: workspaceURL)
    _ = try run(
      ["config", "--worktree", "user.email", Self.agentEmail(authorName)],
      at: workspaceURL
    )
  }

  func withRepositoryOperation<T: Sendable>(
    at repositoryURL: URL,
    operation: @Sendable () async throws -> T
  ) async throws -> T {
    let key = repositoryOperationKey(repositoryURL)
    if let operationID = Self.repositoryOperationID,
      activeRepositoryOperationIDs[key] == operationID
    {
      return try await operation()
    }

    let operationID = UUID()
    await acquireRepositoryOperation(key: key, operationID: operationID)
    do {
      let value = try await Self.$repositoryOperationID.withValue(operationID) {
        try await operation()
      }
      releaseRepositoryOperation(key: key, operationID: operationID)
      return value
    } catch {
      releaseRepositoryOperation(key: key, operationID: operationID)
      throw error
    }
  }

  private func acquireRepositoryOperation(key: String, operationID: UUID) async {
    guard activeRepositoryOperationIDs[key] != nil else {
      activeRepositoryOperationIDs[key] = operationID
      return
    }
    await withCheckedContinuation { continuation in
      repositoryOperationWaiters[key, default: []].append(
        RepositoryOperationWaiter(id: operationID, continuation: continuation)
      )
    }
  }

  private func releaseRepositoryOperation(key: String, operationID: UUID) {
    guard activeRepositoryOperationIDs[key] == operationID else { return }
    if var waiters = repositoryOperationWaiters[key], !waiters.isEmpty {
      let next = waiters.removeFirst()
      repositoryOperationWaiters[key] = waiters.isEmpty ? nil : waiters
      activeRepositoryOperationIDs[key] = next.id
      next.continuation.resume()
    } else {
      activeRepositoryOperationIDs.removeValue(forKey: key)
    }
  }

  private func repositoryOperationKey(_ repositoryURL: URL) -> String {
    repositoryURL.standardizedFileURL.resolvingSymlinksInPath().path
  }

  private func validateRepositoryOperationAccess(at directoryURL: URL) throws {
    let path = repositoryOperationKey(directoryURL)
    let operationID = Self.repositoryOperationID
    let conflictingOperation = activeRepositoryOperationIDs.first { key, ownerID in
      ownerID != operationID && (path == key || path.hasPrefix(key + "/"))
    }
    guard conflictingOperation == nil else {
      throw GitWorkspaceError.operationInProgress
    }
  }

  func run(
    _ arguments: [String],
    at directoryURL: URL,
    authorName: String? = nil,
    environmentOverrides: [String: String] = [:]
  ) throws -> String {
    let result = try runAllowingFailure(
      arguments,
      at: directoryURL,
      authorName: authorName,
      environmentOverrides: environmentOverrides
    )
    guard result.status == 0 else {
      throw GitWorkspaceError.commandFailed(arguments: arguments, output: result.output)
    }
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func runAllowingFailure(
    _ arguments: [String],
    at directoryURL: URL,
    authorName: String? = nil,
    environmentOverrides: [String: String] = [:]
  ) throws -> (status: Int32, output: String) {
    let result = try runDataAllowingFailure(
      arguments,
      at: directoryURL,
      authorName: authorName,
      environmentOverrides: environmentOverrides
    )
    return (
      result.status,
      String(data: result.output, encoding: .utf8) ?? ""
    )
  }

  private func runBounded(
    _ arguments: [String],
    at directoryURL: URL,
    maximumCharacters: Int
  ) throws -> (output: String, isTruncated: Bool) {
    let maximumBytes = max(64 * 1_024, maximumCharacters * 4)
    let result = try runDataBoundedAllowingFailure(
      arguments,
      at: directoryURL,
      maximumOutputBytes: maximumBytes
    )
    let completeOutput = String(decoding: result.output, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let isTruncated = result.isTruncated || completeOutput.count > maximumCharacters
    guard result.status == 0 || isTruncated else {
      throw GitWorkspaceError.commandFailed(arguments: arguments, output: completeOutput)
    }
    return (
      isTruncated ? String(completeOutput.prefix(maximumCharacters)) : completeOutput,
      isTruncated
    )
  }

  private func runDataBoundedAllowingFailure(
    _ arguments: [String],
    at directoryURL: URL,
    maximumOutputBytes: Int
  ) throws -> (status: Int32, output: Data, isTruncated: Bool) {
    let process = Process()
    let outputPipe = Pipe()
    process.executableURL = executableURL
    process.arguments = safeArguments(arguments)
    process.currentDirectoryURL = directoryURL
    process.environment = try commandEnvironment(authorName: nil)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = outputPipe
    try validateRepositoryOperationAccess(at: directoryURL)
    process.standardError = outputPipe
    try process.run()

    var output = Data()
    var isTruncated = false
    while let chunk = try outputPipe.fileHandleForReading.read(upToCount: 64 * 1_024),
      !chunk.isEmpty
    {
      let remaining = maximumOutputBytes - output.count
      if remaining > 0 {
        output.append(chunk.prefix(remaining))
      }
      if chunk.count > remaining {
        isTruncated = true
        if process.isRunning {
          process.terminate()
        }
      }
    }
    process.waitUntilExit()
    return (process.terminationStatus, output, isTruncated)
  }

  func runDataAllowingFailure(
    _ arguments: [String],
    at directoryURL: URL,
    authorName: String? = nil,
    environmentOverrides: [String: String] = [:],
    standardInput: Data? = nil
  ) throws -> (status: Int32, output: Data) {
    let process = Process()
    let outputPipe = Pipe()
    process.executableURL = executableURL
    process.arguments = safeArguments(arguments)
    process.currentDirectoryURL = directoryURL
    process.environment = try commandEnvironment(
      authorName: authorName,
      overrides: environmentOverrides
    )
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    let inputPipe = standardInput.map { _ in Pipe() }
    if let inputPipe {
      process.standardInput = inputPipe
    } else {
      process.standardInput = FileHandle.nullDevice
    }
    try validateRepositoryOperationAccess(at: directoryURL)
    try process.run()
    if let standardInput, let inputPipe {
      inputPipe.fileHandleForWriting.write(standardInput)
      try inputPipe.fileHandleForWriting.close()
    }
    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data)
  }

  func runDataAsync(
    _ arguments: [String],
    at directoryURL: URL,
    environmentOverrides: [String: String] = [:],
    timeout: Duration,
    storageRootURL: URL? = nil,
    maximumStorageBytes: Int64? = nil
  ) async throws -> (status: Int32, output: Data) {
    let process = Process()
    let outputPipe = Pipe()
    process.executableURL = executableURL
    process.arguments = safeArguments(arguments)
    process.currentDirectoryURL = directoryURL
    process.environment = try commandEnvironment(
      authorName: nil,
      overrides: environmentOverrides
    )
    try validateRepositoryOperationAccess(at: directoryURL)
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    let execution = GitAsyncProcess(process: process, outputPipe: outputPipe)
    try execution.start()
    return try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(
        of: GitAsyncProcess.Result.self
      ) { group in
        group.addTask {
          await Task.detached(priority: .userInitiated) {
            execution.waitForExit()
          }.value
        }
        group.addTask {
          try await Task.sleep(for: timeout)
          execution.cancel()
          throw GitWorkspaceError.invalidRepository("import-clone-failed")
        }
        if let storageRootURL, let maximumStorageBytes {
          group.addTask {
            while true {
              if try Self.allocatedByteCount(
                under: storageRootURL,
                stoppingAfter: maximumStorageBytes
              ) > maximumStorageBytes {
                execution.cancel()
                throw GitWorkspaceError.invalidRepository(
                  "The remote repository exceeds Spedito's safe download limit."
                )
              }
              try await Task.sleep(for: .milliseconds(100))
            }
          }
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
          throw GitWorkspaceError.invalidRepository("import-clone-failed")
        }
        return (result.status, result.output)
      }
    } onCancel: {
      execution.cancel()
    }
  }

  private nonisolated static func allocatedByteCount(
    under rootURL: URL,
    stoppingAfter limit: Int64
  ) throws -> Int64 {
    guard
      let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.fileAllocatedSizeKey, .isRegularFileKey],
        options: [.skipsPackageDescendants]
      )
    else {
      return 0
    }
    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      let values = try fileURL.resourceValues(forKeys: [.fileAllocatedSizeKey, .isRegularFileKey])
      guard values.isRegularFile == true else { continue }
      total += Int64(values.fileAllocatedSize ?? 0)
      if total > limit {
        return total
      }
    }
    return total
  }

  private func safeArguments(_ arguments: [String]) -> [String] {
    [
      "-c", "core.hooksPath=/dev/null",
      "-c", "core.fsmonitor=false",
      "-c", "credential.helper=",
    ] + arguments
  }

  private func commandEnvironment(
    authorName: String?,
    overrides: [String: String] = [:]
  ) throws -> [String: String] {
    try fileManager.createDirectory(at: commandHomeURL, withIntermediateDirectories: true)
    let configURL = commandHomeURL.appendingPathComponent("config", isDirectory: true)
    try fileManager.createDirectory(at: configURL, withIntermediateDirectories: true)
    let inherited = ProcessInfo.processInfo.environment
    var environment: [String: String] = [
      "HOME": commandHomeURL.path,
      "XDG_CONFIG_HOME": configURL.path,
      "TMPDIR": inherited["TMPDIR"] ?? fileManager.temporaryDirectory.path,
      "LANG": inherited["LANG"] ?? "en_US.UTF-8",
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_CONFIG_SYSTEM": "/dev/null",
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_ATTR_NOSYSTEM": "1",
      "GIT_TERMINAL_PROMPT": "0",
      "GIT_ASKPASS": "/usr/bin/false",
      "SSH_ASKPASS": "/usr/bin/false",
      "GIT_EDITOR": "/usr/bin/true",
      "GIT_PAGER": "cat",
      "PAGER": "cat",
      "GIT_EXTERNAL_DIFF": "",
      "GIT_CONFIG_COUNT": "0",
      "GIT_AUTHOR_NAME": authorName ?? "Spedito",
      "GIT_AUTHOR_EMAIL": authorName.map(Self.agentEmail) ?? "spedito@localhost",
      "GIT_COMMITTER_NAME": "Spedito",
      "GIT_COMMITTER_EMAIL": "spedito@localhost",
    ]
    for (key, value) in inherited where key.hasPrefix("LC_") {
      environment[key] = value
    }
    for (key, value) in overrides {
      environment[key] = value
    }
    return environment
  }

  private static func pathComponent(_ value: String) -> String {
    let normalized = value.lowercased().map { character -> Character in
      character.isLetter || character.isNumber ? character : "-"
    }
    let collapsed = String(normalized)
      .split(separator: "-", omittingEmptySubsequences: true)
      .joined(separator: "-")
    return collapsed.isEmpty ? "ticket" : collapsed
  }

  private static let fieldSeparator = String(UnicodeScalar(0x1F)!)
  private static let recordSeparator = Character(UnicodeScalar(0x1E)!)

  private func records(in output: String) -> [String] {
    output
      .split(separator: Self.recordSeparator)
      .map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      .filter { !$0.isEmpty }
  }

  private func parseWorktrees(_ output: String) throws -> [String: String] {
    var result: [String: String] = [:]
    var path: String?
    for line in output.components(separatedBy: "\n") {
      if line.hasPrefix("worktree ") {
        path = String(line.dropFirst("worktree ".count))
      } else if line.hasPrefix("branch refs/heads/"), let path {
        let branch = String(line.dropFirst("branch refs/heads/".count))
        result[branch] = path
      } else if line.isEmpty {
        path = nil
      }
    }
    return result
  }

  private static func agentEmail(_ name: String) -> String {
    let localPart = pathComponent(name).replacingOccurrences(of: "-", with: ".")
    return "\(localPart)@agents.spedito.local"
  }
}

private final class GitAsyncProcess: @unchecked Sendable {
  struct Result: Sendable {
    let status: Int32
    let output: Data
  }

  private let process: Process
  private let outputPipe: Pipe
  private let lock = NSLock()
  private let terminationSignal = DispatchSemaphore(value: 0)

  init(process: Process, outputPipe: Pipe) {
    self.process = process
    self.outputPipe = outputPipe
    process.terminationHandler = { [terminationSignal] _ in
      terminationSignal.signal()
    }
  }

  func start() throws {
    try process.run()
  }

  func waitForExit() -> Result {
    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
    terminationSignal.wait()
    return Result(status: process.terminationStatus, output: output)
  }

  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    guard process.isRunning else { return }
    process.terminate()
  }
}
