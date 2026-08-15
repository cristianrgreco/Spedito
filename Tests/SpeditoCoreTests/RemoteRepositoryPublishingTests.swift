import Foundation
import Testing

@testable import SpeditoCore

@Suite("Remote repository publishing", .serialized)
struct RemoteRepositoryPublishingTests {
  @Test("Remote connection initialization and CAS transitions are durable")
  func connectionInitializationTransitions() async throws {
    let root = temporaryDirectory(named: "connection")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Local product")
    let accountID = UUID()
    var connection = RemoteRepositoryConnection(
      productID: product.id,
      kind: .localEmptyRepository,
      accountID: accountID,
      installationID: 41,
      status: .selectingRepository
    )
    connection = try await store.createRemoteRepositoryConnection(connection)
    connection.repositoryID = 52
    connection.owner = "owner"
    connection.name = "repository"
    connection.fullName = "owner/repository"
    connection.canonicalHTTPSURL = URL(string: "https://github.com/owner/repository.git")!
    connection.isPrivate = true
    connection.defaultBranch = "main"
    connection.permissions = publicationPermissions
    connection = try await store.saveRemoteRepositoryConnection(
      connection,
      expectedVersion: connection.version
    )
    connection = try await store.prepareLocalRemoteInitialization(
      id: connection.id,
      expectedVersion: connection.version,
      bootstrapSHA: sha("1"),
      bootstrapTree: sha("2")
    )
    #expect(connection.status == .initializingRemote)
    #expect(connection.initializationAttemptCount == 1)
    connection = try await store.recordLocalRemoteSeed(
      id: connection.id,
      expectedVersion: connection.version,
      expectedAttempt: 1,
      seededSHA: sha("1")
    )
    connection = try await store.finishLocalRemoteInitialization(
      id: connection.id,
      expectedVersion: connection.version,
      originVerified: true
    )
    #expect(connection.status == .connected)
    #expect(connection.originVerified == true)
    let fetched = try await store.fetchRemoteRepositoryConnection(productID: product.id)
    #expect(fetched?.id == connection.id)
    #expect(fetched?.version == connection.version)
    #expect(fetched?.status == .connected)
    #expect(fetched?.seededSHA == sha("1"))
    #expect(fetched?.originVerified == true)
    await store.close()
  }

  @Test("Remote repository persistence snapshot reads one coherent product aggregate")
  func remoteRepositoryPersistenceSnapshot() async throws {
    let root = temporaryDirectory(named: "persistence-snapshot")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Snapshot product")
    let accountID = UUID()
    let connection = try await store.createRemoteRepositoryConnection(
      RemoteRepositoryConnection(
        productID: product.id,
        kind: .importedSource,
        accountID: accountID,
        installationID: 42,
        repositoryID: 71,
        owner: "owner",
        name: "snapshot",
        fullName: "owner/snapshot",
        canonicalHTTPSURL: URL(string: "https://github.com/owner/snapshot.git")!,
        isPrivate: false,
        defaultBranch: "main",
        permissions: publicationPermissions,
        status: .connected
      )
    )
    var olderSync = try await store.createRemoteSafeSync(
      RemoteSafeSync(
        productID: product.id,
        connectionID: connection.id,
        connectionVersion: connection.version,
        kind: .fastForward,
        observationRef: "refs/spedito/observations/older",
        localSHA: sha("1"),
        localTree: sha("2"),
        remoteSHA: sha("3"),
        remoteTree: sha("4"),
        mergeBaseSHA: sha("1"),
        candidateSHA: sha("3"),
        candidateTree: sha("4"),
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
      )
    )
    olderSync = try await store.rejectRemoteSafeSync(
      id: olderSync.id,
      expectedVersion: olderSync.version,
      expectedStatus: olderSync.status,
      candidateSHA: olderSync.candidateSHA
    )
    let latestSyncDate = olderSync.updatedAt.addingTimeInterval(1)
    let latestSync = try await store.createRemoteSafeSync(
      RemoteSafeSync(
        productID: product.id,
        connectionID: connection.id,
        connectionVersion: connection.version,
        kind: .fastForward,
        observationRef: "refs/spedito/observations/latest",
        localSHA: sha("5"),
        localTree: sha("6"),
        remoteSHA: sha("7"),
        remoteTree: sha("8"),
        mergeBaseSHA: sha("5"),
        candidateSHA: sha("7"),
        candidateTree: sha("8"),
        createdAt: latestSyncDate,
        updatedAt: latestSyncDate
      )
    )
    let publication = try await store.createRemotePublication(
      RemotePublication(
        productID: product.id,
        connectionID: connection.id,
        purpose: .existingProductHistory,
        accountID: accountID,
        repositoryID: 71,
        owner: "owner",
        name: "snapshot",
        fullName: "owner/snapshot",
        canonicalHTTPSURL: URL(string: "https://github.com/owner/snapshot.git")!,
        isPrivate: false,
        permissions: publicationPermissions,
        capturedLocalSHA: sha("c"),
        capturedLocalTree: sha("d"),
        remoteBaseSHA: sha("e"),
        remoteBaseTree: sha("f"),
        targetBranch: "main",
        publicationBranch: "spedito/snapshot",
        manifestDigest: String(repeating: "1", count: 64),
        manifestObjectCount: 1,
        manifestCommitCount: 1,
        manifestPathCount: 1,
        commits: [RemoteCommitSummary(sha: sha("c"), subject: "Snapshot")],
        paths: ["README.md"],
        title: "Snapshot",
        body: "Coherent state"
      )
    )

    let snapshot = try await store.fetchRemoteRepositoryPersistenceSnapshot(
      productID: product.id
    )

    #expect(snapshot.connection?.id == connection.id)
    #expect(snapshot.latestSafeSync?.id == latestSync.id)
    #expect(snapshot.latestSafeSync?.id != olderSync.id)
    #expect(snapshot.publications.map(\.id) == [publication.id])
    #expect(snapshot.latestSafeSync?.connectionID == snapshot.connection?.id)
    #expect(snapshot.publications.allSatisfy { $0.connectionID == snapshot.connection?.id })

    _ = try await store.archiveProduct(id: product.id)
    let archivedSnapshot = try await store.fetchRemoteRepositoryPersistenceSnapshot(
      productID: product.id
    )
    #expect(archivedSnapshot == snapshot)
    await store.close()
  }

  @Test("Safe synchronization and publication reject stale transitions")
  func persistenceCAS() async throws {
    let root = temporaryDirectory(named: "cas")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Imported product")
    let accountID = UUID()
    let connection = try await store.createRemoteRepositoryConnection(
      RemoteRepositoryConnection(
        productID: product.id,
        kind: .importedSource,
        accountID: accountID,
        installationID: 7,
        repositoryID: 9,
        owner: "owner",
        name: "repository",
        fullName: "owner/repository",
        canonicalHTTPSURL: URL(string: "https://github.com/owner/repository.git")!,
        isPrivate: false,
        defaultBranch: "main",
        permissions: publicationPermissions,
        status: .connected,
        latestLocalSHA: sha("1"),
        latestLocalTree: sha("2"),
        latestRemoteSHA: sha("3"),
        latestRemoteTree: sha("4"),
        latestRelationship: .remoteAhead,
        latestAheadCount: 0,
        latestBehindCount: 1
      )
    )
    let sync = try await store.createRemoteSafeSync(
      RemoteSafeSync(
        productID: product.id,
        connectionID: connection.id,
        connectionVersion: connection.version,
        kind: .fastForward,
        observationRef: "refs/spedito/observations/\(UUID().uuidString.lowercased())",
        localSHA: sha("1"),
        localTree: sha("2"),
        remoteSHA: sha("3"),
        remoteTree: sha("4"),
        mergeBaseSHA: sha("1"),
        candidateSHA: sha("3"),
        candidateTree: sha("4")
      )
    )
    let accepting = try await store.prepareRemoteSafeSyncAcceptance(
      id: sync.id,
      expectedVersion: sync.version,
      expectedStatus: .awaitingConfirmation,
      expectedLocalSHA: sha("1")
    )
    await #expect(throws: PersistenceError.self) {
      _ = try await store.finishRemoteSafeSyncAcceptance(
        id: sync.id,
        expectedVersion: sync.version,
        expectedStatus: .accepting
      )
    }
    let accepted = try await store.finishRemoteSafeSyncAcceptance(
      id: accepting.id,
      expectedVersion: accepting.version,
      expectedStatus: .accepting
    )
    #expect(accepted.status == .accepted)
    let synchronizedConnection = try #require(
      try await store.fetchRemoteRepositoryConnection(productID: product.id)
    )
    #expect(synchronizedConnection.version == connection.version + 1)
    #expect(synchronizedConnection.latestLocalSHA == sha("3"))
    #expect(synchronizedConnection.latestLocalTree == sha("4"))
    #expect(synchronizedConnection.latestRelationship == .aligned)
    #expect(synchronizedConnection.latestAheadCount == 0)
    #expect(synchronizedConnection.latestBehindCount == 0)

    let publication = try await store.createRemotePublication(
      RemotePublication(
        productID: product.id,
        connectionID: connection.id,
        purpose: .existingProductHistory,
        accountID: accountID,
        repositoryID: 9,
        owner: "owner",
        name: "repository",
        fullName: "owner/repository",
        canonicalHTTPSURL: URL(string: "https://github.com/owner/repository.git")!,
        isPrivate: false,
        permissions: publicationPermissions,
        capturedLocalSHA: sha("5"),
        capturedLocalTree: sha("6"),
        remoteBaseSHA: sha("3"),
        remoteBaseTree: sha("4"),
        targetBranch: "main",
        publicationBranch: "spedito/imported-12345678-555555555555",
        manifestDigest: String(repeating: "a", count: 64),
        manifestObjectCount: 3,
        manifestCommitCount: 1,
        manifestPathCount: 1,
        commits: [RemoteCommitSummary(sha: sha("5"), subject: "Deliver change")],
        paths: ["README.md"],
        title: "Deliver change",
        body: "Spedito created this pull request but did not merge it."
      )
    )
    let checking = try await store.prepareRemotePublicationCheck(
      id: publication.id,
      expectedVersion: publication.version,
      expectedStatus: .awaitingConfirmation,
      title: publication.title,
      body: publication.body,
      textRevision: 2
    )
    let pushing = try await store.prepareRemoteBranchPush(
      id: checking.id,
      expectedVersion: checking.version,
      expectedStatus: .checking,
      expectedLocalSHA: sha("5"),
      expectedManifestDigest: publication.manifestDigest,
      expectedRemoteBaseSHA: sha("3")
    )
    let published = try await store.recordPublishedBranch(
      id: pushing.id,
      expectedVersion: pushing.version,
      expectedAttempt: 1,
      pushedSHA: sha("5")
    )
    #expect(published.status == .branchPublished)
    let recoverable = try await store.fetchRecoverableRemoteOperations(productID: product.id)
    #expect(recoverable.publications.map(\.id) == [publication.id])
    await store.close()
  }

  @Test("Local bootstrap seeds once and later work uses an immutable review branch")
  func localBootstrapAndReviewBranch() async throws {
    let root = temporaryDirectory(named: "local-bootstrap")
    let repository = root.appendingPathComponent("workspace", isDirectory: true)
    let bareRepository = root.appendingPathComponent("remote.git", isDirectory: true)
    let wrapper = root.appendingPathComponent("git-wrapper")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    let controlDirectory = repository.appendingPathComponent(".spedito", isDirectory: true)
    try FileManager.default.createDirectory(
      at: controlDirectory,
      withIntermediateDirectories: true
    )
    try Data("local control state".utf8).write(
      to: controlDirectory.appendingPathComponent("product.sqlite")
    )
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["init", "--bare", "--initial-branch=main", bareRepository.path],
      at: root
    )
    let canonicalURL = URL(string: "https://github.com/example/empty.git")!
    let script = """
      #!/bin/zsh
      remote=\(shellSingleQuoted(bareRepository.path))
      github=\(shellSingleQuoted(canonicalURL.absoluteString))
      network=false
      for value in "$@"; do
        if [[ "$value" == "fetch" || "$value" == "push" || "$value" == "ls-remote" ]]; then
          network=true
        fi
      done
      typeset -a rewritten
      for value in "$@"; do
        if [[ "$network" == true && "$value" == "$github" ]]; then
          value="$remote"
        fi
        rewritten+=("$value")
      done
      exec /usr/bin/git "${rewritten[@]}"
      """
    try Data(script.utf8).write(to: wrapper)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: wrapper.path
    )
    let manager = GitWorkspaceManager(executableURL: wrapper)
    let bootstrapSHA = try await manager.ensureRepository(at: repository)
    let bootstrap = try await manager.localBootstrapRoot(repositoryURL: repository)
    #expect(bootstrap.sha == bootstrapSHA)
    #expect(
      try await manager.repositoryTreeEntries(at: repository, sha: bootstrapSHA).entries.isEmpty
    )

    let database = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await database.createProduct(name: "Blank Product")
    #expect(try await database.fetchProductRepository(productID: product.id) == nil)

    let credential = GitCredentialSessionConfiguration(
      socketPath: root.appendingPathComponent("credential.sock").path
    )
    #expect(
      try await manager.remoteHeadSHAs(
        repositoryURL: repository,
        canonicalHTTPSURL: canonicalURL,
        credentialConfiguration: credential
      ).isEmpty
    )
    try await manager.initializeEmptyRemote(
      repositoryURL: repository,
      canonicalHTTPSURL: canonicalURL,
      defaultBranch: "main",
      bootstrapSHA: bootstrapSHA,
      credentialConfiguration: credential
    )
    let seededSHA = try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["--git-dir", bareRepository.path, "rev-parse", "refs/heads/main"],
      at: root
    )
    #expect(seededSHA == bootstrapSHA)
    let originManager = GitWorkspaceManager()
    try await originManager.verifyOrAddOrigin(
      repositoryURL: repository,
      canonicalHTTPSURL: canonicalURL
    )
    #expect(try await manager.currentSHA(at: repository) == bootstrapSHA)

    try Data("Delivered\n".utf8).write(to: repository.appendingPathComponent("README.md"))
    let localSHA = try await manager.checkpointTrunk(
      at: repository,
      message: "Deliver local change"
    )
    let manifest = try await manager.outboundManifest(
      repositoryURL: repository,
      remoteBaseSHA: bootstrapSHA,
      localSHA: localSHA
    )
    #expect(manifest.commitCount == 1)
    #expect(manifest.paths.map(\.displayPath) == ["README.md"])
    let branch = GitWorkspaceManager.publicationBranchName(
      productName: product.name,
      productID: product.id,
      localSHA: localSHA
    )
    try await manager.createRemoteReviewBranch(
      repositoryURL: repository,
      canonicalHTTPSURL: canonicalURL,
      fullRef: "refs/heads/\(branch)",
      localSHA: localSHA,
      credentialConfiguration: credential
    )
    let reviewSHA = try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["--git-dir", bareRepository.path, "rev-parse", "refs/heads/\(branch)"],
      at: root
    )
    #expect(reviewSHA == localSHA)
    try await manager.deleteRemoteReviewBranch(
      repositoryURL: repository,
      canonicalHTTPSURL: canonicalURL,
      fullRef: "refs/heads/\(branch)",
      expectedSHA: localSHA,
      credentialConfiguration: credential
    )
    #expect(
      try await manager.remoteHeadSHAs(
        repositoryURL: repository,
        canonicalHTTPSURL: canonicalURL,
        credentialConfiguration: credential
      )["refs/heads/\(branch)"] == nil
    )
    try await manager.createRemoteReviewBranch(
      repositoryURL: repository,
      canonicalHTTPSURL: canonicalURL,
      fullRef: "refs/heads/\(branch)",
      localSHA: localSHA,
      credentialConfiguration: credential
    )
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: [
        "--git-dir", bareRepository.path,
        "update-ref", "refs/heads/\(branch)", bootstrapSHA, localSHA,
      ],
      at: root
    )
    await #expect(throws: GitRemoteOperationError.remoteRefConflict) {
      try await manager.deleteRemoteReviewBranch(
        repositoryURL: repository,
        canonicalHTTPSURL: canonicalURL,
        fullRef: "refs/heads/\(branch)",
        expectedSHA: localSHA,
        credentialConfiguration: credential
      )
    }
    #expect(
      try runProcess(
        executable: URL(fileURLWithPath: "/usr/bin/git"),
        arguments: ["--git-dir", bareRepository.path, "rev-parse", "refs/heads/\(branch)"],
        at: root
      ) == bootstrapSHA
    )
    let unchangedDefault = try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["--git-dir", bareRepository.path, "rev-parse", "refs/heads/main"],
      at: root
    )
    #expect(unchangedDefault == bootstrapSHA)
    await database.close()
  }

  @Test("Incoming fast-forward and published-history alignment preserve safe local files")
  func safeSynchronizationPaths() async throws {
    let root = temporaryDirectory(named: "safe-sync")
    let repository = root.appendingPathComponent("workspace", isDirectory: true)
    let bareRepository = root.appendingPathComponent("remote.git", isDirectory: true)
    let remoteClone = root.appendingPathComponent("remote-clone", isDirectory: true)
    let wrapper = root.appendingPathComponent("git-wrapper")
    let sentinel = root.appendingPathComponent("filter-ran")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["init", "--bare", "--initial-branch=main", bareRepository.path],
      at: root
    )
    let canonicalURL = URL(string: "https://github.com/example/sync.git")!
    try writeGitHubWrapper(
      at: wrapper,
      canonicalURL: canonicalURL,
      bareRepository: bareRepository
    )
    let manager = GitWorkspaceManager(executableURL: wrapper)
    let bootstrapSHA = try await manager.ensureRepository(at: repository)
    let credential = GitCredentialSessionConfiguration(
      socketPath: root.appendingPathComponent("credential.sock").path
    )
    try await manager.initializeEmptyRemote(
      repositoryURL: repository,
      canonicalHTTPSURL: canonicalURL,
      defaultBranch: "main",
      bootstrapSHA: bootstrapSHA,
      credentialConfiguration: credential
    )

    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["clone", bareRepository.path, remoteClone.path],
      at: root
    )
    try Data("*.txt filter=evil\n".utf8).write(
      to: remoteClone.appendingPathComponent(".gitattributes")
    )
    try Data("Incoming\n".utf8).write(
      to: remoteClone.appendingPathComponent("incoming.txt")
    )
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: [
        "-C", remoteClone.path,
        "-c", "user.name=Remote",
        "-c", "user.email=remote@example.com",
        "add", "-A",
      ],
      at: root
    )
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: [
        "-C", remoteClone.path,
        "-c", "user.name=Remote",
        "-c", "user.email=remote@example.com",
        "commit", "-m", "Incoming change",
      ],
      at: root
    )
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["-C", remoteClone.path, "push", "origin", "main"],
      at: root
    )
    let incomingSHA = try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["-C", remoteClone.path, "rev-parse", "HEAD"],
      at: root
    )
    let sentinelCommand = "printf unsafe > \(shellSingleQuoted(sentinel.path))"
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["-C", repository.path, "config", "filter.evil.smudge", sentinelCommand],
      at: root
    )

    let observation = try await manager.fetchRemoteObservation(
      repositoryURL: repository,
      canonicalHTTPSURL: canonicalURL,
      targetBranch: "main",
      observationID: UUID(),
      credentialConfiguration: credential
    )
    #expect(observation.relationship == .remoteAhead)
    #expect(observation.remoteSHA == incomingSHA)
    try await manager.promoteRemoteSafeSync(
      repositoryURL: repository,
      expectedTrunkSHA: bootstrapSHA,
      candidateSHA: observation.remoteSHA,
      expectedTree: observation.remoteTree
    )
    #expect(
      try String(contentsOf: repository.appendingPathComponent("incoming.txt"), encoding: .utf8)
        == "Incoming\n"
    )
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))

    try Data("Newer local work\n".utf8).write(
      to: repository.appendingPathComponent("newer.txt")
    )
    let newerLocalSHA = try await manager.checkpointTrunk(
      at: repository,
      message: "Newer local work"
    )
    let publishedTree = try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["-C", repository.path, "rev-parse", "\(incomingSHA)^{tree}"],
      at: root
    )
    let rewrittenRemoteSHA = try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: [
        "--git-dir", bareRepository.path,
        "-c", "user.name=GitHub",
        "-c", "user.email=github@example.com",
        "commit-tree", publishedTree,
        "-p", bootstrapSHA,
        "-m", "Squashed Spedito pull request",
      ],
      at: root
    )
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: [
        "--git-dir", bareRepository.path,
        "update-ref", "refs/heads/main", rewrittenRemoteSHA, incomingSHA,
      ],
      at: root
    )
    let alignmentObservation = try await manager.fetchRemoteObservation(
      repositoryURL: repository,
      canonicalHTTPSURL: canonicalURL,
      targetBranch: "main",
      observationID: UUID(),
      credentialConfiguration: credential
    )
    #expect(alignmentObservation.relationship == .diverged)
    let alignment = try await manager.createHistoryAlignmentCandidate(
      repositoryURL: repository,
      localSHA: newerLocalSHA,
      remoteSHA: rewrittenRemoteSHA,
      publishedSHA: incomingSHA,
      expectedRemoteTree: publishedTree
    )
    let incomingBefore = try Data(contentsOf: repository.appendingPathComponent("incoming.txt"))
    let newerBefore = try Data(contentsOf: repository.appendingPathComponent("newer.txt"))
    try await manager.promoteRemoteSafeSync(
      repositoryURL: repository,
      expectedTrunkSHA: newerLocalSHA,
      candidateSHA: alignment.sha,
      expectedTree: alignment.tree
    )
    #expect(
      try Data(contentsOf: repository.appendingPathComponent("incoming.txt")) == incomingBefore)
    #expect(try Data(contentsOf: repository.appendingPathComponent("newer.txt")) == newerBefore)
    #expect(try await manager.currentSHA(at: repository) == alignment.sha)
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))

    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["-C", remoteClone.path, "fetch", "origin"],
      at: root
    )
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["-C", remoteClone.path, "reset", "--hard", "origin/main"],
      at: root
    )
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: [
        "-C", remoteClone.path,
        "update-index", "--add", "--cacheinfo", "160000,\(bootstrapSHA),vendor/tool",
      ],
      at: root
    )
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: [
        "-C", remoteClone.path,
        "-c", "user.name=Remote",
        "-c", "user.email=remote@example.com",
        "commit", "-m", "Add unsupported submodule",
      ],
      at: root
    )
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["-C", remoteClone.path, "push", "origin", "main"],
      at: root
    )
    let rejectedObservationID = UUID()
    await #expect(throws: GitRemoteOperationError.self) {
      try await manager.fetchRemoteObservation(
        repositoryURL: repository,
        canonicalHTTPSURL: canonicalURL,
        targetBranch: "main",
        observationID: rejectedObservationID,
        credentialConfiguration: credential
      )
    }
    let remainingObservationRefs = try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: [
        "-C", repository.path,
        "for-each-ref", "--format=%(refname)", "refs/spedito/observations",
      ],
      at: root
    )
    #expect(
      !remainingObservationRefs.contains(
        "refs/spedito/observations/\(rejectedObservationID.uuidString.lowercased())"
      )
    )

    let submoduleSHA = try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["--git-dir", bareRepository.path, "rev-parse", "refs/heads/main"],
      at: root
    )
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: [
        "--git-dir", bareRepository.path,
        "update-ref", "refs/heads/main", rewrittenRemoteSHA, submoduleSHA,
      ],
      at: root
    )
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["-C", remoteClone.path, "fetch", "origin"],
      at: root
    )
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["-C", remoteClone.path, "reset", "--hard", "origin/main"],
      at: root
    )
    let lfsPointer = """
      version https://git-lfs.github.com/spec/v1
      oid sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
      size 123

      """
    try Data(lfsPointer.utf8).write(to: remoteClone.appendingPathComponent("large.bin"))
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["-C", remoteClone.path, "add", "large.bin"],
      at: root
    )
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: [
        "-C", remoteClone.path,
        "-c", "user.name=Remote",
        "-c", "user.email=remote@example.com",
        "commit", "-m", "Add unavailable LFS object",
      ],
      at: root
    )
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["-C", remoteClone.path, "push", "origin", "main"],
      at: root
    )
    let rejectedLFSObservationID = UUID()
    await #expect(throws: GitRemoteOperationError.self) {
      try await manager.fetchRemoteObservation(
        repositoryURL: repository,
        canonicalHTTPSURL: canonicalURL,
        targetBranch: "main",
        observationID: rejectedLFSObservationID,
        credentialConfiguration: credential
      )
    }
    let refsAfterLFSRejection = try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: [
        "-C", repository.path,
        "for-each-ref", "--format=%(refname)", "refs/spedito/observations",
      ],
      at: root
    )
    #expect(
      !refsAfterLFSRejection.contains(
        "refs/spedito/observations/\(rejectedLFSObservationID.uuidString.lowercased())"
      )
    )
  }

  @Test("Pull request text rejects credentials and private control-plane references")
  func publicationTextSafety() throws {
    let validator = RemotePublicationTextValidator()
    let activeToken = "ghu_active_token_abcdefghijklmnopqrstuvwxyz"
    let context = RemotePublicationTextValidationContext(
      activeTokens: [activeToken],
      protectedPaths: ["/Users/owner/Spedito/Product Workspaces/private"],
      codexIdentifiers: ["thread_12345678"],
      sqliteRecordIdentifiers: ["11111111-1111-1111-1111-111111111111"]
    )
    let sensitiveValues = [
      activeToken,
      "ghp_abcdefghijklmnopqrstuvwxyz123456",
      "https://secret:password@github.com/example/product.git",
      "/Users/owner/Spedito/Product Workspaces/private",
      "thread_12345678",
      "product_id=11111111-1111-1111-1111-111111111111",
      "private/.spedito/control",
    ]
    for value in sensitiveValues {
      do {
        try validator.validate(title: "Publish changes", body: value, context: context)
        Issue.record("Expected sensitive pull request text to be rejected")
      } catch let error as RemotePublicationTextValidationError {
        #expect(error == .sensitiveContent)
      }
    }
    #expect(throws: RemotePublicationTextValidationError.emptyTitle) {
      try validator.validate(title: "  ", body: "Safe", context: context)
    }
    #expect(throws: RemotePublicationTextValidationError.titleTooLong) {
      try validator.validate(
        title: String(repeating: "a", count: 257),
        body: "Safe",
        context: context
      )
    }
    #expect(throws: RemotePublicationTextValidationError.bodyTooLong) {
      try validator.validate(
        title: "Publish changes",
        body: String(repeating: "a", count: 65_001),
        context: context
      )
    }
    let body = validator.defaultBody(
      commits: [
        RemotePublicationCommitText(
          sha: sha("1"),
          subject: "Add owner-facing repository status\nprivate detail"
        )
      ],
      localSHA: sha("2"),
      remoteSHA: sha("3")
    )
    try validator.validate(title: "Publish changes", body: body, context: context)
    #expect(body.contains("Spedito created this pull request but did not merge it."))
    #expect(!body.contains("private detail"))
  }

  @Test("GitHub API keeps bearer tokens out of URLs and rejects redirected responses")
  func apiRequestSafety() async throws {
    let token = "ghu_abcdefghijklmnopqrstuvwxyz123456"
    let transport = RedirectingGitHubTransport()
    let api = GitHubAPIClient(transport: transport)
    do {
      _ = try await api.user(accessToken: token)
      Issue.record("Expected a redirected response to be rejected")
    } catch let error as GitHubAPIError {
      #expect(error == .invalidResponse)
    }
    let request = try #require(await transport.request)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    #expect(!request.url!.absoluteString.contains(token))
    #expect(
      !(request.httpBody.map { String(decoding: $0, as: UTF8.self).contains(token) } ?? false))
  }

  @Test("Device Flow reports an invalid GitHub App registration precisely")
  func deviceFlowRegistrationFailure() async throws {
    let api = GitHubAPIClient(transport: MissingDeviceFlowTransport())
    do {
      _ = try await api.authorize(clientID: "invalid-client-id") { _ in }
      Issue.record("Expected Device Flow authorization to fail")
    } catch let error as GitHubAPIError {
      #expect(
        error.localizedDescription
          == "GitHub could not find this App registration. Verify the build’s GitHub client ID, enable Device Flow for that GitHub App, then rebuild Spedito."
      )
    }
  }

  @Test("Token refresh reports an invalid GitHub App registration precisely")
  func tokenRefreshRegistrationFailure() async throws {
    let api = GitHubAPIClient(transport: MissingDeviceFlowTransport())
    do {
      _ = try await api.refresh(
        clientID: "invalid-client-id",
        refreshToken: "ghr_expired-registration"
      )
      Issue.record("Expected token refresh to fail")
    } catch let error as GitHubAPIError {
      #expect(
        error.localizedDescription
          == "GitHub could not find this App registration. Verify the build’s GitHub client ID, enable Device Flow for that GitHub App, then rebuild Spedito."
      )
    }
  }

  @Test("GitHub pull request polling reuses ETag responses")
  func pullRequestConditionalRequests() async throws {
    let transport = ConditionalGitHubTransport()
    let api = GitHubAPIClient(transport: transport)
    let first = try await api.pullRequest(
      owner: "example",
      name: "product",
      number: 1,
      accessToken: "ghu_test",
      useConditionalRequest: true
    )
    let second = try await api.pullRequest(
      owner: "example",
      name: "product",
      number: 1,
      accessToken: "ghu_test",
      useConditionalRequest: true
    )
    _ = try await api.pullRequest(
      owner: "example",
      name: "product",
      number: 1,
      accessToken: "ghu_other_account",
      useConditionalRequest: true
    )
    #expect(first == second)
    let requests = await transport.requests
    #expect(requests.count == 3)
    #expect(requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
    #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == #""pull-1""#)
    #expect(requests[2].value(forHTTPHeaderField: "If-None-Match") == nil)
  }

  @Test("GitHub comment reviews accept a null update timestamp")
  func commentReviewNullableUpdateTimestamp() async throws {
    let api = GitHubAPIClient(transport: CommentReviewGitHubTransport())
    let feedback = try await api.pullRequestFeedback(
      owner: "example",
      name: "product",
      number: 3,
      accessToken: "ghu_test"
    )
    let review = try #require(feedback.first { $0.id == "review:71" })
    let inlineComment = try #require(feedback.first { $0.id == "comment:72" })
    #expect(review.decision == .commented)
    #expect(review.createdAt == inlineComment.createdAt)
    #expect(inlineComment.body == "Why is this all inline?")
  }
  private var publicationPermissions: RemoteRepositoryPermissions {
    RemoteRepositoryPermissions(
      metadataRead: true,
      contentsWrite: true,
      pullRequestsWrite: true,
      workflowsWrite: true
    )
  }

  @discardableResult
  private func runProcess(
    executable: URL,
    arguments: [String],
    at directory: URL
  ) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw GitWorkspaceError.commandFailed(
        arguments: arguments,
        output: String(decoding: data, as: UTF8.self)
      )
    }
    return String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func shellSingleQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func writeGitHubWrapper(
    at wrapper: URL,
    canonicalURL: URL,
    bareRepository: URL
  ) throws {
    let script = """
      #!/bin/zsh
      remote=\(shellSingleQuoted(bareRepository.path))
      github=\(shellSingleQuoted(canonicalURL.absoluteString))
      network=false
      for value in "$@"; do
        if [[ "$value" == "fetch" || "$value" == "push" || "$value" == "ls-remote" ]]; then
          network=true
        fi
      done
      typeset -a rewritten
      for value in "$@"; do
        if [[ "$network" == true && "$value" == "$github" ]]; then
          value="$remote"
        fi
        rewritten+=("$value")
      done
      exec /usr/bin/git "${rewritten[@]}"
      """
    try Data(script.utf8).write(to: wrapper)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: wrapper.path
    )
  }

  private func sha(_ digit: Character) -> String {
    String(repeating: String(digit), count: 40)
  }

  private func temporaryDirectory(named name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "Spedito-Remote-\(name)-\(UUID().uuidString)",
      isDirectory: true
    )
  }
}

private actor RedirectingGitHubTransport: GitHubHTTPTransport {
  private(set) var request: URLRequest?

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    self.request = request
    let redirectedURL = URL(string: "https://redirected.example/user")!
    let response = HTTPURLResponse(
      url: redirectedURL,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: [:]
    )!
    return (Data(#"{"id":5,"login":"owner"}"#.utf8), response)
  }
}

private actor MissingDeviceFlowTransport: GitHubHTTPTransport {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    (
      Data(#"{"error":"Not Found"}"#.utf8),
      HTTPURLResponse(
        url: request.url!,
        statusCode: 404,
        httpVersion: "HTTP/1.1",
        headerFields: [:]
      )!
    )
  }
}

private actor ConditionalGitHubTransport: GitHubHTTPTransport {
  private(set) var requests: [URLRequest] = []

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    if request.value(forHTTPHeaderField: "If-None-Match") == #""pull-1""# {
      return (
        Data(),
        HTTPURLResponse(
          url: request.url!,
          statusCode: 304,
          httpVersion: "HTTP/1.1",
          headerFields: ["ETag": #""pull-1""#]
        )!
      )
    }
    let json =
      #"{"number":1,"node_id":"PR_1","html_url":"https://github.com/example/product/pull/1","state":"open","draft":true,"head":{"ref":"spedito/1","sha":"1111111111111111111111111111111111111111"},"base":{"ref":"main","sha":"2222222222222222222222222222222222222222"},"merge_commit_sha":null,"merged_at":null,"updated_at":"2026-08-05T12:00:00Z"}"#
    return (
      Data(json.utf8),
      HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["ETag": #""pull-1""#]
      )!
    )
  }
}

private actor CommentReviewGitHubTransport: GitHubHTTPTransport {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let json: String
    switch request.url?.path {
    case "/repos/example/product/pulls/3/reviews":
      json = #"""
        [{
          "id": 71,
          "user": {
            "login": "reviewer",
            "avatar_url": "https://avatars.githubusercontent.com/u/71"
          },
          "body": "",
          "state": "COMMENTED",
          "html_url": "https://github.com/example/product/pull/3#pullrequestreview-71",
          "submitted_at": "2026-08-15T09:56:48Z",
          "updated_at": null
        }]
        """#
    case "/repos/example/product/pulls/3/comments":
      json = #"""
        [{
          "id": 72,
          "user": {
            "login": "reviewer",
            "avatar_url": "https://avatars.githubusercontent.com/u/71"
          },
          "body": "Why is this all inline?",
          "html_url": "https://github.com/example/product/pull/3#discussion_r72",
          "created_at": "2026-08-15T09:56:48Z",
          "path": "src/App.css",
          "commit_id": "1111111111111111111111111111111111111111",
          "original_commit_id": "1111111111111111111111111111111111111111",
          "diff_hunk": "@@ -1 +1 @@\n-old\n+new",
          "start_line": null,
          "line": 2,
          "start_side": null,
          "side": "RIGHT",
          "original_start_line": null,
          "original_line": 2
        }]
        """#
    default:
      throw GitHubAPIError.invalidResponse
    }
    return (
      Data(json.utf8),
      HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: [:]
      )!
    )
  }
}
