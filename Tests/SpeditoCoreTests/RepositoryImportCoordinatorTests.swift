import Foundation
import Testing

@testable import SpeditoCore

@Suite("Repository import coordinator", .serialized)
@MainActor
struct RepositoryImportCoordinatorTests {
  @Test("Public import reports bounded phases and exact activated provenance")
  func publicImport() async throws {
    let imported = importedProduct(name: "Public Product")
    let activator = ImportActivatorFake(imported: imported)
    let recorder = RepositoryImportSnapshotRecorder()
    let coordinator = makeCoordinator(activator: activator, recorder: recorder)
    let source = try PublicGitRepositoryURL("https://github.com/example/public.git")
    let command = RepositoryImportCommand.importPublic(
      name: imported.product.name,
      source: source
    )

    let completion = try #require(await coordinator.send(command))

    #expect(completion.product == imported.product)
    #expect(
      completion.provenance
        == .imported(
          repository: imported.repository,
          knowledgeRunID: imported.knowledgeRun.id
        )
    )
    #expect(activator.callCount == 1)
    #expect(
      recorder.snapshots.map(\.phase) == [
        .cloningAndStaging,
        .cloningAndStaging,
        .activatingProduct,
        .completed(completion),
      ]
    )
  }

  @Test("Authorized private import keeps credentials inside the activation boundary")
  func authorizedImport() async throws {
    let imported = importedProduct(name: "Private Product")
    let activator = ImportActivatorFake(imported: imported)
    let sourceResolver = RepositoryImportSourceFake()
    let recorder = RepositoryImportSnapshotRecorder()
    let coordinator = makeCoordinator(
      activator: activator,
      sourceResolver: sourceResolver,
      recorder: recorder
    )
    let command = RepositoryImportCommand.importAuthorized(
      name: imported.product.name,
      repositoryID: 42
    )

    let completion = try #require(await coordinator.send(command))

    #expect(completion.product == imported.product)
    #expect(await sourceResolver.requestedRepositoryIDs == [42])
    #expect(
      activator.credentialConfigurations
        == [GitCredentialSessionConfiguration(socketPath: "/tmp/spedito-import-test.sock")]
    )
    #expect(recorder.snapshots.last?.phase == .completed(completion))
  }

  @Test("Authorization cancellation is terminal and a later command can retry")
  func authorizationCancellationAndRetry() async throws {
    let activator = ImportActivatorFake(imported: importedProduct())
    let sourceResolver = RepositoryImportSourceFake()
    await sourceResolver.pauseNextAuthorization()
    let recorder = RepositoryImportSnapshotRecorder()
    let coordinator = makeCoordinator(
      activator: activator,
      sourceResolver: sourceResolver,
      recorder: recorder
    )

    let authorization = Task {
      await coordinator.send(.authorizeGitHub)
    }
    await sourceResolver.waitForAuthorizationStart()
    #expect((await coordinator.snapshot()).authorizationPrompt?.userCode == "IMPORT-TEST")

    await coordinator.cancel()
    #expect(await authorization.value == nil)
    #expect((await coordinator.snapshot()).phase == .cancelled)

    _ = await coordinator.send(.authorizeGitHub)
    let retried = await coordinator.snapshot()
    #expect(retried.phase == .idle)
    #expect(retried.catalog.choices.map(\.repository.id) == [42])
  }

  @Test("A repository disappearing after selection never reaches activation")
  func disappearingRepository() async throws {
    let activator = ImportActivatorFake(imported: importedProduct())
    let sourceResolver = RepositoryImportSourceFake()
    await sourceResolver.failNextImport(
      with: GitHubRemoteRepositoryServiceError.unavailable(
        "That GitHub repository is no longer available to Spedito."
      )
    )
    let recorder = RepositoryImportSnapshotRecorder()
    let coordinator = makeCoordinator(
      activator: activator,
      sourceResolver: sourceResolver,
      recorder: recorder
    )
    let command = RepositoryImportCommand.importAuthorized(
      name: "Missing Product",
      repositoryID: 42
    )

    #expect(await coordinator.send(command) == nil)

    #expect(activator.callCount == 0)
    let failure = try #require((await coordinator.snapshot()).failure)
    #expect(failure.retry == command)
    #expect(failure.message.contains("no longer available"))
  }

  @Test("An empty authorized repository uses one bounded blank activation")
  func emptyAuthorizedRepository() async throws {
    let activator = ImportActivatorFake(imported: importedProduct())
    let sourceResolver = RepositoryImportSourceFake()
    await sourceResolver.failNextImport(with: ProductRepositoryImportError.emptyDefaultBranch)
    let recorder = RepositoryImportSnapshotRecorder()
    let blankProduct = Product(name: "Empty Product")
    let emptyState = GitHubRemoteRepositoryState(isConfigured: true)
    var blankActivationCount = 0
    let coordinator = RepositoryImportCoordinator(
      activator: activator,
      sourceResolver: sourceResolver,
      blankProductActivator: { name, repositoryID in
        #expect(name == blankProduct.name)
        #expect(repositoryID == 42)
        blankActivationCount += 1
        return RepositoryImportCompletion(
          product: blankProduct,
          provenance: .emptyRepository(remoteState: emptyState)
        )
      },
      onSnapshot: recorder.record
    )
    let command = RepositoryImportCommand.importAuthorized(
      name: blankProduct.name,
      repositoryID: 42
    )

    let first = try #require(await coordinator.send(command))
    let repeated = try #require(await coordinator.send(command))

    #expect(first == repeated)
    #expect(blankActivationCount == 1)
    #expect(activator.callCount == 0)
    #expect(recorder.snapshots.last?.phase == .completed(first))
  }

  @Test("Selection changes cannot redirect an in-flight import completion")
  func selectionChangeDoesNotRetargetCompletion() async throws {
    let imported = importedProduct()
    let activator = ImportActivatorFake(imported: imported)
    activator.pauseNextImport()
    let coordinator = makeCoordinator(activator: activator)
    let source = try PublicGitRepositoryURL("https://github.com/example/product.git")
    let command = RepositoryImportCommand.importPublic(
      name: imported.product.name,
      source: source
    )
    var selectedProductID = UUID()

    let importTask = Task {
      await coordinator.send(command)
    }
    await activator.waitForImportStart()
    let independentlySelectedProductID = UUID()
    selectedProductID = independentlySelectedProductID
    activator.completeImport()
    let completion = try #require(await importTask.value)

    #expect(completion.product.id == imported.product.id)
    #expect(selectedProductID == independentlySelectedProductID)
    #expect(completion.product.id != selectedProductID)
  }

  @Test("Repeated completion reuses one activated Product and knowledge run")
  func repeatedCompletion() async throws {
    let imported = importedProduct()
    let activator = ImportActivatorFake(imported: imported)
    let coordinator = makeCoordinator(activator: activator)
    let source = try PublicGitRepositoryURL("https://github.com/example/product.git")
    let command = RepositoryImportCommand.importPublic(
      name: imported.product.name,
      source: source
    )

    let first = try #require(await coordinator.send(command))
    let repeated = try #require(await coordinator.send(command))

    #expect(first == repeated)
    #expect(activator.callCount == 1)
    #expect(
      first.provenance
        == .imported(
          repository: imported.repository,
          knowledgeRunID: imported.knowledgeRun.id
        )
    )
  }

  private func makeCoordinator(
    activator: ImportActivatorFake,
    sourceResolver: RepositoryImportSourceFake? = nil,
    recorder: RepositoryImportSnapshotRecorder = RepositoryImportSnapshotRecorder()
  ) -> RepositoryImportCoordinator {
    RepositoryImportCoordinator(
      activator: activator,
      sourceResolver: sourceResolver,
      blankProductActivator: { _, _ in
        throw GitHubRemoteRepositoryServiceError.unavailable("Blank activation was not expected.")
      },
      onSnapshot: recorder.record
    )
  }

  private func importedProduct(name: String = "Imported Product") -> ImportedProduct {
    let product = Product(name: name)
    let repository = ProductRepository(
      productID: product.id,
      originURL: URL(string: "https://github.com/example/product.git")!,
      sourceDefaultBranch: "main",
      importedSHA: String(repeating: "a", count: 40)
    )
    let run = RepositoryKnowledgeRun(
      productID: product.id,
      attempt: 1,
      analyzedSHA: repository.importedSHA,
      analyzerProfileID: UUID(),
      reviewerProfileID: UUID()
    )
    return ImportedProduct(product: product, repository: repository, knowledgeRun: run)
  }
}

@MainActor
private final class RepositoryImportSnapshotRecorder {
  private(set) var snapshots: [RepositoryImportSnapshot] = []

  func record(_ snapshot: RepositoryImportSnapshot) {
    snapshots.append(snapshot)
  }
}

@MainActor
private final class ImportActivatorFake: RepositoryImportActivating {
  let imported: ImportedProduct
  private(set) var callCount = 0
  private(set) var credentialConfigurations: [GitCredentialSessionConfiguration] = []
  private var shouldPauseNextImport = false
  private var importContinuation: CheckedContinuation<Void, Never>?
  private var importStartWaiters: [CheckedContinuation<Void, Never>] = []

  init(imported: ImportedProduct) {
    self.imported = imported
  }

  func pauseNextImport() {
    shouldPauseNextImport = true
  }

  func waitForImportStart() async {
    if importContinuation != nil { return }
    await withCheckedContinuation { continuation in
      importStartWaiters.append(continuation)
    }
  }

  func completeImport() {
    importContinuation?.resume()
    importContinuation = nil
  }

  func importProduct(
    name: String,
    from source: PublicGitRepositoryURL,
    credentialConfiguration: GitCredentialSessionConfiguration?,
    onProgress: @escaping @Sendable (RepositoryImportActivationProgress) async -> Void
  ) async throws -> ImportedProduct {
    _ = (name, source)
    callCount += 1
    if let credentialConfiguration {
      credentialConfigurations.append(credentialConfiguration)
    }
    await onProgress(.cloningAndStaging)
    if shouldPauseNextImport {
      shouldPauseNextImport = false
      await withCheckedContinuation { continuation in
        importContinuation = continuation
        let waiters = importStartWaiters
        importStartWaiters.removeAll()
        for waiter in waiters {
          waiter.resume()
        }
      }
    }
    await onProgress(.activatingProduct)
    return imported
  }
}

private actor RepositoryImportSourceFake: RepositoryImportSourceResolving {
  private let source = try! PublicGitRepositoryURL("https://github.com/example/private.git")
  private let credential = GitCredentialSessionConfiguration(
    socketPath: "/tmp/spedito-import-test.sock"
  )
  private var nextImportError: (any Error & Sendable)?
  private var shouldPauseAuthorization = false
  private var authorizationContinuation: CheckedContinuation<Void, Error>?
  private var authorizationStartWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var requestedRepositoryIDs: [Int64] = []

  func importRepositories() async throws -> GitHubRepositoryImportCatalog {
    catalog()
  }

  func authorizeImport(
    onPrompt: @escaping @Sendable (GitHubDeviceAuthorizationPrompt) async -> Void
  ) async throws -> GitHubRepositoryImportCatalog {
    await onPrompt(
      GitHubDeviceAuthorizationPrompt(
        userCode: "IMPORT-TEST",
        verificationURL: URL(string: "https://github.com/login/device")!,
        expiresAt: Date().addingTimeInterval(900)
      )
    )
    if shouldPauseAuthorization {
      shouldPauseAuthorization = false
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          authorizationContinuation = continuation
          let waiters = authorizationStartWaiters
          authorizationStartWaiters.removeAll()
          for waiter in waiters {
            waiter.resume()
          }
        }
      } onCancel: {
        Task { await self.cancelAuthorization() }
      }
    }
    return catalog()
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
    _ = name
    requestedRepositoryIDs.append(repositoryID)
    if let nextImportError {
      self.nextImportError = nil
      throw nextImportError
    }
    return try await importer(source, credential)
  }

  func connectLocalProduct(
    productID: UUID,
    repositoryID: Int64
  ) async throws -> GitHubRemoteRepositoryState {
    _ = (productID, repositoryID)
    return GitHubRemoteRepositoryState(isConfigured: true)
  }

  func pauseNextAuthorization() {
    shouldPauseAuthorization = true
  }

  func waitForAuthorizationStart() async {
    if authorizationContinuation != nil { return }
    await withCheckedContinuation { continuation in
      authorizationStartWaiters.append(continuation)
    }
  }

  func failNextImport(with error: any Error & Sendable) {
    nextImportError = error
  }

  private func cancelAuthorization() {
    authorizationContinuation?.resume(throwing: CancellationError())
    authorizationContinuation = nil
  }

  private func catalog() -> GitHubRepositoryImportCatalog {
    GitHubRepositoryImportCatalog(
      installations: [
        GitHubInstallation(
          id: 7,
          accountLogin: "example",
          repositorySelection: "selected",
          permissions: GitHubInstallationPermissions(metadata: "read")
        )
      ],
      choices: [
        GitHubRepositoryChoice(
          installationID: 7,
          repository: GitHubRepository(
            id: 42,
            owner: "example",
            name: "private",
            fullName: "example/private",
            htmlURL: URL(string: "https://github.com/example/private")!,
            canonicalHTTPSURL: source.url,
            isPrivate: true,
            defaultBranch: "main"
          ),
          permissions: RemoteRepositoryPermissions(
            metadataRead: true,
            contentsWrite: true,
            pullRequestsWrite: true,
            workflowsWrite: false
          )
        )
      ]
    )
  }
}
