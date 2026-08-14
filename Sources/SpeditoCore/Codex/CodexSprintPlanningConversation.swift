import Foundation

public struct SprintPlanningTicketSnapshot: Codable, Equatable, Sendable {
  public let version: Int
  public let title: String
  public let type: WorkItemType
  public let body: String
  public let acceptanceCriteria: [String]
  public let priority: WorkItemPriority

  public init(
    version: Int,
    title: String,
    type: WorkItemType,
    body: String,
    acceptanceCriteria: [String],
    priority: WorkItemPriority
  ) {
    self.version = version
    self.title = title
    self.type = type
    self.body = body
    self.acceptanceCriteria = acceptanceCriteria
    self.priority = priority
  }

  public func applying(to item: WorkItem) -> WorkItem {
    var updatedItem = item
    updatedItem.title = title
    updatedItem.type = type
    updatedItem.body = body
    updatedItem.acceptanceCriteria = acceptanceCriteria
    updatedItem.priority = priority
    return updatedItem
  }
}

public struct SprintPlanningTicketProposal: Equatable, Sendable {
  public let baseVersion: Int
  public let title: String
  public let type: WorkItemType
  public let body: String
  public let acceptanceCriteria: [String]
  public let priority: WorkItemPriority
  public let rationale: String

  public init(
    baseVersion: Int,
    title: String,
    type: WorkItemType,
    body: String,
    acceptanceCriteria: [String],
    priority: WorkItemPriority,
    rationale: String
  ) {
    self.baseVersion = baseVersion
    self.title = title
    self.type = type
    self.body = body
    self.acceptanceCriteria = acceptanceCriteria
    self.priority = priority
    self.rationale = rationale
  }

  public var snapshot: SprintPlanningTicketSnapshot {
    SprintPlanningTicketSnapshot(
      version: baseVersion,
      title: title,
      type: type,
      body: body,
      acceptanceCriteria: acceptanceCriteria,
      priority: priority
    )
  }
}

public struct SprintPlanningConversationReply: Equatable, Sendable {
  public let message: String
  public let proposal: SprintPlanningTicketProposal?

  public init(message: String, proposal: SprintPlanningTicketProposal?) {
    self.message = message
    self.proposal = proposal
  }

  public var ticketCommentBody: String {
    guard let proposal else { return message }
    return """
      \(message)

      Proposed ticket changes
      \(proposal.rationale)
      """
  }
}

public enum SprintPlanningConversationError: Error, Equatable, LocalizedError, Sendable {
  case invalidResponse(String)
  case anotherCodexTaskIsRunning

  public var errorDescription: String? {
    switch self {
    case .invalidResponse(let detail):
      "The team member returned an invalid planning response: \(detail)"
    case .anotherCodexTaskIsRunning:
      "Another team response is already running. Wait for it to finish and try again."
    }
  }
}

public enum CodexSprintPlanningConversation {
  private static let platformInstructions = """
    You are the single team member explicitly selected by the product owner in a live, ticket-scoped
    sprint planning chat. The product owner is refining one ticket before delivery and remains the
    decision-maker. Respond only as your configured role. Do not contact, simulate, or aggregate replies
    from other team members. This is planning, not implementation: do not modify files, browse the web,
    start delivery, or make product decisions for the owner. You may use read-only local tools to query
    the live product database and inspect product Git history.

    Write the message as a natural workplace-chat reply: direct, warm, and short. Prefer one to four
    concise sentences. Do not restate the supplied product or ticket context, write an essay, or add
    headings unless the product owner asks for detail. If essential information is missing, ask at most
    one focused question. The prompt supplies the product name, exact ticket version, dependencies,
    proposed assignee, current sprint scope, and recent ticket conversation; use that context silently.

    If a ticket edit would materially improve the delivery contract, you may also propose one complete
    replacement snapshot based on the exact ticket snapshot in the prompt. Briefly explain the useful
    change in the chat message. Never claim that a proposal has been applied. Use a null proposal when no
    edit is needed. Return only the JSON requested by the schema.
    """

  public static func developerInstructions(
    productInstructions: String,
    customInstructions: String,
    recipient: AgentProfile
  ) -> String {
    return """
      \(platformInstructions)

      SELECTED TEAM MEMBER
      \(recipient.name) — \(recipient.role.title)

      \(CodexLifecycleGuidance.configuredRoleGuidance(
        role: recipient.role,
        productInstructions: productInstructions,
        customInstructions: customInstructions
      ))
      """
  }

  public static func prompt(
    product: Product,
    itemKey: String,
    snapshot: SprintPlanningTicketSnapshot,
    prerequisites: [WorkItem],
    sprintItems: [WorkItem],
    proposedAssignee: AgentProfile?,
    previousComments: [TicketComment],
    ownerMessage: String
  ) -> String {
    let criteria =
      snapshot.acceptanceCriteria.isEmpty
      ? "No acceptance criteria supplied."
      : snapshot.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n")
    let blockers =
      prerequisites.isEmpty
      ? "No ticket dependencies."
      : prerequisites.map { "- \($0.key): \($0.title) [\($0.state.title)]" }
        .joined(separator: "\n")
    let scope = sprintItems.map { "- \($0.key): \($0.title)" }.joined(separator: "\n")
    let history =
      previousComments.isEmpty
      ? "No earlier ticket comments."
      : previousComments.suffix(20).map { "- \($0.authorName): \($0.body)" }
        .joined(separator: "\n")

    return """
      Product: \(product.name)
      Exact owner-visible ticket snapshot (version \(snapshot.version)):
      Ticket: \(itemKey) [\(snapshot.type.title), \(snapshot.priority.title)]
      Title: \(snapshot.title)
      Context:
      \(snapshot.body.isEmpty ? "No additional context supplied." : snapshot.body)
      Acceptance criteria:
      \(criteria)

      Dependencies:
      \(blockers)

      Proposed delivery assignee:
      \(proposedAssignee.map { "\($0.name) (\($0.role.title), \($0.model), \($0.reasoningEffort) effort)" } ?? "Unassigned")

      Current next-sprint scope:
      \(scope.isEmpty ? "No other scoped tickets." : scope)

      Recent ticket conversation:
      \(history)

      Product owner message:
      \(ownerMessage)

      If you propose a change, return the complete revised title, type, context, acceptance criteria,
      and priority, preserving every owner field you do not intend to change. Set baseVersion to
      \(snapshot.version). Otherwise return proposal as null.
      """
  }

  public static var outputSchema: JSONValue {
    let proposal = JSONValue.object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([
        .string("baseVersion"), .string("title"), .string("type"), .string("body"),
        .string("acceptanceCriteria"), .string("priority"), .string("rationale"),
      ]),
      "properties": .object([
        "baseVersion": .object(["type": .string("integer")]),
        "title": .object(["type": .string("string")]),
        "type": .object([
          "type": .string("string"),
          "enum": .array(WorkItemType.allCases.map { .string($0.rawValue) }),
        ]),
        "body": .object(["type": .string("string")]),
        "acceptanceCriteria": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
        ]),
        "priority": .object([
          "type": .string("string"),
          "enum": .array([.string("urgent"), .string("high"), .string("normal"), .string("low")]),
        ]),
        "rationale": .object(["type": .string("string")]),
      ]),
    ])
    return .object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([.string("message"), .string("proposal")]),
      "properties": .object([
        "message": .object(["type": .string("string")]),
        "proposal": .object([
          "anyOf": .array([
            proposal,
            .object(["type": .string("null")]),
          ])
        ]),
      ]),
    ])
  }

  public static func decode(_ text: String) throws -> SprintPlanningConversationReply {
    guard let data = text.data(using: .utf8) else {
      throw SprintPlanningConversationError.invalidResponse("The response was not UTF-8.")
    }
    let generated: GeneratedReply
    do {
      generated = try JSONDecoder().decode(GeneratedReply.self, from: data)
    } catch {
      throw SprintPlanningConversationError.invalidResponse(error.localizedDescription)
    }
    let message = generated.message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else {
      throw SprintPlanningConversationError.invalidResponse("A message is required.")
    }
    let proposal: SprintPlanningTicketProposal?
    if let generatedProposal = generated.proposal {
      guard
        let type = WorkItemType(rawValue: generatedProposal.type),
        let priority = priority(named: generatedProposal.priority),
        !generatedProposal.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !generatedProposal.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw SprintPlanningConversationError.invalidResponse(
          "A proposal needs a valid title, type, priority, and rationale."
        )
      }
      proposal = SprintPlanningTicketProposal(
        baseVersion: generatedProposal.baseVersion,
        title: generatedProposal.title,
        type: type,
        body: generatedProposal.body,
        acceptanceCriteria: generatedProposal.acceptanceCriteria,
        priority: priority,
        rationale: generatedProposal.rationale
      )
    } else {
      proposal = nil
    }
    return SprintPlanningConversationReply(message: message, proposal: proposal)
  }

  private static func priority(named value: String) -> WorkItemPriority? {
    switch value {
    case "urgent": .urgent
    case "high": .high
    case "normal": .normal
    case "low": .low
    default: nil
    }
  }
}

private struct GeneratedReply: Decodable {
  let message: String
  let proposal: GeneratedProposal?
}

private struct GeneratedProposal: Decodable {
  let baseVersion: Int
  let title: String
  let type: String
  let body: String
  let acceptanceCriteria: [String]
  let priority: String
  let rationale: String
}
