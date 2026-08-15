import Foundation

public enum RepositoryImportActivationProgress: Equatable, Sendable {
  case cloningAndStaging
  case activatingProduct
}

@MainActor
public protocol RepositoryImportActivating: Sendable {
  func importProduct(
    name: String,
    from source: PublicGitRepositoryURL,
    credentialConfiguration: GitCredentialSessionConfiguration?,
    onProgress: @escaping @Sendable (RepositoryImportActivationProgress) async -> Void
  ) async throws -> ImportedProduct
}

public protocol RepositoryImportSourceResolving: Sendable {
  func importRepositories() async throws -> GitHubRepositoryImportCatalog
  func authorizeImport(
    onPrompt: @escaping @Sendable (GitHubDeviceAuthorizationPrompt) async -> Void
  ) async throws -> GitHubRepositoryImportCatalog
  func importProduct(
    name: String,
    repositoryID: Int64,
    importer:
      @escaping @Sendable (
        PublicGitRepositoryURL,
        GitCredentialSessionConfiguration
      ) async throws -> ImportedProduct
  ) async throws -> ImportedProduct
}

public enum RepositoryImportCommand: Equatable, Sendable {
  case loadAuthorizedRepositories
  case authorizeGitHub
  case importPublic(name: String, source: PublicGitRepositoryURL)
  case importAuthorized(name: String, repositoryID: Int64)
}

public enum RepositoryImportProvenance: Equatable, Sendable {
  case imported(repository: ProductRepository, knowledgeRunID: UUID)
  case emptyRepository(remoteState: GitHubRemoteRepositoryState?)
}

public struct RepositoryImportCompletion: Equatable, Sendable {
  public let product: Product
  public let provenance: RepositoryImportProvenance
  public let ownerFacingWarning: String?

  public init(
    product: Product,
    provenance: RepositoryImportProvenance,
    ownerFacingWarning: String? = nil
  ) {
    self.product = product
    self.provenance = provenance
    self.ownerFacingWarning = ownerFacingWarning
  }
}

public struct RepositoryImportFailure: Equatable, Sendable {
  public let message: String
  public let retry: RepositoryImportCommand

  public init(message: String, retry: RepositoryImportCommand) {
    self.message = message
    self.retry = retry
  }
}

public enum RepositoryImportPhase: Equatable, Sendable {
  case idle
  case loadingAuthorizedRepositories
  case waitingForDeviceAuthorization(GitHubDeviceAuthorizationPrompt)
  case resolvingSelectedRepository(repositoryID: Int64)
  case cloningAndStaging
  case activatingProduct
  case completed(RepositoryImportCompletion)
  case cancelled
  case failed(RepositoryImportFailure)
}

public struct RepositoryImportSnapshot: Equatable, Sendable {
  public var phase: RepositoryImportPhase
  public var catalog: GitHubRepositoryImportCatalog

  public init(
    phase: RepositoryImportPhase = .idle,
    catalog: GitHubRepositoryImportCatalog = GitHubRepositoryImportCatalog()
  ) {
    self.phase = phase
    self.catalog = catalog
  }

  public var authorizationPrompt: GitHubDeviceAuthorizationPrompt? {
    guard case .waitingForDeviceAuthorization(let prompt) = phase else { return nil }
    return prompt
  }

  public var failure: RepositoryImportFailure? {
    guard case .failed(let failure) = phase else { return nil }
    return failure
  }

  public var isLoadingAuthorizedRepositories: Bool {
    switch phase {
    case .loadingAuthorizedRepositories, .waitingForDeviceAuthorization:
      true
    default:
      false
    }
  }

  public var isImportingProduct: Bool {
    switch phase {
    case .resolvingSelectedRepository, .cloningAndStaging, .activatingProduct:
      true
    default:
      false
    }
  }
}

public actor RepositoryImportCoordinator {
  public typealias SnapshotObserver = @MainActor @Sendable (RepositoryImportSnapshot) -> Void
  public typealias BlankProductActivator =
    @MainActor @Sendable (String, Int64) async throws -> RepositoryImportCompletion

  private enum OperationOutcome: Sendable {
    case catalog(GitHubRepositoryImportCatalog)
    case completed(RepositoryImportCompletion)
    case cancelled
    case failed(String)
  }

  private struct ActiveOperation: Sendable {
    let id: UUID
    let task: Task<OperationOutcome, Never>
  }

  private let activator: (any RepositoryImportActivating)?
  private let sourceResolver: (any RepositoryImportSourceResolving)?
  private let blankProductActivator: BlankProductActivator
  private let onSnapshot: SnapshotObserver

  private var currentSnapshot = RepositoryImportSnapshot()
  private var activeOperation: ActiveOperation?
  private var activeOperationID: UUID?
  private var completedCommand: RepositoryImportCommand?

  public init(
    activator: (any RepositoryImportActivating)?,
    sourceResolver: (any RepositoryImportSourceResolving)?,
    blankProductActivator: @escaping BlankProductActivator,
    onSnapshot: @escaping SnapshotObserver
  ) {
    self.activator = activator
    self.sourceResolver = sourceResolver
    self.blankProductActivator = blankProductActivator
    self.onSnapshot = onSnapshot
  }

  public func snapshot() -> RepositoryImportSnapshot {
    currentSnapshot
  }

  @discardableResult
  public func send(_ command: RepositoryImportCommand) async -> RepositoryImportCompletion? {
    if completedCommand == command,
      case .completed(let completion) = currentSnapshot.phase
    {
      return completion
    }
    guard activeOperationID == nil else { return nil }

    let operationID = UUID()
    activeOperationID = operationID
    await begin(command)
    guard activeOperationID == operationID else { return nil }
    let task = makeTask(for: command, operationID: operationID)
    activeOperation = ActiveOperation(id: operationID, task: task)
    let outcome = await task.value
    guard activeOperationID == operationID else {
      if case .completed(let completion) = outcome { return completion }
      return nil
    }
    activeOperation = nil
    activeOperationID = nil

    switch outcome {
    case .catalog(let catalog):
      currentSnapshot.catalog = catalog
      currentSnapshot.phase = .idle
      await publish()
      return nil
    case .completed(let completion):
      completedCommand = command
      currentSnapshot.phase = .completed(completion)
      await publish()
      return completion
    case .cancelled:
      currentSnapshot.phase = .cancelled
      await publish()
      return nil
    case .failed(let message):
      currentSnapshot.phase = .failed(
        RepositoryImportFailure(message: message, retry: command)
      )
      await publish()
      return nil
    }
  }

  public func cancel() async {
    let operationID = activeOperationID
    activeOperationID = nil
    guard let operation = activeOperation else {
      currentSnapshot.phase = .cancelled
      await publish()
      return
    }
    operation.task.cancel()
    _ = await operation.task.value
    guard operationID == operation.id else { return }
    activeOperation = nil
    currentSnapshot.phase = .cancelled
    await publish()
  }

  private func begin(_ command: RepositoryImportCommand) async {
    completedCommand = nil
    switch command {
    case .loadAuthorizedRepositories, .authorizeGitHub:
      currentSnapshot.phase = .loadingAuthorizedRepositories
    case .importPublic:
      currentSnapshot.phase = .cloningAndStaging
    case .importAuthorized(_, let repositoryID):
      currentSnapshot.phase = .resolvingSelectedRepository(repositoryID: repositoryID)
    }
    await publish()
  }

  private func makeTask(
    for command: RepositoryImportCommand,
    operationID: UUID
  ) -> Task<OperationOutcome, Never> {
    let activator = activator
    let sourceResolver = sourceResolver
    let blankProductActivator = blankProductActivator
    let coordinator = self
    return Task {
      do {
        try Task.checkCancellation()
        switch command {
        case .loadAuthorizedRepositories:
          guard let sourceResolver else {
            return .catalog(GitHubRepositoryImportCatalog())
          }
          return .catalog(try await sourceResolver.importRepositories())
        case .authorizeGitHub:
          guard let sourceResolver else {
            return .failed("This Spedito build is not configured for GitHub.")
          }
          let catalog = try await sourceResolver.authorizeImport { prompt in
            await coordinator.present(prompt, operationID: operationID)
          }
          return .catalog(catalog)
        case .importPublic(let name, let source):
          guard let activator else {
            return .failed("Repository import is unavailable.")
          }
          let imported = try await activator.importProduct(
            name: name,
            from: source,
            credentialConfiguration: nil
          ) { progress in
            await coordinator.present(progress, operationID: operationID)
          }
          return .completed(Self.completion(for: imported))
        case .importAuthorized(let name, let repositoryID):
          guard let sourceResolver else {
            return .failed("This Spedito build is not configured for GitHub.")
          }
          guard let activator else {
            return .failed("Repository import is unavailable.")
          }
          do {
            let imported = try await sourceResolver.importProduct(
              name: name,
              repositoryID: repositoryID
            ) { source, credential in
              await coordinator.present(.cloningAndStaging, operationID: operationID)
              return try await activator.importProduct(
                name: name,
                from: source,
                credentialConfiguration: credential
              ) { progress in
                await coordinator.present(progress, operationID: operationID)
              }
            }
            return .completed(Self.completion(for: imported))
          } catch ProductRepositoryImportError.emptyDefaultBranch {
            await coordinator.present(.activatingProduct, operationID: operationID)
            try Task.checkCancellation()
            return .completed(try await blankProductActivator(name, repositoryID))
          }
        }
      } catch is CancellationError {
        return .cancelled
      } catch {
        return .failed(error.localizedDescription)
      }
    }
  }

  private func present(
    _ prompt: GitHubDeviceAuthorizationPrompt,
    operationID: UUID
  ) async {
    guard activeOperationID == operationID else { return }
    currentSnapshot.phase = .waitingForDeviceAuthorization(prompt)
    await publish()
  }

  private func present(
    _ progress: RepositoryImportActivationProgress,
    operationID: UUID
  ) async {
    guard activeOperationID == operationID else { return }
    switch progress {
    case .cloningAndStaging:
      currentSnapshot.phase = .cloningAndStaging
    case .activatingProduct:
      currentSnapshot.phase = .activatingProduct
    }
    await publish()
  }

  private func publish() async {
    await onSnapshot(currentSnapshot)
  }

  private nonisolated static func completion(
    for imported: ImportedProduct
  ) -> RepositoryImportCompletion {
    RepositoryImportCompletion(
      product: imported.product,
      provenance: .imported(
        repository: imported.repository,
        knowledgeRunID: imported.knowledgeRun.id
      )
    )
  }
}
