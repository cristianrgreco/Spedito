import CryptoKit
import Foundation

public struct GitRemotePath: Codable, Equatable, Identifiable, Sendable {
  public var id: Data { rawBytes }
  public let rawBytes: Data
  public let displayPath: String
  public let collisionKey: String?

  public init(rawBytes: Data) {
    self.rawBytes = rawBytes
    if let path = String(data: rawBytes, encoding: .utf8) {
      displayPath = path
      collisionKey = GitWorkspaceManager.repositoryPathCollisionKey(path)
    } else {
      displayPath = "hex:" + rawBytes.map { String(format: "%02x", $0) }.joined()
      collisionKey = nil
    }
  }
}

public struct GitRemoteTreeEntry: Equatable, Sendable {
  public let mode: String
  public let objectType: String
  public let objectSHA: String
  public let path: GitRemotePath
}

public struct GitRemoteObservation: Equatable, Sendable {
  public let observationRef: String
  public let localSHA: String
  public let localTree: String
  public let remoteSHA: String
  public let remoteTree: String
  public let mergeBaseSHA: String?
  public let aheadCount: Int
  public let behindCount: Int
  public let relationship: RemoteRepositoryRelationship
  public let commits: [RemoteCommitSummary]
  public let paths: [GitRemotePath]
}

public struct GitBootstrapRoot: Equatable, Sendable {
  public let sha: String
  public let tree: String

  public init(sha: String, tree: String) {
    self.sha = sha
    self.tree = tree
  }
}

public struct GitOutboundManifest: Equatable, Sendable {
  public let digest: String
  public let objectCount: Int
  public let commits: [RemoteCommitSummary]
  public let paths: [GitRemotePath]

  public var commitCount: Int { commits.count }
  public var pathCount: Int { paths.count }
}

public enum GitRemoteOperationError: Error, Equatable, LocalizedError, Sendable {
  case unsafeRepository(String)
  case remoteMoved
  case remoteNotEmpty
  case remoteRefConflict
  case unsupportedSystemGit

  public var errorDescription: String? {
    switch self {
    case .unsafeRepository(let message): message
    case .remoteMoved: "GitHub changed while Spedito was checking it. Check GitHub again."
    case .remoteNotEmpty:
      "Choose an empty GitHub repository without a README, license, or .gitignore."
    case .remoteRefConflict: "The GitHub branch changed unexpectedly. Spedito did not overwrite it."
    case .unsupportedSystemGit:
      "This Mac’s system Git cannot safely accept these incoming files."
    }
  }
}

extension GitWorkspaceManager {
  public func fetchRemoteObservation(
    repositoryURL: URL,
    canonicalHTTPSURL: URL,
    targetBranch: String,
    observationID: UUID,
    credentialConfiguration: GitCredentialSessionConfiguration,
    timeout: Duration = .seconds(120)
  ) async throws -> GitRemoteObservation {
    try await withRepositoryOperation(at: repositoryURL) {
      try await self.fetchRemoteObservationWithinRepositoryOperation(
        repositoryURL: repositoryURL,
        canonicalHTTPSURL: canonicalHTTPSURL,
        targetBranch: targetBranch,
        observationID: observationID,
        credentialConfiguration: credentialConfiguration,
        timeout: timeout
      )
    }
  }

  private func fetchRemoteObservationWithinRepositoryOperation(
    repositoryURL: URL,
    canonicalHTTPSURL: URL,
    targetBranch: String,
    observationID: UUID,
    credentialConfiguration: GitCredentialSessionConfiguration,
    timeout: Duration = .seconds(120)
  ) async throws -> GitRemoteObservation {
    try validateCanonicalGitHubURL(canonicalHTTPSURL)
    guard
      try runAllowingFailure(
        ["check-ref-format", "--branch", targetBranch],
        at: repositoryURL
      ).status == 0
    else {
      throw GitRemoteOperationError.unsafeRepository("The GitHub default branch name is invalid.")
    }
    let observationRef = "refs/spedito/observations/\(observationID.uuidString.lowercased())"
    guard
      try runAllowingFailure(
        ["show-ref", "--verify", "--quiet", observationRef],
        at: repositoryURL
      ).status == 1
    else {
      throw GitRemoteOperationError.unsafeRepository("The GitHub check reference already exists.")
    }

    let quarantineURL = fileManager.temporaryDirectory.appendingPathComponent(
      "io.spedito.remote-observation-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? fileManager.removeItem(at: quarantineURL) }
    _ = try run(
      ["clone", "--shared", "--no-checkout", "--", repositoryURL.path, quarantineURL.path],
      at: fileManager.temporaryDirectory
    )

    let refspec = "refs/heads/\(targetBranch):\(observationRef)"
    let quarantineObjectsURL =
      quarantineURL
      .appendingPathComponent(".git", isDirectory: true)
      .appendingPathComponent("objects", isDirectory: true)
    let result = try await runDataAsync(
      credentialConfiguration.gitConfigurationArguments + [
        "-c", "http.followRedirects=false",
        "fetch", "--no-tags", "--no-recurse-submodules", "--",
        canonicalHTTPSURL.absoluteString, refspec,
      ],
      at: quarantineURL,
      timeout: timeout,
      storageRootURL: quarantineObjectsURL,
      maximumStorageBytes: 512 * 1_024 * 1_024
    )
    guard result.status == 0 else {
      throw GitRemoteOperationError.unsafeRepository(
        "GitHub repository history could not be fetched safely."
      )
    }
    let observation = try inspectFetchedRemoteObservation(
      repositoryURL: quarantineURL,
      observationRef: observationRef
    )

    do {
      let importResult = try await runDataAsync(
        [
          "fetch", "--no-tags", "--no-recurse-submodules", "--",
          quarantineURL.path, "\(observationRef):\(observationRef)",
        ],
        at: repositoryURL,
        timeout: timeout
      )
      guard importResult.status == 0,
        try run(["rev-parse", "\(observationRef)^{commit}"], at: repositoryURL)
          == observation.remoteSHA
      else {
        throw GitRemoteOperationError.unsafeRepository(
          "The verified GitHub repository history could not be stored."
        )
      }
      return observation
    } catch {
      try? deleteRemoteObservationRef(repositoryURL: repositoryURL, ref: observationRef)
      throw error
    }
  }

  private func inspectFetchedRemoteObservation(
    repositoryURL: URL,
    observationRef: String
  ) throws -> GitRemoteObservation {
    let localSHA = try run(["rev-parse", "refs/heads/trunk^{commit}"], at: repositoryURL)
    let remoteSHA = try run(["rev-parse", "\(observationRef)^{commit}"], at: repositoryURL)
    let localTree = try run(["rev-parse", "\(localSHA)^{tree}"], at: repositoryURL)
    let remoteTree = try run(["rev-parse", "\(remoteSHA)^{tree}"], at: repositoryURL)
    let mergeResult = try runAllowingFailure(
      ["merge-base", localSHA, remoteSHA],
      at: repositoryURL
    )
    let mergeBase =
      mergeResult.status == 0
      ? mergeResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
      : nil
    let relationship: RemoteRepositoryRelationship
    if localSHA == remoteSHA {
      relationship = .aligned
    } else if mergeBase == nil {
      relationship = .unrelated
    } else if try isAncestor(localSHA, of: remoteSHA, at: repositoryURL) {
      relationship = .remoteAhead
    } else if try isAncestor(remoteSHA, of: localSHA, at: repositoryURL) {
      relationship = .localAhead
    } else {
      relationship = .diverged
    }
    let counts = try aheadBehind(localSHA: localSHA, remoteSHA: remoteSHA, at: repositoryURL)
    if let mergeBase, mergeBase != remoteSHA {
      try validateTreeRange(
        repositoryURL: repositoryURL,
        baseSHA: mergeBase,
        candidateSHA: remoteSHA
      )
    }
    let commits = try remoteCommitSummaries(
      repositoryURL: repositoryURL,
      localSHA: localSHA,
      remoteSHA: remoteSHA
    )
    let paths = try changedRemotePaths(
      repositoryURL: repositoryURL,
      localSHA: localSHA,
      remoteSHA: remoteSHA
    )
    return GitRemoteObservation(
      observationRef: observationRef,
      localSHA: localSHA,
      localTree: localTree,
      remoteSHA: remoteSHA,
      remoteTree: remoteTree,
      mergeBaseSHA: mergeBase,
      aheadCount: counts.ahead,
      behindCount: counts.behind,
      relationship: relationship,
      commits: commits,
      paths: paths
    )
  }
  public func deleteRemoteObservationRef(
    repositoryURL: URL,
    ref: String
  ) throws {
    guard ref.hasPrefix("refs/spedito/observations/") else {
      throw GitRemoteOperationError.unsafeRepository("The GitHub check reference is invalid.")
    }
    _ = try runAllowingFailure(["update-ref", "-d", ref], at: repositoryURL)
  }

  public func cleanupOrphanRemoteObservationRefs(
    repositoryURL: URL,
    retaining: Set<String>
  ) throws {
    let output = try run(
      ["for-each-ref", "--format=%(refname)", "refs/spedito/observations"],
      at: repositoryURL
    )
    for ref in output.split(separator: "\n").map(String.init) where !retaining.contains(ref) {
      try deleteRemoteObservationRef(repositoryURL: repositoryURL, ref: ref)
    }
  }

  public func createHistoryAlignmentCandidate(
    repositoryURL: URL,
    localSHA: String,
    remoteSHA: String,
    publishedSHA: String,
    expectedRemoteTree: String
  ) throws -> (sha: String, tree: String) {
    guard try isAncestor(publishedSHA, of: localSHA, at: repositoryURL),
      try run(["rev-parse", "\(publishedSHA)^{tree}"], at: repositoryURL) == expectedRemoteTree,
      try run(["rev-parse", "\(remoteSHA)^{tree}"], at: repositoryURL) == expectedRemoteTree
    else {
      throw GitRemoteOperationError.remoteMoved
    }
    let localTree = try run(["rev-parse", "\(localSHA)^{tree}"], at: repositoryURL)
    let fixedEnvironment = [
      "GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z",
      "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z",
    ]
    let candidate = try run(
      [
        "-c", "commit.gpgSign=false", "commit-tree", localTree,
        "-p", localSHA, "-p", remoteSHA,
        "-m", "Align local history with Spedito pull request",
      ],
      at: repositoryURL,
      environmentOverrides: fixedEnvironment
    )
    let parents = try run(["show", "-s", "--format=%P", candidate], at: repositoryURL)
      .split(separator: " ").map(String.init)
    guard parents == [localSHA, remoteSHA],
      try run(["rev-parse", "\(candidate)^{tree}"], at: repositoryURL) == localTree
    else {
      throw GitRemoteOperationError.unsafeRepository("The history alignment proof is invalid.")
    }
    return (candidate, localTree)
  }

  public func promoteRemoteSafeSync(
    repositoryURL: URL,
    expectedTrunkSHA: String,
    candidateSHA: String,
    expectedTree: String
  ) throws {
    guard try repositoryDirtyPaths(at: repositoryURL).isEmpty,
      try run(["branch", "--show-current"], at: repositoryURL) == "trunk"
    else {
      throw GitRemoteOperationError.unsafeRepository(
        "The Product workspace has uncaptured local changes.")
    }
    let current = try run(["rev-parse", "refs/heads/trunk"], at: repositoryURL)
    guard current == expectedTrunkSHA || current == candidateSHA else {
      throw GitRemoteOperationError.remoteMoved
    }
    guard try run(["rev-parse", "\(candidateSHA)^{tree}"], at: repositoryURL) == expectedTree,
      try isAncestor(expectedTrunkSHA, of: candidateSHA, at: repositoryURL)
    else {
      throw GitRemoteOperationError.unsafeRepository(
        "The incoming GitHub candidate proof is invalid.")
    }
    _ = try remoteTreeEntries(repositoryURL: repositoryURL, sha: candidateSHA)
    let filterArguments = try safeFilterArguments(repositoryURL: repositoryURL, sha: candidateSHA)
    if current == expectedTrunkSHA {
      _ = try run(
        ["update-ref", "refs/heads/trunk", candidateSHA, expectedTrunkSHA],
        at: repositoryURL
      )
    }
    _ = try run(filterArguments + ["reset", "--hard", "trunk"], at: repositoryURL)
    guard try run(["rev-parse", "refs/heads/trunk"], at: repositoryURL) == candidateSHA,
      try repositoryDirtyPaths(at: repositoryURL).isEmpty
    else {
      throw GitRemoteOperationError.unsafeRepository(
        "The accepted GitHub revision was not synchronized safely.")
    }
  }

  public func localBootstrapRoot(repositoryURL: URL) throws -> GitBootstrapRoot {
    guard try repositoryDirtyPaths(at: repositoryURL).isEmpty,
      try run(["branch", "--show-current"], at: repositoryURL) == "trunk"
    else {
      throw GitRemoteOperationError.unsafeRepository(
        "The Product workspace must be clean on trunk.")
    }
    let roots = try run(["rev-list", "--max-parents=0", "trunk"], at: repositoryURL)
      .split(separator: "\n").map(String.init)
    guard roots.count == 1 else {
      throw GitRemoteOperationError.unsafeRepository(
        "The Product does not have one bootstrap root commit.")
    }
    let parents = try run(["show", "-s", "--format=%P", roots[0]], at: repositoryURL)
    guard parents.isEmpty else {
      throw GitRemoteOperationError.unsafeRepository(
        "The Product bootstrap commit is not a root commit.")
    }
    return GitBootstrapRoot(
      sha: roots[0],
      tree: try run(["rev-parse", "\(roots[0])^{tree}"], at: repositoryURL)
    )
  }

  public func remoteHeadSHAs(
    repositoryURL: URL,
    canonicalHTTPSURL: URL,
    credentialConfiguration: GitCredentialSessionConfiguration,
    timeout: Duration = .seconds(60)
  ) async throws -> [String: String] {
    try await withRepositoryOperation(at: repositoryURL) {
      try await self.remoteHeadSHAsWithinRepositoryOperation(
        repositoryURL: repositoryURL,
        canonicalHTTPSURL: canonicalHTTPSURL,
        credentialConfiguration: credentialConfiguration,
        timeout: timeout
      )
    }
  }

  private func remoteHeadSHAsWithinRepositoryOperation(
    repositoryURL: URL,
    canonicalHTTPSURL: URL,
    credentialConfiguration: GitCredentialSessionConfiguration,
    timeout: Duration = .seconds(60)
  ) async throws -> [String: String] {
    try validateCanonicalGitHubURL(canonicalHTTPSURL)
    let result = try await runDataAsync(
      credentialConfiguration.gitConfigurationArguments + [
        "-c", "http.followRedirects=false", "ls-remote", "--heads", "--",
        canonicalHTTPSURL.absoluteString,
      ],
      at: repositoryURL,
      timeout: timeout
    )
    guard result.status == 0,
      let output = String(data: result.output, encoding: .utf8)
    else {
      throw GitRemoteOperationError.unsafeRepository("GitHub branch information is unavailable.")
    }
    var heads: [String: String] = [:]
    for line in output.split(separator: "\n") {
      let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
      guard fields.count == 2, fields[1].hasPrefix("refs/heads/") else {
        throw GitRemoteOperationError.unsafeRepository(
          "GitHub returned malformed branch information.")
      }
      heads[fields[1]] = fields[0]
    }
    return heads
  }

  public func remoteHeadSHA(
    repositoryURL: URL,
    canonicalHTTPSURL: URL,
    fullRef: String,
    credentialConfiguration: GitCredentialSessionConfiguration,
    timeout: Duration = .seconds(60)
  ) async throws -> String? {
    try await withRepositoryOperation(at: repositoryURL) {
      try await self.remoteHeadSHAWithinRepositoryOperation(
        repositoryURL: repositoryURL,
        canonicalHTTPSURL: canonicalHTTPSURL,
        fullRef: fullRef,
        credentialConfiguration: credentialConfiguration,
        timeout: timeout
      )
    }
  }

  private func remoteHeadSHAWithinRepositoryOperation(
    repositoryURL: URL,
    canonicalHTTPSURL: URL,
    fullRef: String,
    credentialConfiguration: GitCredentialSessionConfiguration,
    timeout: Duration
  ) async throws -> String? {
    try validateCanonicalGitHubURL(canonicalHTTPSURL)
    guard fullRef.hasPrefix("refs/heads/"),
      try runAllowingFailure(["check-ref-format", fullRef], at: repositoryURL).status == 0
    else {
      throw GitRemoteOperationError.unsafeRepository("The GitHub branch name is invalid.")
    }
    let result = try await runDataAsync(
      credentialConfiguration.gitConfigurationArguments + [
        "-c", "http.followRedirects=false", "ls-remote", "--heads", "--",
        canonicalHTTPSURL.absoluteString, fullRef,
      ],
      at: repositoryURL,
      timeout: timeout
    )
    guard result.status == 0,
      let output = String(data: result.output, encoding: .utf8)
    else {
      throw GitRemoteOperationError.unsafeRepository("GitHub branch information is unavailable.")
    }
    let lines = output.split(separator: "\n")
    guard lines.count <= 1 else {
      throw GitRemoteOperationError.unsafeRepository(
        "GitHub returned ambiguous branch information."
      )
    }
    guard let line = lines.first else { return nil }
    let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
    guard fields.count == 2, fields[1] == fullRef else {
      throw GitRemoteOperationError.unsafeRepository(
        "GitHub returned malformed branch information."
      )
    }
    return fields[0]
  }

  public func initializeEmptyRemote(
    repositoryURL: URL,
    canonicalHTTPSURL: URL,
    defaultBranch: String,
    bootstrapSHA: String,
    credentialConfiguration: GitCredentialSessionConfiguration,
    timeout: Duration = .seconds(120)
  ) async throws {
    try await withRepositoryOperation(at: repositoryURL) {
      try await self.initializeEmptyRemoteWithinRepositoryOperation(
        repositoryURL: repositoryURL,
        canonicalHTTPSURL: canonicalHTTPSURL,
        defaultBranch: defaultBranch,
        bootstrapSHA: bootstrapSHA,
        credentialConfiguration: credentialConfiguration,
        timeout: timeout
      )
    }
  }

  private func initializeEmptyRemoteWithinRepositoryOperation(
    repositoryURL: URL,
    canonicalHTTPSURL: URL,
    defaultBranch: String,
    bootstrapSHA: String,
    credentialConfiguration: GitCredentialSessionConfiguration,
    timeout: Duration = .seconds(120)
  ) async throws {
    let heads = try await remoteHeadSHAs(
      repositoryURL: repositoryURL,
      canonicalHTTPSURL: canonicalHTTPSURL,
      credentialConfiguration: credentialConfiguration
    )
    guard heads.isEmpty else { throw GitRemoteOperationError.remoteNotEmpty }
    guard
      try runAllowingFailure(
        ["check-ref-format", "--branch", defaultBranch],
        at: repositoryURL
      ).status == 0,
      try localBootstrapRoot(repositoryURL: repositoryURL).sha == bootstrapSHA
    else {
      throw GitRemoteOperationError.unsafeRepository("The Product bootstrap revision changed.")
    }
    let fullRef = "refs/heads/\(defaultBranch)"
    let result = try await runDataAsync(
      credentialConfiguration.gitConfigurationArguments + [
        "-c", "http.followRedirects=false", "push", "--no-verify", "--no-recurse-submodules",
        "--force-with-lease=\(fullRef):", "--", canonicalHTTPSURL.absoluteString,
        "\(bootstrapSHA):\(fullRef)",
      ],
      at: repositoryURL,
      timeout: timeout
    )
    if result.status != 0 {
      let after = try await remoteHeadSHAs(
        repositoryURL: repositoryURL,
        canonicalHTTPSURL: canonicalHTTPSURL,
        credentialConfiguration: credentialConfiguration
      )
      if after[fullRef] == bootstrapSHA { return }
      if after[fullRef] == nil { throw GitRemoteOperationError.remoteMoved }
      throw GitRemoteOperationError.remoteRefConflict
    }
    let after = try await remoteHeadSHAs(
      repositoryURL: repositoryURL,
      canonicalHTTPSURL: canonicalHTTPSURL,
      credentialConfiguration: credentialConfiguration
    )
    guard after[fullRef] == bootstrapSHA else {
      throw after[fullRef] == nil
        ? GitRemoteOperationError.remoteMoved
        : GitRemoteOperationError.remoteRefConflict
    }
  }

  public func verifyOrAddOrigin(
    repositoryURL: URL,
    canonicalHTTPSURL: URL
  ) throws {
    try validateCanonicalGitHubURL(canonicalHTTPSURL)
    let current = try runAllowingFailure(["remote", "get-url", "origin"], at: repositoryURL)
    if current.status == 0 {
      guard
        current.output.trimmingCharacters(in: .whitespacesAndNewlines)
          == canonicalHTTPSURL.absoluteString
      else {
        throw GitRemoteOperationError.unsafeRepository(
          "The Product already has a different Git origin.")
      }
      return
    }
    _ = try run(["remote", "add", "origin", canonicalHTTPSURL.absoluteString], at: repositoryURL)
    guard
      try run(["remote", "get-url", "origin"], at: repositoryURL)
        == canonicalHTTPSURL.absoluteString
    else {
      throw GitRemoteOperationError.unsafeRepository("The GitHub origin could not be verified.")
    }
  }

  public func createRemoteReviewBranch(
    repositoryURL: URL,
    canonicalHTTPSURL: URL,
    fullRef: String,
    localSHA: String,
    expectedCurrentSHA: String? = nil,
    credentialConfiguration: GitCredentialSessionConfiguration,
    timeout: Duration = .seconds(120)
  ) async throws {
    try await withRepositoryOperation(at: repositoryURL) {
      try await self.createRemoteReviewBranchWithinRepositoryOperation(
        repositoryURL: repositoryURL,
        canonicalHTTPSURL: canonicalHTTPSURL,
        fullRef: fullRef,
        localSHA: localSHA,
        expectedCurrentSHA: expectedCurrentSHA,
        credentialConfiguration: credentialConfiguration,
        timeout: timeout
      )
    }
  }

  private func createRemoteReviewBranchWithinRepositoryOperation(
    repositoryURL: URL,
    canonicalHTTPSURL: URL,
    fullRef: String,
    localSHA: String,
    expectedCurrentSHA: String? = nil,
    credentialConfiguration: GitCredentialSessionConfiguration,
    timeout: Duration = .seconds(120)
  ) async throws {
    guard fullRef.hasPrefix("refs/heads/spedito/"),
      try runAllowingFailure(["check-ref-format", fullRef], at: repositoryURL).status == 0,
      try run(["rev-parse", "\(localSHA)^{commit}"], at: repositoryURL) == localSHA
    else {
      throw GitRemoteOperationError.unsafeRepository("The review branch is invalid.")
    }
    let before = try await remoteHeadSHA(
      repositoryURL: repositoryURL,
      canonicalHTTPSURL: canonicalHTTPSURL,
      fullRef: fullRef,
      credentialConfiguration: credentialConfiguration
    )
    if before == localSHA { return }
    guard before == expectedCurrentSHA else {
      throw GitRemoteOperationError.remoteRefConflict
    }
    let result = try await runDataAsync(
      credentialConfiguration.gitConfigurationArguments + [
        "-c", "http.followRedirects=false", "push", "--no-verify", "--no-recurse-submodules",
        "--force-with-lease=\(fullRef):\(expectedCurrentSHA ?? "")", "--",
        canonicalHTTPSURL.absoluteString,
        "\(localSHA):\(fullRef)",
      ],
      at: repositoryURL,
      timeout: timeout
    )
    let after = try await remoteHeadSHA(
      repositoryURL: repositoryURL,
      canonicalHTTPSURL: canonicalHTTPSURL,
      fullRef: fullRef,
      credentialConfiguration: credentialConfiguration
    )
    guard after == localSHA else {
      if after != nil { throw GitRemoteOperationError.remoteRefConflict }
      guard result.status == 0 else { throw GitRemoteOperationError.remoteMoved }
      throw GitRemoteOperationError.remoteMoved
    }
  }

  func deleteRemoteReviewBranch(
    repositoryURL: URL,
    canonicalHTTPSURL: URL,
    fullRef: String,
    expectedSHA: String,
    credentialConfiguration: GitCredentialSessionConfiguration,
    timeout: Duration = .seconds(120)
  ) async throws {
    try await withRepositoryOperation(at: repositoryURL) {
      try await self.deleteRemoteReviewBranchWithinRepositoryOperation(
        repositoryURL: repositoryURL,
        canonicalHTTPSURL: canonicalHTTPSURL,
        fullRef: fullRef,
        expectedSHA: expectedSHA,
        credentialConfiguration: credentialConfiguration,
        timeout: timeout
      )
    }
  }

  private func deleteRemoteReviewBranchWithinRepositoryOperation(
    repositoryURL: URL,
    canonicalHTTPSURL: URL,
    fullRef: String,
    expectedSHA: String,
    credentialConfiguration: GitCredentialSessionConfiguration,
    timeout: Duration = .seconds(120)
  ) async throws {
    guard fullRef.hasPrefix("refs/heads/spedito/"),
      try runAllowingFailure(["check-ref-format", fullRef], at: repositoryURL).status == 0,
      expectedSHA.utf8.count == 40,
      expectedSHA.utf8.allSatisfy({
        ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
      })
    else {
      throw GitRemoteOperationError.unsafeRepository("The review branch is invalid.")
    }
    guard
      let currentSHA = try await remoteHeadSHA(
        repositoryURL: repositoryURL,
        canonicalHTTPSURL: canonicalHTTPSURL,
        fullRef: fullRef,
        credentialConfiguration: credentialConfiguration
      )
    else { return }
    guard currentSHA == expectedSHA else {
      throw GitRemoteOperationError.remoteRefConflict
    }
    _ = try await runDataAsync(
      credentialConfiguration.gitConfigurationArguments + [
        "-c", "http.followRedirects=false", "push", "--no-verify", "--no-recurse-submodules",
        "--force-with-lease=\(fullRef):\(expectedSHA)", "--delete", "--",
        canonicalHTTPSURL.absoluteString,
        fullRef,
      ],
      at: repositoryURL,
      timeout: timeout
    )
    let remainingSHA = try await remoteHeadSHA(
      repositoryURL: repositoryURL,
      canonicalHTTPSURL: canonicalHTTPSURL,
      fullRef: fullRef,
      credentialConfiguration: credentialConfiguration
    )
    guard let remainingSHA else { return }
    guard remainingSHA == expectedSHA else {
      throw GitRemoteOperationError.remoteRefConflict
    }
    throw GitRemoteOperationError.remoteMoved
  }

  public nonisolated static func publicationBranchName(
    productName: String,
    productID: UUID,
    localSHA: String
  ) -> String {
    let folded = productName.folding(
      options: [.diacriticInsensitive, .caseInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
    var slug = folded.unicodeScalars.map { scalar -> Character in
      scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
        ? Character(String(scalar).lowercased())
        : "-"
    }
    while slug.first == "-" { slug.removeFirst() }
    while slug.last == "-" { slug.removeLast() }
    let normalized = String(slug.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let safeSlug = normalized.isEmpty ? "product" : normalized
    let productPart = productID.uuidString.replacingOccurrences(of: "-", with: "")
      .lowercased().prefix(8)
    return "spedito/\(safeSlug)-\(productPart)-\(localSHA.lowercased().prefix(12))"
  }

  public func revisionTreeSHA(
    repositoryURL: URL,
    revisionSHA: String
  ) throws -> String {
    try run(["rev-parse", "\(revisionSHA)^{tree}"], at: repositoryURL)
  }

  public func outboundManifest(
    repositoryURL: URL,
    remoteBaseSHA: String,
    localSHA: String,
    activeTokens: Set<String> = []
  ) throws -> GitOutboundManifest {
    guard try repositoryDirtyPaths(at: repositoryURL).isEmpty,
      try isAncestor(remoteBaseSHA, of: localSHA, at: repositoryURL)
    else {
      throw GitRemoteOperationError.unsafeRepository(
        "The local Product is not cleanly based on GitHub.")
    }
    let commitSHAs = try run(
      ["rev-list", "--reverse", "\(remoteBaseSHA)..\(localSHA)"],
      at: repositoryURL
    ).split(separator: "\n").map(String.init)
    var commits: [RemoteCommitSummary] = []
    var pathsByBytes: [Data: GitRemotePath] = [:]
    var objects = Set<String>()
    for commitSHA in commitSHAs {
      let commitData = try repositoryObjectData(
        repositoryURL: repositoryURL,
        type: "commit",
        sha: commitSHA
      )
      try rejectSensitiveData(commitData, activeTokens: activeTokens)
      let subject = try run(["show", "-s", "--format=%s", commitSHA], at: repositoryURL)
      commits.append(RemoteCommitSummary(sha: commitSHA, subject: subject))
      let changed = try runDataAllowingFailure(
        ["diff-tree", "--root", "--no-commit-id", "--name-only", "-r", "-z", commitSHA],
        at: repositoryURL
      )
      guard changed.status == 0 else {
        throw GitRemoteOperationError.unsafeRepository(
          "Outgoing repository paths could not be inspected.")
      }
      for bytes in changed.output.split(separator: 0, omittingEmptySubsequences: true) {
        let path = GitRemotePath(rawBytes: Data(bytes))
        try rejectControlPath(path)
        pathsByBytes[path.rawBytes] = path
      }
      for entry in try remoteTreeEntries(repositoryURL: repositoryURL, sha: commitSHA) {
        try rejectControlPath(entry.path)
        objects.insert(entry.objectSHA)
        if entry.objectType == "blob" {
          let data = try repositoryObjectData(
            repositoryURL: repositoryURL,
            type: "blob",
            sha: entry.objectSHA
          )
          try rejectSensitiveData(data, activeTokens: activeTokens)
          if data.starts(with: Data("version https://git-lfs.github.com/spec/v1\n".utf8)) {
            throw GitRemoteOperationError.unsafeRepository(
              "Git LFS files cannot be published until their remote objects can be verified."
            )
          }
        }
      }
      objects.insert(commitSHA)
      objects.insert(try run(["rev-parse", "\(commitSHA)^{tree}"], at: repositoryURL))
    }
    guard objects.count <= 100_000, pathsByBytes.count <= 100_000 else {
      throw GitRemoteOperationError.unsafeRepository(
        "The outgoing repository history is too large to verify safely.")
    }
    let paths = pathsByBytes.values.sorted { $0.rawBytes.lexicographicallyPrecedes($1.rawBytes) }
    var manifest = Data()
    for value in objects.sorted() {
      appendLengthPrefixed(Data(value.utf8), to: &manifest)
    }
    for commit in commits {
      appendLengthPrefixed(Data(commit.sha.utf8), to: &manifest)
      appendLengthPrefixed(Data(commit.subject.utf8), to: &manifest)
    }
    for path in paths {
      appendLengthPrefixed(path.rawBytes, to: &manifest)
    }
    return GitOutboundManifest(
      digest: SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined(),
      objectCount: objects.count,
      commits: commits,
      paths: paths
    )
  }

  private func remoteTreeEntries(
    repositoryURL: URL,
    sha: String
  ) throws -> [GitRemoteTreeEntry] {
    let result = try runDataAllowingFailure(
      ["ls-tree", "-r", "-z", "--full-tree", sha],
      at: repositoryURL
    )
    guard result.status == 0 else {
      throw GitRemoteOperationError.unsafeRepository("The repository tree is unavailable.")
    }
    var entries: [GitRemoteTreeEntry] = []
    for record in result.output.split(separator: 0, omittingEmptySubsequences: true) {
      guard let tab = record.firstIndex(of: 9),
        let metadata = String(bytes: record[..<tab], encoding: .utf8)
      else {
        throw GitRemoteOperationError.unsafeRepository("The repository tree is malformed.")
      }
      let fields = metadata.split(separator: " ").map(String.init)
      guard fields.count == 3,
        ["100644", "100755"].contains(fields[0]),
        fields[1] == "blob",
        entries.count < 100_000
      else {
        throw GitRemoteOperationError.unsafeRepository(
          "The repository contains unsupported or too many file entries."
        )
      }
      let rawPath = Data(record[record.index(after: tab)...])
      guard rawPath.count <= 4_096 else {
        throw GitRemoteOperationError.unsafeRepository(
          "The repository contains a path that cannot be checked out safely."
        )
      }
      let path = GitRemotePath(rawBytes: rawPath)
      try rejectControlPath(path)
      entries.append(
        GitRemoteTreeEntry(
          mode: fields[0],
          objectType: fields[1],
          objectSHA: fields[2],
          path: path
        )
      )
    }
    return entries
  }

  private func validateTreeRange(
    repositoryURL: URL,
    baseSHA: String,
    candidateSHA: String
  ) throws {
    let commits = try run(
      ["rev-list", "--reverse", "--max-count=5001", "\(baseSHA)..\(candidateSHA)"],
      at: repositoryURL
    ).split(separator: "\n").map(String.init)
    guard commits.count <= 5_000 else {
      throw GitRemoteOperationError.unsafeRepository(
        "The incoming repository history is too large to verify safely."
      )
    }
    var inspectedBlobs = Set<String>()
    for commit in commits {
      let entries = try remoteTreeEntries(repositoryURL: repositoryURL, sha: commit)
      try rejectLFSPointers(
        in: entries,
        repositoryURL: repositoryURL,
        inspectedBlobs: &inspectedBlobs
      )
    }
  }

  private func safeFilterArguments(repositoryURL: URL, sha: String) throws -> [String] {
    let entries = try remoteTreeEntries(repositoryURL: repositoryURL, sha: sha)
    var inspectedBlobs = Set<String>()
    try rejectLFSPointers(
      in: entries,
      repositoryURL: repositoryURL,
      inspectedBlobs: &inspectedBlobs
    )
    let paths = try entries.map { entry -> String in
      guard let value = String(data: entry.path.rawBytes, encoding: .utf8) else {
        throw GitRemoteOperationError.unsupportedSystemGit
      }
      return value
    }
    var drivers = Set<String>()
    func inspectAttributes(standardInput: Data) throws {
      let result = try runDataAllowingFailure(
        ["check-attr", "--source=\(sha)", "-z", "--stdin", "filter"],
        at: repositoryURL,
        standardInput: standardInput
      )
      guard result.status == 0 else { throw GitRemoteOperationError.unsupportedSystemGit }
      let fields = result.output.split(separator: 0, omittingEmptySubsequences: false)
      guard fields.count >= 1, (fields.count - 1).isMultiple(of: 3) else {
        throw GitRemoteOperationError.unsupportedSystemGit
      }
      var index = 0
      while index + 2 < fields.count - 1 {
        guard String(bytes: fields[index], encoding: .utf8) != nil,
          let attribute = String(bytes: fields[index + 1], encoding: .utf8),
          let value = String(bytes: fields[index + 2], encoding: .utf8),
          attribute == "filter"
        else {
          throw GitRemoteOperationError.unsupportedSystemGit
        }
        if !["unspecified", "unset", "set"].contains(value) {
          guard
            value.range(
              of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#,
              options: .regularExpression
            ) != nil
          else {
            throw GitRemoteOperationError.unsupportedSystemGit
          }
          drivers.insert(value)
        }
        index += 3
      }
    }
    var standardInput = Data()
    for path in paths {
      let pathData = Data(path.utf8)
      if standardInput.count + pathData.count + 1 > 32 * 1_024 {
        try inspectAttributes(standardInput: standardInput)
        standardInput.removeAll(keepingCapacity: true)
      }
      standardInput.append(pathData)
      standardInput.append(0)
    }
    if !standardInput.isEmpty {
      try inspectAttributes(standardInput: standardInput)
    }
    return drivers.sorted().flatMap { driver in
      [
        "-c", "filter.\(driver).clean=/usr/bin/cat",
        "-c", "filter.\(driver).smudge=/usr/bin/cat",
        "-c", "filter.\(driver).process=",
        "-c", "filter.\(driver).required=false",
      ]
    }
  }

  private func changedRemotePaths(
    repositoryURL: URL,
    localSHA: String,
    remoteSHA: String
  ) throws -> [GitRemotePath] {
    let result = try runDataAllowingFailure(
      ["diff", "--name-only", "-z", localSHA, remoteSHA, "--"],
      at: repositoryURL
    )
    guard result.status == 0 else { return [] }
    let paths = result.output.split(separator: 0, omittingEmptySubsequences: true)
      .map { GitRemotePath(rawBytes: Data($0)) }
    guard paths.count <= 100_000 else {
      throw GitRemoteOperationError.unsafeRepository(
        "The incoming repository changes are too large to verify safely."
      )
    }
    return paths
  }

  private func remoteCommitSummaries(
    repositoryURL: URL,
    localSHA: String,
    remoteSHA: String
  ) throws -> [RemoteCommitSummary] {
    let output = try run(
      ["log", "--reverse", "--format=%H%x1f%s%x1e", "\(localSHA)..\(remoteSHA)"],
      at: repositoryURL
    )
    return output.split(separator: "\u{1e}").compactMap { record in
      let fields = record.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "\u{1f}", maxSplits: 1).map(String.init)
      guard fields.count == 2 else { return nil }
      return RemoteCommitSummary(sha: fields[0], subject: fields[1])
    }
  }

  private func aheadBehind(
    localSHA: String,
    remoteSHA: String,
    at repositoryURL: URL
  ) throws -> (ahead: Int, behind: Int) {
    let values = try run(
      ["rev-list", "--left-right", "--count", "\(localSHA)...\(remoteSHA)"],
      at: repositoryURL
    ).split(whereSeparator: \Character.isWhitespace).compactMap { Int($0) }
    guard values.count == 2 else {
      throw GitRemoteOperationError.unsafeRepository("Repository history counts are unavailable.")
    }
    return (values[0], values[1])
  }

  private func isAncestor(
    _ ancestor: String,
    of descendant: String,
    at repositoryURL: URL
  ) throws -> Bool {
    let result = try runAllowingFailure(
      ["merge-base", "--is-ancestor", ancestor, descendant],
      at: repositoryURL
    )
    if result.status == 0 { return true }
    if result.status == 1 { return false }
    throw GitRemoteOperationError.unsafeRepository("Repository ancestry could not be verified.")
  }

  private func validateCanonicalGitHubURL(_ value: URL) throws {
    guard value.scheme?.lowercased() == "https",
      value.host?.lowercased() == "github.com",
      value.user == nil,
      value.password == nil,
      value.query == nil,
      value.fragment == nil,
      value.path.hasSuffix(".git")
    else {
      throw GitRemoteOperationError.unsafeRepository("The GitHub repository address is invalid.")
    }
  }

  private func rejectControlPath(_ path: GitRemotePath) throws {
    guard path.collisionKey?.split(separator: "/", maxSplits: 1).first != ".spedito" else {
      throw GitRemoteOperationError.unsafeRepository(
        "The repository contains a path reserved for Spedito."
      )
    }
  }

  private func repositoryObjectData(
    repositoryURL: URL,
    type: String,
    sha: String
  ) throws -> Data {
    let size = try run(["cat-file", "-s", sha], at: repositoryURL)
    guard let byteCount = Int(size), byteCount >= 0, byteCount <= 5 * 1_024 * 1_024 else {
      throw GitRemoteOperationError.unsafeRepository(
        "A repository object is too large to verify safely.")
    }
    let result = try runDataAllowingFailure(["cat-file", type, sha], at: repositoryURL)
    guard result.status == 0, result.output.count == byteCount else {
      throw GitRemoteOperationError.unsafeRepository("A repository object is unavailable.")
    }
    return result.output
  }

  private func rejectLFSPointers(
    in entries: [GitRemoteTreeEntry],
    repositoryURL: URL,
    inspectedBlobs: inout Set<String>
  ) throws {
    for entry in entries where inspectedBlobs.insert(entry.objectSHA).inserted {
      let data = try repositoryObjectData(
        repositoryURL: repositoryURL,
        type: "blob",
        sha: entry.objectSHA
      )
      if data.starts(with: Data("version https://git-lfs.github.com/spec/v1\n".utf8)) {
        throw GitRemoteOperationError.unsafeRepository(
          "Git LFS files cannot be accepted until their remote objects can be verified."
        )
      }
    }
  }

  private func rejectSensitiveData(_ data: Data, activeTokens: Set<String>) throws {
    let value = String(decoding: data, as: UTF8.self)
    let patterns = [
      #"(?i)\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"#,
      #"(?i)https://[^\s/@:]+(?::[^\s/@]*)?@"#,
      #"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"#,
    ]
    guard !activeTokens.filter({ !$0.isEmpty }).contains(where: value.contains),
      !patterns.contains(where: { value.range(of: $0, options: .regularExpression) != nil })
    else {
      throw GitRemoteOperationError.unsafeRepository(
        "Outgoing history contains credentials or private key material."
      )
    }
  }

  private func appendLengthPrefixed(_ value: Data, to target: inout Data) {
    var length = UInt64(value.count).bigEndian
    withUnsafeBytes(of: &length) { target.append(contentsOf: $0) }
    target.append(value)
  }
}
