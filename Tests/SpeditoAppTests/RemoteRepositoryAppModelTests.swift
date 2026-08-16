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
      remoteRepositoryFeature: RemoteRepositoryFeatureModel(service: service)
    )
    await model.reload()
    await model.sendRepositoryImportCommand(.loadAuthorizedRepositories)
    #expect(
      model.repositoryImportSnapshot.catalog.choices.map(\.repository.fullName)
        == ["example/importable"]
    )
    #expect(model.repositoryImportSnapshot.catalog.installations.map(\.id) == [41])
    #expect(model.repositoryImportSnapshot.failure == nil)
    await model.sendRepositoryImportCommand(.authorizeGitHub)
    #expect(await service.didAuthorizeImport)
    #expect(
      model.repositoryImportSnapshot.catalog.choices.first?.repository.isPrivate == true
    )

    let connectionTask = Task {
      await model.connectGitHub(productID: product.id)
    }
    await service.waitForConnectionStart()
    #expect(
      model.remoteRepositorySnapshot(for: product.id).authorizationPrompt?.userCode == "ABCD-EFGH")
    #expect(model.remoteRepositorySnapshot(for: product.id).isBusy)

    let queuedSelection = Task {
      await model.selectLocalGitHubRepository(productID: product.id, repositoryID: 91)
    }
    await service.completeConnection()
    await connectionTask.value
    await queuedSelection.value
    #expect(await service.selectionCount == 1)
    #expect(model.remoteRepositorySnapshot(for: product.id).authorizationPrompt == nil)
    #expect(
      model.remoteRepositorySnapshotIfLoaded(for: product.id)?.repositoryState.connection?.status
        == .selectingRepository
    )
    #expect(!model.remoteRepositorySnapshot(for: product.id).isBusy)

    await service.pauseNextInitialization()
    let initializationTask = Task {
      await model.initializeLocalGitHubRepository(productID: product.id)
    }
    await service.waitForInitializationStart()
    #expect(
      model.remoteRepositorySnapshot(for: product.id).setupActivity
        == .inProgress(progress: .validatingProduct, publishesExistingHistory: false)
    )
    #expect(
      !GitHubRepositoryPickerDismissalPolicy.canDismiss(
        activity: model.remoteRepositorySnapshot(for: product.id).setupActivity
      )
    )
    await service.completeInitialization()
    await initializationTask.value
    #expect(
      model.remoteRepositorySnapshotIfLoaded(for: product.id)?.repositoryState.connection?.status
        == .connected
    )
    #expect(
      model.remoteRepositorySnapshot(for: product.id).setupActivity
        == .completed(publishedExistingHistory: false)
    )
    #expect(
      GitHubRepositoryPickerDismissalPolicy.canDismiss(
        activity: model.remoteRepositorySnapshot(for: product.id).setupActivity
      )
    )

    await service.failChecks()
    await model.checkRemoteRepository(productID: product.id)
    #expect(
      model.remoteRepositorySnapshot(for: product.id).failure?.message
        == "GitHub is temporarily unavailable.")
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
      remoteRepositoryFeature: RemoteRepositoryFeatureModel(service: service)
    )
    await model.reload()

    #expect(
      model.remoteRepositorySnapshotIfLoaded(for: product.id)?.repositoryState.repositories.isEmpty
        == true
    )
    await model.resumeLocalGitHubRepositorySetup(productID: product.id)
    #expect(await service.refreshRepositoryCount == 1)
    #expect(await service.selectionCount == 1)

    await model.shutdown()
    await store.close()
  }

  @Test("Archived Products require restoration before remote recovery resumes")
  func archivedProductRemoteWorkIsSuspendedUntilRestore() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Spedito-AppModel-Archived-Remote-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Archived remote Product")
    let service = AppModelRemoteService()
    await service.setState(
      GitHubRemoteRepositoryState(
        isConfigured: true,
        connection: RemoteRepositoryConnection(
          productID: product.id,
          kind: .importedSource,
          status: .connected
        )
      )
    )
    let model = AppModel(
      store: store,
      selectedProductID: product.id,
      remoteRepositoryFeature: RemoteRepositoryFeatureModel(service: service)
    )
    await model.reload()

    #expect(await model.archiveSelectedProduct())
    let archived = try #require(model.archivedProducts.first { $0.id == product.id })
    await model.checkRemoteRepository(productID: product.id)
    #expect(await service.checkCount == 0)
    #expect(
      model.remoteRepositorySnapshot(for: product.id).failure?.message
        == "Restore this Product before resuming its GitHub repository work."
    )

    #expect(await model.restoreProductAndSelect(archived))
    await service.waitForRecovery()
    #expect(await service.recoveryCount == 1)

    await model.shutdown()
    await store.close()
  }

  /// Existing partial coverage:
  /// - `RepositoryImportCoordinatorTests.emptyAuthorizedRepository`
  /// - `RemoteRepositoryServiceTests.localProductLifecycle`
  /// - `ProductScopedPersistenceTests.a02BlankProductCreationActivatesLocalWorkspace`
  /// This test covers only R05's composition from empty-import result through exact-target setup.
  @Test("R05 an empty GitHub repository creates and connects a blank Product")
  func r05EmptyGitHubRepositoryCreation() async throws {
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
    let model = AppModel(
      storeRegistry: registry,
      remoteRepositoryFeature: RemoteRepositoryFeatureModel(service: service)
    )
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
    let remoteState = model.remoteRepositorySnapshot(for: product.id)
    #expect(remoteState.repositoryState.connection?.productID == product.id)
    #expect(remoteState.repositoryState.connection?.repositoryID == 99)
    #expect(remoteState.repositoryState.connection?.defaultBranch == "main")
    #expect(remoteState.repositoryState.connection?.status == .connected)
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

  @Test("Blank Product creation remains independent of repository import")
  func blankProductCreation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Spedito-AppModel-Blank-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: root.appendingPathComponent(
        "Product Workspaces",
        isDirectory: true
      )
    )
    let model = AppModel(storeRegistry: registry)
    await model.reload()

    #expect(await model.createProductAndSelect(.blank(name: "Blank Product")))

    let product = try #require(model.products.first { $0.name == "Blank Product" })
    #expect(model.selectedProductID == product.id)
    #expect(model.repositoryImportSnapshot.phase == .idle)
    #expect(
      FileManager.default.fileExists(
        atPath: registry.productWorkspacesRootURL
          .appendingPathComponent(product.id.uuidString, isDirectory: true)
          .appendingPathComponent(".git", isDirectory: true)
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
    let model = AppModel(
      storeRegistry: registry,
      remoteRepositoryFeature: RemoteRepositoryFeatureModel(service: service)
    )
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
          reviewerProfileID: nil,
          estimatedTokens: 1
        )
      ]
    )
    let service = AppModelRemoteService()
    await service.setRelationship(productID: product.id, relationship: .remoteAhead)
    let model = AppModel(
      store: store,
      selectedProductID: product.id,
      remoteRepositoryFeature: RemoteRepositoryFeatureModel(service: service)
    )
    await model.reload()

    #expect(await model.startSprint())
    #expect(try await store.fetchCurrentSprint(productID: product.id)?.sprint.state == .active)
    #expect(await service.checkCount == 0)
    #expect(model.errorMessage == nil)

    await model.prepareIncomingRepositoryChange(productID: product.id)
    #expect(await service.prepareSafeSyncCount == 0)
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

  @Test("Product settings hides a routine up-to-date repository status")
  func repositoryRelationshipVisibility() {
    #expect(
      !GitHubRepositoryRelationshipVisibility.showsStatus(for: .aligned)
    )
    for relationship in [
      RemoteRepositoryRelationship.localAhead,
      .remoteAhead,
      .historyAlignmentAvailable,
      .diverged,
      .unrelated,
    ] {
      #expect(
        GitHubRepositoryRelationshipVisibility.showsStatus(for: relationship)
      )
    }
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

  @Test("Product archival blocks only remote side effects that cannot pause safely")
  func remoteArchivePolicy() {
    let policy = RemoteProductArchivePolicy()
    let productID = UUID()
    let connectionID = UUID()
    let accountID = UUID()

    for status in [
      RemoteRepositoryConnectionStatus.selectingRepository,
      .initializingRemote,
      .connected,
      .disconnected,
      .needsAuthorization,
      .needsInstallation,
      .needsTargetReview,
      .unavailable,
    ] {
      let state = GitHubRemoteRepositoryState(
        isConfigured: true,
        connection: RemoteRepositoryConnection(
          id: connectionID,
          productID: productID,
          kind: .localEmptyRepository,
          status: status
        )
      )
      #expect(
        (policy.blockingReason(for: state) != nil)
          == (status == .initializingRemote)
      )
    }

    let sha = String(repeating: "1", count: 40)
    for status in [
      RemoteSafeSyncStatus.awaitingConfirmation,
      .accepting,
      .accepted,
      .rejected,
      .stale,
      .failed,
    ] {
      let state = GitHubRemoteRepositoryState(
        isConfigured: true,
        safeSync: RemoteSafeSync(
          productID: productID,
          connectionID: connectionID,
          connectionVersion: 1,
          kind: .fastForward,
          status: status,
          observationRef: "refs/spedito/observation",
          localSHA: sha,
          localTree: sha,
          remoteSHA: sha,
          remoteTree: sha,
          mergeBaseSHA: sha,
          candidateSHA: sha,
          candidateTree: sha
        )
      )
      #expect(
        (policy.blockingReason(for: state) != nil)
          == (status == .accepting)
      )
    }

    for (index, status) in [
      RemotePublicationStatus.awaitingConfirmation,
      .checking,
      .pushing,
      .branchPublished,
      .creatingPullRequest,
      .open,
      .openOutdated,
      .openStale,
      .merged,
      .closed,
      .cancelled,
      .stale,
      .failed,
    ].enumerated() {
      let publication = pollingPublication(
        productID: productID,
        connectionID: connectionID,
        accountID: accountID,
        workItemID: UUID(),
        number: index + 1,
        status: status,
        updatedAt: Date()
      )
      let state = GitHubRemoteRepositoryState(
        isConfigured: true,
        publications: [publication]
      )
      let shouldBlock =
        status == .checking || status == .pushing
        || status == .branchPublished || status == .creatingPullRequest
      #expect((policy.blockingReason(for: state) != nil) == shouldBlock)
    }
  }

  /// Existing partial coverage:
  /// - `RemoteRepositoryServiceTests.importedProductConnection`
  /// - `repositoryAttentionPolicy`
  /// This test covers only R12's explicit confirm-or-disconnect owner choice.
  @Test("R12 owner can confirm the newly observed target or disconnect")
  func r12ObservedTargetChoice() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-r12-\(UUID())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Observed target")
    let observedAt = Date(timeIntervalSince1970: 5_000)
    let pendingConnection = RemoteRepositoryConnection(
      productID: product.id,
      version: 7,
      kind: .importedSource,
      repositoryID: 11,
      owner: "example",
      name: "old",
      fullName: "example/old",
      canonicalHTTPSURL: URL(string: "https://github.com/example/old.git"),
      defaultBranch: "main",
      status: .needsTargetReview,
      pendingRepositoryID: 22,
      pendingFullName: "example/new",
      pendingCanonicalHTTPSURL: URL(string: "https://github.com/example/new.git"),
      pendingDefaultBranch: "trunk",
      pendingObservedAt: observedAt
    )
    let service = AppModelRemoteService()
    await service.setState(
      GitHubRemoteRepositoryState(
        isConfigured: true,
        connection: pendingConnection
      )
    )
    let model = AppModel(
      store: store,
      selectedProductID: product.id,
      remoteRepositoryFeature: RemoteRepositoryFeatureModel(service: service)
    )
    await model.reload()

    await model.confirmRemoteRepositoryTarget(
      productID: product.id,
      expectedVersion: pendingConnection.version,
      pendingObservedAt: observedAt
    )
    let confirmed = try #require(
      model.remoteRepositorySnapshot(for: product.id).repositoryState.connection
    )
    #expect(confirmed.repositoryID == 22)
    #expect(confirmed.fullName == "example/new")
    #expect(confirmed.defaultBranch == "trunk")
    #expect(confirmed.pendingRepositoryID == nil)
    #expect(confirmed.status == .connected)
    #expect(await service.confirmTargetCount == 1)

    await service.setState(
      GitHubRemoteRepositoryState(
        isConfigured: true,
        connection: pendingConnection
      )
    )
    await model.checkRemoteRepository(productID: product.id)
    await model.disconnectGitHub(productID: product.id)
    let disconnected = try #require(
      model.remoteRepositorySnapshot(for: product.id).repositoryState.connection
    )
    #expect(disconnected.status == .disconnected)
    #expect(await service.disconnectCount == 1)

    await model.shutdown()
    await store.close()
  }

  /// Existing partial coverage:
  /// - `RepositoryImportCoordinatorTests.publicImport`
  /// - `RepositoryImportKnowledgeTests.stagedRepositoryImport`
  /// This test covers only R01's application selection before durable understanding recovery.
  @Test("R01 imported Product opens before background repository understanding continues")
  func r01ImportedProductOpensBeforeUnderstandingContinues() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-r01-\(UUID())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: root.appendingPathComponent("products", isDirectory: true)
    )
    let activator = AppModelRepositoryImportActivator(registry: registry)
    let model = AppModel(
      storeRegistry: registry,
      repositoryImportActivator: activator
    )
    let source = try PublicGitRepositoryURL(
      "https://github.com/example/imported-product.git"
    )

    #expect(
      await model.createProductAndSelect(
        .importRepository(name: "Imported product", source: source)
      )
    )
    let product = try #require(model.selectedProduct)
    let store = try #require(registry.store(for: product.id))
    let repository = try #require(
      try await store.fetchProductRepository(productID: product.id)
    )
    let pendingRun = try #require(
      try await store.fetchLatestRepositoryKnowledgeRun(productID: product.id)
    )

    #expect(model.selectedProductID == product.id)
    #expect(model.workItems.isEmpty)
    #expect(repository.importedSHA == AppModelRepositoryImportActivator.importedSHA)
    #expect(pendingRun.status == .pendingAnalysis)

    await model.awaitRepositoryKnowledgeRecovery(productID: product.id)
    #expect(model.repositoryKnowledgeSnapshot?.productID == product.id)
    #expect(model.repositoryKnowledgeSnapshot?.run?.id == pendingRun.id)
    #expect(model.repositoryKnowledgeSnapshot?.isActive == true)

    await model.shutdown()
    for productStore in registry.allStores {
      await productStore.close()
    }
  }

  /// Existing partial coverage:
  /// - `RemoteRepositoryServiceTests.localProductLifecycle`
  /// - `RemoteProductArchivePolicy` status coverage
  /// - `RemoteRepositoryFeatureModelTests.recovery`
  /// This test covers only R13's AppModel review commands and relaunched recovery composition.
  @Test("R13 incoming changes accept reject and recover after interruption")
  func r13IncomingReviewAndInterruptedRecovery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-r13-\(UUID())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Incoming review")
    let acceptedSyncID = UUID()
    let rejectedSyncID = UUID()
    let interruptedSyncID = UUID()
    func state(_ status: RemoteSafeSyncStatus, syncID: UUID) -> GitHubRemoteRepositoryState {
      let sha = String(repeating: "a", count: 40)
      return GitHubRemoteRepositoryState(
        isConfigured: true,
        safeSync: RemoteSafeSync(
          id: syncID,
          productID: product.id,
          connectionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
          connectionVersion: 1,
          kind: .fastForward,
          status: status,
          observationRef: "refs/spedito/observation",
          localSHA: sha,
          localTree: sha,
          remoteSHA: sha,
          remoteTree: sha,
          mergeBaseSHA: sha,
          candidateSHA: sha,
          candidateTree: sha
        )
      )
    }

    let service = AppModelRemoteService()
    let model = AppModel(
      store: store,
      selectedProductID: product.id,
      remoteRepositoryFeature: RemoteRepositoryFeatureModel(service: service)
    )
    await model.reload()
    await service.setAcceptState(state(.accepted, syncID: acceptedSyncID))
    await model.acceptIncomingRepositoryChange(
      productID: product.id,
      syncID: acceptedSyncID
    )
    #expect(await service.acceptedSafeSyncIDs == [acceptedSyncID])
    #expect(
      model.remoteRepositorySnapshot(for: product.id).repositoryState.safeSync?.status
        == .accepted
    )

    await service.setRejectState(state(.rejected, syncID: rejectedSyncID))
    await model.rejectIncomingRepositoryChange(
      productID: product.id,
      syncID: rejectedSyncID
    )
    #expect(await service.rejectedSafeSyncIDs == [rejectedSyncID])
    #expect(
      model.remoteRepositorySnapshot(for: product.id).repositoryState.safeSync?.status
        == .rejected
    )
    await model.shutdown()

    let relaunchedService = AppModelRemoteService()
    await relaunchedService.setState(state(.accepting, syncID: interruptedSyncID))
    await relaunchedService.setRecoveryState(state(.accepted, syncID: interruptedSyncID))
    let relaunched = AppModel(
      store: store,
      selectedProductID: product.id,
      remoteRepositoryFeature: RemoteRepositoryFeatureModel(service: relaunchedService)
    )
    await relaunched.load()
    await relaunchedService.waitForRecovery()

    #expect(await relaunchedService.recoveryCount == 1)
    #expect(
      relaunched.remoteRepositorySnapshot(for: product.id).repositoryState.safeSync?.id
        == interruptedSyncID
    )
    #expect(
      relaunched.remoteRepositorySnapshot(for: product.id).repositoryState.safeSync?.status
        == .accepted
    )
    await relaunched.shutdown()
    await store.close()
  }

  /// Existing partial coverage:
  /// - `RemoteRepositoryServiceTests.localProductLifecycle`
  /// This test covers only D13's remote-sync callback into the durable delivery transition.
  @Test("D13 requested GitHub changes resume the same published ticket branch")
  func d13RequestedChangesResumePublishedTicket() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-d13-\(UUID())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let workspaces = root.appendingPathComponent("workspaces", isDirectory: true)
    try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
    let registry = try ProductStoreRegistry(productWorkspacesRootURL: workspaces)
    let product = try await registry.createProduct(name: "Remote review changes")
    let store = try #require(registry.store(for: product.id))
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let reviewer = try #require(profiles.first { $0.role == .lead })
    var item = try await store.createWorkItem(
      productID: product.id,
      title: "Address bounded GitHub feedback",
      acceptanceCriteria: ["Requested changes resume the same publication branch."]
    )
    item = try await store.transitionWorkItem(
      id: item.id,
      to: .refining,
      actor: "Business analyst",
      reason: "Refine"
    )
    item = try await store.transitionWorkItem(
      id: item.id,
      to: .ready,
      actor: "Product owner",
      reason: "Ready"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Address review feedback",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: item.id,
          implementerProfileID: implementer.id,
          reviewerProfileID: reviewer.id,
          estimatedTokens: 1
        )
      ]
    )
    _ = try await store.startSprint(id: draft.sprint.id)
    let implementationRun = try #require(
      try await store.fetchAgentRuns(productID: product.id).first
    )
    _ = try await store.updateAgentRun(
      id: implementationRun.id,
      status: .completed,
      codexThreadID: "thread-d13-implementation",
      eventActor: implementer.name,
      eventDetail: "Candidate reviewed"
    )
    for state in [WorkItemState.running, .integrating, .verifying, .acceptance] {
      item = try await store.transitionWorkItem(
        id: item.id,
        to: state,
        actor: state == .acceptance ? reviewer.name : implementer.name,
        reason: "Prepare remote review"
      )
    }

    let publication = pollingPublication(
      productID: product.id,
      connectionID: UUID(),
      accountID: UUID(),
      workItemID: item.id,
      number: 13,
      status: .open,
      updatedAt: Date(timeIntervalSince1970: 13)
    )
    let remoteState = GitHubRemoteRepositoryState(
      isConfigured: true,
      publications: [publication]
    )
    let service = AppModelRemoteService()
    await service.setState(remoteState)
    await service.setPullRequestSync(
      GitHubTicketPullRequestSync(
        state: remoteState,
        workItemID: item.id,
        changesRequested: true,
        closedWithoutMerge: false
      )
    )
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id,
      remoteRepositoryFeature: RemoteRepositoryFeatureModel(service: service)
    )
    await model.load()

    await model.pollGitHubPullRequestsOnce(productID: product.id)

    let resumedItem = try #require(
      try await store.fetchWorkItems(productID: product.id).first { $0.id == item.id }
    )
    let resumedRun = try #require(
      try await store.fetchAgentRuns(productID: product.id)
        .first { $0.id == implementationRun.id }
    )
    let resumedPublication = try #require(
      model.remoteRepositorySnapshot(for: product.id).repositoryState.publication
    )
    let syncedPublicationIDs = await service.syncedPublicationIDs
    #expect(!syncedPublicationIDs.isEmpty)
    #expect(Set(syncedPublicationIDs) == [publication.id])
    #expect(resumedItem.state == .running)
    #expect(resumedRun.status == .queued)
    #expect(resumedRun.codexThreadID == "thread-d13-implementation")
    #expect(resumedPublication.id == publication.id)
    #expect(resumedPublication.publicationBranch == publication.publicationBranch)

    await model.shutdown()
    for productStore in registry.allStores {
      await productStore.close()
    }
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
      purpose: .ticket,
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

@Suite("Remote repository feature model", .serialized)
@MainActor
struct RemoteRepositoryFeatureModelTests {
  @Test("Loading, failure, owner retry, and product switches keep bounded snapshots")
  func snapshotLifecycle() async {
    let firstProductID = UUID()
    let secondProductID = UUID()
    let service = AppModelRemoteService()
    let feature = RemoteRepositoryFeatureModel(service: service)

    #expect(feature.snapshotIfLoaded(for: firstProductID) == nil)
    await service.setRelationship(productID: firstProductID, relationship: .aligned)
    await feature.load(productID: firstProductID)
    #expect(
      feature.snapshot(for: firstProductID).repositoryState.connection?.status == .connected
    )

    await service.failChecks()
    await feature.check(productID: firstProductID, isProductActive: true)
    #expect(
      feature.snapshot(for: firstProductID).failure?.message
        == "GitHub is temporarily unavailable."
    )
    #expect(!feature.snapshot(for: firstProductID).isBusy)

    await service.resumeChecks()
    await feature.check(productID: firstProductID, isProductActive: true)
    #expect(feature.snapshot(for: firstProductID).failure == nil)

    await service.prepareRelaunchedSetup(productID: secondProductID)
    await feature.load(productID: secondProductID)
    #expect(
      feature.snapshot(for: secondProductID).repositoryState.connection?.status
        == .selectingRepository
    )
    #expect(
      feature.snapshot(for: firstProductID).repositoryState.connection?.status == .connected
    )
    await feature.shutdown()
  }

  @Test("Cancellation clears pending presentation and shutdown settles live work")
  func cancellationAndShutdown() async {
    let productID = UUID()
    let service = AppModelRemoteService()
    let feature = RemoteRepositoryFeatureModel(service: service)

    let connection = Task {
      await feature.connect(productID: productID, isProductActive: true)
    }
    await service.waitForConnectionStart()
    #expect(feature.snapshot(for: productID).authorizationPrompt != nil)
    #expect(feature.snapshot(for: productID).isBusy)

    let cancellation = Task {
      await feature.cancelConnection(productID: productID, isProductActive: true)
    }
    await service.completeConnection()
    await cancellation.value
    await connection.value
    #expect(feature.snapshot(for: productID).authorizationPrompt == nil)

    await service.prepareForConnection()
    #expect(!feature.snapshot(for: productID).isBusy)
    #expect(feature.snapshot(for: productID).repositoryState.connection?.status == .disconnected)

    let liveConnection = Task {
      await feature.connect(productID: productID, isProductActive: true)
    }
    await service.waitForConnectionStart()
    await feature.shutdown()
    await liveConnection.value
    #expect(await service.didShutdown)
    #expect(!feature.snapshot(for: productID).isBusy)
  }

  @Test("Recovery is owned and settled by the feature model")
  func recovery() async {
    let productID = UUID()
    let service = AppModelRemoteService()
    let feature = RemoteRepositoryFeatureModel(service: service)

    feature.scheduleRecovery(productIDs: [productID])
    await service.waitForRecovery()
    await feature.shutdown()

    #expect(await service.recoveryCount == 1)
    #expect(await service.didShutdown)
  }

  @Test("Polling uses injected time and cancels on product and activity changes")
  func deterministicPollingLifecycle() async {
    let firstProductID = UUID()
    let secondProductID = UUID()
    let sleeper = TestRemotePollingSleeper()
    let feature = RemoteRepositoryFeatureModel(
      service: nil,
      pollingSleeper: sleeper
    )
    var selectedProductID = firstProductID

    feature.schedulePullRequestPolling(
      productID: firstProductID,
      workItems: { [] },
      isSelected: { $0 == selectedProductID },
      onSync: { _ in }
    )
    var intervals = await sleeper.waitForRequestCount(1)
    #expect(intervals == [.seconds(120)])

    selectedProductID = secondProductID
    feature.schedulePullRequestPolling(
      productID: secondProductID,
      workItems: { [] },
      isSelected: { $0 == selectedProductID },
      onSync: { _ in }
    )
    await sleeper.waitForCancellationCount(1)
    intervals = await sleeper.waitForRequestCount(2)
    #expect(intervals == [.seconds(120), .seconds(120)])

    feature.setApplicationActive(false)
    await sleeper.waitForCancellationCount(2)
    intervals = await sleeper.waitForRequestCount(3)
    #expect(intervals == [.seconds(120), .seconds(120), .seconds(300)])

    await feature.shutdown()
    await sleeper.waitForCancellationCount(3)
  }
  #if DEBUG
    @Test("Development catalog covers every remote owner-facing state")
    func presentationScenarioCatalog() {
      let scenarios = RemoteRepositoryPresentationScenarioCatalog.all
      let scenarioIDs = scenarios.map(\.id)

      #expect(Set(scenarioIDs) == Set(RemoteRepositoryPresentationScenarioID.allCases))
      #expect(scenarioIDs.count == Set(scenarioIDs).count)
      #expect(scenarios.allSatisfy { !$0.title.isEmpty })
      #expect(
        scenarios.first { $0.id == .waitingForDeviceFlow }?.snapshot.authorizationPrompt != nil
      )
      #expect(
        scenarios.first { $0.id == .publishingBootstrap }?.snapshot.setupActivity?.isInProgress
          == true
      )
      #expect(
        scenarios.first { $0.id == .incomingChangesAvailable }?.snapshot.repositoryState
          .observation?.relationship == .remoteAhead
      )
      #expect(
        scenarios.first { $0.id == .awaitingSafeSyncConfirmation }?.snapshot.repositoryState
          .safeSync?.status == .awaitingConfirmation
      )
      #expect(
        scenarios.first { $0.id == .pullRequestAwaitingReview }?.snapshot.repositoryState
          .publication?.pullRequest?.isDraft == true
      )
      #expect(
        scenarios.first { $0.id == .pullRequestReadyForApproval }?.snapshot.repositoryState
          .publication?.pullRequest?.isDraft == false
      )
      #expect(
        scenarios.first { $0.id == .retryableFailure }?.snapshot.failure?.kind == .operation
      )
    }
  #endif
}

private actor TestRemotePollingSleeper: RemoteRepositoryPollingSleeping {
  private var requests: [Duration] = []
  private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
  private var cancelledBeforeWaiting: Set<UUID> = []
  private var recordedCancellations: Set<UUID> = []
  private var cancellationCount = 0
  private var requestObservers: [Int: [CheckedContinuation<Void, Never>]] = [:]
  private var cancellationObservers: [Int: [CheckedContinuation<Void, Never>]] = [:]

  func sleep(for duration: Duration) async throws {
    let id = UUID()
    requests.append(duration)
    resumeSatisfiedRequestObservers()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        if cancelledBeforeWaiting.remove(id) != nil {
          continuation.resume(throwing: CancellationError())
        } else {
          waiters[id] = continuation
        }
      }
    } onCancel: {
      Task {
        await self.cancel(id: id)
      }
    }
  }

  func waitForRequestCount(_ count: Int) async -> [Duration] {
    if requests.count < count {
      await withCheckedContinuation { continuation in
        requestObservers[count, default: []].append(continuation)
      }
    }
    return requests
  }

  func waitForCancellationCount(_ count: Int) async {
    if cancellationCount < count {
      await withCheckedContinuation { continuation in
        cancellationObservers[count, default: []].append(continuation)
      }
    }
  }

  private func cancel(id: UUID) {
    guard recordedCancellations.insert(id).inserted else { return }
    cancellationCount += 1
    if let continuation = waiters.removeValue(forKey: id) {
      continuation.resume(throwing: CancellationError())
    } else {
      cancelledBeforeWaiting.insert(id)
    }
    resumeSatisfiedCancellationObservers()
  }

  private func resumeSatisfiedRequestObservers() {
    let satisfiedCounts = requestObservers.keys.filter { $0 <= requests.count }
    for count in satisfiedCounts {
      requestObservers.removeValue(forKey: count)?.forEach { $0.resume() }
    }
  }

  private func resumeSatisfiedCancellationObservers() {
    let satisfiedCounts = cancellationObservers.keys.filter { $0 <= cancellationCount }
    for count in satisfiedCounts {
      cancellationObservers.removeValue(forKey: count)?.forEach { $0.resume() }
    }
  }
}

@MainActor
private final class AppModelRepositoryImportActivator: RepositoryImportActivating {
  static let importedSHA = String(repeating: "a", count: 40)

  private let registry: ProductStoreRegistry

  init(registry: ProductStoreRegistry) {
    self.registry = registry
  }

  func importProduct(
    name: String,
    from source: PublicGitRepositoryURL,
    credentialConfiguration: GitCredentialSessionConfiguration?,
    onProgress: @escaping @Sendable (RepositoryImportActivationProgress) async -> Void
  ) async throws -> ImportedProduct {
    _ = credentialConfiguration
    await onProgress(.cloningAndStaging)
    let product = try await registry.createProduct(name: name)
    let store = try #require(registry.store(for: product.id))
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let analyzer = try #require(profiles.first { $0.role == .businessAnalyst })
    let reviewer = try #require(profiles.first { $0.role == .lead })
    let repository = ProductRepository(
      productID: product.id,
      originURL: source.url,
      sourceDefaultBranch: "main",
      importedSHA: Self.importedSHA
    )
    try await store.createProductRepository(repository)
    let run = RepositoryKnowledgeRun(
      productID: product.id,
      attempt: 1,
      purpose: .importedAppLaunch,
      analyzedSHA: Self.importedSHA,
      analyzerProfileID: analyzer.id,
      reviewerProfileID: reviewer.id
    )
    try await store.createRepositoryKnowledgeRun(run)
    await onProgress(.activatingProduct)
    return ImportedProduct(
      product: product,
      repository: repository,
      knowledgeRun: run
    )
  }
}

private actor AppModelRemoteService: GitHubRemoteRepositoryServing {
  private var currentState = GitHubRemoteRepositoryState(isConfigured: true)
  private var connectionContinuation: CheckedContinuation<Void, Never>?
  private var connectionStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var shouldFailChecks = false
  private(set) var checkCount = 0
  private(set) var prepareSafeSyncCount = 0
  private(set) var didPresentPrompt = false
  private(set) var didAuthorizeImport = false
  private(set) var didShutdown = false
  private(set) var selectionCount = 0
  private(set) var refreshRepositoryCount = 0
  private(set) var recoveryCount = 0
  private(set) var confirmTargetCount = 0
  private(set) var disconnectCount = 0
  private var recoveryContinuation: CheckedContinuation<Void, Never>?
  private var initializationContinuation: CheckedContinuation<Void, Never>?
  private var initializationStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var shouldPauseInitialization = false
  private(set) var didStartInitialization = false
  private var nextImportError: ProductRepositoryImportError?
  private(set) var connectedLocalProductID: UUID?
  private(set) var connectedLocalRepositoryID: Int64?
  private(set) var acceptedSafeSyncIDs: [UUID] = []
  private(set) var rejectedSafeSyncIDs: [UUID] = []
  private var acceptState: GitHubRemoteRepositoryState?
  private var rejectState: GitHubRemoteRepositoryState?
  private var recoveryState: GitHubRemoteRepositoryState?
  private var pullRequestSync: GitHubTicketPullRequestSync?
  private(set) var syncedPublicationIDs: [UUID] = []

  func state(productID: UUID) async -> GitHubRemoteRepositoryState {
    _ = productID
    return currentState
  }

  func setState(_ state: GitHubRemoteRepositoryState) {
    currentState = state
  }
  func setAcceptState(_ state: GitHubRemoteRepositoryState) {
    acceptState = state
  }

  func setRejectState(_ state: GitHubRemoteRepositoryState) {
    rejectState = state
  }

  func setRecoveryState(_ state: GitHubRemoteRepositoryState) {
    recoveryState = state
  }
  func setPullRequestSync(_ sync: GitHubTicketPullRequestSync) {
    pullRequestSync = sync
  }


  func waitForRecovery() async {
    if recoveryCount > 0 { return }
    await withCheckedContinuation { continuation in
      recoveryContinuation = continuation
    }
  }

  func waitForConnectionStart() async {
    if didPresentPrompt { return }
    await withCheckedContinuation { continuation in
      connectionStartWaiters.append(continuation)
    }
  }

  func waitForInitializationStart() async {
    if didStartInitialization { return }
    await withCheckedContinuation { continuation in
      initializationStartWaiters.append(continuation)
    }
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
      connection: connection(
        productID: productID,
        status: .connected,
        repositoryID: repositoryID
      )
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
    await withCheckedContinuation { continuation in
      connectionContinuation = continuation
      didPresentPrompt = true
      let waiters = connectionStartWaiters
      connectionStartWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
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

  func prepareForConnection() {
    didPresentPrompt = false
  }

  func failChecks() {
    shouldFailChecks = true
  }

  func resumeChecks() {
    shouldFailChecks = false
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
    disconnectCount += 1
    return try await cancelConnection(productID: productID)
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
    await onProgress(.validatingProduct)
    if shouldPauseInitialization {
      await withCheckedContinuation { continuation in
        initializationContinuation = continuation
        didStartInitialization = true
        let waiters = initializationStartWaiters
        initializationStartWaiters.removeAll()
        for waiter in waiters {
          waiter.resume()
        }
      }
      shouldPauseInitialization = false
    } else {
      didStartInitialization = true
      let waiters = initializationStartWaiters
      initializationStartWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
    }
    await onProgress(.publishingBootstrap)
    return try await initializeLocalRepository(productID: productID)
  }

  func confirmTarget(
    productID: UUID,
    expectedVersion: Int,
    pendingObservedAt: Date
  ) async throws -> GitHubRemoteRepositoryState {
    guard
      var connection = currentState.connection,
      connection.productID == productID,
      connection.version == expectedVersion,
      connection.pendingObservedAt == pendingObservedAt
    else {
      throw GitHubRemoteRepositoryServiceError.unavailable(
        "The observed repository target changed."
      )
    }
    confirmTargetCount += 1
    connection.version += 1
    connection.repositoryID = connection.pendingRepositoryID
    connection.fullName = connection.pendingFullName
    connection.canonicalHTTPSURL = connection.pendingCanonicalHTTPSURL
    connection.defaultBranch = connection.pendingDefaultBranch
    connection.pendingRepositoryID = nil
    connection.pendingFullName = nil
    connection.pendingCanonicalHTTPSURL = nil
    connection.pendingDefaultBranch = nil
    connection.pendingObservedAt = nil
    connection.status = .connected
    currentState = GitHubRemoteRepositoryState(
      isConfigured: currentState.isConfigured,
      connection: connection,
      repositories: currentState.repositories,
      selectedEligibility: currentState.selectedEligibility,
      observation: currentState.observation,
      safeSync: currentState.safeSync,
      publications: currentState.publications,
      errorMessage: currentState.errorMessage
    )
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

  func prepareTicketIntegration(
    productID: UUID
  ) async throws -> GitHubTicketIntegrationPreparation {
    GitHubTicketIntegrationPreparation(
      state: try await check(productID: productID),
      base: nil
    )
  }

  func prepareSafeSync(productID: UUID) async throws -> GitHubRemoteRepositoryState {
    prepareSafeSyncCount += 1
    _ = productID
    return currentState
  }

  func acceptSafeSync(syncID: UUID) async throws -> GitHubRemoteRepositoryState {
    acceptedSafeSyncIDs.append(syncID)
    if let acceptState {
      currentState = acceptState
      self.acceptState = nil
    }
    return currentState
  }

  func rejectSafeSync(syncID: UUID) async throws -> GitHubRemoteRepositoryState {
    rejectedSafeSyncIDs.append(syncID)
    if let rejectState {
      currentState = rejectState
      self.rejectState = nil
    }
    return currentState
  }

  func prepareTicketPullRequest(
    productID: UUID,
    workItemID: UUID,
    candidateRevisionID: UUID
  ) async throws -> GitHubRemoteRepositoryState {
    _ = (productID, workItemID, candidateRevisionID)
    throw GitHubRemoteRepositoryServiceError.unavailable(
      "Ticket pull requests are unavailable in this test."
    )
  }

  func markTicketPullRequestReady(
    publicationID: UUID
  ) async throws -> GitHubRemoteRepositoryState {
    _ = publicationID
    throw GitHubRemoteRepositoryServiceError.unavailable(
      "Ticket pull requests are unavailable in this test."
    )
  }

  func returnTicketPullRequestToDraft(
    publicationID: UUID
  ) async throws -> GitHubRemoteRepositoryState {
    _ = publicationID
    throw GitHubRemoteRepositoryServiceError.unavailable(
      "Ticket pull requests are unavailable in this test."
    )
  }

  func syncTicketPullRequest(
    publicationID: UUID
  ) async throws -> GitHubTicketPullRequestSync {
    guard let pullRequestSync else {
      throw GitHubRemoteRepositoryServiceError.unavailable(
        "Ticket pull requests are unavailable in this test."
      )
    }
    syncedPublicationIDs.append(publicationID)
    currentState = pullRequestSync.state
    return pullRequestSync
  }

  func mergeTicketPullRequest(
    publicationID: UUID
  ) async throws -> GitHubTicketPullRequestMergeResult {
    _ = publicationID
    throw GitHubRemoteRepositoryServiceError.unavailable(
      "Ticket pull requests are unavailable in this test."
    )
  }

  func refreshPullRequest(publicationID: UUID) async throws -> GitHubRemoteRepositoryState {
    _ = publicationID
    return currentState
  }

  func recover(productID: UUID) async {
    _ = productID
    recoveryCount += 1
    if let recoveryState {
      currentState = recoveryState
      self.recoveryState = nil
    }
    recoveryContinuation?.resume()
    recoveryContinuation = nil
  }

  func shutdown() async {
    didShutdown = true
    completeConnection()
  }

  private func connection(
    productID: UUID,
    status: RemoteRepositoryConnectionStatus,
    repositoryID: Int64 = 91,
    relationship: RemoteRepositoryRelationship? = nil
  ) -> RemoteRepositoryConnection {
    RemoteRepositoryConnection(
      productID: productID,
      kind: .localEmptyRepository,
      accountID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
      installationID: 1,
      repositoryID: repositoryID,
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
