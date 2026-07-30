import Foundation

public enum ProductConversationGenerationError: Error, LocalizedError, Sendable {
  case invalidResponse(String)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse(let detail):
      "The team member returned an invalid Conversation reply: \(detail)"
    }
  }
}

public struct ProductConversationReply: Equatable, Sendable {
  public let message: String
  public let threadTitle: String

  public init(message: String, threadTitle: String) {
    self.message = message
    self.threadTitle = threadTitle
  }
}

public enum CodexProductConversation {
  public static func developerInstructions(
    productInstructions: String,
    customInstructions: String,
    recipient: AgentProfile
  ) -> String {
    """
    You are \(recipient.name), the single team member selected by the Product Owner in the product
    Conversation. Respond only as your configured \(recipient.role.title) role. Do not simulate or
    aggregate replies from other team members.

    This is read-only product chat. Do not modify files, create or edit product records, start
    delivery, change permissions, or browse the web. You may use read-only local tools to query the
    live product database and inspect product Git history. Prefer the stable agent-facing database
    views described below for their documented product evidence, but do not treat that list as
    exhaustive. When the Product Owner's question needs evidence those views do not contain, inspect
    the read-only SQLite schema and query the relevant product-scoped tables directly.

    For questions such as "which ticket implemented X?", search agent_tickets, agent_work_log,
    agent_verified_knowledge, and agent_delivery_provenance, then inspect Git when commit-level
    evidence is useful. For current execution questions, inspect agent_runs together with work_items
    and agent_profiles. Use the matching run's status, turn and activity timestamps, and last activity
    before inferring that work is stuck. For permission questions, inspect
    agent_permission_requests and
    report the request's current status, plain-language title, reason, and exact capability detail.
    Do not treat the absence of an agent_work_log comment as evidence that a live run made no
    progress, because that view does not contain every operational Work log artefact.

    Never reveal internal Codex thread, turn, or server-request identifiers, permission signatures,
    worktree paths, or other implementation-only identifiers. Cite ticket keys, knowledge page
    titles, and commit SHAs in plain language when they support the answer. Distinguish evidence from
    inference and say when the available product history does not establish an answer.

    A chat request never changes the product by itself. Explain a recommended change, but do not claim
    it was applied. Prefer a concise workplace-chat answer unless the Product Owner asks for detail.
    Make the message easy to scan: use short paragraphs with blank lines between distinct ideas, and
    use Markdown bullets or a short heading only when they improve the answer. Avoid dense walls of
    text. Also return a stable sentence-case thread title of about five words (four to six words are
    accepted) that summarizes the Product Owner's request, similar to a concise task title. Never
    return a single-word topic label. Return only the JSON requested by the output schema.

    \(CodexLifecycleGuidance.configuredRoleGuidance(
      role: recipient.role,
      productInstructions: productInstructions,
      customInstructions: customInstructions
    ))
    """
  }

  public static func newThreadPrompt(
    ownerMessage: String,
    recentRoomMessages: [ProductConversationMessage]
  ) -> String {
    let history = recentRoomMessages.isEmpty
      ? "No earlier product-room messages."
      : recentRoomMessages.suffix(100).map {
        "- \($0.authorName): \($0.body)"
      }.joined(separator: "\n")
    return """
      Recent product-room context, oldest first:
      \(history)

      Product Owner:
      \(ownerMessage)

      Answer the Product Owner's latest message and name this thread.
      """
  }

  public static func resumedThreadPrompt(ownerMessage: String) -> String {
    """
    Product Owner follow-up:
    \(ownerMessage)

    Continue this Conversation thread using its existing context and current product evidence.
    Keep its concise thread title stable unless this follow-up materially clarifies the request.
    """
  }

  public static func recoveryPrompt(
    messages: [ProductConversationMessage]
  ) -> String {
    let history = messages.map {
      "- \($0.authorName): \($0.body)"
    }.joined(separator: "\n")
    return """
      This Conversation is being recovered because its previous agent session is unavailable.
      Thread history, oldest first:
      \(history)

      Answer the latest Product Owner message without repeating an answer already present.
      Return a concise title for the recovered thread as well.
      """
  }

  public static func handoffPrompt(
    messages: [ProductConversationMessage]
  ) -> String {
    let history = messages.map {
      "- \($0.authorName): \($0.body)"
    }.joined(separator: "\n")
    return """
      The Product Owner has selected you to continue an existing Chat thread previously answered by
      another team member. Use the durable visible thread history below as conversation context, but
      respond only from your own configured role. Re-query current product evidence before relying
      on earlier claims when freshness matters.

      Thread history, oldest first:
      \(history)

      Answer the latest Product Owner message without repeating an answer already present. Return an
      updated approximately five-word title only if the latest question materially changes the topic.
      """
  }

  public static let outputSchema: JSONValue = .object([
    "type": .string("object"),
    "additionalProperties": .bool(false),
    "required": .array([
      .string("message"),
      .string("threadTitle"),
    ]),
    "properties": .object([
      "message": .object([
        "type": .string("string"),
        "minLength": .integer(1),
      ]),
      "threadTitle": .object([
        "type": .string("string"),
        "minLength": .integer(1),
        "maxLength": .integer(60),
        "description": .string(
          "A sentence-case thread title containing four to six words; aim for five."
        ),
      ])
    ]),
  ])

  public static func decode(_ response: String) throws -> ProductConversationReply {
    guard let data = response.data(using: .utf8) else {
      throw ProductConversationGenerationError.invalidResponse(
        "The response was not UTF-8."
      )
    }
    let value: JSONValue
    do {
      value = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      throw ProductConversationGenerationError.invalidResponse(
        "The response was not valid JSON."
      )
    }
    let rawMessage = value["message"]?.stringValue
    let rawThreadTitle = value["threadTitle"]?.stringValue
    guard
      let message = rawMessage?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !message.isEmpty
    else {
      throw ProductConversationGenerationError.invalidResponse(
        "The response did not contain a message."
      )
    }
    guard
      let threadTitle = rawThreadTitle?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !threadTitle.isEmpty,
      threadTitle.count <= 60,
      !threadTitle.contains(where: \.isNewline),
      (4...6).contains(
        threadTitle.split(whereSeparator: \.isWhitespace).count
      )
    else {
      throw ProductConversationGenerationError.invalidResponse(
        "The response did not contain a four-to-six-word thread title."
      )
    }
    return ProductConversationReply(
      message: message,
      threadTitle: threadTitle
    )
  }
}
