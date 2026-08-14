import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

@Suite("Remote repository AppModel", .serialized)
@MainActor
struct RemoteRepositoryAppModelTests {
  @Test("GitHub prompts, state, failures, and shutdown stay Product scoped")
  func remoteLifecycle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Spedito-AppModel-Remote-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Remote Product")
    let service = AppModelRemoteService()
    let model = AppModel(
      store: store,
      selectedProductID: product.id,
      githubRemoteService: service
    )
    await model.reload()
    await model.refreshGitHubImportRepositories()
    #expect(
      model.githubImportRepositoryCatalog.choices.map(\.repository.fullName)
        == ["example/importable"]
    )
    #expect(model.githubImportRepositoryCatalog.installations.map(\.id) == [41])
    #expect(model.githubImportRepositoryError == nil)
    await model.connectGitHubForImport()
    #expect(await service.didAuthorizeImport)
    #expect(model.githubImportRepositoryCatalog.choices.first?.repository.isPrivate == true)

    let connectionTask = Task {
      await model.connectGitHub(productID: product.id)
    }
    for _ in 0..<100 where !(await service.didPresentPrompt) {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.githubDeviceAuthorizationPrompts[product.id]?.userCode == "ABCD-EFGH")
    #expect(model.githubRemoteRepositoryBusyProductIDs.contains(product.id))

    let queuedSelection = Task {
      await model.selectLocalGitHubRepository(productID: product.id, repositoryID: 91)
    }
    try await Task.sleep(for: .milliseconds(10))
    await service.completeConnection()
    await connectionTask.value
    await queuedSelection.value
    #expect(await service.selectionCount == 1)
    #expect(model.githubDeviceAuthorizationPrompts[product.id] == nil)
    #expect(
      model.githubRemoteRepositoryStates[product.id]?.connection?.status == .selectingRepository)
    #expect(!model.githubRemoteRepositoryBusyProductIDs.contains(product.id))

    await service.pauseNextInitialization()
    let initializationTask = Task {
      await model.initializeLocalGitHubRepository(productID: product.id)
    }
    for _ in 0..<100 where !(await service.didStartInitialization) {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(
      model.githubRepositorySetupActivities[product.id]
        == .inProgress(progress: .validatingProduct, publishesExistingHistory: false)
    )
    #expect(
      !GitHubRepositoryPickerDismissalPolicy.canDismiss(
        activity: model.githubRepositorySetupActivities[product.id]
      )
    )
    await service.completeInitialization()
    await initializationTask.value
    #expect(model.githubRemoteRepositoryStates[product.id]?.connection?.status == .connected)
    #expect(
      model.githubRepositorySetupActivities[product.id]
        == .completed(publishedExistingHistory: false)
    )
    #expect(
      GitHubRepositoryPickerDismissalPolicy.canDismiss(
        activity: model.githubRepositorySetupActivities[product.id]
      )
    )

    await service.failChecks()
    await model.checkRemoteRepository(productID: product.id)
    #expect(model.githubRemoteRepositoryErrors[product.id] == "GitHub is temporarily unavailable.")
    #expect(model.errorMessage == nil)

    await model.shutdown()
    #expect(await service.didShutdown)
    await store.close()
  }

  @Test("Relaunched repository setup reloads access before verification")
  func relaunchedRepositorySetupRecovery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Spedito-AppModel-Remote-Resume-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Resumed setup")
    let service = AppModelRemoteService()
    await service.prepareRelaunchedSetup(productID: product.id)
    let model = AppModel(
      store: store,
      selectedProductID: product.id,
      githubRemoteService: service
    )
    await model.reload()

    #expect(model.githubRemoteRepositoryStates[product.id]?.repositories.isEmpty == true)
    await model.resumeLocalGitHubRepositorySetup(productID: product.id)
    #expect(await service.refreshRepositoryCount == 1)
    #expect(await service.selectionCount == 1)

    await model.shutdown()
    await store.close()
  }

  @Test("An empty GitHub repository creates and connects a blank Product")
  func emptyGitHubRepositoryCreation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Spedito-AppModel-Empty-Remote-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: root.appendingPathComponent(
        "Product Workspaces",
        isDirectory: true
      )
    )
    let service = AppModelRemoteService()
    await service.failNextImport(with: .emptyDefaultBranch)
    let model = AppModel(storeRegistry: registry, githubRemoteService: service)
    await model.reload()

    let created = await model.createProductAndSelect(
      .importGitHubRepository(name: "WeatherApp3", repositoryID: 99)
    )

    #expect(created)
    let product = try #require(model.products.first { $0.name == "WeatherApp3" })
    #expect(model.selectedProductID == product.id)
    #expect(model.productCreationError == nil)
    #expect(await service.connectedLocalProductID == product.id)
    #expect(await service.connectedLocalRepositoryID == 99)
    let store = try #require(registry.store(for: product.id))
    #expect(try await store.fetchProductRepository(productID: product.id) == nil)
    #expect(
      FileManager.default.fileExists(
        atPath: registry.productWorkspacesRootURL
          .appendingPathComponent(product.id.uuidString)
          .appendingPathComponent(".git")
          .path
      )
    )

    await model.shutdown()
    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("A failed repository creation leaves an owner-facing error")
  func repositoryCreationFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Spedito-AppModel-Failed-Remote-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: root.appendingPathComponent(
        "Product Workspaces",
        isDirectory: true
      )
    )
    let service = AppModelRemoteService()
    await service.failNextImport(with: .cloneFailed)
    let model = AppModel(storeRegistry: registry, githubRemoteService: service)
    await model.reload()

    let created = await model.createProductAndSelect(
      .importGitHubRepository(name: "Unavailable", repositoryID: 99)
    )

    #expect(!created)
    #expect(
      model.productCreationError
        == "Spedito couldn't clone that public repository. Check the link, repository visibility, and network connection, then try again."
    )
    #expect(model.products.isEmpty)

    await model.shutdown()
  }

  @Test("Delivery starts without a GitHub gate and active delivery blocks incoming changes")
  func deliveryRemoteSafety() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Spedito-AppModel-Remote-Safety-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Remote safety")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Deliver safely",
      acceptanceCriteria: ["Remote work is checked"]
    )
    _ = try await store.transitionWorkItem(
      id: item.id,
      to: .refining,
      actor: "Business analyst",
      reason: "Refine"
    )
    let ready = try await store.transitionWorkItem(
      id: item.id,
      to: .ready,
      actor: "Product owner",
      reason: "Ready"
    )
    _ = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Deliver without overwriting remote work",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: ready.id,
          implementerProfileID: implementer.id,
          reviewerProfileID: nil
        )
      ]
    )
    let service = AppModelRemoteService()
    await service.setRelationship(productID: product.id, relationship: .remoteAhead)
    let model = AppModel(
      store: store,
      selectedProductID: product.id,
      githubRemoteService: service
    )
    await model.reload()

    #expect(await model.startSprint())
    #expect(try await store.fetchCurrentSprint(productID: product.id)?.sprint.state == .active)
    #expect(await service.checkCount == 0)
    #expect(model.errorMessage == nil)

    await model.prepareIncomingRepositoryChange(productID: product.id)
    #expect(await service.prepareSafeSyncCount == 0)
    await model.prepareRemotePublication(productID: product.id)
    #expect(await service.preparePublicationCount == 0)
    #expect(
      model.githubRemoteRepositoryErrors[product.id]?
        .contains("before preparing a pull request") == true
    )
    await model.shutdown()
    await store.close()
  }

  @Test("Repository setup advances directly to its required destination")
  func repositorySetupLaunch() {
    #expect(
      GitHubRepositorySetupLaunch.resolve(status: .selectingRepository)
        == .repositoryPicker
    )
    #expect(
      GitHubRepositorySetupLaunch.resolve(status: .needsInstallation)
        == .installation
    )
    #expect(GitHubRepositorySetupLaunch.resolve(status: .connected) == .none)
  }

  @Test("Repository picker distinguishes loading failures from empty access")
  func repositoryPickerContent() {
    #expect(
      GitHubRepositoryPickerContent.resolve(
        repositoryCount: 0,
        isBusy: true,
        error: "Old error"
      ) == .loading
    )
    #expect(
      GitHubRepositoryPickerContent.resolve(
        repositoryCount: 0,
        isBusy: false,
        error: "GitHub authorization failed."
      ) == .failure("GitHub authorization failed.")
    )
    #expect(
      GitHubRepositoryPickerContent.resolve(
        repositoryCount: 0,
        isBusy: false,
        error: nil
      ) == .empty
    )
    #expect(
      GitHubRepositoryPickerContent.resolve(
        repositoryCount: 1,
        isBusy: false,
        error: "Old error"
      ) == .repositories
    )
  }

  @Test("New Product import can manage existing GitHub App repository access")
  func repositoryImportAccessPresentation() {
    let installation = GitHubInstallation(
      id: 41,
      accountLogin: "example",
      repositorySelection: "selected",
      permissions: GitHubInstallationPermissions(metadata: "read")
    )
    #expect(
      GitHubRepositoryImportAccessPresentation.resolve(
        installations: [installation],
        appSlug: "spedito-test"
      )
        == [
          GitHubRepositoryImportAccessDestination(
            installationID: 41,
            title: "Manage repository access",
            url: URL(string: "https://github.com/settings/installations/41")!
          )
        ]
    )
    #expect(
      GitHubRepositoryImportAccessPresentation.resolve(
        installations: [],
        appSlug: "spedito-test"
      )
        == [
          GitHubRepositoryImportAccessDestination(
            installationID: nil,
            title: "Choose repositories on GitHub",
            url: URL(string: "https://github.com/apps/spedito-test/installations/new")!
          )
        ]
    )
  }

  @Test("Verified repository guidance stays concise")
  func verifiedRepositoryPresentation() {
    #expect(
      GitHubVerifiedRepositoryPresentation.resolve(hasExistingHistory: false)
        == GitHubVerifiedRepositoryPresentation(
          message: "Spedito will initialize this empty repository with the Product.",
          actionTitle: "Connect repository"
        )
    )
    #expect(
      GitHubVerifiedRepositoryPresentation.resolve(hasExistingHistory: true)
        == GitHubVerifiedRepositoryPresentation(
          message:
            "Spedito will initialize this empty repository, then publish the Product's existing work through one pull request. No action is needed on GitHub.",
          actionTitle: "Connect and publish"
        )
    )
  }

  @Test("Repository setup presents one clear next step")
  func repositorySetupPresentation() {
    #expect(
      GitHubRepositorySetupPresentation.resolve(
        repositoryID: nil,
        eligibility: nil
      )
        == GitHubRepositorySetupPresentation(
          step: .chooseRepository,
          actionTitle: "Choose repository"
        )
    )
    #expect(
      GitHubRepositorySetupPresentation.resolve(
        repositoryID: 91,
        eligibility: nil
      )
        == GitHubRepositorySetupPresentation(
          step: .verifyRepository,
          actionTitle: "Continue setup"
        )
    )
    #expect(
      GitHubRepositorySetupPresentation.resolve(
        repositoryID: 91,
        eligibility: .checking
      )
        == GitHubRepositorySetupPresentation(
          step: .checkingRepository,
          actionTitle: nil
        )
    )
    #expect(
      GitHubRepositorySetupPresentation.resolve(
        repositoryID: 91,
        eligibility: .ineligible("Repository is not empty.")
      )
        == GitHubRepositorySetupPresentation(
          step: .chooseAnotherRepository,
          actionTitle: "Choose another repository"
        )
    )
  }

  @Test("Repository setup progress explains publication and completion")
  func repositorySetupProgressPresentation() {
    #expect(
      GitHubRepositoryInitializationPresentation.resolve(
        activity: .inProgress(
          progress: .publishingExistingHistory,
          publishesExistingHistory: true
        )
      )
        == GitHubRepositoryInitializationPresentation(
          title: "Publishing existing Product work",
          detail: "Creating one review branch and pull request for the accepted local history.",
          step: 5,
          stepCount: 6,
          isComplete: false
        )
    )
    #expect(
      GitHubRepositoryInitializationPresentation.resolve(
        activity: .completed(publishedExistingHistory: true)
      )
        == GitHubRepositoryInitializationPresentation(
          title: "GitHub repository connected",
          detail:
            "Spedito initialized the repository, merged the pull request, and aligned the local Product.",
          step: 6,
          stepCount: 6,
          isComplete: true
        )
    )
  }

  @Test("Existing Product history exposes one clear recovery action")
  func existingHistoryRecoveryPresentation() {
    #expect(
      GitHubPullRequestActionPresentation.resolve(
        purpose: .existingProductHistory,
        status: .open,
        relationship: .localAhead,
        hasAcceptedSynchronization: false
      )
        == GitHubPullRequestActionPresentation(
          title: "Finish GitHub setup",
          isPrimary: true,
          showsButton: true
        )
    )
    #expect(
      GitHubPullRequestActionPresentation.resolve(
        purpose: .ticket,
        status: .open,
        relationship: nil,
        hasAcceptedSynchronization: false
      )
        == GitHubPullRequestActionPresentation(
          title: "Refresh pull request",
          isPrimary: false,
          showsButton: true
        )
    )
    #expect(
      GitHubPullRequestActionPresentation.resolve(
        purpose: .existingProductHistory,
        status: .merged,
        relationship: .aligned,
        hasAcceptedSynchronization: false
      )
        == GitHubPullRequestActionPresentation(
          title: "Refresh pull request",
          isPrimary: false,
          showsButton: false
        )
    )
    #expect(
      GitHubPullRequestActionPresentation.resolve(
        purpose: .existingProductHistory,
        status: .merged,
        relationship: .remoteAhead,
        hasAcceptedSynchronization: true
      )
        == GitHubPullRequestActionPresentation(
          title: "Refresh pull request",
          isPrimary: false,
          showsButton: false
        )
    )
  }

  @Test("Product settings warns only for repository failures and unsafe states")
  func repositoryAttentionPolicy() {
    #expect(
      !GitHubRepositoryAttentionPolicy.needsAttention(
        error: nil,
        connectionStatus: .connected,
        relationship: .localAhead,
        publicationStatus: nil
      )
    )
    #expect(
      !GitHubRepositoryAttentionPolicy.needsAttention(
        error: nil,
        connectionStatus: .connected,
        relationship: .remoteAhead,
        publicationStatus: .openOutdated
      )
    )
    #expect(
      GitHubRepositoryAttentionPolicy.needsAttention(
        error: nil,
        connectionStatus: .connected,
        relationship: .diverged,
        publicationStatus: nil
      )
    )
    #expect(
      GitHubRepositoryAttentionPolicy.needsAttention(
        error: "GitHub could not be checked.",
        connectionStatus: .connected,
        relationship: .aligned,
        publicationStatus: nil
      )
    )
    #expect(
      GitHubRepositoryAttentionPolicy.needsAttention(
        error: nil,
        connectionStatus: .connected,
        relationship: .aligned,
        publicationStatus: .openStale
      )
    )
  }

  @Test("Sprint board hides routine publication states and shows owner actions")
  func sprintBoardGitHubPresentation() throws {
    #expect(
      SprintBoardGitHubPresentation.resolve(
        error: nil,
        connectionStatus: .connected,
        relationship: .localAhead,
        aheadCount: 1,
        behindCount: 0,
        publicationStatus: nil,
        hasActiveDelivery: true
      ) == nil
    )

    for status in [
      RemotePublicationStatus.checking,
      .pushing,
      .branchPublished,
      .creatingPullRequest,
      .open,
      .openOutdated,
      .merged,
    ] {
      #expect(
        SprintBoardGitHubPresentation.resolve(
          error: nil,
          connectionStatus: .connected,
          relationship: .aligned,
          aheadCount: 0,
          behindCount: 0,
          publicationStatus: status,
          hasActiveDelivery: true
        ) == nil
      )
    }

    let incoming = try #require(
      SprintBoardGitHubPresentation.resolve(
        error: nil,
        connectionStatus: .connected,
        relationship: .remoteAhead,
        aheadCount: 0,
        behindCount: 2,
        publicationStatus: nil,
        hasActiveDelivery: false
      )
    )
    #expect(incoming.title == "GitHub has 2 incoming changes")
    #expect(incoming.action == .reviewIncoming)

    #expect(
      SprintBoardGitHubPresentation.resolve(
        error: nil,
        connectionStatus: .connected,
        relationship: .remoteAhead,
        aheadCount: 0,
        behindCount: 2,
        publicationStatus: nil,
        hasActiveDelivery: true
      ) == nil
    )

    let attention = try #require(
      SprintBoardGitHubPresentation.resolve(
        error: nil,
        connectionStatus: .connected,
        relationship: .aligned,
        aheadCount: 0,
        behindCount: 0,
        publicationStatus: .openStale,
        hasActiveDelivery: true
      )
    )
    #expect(attention.title == "Ticket delivery needs attention")
    #expect(!attention.detail.localizedCaseInsensitiveContains("pull request"))
  }

  @Test("Polling covers every active ticket pull request in owner-action order")
  func pullRequestPollingPolicy() {
    let productID = UUID()
    let connectionID = UUID()
    let accountID = UUID()
    let visibleItem = pollingWorkItem(
      productID: productID,
      key: "T1",
      state: .running
    )
    let ownerActionItem = pollingWorkItem(
      productID: productID,
      key: "T2",
      state: .acceptance
    )
    let ordinaryItem = pollingWorkItem(
      productID: productID,
      key: "T3",
      state: .verifying
    )
    let now = Date(timeIntervalSince1970: 100)
    let ordinary = pollingPublication(
      productID: productID,
      connectionID: connectionID,
      accountID: accountID,
      workItemID: ordinaryItem.id,
      number: 3,
      status: .open,
      updatedAt: now
    )
    let ownerAction = pollingPublication(
      productID: productID,
      connectionID: connectionID,
      accountID: accountID,
      workItemID: ownerActionItem.id,
      number: 2,
      status: .openOutdated,
      updatedAt: now.addingTimeInterval(1)
    )
    let visible = pollingPublication(
      productID: productID,
      connectionID: connectionID,
      accountID: accountID,
      workItemID: visibleItem.id,
      number: 1,
      status: .openStale,
      updatedAt: now.addingTimeInterval(2)
    )
    let closed = pollingPublication(
      productID: productID,
      connectionID: connectionID,
      accountID: accountID,
      workItemID: ordinaryItem.id,
      number: 4,
      status: .closed,
      updatedAt: now.addingTimeInterval(3)
    )
    let workItems = [ordinaryItem, ownerActionItem, visibleItem]
    let ordered = GitHubPullRequestPollingPolicy.orderedPublications(
      [ordinary, ownerAction, visible, closed],
      workItems: workItems,
      visibleWorkItemIDs: [visibleItem.id]
    )
    #expect(ordered.map(\.id) == [visible.id, ownerAction.id, ordinary.id])
    #expect(
      GitHubPullRequestPollingPolicy.interval(
        isApplicationActive: true,
        publications: ordered,
        workItems: workItems,
        visibleWorkItemIDs: [visibleItem.id]
      ) == .seconds(60)
    )
    #expect(
      GitHubPullRequestPollingPolicy.interval(
        isApplicationActive: true,
        publications: [ordinary],
        workItems: workItems,
        visibleWorkItemIDs: []
      ) == .seconds(120)
    )
    #expect(
      GitHubPullRequestPollingPolicy.interval(
        isApplicationActive: false,
        publications: ordered,
        workItems: workItems,
        visibleWorkItemIDs: [visibleItem.id]
      ) == .seconds(300)
    )
  }

  private func pollingWorkItem(
    productID: UUID,
    key: String,
    state: WorkItemState
  ) -> WorkItem {
    WorkItem(
      productID: productID,
      key: key,
      title: key,
      state: state
    )
  }

  private func pollingPublication(
    productID: UUID,
    connectionID: UUID,
    accountID: UUID,
    workItemID: UUID,
    number: Int,
    status: RemotePublicationStatus,
    updatedAt: Date
  ) -> RemotePublication {
    let sha = String(repeating: "\(number)", count: 40)
    return RemotePublication(
      productID: productID,
      connectionID: connectionID,
      workItemID: workItemID,
      accountID: accountID,
      repositoryID: 1,
      owner: "example",
      name: "product",
      fullName: "example/product",
      canonicalHTTPSURL: URL(string: "https://github.com/example/product.git")!,
      isPrivate: true,
      permissions: RemoteRepositoryPermissions(
        metadataRead: true,
        contentsWrite: true,
        pullRequestsWrite: true,
        workflowsWrite: true
      ),
      capturedLocalSHA: sha,
      capturedLocalTree: sha,
      remoteBaseSHA: sha,
      remoteBaseTree: sha,
      targetBranch: "main",
      publicationBranch: "spedito/\(number)",
      manifestDigest: sha,
      manifestObjectCount: 1,
      manifestCommitCount: 1,
      manifestPathCount: 1,
      commits: [],
      paths: ["README.md"],
      title: "Ticket \(number)",
      body: "Body",
      status: status,
      pushedSHA: sha,
      pullRequest: RemotePullRequestSnapshot(
        number: number,
        nodeID: "PR_\(number)",
        canonicalURL: URL(string: "https://github.com/example/product/pull/\(number)")!,
        state: status == .closed ? .closed : .open,
        isDraft: true,
        headSHA: sha,
        baseBranch: "main",
        baseSHA: sha,
        mergedSHA: nil,
        updatedAt: updatedAt
      ),
      createdAt: updatedAt,
      updatedAt: updatedAt
    )
  }
}

private actor AppModelRemoteService: GitHubRemoteRepositoryServing {
  private var currentState = GitHubRemoteRepositoryState(isConfigured: true)
  private var connectionContinuation: CheckedContinuation<Void, Never>?
  private var shouldFailChecks = false
  private(set) var checkCount = 0
  private(set) var prepareSafeSyncCount = 0
  private(set) var preparePublicationCount = 0
  private(set) var didPresentPrompt = false
  private(set) var didAuthorizeImport = false
  private(set) var didShutdown = false
  private(set) var selectionCount = 0
  private(set) var refreshRepositoryCount = 0
  private var initializationContinuation: CheckedContinuation<Void, Never>?
  private var shouldPauseInitialization = false
  private(set) var didStartInitialization = false
  private var nextImportError: ProductRepositoryImportError?
  private(set) var connectedLocalProductID: UUID?
  private(set) var connectedLocalRepositoryID: Int64?

  func state(productID: UUID) async -> GitHubRemoteRepositoryState {
    _ = productID
    return currentState
  }

  func importRepositories() async throws -> GitHubRepositoryImportCatalog {
    let repository = GitHubRepository(
      id: 99,
      owner: "example",
      name: "importable",
      fullName: "example/importable",
      htmlURL: URL(string: "https://github.com/example/importable")!,
      canonicalHTTPSURL: URL(string: "https://github.com/example/importable.git")!,
      isPrivate: true,
      defaultBranch: "main"
    )
    return GitHubRepositoryImportCatalog(
      installations: [
        GitHubInstallation(
          id: 41,
          accountLogin: "example",
          repositorySelection: "selected",
          permissions: GitHubInstallationPermissions(metadata: "read")
        )
      ],
      choices: [
        GitHubRepositoryChoice(
          installationID: 41,
          repository: repository,
          permissions: RemoteRepositoryPermissions(
            metadataRead: true,
            contentsWrite: true,
            pullRequestsWrite: true,
            workflowsWrite: true
          )
        )
      ]
    )
  }

  func authorizeImport(
    onPrompt: @escaping @Sendable (GitHubDeviceAuthorizationPrompt) async -> Void
  ) async throws -> GitHubRepositoryImportCatalog {
    didAuthorizeImport = true
    await onPrompt(
      GitHubDeviceAuthorizationPrompt(
        userCode: "IMPORT-1",
        verificationURL: URL(string: "https://github.com/login/device")!,
        expiresAt: Date().addingTimeInterval(900)
      )
    )
    return try await importRepositories()
  }
  func importProduct(
    name: String,
    repositoryID: Int64,
    importer:
      @escaping @Sendable (
        PublicGitRepositoryURL,
        GitCredentialSessionConfiguration
      ) async throws -> ImportedProduct
  ) async throws -> ImportedProduct {
    _ = (name, repositoryID, importer)
    if let nextImportError {
      self.nextImportError = nil
      throw nextImportError
    }
    throw GitHubRemoteRepositoryServiceError.unavailable("Not used by this test.")
  }

  func failNextImport(with error: ProductRepositoryImportError) {
    nextImportError = error
  }

  func connectLocalProduct(
    productID: UUID,
    repositoryID: Int64
  ) async throws -> GitHubRemoteRepositoryState {
    connectedLocalProductID = productID
    connectedLocalRepositoryID = repositoryID
    currentState = GitHubRemoteRepositoryState(
      isConfigured: true,
      connection: connection(productID: productID, status: .connected)
    )
    return currentState
  }

  func connect(
    productID: UUID,
    onPrompt: @escaping @Sendable (GitHubDeviceAuthorizationPrompt) async -> Void
  ) async throws -> GitHubRemoteRepositoryState {
    await onPrompt(
      GitHubDeviceAuthorizationPrompt(
        userCode: "ABCD-EFGH",
        verificationURL: URL(string: "https://github.com/login/device")!,
        expiresAt: Date().addingTimeInterval(900)
      )
    )
    didPresentPrompt = true
    await withCheckedContinuation { continuation in
      connectionContinuation = continuation
    }
    currentState = GitHubRemoteRepositoryState(
      isConfigured: true,
      connection: connection(productID: productID, status: .selectingRepository)
    )
    return currentState
  }

  func setRelationship(
    productID: UUID,
    relationship: RemoteRepositoryRelationship
  ) {
    currentState = GitHubRemoteRepositoryState(
      isConfigured: true,
      connection: connection(
        productID: productID,
        status: .connected,
        relationship: relationship
      )
    )
  }

  func completeConnection() {
    connectionContinuation?.resume()
    connectionContinuation = nil
  }

  func failChecks() {
    shouldFailChecks = true
  }

  func pauseNextInitialization() {
    shouldPauseInitialization = true
  }

  func completeInitialization() {
    shouldPauseInitialization = false
    initializationContinuation?.resume()
    initializationContinuation = nil
  }

  func prepareRelaunchedSetup(productID: UUID) {
    currentState = GitHubRemoteRepositoryState(
      isConfigured: true,
      connection: connection(productID: productID, status: .selectingRepository)
    )
  }

  func cancelConnection(productID: UUID) async throws -> GitHubRemoteRepositoryState {
    completeConnection()
    currentState = GitHubRemoteRepositoryState(
      isConfigured: true,
      connection: connection(productID: productID, status: .disconnected)
    )
    return currentState
  }

  func disconnect(productID: UUID) async throws -> GitHubRemoteRepositoryState {
    try await cancelConnection(productID: productID)
  }

  func signOut(accountID: UUID) async throws {
    _ = accountID
  }

  func selectLocalRepository(
    productID: UUID,
    repositoryID: Int64
  ) async throws -> GitHubRemoteRepositoryState {
    _ = repositoryID
    selectionCount += 1
    currentState = GitHubRemoteRepositoryState(
      isConfigured: true,
      connection: connection(productID: productID, status: .selectingRepository)
    )
    return currentState
  }

  func refreshRepositories(productID: UUID) async throws -> GitHubRemoteRepositoryState {
    refreshRepositoryCount += 1
    let repository = GitHubRepository(
      id: 91,
      owner: "example",
      name: "product",
      fullName: "example/product",
      htmlURL: URL(string: "https://github.com/example/product")!,
      canonicalHTTPSURL: URL(string: "https://github.com/example/product.git")!,
      isPrivate: true,
      defaultBranch: "main"
    )
    currentState = GitHubRemoteRepositoryState(
      isConfigured: true,
      connection: connection(productID: productID, status: .selectingRepository),
      repositories: [
        GitHubRepositoryChoice(
          installationID: 1,
          repository: repository,
          permissions: RemoteRepositoryPermissions(
            metadataRead: true,
            contentsWrite: true,
            pullRequestsWrite: true,
            workflowsWrite: true
          )
        )
      ]
    )
    return currentState
  }

  func initializeLocalRepository(productID: UUID) async throws -> GitHubRemoteRepositoryState {
    currentState = GitHubRemoteRepositoryState(
      isConfigured: true,
      connection: connection(productID: productID, status: .connected)
    )
    return currentState
  }

  func initializeLocalRepository(
    productID: UUID,
    onProgress:
      @escaping @Sendable (
        GitHubRemoteRepositoryInitializationProgress
      ) async -> Void
  ) async throws -> GitHubRemoteRepositoryState {
    didStartInitialization = true
    await onProgress(.validatingProduct)
    if shouldPauseInitialization {
      await withCheckedContinuation { continuation in
        initializationContinuation = continuation
      }
      shouldPauseInitialization = false
    }
    await onProgress(.publishingBootstrap)
    return try await initializeLocalRepository(productID: productID)
  }

  func confirmTarget(
    productID: UUID,
    expectedVersion: Int,
    pendingObservedAt: Date
  ) async throws -> GitHubRemoteRepositoryState {
    _ = (productID, expectedVersion, pendingObservedAt)
    return currentState
  }

  func check(productID: UUID) async throws -> GitHubRemoteRepositoryState {
    checkCount += 1
    _ = productID
    if shouldFailChecks {
      throw GitHubRemoteRepositoryServiceError.unavailable(
        "GitHub is temporarily unavailable."
      )
    }
    return currentState
  }

  func prepareSafeSync(productID: UUID) async throws -> GitHubRemoteRepositoryState {
    prepareSafeSyncCount += 1
    _ = productID
    return currentState
  }

  func acceptSafeSync(syncID: UUID) async throws -> GitHubRemoteRepositoryState {
    _ = syncID
    return currentState
  }

  func rejectSafeSync(syncID: UUID) async throws -> GitHubRemoteRepositoryState {
    _ = syncID
    return currentState
  }

  func preparePublication(productID: UUID) async throws -> GitHubRemoteRepositoryState {
    preparePublicationCount += 1
    _ = productID
    return currentState
  }

  func cancelPublication(id: UUID) async throws -> GitHubRemoteRepositoryState {
    _ = id
    return currentState
  }

  func confirmPublication(
    id: UUID,
    title: String,
    body: String
  ) async throws -> GitHubRemoteRepositoryState {
    _ = (id, title, body)
    return currentState
  }

  func finishPullRequest(
    id: UUID,
    title: String,
    body: String
  ) async throws -> GitHubRemoteRepositoryState {
    _ = (id, title, body)
    return currentState
  }

  func refreshPullRequest(publicationID: UUID) async throws -> GitHubRemoteRepositoryState {
    _ = publicationID
    return currentState
  }

  func recover(productID: UUID) async {
    _ = productID
  }

  func shutdown() async {
    didShutdown = true
    completeConnection()
  }

  private func connection(
    productID: UUID,
    status: RemoteRepositoryConnectionStatus,
    relationship: RemoteRepositoryRelationship? = nil
  ) -> RemoteRepositoryConnection {
    RemoteRepositoryConnection(
      productID: productID,
      kind: .localEmptyRepository,
      accountID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
      installationID: 1,
      repositoryID: 91,
      owner: "example",
      name: "product",
      fullName: "example/product",
      canonicalHTTPSURL: URL(string: "https://github.com/example/product.git"),
      isPrivate: true,
      defaultBranch: "main",
      permissions: RemoteRepositoryPermissions(
        metadataRead: true,
        contentsWrite: true,
        pullRequestsWrite: true,
        workflowsWrite: true
      ),
      status: status,
      latestLocalSHA: String(repeating: "1", count: 40),
      latestLocalTree: String(repeating: "2", count: 40),
      latestRemoteSHA: String(repeating: "3", count: 40),
      latestRemoteTree: String(repeating: "4", count: 40),
      latestRelationship: relationship
    )
  }
}
