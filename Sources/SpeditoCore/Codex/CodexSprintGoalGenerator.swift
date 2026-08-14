import Foundation

public enum SprintGoalGenerationError: Error, Equatable, LocalizedError, Sendable {
  case invalidResponse(String)
  case anotherCodexTaskIsRunning
  case noTickets
  case timedOut

  public var errorDescription: String? {
    switch self {
    case .invalidResponse(let detail):
      "The business analyst returned an invalid sprint goal: \(detail)"
    case .anotherCodexTaskIsRunning:
      "Another team response is already running. Wait for it to finish and try again."
    case .noTickets:
      "Add at least one ticket to the sprint before generating its goal."
    case .timedOut:
      "The sprint goal took longer than 15 seconds. Try again."
    }
  }
}

public enum CodexSprintGoalGenerator {
  public static let totalTimeout: Duration = .seconds(15)

  private static let platformInstructions = """
    You are the business analyst helping a product owner name the outcome of one planned sprint.
    This is a read-only writing task. Use only the supplied ticket titles as evidence of sprint scope;
    do not inspect files, browse the web, run tools, or invent requirements that are not supported by
    those titles.

    Write one short, memorable, outcome-oriented sprint goal that a non-technical product owner can
    scan at a glance. Aim for five to ten words and never exceed 80 characters. Capture the single
    user-visible outcome that unifies the sprint rather than summarizing every ticket. Omit supporting
    details such as research, providers, licensing, design work, implementation steps, and verification;
    those belong in sprint scope, not its goal.

    When the titles cover distinct outcomes, describe the combined product focus honestly without
    implying a relationship that the titles do not support. Do not mention ticket keys, sprint numbers,
    agents, implementation mechanics, or generic activity such as "complete the planned tickets." Use
    plain text with no heading, quotation marks, Markdown, or punctuation at the end. Return only the
    JSON requested by the schema.
    """

  public static var developerInstructions: String {
    platformInstructions
  }

  public static func lightestReasoningEffort(
    supportedEfforts: [String],
    fallback: String
  ) -> String {
    let preferredOrder = [
      "none",
      "minimal",
      "low",
      "medium",
      "high",
      "xhigh",
      "max",
      "ultra",
    ]
    for effort in preferredOrder where supportedEfforts.contains(effort) {
      return effort
    }
    return supportedEfforts.first ?? fallback
  }

  public static func prompt(
    productName: String,
    sprintNumber: Int,
    ticketTitles: [String]
  ) -> String {
    let scope = ticketTitles.map { "- \($0)" }.joined(separator: "\n")
    return """
      Product: \(productName)
      Sprint: \(sprintNumber)

      Owner-approved sprint ticket titles:
      \(scope)

      Propose one editable sprint goal of five to ten words and at most 80 characters. Base it only on
      the ticket titles above, express the unifying user-visible outcome, and leave off final punctuation.
      Return only that short goal in the goal field.
      """
  }

  public static var outputSchema: JSONValue {
    .object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([.string("goal")]),
      "properties": .object([
        "goal": .object(["type": .string("string")])
      ]),
    ])
  }

  public static func decode(_ text: String) throws -> String {
    guard let data = text.data(using: .utf8) else {
      throw SprintGoalGenerationError.invalidResponse("The response was not UTF-8.")
    }
    let generated: GeneratedSprintGoal
    do {
      generated = try JSONDecoder().decode(GeneratedSprintGoal.self, from: data)
    } catch {
      throw SprintGoalGenerationError.invalidResponse(error.localizedDescription)
    }
    var goal = generated.goal
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    while goal.last == "." {
      goal.removeLast()
    }
    guard !goal.isEmpty else {
      throw SprintGoalGenerationError.invalidResponse("A goal is required.")
    }
    guard goal.count <= 80 else {
      throw SprintGoalGenerationError.invalidResponse(
        "The goal must be no longer than 80 characters."
      )
    }
    return goal
  }
}

private struct GeneratedSprintGoal: Decodable {
  let goal: String
}
