import Foundation

public struct EpicConversationReply: Equatable, Sendable {
  public let message: String

  public init(message: String) {
    self.message = message
  }
}

public enum EpicConversationGenerationError: Error, Equatable, LocalizedError, Sendable {
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

public enum CodexEpicConversation {
  private static let platformInstructions = """
    You are the single team member explicitly selected by the Product Owner in a live conversation
    attached to one epic. Respond only as your configured role. Do not contact, simulate, or aggregate
    replies from other team members.

    This is a concise workplace chat, not an implementation or planning turn. Do not modify files,
    browse the web, create tickets, or claim to update the epic. You may use read-only local tools to
    query the live product database and inspect product Git history. Answer the owner's actual question
    directly from that evidence and the Epic Conversation. Prefer one to four short sentences. If the
    requested rationale is not established, say that plainly rather than inventing one. Ask at most one
    focused follow-up question when it is necessary.

    The separate Business Analyst refinement questions are governed inputs. Ordinary chat never answers,
    dismisses, or changes them. If the owner asks for an epic change, discuss the recommendation without
    claiming it was applied. Return only the JSON requested by the output schema.
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
    epic: Epic,
    relatedItems: [WorkItem],
    proposedItems: [TicketSuggestion],
    previousMessages: [EpicPlanningConversationMessage],
    ownerMessage: String
  ) -> String {
    let successCriteria = epic.successCriteria.isEmpty
      ? "No success criteria supplied."
      : epic.successCriteria.map { "- \($0)" }.joined(separator: "\n")
    let constraints = epic.constraints.trimmingCharacters(in: .whitespacesAndNewlines)
    let acceptedScope = relatedItems.isEmpty
      ? "No accepted tickets belong to this epic."
      : relatedItems.map { "- \($0.key) [\($0.state.title)]: \($0.title)" }
        .joined(separator: "\n")
    let proposedScope = proposedItems.isEmpty
      ? "No ticket proposals are awaiting review."
      : proposedItems.map { "- \($0.title)" }.joined(separator: "\n")
    let history = chatHistory(previousMessages)

    return """
      Product: \(product.name)
      Product vision:
      \(product.vision)

      Epic: \(epic.title) [\(epic.status.title)]
      Goal and customer value:
      \(epic.goal)

      Success criteria:
      \(successCriteria)

      Constraints and context:
      \(constraints.isEmpty ? "No constraints supplied." : constraints)

      Accepted tickets:
      \(acceptedScope)

      Proposed tickets:
      \(proposedScope)

      Recent epic conversation:
      \(history)

      Product Owner message:
      \(ownerMessage)
      """
  }

  public static let outputSchema: JSONValue = .object([
    "type": .string("object"),
    "additionalProperties": .bool(false),
    "required": .array([.string("message")]),
    "properties": .object([
      "message": .object(["type": .string("string")])
    ]),
  ])

  public static func decode(_ text: String) throws -> EpicConversationReply {
    guard let data = text.data(using: .utf8) else {
      throw EpicConversationGenerationError.invalidResponse(
        "The response was not UTF-8."
      )
    }
    let generated: GeneratedEpicConversationReply
    do {
      generated = try JSONDecoder().decode(GeneratedEpicConversationReply.self, from: data)
    } catch {
      throw EpicConversationGenerationError.invalidResponse(error.localizedDescription)
    }
    let message = generated.message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else {
      throw EpicConversationGenerationError.invalidResponse("A message is required.")
    }
    return EpicConversationReply(message: message)
  }

  private static func chatHistory(
    _ messages: [EpicPlanningConversationMessage]
  ) -> String {
    let entries = messages
      .filter { $0.kind == .chat }
      .suffix(24)
      .compactMap { message -> String? in
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        switch message.author {
        case .owner:
          return "Product Owner: \(body)"
        case .agent, .businessAnalyst:
          return "\(message.participantName ?? "Team member"): \(body)"
        case .system:
          return "StoryPointless: \(body)"
        }
      }
    return entries.isEmpty
      ? "No earlier epic chat."
      : entries.joined(separator: "\n")
  }
}

private struct GeneratedEpicConversationReply: Decodable {
  let message: String
}
