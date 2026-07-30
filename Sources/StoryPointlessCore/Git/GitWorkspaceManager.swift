import Foundation

public enum GitWorkspaceError: Error, LocalizedError, Sendable {
  case commandFailed(arguments: [String], output: String)
  case invalidRepository(String)
  case mergeConflict(worktreePath: String, conflictedFiles: [String], output: String)

  public var errorDescription: String? {
    switch self {
    case .commandFailed(let arguments, let output):
      let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
      return "Git \(arguments.joined(separator: " ")) failed\(detail.isEmpty ? "." : ": \(detail)")"
    case .invalidRepository(let detail):
      return "The product workspace is not ready for isolated delivery: \(detail)"
    case .mergeConflict(_, let conflictedFiles, _):
      return "Candidate integration needs conflict resolution in: \(conflictedFiles.joined(separator: ", "))."
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

public actor GitWorkspaceManager {
  private let executableURL: URL
  private let fileManager: FileManager

  public init(
    executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
    fileManager: FileManager = .default
  ) {
    self.executableURL = executableURL
    self.fileManager = fileManager
  }

  @discardableResult
  public func ensureRepository(
    at repositoryURL: URL,
    rootIgnoreEntries: [String] = []
  ) throws -> String {
    try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
    try ensureRootGitIgnore(
      at: repositoryURL,
      entries: rootIgnoreEntries
    )
    let gitDirectory = repositoryURL.appendingPathComponent(".git", isDirectory: true)
    if !fileManager.fileExists(atPath: gitDirectory.path) {
      _ = try run(["init", "-b", "trunk"], at: repositoryURL)
      try configureIdentity(at: repositoryURL)
      _ = try run(["add", "-A"], at: repositoryURL)
      _ = try run(
        ["commit", "--allow-empty", "-m", "Initialize product workspace"],
        at: repositoryURL
      )
    } else {
      try configureIdentity(at: repositoryURL)
      guard (try? run(["rev-parse", "--is-inside-work-tree"], at: repositoryURL)) == "true" else {
        throw GitWorkspaceError.invalidRepository(repositoryURL.path)
      }
      if (try? run(["rev-parse", "--verify", "refs/heads/trunk"], at: repositoryURL)) == nil {
        _ = try run(["branch", "trunk", "HEAD"], at: repositoryURL)
      }
    }
    return try run(["rev-parse", "refs/heads/trunk"], at: repositoryURL)
  }

  private func ensureRootGitIgnore(
    at repositoryURL: URL,
    entries: [String]
  ) throws {
    let normalizedEntries = entries
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && !$0.contains("\n") && !$0.contains("\r") }
    guard !normalizedEntries.isEmpty else { return }

    let ignoreURL = repositoryURL.appendingPathComponent(".gitignore")
    let existing = (try? String(contentsOf: ignoreURL, encoding: .utf8)) ?? ""
    let existingEntries = Set(
      existing.split(whereSeparator: \.isNewline).map(String.init)
    )
    let missingEntries = normalizedEntries.filter {
      !existingEntries.contains($0)
    }
    guard !missingEntries.isEmpty else { return }

    let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
    let addition = missingEntries.map { "\($0)\n" }.joined()
    try Data("\(existing)\(separator)\(addition)".utf8).write(
      to: ignoreURL,
      options: .atomic
    )
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
      _ = try run(["commit", "-m", message], at: repositoryURL)
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
    let workspaceURL = worktreesRootURL
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
    summary: String? = nil
  ) throws -> GitCandidateSnapshot {
    let branchName = try run(["branch", "--show-current"], at: ticketWorkspaceURL)
    guard branchName.hasPrefix("ticket/") else {
      throw GitWorkspaceError.invalidRepository(
        "\(ticketWorkspaceURL.path) is not on a ticket branch."
      )
    }
    _ = try run(["add", "-A"], at: ticketWorkspaceURL)
    let trimmedSummary = summary?
      .components(separatedBy: .newlines)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let message = if let trimmedSummary, !trimmedSummary.isEmpty {
      "\(ticketKey.uppercased()): \(String(trimmedSummary.prefix(160)))"
    } else {
      "\(ticketKey.uppercased()): candidate v\(version)"
    }
    _ = try run(
      [
        "commit", "--allow-empty", "-m", message,
      ],
      at: ticketWorkspaceURL,
      authorName: authorName
    )
    let headSHA = try run(["rev-parse", "HEAD"], at: ticketWorkspaceURL)
    let baseSHA = try run(["merge-base", "trunk", headSHA], at: ticketWorkspaceURL)
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
    commitMessage: String? = nil
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
    _ = try run(
      ["worktree", "add", "--detach", integrationURL.path, "trunk"],
      at: repositoryURL
    )
    do {
      var mergeArguments = ["merge", "--no-ff"]
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
      let conflictedFiles = (
        try? run(["diff", "--name-only", "--diff-filter=U"], at: integrationURL)
      )?
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

  public func preparePreviewWorkspace(
    repositoryURL: URL,
    previewsRootURL: URL,
    candidateID: UUID,
    integratedSHA: String
  ) throws -> URL {
    try fileManager.createDirectory(at: previewsRootURL, withIntermediateDirectories: true)
    let previewURL = previewsRootURL.appendingPathComponent(
      candidateID.uuidString.lowercased(),
      isDirectory: true
    )
    if fileManager.fileExists(atPath: previewURL.path) {
      let currentRevision = try? run(["rev-parse", "HEAD"], at: previewURL)
      if currentRevision == integratedSHA {
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
      _ = try run(["commit", "--no-edit"], at: integrationWorkspaceURL)
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
    let currentTrunk = try run(["rev-parse", "refs/heads/trunk"], at: repositoryURL)
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
      _ = try run(["commit", "-m", message], at: workspaceURL)
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
    let accepted = try runAllowingFailure(
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
      let path = fields.count >= 3
        ? "\(fields[1]) → \(fields[2])"
        : String(fields[1])
      return GitChangedFile(status: status, path: path)
    }
    let completeDiff = try run(diffArguments, at: repositoryURL)
    let isTruncated = completeDiff.count > maximumDiffCharacters
    let diff = isTruncated
      ? String(completeDiff.prefix(maximumDiffCharacters))
      : completeDiff
    return GitCommitDetail(
      commit: commit,
      files: files,
      unifiedDiff: diff,
      isDiffTruncated: isTruncated
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
    let workspaceURL = branch.worktreePath.map {
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
        let path = fields.count >= 3
          ? "\(fields[1]) → \(fields[2])"
          : String(fields[1])
        return GitChangedFile(status: status, path: path)
      }
    let completeDiff = try run(diffArguments, at: workspaceURL)
    let isTruncated = completeDiff.count > maximumDiffCharacters
    return GitBranchDetail(
      branch: branch,
      files: files,
      unifiedDiff: isTruncated
        ? String(completeDiff.prefix(maximumDiffCharacters))
        : completeDiff,
      isDiffTruncated: isTruncated
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
    _ = try run(["config", "user.name", "StoryPointless"], at: repositoryURL)
    _ = try run(["config", "user.email", "storypointless@localhost"], at: repositoryURL)
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

  private func run(
    _ arguments: [String],
    at directoryURL: URL,
    authorName: String? = nil
  ) throws -> String {
    let result = try runAllowingFailure(
      arguments,
      at: directoryURL,
      authorName: authorName
    )
    guard result.status == 0 else {
      throw GitWorkspaceError.commandFailed(arguments: arguments, output: result.output)
    }
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func runAllowingFailure(
    _ arguments: [String],
    at directoryURL: URL,
    authorName: String? = nil
  ) throws -> (status: Int32, output: String) {
    let process = Process()
    let outputPipe = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.currentDirectoryURL = directoryURL
    if let authorName {
      var environment = ProcessInfo.processInfo.environment
      environment["GIT_AUTHOR_NAME"] = authorName
      environment["GIT_AUTHOR_EMAIL"] = Self.agentEmail(authorName)
      environment["GIT_COMMITTER_NAME"] = "StoryPointless"
      environment["GIT_COMMITTER_EMAIL"] = "storypointless@localhost"
      process.environment = environment
    }
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    try process.run()
    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
      process.terminationStatus,
      String(data: data, encoding: .utf8) ?? ""
    )
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
    return "\(localPart)@agents.storypointless.local"
  }
}
