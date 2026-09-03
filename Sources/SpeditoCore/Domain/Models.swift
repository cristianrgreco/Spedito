import Foundation

public enum ProductStatus: String, Codable, CaseIterable, Hashable, Sendable {
  case active
  case archived

  public var title: String {
    switch self {
    case .active: "Active"
    case .archived: "Archived"
    }
  }
}

public enum ProductColor: String, Codable, CaseIterable, Hashable, Sendable {
  case accent
  case blue
  case teal
  case green
  case orange
  case pink
  case indigo

  static let assignmentOrder: [ProductColor] = [
    .green,
    .indigo,
    .orange,
    .teal,
    .pink,
    .blue,
  ]

  static func nextUnassigned(after existingColors: [ProductColor]) -> ProductColor? {
    let usedColors = Set(existingColors.filter { $0 != .accent })
    return assignmentOrder.first { !usedColors.contains($0) }
  }

  static func nextAssigned(after existingColors: [ProductColor]) -> ProductColor {
    guard !existingColors.isEmpty else {
      return .accent
    }

    if let unusedColor = nextUnassigned(after: existingColors) {
      return unusedColor
    }
    let rotatedColorCount = existingColors.count { $0 != .accent }
    return assignmentOrder[rotatedColorCount % assignmentOrder.count]
  }
}

public struct Product: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public var name: String
  public var instructions: String
  public var status: ProductStatus
  public var color: ProductColor
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    instructions: String = "",
    status: ProductStatus = .active,
    color: ProductColor = .accent,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.instructions = instructions
    self.status = status
    self.color = color
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case instructions
    case status
    case color
    case createdAt
    case updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? ""
    status = try container.decodeIfPresent(ProductStatus.self, forKey: .status) ?? .active
    color = try container.decodeIfPresent(ProductColor.self, forKey: .color) ?? .accent
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
  }
}

public enum EpicStatus: String, Codable, CaseIterable, Hashable, Sendable {
  case open
  case closed
  case archived

  public var title: String {
    switch self {
    case .open: "Open"
    case .closed: "Completed"
    case .archived: "Archived"
    }
  }
}

public enum EpicColor: String, Codable, CaseIterable, Hashable, Sendable {
  case blue
  case teal
  case green
  case orange
  case pink
  case indigo

  static let assignmentOrder: [EpicColor] = [
    .blue,
    .green,
    .indigo,
    .orange,
    .teal,
    .pink,
  ]
}

public enum EpicProgress: String, Codable, CaseIterable, Hashable, Sendable {
  case created
  case planned
  case inProgress = "in_progress"
  case complete

  public init(tickets: [WorkItem]) {
    let activeTickets = tickets.filter { $0.state != .cancelled }
    guard !activeTickets.isEmpty else {
      self = .created
      return
    }
    if activeTickets.allSatisfy({ $0.state == .released }) {
      self = .complete
      return
    }
    let deliveryStates: Set<WorkItemState> = [
      .queued,
      .running,
      .integrating,
      .verifying,
      .acceptance,
      .readyToRelease,
      .released,
    ]
    self =
      activeTickets.contains { deliveryStates.contains($0.state) }
      ? .inProgress
      : .planned
  }

  public var title: String {
    switch self {
    case .created: "Created"
    case .planned: "Planned"
    case .inProgress: "In progress"
    case .complete: "Ready to complete"
    }
  }
}

public struct Epic: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let productID: UUID
  public var title: String
  public var goal: String
  public var successCriteria: [String]
  public var constraints: String
  public var status: EpicStatus
  public var color: EpicColor
  public var rank: Int
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    productID: UUID,
    title: String,
    goal: String,
    successCriteria: [String] = [],
    constraints: String = "",
    status: EpicStatus = .open,
    color: EpicColor = .blue,
    rank: Int = 0,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.productID = productID
    self.title = title
    self.goal = goal
    self.successCriteria = successCriteria
    self.constraints = constraints
    self.status = status
    self.color = color
    self.rank = rank
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var hasAnalyzedMetadata: Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  public var displayTitle: String {
    hasAnalyzedMetadata ? title : goal
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case productID
    case title
    case goal
    case successCriteria
    case constraints
    case status
    case color
    case rank
    case createdAt
    case updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    productID = try container.decode(UUID.self, forKey: .productID)
    title = try container.decode(String.self, forKey: .title)
    goal = try container.decode(String.self, forKey: .goal)
    successCriteria = try container.decodeIfPresent([String].self, forKey: .successCriteria) ?? []
    constraints = try container.decodeIfPresent(String.self, forKey: .constraints) ?? ""
    status = try container.decodeIfPresent(EpicStatus.self, forKey: .status) ?? .open
    color = try container.decodeIfPresent(EpicColor.self, forKey: .color) ?? .blue
    rank = try container.decodeIfPresent(Int.self, forKey: .rank) ?? 0
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
  }
}

public enum WorkItemState: String, Codable, CaseIterable, Sendable {
  case backlog
  case refining
  case ready
  case queued
  case running
  case integrating
  case verifying
  case acceptance
  case readyToRelease = "ready_to_release"
  case released
  case cancelled

  public var title: String {
    switch self {
    case .backlog: "Backlog"
    case .refining: "Refining"
    case .ready: "Ready"
    case .queued: "Queued"
    case .running: "Running"
    case .integrating: "Integrating"
    case .verifying: "Verifying"
    case .acceptance: "Acceptance"
    case .readyToRelease: "Ready to release"
    case .released: "Released"
    case .cancelled: "Cancelled"
    }
  }
}

public enum WorkItemPriority: Int, Codable, CaseIterable, Sendable {
  case urgent = 0
  case high = 1
  case normal = 2
  case low = 3

  public var title: String {
    switch self {
    case .urgent: "Urgent"
    case .high: "High"
    case .normal: "Normal"
    case .low: "Low"
    }
  }
}

public enum WorkItemType: String, Codable, CaseIterable, Sendable {
  case story
  case task
  case bug

  public var title: String {
    switch self {
    case .story: "Story"
    case .task: "Task"
    case .bug: "Bug"
    }
  }

  public var guidance: String {
    switch self {
    case .story: "A user-visible product outcome"
    case .task: "Supporting delivery, research, or maintenance work"
    case .bug: "Behavior that should already work but does not"
    }
  }
}

public struct WorkItem: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let productID: UUID
  public let key: String
  public var title: String
  public var type: WorkItemType
  public var body: String
  public var acceptanceCriteria: [String]
  public var state: WorkItemState
  public var priority: WorkItemPriority
  public var rank: Int
  public var customFields: [String: String]
  public var ownerProfileID: UUID?
  public var epicID: UUID?
  public var demoKind: TicketDemoKind?
  public var version: Int
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    productID: UUID,
    key: String,
    title: String,
    type: WorkItemType = .story,
    body: String = "",
    acceptanceCriteria: [String] = [],
    state: WorkItemState = .backlog,
    priority: WorkItemPriority = .normal,
    rank: Int = 0,
    customFields: [String: String] = [:],
    ownerProfileID: UUID? = nil,
    epicID: UUID? = nil,
    demoKind: TicketDemoKind? = nil,
    version: Int = 1,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.productID = productID
    self.key = key
    self.title = title
    self.type = type
    self.body = body
    self.acceptanceCriteria = acceptanceCriteria
    self.state = state
    self.priority = priority
    self.rank = rank
    self.customFields = customFields
    self.ownerProfileID = ownerProfileID
    self.epicID = epicID
    self.demoKind = demoKind
    self.version = version
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum WorkItemRankPosition: Sendable {
  case top
  case bottom
}

public enum WorkItemUpdateError: Error, Equatable, LocalizedError, Sendable {
  case versionConflict(key: String, expected: Int, actual: Int)

  public var errorDescription: String? {
    switch self {
    case .versionConflict(let key, let expected, let actual):
      "\(key) changed while you were editing it (expected version \(expected), found \(actual)). Reload the ticket before applying these changes."
    }
  }
}

public enum WorkItemRankingError: Error, Equatable, LocalizedError, Sendable {
  case notPlanningItem(String)
  case dependencyOrder(String)

  public var errorDescription: String? {
    switch self {
    case .notPlanningItem(let key):
      "\(key) is no longer in the planning backlog."
    case .dependencyOrder(let message):
      message
    }
  }
}

public struct WorkItemDependency: Codable, Hashable, Sendable {
  public let workItemID: UUID
  public let dependsOnWorkItemID: UUID

  public init(workItemID: UUID, dependsOnWorkItemID: UUID) {
    self.workItemID = workItemID
    self.dependsOnWorkItemID = dependsOnWorkItemID
  }
}

public enum SuggestionSessionStatus: String, Codable, Sendable {
  case generating
  case ready
  case failed
  case cancelled
}

public struct SuggestionSession: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let productID: UUID
  public let epicID: UUID?
  public let sourceWorkItemID: UUID?
  public var status: SuggestionSessionStatus
  public var codexThreadID: String?
  public var codexTurnID: String?
  public var errorMessage: String?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    productID: UUID,
    epicID: UUID? = nil,
    sourceWorkItemID: UUID? = nil,
    status: SuggestionSessionStatus = .generating,
    codexThreadID: String? = nil,
    codexTurnID: String? = nil,
    errorMessage: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.productID = productID
    self.epicID = epicID
    self.sourceWorkItemID = sourceWorkItemID
    self.status = status
    self.codexThreadID = codexThreadID
    self.codexTurnID = codexTurnID
    self.errorMessage = errorMessage
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum TicketSuggestionStatus: String, Codable, Sendable {
  case proposed
  case accepted
  case rejected
}

public enum TicketEnvironmentRelationship: String, Codable, CaseIterable, Hashable, Sendable {
  case independent
  case establishes
  case requires
}

public enum EpicEnvironmentReadiness: String, Codable, CaseIterable, Hashable, Sendable {
  case sufficient
  case foundationRequired = "foundation_required"
  case notRequired = "not_required"
}

public struct EpicEnvironmentAssessment: Codable, Hashable, Sendable {
  public let readiness: EpicEnvironmentReadiness
  public let rationale: String
  public let foundationTicketReference: String?

  public init(
    readiness: EpicEnvironmentReadiness,
    rationale: String,
    foundationTicketReference: String? = nil
  ) {
    self.readiness = readiness
    self.rationale = rationale
    self.foundationTicketReference = foundationTicketReference
  }
}

public struct TicketSuggestion: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let sessionID: UUID
  public let reference: String
  public let position: Int
  public var title: String
  public var type: WorkItemType
  public var body: String
  public var acceptanceCriteria: [String]
  public var suggestedRole: AgentRole
  public var priority: WorkItemPriority
  public var rationale: String
  public var dependencyIDs: [UUID]
  public var existingDependencyWorkItemIDs: [UUID]
  public var demoKind: TicketDemoKind?
  public var status: TicketSuggestionStatus
  public var acceptedWorkItemID: UUID?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    sessionID: UUID,
    reference: String,
    position: Int,
    title: String,
    type: WorkItemType = .story,
    body: String,
    acceptanceCriteria: [String],
    suggestedRole: AgentRole,
    priority: WorkItemPriority,
    rationale: String,
    dependencyIDs: [UUID] = [],
    existingDependencyWorkItemIDs: [UUID] = [],
    demoKind: TicketDemoKind? = nil,
    status: TicketSuggestionStatus = .proposed,
    acceptedWorkItemID: UUID? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.sessionID = sessionID
    self.reference = reference
    self.position = position
    self.title = title
    self.type = type
    self.body = body
    self.acceptanceCriteria = acceptanceCriteria
    self.suggestedRole = suggestedRole
    self.priority = priority
    self.rationale = rationale
    self.dependencyIDs = dependencyIDs
    self.existingDependencyWorkItemIDs = existingDependencyWorkItemIDs
    self.demoKind = demoKind
    self.status = status
    self.acceptedWorkItemID = acceptedWorkItemID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct TicketSuggestionDraft: Codable, Hashable, Sendable {
  public let reference: String
  public let title: String
  public let type: WorkItemType
  public let body: String
  public let acceptanceCriteria: [String]
  public let suggestedRole: AgentRole
  public let priority: WorkItemPriority
  public let rationale: String
  public let dependsOnReferences: [String]
  public let dependsOnExistingWorkItemKeys: [String]
  public let environmentRelationship: TicketEnvironmentRelationship
  public let demoKind: TicketDemoKind?

  public init(
    reference: String,
    title: String,
    type: WorkItemType = .story,
    body: String,
    acceptanceCriteria: [String],
    suggestedRole: AgentRole,
    priority: WorkItemPriority,
    rationale: String,
    dependsOnReferences: [String] = [],
    dependsOnExistingWorkItemKeys: [String] = [],
    environmentRelationship: TicketEnvironmentRelationship = .independent,
    demoKind: TicketDemoKind? = nil
  ) {
    self.reference = reference
    self.title = title
    self.type = type
    self.body = body
    self.acceptanceCriteria = acceptanceCriteria
    self.suggestedRole = suggestedRole
    self.priority = priority
    self.rationale = rationale
    self.dependsOnReferences = dependsOnReferences
    self.dependsOnExistingWorkItemKeys = dependsOnExistingWorkItemKeys
    self.environmentRelationship = environmentRelationship
    self.demoKind = demoKind
  }
}

public struct EpicPlanDraft: Codable, Hashable, Sendable {
  public let title: String
  public let goal: String
  public let successCriteria: [String]
  public let constraints: String
  public let environmentAssessment: EpicEnvironmentAssessment
  public let ticketSuggestions: [TicketSuggestionDraft]

  public init(
    title: String,
    goal: String,
    successCriteria: [String],
    constraints: String,
    environmentAssessment: EpicEnvironmentAssessment,
    ticketSuggestions: [TicketSuggestionDraft]
  ) {
    self.title = title
    self.goal = goal
    self.successCriteria = successCriteria
    self.constraints = constraints
    self.environmentAssessment = environmentAssessment
    self.ticketSuggestions = ticketSuggestions
  }
}

public struct TicketSuggestionBatch: Codable, Hashable, Sendable {
  public var session: SuggestionSession
  public var suggestions: [TicketSuggestion]

  public init(session: SuggestionSession, suggestions: [TicketSuggestion]) {
    self.session = session
    self.suggestions = suggestions
  }
}

public enum CommentAuthorKind: String, Codable, Sendable {
  case owner
  case agent
  case system
  case external
}

public enum OwnerNotificationKind: String, Codable, CaseIterable, Sendable {
  case needsInput = "needs_input"
  case refinementComplete = "refinement_complete"
  case newReply = "new_reply"

  public var requiresAction: Bool {
    self == .needsInput
  }
}

public enum OwnerNotificationTargetKind: String, Codable, CaseIterable, Sendable {
  case ticket
  case epic
  case conversationThread = "conversation_thread"
}

public struct OwnerNotificationTarget: Codable, Hashable, Sendable {
  public let kind: OwnerNotificationTargetKind
  public let id: UUID

  public init(kind: OwnerNotificationTargetKind, id: UUID) {
    self.kind = kind
    self.id = id
  }
}

public struct OwnerNotification: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let productID: UUID
  public let kind: OwnerNotificationKind
  public let target: OwnerNotificationTarget
  public let title: String
  public let body: String
  public let createdAt: Date
  public var readAt: Date?
  public var resolvedAt: Date?

  public init(
    id: UUID = UUID(),
    productID: UUID,
    kind: OwnerNotificationKind,
    target: OwnerNotificationTarget,
    title: String,
    body: String,
    createdAt: Date = Date(),
    readAt: Date? = nil,
    resolvedAt: Date? = nil
  ) {
    self.id = id
    self.productID = productID
    self.kind = kind
    self.target = target
    self.title = title
    self.body = body
    self.createdAt = createdAt
    self.readAt = readAt
    self.resolvedAt = resolvedAt
  }

  public var isUnread: Bool {
    readAt == nil
  }

  public var isActive: Bool {
    isUnread || (kind.requiresAction && resolvedAt == nil)
  }
}

public enum ConversationThreadStatus: String, Codable, CaseIterable, Sendable {
  case working
  case complete
  case needsInput = "needs_input"
  case failed
  case cancelled
  case archived

  public var title: String {
    switch self {
    case .working: "Working"
    case .complete: "Complete"
    case .needsInput: "Needs your input"
    case .failed: "Failed"
    case .cancelled: "Cancelled"
    case .archived: "Archived"
    }
  }
}

public struct ProductConversationThread: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let productID: UUID
  public let recipientProfileID: UUID
  public var subject: String
  public var status: ConversationThreadStatus
  public var codexThreadID: String?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    productID: UUID,
    recipientProfileID: UUID,
    subject: String,
    status: ConversationThreadStatus = .working,
    codexThreadID: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.productID = productID
    self.recipientProfileID = recipientProfileID
    self.subject = subject
    self.status = status
    self.codexThreadID = codexThreadID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var isArchived: Bool {
    status == .archived
  }
}

public struct ProductConversationMessage: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let threadID: UUID
  public let authorKind: CommentAuthorKind
  public let authorName: String
  public let body: String
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    threadID: UUID,
    authorKind: CommentAuthorKind,
    authorName: String,
    body: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.threadID = threadID
    self.authorKind = authorKind
    self.authorName = authorName
    self.body = body
    self.createdAt = createdAt
  }
}

public struct TicketDecisionArtifact: Codable, Hashable, Sendable {
  public let title: String
  public let path: String

  public init(title: String, path: String) {
    self.title = title
    self.path = path
  }
}

public struct TicketOwnerQuestion: Codable, Hashable, Sendable {
  public let prompt: String
  public let options: [String]
  public let decisionArtifact: TicketDecisionArtifact?

  public init(
    prompt: String,
    options: [String],
    decisionArtifact: TicketDecisionArtifact? = nil
  ) {
    self.prompt = prompt
    self.options = options
    self.decisionArtifact = decisionArtifact
  }

  public static func presentation(
    in body: String,
    structuredQuestion: TicketOwnerQuestion?
  ) -> TicketOwnerQuestionPresentation? {
    if let legacyPresentation = parseLegacyWorkLogBody(body) {
      if let structuredQuestion,
        structuredQuestion.prompt != legacyPresentation.question.prompt
          || structuredQuestion.options != legacyPresentation.question.options
      {
        return TicketOwnerQuestionPresentation(
          context: body,
          question: structuredQuestion
        )
      }
      return TicketOwnerQuestionPresentation(
        context: legacyPresentation.context,
        question: structuredQuestion ?? legacyPresentation.question
      )
    }
    return structuredQuestion.map {
      TicketOwnerQuestionPresentation(context: body, question: $0)
    }
  }

  private static func parseLegacyWorkLogBody(
    _ body: String
  ) -> TicketOwnerQuestionPresentation? {
    let questionMarker = "\n\nQuestion for you: "
    let optionsMarker = "\n\nOptions:\n"
    guard
      let questionRange = body.range(of: questionMarker, options: .backwards)
    else { return nil }

    let questionAndOptions = body[questionRange.upperBound...]
    guard let optionsRange = questionAndOptions.range(of: optionsMarker) else {
      return nil
    }

    let prompt = questionAndOptions[..<optionsRange.lowerBound]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let optionLines = questionAndOptions[optionsRange.upperBound...]
      .components(separatedBy: .newlines)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let options = optionLines.compactMap { line -> String? in
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.hasPrefix("- ") else { return nil }
      return String(trimmed.dropFirst(2))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard
      !prompt.isEmpty,
      (2...4).contains(options.count),
      options.count == optionLines.count,
      options.allSatisfy({ !$0.isEmpty })
    else { return nil }

    return TicketOwnerQuestionPresentation(
      context: String(body[..<questionRange.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines),
      question: TicketOwnerQuestion(prompt: prompt, options: options)
    )
  }
}

public struct TicketOwnerQuestionPresentation: Equatable, Sendable {
  public let context: String
  public let question: TicketOwnerQuestion

  public init(context: String, question: TicketOwnerQuestion) {
    self.context = context
    self.question = question
  }
}

public struct GitHubReviewCommentContext: Codable, Hashable, Sendable {
  public let path: String
  public let commitSHA: String
  public let originalCommitSHA: String
  public let diffHunk: String
  public let startLine: Int?
  public let line: Int?
  public let startSide: String?
  public let side: String?
  public let originalStartLine: Int?
  public let originalLine: Int?

  public init(
    path: String,
    commitSHA: String,
    originalCommitSHA: String,
    diffHunk: String,
    startLine: Int? = nil,
    line: Int? = nil,
    startSide: String? = nil,
    side: String? = nil,
    originalStartLine: Int? = nil,
    originalLine: Int? = nil
  ) {
    self.path = path
    self.commitSHA = commitSHA
    self.originalCommitSHA = originalCommitSHA
    self.diffHunk = diffHunk
    self.startLine = startLine
    self.line = line
    self.startSide = startSide
    self.side = side
    self.originalStartLine = originalStartLine
    self.originalLine = originalLine
  }

  public var lineDescription: String {
    let current = Self.rangeDescription(start: startLine, end: line, side: side ?? startSide)
    if let current { return current }
    return Self.rangeDescription(
      start: originalStartLine,
      end: originalLine,
      side: "original"
    ) ?? "Location unavailable"
  }

  public var agentContext: String {
    """
    GitHub inline review context:
    - File: \(path)
    - Location: \(lineDescription)
    - Reviewed commit: \(commitSHA)
    - Original commit: \(originalCommitSHA)
    ----- BEGIN GITHUB DIFF HUNK -----
    \(diffHunk)
    ----- END GITHUB DIFF HUNK -----
    """
  }

  private static func rangeDescription(start: Int?, end: Int?, side: String?) -> String? {
    guard let line = end ?? start else { return nil }
    let range =
      if let start, start != line {
        "\(start)-\(line)"
      } else {
        "\(line)"
      }
    let normalizedSide = side?.lowercased()
    let sideDescription: String? =
      switch normalizedSide {
      case "left": "old"
      case "right": "new"
      case "original": "original"
      default: nil
      }
    return sideDescription.map { "Lines \(range) (\($0))" } ?? "Lines \(range)"
  }
}

public struct TicketComment: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let workItemID: UUID
  public let authorKind: CommentAuthorKind
  public let authorName: String
  public let body: String
  public let ownerQuestion: TicketOwnerQuestion?
  public let answeredQuestions: [TicketAnsweredQuestion]
  public let authorAvatarURL: URL?
  public let externalURL: URL?
  public let externalID: String?
  public let githubReviewContext: GitHubReviewCommentContext?
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    workItemID: UUID,
    authorKind: CommentAuthorKind,
    authorName: String,
    body: String,
    ownerQuestion: TicketOwnerQuestion? = nil,
    answeredQuestions: [TicketAnsweredQuestion] = [],
    authorAvatarURL: URL? = nil,
    externalURL: URL? = nil,
    externalID: String? = nil,
    githubReviewContext: GitHubReviewCommentContext? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.workItemID = workItemID
    self.authorKind = authorKind
    self.authorName = authorName
    self.body = body
    self.ownerQuestion = ownerQuestion
    self.answeredQuestions = answeredQuestions
    self.authorAvatarURL = authorAvatarURL
    self.externalURL = externalURL
    self.externalID = externalID
    self.githubReviewContext = githubReviewContext
    self.createdAt = createdAt
  }
}

extension TicketComment {
  public var agentContextBody: String {
    guard let githubReviewContext else { return body }
    return "\(body)\n\n\(githubReviewContext.agentContext)"
  }
}

public struct TicketAnsweredQuestion: Codable, Hashable, Sendable {
  public let question: TicketRefinementQuestion
  public let selectedOption: String?
  public let answer: String

  public init(
    question: TicketRefinementQuestion,
    selectedOption: String?,
    answer: String
  ) {
    self.question = question
    self.selectedOption = selectedOption
    self.answer = answer
  }
}

public typealias EpicPlanningAnsweredQuestion = TicketAnsweredQuestion

public struct EpicPlanningConversationMessage: Identifiable, Codable, Hashable, Sendable {
  public enum Author: String, Codable, Hashable, Sendable {
    case owner
    case businessAnalyst = "business_analyst"
    case agent
    case system
  }

  public enum Kind: String, Codable, Hashable, Sendable {
    case refinement
    case chat
  }

  public let id: UUID
  public let author: Author
  public let body: String
  public let createdAt: Date
  public let answeredQuestions: [EpicPlanningAnsweredQuestion]
  public let kind: Kind?
  public let participantID: UUID?
  public let participantName: String?

  public init(
    id: UUID = UUID(),
    author: Author,
    body: String,
    createdAt: Date = Date(),
    answeredQuestions: [EpicPlanningAnsweredQuestion] = [],
    kind: Kind = .refinement,
    participantID: UUID? = nil,
    participantName: String? = nil
  ) {
    self.id = id
    self.author = author
    self.body = body
    self.createdAt = createdAt
    self.answeredQuestions = answeredQuestions
    self.kind = kind
    self.participantID = participantID
    self.participantName = participantName
  }
}

public struct EpicPlanningConversationSnapshot: Codable, Hashable, Sendable {
  public let epicID: UUID
  public var messages: [EpicPlanningConversationMessage]
  public var questions: [TicketRefinementQuestion]
  public var isComplete: Bool
  public var threadID: String?
  public var hasStartedPlanning: Bool?
  public var updatedAt: Date

  public init(
    epicID: UUID,
    messages: [EpicPlanningConversationMessage],
    questions: [TicketRefinementQuestion],
    isComplete: Bool,
    threadID: String? = nil,
    hasStartedPlanning: Bool = true,
    updatedAt: Date = Date()
  ) {
    self.epicID = epicID
    self.messages = messages
    self.questions = questions
    self.isComplete = isComplete
    self.threadID = threadID
    self.hasStartedPlanning = hasStartedPlanning
    self.updatedAt = updatedAt
  }
}

public enum AgentRole: String, Codable, CaseIterable, Sendable {
  case businessAnalyst = "business_analyst"
  case uxDesigner = "ux_designer"
  case lead
  case implementer
  case frontendEngineer = "frontend_engineer"
  case backendEngineer = "backend_engineer"
  case reviewer
  case qualityAssurance = "quality_assurance"
  case knowledgeCurator = "knowledge_curator"

  public var title: String {
    switch self {
    case .businessAnalyst: "Business analyst"
    case .uxDesigner: "UX designer"
    case .lead: "Tech lead"
    case .implementer: "Implementer"
    case .frontendEngineer: "Frontend engineer"
    case .backendEngineer: "Backend engineer"
    case .reviewer: "Reviewer"
    case .qualityAssurance: "QA Explorer"
    case .knowledgeCurator: "Knowledge Curator"
    }
  }

  public var canImplement: Bool {
    switch self {
    case .implementer, .frontendEngineer, .backendEngineer: true
    default: false
    }
  }

  /// Whether this role can own the primary deliverable for a ticket.
  ///
  /// Delivery is broader than writing code: research, experience design, quality
  /// work, and documentation can each be the ticket's intended artifact.
  public var canOwnDelivery: Bool {
    true
  }

  public var canReview: Bool {
    switch self {
    case .lead, .reviewer: true
    default: false
    }
  }

  public var capabilityTitle: String {
    switch self {
    case .businessAnalyst: "Analysis & research"
    case .uxDesigner: "Experience design"
    case .lead: "Architecture, planning & review"
    case .implementer: "General implementation"
    case .frontendEngineer: "Frontend implementation"
    case .backendEngineer: "Backend & platform implementation"
    case .reviewer: "Independent review & audit"
    case .qualityAssurance: "Quality assurance"
    case .knowledgeCurator: "Knowledge & documentation"
    }
  }
}

public struct AgentProfile: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let productID: UUID
  public var name: String
  public var role: AgentRole
  public var model: String
  public var reasoningEffort: String
  public var customInstructions: String?
  public var isBuiltIn: Bool
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    productID: UUID,
    name: String,
    role: AgentRole,
    model: String = "default",
    reasoningEffort: String = "medium",
    customInstructions: String? = nil,
    isBuiltIn: Bool = true,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.productID = productID
    self.name = name
    self.role = role
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.customInstructions = customInstructions
    self.isBuiltIn = isBuiltIn
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var customInstructionText: String {
    guard
      let instructions = customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
      !instructions.isEmpty,
      instructions != AgentPersonaDefaults.instructions(for: role)
    else {
      return ""
    }
    return instructions
  }
}

public enum SprintState: String, Codable, CaseIterable, Sendable {
  case draft
  case active
  case paused
  case completed
  case cancelled

  public var title: String {
    switch self {
    case .draft: "Draft"
    case .active: "Active"
    case .paused: "Paused"
    case .completed: "Completed"
    case .cancelled: "Cancelled"
    }
  }

  public var isInProgress: Bool {
    self == .active || self == .paused
  }
}

public struct Sprint: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let productID: UUID
  public let number: Int
  public var goal: String
  public var state: SprintState
  public var tokenBudgetLimit: Int?
  public var planVersion: Int
  public var startedAt: Date?
  public var completedAt: Date?
  public var retrospectiveConcludedAt: Date?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    productID: UUID,
    number: Int,
    goal: String,
    state: SprintState = .draft,
    tokenBudgetLimit: Int? = nil,
    planVersion: Int = 1,
    startedAt: Date? = nil,
    completedAt: Date? = nil,
    retrospectiveConcludedAt: Date? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.productID = productID
    self.number = number
    self.goal = goal
    self.state = state
    self.tokenBudgetLimit = tokenBudgetLimit
    self.planVersion = planVersion
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.retrospectiveConcludedAt = retrospectiveConcludedAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct SprintItem: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let sprintID: UUID
  public let workItemID: UUID
  public var implementerProfileID: UUID?
  public var reviewerProfileID: UUID?
  public var estimatedTokens: Int
  public var frozenWorkItemVersion: Int?
  public var frozenTitle: String?
  public var frozenBody: String?
  public var frozenAcceptanceCriteria: [String]?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    sprintID: UUID,
    workItemID: UUID,
    implementerProfileID: UUID? = nil,
    reviewerProfileID: UUID? = nil,
    estimatedTokens: Int,
    frozenWorkItemVersion: Int? = nil,
    frozenTitle: String? = nil,
    frozenBody: String? = nil,
    frozenAcceptanceCriteria: [String]? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.sprintID = sprintID
    self.workItemID = workItemID
    self.implementerProfileID = implementerProfileID
    self.reviewerProfileID = reviewerProfileID
    self.estimatedTokens = estimatedTokens
    self.frozenWorkItemVersion = frozenWorkItemVersion
    self.frozenTitle = frozenTitle
    self.frozenBody = frozenBody
    self.frozenAcceptanceCriteria = frozenAcceptanceCriteria
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct SprintPlan: Codable, Hashable, Sendable {
  public var sprint: Sprint
  public var items: [SprintItem]

  public init(sprint: Sprint, items: [SprintItem]) {
    self.sprint = sprint
    self.items = items
  }

  public var estimatedTokens: Int {
    items.reduce(0) { $0 + $1.estimatedTokens }
  }
}

public struct SprintDraftItemInput: Equatable, Sendable {
  public let workItemID: UUID
  public let implementerProfileID: UUID?
  public let reviewerProfileID: UUID?
  public let estimatedTokens: Int

  public init(
    workItemID: UUID,
    implementerProfileID: UUID? = nil,
    reviewerProfileID: UUID? = nil,
    estimatedTokens: Int = 0
  ) {
    self.workItemID = workItemID
    self.implementerProfileID = implementerProfileID
    self.reviewerProfileID = reviewerProfileID
    self.estimatedTokens = estimatedTokens
  }
}

public struct SprintReadinessIssue: Identifiable, Codable, Hashable, Sendable {
  public let id: String
  public let workItemID: UUID?
  public let message: String

  public init(id: String, workItemID: UUID? = nil, message: String) {
    self.id = id
    self.workItemID = workItemID
    self.message = message
  }
}

public enum SprintPlanningError: Error, Equatable, LocalizedError, Sendable {
  case activeSprintExists
  case sprintNotDraft
  case planChanged
  case emptySprint
  case invalidTokenBudget
  case duplicateWorkItem
  case itemNotReady(String)
  case invalidImplementer(String)
  case invalidReviewer(String)
  case notReady([String])

  public var errorDescription: String? {
    switch self {
    case .activeSprintExists:
      "Only one sprint can be active at a time."
    case .sprintNotDraft:
      "Only a draft sprint can be edited or started."
    case .planChanged:
      "The sprint plan changed before the generated goal could be saved."
    case .emptySprint:
      "Select at least one ready ticket."
    case .invalidTokenBudget:
      "The sprint token budget must be greater than zero."
    case .duplicateWorkItem:
      "A ticket can only appear once in a sprint."
    case .itemNotReady(let key):
      "\(key) is no longer ready for sprint planning."
    case .invalidImplementer(let key):
      "\(key) needs a valid delivery owner."
    case .invalidReviewer(let key):
      "\(key) needs a valid review assignment."
    case .notReady(let messages):
      messages.joined(separator: "\n")
    }
  }
}

public enum AgentRunStatus: String, Codable, CaseIterable, Sendable {
  case queued
  case running
  case awaitingOwner = "awaiting_owner"
  case interrupted
  case completed
  case failed
  case cancelled
}

public enum AgentRunExecutionConstraintKind: String, Codable, Hashable, Sendable {
  case accountRateLimit = "account_rate_limit"
  case safetyBackPressure = "safety_back_pressure"

  public var ownerFacingTitle: String {
    switch self {
    case .accountRateLimit: "Usage limit reached"
    case .safetyBackPressure: "Codex safety pause"
    }
  }

  public var ownerFacingExplanation: String {
    switch self {
    case .accountRateLimit:
      "Codex reached an account limit. Delivery will continue automatically after the capacity window resets."
    case .safetyBackPressure:
      "Codex applied safety back-pressure. Delivery will continue automatically when it clears."
    }
  }
}

public struct AgentRunExecutionConstraint: Codable, Hashable, Sendable {
  public let kind: AgentRunExecutionConstraintKind
  public let observedAt: Date
  public let retryAt: Date?
  public let technicalEvidence: String?

  public init(
    kind: AgentRunExecutionConstraintKind,
    observedAt: Date,
    retryAt: Date?,
    technicalEvidence: String?
  ) {
    self.kind = kind
    self.observedAt = observedAt
    self.retryAt = retryAt
    self.technicalEvidence = technicalEvidence
  }
}


public struct AgentRun: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let productID: UUID
  public let sprintID: UUID?
  public let sprintItemID: UUID?
  public let workItemID: UUID
  public let profileID: UUID
  public var status: AgentRunStatus
  public var codexThreadID: String?
  public var worktreePath: String?
  public var ticketBudgetUsed: Double
  public var contextUsedTokens: Int?
  public var contextWindowTokens: Int?
  public var cumulativeUsedTokens: Int?
  public var compactionCount: Int
  public var activeDurationSeconds: TimeInterval
  public var turnStartedAt: Date?
  public var lastActivityAt: Date?
  public var lastActivityText: String?
  public var lastActivityKind: CodexLiveActivityKind?
  public var executionConstraint: AgentRunExecutionConstraint?
  public var settlementOperationID: UUID?
  public var settlementCandidateVersion: Int?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    productID: UUID,
    sprintID: UUID? = nil,
    sprintItemID: UUID? = nil,
    workItemID: UUID,
    profileID: UUID,
    status: AgentRunStatus = .queued,
    codexThreadID: String? = nil,
    worktreePath: String? = nil,
    ticketBudgetUsed: Double = 0,
    contextUsedTokens: Int? = nil,
    contextWindowTokens: Int? = nil,
    compactionCount: Int = 0,
    cumulativeUsedTokens: Int? = nil,
    activeDurationSeconds: TimeInterval = 0,
    turnStartedAt: Date? = nil,
    lastActivityAt: Date? = nil,
    lastActivityText: String? = nil,
    lastActivityKind: CodexLiveActivityKind? = nil,
    executionConstraint: AgentRunExecutionConstraint? = nil,
    settlementOperationID: UUID? = nil,
    settlementCandidateVersion: Int? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.productID = productID
    self.sprintID = sprintID
    self.sprintItemID = sprintItemID
    self.workItemID = workItemID
    self.profileID = profileID
    self.status = status
    self.codexThreadID = codexThreadID
    self.worktreePath = worktreePath
    self.ticketBudgetUsed = ticketBudgetUsed
    self.contextUsedTokens = contextUsedTokens
    self.contextWindowTokens = contextWindowTokens
    self.compactionCount = compactionCount
    self.activeDurationSeconds = activeDurationSeconds
    self.cumulativeUsedTokens = cumulativeUsedTokens
    self.turnStartedAt = turnStartedAt
    self.lastActivityAt = lastActivityAt
    self.lastActivityText = lastActivityText
    self.lastActivityKind = lastActivityKind
    self.executionConstraint = executionConstraint
    self.settlementOperationID = settlementOperationID
    self.settlementCandidateVersion = settlementCandidateVersion
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var persistedActivity: CodexLiveActivity? {
    guard let lastActivityText, let lastActivityKind else { return nil }
    return CodexLiveActivity(text: lastActivityText, kind: lastActivityKind)
  }

  public func activeDuration(at referenceDate: Date = Date()) -> TimeInterval {
    let currentTurn =
      status == .running
      ? turnStartedAt.map { max(0, referenceDate.timeIntervalSince($0)) } ?? 0
      : 0
    return max(0, activeDurationSeconds + currentTurn)
  }
}

public struct AgentRunKnowledgePage: Codable, Hashable, Sendable {
  public let runID: UUID
  public let pageID: UUID

  public init(runID: UUID, pageID: UUID) {
    self.runID = runID
    self.pageID = pageID
  }
}

public struct AgentRunKnowledgeDestination: Codable, Hashable, Sendable {
  public let runID: UUID
  public let pageID: UUID

  public init(runID: UUID, pageID: UUID) {
    self.runID = runID
    self.pageID = pageID
  }
}

public struct ActivityEvent: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let sequence: Int64
  public let productID: UUID
  public let workItemID: UUID?
  public let kind: String
  public let actor: String
  public let detail: String
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    sequence: Int64 = 0,
    productID: UUID,
    workItemID: UUID? = nil,
    kind: String,
    actor: String,
    detail: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.sequence = sequence
    self.productID = productID
    self.workItemID = workItemID
    self.kind = kind
    self.actor = actor
    self.detail = detail
    self.createdAt = createdAt
  }
}

public enum RetrospectiveNoteCategory: String, Codable, CaseIterable, Sendable {
  case wentWell = "went_well"
  case couldImprove = "could_improve"
  case suggestedAction = "suggested_action"

  public var title: String {
    switch self {
    case .wentWell: "Went well"
    case .couldImprove: "Could improve"
    case .suggestedAction: "Suggested actions"
    }
  }
}

public enum RetrospectiveActionStatus: String, Codable, Sendable {
  case proposed
  case accepted
  case dismissed
}

public enum RetrospectiveActionDestination: String, Codable, CaseIterable, Sendable {
  case teamPractice = "team_practice"
  case backlog

  public var title: String {
    switch self {
    case .teamPractice: "Ways of working"
    case .backlog: "Backlog ticket"
    }
  }
}

public struct RetrospectiveNote: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let productID: UUID
  public let sprintID: UUID
  public let workItemID: UUID?
  public let profileID: UUID?
  public let authorName: String
  public let category: RetrospectiveNoteCategory
  public let body: String
  public let isActionCandidate: Bool
  public var actionStatus: RetrospectiveActionStatus?
  public let actionDestination: RetrospectiveActionDestination?
  public let expectedEffect: String?
  public let synthesisID: UUID?
  public var acceptedWorkItemID: UUID?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    productID: UUID,
    sprintID: UUID,
    workItemID: UUID? = nil,
    profileID: UUID? = nil,
    authorName: String,
    category: RetrospectiveNoteCategory,
    body: String,
    isActionCandidate: Bool = false,
    actionStatus: RetrospectiveActionStatus? = nil,
    actionDestination: RetrospectiveActionDestination? = nil,
    expectedEffect: String? = nil,
    synthesisID: UUID? = nil,
    acceptedWorkItemID: UUID? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.productID = productID
    self.sprintID = sprintID
    self.workItemID = workItemID
    self.profileID = profileID
    self.authorName = authorName
    self.category = category
    self.body = body
    self.isActionCandidate = isActionCandidate
    self.actionStatus = actionStatus
    self.actionDestination = actionDestination
    self.expectedEffect = expectedEffect
    self.synthesisID = synthesisID
    self.acceptedWorkItemID = acceptedWorkItemID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum RetrospectiveSynthesisStatus: String, Codable, Sendable {
  case pending
  case generating
  case completed
  case failed
  case skipped

  public var isResolved: Bool {
    self == .completed || self == .skipped
  }
}

public struct RetrospectiveSynthesis: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let productID: UUID
  public let sprintID: UUID
  public var profileID: UUID?
  public var status: RetrospectiveSynthesisStatus
  public var codexThreadID: String?
  public var codexTurnID: String?
  public var errorMessage: String?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    productID: UUID,
    sprintID: UUID,
    profileID: UUID? = nil,
    status: RetrospectiveSynthesisStatus = .pending,
    codexThreadID: String? = nil,
    codexTurnID: String? = nil,
    errorMessage: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.productID = productID
    self.sprintID = sprintID
    self.profileID = profileID
    self.status = status
    self.codexThreadID = codexThreadID
    self.codexTurnID = codexTurnID
    self.errorMessage = errorMessage
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct RetrospectiveActionSource: Codable, Hashable, Sendable {
  public let actionNoteID: UUID
  public let sourceNoteID: UUID

  public init(actionNoteID: UUID, sourceNoteID: UUID) {
    self.actionNoteID = actionNoteID
    self.sourceNoteID = sourceNoteID
  }
}

public struct ProtectedRepositoryPath: Codable, Hashable, Sendable {
  public let path: String
  public let objectMode: String

  public init(path: String, objectMode: String) {
    self.path = path
    self.objectMode = objectMode
  }
}

public struct ProductRepository: Codable, Hashable, Sendable {
  public let productID: UUID
  public let originURL: URL
  public let sourceDefaultBranch: String
  public let importedSHA: String
  public let protectedKnowledgePaths: [ProtectedRepositoryPath]
  public let blocksKnowledgeExport: Bool
  public let importedAt: Date

  public init(
    productID: UUID,
    originURL: URL,
    sourceDefaultBranch: String,
    importedSHA: String,
    protectedKnowledgePaths: [ProtectedRepositoryPath] = [],
    blocksKnowledgeExport: Bool = false,
    importedAt: Date = Date()
  ) {
    self.productID = productID
    self.originURL = originURL
    self.sourceDefaultBranch = sourceDefaultBranch
    self.importedSHA = importedSHA
    self.protectedKnowledgePaths = protectedKnowledgePaths.sorted {
      $0.path < $1.path
    }
    self.blocksKnowledgeExport = blocksKnowledgeExport
    self.importedAt = importedAt
  }
}

public enum RepositoryKnowledgeRunStatus: String, Codable, CaseIterable, Sendable {
  case pendingAnalysis = "pending_analysis"
  case analyzing
  case reviewing
  case publishing
  case completed
  case failed
  case interrupted
  case stale
}

public enum RepositoryKnowledgeRunPurpose: String, Codable, CaseIterable, Sendable {
  case knowledge
  case importedAppLaunch = "imported_app_launch"
}

public struct RepositoryKnowledgeRun: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let productID: UUID
  public let attempt: Int
  public let purpose: RepositoryKnowledgeRunPurpose
  public let analyzedSHA: String
  public let analyzerProfileID: UUID
  public let reviewerProfileID: UUID
  public var analyzerThreadID: String?
  public var analyzerTurnID: String?
  public var reviewerThreadID: String?
  public var reviewerTurnID: String?
  public var status: RepositoryKnowledgeRunStatus
  public var analysisSummary: String?
  public var reviewSummary: String?
  public var errorMessage: String?
  public var knowledgeExportPaths: [String]
  public var knowledgeCommitSHA: String?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    productID: UUID,
    attempt: Int,
    purpose: RepositoryKnowledgeRunPurpose = .knowledge,
    analyzedSHA: String,
    analyzerProfileID: UUID,
    reviewerProfileID: UUID,
    analyzerThreadID: String? = nil,
    analyzerTurnID: String? = nil,
    reviewerThreadID: String? = nil,
    reviewerTurnID: String? = nil,
    status: RepositoryKnowledgeRunStatus = .pendingAnalysis,
    analysisSummary: String? = nil,
    reviewSummary: String? = nil,
    errorMessage: String? = nil,
    knowledgeExportPaths: [String] = [],
    knowledgeCommitSHA: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.productID = productID
    self.attempt = attempt
    self.purpose = purpose
    self.analyzedSHA = analyzedSHA
    self.analyzerProfileID = analyzerProfileID
    self.reviewerProfileID = reviewerProfileID
    self.analyzerThreadID = analyzerThreadID
    self.analyzerTurnID = analyzerTurnID
    self.reviewerThreadID = reviewerThreadID
    self.reviewerTurnID = reviewerTurnID
    self.status = status
    self.analysisSummary = analysisSummary
    self.reviewSummary = reviewSummary
    self.errorMessage = errorMessage
    self.knowledgeExportPaths = knowledgeExportPaths.sorted()
    self.knowledgeCommitSHA = knowledgeCommitSHA
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum RepositoryKnowledgeDraftOperation: String, Codable, CaseIterable, Sendable {
  case update
  case create
}

public enum RepositoryKnowledgeDraftStatus: String, Codable, CaseIterable, Sendable {
  case proposed
  case approved
  case published
  case rejected
  case superseded
}

public struct RepositoryEvidence: Codable, Hashable, Sendable {
  public let path: String
  public let startLine: Int?
  public let endLine: Int?

  public init(path: String, startLine: Int? = nil, endLine: Int? = nil) {
    self.path = path
    self.startLine = startLine
    self.endLine = endLine
  }
}

public enum RepositoryLaunchProposalStatus: String, Codable, CaseIterable, Sendable {
  case proposed
  case approved
  case published
  case rejected
}

public struct RepositoryLaunchProposal: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let runID: UUID
  public let specification: DemoLaunchSpecification
  public let evidence: [RepositoryEvidence]
  public var status: RepositoryLaunchProposalStatus
  public var reviewExplanation: String?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    runID: UUID,
    specification: DemoLaunchSpecification,
    evidence: [RepositoryEvidence],
    status: RepositoryLaunchProposalStatus = .proposed,
    reviewExplanation: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.runID = runID
    self.specification = specification
    self.evidence = evidence
    self.status = status
    self.reviewExplanation = reviewExplanation
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct RepositoryLaunchReviewDecision: Codable, Equatable, Sendable {
  public let proposalID: UUID
  public let approved: Bool
  public let explanation: String

  public init(proposalID: UUID, approved: Bool, explanation: String) {
    self.proposalID = proposalID
    self.approved = approved
    self.explanation = explanation
  }
}

public struct RepositoryKnowledgeDraft: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let runID: UUID
  public let operation: RepositoryKnowledgeDraftOperation
  public let targetPageID: UUID?
  public let parentPageID: UUID?
  public let basePageTitle: String?
  public let basePageBodyMarkdown: String?
  public let basePageUpdatedAt: Date?
  public let title: String
  public let proposedBodyMarkdown: String
  public let rationale: String
  public let evidence: [RepositoryEvidence]
  public var status: RepositoryKnowledgeDraftStatus
  public var reviewExplanation: String?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    runID: UUID,
    operation: RepositoryKnowledgeDraftOperation,
    targetPageID: UUID? = nil,
    parentPageID: UUID? = nil,
    basePageTitle: String? = nil,
    basePageBodyMarkdown: String? = nil,
    basePageUpdatedAt: Date? = nil,
    title: String,
    proposedBodyMarkdown: String,
    rationale: String,
    evidence: [RepositoryEvidence],
    status: RepositoryKnowledgeDraftStatus = .proposed,
    reviewExplanation: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.runID = runID
    self.operation = operation
    self.targetPageID = targetPageID
    self.parentPageID = parentPageID
    self.basePageTitle = basePageTitle
    self.basePageBodyMarkdown = basePageBodyMarkdown
    self.basePageUpdatedAt = basePageUpdatedAt
    self.title = title
    self.proposedBodyMarkdown = proposedBodyMarkdown
    self.rationale = rationale
    self.evidence = evidence
    self.status = status
    self.reviewExplanation = reviewExplanation
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct RepositoryKnowledgeReviewDecision: Codable, Hashable, Sendable {
  public let draftID: UUID
  public let approved: Bool
  public let explanation: String

  public init(draftID: UUID, approved: Bool, explanation: String) {
    self.draftID = draftID
    self.approved = approved
    self.explanation = explanation
  }
}

public struct RepositoryKnowledgePublicationProjection: Codable, Hashable, Sendable {
  public let pages: [KnowledgePage]
  public let changedPageIDs: [UUID]

  public init(pages: [KnowledgePage], changedPageIDs: [UUID]) {
    self.pages = pages
    self.changedPageIDs = changedPageIDs
  }
}

public enum KnowledgePageKind: String, Codable, Sendable {
  case section
  case page
  case deliveryNote = "delivery_note"
}

public enum KnowledgeVerificationStatus: String, Codable, Sendable {
  case proposed
  case verified
  case stale

  public var title: String {
    rawValue.capitalized
  }
}

public struct KnowledgePage: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let productID: UUID
  public var parentID: UUID?
  public var title: String
  public var slug: String
  public var bodyMarkdown: String
  public var kind: KnowledgePageKind
  public var verificationStatus: KnowledgeVerificationStatus
  public var sortOrder: Int
  public var sourceWorkItemID: UUID?
  public var sourceRepositoryKnowledgeRunID: UUID?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    productID: UUID,
    parentID: UUID? = nil,
    title: String,
    slug: String,
    bodyMarkdown: String = "",
    kind: KnowledgePageKind = .page,
    verificationStatus: KnowledgeVerificationStatus = .verified,
    sortOrder: Int = 0,
    sourceWorkItemID: UUID? = nil,
    sourceRepositoryKnowledgeRunID: UUID? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.productID = productID
    self.parentID = parentID
    self.title = title
    self.slug = slug
    self.bodyMarkdown = bodyMarkdown
    self.kind = kind
    self.verificationStatus = verificationStatus
    self.sortOrder = sortOrder
    self.sourceWorkItemID = sourceWorkItemID
    self.sourceRepositoryKnowledgeRunID = sourceRepositoryKnowledgeRunID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct KnowledgePageRevision: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let pageID: UUID
  public let version: Int
  public let bodyMarkdown: String
  public let authorName: String
  public let changeSummary: String
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    pageID: UUID,
    version: Int,
    bodyMarkdown: String,
    authorName: String,
    changeSummary: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.pageID = pageID
    self.version = version
    self.bodyMarkdown = bodyMarkdown
    self.authorName = authorName
    self.changeSummary = changeSummary
    self.createdAt = createdAt
  }
}

public enum CandidateRevisionStatus: String, Codable, CaseIterable, Sendable {
  case queuedForReview = "queued_for_review"
  case reviewing
  case queuedForIntegration = "queued_for_integration"
  case integrating
  case resolvingConflict = "resolving_conflict"
  case changesRequested = "changes_requested"
  case readyForDemo = "ready_for_demo"
  case promoting
  case accepted
  case superseded
  case failed
}

public enum CandidateDeliveryKind: String, Codable, CaseIterable, Sendable {
  case repositoryChange = "repository_change"
  case localOutcome = "local_outcome"

  public var changesRepository: Bool {
    self == .repositoryChange
  }
}

public struct CandidateRevision: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let productID: UUID
  public let sprintID: UUID
  public let sprintItemID: UUID
  public let workItemID: UUID
  public let implementationRunID: UUID
  public let version: Int
  public let deliveryKind: CandidateDeliveryKind
  public let branchName: String
  public let baseSHA: String
  public let headSHA: String
  public var integratedSHA: String?
  public let worktreePath: String
  public var integrationWorktreePath: String?
  public var status: CandidateRevisionStatus
  public var reviewedHeadSHA: String?
  public var reviewRunID: UUID?
  public let commitCount: Int
  public let executionResultJSON: String
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    productID: UUID,
    sprintID: UUID,
    sprintItemID: UUID,
    workItemID: UUID,
    implementationRunID: UUID,
    version: Int,
    deliveryKind: CandidateDeliveryKind = .repositoryChange,
    branchName: String,
    baseSHA: String,
    headSHA: String,
    integratedSHA: String? = nil,
    worktreePath: String,
    integrationWorktreePath: String? = nil,
    status: CandidateRevisionStatus = .queuedForIntegration,
    reviewedHeadSHA: String? = nil,
    reviewRunID: UUID? = nil,
    commitCount: Int,
    executionResultJSON: String,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.productID = productID
    self.sprintID = sprintID
    self.sprintItemID = sprintItemID
    self.workItemID = workItemID
    self.implementationRunID = implementationRunID
    self.version = version
    self.deliveryKind = deliveryKind
    self.branchName = branchName
    self.baseSHA = baseSHA
    self.headSHA = headSHA
    self.integratedSHA = integratedSHA
    self.worktreePath = worktreePath
    self.integrationWorktreePath = integrationWorktreePath
    self.status = status
    self.reviewedHeadSHA = reviewedHeadSHA
    self.reviewRunID = reviewRunID
    self.commitCount = commitCount
    self.executionResultJSON = executionResultJSON
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var shortHeadSHA: String {
    String(headSHA.prefix(8))
  }

  public var shortIntegratedSHA: String? {
    integratedSHA.map { String($0.prefix(8)) }
  }
}

public enum KnowledgePageProposalOperation: String, Codable, CaseIterable, Sendable {
  case create
  case update
}

public enum KnowledgePageProposalStatus: String, Codable, CaseIterable, Sendable {
  case proposed
  case reviewed
  case accepted
  case rejected
  case superseded
}

public struct KnowledgePageProposal: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let productID: UUID
  public let sprintID: UUID
  public let workItemID: UUID
  public let candidateRevisionID: UUID
  public let operation: KnowledgePageProposalOperation
  public let targetPageID: UUID?
  public let parentPageID: UUID?
  public let basePageTitle: String?
  public let basePageBodyMarkdown: String?
  public let basePageUpdatedAt: Date?
  public let title: String
  public let proposedBodyMarkdown: String
  public let rationale: String
  public var status: KnowledgePageProposalStatus
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    productID: UUID,
    sprintID: UUID,
    workItemID: UUID,
    candidateRevisionID: UUID,
    operation: KnowledgePageProposalOperation,
    targetPageID: UUID? = nil,
    parentPageID: UUID? = nil,
    basePageTitle: String? = nil,
    basePageBodyMarkdown: String? = nil,
    basePageUpdatedAt: Date? = nil,
    title: String,
    proposedBodyMarkdown: String,
    rationale: String,
    status: KnowledgePageProposalStatus = .proposed,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.productID = productID
    self.sprintID = sprintID
    self.workItemID = workItemID
    self.candidateRevisionID = candidateRevisionID
    self.operation = operation
    self.targetPageID = targetPageID
    self.parentPageID = parentPageID
    self.basePageTitle = basePageTitle
    self.basePageBodyMarkdown = basePageBodyMarkdown
    self.basePageUpdatedAt = basePageUpdatedAt
    self.title = title
    self.proposedBodyMarkdown = proposedBodyMarkdown
    self.rationale = rationale
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}
