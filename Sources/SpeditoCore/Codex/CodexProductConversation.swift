import Foundation

public enum ProductConversationGenerationError: Error, LocalizedError, Sendable {
  case invalidResponse(String)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse(let detail):
      "The team member returned an invalid conversation reply: \(detail)"
    }
  }
}

public enum CodexProductConversation {
  public static func developerInstructions(
    productInstructions: String,
    customInstructions: String,
    recipient: AgentProfile
  ) -> String {
    """
    You are \(recipient.name), the single team member selected by the product owner in the product
    conversation. Respond only as your configured \(recipient.role.title) role. Do not simulate or
    aggregate replies from other team members.

    This is read-only product chat. Do not modify files, create or edit product records, start
    delivery, change permissions, or browse the web. You may use read-only local tools to query the
    live product database and inspect product Git history. Prefer the stable agent-facing database
    views described below for their documented product evidence, but do not treat that list as
    exhaustive. When the product owner's question needs evidence those views do not contain, inspect
    the read-only SQLite schema and query the relevant product-scoped tables directly.

    For questions such as "which ticket implemented X?", search agent_tickets, agent_work_log,
    agent_verified_knowledge, and agent_delivery_provenance, then inspect Git when commit-level
    evidence is useful. For current execution questions, inspect agent_runs together with work_items
    and agent_profiles. Use the matching run's status, turn and activity timestamps, and last activity
    before inferring that work is stuck. For permission questions, inspect
    agent_permission_requests and
    report the request's current status, plain-language title, reason, and exact capability detail.
    Do not treat the absence of an agent_work_log comment as evidence that a live run made no
    progress, because that view does not contain every operational work log artefact.

    Never reveal internal Codex thread, turn, or server-request identifiers, permission signatures,
    worktree paths, or other implementation-only identifiers. Cite ticket keys, knowledge page
    titles, and commit SHAs in plain language when they support the answer. Distinguish evidence from
    inference and say when the available product history does not establish an answer.

    A chat request never changes the product by itself. Explain a recommended change, but do not claim
    it was applied. Prefer a concise workplace-chat answer unless the product owner asks for detail.
    Make the message easy to scan: use short paragraphs with blank lines between distinct ideas, and
    use Markdown bullets or a short heading only when they improve the answer. Avoid dense walls of
    text.

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
    let history =
      recentRoomMessages.isEmpty
      ? "No earlier product-room messages."
      : recentRoomMessages.suffix(100).map {
        "- \($0.authorName): \($0.body)"
      }.joined(separator: "\n")
    return """
      Recent product-room context, oldest first:
      \(history)

      Product owner:
      \(ownerMessage)

      Answer the product owner's latest message.
      """
  }

  public static func resumedThreadPrompt(ownerMessage: String) -> String {
    """
    Product owner follow-up:
    \(ownerMessage)

    Continue this conversation thread using its existing context and current product evidence.
    """
  }

  public static func recoveryPrompt(
    messages: [ProductConversationMessage]
  ) -> String {
    let history = messages.map {
      "- \($0.authorName): \($0.body)"
    }.joined(separator: "\n")
    return """
      This conversation is being recovered because its previous agent session is unavailable.
      Thread history, oldest first:
      \(history)

      Answer the latest product owner message without repeating an answer already present.
      """
  }

  public static func handoffPrompt(
    messages: [ProductConversationMessage]
  ) -> String {
    let history = messages.map {
      "- \($0.authorName): \($0.body)"
    }.joined(separator: "\n")
    return """
      The product owner has selected you to continue an existing Chat thread previously answered by
      another team member. Use the durable visible thread history below as conversation context, but
      respond only from your own configured role. Re-query current product evidence before relying
      on earlier claims when freshness matters.

      Thread history, oldest first:
      \(history)

      Answer the latest product owner message without repeating an answer already present.
      """
  }

  public static let titleGenerationTimeout: Duration = .seconds(15)

  public static let titleDeveloperInstructions = """
    Name one product conversation from the product owner's first message. This is a read-only writing
    task. Use only the supplied message; do not inspect files, query product data, browse the web, run
    tools, or invent context.

    Return a stable sentence-case thread title of four to six words that summarizes the request,
    similar to a concise task title. Aim for five words and never return a vague single-word topic
    label. Return only the JSON requested by the output schema.
    """

  public static func titlePrompt(ownerMessage: String) -> String {
    """
    Product owner's first message:
    \(ownerMessage)

    Name this conversation in four to six words.
    """
  }

  public static let titleOutputSchema: JSONValue = .object([
    "type": .string("object"),
    "additionalProperties": .bool(false),
    "required": .array([
      .string("threadTitle")
    ]),
    "properties": .object([
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

  public static func decodeMessage(_ response: String) throws -> String {
    let message = response.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else {
      throw ProductConversationGenerationError.invalidResponse(
        "The response did not contain a message."
      )
    }
    return message
  }

  public static func decodeTitle(_ response: String) throws -> String {
    guard let data = response.data(using: .utf8) else {
      throw ProductConversationGenerationError.invalidResponse(
        "The title response was not UTF-8."
      )
    }
    let value: JSONValue
    do {
      value = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      throw ProductConversationGenerationError.invalidResponse(
        "The title response was not valid JSON."
      )
    }
    guard
      let threadTitle = value["threadTitle"]?.stringValue?
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
    return threadTitle
  }
}
