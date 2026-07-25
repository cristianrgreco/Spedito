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

      Actively inspect consequential decision surfaces relevant to this outcome, including data or
      content sources, third-party services, licensing, cost, reliability, privacy, security, and
      maintenance ownership. Resolve those choices during this conversation whenever the available
      context supports a responsible recommendation. Recommend a sensible default with a brief rationale.
      Do not silently defer an unresolved Product Owner decision into a backlog ticket. Offer research as
      a choice only when external evidence is genuinely required; the Product Owner choosing it is explicit
      permission to create a time-boxed research ticket with a concrete comparison and recommendation.
      Selecting a specific real external source or service is not resolved merely by agreeing desired
      constraints when current evidence about candidates, terms, suitability, or operation is still needed.
      In that situation, make the work consequence explicit in the choices. Distinguish:
      - creating a Business Analyst research ticket to compare candidates and recommend one for approval;
      - the Product Owner naming an already approved choice; and
      - explicitly delegating implementation-time selection to the implementer without a separate
        recommendation.
      Recommend the research option when no choice is already approved and a responsible recommendation
      needs external evidence. Do not offer a vague option such as “let the team choose.”

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
      questions. Before declaring the outcome ready, confirm that consequential choices such as sources,
      third-party services, licensing, cost, reliability, privacy, security, and maintenance ownership
      have either been resolved or explicitly delegated to research by the Product Owner. Do not silently
      turn an unresolved choice into a discovery ticket. Constraints for an unnamed external source do not
      resolve its selection. Treat an instruction to identify, compare, recommend, or choose it using
      current external evidence as authorisation for Business Analyst research. A broad answer such as
      “let the team choose” is ambiguous: ask whether the Product Owner wants a separate recommendation or
      explicitly delegates implementation-time selection without one. If the outcome is sufficiently clear
      to define a coherent epic and delivery backlog, return no questions, set readyToPlan to true, and
      briefly confirm any authorised research that the plan will include. Do not propose tickets in this
      response.
      """
  }

  public static func recoveryPrompt(
    product: Product,
    epic: Epic,
    existingItems: [WorkItem],
    messages: [EpicPlanningConversationMessage]
  ) -> String {
    let scope = activeScope(existingItems)
    let transcript = durableTranscript(messages)
    return """
      The previous Codex thread for this epic is no longer available. Continue the requirements
      conversation from the durable StoryPointless transcript below. Treat every Product Owner answer
      in the transcript as authoritative. Do not repeat resolved questions or ask the Product Owner to
      re-enter an answer.

      Product: \(product.name)
      Product vision:
      \(product.vision)

      Outcome captured from the Product Owner:
      \(epic.goal)

      Existing active work (do not duplicate it):
      \(scope)

      Durable conversation:
      \(transcript)

      Decide whether a further material clarification is genuinely required. If so, ask one to three new
      concise questions with two to four mutually exclusive, business-friendly choices each. Put your
      recommended choice first and suffix it with "(Recommended)". Do not include an "Other" option; the
      interface adds it. Before declaring the outcome ready, confirm that consequential choices such as
      data or content sources, third-party services, licensing, cost, reliability, privacy, security, and
      maintenance ownership have either been resolved or explicitly delegated to research by the Product
      Owner. Do not silently turn an unresolved choice into a discovery ticket. Constraints for an unnamed
      external source do not resolve its selection. Treat an instruction to identify, compare, recommend,
      or choose it using current external evidence as authorisation for Business Analyst research. A broad
      answer such as “let the team choose” is ambiguous: ask whether the Product Owner wants a separate
      recommendation or explicitly delegates implementation-time selection without one. If the outcome is
      sufficiently clear to define a coherent epic and delivery backlog, return no questions, set
      readyToPlan to true, and briefly confirm any authorised research that the plan will include. Do not
      propose tickets in this response.
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
        and ticket plan now. Create research or discovery work only when the Product Owner explicitly
        requested it or agreed during clarification that more evidence is required. An instruction for the
        Business Analyst or team to identify, compare, recommend, or choose a real external source using
        current evidence is such authorisation. Give that work a separate Business Analyst ticket; do not
        bury it inside design or implementation. The only exception is an explicit Product Owner decision
        to delegate implementation-time selection to the implementer without a separate recommendation.
        Otherwise return tickets that deliver the agreed outcome, not tickets that discover what the
        outcome should be. If approved research is needed before delivery, include it together with the
        dependent design, implementation, and verification work; do not return a research-only plan for an
        epic whose success criteria include a product change. Do not ask more questions in this response.
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

  private static func durableTranscript(
    _ messages: [EpicPlanningConversationMessage]
  ) -> String {
    let entries = messages.compactMap { message -> String? in
      switch message.author {
      case .businessAnalyst:
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : "Business Analyst: \(body)"
      case .owner:
        if !message.answeredQuestions.isEmpty {
          let answers = message.answeredQuestions.map {
            "- Question: \($0.question.prompt)\n  Answer: \($0.answer)"
          }
          .joined(separator: "\n")
          return "Product Owner answered:\n\(answers)"
        }
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : "Product Owner: \(body)"
      case .system:
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : "StoryPointless: \(body)"
      }
    }
    return entries.isEmpty
      ? "No earlier messages were available."
      : entries.joined(separator: "\n\n")
  }
}

private struct GeneratedEpicClarificationReply: Decodable {
  let message: String
  let questions: [TicketRefinementQuestion]
  let readyToPlan: Bool
}
