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

      Before deciding the outcome is ready to plan, inspect verified Environments knowledge and
      repository-owned manifests, scripts, CI, and documentation. Decide whether the existing product
      environment can build, test, prototype, demo, and locally run the likely delivery work. Do not scan
      the Product Owner's Mac for installed package managers or treat an incidental executable as an
      approved product environment. If the environment is absent or insufficient and executable work is
      likely, ask at most one business-friendly question about an existing technology or hosting
      constraint versus having the team recommend the simplest suitable option. Do not ask a
      non-technical owner to choose Node, Python, package-manager paths, caches, or sandbox permissions
      unless they already expressed a relevant technical preference. Every choice must itself be a
      complete answer; never offer a placeholder such as “I’ll provide,” “we’ll decide later,” or “tell
      the team separately.” The interface allows exactly one selection per question, so choices must be
      mutually exclusive, self-contained descriptions of the complete resulting scope. Never make one
      choice an addition to another with wording such as “add … as well,” “include … too,” or “also.”
      Restate the full outcome in every option. If the owner may have an unlisted technology or hosting
      constraint, say in the question that they can choose Other and describe it in the interface's text
      field. Explain material cost, maintenance, privacy, portability, and deployment consequences in the
      choices.

      Resolve a standard foundation recommendation in this conversation when current product and
      repository evidence is enough. If a responsible recommendation genuinely needs current external
      evidence, offer a separate Business Analyst research outcome; choosing it authorises that research.
      Make the consequence explicit in the choices: a standard recommendation uses the product and
      repository evidence already available and creates no research ticket, while time-boxed research
      creates a separate Business Analyst ticket that compares current options before the environment is
      established.
      The eventual plan must keep stack recommendation separate from the Implementer task that establishes
      and verifies the environment. Considering the intended deployment destination early does not
      authorise production credentials, accounts, signing identities, or a deployment.

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
      briefly confirm any authorised research that the plan will include.

      Also re-check verified Environments knowledge and repository evidence. If likely executable work is
      not covered, resolve any material technology or hosting preference in business terms before setting
      readyToPlan to true. Recommend the simplest suitable option when the owner has no preference. Do not
      ask them to interpret runtime paths or permission details. Every choice must be a complete answer,
      never a promise to provide information later. Because the owner can select only one option per
      question, every option must restate the complete resulting scope rather than add to a previous option;
      never use incremental labels such as “as well,” “too,” or “also.” Direct an unlisted constraint
      through the interface's Other text field. Distinguish using current product and repository evidence
      without a research ticket from authorising a time-boxed Business Analyst comparison of current
      options. Confirm whether the final plan must include an environment-establishment prerequisite, and
      authorise separate environment research only when the Product Owner agreed that current external
      evidence is needed. Do not propose tickets in this response.
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
      readyToPlan to true, and briefly confirm any authorised research that the plan will include.

      Re-check verified Environments knowledge and repository evidence before declaring readiness. When
      likely executable work lacks a sufficient environment, recover or ask the one material owner-facing
      question about an existing technology or hosting constraint versus a team recommendation. Never ask
      for package-manager paths, cache access, or other machine plumbing. Every choice must be a complete
      answer, never “I’ll provide” or another promise of a later answer. The owner can select exactly one
      option per question, so every option must describe the complete resulting scope and must not compound
      another option with “as well,” “too,” “also,” or equivalent wording. Tell the owner to use the
      interface's Other text field for an unlisted constraint. Distinguish a recommendation made from
      existing evidence without a research ticket from time-boxed research that creates one. Confirm that
      the final plan will include an environment-establishment prerequisite, with separate research only
      when the Product Owner authorised evidence gathering. Do not propose tickets in this response.
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
        downstream work needed to achieve the epic; do not return a research-only plan for an epic whose
        success criteria include a product change. Do not force that work into a standard sequence of
        research, design, implementation, and verification tickets. Make verification explicit in the
        relevant acceptance criteria, using a separate ticket only when it has an independently valuable
        outcome.

        Return the structured environment assessment required by the schema. If executable delivery is not
        covered by verified Environments guidance, include one concrete Implementer-owned environment
        establishment task and make every ticket that needs it depend on it directly or transitively.
        Mark research, product decisions, and neutral design artefacts independent only when they can
        truthfully proceed without that environment. If a material stack recommendation needed research,
        include the separately authorised Business Analyst recommendation before the establishment task.
        The establishment task must verify stable repository entry points, run-private temporary and cache
        locations, required capabilities, managed demo readiness, limitations, and the complete
        Environments Product knowledge update. Do not ask more questions in this response.
        """
  }

  public static func finalPlanRecoveryPrompt(
    product: Product,
    epic: Epic,
    existingItems: [WorkItem],
    rejectedSuggestions: [TicketSuggestion],
    messages: [EpicPlanningConversationMessage]
  ) -> String {
    """
      The previous Codex thread stopped while preparing the final epic plan. Reconstruct the plan from
      the durable StoryPointless transcript below. Treat every Product Owner answer as authoritative,
      retain the Business Analyst's confirmed scope, and do not ask the Product Owner to repeat anything.

      Durable conversation:
      \(durableTranscript(messages))

      \(finalPlanPrompt(
        product: product,
        epic: epic,
        existingItems: existingItems,
        rejectedSuggestions: rejectedSuggestions
      ))
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
      guard message.kind != .chat else { return nil }
      switch message.author {
      case .businessAnalyst:
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : "Business Analyst: \(body)"
      case .agent:
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = message.participantName ?? "Team member"
        return body.isEmpty ? nil : "\(name): \(body)"
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
