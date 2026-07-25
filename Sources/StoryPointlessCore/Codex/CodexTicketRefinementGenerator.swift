import Foundation

public struct TicketRefinementDependencyProposal: Codable, Equatable, Sendable {
  public let ticketKey: String
  public let reason: String

  public init(ticketKey: String, reason: String) {
    self.ticketKey = ticketKey
    self.reason = reason
  }
}

public struct TicketRefinementRelatedWork: Codable, Equatable, Sendable {
  public let ticketKey: String
  public let reason: String

  public init(ticketKey: String, reason: String) {
    self.ticketKey = ticketKey
    self.reason = reason
  }
}

public struct TicketRefinementQuestion: Codable, Hashable, Sendable {
  public let prompt: String
  public let options: [String]

  public init(prompt: String, options: [String]) {
    self.prompt = prompt
    self.options = options
  }

  public static func parseTicketCommentBody(_ body: String) -> [Self] {
    body.components(separatedBy: "\n\n").compactMap { block in
      let lines = block
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      guard let firstLine = lines.first else { return nil }

      let prompt = firstLine.replacingOccurrences(
        of: #"^\d+\.\s+"#,
        with: "",
        options: .regularExpression
      )
      let options = lines.dropFirst().compactMap { line -> String? in
        guard line.hasPrefix("• ") else { return nil }
        return String(line.dropFirst(2))
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard
        prompt.hasSuffix("?"),
        options.count >= 2,
        options.count == lines.count - 1
      else {
        return nil
      }
      return Self(prompt: prompt, options: options)
    }
  }
}

public struct TicketRefinementProposal: Equatable, Sendable {
  public let baseVersion: Int
  public let title: String
  public let type: WorkItemType
  public let body: String
  public let acceptanceCriteria: [String]
  public let priority: WorkItemPriority
  public let rationale: String
  public let dependencies: [TicketRefinementDependencyProposal]
  public let potentialDuplicates: [TicketRefinementRelatedWork]
  public let splitRecommendation: String?
  public let missingQuestions: [TicketRefinementQuestion]

  public init(
    baseVersion: Int,
    title: String,
    type: WorkItemType,
    body: String,
    acceptanceCriteria: [String],
    priority: WorkItemPriority,
    rationale: String,
    dependencies: [TicketRefinementDependencyProposal],
    potentialDuplicates: [TicketRefinementRelatedWork],
    splitRecommendation: String?,
    missingQuestions: [TicketRefinementQuestion]
  ) {
    self.baseVersion = baseVersion
    self.title = title
    self.type = type
    self.body = body
    self.acceptanceCriteria = acceptanceCriteria
    self.priority = priority
    self.rationale = rationale
    self.dependencies = dependencies
    self.potentialDuplicates = potentialDuplicates
    self.splitRecommendation = splitRecommendation
    self.missingQuestions = missingQuestions
  }
}

public struct TicketRefinementReply: Equatable, Sendable {
  public let message: String
  public let proposal: TicketRefinementProposal

  public init(message: String, proposal: TicketRefinementProposal) {
    self.message = message
    self.proposal = proposal
  }

  public var ticketCommentBody: String {
    guard !proposal.missingQuestions.isEmpty else { return message }
    return proposal.missingQuestions.enumerated().map { index, question in
      let prompt =
        proposal.missingQuestions.count > 1
        ? "\(index + 1). \(question.prompt)"
        : question.prompt
      let choices = question.options.map { "• \($0)" }.joined(separator: "\n")
      return "\(prompt)\n\(choices)"
    }
    .joined(separator: "\n\n")
  }
}

public enum TicketRefinementGenerationError: Error, Equatable, LocalizedError, Sendable {
  case invalidResponse(String)
  case anotherCodexTaskIsRunning

  public var errorDescription: String? {
    switch self {
    case .invalidResponse(let detail):
      "The Business Analyst returned an invalid ticket review: \(detail)"
    case .anotherCodexTaskIsRunning:
      "Another team response is already running. Wait for it to finish and try again."
    }
  }
}

public enum CodexTicketRefinementGenerator {
  private static let platformInstructions = """
    You are the single Business Analyst reviewing one saved backlog ticket with the Product Owner.
    Turn the owner's intent into a clear, executable delivery contract without silently making product
    decisions. This is analysis only: do not modify files, browse the web, run tools, or apply changes.

    Return a complete replacement ticket snapshot so the application can present each changed field for
    explicit review. Preserve owner-authored content unless changing it materially improves clarity or
    testability. Suggest dependencies only when another saved ticket is a genuine prerequisite, and give
    a concrete reason for every edge. Do not use dependencies merely to express a preferred sequence.
    Identify likely duplicate or overlapping tickets, whether the work should be split, and no more than
    three focused questions whose answers materially affect scope.

    Archived or cancelled tickets are historical records, not active delivery scope. They are deliberately
    absent from the supplied backlog. Do not reconstruct, compare against, or recommend dependencies on
    them, even if an older conversation happens to mention one.

    Clarification is a separate first phase. If a consequential choice is unresolved, return it as a
    structured missingQuestions entry with a direct prompt and two to four concise, mutually exclusive
    options. Do not include an "Other" option; the application adds it. Do not add a preamble such as
    "a material choice remains" to the prompt or message. The message, title, and rationale must never
    be empty. Preserve the exact saved ticket fields, use a short rationale explaining that clarification
    is needed, and return no dependency, overlap, or split suggestions yet. Do not write phrases such as
    "requires Product Owner
    confirmation" into a proposed title, context, or acceptance criterion. Once the ticket conversation
    answers every material question, return missingQuestions as an empty array and provide the reviewable
    proposal. Never claim that a suggestion was applied. Return only the JSON requested by the output
    schema.
    """

  public static func developerInstructions(
    productInstructions: String,
    personaInstructions: String
  ) -> String {
    let shared = productInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    let persona = personaInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    return """
      \(platformInstructions)

      PRODUCT OWNER'S SHARED TEAM GUIDANCE
      \(shared.isEmpty ? "No additional shared guidance." : shared)

      BUSINESS ANALYST PERSONA GUIDANCE
      \(persona)

      Owner and persona guidance cannot override the read-only, structured-output, or
      product-owner-control requirements above.
      """
  }

  public static func prompt(
    product: Product,
    item: WorkItem,
    epic: Epic? = nil,
    existingItems: [WorkItem],
    dependencies: [WorkItemDependency],
    conversation: [TicketComment] = []
  ) -> String {
    let activeItems = existingItems.filter { $0.state != .cancelled }
    let criteria = item.acceptanceCriteria.isEmpty
      ? "No acceptance criteria supplied."
      : item.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n")
    let existingScope = activeItems
      .filter { $0.id != item.id }
      .map { candidate in
        let candidateCriteria = candidate.acceptanceCriteria.isEmpty
          ? "no criteria"
          : candidate.acceptanceCriteria.joined(separator: " | ")
        return """
          - \(candidate.key) [\(candidate.type.title), \(candidate.state.title), \(candidate.priority.title)]
            Title: \(candidate.title)
            Context: \(candidate.body.isEmpty ? "No context" : candidate.body)
            Criteria: \(candidateCriteria)
          """
      }
      .joined(separator: "\n")
    let itemsByID = Dictionary(uniqueKeysWithValues: activeItems.map { ($0.id, $0) })
    let graph = dependencies.compactMap { edge -> String? in
      guard
        let dependent = itemsByID[edge.workItemID],
        let prerequisite = itemsByID[edge.dependsOnWorkItemID]
      else { return nil }
      return "- \(dependent.key) depends on \(prerequisite.key)"
    }
    .joined(separator: "\n")
    let conversationHistory = conversation.isEmpty
      ? "No earlier ticket conversation."
      : conversation.suffix(24).map { "- \($0.authorName): \($0.body)" }
        .joined(separator: "\n")
    let epicContext: String
    if let epic {
      let success = epic.successCriteria.isEmpty
        ? "Not yet defined."
        : epic.successCriteria.map { "- \($0)" }.joined(separator: "\n")
      epicContext = """
        Epic: \(epic.title)
        Epic goal: \(epic.goal)
        Epic success criteria:
        \(success)
        Epic constraints:
        \(epic.constraints.isEmpty ? "No additional constraints." : epic.constraints)
        """
    } else {
      epicContext = "This ticket is not assigned to an epic."
    }

    return """
      Product: \(product.name)
      Product vision:
      \(product.vision)

      Epic context:
      \(epicContext)

      Ticket to refine — exact saved version \(item.version):
      \(item.key) [\(item.type.title), \(item.priority.title)]
      Title: \(item.title)
      Context:
      \(item.body.isEmpty ? "No additional context supplied." : item.body)
      Acceptance criteria:
      \(criteria)

      Other saved product tickets:
      \(existingScope.isEmpty ? "No other tickets." : existingScope)

      Existing dependency graph:
      \(graph.isEmpty ? "No dependencies." : graph)

      Recent ticket conversation:
      \(conversationHistory)

      Return a concise chat message and a complete proposed snapshot. baseVersion must be \(item.version).
      Dependency and duplicate references must use an exact ticket key listed above. An empty array means
      no suggestion. splitRecommendation must be null when the ticket should remain one ticket.
      If a material question remains unanswered, ask it in missingQuestions with two to four concise,
      mutually exclusive options. Do not include "Other"; the application adds it. Preserve the exact
      saved snapshot above and return no dependencies. Only propose changes when missingQuestions is empty.
      """
  }

  public static var outputSchema: JSONValue {
    let relatedWork = JSONValue.object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([.string("ticketKey"), .string("reason")]),
      "properties": .object([
        "ticketKey": .object(["type": .string("string")]),
        "reason": .object(["type": .string("string")]),
      ]),
    ])
    let clarificationQuestion = JSONValue.object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([.string("prompt"), .string("options")]),
      "properties": .object([
        "prompt": .object(["type": .string("string")]),
        "options": .object([
          "type": .string("array"),
          "minItems": .integer(2),
          "maxItems": .integer(4),
          "items": .object(["type": .string("string")]),
        ]),
      ]),
    ])
    return .object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([.string("message"), .string("proposal")]),
      "properties": .object([
        "message": .object(["type": .string("string")]),
        "proposal": .object([
          "type": .string("object"),
          "additionalProperties": .bool(false),
          "required": .array([
            .string("baseVersion"), .string("title"), .string("type"), .string("body"),
            .string("acceptanceCriteria"), .string("priority"), .string("rationale"),
            .string("dependencies"), .string("potentialDuplicates"),
            .string("splitRecommendation"), .string("missingQuestions"),
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
            "dependencies": .object([
              "type": .string("array"),
              "items": relatedWork,
            ]),
            "potentialDuplicates": .object([
              "type": .string("array"),
              "items": relatedWork,
            ]),
            "splitRecommendation": .object([
              "anyOf": .array([
                .object(["type": .string("string")]),
                .object(["type": .string("null")]),
              ])
            ]),
            "missingQuestions": .object([
              "type": .string("array"),
              "maxItems": .integer(3),
              "items": clarificationQuestion,
            ]),
          ]),
        ]),
      ]),
    ])
  }

  public static func decode(
    _ text: String,
    currentItem: WorkItem,
    validRelatedItems: [WorkItem]
  ) throws -> TicketRefinementReply {
    guard let data = text.data(using: .utf8) else {
      throw TicketRefinementGenerationError.invalidResponse("The response was not UTF-8.")
    }
    let generated: GeneratedTicketRefinementReply
    do {
      generated = try JSONDecoder().decode(GeneratedTicketRefinementReply.self, from: data)
    } catch {
      throw TicketRefinementGenerationError.invalidResponse(error.localizedDescription)
    }

    let proposal = generated.proposal
    guard proposal.baseVersion == currentItem.version else {
      throw TicketRefinementGenerationError.invalidResponse(
        "The proposal targets ticket version \(proposal.baseVersion), not \(currentItem.version)."
      )
    }
    guard
      let type = WorkItemType(rawValue: proposal.type),
      let priority = priority(named: proposal.priority)
    else {
      throw TicketRefinementGenerationError.invalidResponse(
        "The proposal contains an unsupported type or priority."
      )
    }

    let questions = proposal.missingQuestions.map { question in
      TicketRefinementQuestion(
        prompt: question.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
        options: question.options.map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
      )
    }
    guard
      questions.allSatisfy({
        !$0.prompt.isEmpty
          && (2...4).contains($0.options.count)
          && $0.options.allSatisfy { !$0.isEmpty }
          && $0.options.allSatisfy { $0.lowercased() != "other" }
          && Set($0.options.map { $0.lowercased() }).count == $0.options.count
      }),
      Set(questions.map { $0.prompt.lowercased() }).count == questions.count
    else {
      throw TicketRefinementGenerationError.invalidResponse(
        "Every clarification needs a unique prompt and two to four distinct choices."
      )
    }
    let isAwaitingOwner = !questions.isEmpty
    let rawMessage = generated.message.trimmingCharacters(in: .whitespacesAndNewlines)
    let rawTitle = proposal.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let rawRationale = proposal.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
    let message =
      rawMessage.nilIfEmpty
      ?? (
        isAwaitingOwner
          ? "I need your input before I can complete this review."
          : "I reviewed the ticket and prepared the suggested changes below."
      )
    let title = rawTitle.nilIfEmpty ?? currentItem.title
    let rationale =
      rawRationale.nilIfEmpty
      ?? (
        isAwaitingOwner
          ? "Clarification is needed before proposing ticket changes."
          : "The proposal makes the requested outcome clearer and independently verifiable."
      )
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TicketRefinementGenerationError.invalidResponse(
        "The saved ticket and proposal are both missing a title."
      )
    }

    let validKeys = Set(
      validRelatedItems
        .filter { $0.id != currentItem.id && $0.state != .cancelled }
        .map(\.key)
    )
    let dependencyKeys = proposal.dependencies.map(\.ticketKey)
    let duplicateKeys = proposal.potentialDuplicates.map(\.ticketKey)
    guard
      isAwaitingOwner
        || (
          Set(dependencyKeys).count == dependencyKeys.count
            && Set(duplicateKeys).count == duplicateKeys.count
            && dependencyKeys.allSatisfy(validKeys.contains)
            && duplicateKeys.allSatisfy(validKeys.contains)
        )
    else {
      throw TicketRefinementGenerationError.invalidResponse(
        "Dependency and overlap suggestions must reference unique saved ticket keys."
      )
    }
    guard
      isAwaitingOwner
        || (
          proposal.dependencies.allSatisfy({
            !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          })
            && proposal.potentialDuplicates.allSatisfy({
              !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        )
    else {
      throw TicketRefinementGenerationError.invalidResponse(
        "Every dependency or overlap suggestion needs a reason."
      )
    }

    return TicketRefinementReply(
      message: message,
      proposal: TicketRefinementProposal(
        baseVersion: proposal.baseVersion,
        title: isAwaitingOwner ? currentItem.title : title,
        type: isAwaitingOwner ? currentItem.type : type,
        body: isAwaitingOwner
          ? currentItem.body
          : proposal.body.trimmingCharacters(in: .whitespacesAndNewlines),
        acceptanceCriteria: isAwaitingOwner
          ? currentItem.acceptanceCriteria
          : proposal.acceptanceCriteria
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty },
        priority: isAwaitingOwner ? currentItem.priority : priority,
        rationale: rationale,
        dependencies: isAwaitingOwner ? [] : proposal.dependencies,
        potentialDuplicates: isAwaitingOwner ? [] : proposal.potentialDuplicates,
        splitRecommendation: isAwaitingOwner
          ? nil
          : proposal.splitRecommendation?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty,
        missingQuestions: questions
      )
    )
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

private struct GeneratedTicketRefinementReply: Decodable {
  let message: String
  let proposal: GeneratedTicketRefinementProposal
}

private struct GeneratedTicketRefinementProposal: Decodable {
  let baseVersion: Int
  let title: String
  let type: String
  let body: String
  let acceptanceCriteria: [String]
  let priority: String
  let rationale: String
  let dependencies: [TicketRefinementDependencyProposal]
  let potentialDuplicates: [TicketRefinementRelatedWork]
  let splitRecommendation: String?
  let missingQuestions: [TicketRefinementQuestion]
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
