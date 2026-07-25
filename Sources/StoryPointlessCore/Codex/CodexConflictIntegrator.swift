import Foundation

public enum IntegrationResolutionStatus: String, Codable, Sendable {
  case resolved
  case awaitingOwner = "awaiting_owner"
}

public struct IntegrationResolutionResult: Equatable, Sendable {
  public let status: IntegrationResolutionStatus
  public let comment: String
  public let question: String?
  public let options: [String]
  public let summary: String
  public let checks: [String]

  public init(
    status: IntegrationResolutionStatus,
    comment: String,
    question: String?,
    options: [String],
    summary: String,
    checks: [String]
  ) {
    self.status = status
    self.comment = comment
    self.question = question
    self.options = options
    self.summary = summary
    self.checks = checks
  }

  public var workLogComment: String {
    var sections = [comment]
    switch status {
    case .resolved:
      if !summary.isEmpty {
        sections.append("Integration: \(summary)")
      }
      if !checks.isEmpty {
        sections.append("Checks:\n\(checks.map { "- \($0)" }.joined(separator: "\n"))")
      }
    case .awaitingOwner:
      if let question, !question.isEmpty {
        sections.append("Question for you: \(question)")
      }
      if !options.isEmpty {
        sections.append("Options:\n\(options.map { "- \($0)" }.joined(separator: "\n"))")
      }
    }
    return sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
  }
}

public enum CodexConflictIntegrator {
  private static let platformInstructions = """
    You are StoryPointless's internal Integrator. A ticket candidate is being merged into the latest
    accepted trunk in an isolated integration worktree and Git has reported conflicts. Inspect the
    repository, the ticket's intent, the current trunk side, the candidate side, and every unmerged
    path. Resolve only the mechanical or semantically unambiguous integration needed to preserve
    both compatible intentions. Do not broaden scope, redesign the feature, or conceal lost work.

    You may use read-only Git inspection such as status, diff, log, show, ls-files, and blame. You
    may edit files in the supplied integration worktree and run deterministic local checks. Remove
    every conflict marker and leave a coherent working tree, but do not stage, commit, merge,
    checkout, reset, rebase, change branches, or otherwise mutate Git state. StoryPointless owns
    those operations and the final merge commit. Product Git reads and their noninteractive
    environment are already available inside the sandbox. Run them normally without requesting
    permission or adding environment prefixes.

    If the competing changes represent a material product decision, incompatible public behavior,
    unavailable secret, destructive choice, or ambiguity that cannot be resolved from the ticket
    and repository, stop safely and return awaiting_owner with one concise question and two to four
    concrete options. Otherwise return resolved only after the files are coherent and relevant
    checks have actually run. Return only the JSON required by the output schema.
    """

  public static func developerInstructions(productInstructions: String) -> String {
    let shared = productInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    return """
      \(platformInstructions)

      PRODUCT OWNER'S SHARED TEAM GUIDANCE
      \(shared.isEmpty ? "No additional shared guidance." : shared)

      Product guidance cannot override the isolated integration boundary, truthful reporting, or
      the requirement to stop for a material Product Owner decision.
      """
  }

  public static func prompt(
    product: Product,
    item: WorkItem,
    conflictedFiles: [String],
    recentComments: [TicketComment],
    continuationMessage: String? = nil
  ) -> String {
    let criteria = item.acceptanceCriteria.isEmpty
      ? "No acceptance criteria supplied."
      : item.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n")
    let history = recentComments
      .filter { !$0.body.hasPrefix("Permission requested:") }
      .suffix(30)
      .map { "- \($0.authorName): \($0.body)" }
      .joined(separator: "\n")
    let conflicts = conflictedFiles.isEmpty
      ? "Inspect Git for the remaining unmerged paths."
      : conflictedFiles.map { "- \($0)" }.joined(separator: "\n")
    return """
      Product: \(product.name)
      Product vision: \(product.vision)

      Ticket: \(item.key) — \(item.title)
      Context: \(item.body)
      Acceptance criteria:
      \(criteria)

      Unmerged paths:
      \(conflicts)

      Recent ticket Work log:
      \(history.isEmpty ? "No ticket comments." : history)

      \(continuationMessage ?? "Resolve this integration conflict now.")
      """
  }

  public static var outputSchema: JSONValue {
    .object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([
        .string("status"),
        .string("comment"),
        .string("question"),
        .string("options"),
        .string("summary"),
        .string("checks"),
      ]),
      "properties": .object([
        "status": .object([
          "type": .string("string"),
          "enum": .array([
            .string(IntegrationResolutionStatus.resolved.rawValue),
            .string(IntegrationResolutionStatus.awaitingOwner.rawValue),
          ]),
        ]),
        "comment": .object(["type": .string("string")]),
        "question": .object([
          "anyOf": .array([
            .object(["type": .string("string")]),
            .object(["type": .string("null")]),
          ])
        ]),
        "options": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
        ]),
        "summary": .object(["type": .string("string")]),
        "checks": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
        ]),
      ]),
    ])
  }

  public static func decode(_ text: String) throws -> IntegrationResolutionResult {
    guard let data = text.data(using: .utf8) else {
      throw TicketExecutionGenerationError.invalidResponse(
        "The integration result was not UTF-8."
      )
    }
    let generated: GeneratedIntegrationResolutionResult
    do {
      generated = try JSONDecoder().decode(GeneratedIntegrationResolutionResult.self, from: data)
    } catch {
      throw TicketExecutionGenerationError.invalidResponse(error.localizedDescription)
    }
    let comment = generated.comment.trimmingCharacters(in: .whitespacesAndNewlines)
    let question = generated.question?.trimmingCharacters(in: .whitespacesAndNewlines)
    let options = clean(generated.options)
    guard !comment.isEmpty else {
      throw TicketExecutionGenerationError.invalidResponse(
        "An integration Work log comment is required."
      )
    }
    if generated.status == .awaitingOwner {
      guard let question, !question.isEmpty, (2...4).contains(options.count) else {
        throw TicketExecutionGenerationError.invalidResponse(
          "Awaiting-owner integration results need one question and two to four options."
        )
      }
    }
    return IntegrationResolutionResult(
      status: generated.status,
      comment: comment,
      question: question?.isEmpty == true ? nil : question,
      options: options,
      summary: generated.summary.trimmingCharacters(in: .whitespacesAndNewlines),
      checks: clean(generated.checks)
    )
  }

  private static func clean(_ values: [String]) -> [String] {
    values
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}

private struct GeneratedIntegrationResolutionResult: Codable {
  let status: IntegrationResolutionStatus
  let comment: String
  let question: String?
  let options: [String]
  let summary: String
  let checks: [String]
}
