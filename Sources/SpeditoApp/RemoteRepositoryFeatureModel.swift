import Combine
import Foundation
import SpeditoCore

struct RemoteRepositoryPresentationSnapshot: Equatable, Sendable {
  let productID: UUID
  var repositoryState: GitHubRemoteRepositoryState
  var authorizationPrompt: GitHubDeviceAuthorizationPrompt?
  var isBusy: Bool
  var failure: RemoteRepositoryFeatureFailure?
  var setupActivity: GitHubRepositorySetupActivity?

  init(
    productID: UUID,
    repositoryState: GitHubRemoteRepositoryState = .init(isConfigured: false),
    authorizationPrompt: GitHubDeviceAuthorizationPrompt? = nil,
    isBusy: Bool = false,
    failure: RemoteRepositoryFeatureFailure? = nil,
    setupActivity: GitHubRepositorySetupActivity? = nil
  ) {
    self.productID = productID
    self.repositoryState = repositoryState
    self.authorizationPrompt = authorizationPrompt
    self.isBusy = isBusy
    self.failure = failure
    self.setupActivity = setupActivity
  }
}

struct RemoteRepositoryFeatureFailure: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case operation
    case inactiveProduct
    case closedWithoutMerge
    case activeDeliveryCheck
  }

  let kind: Kind
  let message: String
}

@MainActor
final class RemoteRepositoryFeatureModel: ObservableObject, RepositoryImportSourceResolving {
  typealias PullRequestSyncHandler = @MainActor (GitHubTicketPullRequestSync) async -> Void

  private struct PullRequestPollingConfiguration {
    let productID: UUID
    let workItems: @MainActor () -> [WorkItem]
    let isSelected: @MainActor (UUID) -> Bool
    let onSync: PullRequestSyncHandler
  }

  @Published private var snapshots: [UUID: RemoteRepositoryPresentationSnapshot] = [:]

  private let stateService: (any GitHubRepositoryStateServing)?
  private let connectionService: (any GitHubRepositoryConnectionServing)?
  private let observationService: (any GitHubRepositoryObservationServing)?
  private let safeSyncService: (any GitHubRepositorySafeSyncServing)?
  private let publicationService: (any GitHubRepositoryPublicationServing)?
  private let lifecycleService: (any GitHubRepositoryLifecycleServing)?
  private let importSource: (any RepositoryImportSourceResolving)?
  private let pollingSleeper: any RemoteRepositoryPollingSleeping

  private var operationTasks: [UUID: Task<Void, Never>] = [:]
  private var pullRequestSyncTasks: [UUID: Task<GitHubTicketPullRequestSync?, Never>] = [:]
  private var pollingTask: Task<Void, Never>?
  private var pollingConfiguration: PullRequestPollingConfiguration?
  private var isApplicationActive = true
  private var visibleReviewWorkItemCounts: [UUID: Int] = [:]
  private var busyCounts: [UUID: Int] = [:]
  private var isShuttingDown = false

  init(
    service: (any GitHubRemoteRepositoryServing)?,
    pollingSleeper: any RemoteRepositoryPollingSleeping =
      ContinuousRemoteRepositoryPollingSleeper()
  ) {
    stateService = service
    connectionService = service
    observationService = service
    safeSyncService = service
    publicationService = service
    lifecycleService = service
    importSource = service
    self.pollingSleeper = pollingSleeper
  }

  var isAvailable: Bool {
    connectionService != nil
  }

  func snapshot(for productID: UUID) -> RemoteRepositoryPresentationSnapshot {
    snapshots[productID] ?? RemoteRepositoryPresentationSnapshot(productID: productID)
  }

  func snapshotIfLoaded(for productID: UUID) -> RemoteRepositoryPresentationSnapshot? {
    snapshots[productID]
  }

  func importRepositories() async throws -> GitHubRepositoryImportCatalog {
    guard let importSource else { throw GitHubRemoteRepositoryServiceError.notConfigured }
    return try await importSource.importRepositories()
  }

  func record(_ state: GitHubRemoteRepositoryState, productID: UUID) {
    setState(state, productID: productID)
  }

  func state(productID: UUID) async -> GitHubRemoteRepositoryState? {
    guard let stateService else { return nil }
    let state = await stateService.state(productID: productID)
    setState(state, productID: productID)
    return state
  }

  func hasActiveOperation(productID: UUID) -> Bool {
    operationTasks[productID] != nil || snapshot(for: productID).isBusy
  }

  func settleForArchival(productID: UUID) async -> GitHubRemoteRepositoryState? {
    guard let stateService else { return nil }
    pollingTask?.cancel()
    await pollingTask?.value
    pollingTask = nil
    let current = await stateService.state(productID: productID)
    let publicationIDs = Set(current.publications.map(\.id))
    let tasks = pullRequestSyncTasks.filter { publicationIDs.contains($0.key) }
    for task in tasks.values { task.cancel() }
    for task in tasks.values { _ = await task.value }
    for publicationID in tasks.keys {
      pullRequestSyncTasks[publicationID] = nil
    }
    let settled = await stateService.state(productID: productID)
    mutateSnapshot(productID: productID) {
      $0.repositoryState = settled
      $0.authorizationPrompt = nil
      $0.setupActivity = nil
      $0.isBusy = false
    }
    busyCounts[productID] = nil
    return settled
  }
  func authorizeImport(
    onPrompt: @escaping @Sendable (GitHubDeviceAuthorizationPrompt) async -> Void
  ) async throws -> GitHubRepositoryImportCatalog {
    guard let importSource else { throw GitHubRemoteRepositoryServiceError.notConfigured }
    return try await importSource.authorizeImport(onPrompt: onPrompt)
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
    guard let importSource else { throw GitHubRemoteRepositoryServiceError.notConfigured }
    return try await importSource.importProduct(
      name: name,
      repositoryID: repositoryID,
      importer: importer
    )
  }

  func connectLocalProduct(
    productID: UUID,
    repositoryID: Int64
  ) async throws -> GitHubRemoteRepositoryState {
    guard let connectionService else { throw GitHubRemoteRepositoryServiceError.notConfigured }
    let state = try await connectionService.connectLocalProduct(
      productID: productID,
      repositoryID: repositoryID
    )
    setState(state, productID: productID)
    return state
  }

  func load(productID: UUID) async {
    guard let stateService else { return }
    let state = await stateService.state(productID: productID)
    setState(state, productID: productID)
  }

  func load(productIDs: [UUID]) async {
    for productID in productIDs {
      await load(productID: productID)
    }
  }

  func connect(productID: UUID, isProductActive: Bool) async {
    setAuthorizationPrompt(nil, productID: productID)
    setSetupActivity(nil, productID: productID)
    let feature = self
    await performConnectionAction(productID: productID, isProductActive: isProductActive) {
      service in
      try await service.connect(productID: productID) { prompt in
        await feature.setAuthorizationPrompt(prompt, productID: productID)
      }
    }
    setAuthorizationPrompt(nil, productID: productID)
  }

  func cancelConnection(productID: UUID, isProductActive: Bool) async {
    if let task = operationTasks[productID] {
      task.cancel()
      await task.value
    }
    setAuthorizationPrompt(nil, productID: productID)
    setSetupActivity(nil, productID: productID)
    await performConnectionAction(productID: productID, isProductActive: isProductActive) {
      try await $0.cancelConnection(productID: productID)
    }
  }

  func disconnect(productID: UUID, isProductActive: Bool) async {
    setSetupActivity(nil, productID: productID)
    await performConnectionAction(productID: productID, isProductActive: isProductActive) {
      try await $0.disconnect(productID: productID)
    }
  }

  func signOut(
    accountID: UUID,
    productID: UUID,
    isProductActive: Bool,
    allProductIDs: [UUID]
  ) async {
    setSetupActivity(nil, productID: productID)
    await performConnectionAction(productID: productID, isProductActive: isProductActive) {
      service in
      try await service.signOut(accountID: accountID)
      return await service.state(productID: productID)
    }
    await load(productIDs: allProductIDs)
  }

  func selectLocalRepository(
    productID: UUID,
    repositoryID: Int64,
    optimisticState: GitHubRemoteRepositoryState?,
    isProductActive: Bool
  ) async {
    setSetupActivity(nil, productID: productID)
    if let optimisticState {
      setState(optimisticState, productID: productID)
    }
    await performConnectionAction(productID: productID, isProductActive: isProductActive) {
      try await $0.selectLocalRepository(productID: productID, repositoryID: repositoryID)
    }
  }

  func refreshRepositories(productID: UUID, isProductActive: Bool) async {
    await performConnectionAction(productID: productID, isProductActive: isProductActive) {
      try await $0.refreshRepositories(productID: productID)
    }
  }

  func initializeLocalRepository(
    productID: UUID,
    publishesExistingHistory: Bool,
    isProductActive: Bool
  ) async {
    setSetupActivity(
      .inProgress(
        progress: .validatingProduct,
        publishesExistingHistory: publishesExistingHistory
      ),
      productID: productID
    )
    let feature = self
    await performConnectionAction(productID: productID, isProductActive: isProductActive) {
      service in
      try await service.initializeLocalRepository(productID: productID) { progress in
        await feature.setSetupActivity(
          .inProgress(
            progress: progress,
            publishesExistingHistory: publishesExistingHistory
          ),
          productID: productID
        )
      }
    }
    let snapshot = snapshot(for: productID)
    if snapshot.failure == nil, snapshot.repositoryState.connection?.status == .connected {
      setSetupActivity(
        .completed(publishedExistingHistory: publishesExistingHistory),
        productID: productID
      )
    } else {
      setSetupActivity(nil, productID: productID)
    }
  }

  func confirmTarget(
    productID: UUID,
    expectedVersion: Int,
    pendingObservedAt: Date,
    isProductActive: Bool
  ) async {
    await performConnectionAction(productID: productID, isProductActive: isProductActive) {
      try await $0.confirmTarget(
        productID: productID,
        expectedVersion: expectedVersion,
        pendingObservedAt: pendingObservedAt
      )
    }
  }

  func check(productID: UUID, isProductActive: Bool) async {
    await performObservationAction(productID: productID, isProductActive: isProductActive) {
      try await $0.check(productID: productID)
    }
  }

  func prepareSafeSync(productID: UUID, isProductActive: Bool) async {
    await performSafeSyncAction(productID: productID, isProductActive: isProductActive) {
      try await $0.prepareSafeSync(productID: productID)
    }
  }

  func acceptSafeSync(productID: UUID, syncID: UUID, isProductActive: Bool) async {
    await performSafeSyncAction(productID: productID, isProductActive: isProductActive) {
      try await $0.acceptSafeSync(syncID: syncID)
    }
  }

  func rejectSafeSync(productID: UUID, syncID: UUID, isProductActive: Bool) async {
    await performSafeSyncAction(productID: productID, isProductActive: isProductActive) {
      try await $0.rejectSafeSync(syncID: syncID)
    }
  }

  func refreshPullRequest(
    productID: UUID,
    publicationID: UUID,
    isProductActive: Bool
  ) async {
    await performPublicationAction(productID: productID, isProductActive: isProductActive) {
      try await $0.refreshPullRequest(publicationID: publicationID)
    }
  }
  func syncTicketPullRequestForDelivery(
    productID: UUID,
    publicationID: UUID
  ) async throws -> GitHubTicketPullRequestSync {
    guard let publicationService else {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }
    let result = try await publicationService.syncTicketPullRequest(
      publicationID: publicationID
    )
    setState(result.state, productID: productID)
    if result.closedWithoutMerge {
      setFailure(
        RemoteRepositoryFeatureFailure(
          kind: .closedWithoutMerge,
          message:
            "The pull request was closed on GitHub without being merged. Reopen it on GitHub to continue this ticket."
        ),
        productID: productID
      )
    }
    return result
  }

  func syncTicketPullRequest(
    productID: UUID,
    publicationID: UUID,
    showsProgress: Bool = true
  ) async -> GitHubTicketPullRequestSync? {
    guard !isShuttingDown, let publicationService else { return nil }
    if showsProgress { beginBusy(productID: productID) }
    defer {
      if showsProgress { endBusy(productID: productID) }
    }
    if let existingTask = pullRequestSyncTasks[publicationID] {
      return await existingTask.value
    }
    setFailure(nil, productID: productID)
    let task = Task { @MainActor [weak self] () -> GitHubTicketPullRequestSync? in
      guard let self else { return nil }
      do {
        let result = try await publicationService.syncTicketPullRequest(
          publicationID: publicationID
        )
        setState(result.state, productID: productID)
        if result.closedWithoutMerge {
          setFailure(
            RemoteRepositoryFeatureFailure(
              kind: .closedWithoutMerge,
              message:
                "The pull request was closed on GitHub without being merged. Reopen it on GitHub to continue this ticket."
            ),
            productID: productID
          )
        }
        return result
      } catch is CancellationError {
        return nil
      } catch {
        setFailure(
          RemoteRepositoryFeatureFailure(kind: .operation, message: error.localizedDescription),
          productID: productID
        )
        setState(await publicationService.state(productID: productID), productID: productID)
        return nil
      }
    }
    pullRequestSyncTasks[publicationID] = task
    let result = await task.value
    pullRequestSyncTasks[publicationID] = nil
    return result
  }

  func prepareTicketPullRequestIfConnected(
    productID: UUID,
    workItemID: UUID,
    candidateRevisionID: UUID
  ) async throws -> RemotePublication? {
    guard let publicationService else { return nil }
    let current = await publicationService.state(productID: productID)
    setState(current, productID: productID)
    guard current.connection?.status == .connected else { return nil }
    let state = try await publicationService.prepareTicketPullRequest(
      productID: productID,
      workItemID: workItemID,
      candidateRevisionID: candidateRevisionID
    )
    setState(state, productID: productID)
    guard
      let publication = state.publications.first(where: {
        $0.workItemID == workItemID && $0.candidateRevisionID == candidateRevisionID
      })
    else {
      throw PersistenceError.corruptData("GitHub did not preserve the ticket pull request.")
    }
    return publication
  }

  func markTicketPullRequestReadyIfNeeded(_ publication: RemotePublication?) async throws {
    guard let publication, publication.pullRequest?.isDraft == true, let publicationService else {
      return
    }
    let state = try await publicationService.markTicketPullRequestReady(
      publicationID: publication.id
    )
    setState(state, productID: publication.productID)
  }

  func prepareTicketIntegration(
    productID: UUID
  ) async throws -> GitHubTicketIntegrationPreparation? {
    guard let observationService else { return nil }
    let preparation = try await observationService.prepareTicketIntegration(productID: productID)
    setState(preparation.state, productID: productID)
    return preparation
  }

  func checkForDelivery(productID: UUID) async throws -> GitHubRemoteRepositoryState? {
    guard let observationService else { return nil }
    let state = try await observationService.check(productID: productID)
    setState(state, productID: productID)
    return state
  }

  func acceptSafeSyncForDelivery(syncID: UUID, productID: UUID) async throws {
    guard let safeSyncService else { return }
    let state = try await safeSyncService.acceptSafeSync(syncID: syncID)
    setState(state, productID: productID)
  }

  func mergeTicketPullRequest(
    publicationID: UUID,
    productID: UUID
  ) async throws -> GitHubTicketPullRequestMergeResult? {
    guard let publicationService else { return nil }
    let result = try await publicationService.mergeTicketPullRequest(publicationID: publicationID)
    setState(result.state, productID: productID)
    return result
  }

  func returnTicketPullRequestToDraft(
    publicationID: UUID,
    productID: UUID
  ) async throws {
    guard let publicationService else { return }
    let state = try await publicationService.returnTicketPullRequestToDraft(
      publicationID: publicationID
    )
    setState(state, productID: productID)
  }

  func scheduleRecovery(productIDs: [UUID]) {
    guard let lifecycleService, let stateService else { return }
    for productID in productIDs where operationTasks[productID] == nil {
      let task = Task { @MainActor [weak self] in
        guard let self else { return }
        setFailure(nil, productID: productID)
        await lifecycleService.recover(productID: productID)
        setState(await stateService.state(productID: productID), productID: productID)
        operationTasks[productID] = nil
      }
      operationTasks[productID] = task
    }
  }

  func setReviewTicket(_ workItemID: UUID, isVisible: Bool) {
    if isVisible {
      visibleReviewWorkItemCounts[workItemID, default: 0] += 1
    } else if let count = visibleReviewWorkItemCounts[workItemID] {
      visibleReviewWorkItemCounts[workItemID] = count > 1 ? count - 1 : nil
    }
  }

  func schedulePullRequestPolling(
    productID: UUID?,
    workItems: @escaping @MainActor () -> [WorkItem],
    isSelected: @escaping @MainActor (UUID) -> Bool,
    onSync: @escaping PullRequestSyncHandler
  ) {
    pollingConfiguration = productID.map {
      PullRequestPollingConfiguration(
        productID: $0,
        workItems: workItems,
        isSelected: isSelected,
        onSync: onSync
      )
    }
    restartPullRequestPolling()
  }

  func setApplicationActive(_ isActive: Bool) {
    guard isApplicationActive != isActive else { return }
    isApplicationActive = isActive
    restartPullRequestPolling()
  }

  private func restartPullRequestPolling() {
    pollingTask?.cancel()
    guard let configuration = pollingConfiguration, !isShuttingDown else {
      pollingTask = nil
      return
    }
    pollingTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self, configuration.isSelected(configuration.productID) else { return }
        await pollPullRequestsOnce(
          productID: configuration.productID,
          workItems: configuration.workItems(),
          isSelected: configuration.isSelected,
          onSync: configuration.onSync
        )
        guard !Task.isCancelled, configuration.isSelected(configuration.productID) else {
          return
        }
        let visibleWorkItemIDs = Set(visibleReviewWorkItemCounts.keys)
        let items = configuration.workItems()
        let publications = GitHubPullRequestPollingPolicy.orderedPublications(
          snapshot(for: configuration.productID).repositoryState.publications,
          workItems: items,
          visibleWorkItemIDs: visibleWorkItemIDs
        )
        let interval = GitHubPullRequestPollingPolicy.interval(
          isApplicationActive: isApplicationActive,
          publications: publications,
          workItems: items,
          visibleWorkItemIDs: visibleWorkItemIDs
        )
        do {
          try await pollingSleeper.sleep(for: interval)
        } catch {
          return
        }
      }
    }
  }

  func pollPullRequestsOnce(
    productID: UUID,
    workItems: [WorkItem],
    isSelected: @escaping @MainActor (UUID) -> Bool,
    onSync: @escaping PullRequestSyncHandler
  ) async {
    guard !isShuttingDown, isSelected(productID) else { return }
    let publications = GitHubPullRequestPollingPolicy.orderedPublications(
      snapshot(for: productID).repositoryState.publications,
      workItems: workItems,
      visibleWorkItemIDs: Set(visibleReviewWorkItemCounts.keys)
    )
    for publication in publications {
      guard !Task.isCancelled, isSelected(productID) else { return }
      if let result = await syncTicketPullRequest(
        productID: productID,
        publicationID: publication.id,
        showsProgress: false
      ) {
        await onSync(result)
      }
    }
  }

  func setFailure(_ failure: RemoteRepositoryFeatureFailure?, productID: UUID) {
    mutateSnapshot(productID: productID) { $0.failure = failure }
  }

  func shutdown() async {
    isShuttingDown = true
    let currentPollingTask = pollingTask
    currentPollingTask?.cancel()
    let syncTasks = Array(pullRequestSyncTasks.values)
    let currentOperationTasks = Array(operationTasks.values)
    for task in syncTasks { task.cancel() }
    for task in currentOperationTasks { task.cancel() }
    await lifecycleService?.shutdown()
    await currentPollingTask?.value
    for task in syncTasks { _ = await task.value }
    for task in currentOperationTasks { await task.value }
    pollingTask = nil
    pollingConfiguration = nil
    pullRequestSyncTasks.removeAll()
    operationTasks.removeAll()
  }

  private func performConnectionAction(
    productID: UUID,
    isProductActive: Bool,
    operation:
      @escaping @Sendable (
        any GitHubRepositoryConnectionServing
      ) async throws -> GitHubRemoteRepositoryState
  ) async {
    guard let service = connectionService else { return }
    await perform(
      productID: productID,
      isProductActive: isProductActive,
      stateService: service
    ) {
      try await operation(service)
    }
  }

  private func performObservationAction(
    productID: UUID,
    isProductActive: Bool,
    operation:
      @escaping @Sendable (
        any GitHubRepositoryObservationServing
      ) async throws -> GitHubRemoteRepositoryState
  ) async {
    guard let service = observationService else { return }
    await perform(
      productID: productID,
      isProductActive: isProductActive,
      stateService: service
    ) {
      try await operation(service)
    }
  }

  private func performSafeSyncAction(
    productID: UUID,
    isProductActive: Bool,
    operation:
      @escaping @Sendable (
        any GitHubRepositorySafeSyncServing
      ) async throws -> GitHubRemoteRepositoryState
  ) async {
    guard let service = safeSyncService else { return }
    await perform(
      productID: productID,
      isProductActive: isProductActive,
      stateService: service
    ) {
      try await operation(service)
    }
  }

  private func performPublicationAction(
    productID: UUID,
    isProductActive: Bool,
    operation:
      @escaping @Sendable (
        any GitHubRepositoryPublicationServing
      ) async throws -> GitHubRemoteRepositoryState
  ) async {
    guard let service = publicationService else { return }
    await perform(
      productID: productID,
      isProductActive: isProductActive,
      stateService: service
    ) {
      try await operation(service)
    }
  }

  private func perform(
    productID: UUID,
    isProductActive: Bool,
    stateService: any GitHubRepositoryStateServing,
    operation: @escaping @Sendable () async throws -> GitHubRemoteRepositoryState
  ) async {
    guard !isShuttingDown else { return }
    guard isProductActive else {
      setFailure(
        RemoteRepositoryFeatureFailure(
          kind: .inactiveProduct,
          message: "Restore this Product before resuming its GitHub repository work."
        ),
        productID: productID
      )
      return
    }
    while let task = operationTasks[productID] {
      await task.value
    }
    guard !isShuttingDown else { return }
    beginBusy(productID: productID)
    setFailure(nil, productID: productID)
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let state = try await operation()
        setState(state, productID: productID)
        if let message = state.errorMessage {
          setFailure(
            RemoteRepositoryFeatureFailure(kind: .operation, message: message),
            productID: productID
          )
        }
      } catch is CancellationError {
        setState(await stateService.state(productID: productID), productID: productID)
      } catch {
        setFailure(
          RemoteRepositoryFeatureFailure(kind: .operation, message: error.localizedDescription),
          productID: productID
        )
        setState(await stateService.state(productID: productID), productID: productID)
      }
      endBusy(productID: productID)
      operationTasks[productID] = nil
    }
    operationTasks[productID] = task
    await task.value
  }

  private func setState(_ state: GitHubRemoteRepositoryState, productID: UUID) {
    mutateSnapshot(productID: productID) {
      $0.repositoryState = state
      if $0.failure == nil, let message = state.errorMessage {
        $0.failure = RemoteRepositoryFeatureFailure(kind: .operation, message: message)
      }
    }
  }

  private func setAuthorizationPrompt(
    _ prompt: GitHubDeviceAuthorizationPrompt?,
    productID: UUID
  ) {
    mutateSnapshot(productID: productID) { $0.authorizationPrompt = prompt }
  }

  private func setSetupActivity(_ activity: GitHubRepositorySetupActivity?, productID: UUID) {
    mutateSnapshot(productID: productID) { $0.setupActivity = activity }
  }

  private func beginBusy(productID: UUID) {
    busyCounts[productID, default: 0] += 1
    mutateSnapshot(productID: productID) { $0.isBusy = true }
  }

  private func endBusy(productID: UUID) {
    let count = max(0, (busyCounts[productID] ?? 1) - 1)
    busyCounts[productID] = count == 0 ? nil : count
    mutateSnapshot(productID: productID) { $0.isBusy = count > 0 }
  }

  private func mutateSnapshot(
    productID: UUID,
    mutation: (inout RemoteRepositoryPresentationSnapshot) -> Void
  ) {
    var snapshot = snapshot(for: productID)
    mutation(&snapshot)
    snapshots[productID] = snapshot
  }
}
