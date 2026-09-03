import Foundation

public struct TicketConversationReply: Equatable, Sendable {
  public let message: String
  public let proposal: SprintPlanningTicketProposal?

  public init(message: String, proposal: SprintPlanningTicketProposal? = nil) {
    self.message = message
    self.proposal = proposal
  }

  public var ticketCommentBody: String {
    guard proposal != nil else { return message }
    return """
      \(message)

      Proposed reviewable ticket changes. No changes were applied automatically.
      """
  }
}

public enum TicketConversationGenerationError: Error, Equatable, LocalizedError, Sendable {
  case invalidResponse(String)
  case anotherCodexTaskIsRunning

  public var errorDescription: String? {
    switch self {
    case .invalidResponse(let detail):
      "The team member returned an invalid reply: \(detail)"
    case .anotherCodexTaskIsRunning:
      "Another team response is already running. Wait for it to finish and try again."
    }
  }
}

public enum CodexTicketConversation {
  private static let platformInstructions = """
    You are the single team member explicitly selected by the product owner in a live conversation
    attached to one ticket. Respond only as your configured role. Do not contact, simulate, or aggregate
    replies from other team members.

    This is a concise workplace chat, not an implementation turn. Do not modify files, browse the web,
    or claim to update the ticket. You may use read-only local tools to inspect product Git history.
    Answer the owner's actual question directly from that evidence and the ticket conversation. Prefer
    one to four short sentences. If the requested rationale is not
    established, say that plainly rather than inventing one. Ask at most one focused follow-up question
    when it is necessary.

    If the conversation establishes a concrete improvement to the ticket, you may attach one complete,
    versioned replacement snapshot for explicit product owner review. This is appropriate when the owner
    asks to capture an agreed choice, or when your answer directly resolves an ambiguity in the delivery
    contract. Preserve every field you do not intend to change. Never claim the proposal was applied.
    Use null when the exchange is only explanatory or exploratory. Dependency analysis, duplicate checks,
    and broad refinement belong to the automatic business analyst refinement flow. Return only the JSON requested
    by the output schema.
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
    item: WorkItem,
    prerequisites: [WorkItem],
    previousComments: [TicketComment],
    ownerMessage: String,
    allowsProposal: Bool = true
  ) -> String {
    let criteria =
      item.acceptanceCriteria.isEmpty
      ? "No acceptance criteria supplied."
      : item.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n")
    let blockers =
      prerequisites.isEmpty
      ? "No active ticket dependencies."
      : prerequisites.map { "- \($0.key): \($0.title) [\($0.state.title)]" }
        .joined(separator: "\n")
    let history =
      previousComments.isEmpty
      ? "No earlier ticket conversation."
      : previousComments.suffix(24).map { "- \($0.authorName): \($0.body)" }
        .joined(separator: "\n")
    let proposalGuidance =
      allowsProposal
      ? """
      If your answer establishes a useful ticket edit, return the complete revised title, type,
      context, acceptance criteria, and priority, preserving unchanged fields. Set baseVersion
      to \(item.version). Otherwise return proposal as null.
      """
      : """
      This is an explanatory question about sprint delivery. Answer it directly and return
      proposal as null. Do not resume implementation, invalidate a reviewed candidate, or imply
      that the ticket status changed.
      """

    return """
      Product: \(product.name)
      Ticket: \(item.key) [\(item.type.title), \(item.priority.title), version \(item.version)]
      Title: \(item.title)
      Context:
      \(item.body.isEmpty ? "No additional context supplied." : item.body)
      Acceptance criteria:
      \(criteria)

      Active dependencies:
      \(blockers)

      Recent ticket conversation:
      \(history)

      Product owner message:
      \(ownerMessage)

      \(proposalGuidance)
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
          "enum": .array([
            .string("urgent"), .string("high"), .string("normal"), .string("low"),
          ]),
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

  public static func decode(
    _ text: String,
    currentItem: WorkItem
  ) throws -> TicketConversationReply {
    guard let data = text.data(using: .utf8) else {
      throw TicketConversationGenerationError.invalidResponse("The response was not UTF-8.")
    }
    let generated: GeneratedTicketConversationReply
    do {
      generated = try JSONDecoder().decode(GeneratedTicketConversationReply.self, from: data)
    } catch {
      throw TicketConversationGenerationError.invalidResponse(error.localizedDescription)
    }
    let message = generated.message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else {
      throw TicketConversationGenerationError.invalidResponse("A message is required.")
    }
    let proposal: SprintPlanningTicketProposal?
    if let generatedProposal = generated.proposal {
      guard
        generatedProposal.baseVersion == currentItem.version,
        let type = WorkItemType(rawValue: generatedProposal.type),
        let priority = priority(named: generatedProposal.priority),
        !generatedProposal.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !generatedProposal.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw TicketConversationGenerationError.invalidResponse(
          "A proposal needs the current ticket version, title, type, priority, and rationale."
        )
      }
      proposal = SprintPlanningTicketProposal(
        baseVersion: generatedProposal.baseVersion,
        title: generatedProposal.title.trimmingCharacters(in: .whitespacesAndNewlines),
        type: type,
        body: generatedProposal.body.trimmingCharacters(in: .whitespacesAndNewlines),
        acceptanceCriteria: generatedProposal.acceptanceCriteria
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty },
        priority: priority,
        rationale: generatedProposal.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    } else {
      proposal = nil
    }
    return TicketConversationReply(message: message, proposal: proposal)
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

private struct GeneratedTicketConversationReply: Decodable {
  let message: String
  let proposal: GeneratedTicketConversationProposal?
}

private struct GeneratedTicketConversationProposal: Decodable {
  let baseVersion: Int
  let title: String
  let type: String
  let body: String
  let acceptanceCriteria: [String]
  let priority: String
  let rationale: String
}
