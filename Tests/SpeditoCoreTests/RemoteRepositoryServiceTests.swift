import Foundation
import Testing

@testable import SpeditoCore

@Suite("GitHub remote repository service", .serialized)
struct RemoteRepositoryServiceTests {
  @Test("Local Product setup publishes one immutable PR and accepts merged history")
  func localProductLifecycle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Spedito-Service-\(UUID().uuidString)",
      isDirectory: true
    )
    let repository = root.appendingPathComponent("workspace", isDirectory: true)
    let bareRepository = root.appendingPathComponent("remote.git", isDirectory: true)
    let wrapper = root.appendingPathComponent("git-wrapper")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["init", "--bare", "--initial-branch=main", bareRepository.path],
      at: root
    )
    let canonicalURL = URL(string: "https://github.com/example/service.git")!
    try writeWrapper(
      wrapper,
      canonicalURL: canonicalURL,
      bareRepository: bareRepository
    )
    let git = GitWorkspaceManager(executableURL: wrapper)
    let bootstrapSHA = try await git.ensureRepository(at: repository)
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Service Product")
    let transport = ServiceFakeGitHubTransport(
      repositoryID: 91,
      canonicalURL: canonicalURL,
      defaultBranch: "main",
      onMerge: { mergedSHA in
        try runProcess(
          executable: URL(fileURLWithPath: "/usr/bin/git"),
          arguments: [
            "--git-dir", bareRepository.path,
            "update-ref", "refs/heads/main", mergedSHA,
          ],
          at: root
        )
      }
    )
    await transport.makeNextUserRequestTimeout()
    await transport.setHead(bootstrapSHA)
    let api = GitHubAPIClient(
      transport: transport,
      sleep: { _ in }
    )
    let service = GitHubRemoteRepositoryService(
      configuration: GitHubConfiguration(clientID: "client-id", appSlug: "spedito-test"),
      api: api,
      credentialStore: ServiceMemoryCredentialStore(),
      credentialSession: GitCredentialSession(),
      git: git,
      storeProvider: { requestedID in requestedID == product.id ? store : nil },
      storesProvider: { [store] },
      workspaceProvider: { requestedID in
        guard requestedID == product.id else {
          throw GitHubRemoteRepositoryServiceError.stale
        }
        return repository
      }
    )
    let prompt = ServicePromptRecorder()
    var state = try await service.connect(productID: product.id) { value in
      await prompt.record(value)
    }
    #expect(await transport.userRequestCount == 2)
    #expect(await prompt.value?.userCode == "ABCD-EFGH")
    #expect(state.connection?.kind == .localEmptyRepository)
    #expect(state.connection?.status == .selectingRepository)
    #expect(state.repositories.map(\.id) == [91])
    let importCatalog = try await service.importRepositories()
    #expect(importCatalog.installations.map(\.id) == [1])
    #expect(importCatalog.choices.map(\.repository.fullName) == ["example/service"])
    let importRecorder = ServiceImportRecorder()
    await #expect(throws: ServiceImportProbe.self) {
      _ = try await service.importProduct(name: "Imported", repositoryID: 91) {
        source,
        credential in
        await importRecorder.record(source: source, credential: credential)
        throw ServiceImportProbe.recorded
      }
    }
    #expect(
      await importRecorder.sourceURL
        == URL(string: "https://github.com/example/service.git")
    )
    #expect(await importRecorder.configurationArguments.contains("credential.helper="))

    state = try await service.selectLocalRepository(productID: product.id, repositoryID: 91)
    guard case .empty(let bootstrap, let existingHistory) = state.selectedEligibility else {
      Issue.record("Expected the selected repository to be proven empty")
      return
    }
    #expect(existingHistory == nil)
    #expect(bootstrap.sha == bootstrapSHA)
    state = try await service.cancelConnection(productID: product.id)
    #expect(state.connection?.repositoryID == nil)
    await transport.setRepositoryContainsBranches(true)
    await #expect(
      throws: GitHubRemoteRepositoryServiceError.notEligible(
        "This repository already contains work. Choose an empty repository instead."
      )
    ) {
      _ = try await service.connectLocalProduct(
        productID: product.id,
        repositoryID: 91
      )
    }
    state = await service.state(productID: product.id)
    #expect(
      state.selectedEligibility
        == .ineligible("This repository already contains work. Choose an empty repository instead.")
    )
    await transport.setRepositoryContainsBranches(false)
    state = try await service.connectLocalProduct(
      productID: product.id,
      repositoryID: 91
    )
    #expect(state.connection?.status == .connected)
    #expect(state.observation?.relationship == .aligned)
    #expect(
      try runProcess(
        executable: URL(fileURLWithPath: "/usr/bin/git"),
        arguments: ["--git-dir", bareRepository.path, "rev-parse", "refs/heads/main"],
        at: root
      ) == bootstrapSHA
    )

    try Data("Published\n".utf8).write(to: repository.appendingPathComponent("README.md"))
    var localSHA = try await git.checkpointTrunk(at: repository, message: "Publish service change")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    var ticket = try await store.createWorkItem(
      productID: product.id,
      title: "Publish reviewed ticket",
      acceptanceCriteria: ["The exact reviewed revision is merged"]
    )
    ticket = try await store.transitionWorkItem(
      id: ticket.id,
      to: .refining,
      actor: "Business analyst",
      reason: "Refine"
    )
    ticket = try await store.transitionWorkItem(
      id: ticket.id,
      to: .ready,
      actor: "Product owner",
      reason: "Ready"
    )
    let draftSprint = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Publish one reviewed ticket",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: ticket.id,
          implementerProfileID: implementer.id
        )
      ]
    )
    let sprint = try await store.startSprint(id: draftSprint.sprint.id)
    let sprintItem = try #require(sprint.items.first)
    let implementationRun = try #require(
      try await store.fetchAgentRuns(productID: product.id).first
    )
    ticket = try await store.transitionWorkItem(
      id: ticket.id,
      to: .running,
      actor: implementer.name,
      reason: "Deliver"
    )
    ticket = try await store.transitionWorkItem(
      id: ticket.id,
      to: .integrating,
      actor: implementer.name,
      reason: "Review"
    )
    var candidate = try await store.createCandidateRevision(
      CandidateRevision(
        productID: product.id,
        sprintID: sprint.sprint.id,
        sprintItemID: sprintItem.id,
        workItemID: ticket.id,
        implementationRunID: implementationRun.id,
        version: 1,
        branchName: "ticket/\(ticket.key)",
        baseSHA: bootstrapSHA,
        headSHA: localSHA,
        integratedSHA: localSHA,
        worktreePath: repository.path,
        status: .reviewing,
        commitCount: 1,
        executionResultJSON: "{}"
      )
    )
    state = try await service.check(productID: product.id)
    #expect(state.observation?.relationship == .localAhead)
    await transport.setPullRequestHead(localSHA)
    state = try await service.prepareTicketPullRequest(
      productID: product.id,
      workItemID: ticket.id,
      candidateRevisionID: candidate.id
    )
    guard var publication = state.publication else {
      Issue.record("Expected a ticket pull request publication")
      return
    }
    #expect(publication.status == .open)
    #expect(publication.workItemID == ticket.id)
    #expect(publication.candidateRevisionID == candidate.id)
    #expect(publication.pullRequest?.isDraft == true)
    #expect(publication.pullRequest?.number == 1)
    #expect(await transport.pullRequestPostCount == 1)
    let previousCandidateSHA = localSHA
    try Data("Replacement\n".utf8).write(to: repository.appendingPathComponent("README.md"))
    localSHA = try await git.checkpointTrunk(
      at: repository,
      message: "Replace reviewed ticket candidate"
    )
    _ = try await store.updateCandidateRevision(
      id: candidate.id,
      status: .superseded
    )
    candidate = try await store.createCandidateRevision(
      CandidateRevision(
        productID: product.id,
        sprintID: sprint.sprint.id,
        sprintItemID: sprintItem.id,
        workItemID: ticket.id,
        implementationRunID: implementationRun.id,
        version: 2,
        branchName: "ticket/\(ticket.key)",
        baseSHA: previousCandidateSHA,
        headSHA: localSHA,
        integratedSHA: localSHA,
        worktreePath: repository.path,
        status: .reviewing,
        commitCount: 1,
        executionResultJSON: "{}"
      )
    )

    state = try await service.prepareTicketPullRequest(
      productID: product.id,
      workItemID: ticket.id,
      candidateRevisionID: candidate.id
    )
    publication = try #require(state.publication)
    #expect(publication.status == .open)
    #expect(publication.candidateRevisionID == candidate.id)
    #expect(publication.capturedLocalSHA == localSHA)
    #expect(publication.pullRequest?.headSHA == localSHA)
    #expect(await transport.pullRequestPostCount == 1)

    state = try await service.markTicketPullRequestReady(publicationID: publication.id)
    publication = try #require(state.publication)
    #expect(publication.status == .open)
    #expect(publication.pullRequest?.headSHA == localSHA)
    #expect(publication.pullRequest?.isDraft == false)
    await transport.setPullRequestHead(localSHA)
    await transport.setChangesRequested(true)
    let reviewSync = try await service.syncTicketPullRequest(publicationID: publication.id)
    #expect(reviewSync.changesRequested)
    let reviewComments = try await store.fetchComments(workItemID: ticket.id)
    #expect(reviewComments.map(\.authorName) == ["reviewer", "reviewer"])
    #expect(
      reviewComments.first?.body
        == "GitHub review — Changes requested\n\nPlease cover the failure state."
    )
    #expect(
      reviewComments.first?.externalURL
        == URL(string: "https://github.com/example/service/pull/1#pullrequestreview-71")
    )
    let inlineComment = try #require(
      reviewComments.first(where: { $0.githubReviewContext != nil })
    )
    #expect(inlineComment.body == "Handle this branch.")
    #expect(inlineComment.githubReviewContext?.path == "Sources/Service.swift")
    #expect(inlineComment.githubReviewContext?.lineDescription == "Lines 8-9 (new)")
    #expect(inlineComment.githubReviewContext?.commitSHA == localSHA)
    #expect(inlineComment.agentContextBody.contains("BEGIN GITHUB DIFF HUNK"))
    #if DEBUG
      await store.resetPreparedStatementCount()
    #endif
    _ = try await service.syncTicketPullRequest(publicationID: publication.id)
    #if DEBUG
      let boundedPollingQueryCount = await store.currentPreparedStatementCount()
      let unrelatedTicket = try await store.createWorkItem(
        productID: product.id,
        title: "Unrelated historical ticket"
      )
      for index in 0..<20 {
        _ = try await store.appendComment(
          workItemID: unrelatedTicket.id,
          authorKind: .owner,
          authorName: "Product owner",
          body: "Historical comment \(index)"
        )
      }
      await store.resetPreparedStatementCount()
      _ = try await service.syncTicketPullRequest(publicationID: publication.id)
      #expect(await store.currentPreparedStatementCount() == boundedPollingQueryCount)
    #endif
    #expect(try await store.fetchComments(workItemID: ticket.id).count == 2)
    let externalWorkspace = root.appendingPathComponent(
      "external-change",
      isDirectory: true
    )
    _ = try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["worktree", "add", "--detach", externalWorkspace.path, bootstrapSHA],
      at: repository
    )
    try Data("External\n".utf8).write(
      to: externalWorkspace.appendingPathComponent("EXTERNAL.md")
    )
    _ = try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["add", "EXTERNAL.md"],
      at: externalWorkspace
    )
    _ = try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: [
        "-c", "user.name=GitHub collaborator",
        "-c", "user.email=github@example.com",
        "commit", "--no-gpg-sign", "-m", "External change",
      ],
      at: externalWorkspace
    )
    let externalSHA = try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["rev-parse", "HEAD"],
      at: externalWorkspace
    )
    _ = try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: [
        "push", "--force", bareRepository.path,
        "\(externalSHA):refs/heads/main",
      ],
      at: externalWorkspace
    )
    await transport.setHead(externalSHA)
    let remotePreparation = try await service.prepareTicketIntegration(productID: product.id)
    let remoteBase = try #require(remotePreparation.base)
    let integration = try await git.integrateCandidate(
      repositoryURL: repository,
      integrationsRootURL: root.appendingPathComponent("integrations", isDirectory: true),
      candidateID: candidate.id,
      headSHA: localSHA
    )
    let remoteIntegration = try await git.integrateVerifiedRemote(
      repositoryURL: repository,
      integrationWorkspaceURL: integration.url,
      observationRef: remoteBase.observationRef,
      expectedRemoteSHA: remoteBase.remoteSHA,
      candidateHeadSHA: candidate.headSHA
    )
    localSHA = remoteIntegration.integratedSHA
    _ = try await store.updateCandidateRevision(
      id: candidate.id,
      status: .reviewing,
      integratedSHA: localSHA,
      integrationWorktreePath: remoteIntegration.url.path
    )
    await transport.setPullRequestHead(localSHA)
    await transport.setPullRequestBase(externalSHA)
    state = try await service.prepareTicketPullRequest(
      productID: product.id,
      workItemID: ticket.id,
      candidateRevisionID: candidate.id
    )
    publication = try #require(state.publication)
    #expect(publication.remoteBaseSHA == externalSHA)
    #expect(publication.capturedLocalSHA == localSHA)
    #expect(publication.pullRequest?.baseSHA == externalSHA)
    await transport.setChangesRequested(false)
    state = try await service.markTicketPullRequestReady(publicationID: publication.id)
    #expect(state.publication?.pullRequest?.isDraft == false)
    await transport.makeNextPullRequestFetchReportChangedBase()
    await #expect(
      throws: GitHubRemoteRepositoryServiceError.ticketIntegrationRequired
    ) {
      _ = try await service.mergeTicketPullRequest(publicationID: publication.id)
    }
    let publicationRef = "refs/heads/\(publication.publicationBranch)"
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: [
        "--git-dir", bareRepository.path,
        "update-ref", publicationRef, bootstrapSHA, localSHA,
      ],
      at: root
    )
    await #expect(throws: GitRemoteOperationError.remoteRefConflict) {
      _ = try await service.mergeTicketPullRequest(publicationID: publication.id)
    }
    let pendingCleanup = try #require(
      try await store.fetchRemotePublication(id: publication.id)
    )
    #expect(pendingCleanup.status == .merged)
    #expect(pendingCleanup.remoteBranchDeletedAt == nil)
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: [
        "--git-dir", bareRepository.path,
        "update-ref", publicationRef, localSHA, bootstrapSHA,
      ],
      at: root
    )
    await service.recover(productID: product.id)
    let afterLaunchRecovery = try #require(
      try await store.fetchRemotePublication(id: publication.id)
    )
    #expect(afterLaunchRecovery.remoteBranchDeletedAt == nil)
    #expect(
      try runProcess(
        executable: URL(fileURLWithPath: "/usr/bin/git"),
        arguments: ["--git-dir", bareRepository.path, "rev-parse", publicationRef],
        at: root
      ) == localSHA
    )
    await transport.delayMergedHeadVisibility(requestCount: 4)
    let merge = try await service.mergeTicketPullRequest(publicationID: publication.id)
    #expect(merge.state.publication?.status == .merged)
    #expect(merge.publication.remoteBranchDeletedAt != nil)
    #expect(merge.mergedSHA == localSHA)
    #expect(await transport.pullRequestPostCount == 1)
    #expect(
      try runProcess(
        executable: URL(fileURLWithPath: "/usr/bin/git"),
        arguments: [
          "--git-dir", bareRepository.path,
          "for-each-ref", "--format=%(refname)", publicationRef,
        ],
        at: root
      ).isEmpty
    )
    #expect(
      try runProcess(
        executable: URL(fileURLWithPath: "/usr/bin/git"),
        arguments: ["--git-dir", bareRepository.path, "rev-parse", "refs/heads/main"],
        at: root
      ) == localSHA
    )
    state = try await service.refreshPullRequest(publicationID: publication.id)
    #expect(state.publication?.status == .merged)
    #expect(try await git.currentSHA(at: repository) == localSHA)

    state = try await service.check(productID: product.id)
    #expect(state.observation?.relationship == .aligned)
    #expect(await transport.pullRequestPostCount == 1)
    await service.shutdown()
    await store.close()
  }

  @Test("Connecting a mature local Product publishes and merges its existing history")
  func matureLocalProductConnection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Spedito-Mature-Service-\(UUID().uuidString)",
      isDirectory: true
    )
    let repository = root.appendingPathComponent("workspace", isDirectory: true)
    let bareRepository = root.appendingPathComponent("remote.git", isDirectory: true)
    let wrapper = root.appendingPathComponent("git-wrapper")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["init", "--bare", "--initial-branch=main", bareRepository.path],
      at: root
    )
    let canonicalURL = URL(string: "https://github.com/example/service.git")!
    try writeWrapper(wrapper, canonicalURL: canonicalURL, bareRepository: bareRepository)
    let git = GitWorkspaceManager(executableURL: wrapper)
    let bootstrapSHA = try await git.ensureRepository(at: repository)
    try Data("Accepted history\n".utf8).write(to: repository.appendingPathComponent("README.md"))
    let localSHA = try await git.checkpointTrunk(
      at: repository,
      message: "Add accepted Product history"
    )
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Mature Product")
    let transport = ServiceFakeGitHubTransport(
      repositoryID: 91,
      canonicalURL: canonicalURL,
      defaultBranch: "main",
      onMerge: { mergedSHA in
        try runProcess(
          executable: URL(fileURLWithPath: "/usr/bin/git"),
          arguments: [
            "--git-dir", bareRepository.path,
            "update-ref", "refs/heads/main", mergedSHA,
          ],
          at: root
        )
      }
    )
    let api = GitHubAPIClient(transport: transport, sleep: { _ in })
    let service = GitHubRemoteRepositoryService(
      configuration: GitHubConfiguration(clientID: "client-id", appSlug: "spedito-test"),
      api: api,
      credentialStore: ServiceMemoryCredentialStore(),
      credentialSession: GitCredentialSession(),
      git: git,
      storeProvider: { requestedID in requestedID == product.id ? store : nil },
      storesProvider: { [store] },
      workspaceProvider: { requestedID in
        guard requestedID == product.id else {
          throw GitHubRemoteRepositoryServiceError.stale
        }
        return repository
      }
    )
    var state = try await service.connect(productID: product.id) { _ in }
    #expect(state.connection?.status == .selectingRepository)
    state = try await service.selectLocalRepository(productID: product.id, repositoryID: 91)
    guard case .empty(let bootstrap, let existingHistory) = state.selectedEligibility else {
      Issue.record("Expected an empty repository with captured local history")
      return
    }
    #expect(bootstrap.sha == bootstrapSHA)
    #expect(existingHistory?.localSHA == localSHA)

    await transport.setHead(bootstrapSHA)
    await transport.setPullRequestHead(localSHA)
    await transport.makeNextPullRequestFetchReportChangedBase()
    let progress = ServiceInitializationProgressRecorder()
    await #expect(
      throws: GitHubRemoteRepositoryServiceError.notEligible(
        "GitHub changed this pull request. Review it on GitHub before trying again."
      )
    ) {
      _ = try await service.initializeLocalRepository(productID: product.id) { value in
        await progress.record(value)
      }
    }
    state = await service.state(productID: product.id)

    #expect(state.connection?.status == .connected)
    #expect(state.publication?.purpose == .existingProductHistory)
    #expect(state.publication?.status == .open)
    #expect(state.publication?.pullRequest?.isDraft == false)
    #expect(await transport.pullRequestPostCount == 1)
    #expect(
      await progress.values
        == [
          .validatingProduct,
          .publishingBootstrap,
          .verifyingConnection,
          .checkingRepository,
          .publishingExistingHistory,
          .mergingExistingHistory,
        ]
    )
    #expect(
      try runProcess(
        executable: URL(fileURLWithPath: "/usr/bin/git"),
        arguments: ["--git-dir", bareRepository.path, "rev-parse", "refs/heads/main"],
        at: root
      ) == bootstrapSHA
    )
    let localTree = try await git.revisionTreeSHA(
      repositoryURL: repository,
      revisionSHA: localSHA
    )
    let remoteMergedSHA = try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: [
        "--git-dir", bareRepository.path,
        "-c", "user.name=GitHub",
        "-c", "user.email=github@example.com",
        "commit-tree", localTree,
        "-p", bootstrapSHA,
        "-p", localSHA,
        "-m", "Merge existing Product history",
      ],
      at: root
    )
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: [
        "--git-dir", bareRepository.path,
        "update-ref", "refs/heads/main", remoteMergedSHA, bootstrapSHA,
      ],
      at: root
    )
    await transport.setHead(remoteMergedSHA)
    await transport.markPullRequestMerged(mergedSHA: nil)
    let existingHistoryPublication = try #require(state.publication)
    state = try await service.refreshPullRequest(
      publicationID: existingHistoryPublication.id
    )
    #expect(state.publication?.status == .merged)
    #expect(state.publication?.remoteBranchDeletedAt != nil)
    #expect(
      try runProcess(
        executable: URL(fileURLWithPath: "/usr/bin/git"),
        arguments: [
          "--git-dir", bareRepository.path,
          "for-each-ref", "--format=%(refname)",
          "refs/heads/\(existingHistoryPublication.publicationBranch)",
        ],
        at: root
      ).isEmpty
    )
    #expect(state.connection?.latestLocalSHA == remoteMergedSHA)
    #expect(state.connection?.latestRemoteSHA == remoteMergedSHA)
    #expect(state.connection?.latestRelationship == .aligned)
    #expect(state.safeSync?.status == .accepted)
    #expect(
      try runProcess(
        executable: URL(fileURLWithPath: "/usr/bin/git"),
        arguments: ["--git-dir", bareRepository.path, "rev-parse", "refs/heads/main"],
        at: root
      ) == remoteMergedSHA
    )
    #expect(try await git.currentSHA(at: repository) == remoteMergedSHA)
    state = try await service.check(productID: product.id)
    #expect(state.observation?.relationship == .aligned)
    await service.shutdown()
    await store.close()
  }

  @Test("Imported Product connects only to its preserved GitHub origin")
  func importedProductConnection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Spedito-Service-Imported-\(UUID().uuidString)",
      isDirectory: true
    )
    let repository = root.appendingPathComponent("workspace", isDirectory: true)
    let bareRepository = root.appendingPathComponent("remote.git", isDirectory: true)
    let wrapper = root.appendingPathComponent("git-wrapper")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: ["init", "--bare", "--initial-branch=main", bareRepository.path],
      at: root
    )
    let canonicalURL = URL(string: "https://github.com/example/service.git")!
    try writeWrapper(
      wrapper,
      canonicalURL: canonicalURL,
      bareRepository: bareRepository
    )
    let git = GitWorkspaceManager(executableURL: wrapper)
    let importedSHA = try await git.ensureRepository(at: repository)
    _ = try await git.run(
      ["remote", "add", "origin", canonicalURL.absoluteString],
      at: repository
    )
    _ = try await git.run(
      [
        "push", "--", canonicalURL.absoluteString,
        "refs/heads/trunk:refs/heads/main",
      ],
      at: repository
    )
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Imported Product")
    let provenance = ProductRepository(
      productID: product.id,
      originURL: canonicalURL,
      sourceDefaultBranch: "main",
      importedSHA: importedSHA
    )
    try await store.createProductRepository(provenance)
    let transport = ServiceFakeGitHubTransport(
      repositoryID: 91,
      canonicalURL: canonicalURL,
      defaultBranch: "main"
    )
    await transport.setHead(importedSHA)
    await transport.setRepositoriesVisible(false)
    let service = GitHubRemoteRepositoryService(
      configuration: GitHubConfiguration(clientID: "client-id", appSlug: "spedito-test"),
      api: GitHubAPIClient(transport: transport, sleep: { _ in }),
      credentialStore: ServiceMemoryCredentialStore(),
      credentialSession: GitCredentialSession(),
      git: git,
      storeProvider: { requestedID in requestedID == product.id ? store : nil },
      storesProvider: { [store] },
      workspaceProvider: { requestedID in
        guard requestedID == product.id else {
          throw GitHubRemoteRepositoryServiceError.stale
        }
        return repository
      }
    )

    var state = try await service.connect(productID: product.id) { _ in }
    #expect(state.connection?.kind == .importedSource)
    #expect(state.connection?.status == .needsInstallation)
    #expect(state.connection?.installationID == 1)

    await transport.setRepositoriesVisible(true)
    state = try await service.refreshRepositories(productID: product.id)
    #expect(state.connection?.status == .connected)
    #expect(state.connection?.canonicalHTTPSURL == canonicalURL)
    #expect(state.observation?.relationship == .aligned)
    let imported = try await service.importProduct(
      name: product.name,
      repositoryID: 91
    ) { source, credential in
      #expect(source.url == canonicalURL)
      #expect(credential.gitConfigurationArguments.contains("credential.helper="))
      return ImportedProduct(
        product: product,
        repository: provenance,
        knowledgeRun: RepositoryKnowledgeRun(
          productID: product.id,
          attempt: 1,
          analyzedSHA: importedSHA,
          analyzerProfileID: UUID(),
          reviewerProfileID: UUID()
        )
      )
    }
    #expect(imported.product.id == product.id)
    state = await service.state(productID: product.id)
    #expect(state.connection?.status == .connected)
    #expect(state.observation?.relationship == .aligned)
    #expect(
      try await git.run(["remote", "get-url", "origin"], at: repository)
        == canonicalURL.absoluteString)
    await service.shutdown()
    await store.close()
  }

  @Test("Expired saved authorization reconnects setup without Device Flow")
  func expiredAuthorizationReconnectsSetup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Spedito-Service-Expired-Authorization-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Reconnect Product")
    let accountID = UUID()
    _ = try await store.createRemoteRepositoryConnection(
      RemoteRepositoryConnection(
        productID: product.id,
        kind: .localEmptyRepository,
        accountID: accountID,
        status: .needsAuthorization
      )
    )
    let credentialStore = ServiceMemoryCredentialStore()
    try await credentialStore.save(
      GitHubAccountTokenSet(
        accountID: accountID,
        githubUserID: 5,
        login: "owner",
        accessToken: "ghu_expired",
        accessTokenExpiresAt: .distantPast,
        refreshToken: "ghr_current",
        refreshTokenExpiresAt: .distantFuture
      )
    )
    let transport = ServiceFakeGitHubTransport(
      repositoryID: 91,
      canonicalURL: URL(string: "https://github.com/example/service.git")!,
      defaultBranch: "main"
    )
    let service = GitHubRemoteRepositoryService(
      configuration: GitHubConfiguration(clientID: "client-id", appSlug: "spedito-test"),
      api: GitHubAPIClient(transport: transport, sleep: { _ in }),
      credentialStore: credentialStore,
      credentialSession: GitCredentialSession(temporaryDirectory: root),
      git: GitWorkspaceManager(),
      storeProvider: { requestedID in requestedID == product.id ? store : nil },
      storesProvider: { [store] },
      workspaceProvider: { _ in root }
    )
    let prompt = ServicePromptRecorder()

    var state = try await service.connect(productID: product.id) { value in
      await prompt.record(value)
    }
    #expect(state.connection?.status == .selectingRepository)
    #expect(state.repositories.map(\.id) == [91])
    #expect(await prompt.value == nil)
    #expect(await transport.deviceCodeRequestCount == 0)
    #expect(await transport.oauthTokenRequestCount == 1)

    state = try await service.cancelConnection(productID: product.id)
    #expect(state.connection?.status == .disconnected)
    state = try await service.connect(productID: product.id) { value in
      await prompt.record(value)
    }
    #expect(state.connection?.status == .selectingRepository)
    #expect(state.repositories.map(\.id) == [91])
    #expect(await prompt.value == nil)
    #expect(await transport.deviceCodeRequestCount == 0)
    #expect(await transport.oauthTokenRequestCount == 1)
    await service.shutdown()
    await store.close()
  }

  @Test("Cancelling repository setup does not access Keychain")
  func cancelSetupWithoutCredentials() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Spedito-Service-Cancel-Setup-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Setup Product")
    _ = try await store.createRemoteRepositoryConnection(
      RemoteRepositoryConnection(
        productID: product.id,
        kind: .localEmptyRepository,
        accountID: UUID(),
        installationID: 1,
        repositoryID: 91,
        owner: "example",
        name: "service",
        fullName: "example/service",
        canonicalHTTPSURL: URL(string: "https://github.com/example/service.git"),
        isPrivate: true,
        defaultBranch: "main",
        permissions: RemoteRepositoryPermissions(
          metadataRead: true,
          contentsWrite: true,
          pullRequestsWrite: true,
          workflowsWrite: true
        ),
        status: .selectingRepository
      )
    )
    let credentialStore = ServiceCountingCredentialStore()
    let service = GitHubRemoteRepositoryService(
      configuration: GitHubConfiguration(clientID: "client-id", appSlug: "spedito-test"),
      credentialStore: credentialStore,
      credentialSession: GitCredentialSession(temporaryDirectory: root),
      git: GitWorkspaceManager(),
      storeProvider: { requestedID in requestedID == product.id ? store : nil },
      storesProvider: { [store] },
      workspaceProvider: { _ in root }
    )

    let state = try await service.cancelConnection(productID: product.id)

    #expect(state.connection?.status == .disconnected)
    #expect(state.connection?.accountID == nil)
    #expect(state.connection?.installationID == nil)
    #expect(state.connection?.repositoryID == nil)
    #expect(state.connection?.fullName == nil)
    #expect(await credentialStore.accessCount == 0)
    await service.shutdown()
    await store.close()
  }

  @Test("Unconnected Products do not query Keychain during recovery")
  func unconnectedProductRecovery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Spedito-Service-Unconnected-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Unconnected Product")
    let credentialStore = ServiceCountingCredentialStore()
    let service = GitHubRemoteRepositoryService(
      configuration: GitHubConfiguration(clientID: "client-id", appSlug: "spedito-test"),
      credentialStore: credentialStore,
      credentialSession: GitCredentialSession(temporaryDirectory: root),
      git: GitWorkspaceManager(),
      storeProvider: { requestedID in requestedID == product.id ? store : nil },
      storesProvider: { [store] },
      workspaceProvider: { _ in root }
    )

    await service.recover(productID: product.id)

    #expect(await credentialStore.accessCount == 0)
    #expect(await service.state(productID: product.id).errorMessage == nil)
    await service.shutdown()
    await store.close()
  }

  @Test("Remote state and commands report persistence failures")
  func persistenceFailuresRemainOwnerVisible() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Spedito-Service-Persistence-Failure-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Persistence failure")
    let service = GitHubRemoteRepositoryService(
      configuration: GitHubConfiguration(clientID: "client-id", appSlug: "spedito-test"),
      credentialStore: ServiceCountingCredentialStore(),
      credentialSession: GitCredentialSession(temporaryDirectory: root),
      git: GitWorkspaceManager(),
      storeProvider: { requestedID in requestedID == product.id ? store : nil },
      storesProvider: { [store] },
      workspaceProvider: { _ in root }
    )
    await store.close()

    let state = await service.state(productID: product.id)

    #expect(state.errorMessage?.isEmpty == false)
    await service.shutdown()
  }

  @Test("Idle connected Products do not query Keychain during recovery")
  func idleConnectedProductRecovery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Spedito-Service-Idle-Connected-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Connected Product")
    _ = try await store.createRemoteRepositoryConnection(
      RemoteRepositoryConnection(
        productID: product.id,
        kind: .importedSource,
        accountID: UUID(),
        installationID: 1,
        repositoryID: 2,
        owner: "owner",
        name: "repository",
        fullName: "owner/repository",
        canonicalHTTPSURL: URL(string: "https://github.com/owner/repository.git")!,
        isPrivate: true,
        defaultBranch: "main",
        status: .connected
      )
    )
    let credentialStore = ServiceCountingCredentialStore()
    let service = GitHubRemoteRepositoryService(
      configuration: GitHubConfiguration(clientID: "client-id", appSlug: "spedito-test"),
      credentialStore: credentialStore,
      credentialSession: GitCredentialSession(temporaryDirectory: root),
      git: GitWorkspaceManager(),
      storeProvider: { requestedID in requestedID == product.id ? store : nil },
      storesProvider: { [store] },
      workspaceProvider: { _ in root }
    )

    await service.recover(productID: product.id)

    #expect(await credentialStore.accessCount == 0)
    #expect(await service.state(productID: product.id).errorMessage == nil)
    await service.shutdown()
    await store.close()
  }

  @Test("Archived Products retain remote audit state without recovery access")
  func archivedProductRecoveryDoesNoExternalWork() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Spedito-Service-Archived-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Archived Product")
    let connection = try await store.createRemoteRepositoryConnection(
      RemoteRepositoryConnection(
        productID: product.id,
        kind: .localEmptyRepository,
        accountID: UUID(),
        installationID: 1,
        repositoryID: 2,
        owner: "owner",
        name: "repository",
        fullName: "owner/repository",
        canonicalHTTPSURL: URL(string: "https://github.com/owner/repository.git")!,
        isPrivate: true,
        defaultBranch: "main",
        status: .initializingRemote,
        bootstrapRootSHA: String(repeating: "1", count: 40),
        bootstrapRootTree: String(repeating: "2", count: 40),
        initializationAttemptCount: 1
      )
    )
    _ = try await store.archiveProduct(id: product.id)
    let credentialStore = ServiceCountingCredentialStore()
    let service = GitHubRemoteRepositoryService(
      configuration: GitHubConfiguration(clientID: "client-id", appSlug: "spedito-test"),
      credentialStore: credentialStore,
      credentialSession: GitCredentialSession(temporaryDirectory: root),
      git: GitWorkspaceManager(),
      storeProvider: { requestedID in requestedID == product.id ? store : nil },
      storesProvider: { [store] },
      workspaceProvider: { _ in root }
    )

    await service.recover(productID: product.id)
    let state = await service.state(productID: product.id)

    #expect(await credentialStore.accessCount == 0)
    #expect(state.connection?.id == connection.id)
    #expect(state.connection?.status == .initializingRemote)
    #expect(state.errorMessage == nil)
    await service.shutdown()
    await store.close()
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

  private func writeWrapper(
    _ wrapper: URL,
    canonicalURL: URL,
    bareRepository: URL
  ) throws {
    let quote: (String) -> String = {
      "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    let script = """
      #!/bin/zsh
      remote=\(quote(bareRepository.path))
      github=\(quote(canonicalURL.absoluteString))
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
}
private enum ServiceImportProbe: Error {
  case recorded
}

private actor ServiceImportRecorder {
  private(set) var sourceURL: URL?
  private(set) var configurationArguments: [String] = []

  func record(
    source: PublicGitRepositoryURL,
    credential: GitCredentialSessionConfiguration
  ) {
    sourceURL = source.url
    configurationArguments = credential.gitConfigurationArguments
  }
}

private actor ServiceMemoryCredentialStore: GitHubCredentialStoring {
  private var values: [UUID: GitHubAccountTokenSet] = [:]

  func tokenSet(accountID: UUID) async throws -> GitHubAccountTokenSet? {
    values[accountID]
  }

  func allTokenSets() async throws -> [GitHubAccountTokenSet] {
    Array(values.values)
  }

  func save(_ tokenSet: GitHubAccountTokenSet) async throws {
    values[tokenSet.accountID] = tokenSet
  }

  func delete(accountID: UUID) async throws {
    values.removeValue(forKey: accountID)
  }
}

private actor ServiceCountingCredentialStore: GitHubCredentialStoring {
  private(set) var accessCount = 0

  func tokenSet(accountID: UUID) async throws -> GitHubAccountTokenSet? {
    accessCount += 1
    return nil
  }

  func allTokenSets() async throws -> [GitHubAccountTokenSet] {
    accessCount += 1
    return []
  }

  func save(_ tokenSet: GitHubAccountTokenSet) async throws {
    accessCount += 1
  }

  func delete(accountID: UUID) async throws {
    accessCount += 1
  }
}

private actor ServicePromptRecorder {
  private(set) var value: GitHubDeviceAuthorizationPrompt?

  func record(_ value: GitHubDeviceAuthorizationPrompt) {
    self.value = value
  }
}

private actor ServiceInitializationProgressRecorder {
  private(set) var values: [GitHubRemoteRepositoryInitializationProgress] = []

  func record(_ value: GitHubRemoteRepositoryInitializationProgress) {
    values.append(value)
  }
}

private actor ServiceFakeGitHubTransport: GitHubHTTPTransport {
  private let repositoryID: Int64
  private let canonicalURL: URL
  private let defaultBranch: String
  private var headSHA: String?
  private let onMerge: @Sendable (String) throws -> Void
  private var pullRequestHeadSHA: String?
  private var pullRequestBaseSHA: String?
  private var pullRequestMergedSHA: String?
  private var pullRequestWasMerged = false
  private var pullRequestCreated = false
  private var pullRequestIsDraft = false
  private var hasChangesRequested = false
  private(set) var pullRequestPostCount = 0
  private var nextPullRequestPostIsAmbiguous = false
  private var nextUserRequestTimesOut = false
  private(set) var userRequestCount = 0
  private(set) var deviceCodeRequestCount = 0
  private(set) var oauthTokenRequestCount = 0
  private var repositoriesVisible = true
  private var repositoryContainsBranches = false
  private var pendingMergedHeadSHA: String?
  private var mergedHeadVisibilityDelay = 0
  private var nextPullRequestFetchBaseSHA: String?

  init(
    repositoryID: Int64,
    canonicalURL: URL,
    defaultBranch: String,
    onMerge: @escaping @Sendable (String) throws -> Void = { _ in }
  ) {
    self.repositoryID = repositoryID
    self.canonicalURL = canonicalURL
    self.defaultBranch = defaultBranch
    self.onMerge = onMerge
  }

  func setHead(_ value: String?) {
    headSHA = value
  }

  func setPullRequestHead(_ value: String) {
    pullRequestHeadSHA = value
  }

  func setPullRequestBase(_ value: String) {
    pullRequestBaseSHA = value
  }

  func markPullRequestMerged(mergedSHA: String?) {
    pullRequestWasMerged = true
    pullRequestMergedSHA = mergedSHA
  }

  func makeNextPullRequestPostAmbiguous() {
    nextPullRequestPostIsAmbiguous = true
  }

  func setChangesRequested(_ value: Bool) {
    hasChangesRequested = value
  }

  func makeNextUserRequestTimeout() {
    nextUserRequestTimesOut = true
  }

  func delayMergedHeadVisibility(requestCount: Int) {
    mergedHeadVisibilityDelay = requestCount
  }

  func makeNextPullRequestFetchReportChangedBase() {
    nextPullRequestFetchBaseSHA = String(repeating: "f", count: 40)
  }
  func setRepositoriesVisible(_ value: Bool) {
    repositoriesVisible = value
  }

  func setRepositoryContainsBranches(_ value: Bool) {
    repositoryContainsBranches = value
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    guard let url = request.url else { throw GitHubAPIError.invalidResponse }
    let path = url.path
    if url.host == "github.com", path == "/login/device/code" {
      deviceCodeRequestCount += 1
      return response(
        request,
        json: [
          "device_code": "device-code",
          "user_code": "ABCD-EFGH",
          "verification_uri": "https://github.com/login/device",
          "expires_in": 900,
          "interval": 1,
        ]
      )
    }
    if url.host == "github.com", path == "/login/oauth/access_token" {
      oauthTokenRequestCount += 1
      return response(
        request,
        json: [
          "access_token": "ghu_abcdefghijklmnopqrstuvwxyz123456",
          "expires_in": 28_800,
          "refresh_token": "ghr_abcdefghijklmnopqrstuvwxyz123456",
          "refresh_token_expires_in": 15_811_200,
        ]
      )
    }
    if path == "/user" {
      userRequestCount += 1
      if nextUserRequestTimesOut {
        nextUserRequestTimesOut = false
        throw URLError(.timedOut)
      }
      return response(request, json: ["id": 5, "login": "owner"])
    }
    if path == "/user/installations" {
      return response(
        request,
        json: [
          "installations": [
            [
              "id": 1,
              "account": ["login": "example"],
              "repository_selection": "selected",
              "permissions": [
                "metadata": "read",
                "contents": "write",
                "pull_requests": "write",
                "workflows": "write",
              ],
            ]
          ]
        ]
      )
    }
    if path == "/user/installations/1/repositories" {
      return response(
        request,
        json: ["repositories": repositoriesVisible ? [repositoryJSON()] : []]
      )
    }
    if path == "/repos/example/service/branches" {
      return response(
        request,
        json: repositoryContainsBranches ? [["name": defaultBranch]] : []
      )
    }
    if path == "/repos/example/service" {
      return response(request, json: repositoryJSON())
    }
    if path == "/repos/example/service/git/ref/heads/main" {
      if mergedHeadVisibilityDelay > 0 {
        mergedHeadVisibilityDelay -= 1
      } else if let pendingMergedHeadSHA {
        headSHA = pendingMergedHeadSHA
        self.pendingMergedHeadSHA = nil
      }
      guard let headSHA else { return response(request, status: 404, json: [:]) }
      return response(request, json: ["object": ["sha": headSHA]])
    }
    if path == "/repos/example/service/pulls", request.httpMethod == "GET" {
      let values: [[String: Any]] = pullRequestCreated ? [pullRequestJSON()] : []
      return response(request, json: values)
    }
    if path == "/repos/example/service/pulls", request.httpMethod == "POST" {
      pullRequestPostCount += 1
      pullRequestCreated = true
      pullRequestBaseSHA = headSHA
      if let body = request.httpBody,
        let value = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
      {
        _ = value["title"] as? String
        _ = value["body"] as? String
        pullRequestIsDraft = value["draft"] as? Bool ?? false
      }
      if nextPullRequestPostIsAmbiguous {
        nextPullRequestPostIsAmbiguous = false
        throw GitHubAPIError.timedOut
      }
      return response(request, status: 201, json: pullRequestJSON())
    }
    if path == "/repos/example/service/pulls/1" {
      let baseSHA = nextPullRequestFetchBaseSHA
      nextPullRequestFetchBaseSHA = nil
      return response(
        request,
        json: pullRequestJSON(baseSHA: baseSHA)
      )
    }
    if path == "/repos/example/service/pulls/1/reviews" {
      let reviews: [[String: Any]] =
        hasChangesRequested
        ? [
          [
            "id": 71,
            "user": [
              "login": "reviewer",
              "avatar_url": "https://avatars.githubusercontent.com/u/71",
            ],
            "body": "Please cover the failure state.",
            "state": "CHANGES_REQUESTED",
            "updated_at": "2026-08-05T12:00:00Z",
            "html_url": "https://github.com/example/service/pull/1#pullrequestreview-71",
            "submitted_at": "2026-08-05T12:00:00Z",
          ],
          [
            "id": 73,
            "user": [
              "login": "reviewer",
              "avatar_url": "https://avatars.githubusercontent.com/u/71",
            ],
            "body": "",
            "state": "COMMENTED",
            "updated_at": NSNull(),
            "html_url": "https://github.com/example/service/pull/1#pullrequestreview-73",
            "submitted_at": "2026-08-05T12:01:00Z",
          ],
        ]
        : []
      return response(request, json: reviews)
    }
    if path == "/repos/example/service/pulls/1/comments" {
      guard hasChangesRequested, let pullRequestHeadSHA else {
        return response(request, json: [])
      }
      return response(
        request,
        json: [
          [
            "id": 72,
            "user": [
              "login": "reviewer",
              "avatar_url": "https://avatars.githubusercontent.com/u/71",
            ],
            "body": "Handle this branch.",
            "html_url": "https://github.com/example/service/pull/1#discussion_r72",
            "created_at": "2026-08-05T12:01:00Z",
            "path": "Sources/Service.swift",
            "commit_id": pullRequestHeadSHA,
            "original_commit_id": pullRequestHeadSHA,
            "diff_hunk": "@@ -8,2 +8,3 @@\\n existing\\n+changed",
            "start_line": 8,
            "line": 9,
            "start_side": "RIGHT",
            "side": "RIGHT",
            "original_start_line": NSNull(),
            "original_line": NSNull(),
          ]
        ]
      )
    }
    if path == "/graphql", request.httpMethod == "POST" {
      guard let body = request.httpBody,
        let value = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
        let query = value["query"] as? String
      else {
        throw GitHubAPIError.invalidResponse
      }
      if query.contains("markPullRequestReadyForReview") {
        pullRequestIsDraft = false
        return response(
          request,
          json: [
            "data": [
              "markPullRequestReadyForReview": [
                "pullRequest": ["id": "PR_node_1", "isDraft": false]
              ]
            ]
          ]
        )
      }
      if query.contains("convertPullRequestToDraft") {
        pullRequestIsDraft = true
        return response(
          request,
          json: [
            "data": [
              "convertPullRequestToDraft": [
                "pullRequest": ["id": "PR_node_1", "isDraft": true]
              ]
            ]
          ]
        )
      }
      throw GitHubAPIError.invalidResponse
    }
    if path == "/repos/example/service/pulls/1/merge", request.httpMethod == "PUT" {
      guard let pullRequestHeadSHA else { throw GitHubAPIError.invalidResponse }
      try onMerge(pullRequestHeadSHA)
      if mergedHeadVisibilityDelay > 0 {
        pendingMergedHeadSHA = pullRequestHeadSHA
      } else {
        headSHA = pullRequestHeadSHA
      }
      pullRequestWasMerged = true
      pullRequestMergedSHA = pullRequestHeadSHA
      return response(
        request,
        json: ["sha": pullRequestHeadSHA, "merged": true, "message": "Merged"]
      )
    }
    throw GitHubAPIError.invalidResponse
  }

  private func repositoryJSON() -> [String: Any] {
    [
      "id": repositoryID,
      "owner": ["login": "example"],
      "name": "service",
      "full_name": "example/service",
      "html_url": "https://github.com/example/service",
      "clone_url": canonicalURL.absoluteString,
      "private": false,
      "default_branch": defaultBranch,
    ]
  }

  private func pullRequestJSON(baseSHA: String? = nil) -> [String: Any] {
    let merged = pullRequestWasMerged
    return [
      "number": 1,
      "node_id": "PR_node_1",
      "html_url": "https://github.com/example/service/pull/1",
      "state": merged ? "closed" : "open",
      "draft": pullRequestIsDraft,
      "head": [
        "ref": "spedito/service", "sha": pullRequestHeadSHA ?? String(repeating: "0", count: 40),
      ],
      "base": [
        "ref": defaultBranch,
        "sha": baseSHA ?? pullRequestBaseSHA ?? headSHA ?? String(repeating: "0", count: 40),
      ],
      "merge_commit_sha": pullRequestMergedSHA as Any,
      "merged_at": merged ? "2026-08-05T12:00:00Z" : NSNull(),
      "updated_at": "2026-08-05T12:00:00Z",
    ]
  }

  private func response(
    _ request: URLRequest,
    status: Int = 200,
    json: Any
  ) -> (Data, HTTPURLResponse) {
    let data = try! JSONSerialization.data(withJSONObject: json)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: [:]
    )!
    return (data, response)
  }
}
