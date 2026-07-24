import Foundation

public struct EpicClarificationReply: Equatable, Sendable {
  public let message: String
  public let questions: [TicketRefinementQuestion]
  public let readyToPlan: Bool

  public init(
    message: String,
    questions: [TicketRefinementQuestion],
    readyToPlan: Bool
  ) {
    self.message = message
    self.questions = questions
    self.readyToPlan = readyToPlan
  }
}

public enum EpicClarificationGenerationError: Error, Equatable, LocalizedError, Sendable {
  case invalidResponse(String)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse(let detail):
      "The Business Analyst returned an invalid epic clarification: \(detail)"
    }
  }
}

public enum CodexEpicClarificationGenerator {
  public static var outputSchema: JSONValue {
    let question: JSONValue = .object([
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
      "required": .array([
        .string("message"), .string("questions"), .string("readyToPlan"),
      ]),
      "properties": .object([
        "message": .object(["type": .string("string")]),
        "questions": .object([
          "type": .string("array"),
          "maxItems": .integer(3),
          "items": question,
        ]),
        "readyToPlan": .object(["type": .string("boolean")]),
      ]),
    ])
  }

  public static func initialPrompt(
    product: Product,
    epic: Epic,
    existingItems: [WorkItem]
  ) -> String {
    let scope = activeScope(existingItems)
    return """
      Before proposing an epic or any delivery tickets, have a short requirements conversation with the
      Product Owner. Ask only material questions whose answers can change scope, success criteria, user
      experience, constraints, or the ticket breakdown.

      Product: \(product.name)
      Product vision:
      \(product.vision)

      Outcome captured from the Product Owner:
      \(epic.goal)

      Existing active work (do not duplicate it):
      \(scope)

      This is the first clarification turn. Ask one to three concise questions with two to four mutually
      exclusive, business-friendly choices each. Put your recommended choice first and suffix it with
      "(Recommended)". Do not include an "Other" option; the interface adds it. Keep the message short and
      conversational. Set readyToPlan to false while questions remain. Do not propose tickets yet.
      """
  }

  public static func followUpPrompt(answers: [String]) -> String {
    let answerText = answers.enumerated()
      .map { "\($0.offset + 1). \($0.element)" }
      .joined(separator: "\n")
    return """
      The Product Owner answered:
      \(answerText)

      Decide whether a further material clarification is genuinely required. If so, ask one to three new
      concise questions using the same choice format and set readyToPlan to false. Do not repeat resolved
      questions. If the outcome is sufficiently clear to define a coherent epic and delivery backlog,
      return no questions, set readyToPlan to true, and briefly confirm that you are ready to prepare the
      plan. Do not propose tickets in this response.
      """
  }

  public static func finalPlanPrompt(
    product: Product,
    epic: Epic,
    existingItems: [WorkItem],
    rejectedSuggestions: [TicketSuggestion]
  ) -> String {
    CodexTicketSuggestionGenerator.epicPrompt(
      product: product,
      epic: epic,
      existingItems: existingItems,
      rejectedSuggestions: rejectedSuggestions
    )
      + """

        Use every requirement resolved in the preceding conversation. Return the complete epic metadata
        and ticket plan now. Do not ask more questions in this response.
        """
  }

  public static func decode(_ text: String) throws -> EpicClarificationReply {
    guard let data = text.data(using: .utf8) else {
      throw EpicClarificationGenerationError.invalidResponse(
        "The response was not UTF-8."
      )
    }

    let generated: GeneratedEpicClarificationReply
    do {
      generated = try JSONDecoder().decode(GeneratedEpicClarificationReply.self, from: data)
    } catch {
      throw EpicClarificationGenerationError.invalidResponse(error.localizedDescription)
    }

    let questions = generated.questions.map {
      TicketRefinementQuestion(
        prompt: $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
        options: $0.options.map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
      )
    }
    guard
      questions.allSatisfy({
        !$0.prompt.isEmpty
          && (2...4).contains($0.options.count)
          && $0.options.allSatisfy { !$0.isEmpty && $0.lowercased() != "other" }
          && Set($0.options.map { $0.lowercased() }).count == $0.options.count
      }),
      Set(questions.map { $0.prompt.lowercased() }).count == questions.count
    else {
      throw EpicClarificationGenerationError.invalidResponse(
        "Every clarification needs a unique prompt and two to four distinct choices."
      )
    }
    guard generated.readyToPlan == questions.isEmpty else {
      throw EpicClarificationGenerationError.invalidResponse(
        "A response is ready to plan only when no clarification questions remain."
      )
    }

    let message = generated.message.trimmingCharacters(in: .whitespacesAndNewlines)
    return EpicClarificationReply(
      message: message.isEmpty
        ? (generated.readyToPlan
          ? "That gives me what I need to prepare the epic plan."
          : "I need a little more detail before I prepare the epic plan.")
        : message,
      questions: questions,
      readyToPlan: generated.readyToPlan
    )
  }

  private static func activeScope(_ items: [WorkItem]) -> String {
    let active = items.filter { $0.state != .cancelled }
    guard !active.isEmpty else { return "There is no existing active work." }
    return active
      .map { "- \($0.key) [\($0.type.title)]: \($0.title)" }
      .joined(separator: "\n")
  }
}

private struct GeneratedEpicClarificationReply: Decodable {
  let message: String
  let questions: [TicketRefinementQuestion]
  let readyToPlan: Bool
}
