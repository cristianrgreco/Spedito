import Foundation

public struct ProductWorkspacePersistenceSnapshot: Sendable {
  public let productRepository: ProductRepository?
  public let importedAppLaunch: ImportedAppLaunch?
  public let epics: [Epic]
  public let workItems: [WorkItem]
  public let dependencies: [WorkItemDependency]
  public let profiles: [AgentProfile]
  public let knowledgePages: [KnowledgePage]
  public let candidateRevisions: [CandidateRevision]
  public let agentRunKnowledgeContext: [AgentRunKnowledgePage]
  public let agentRunKnowledgeDestinations: [AgentRunKnowledgeDestination]
  public let demoSessions: [DemoSession]
  public let permissionRequests: [AgentPermissionRequest]
  public let permissionGrants: [AgentPermissionGrant]
  public let knowledgePageProposals: [KnowledgePageProposal]
  public let sprintPlan: SprintPlan?
  public let sprintHistory: [SprintPlan]
  public let runs: [AgentRun]
  public let sprintReadinessIssues: [SprintReadinessIssue]
  public let activity: [ActivityEvent]
  public let retrospectiveNotes: [RetrospectiveNote]
  public let retrospectiveSyntheses: [RetrospectiveSynthesis]
  public let retrospectiveActionSources: [RetrospectiveActionSource]
  public let suggestionBatch: TicketSuggestionBatch?
  public let conversationThreads: [ProductConversationThread]
}

public struct SprintExecutionPersistenceSnapshot: Sendable {
  public let product: Product
  public let plan: SprintPlan
  public let workItems: [WorkItem]
  public let dependencies: [WorkItemDependency]
  public let profiles: [AgentProfile]
  public let runs: [AgentRun]
  public let candidates: [CandidateRevision]
  public let permissionRequests: [AgentPermissionRequest]
  public let permissionGrants: [AgentPermissionGrant]
  public let knowledgePages: [KnowledgePage]
}

extension SQLiteStore {
  public func fetchProductWorkspaceSnapshot(
    productID: UUID
  ) throws -> ProductWorkspacePersistenceSnapshot {
    try readTransaction {
      let sprintPlan = try fetchCurrentSprint(productID: productID)
      let sprintHistory = try fetchSprintHistory(productID: productID)
      let candidateSprint =
        if let sprintPlan, sprintPlan.sprint.state == .draft {
          sprintPlan
        } else {
          sprintHistory.first { $0.sprint.state == .draft }
        }
      let readinessIssues: [SprintReadinessIssue] =
        if let candidateSprint {
          try sprintReadinessIssues(sprintID: candidateSprint.sprint.id)
        } else {
          []
        }

      return try ProductWorkspacePersistenceSnapshot(
        productRepository: fetchProductRepository(productID: productID),
        importedAppLaunch: fetchImportedAppLaunch(productID: productID),
        epics: fetchEpics(productID: productID),
        workItems: fetchWorkItems(productID: productID),
        dependencies: fetchWorkItemDependencies(productID: productID),
        profiles: fetchAgentProfiles(productID: productID),
        knowledgePages: fetchKnowledgePages(productID: productID),
        candidateRevisions: fetchCandidateRevisions(productID: productID),
        agentRunKnowledgeContext: fetchAgentRunKnowledgeContext(productID: productID),
        agentRunKnowledgeDestinations: fetchAgentRunKnowledgeDestinations(productID: productID),
        demoSessions: fetchDemoSessions(productID: productID),
        permissionRequests: fetchAgentPermissionRequests(productID: productID),
        permissionGrants: fetchAgentPermissionGrants(productID: productID),
        knowledgePageProposals: fetchKnowledgePageProposals(productID: productID),
        sprintPlan: sprintPlan,
        sprintHistory: sprintHistory,
        runs: fetchAgentRuns(productID: productID),
        sprintReadinessIssues: readinessIssues,
        activity: fetchActivity(productID: productID),
        retrospectiveNotes: fetchRetrospectiveNotes(productID: productID),
        retrospectiveSyntheses: fetchRetrospectiveSyntheses(productID: productID),
        retrospectiveActionSources: fetchRetrospectiveActionSources(productID: productID),
        suggestionBatch: fetchLatestTicketSuggestionBatch(productID: productID),
        conversationThreads: fetchConversationThreads(productID: productID)
      )
    }
  }

  public func fetchSprintExecutionSnapshot(
    productID: UUID
  ) throws -> SprintExecutionPersistenceSnapshot? {
    try readTransaction {
      let product = try fetchProduct(id: productID)
      guard
        product.status == .active,
        let plan = try fetchCurrentSprint(productID: productID),
        plan.sprint.state == .active
      else { return nil }

      return try SprintExecutionPersistenceSnapshot(
        product: product,
        plan: plan,
        workItems: fetchSprintExecutionWorkItems(
          productID: productID,
          sprintID: plan.sprint.id
        ),
        dependencies: fetchSprintExecutionDependencies(sprintID: plan.sprint.id),
        profiles: fetchAgentProfiles(productID: productID),
        runs: fetchSprintExecutionAgentRuns(sprintID: plan.sprint.id),
        candidates: fetchSprintExecutionCandidateRevisions(sprintID: plan.sprint.id),
        permissionRequests: fetchSprintExecutionPermissionRequests(sprintID: plan.sprint.id),
        permissionGrants: fetchAgentPermissionGrants(productID: productID),
        knowledgePages: fetchKnowledgePages(productID: productID)
      )
    }
  }
}
