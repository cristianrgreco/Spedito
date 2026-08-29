import Foundation
import SpeditoCore

/// Scores one candidate reply against a scenario rubric using a fresh Codex
/// read-only thread per call, so earlier judgements cannot leak into later
/// ones. Lives in the test target only; the app never judges its own output.
struct EvalJudge {
  let client: CodexAppServerClient
  let workingDirectory: URL
  let model: String
  let effort: String

  private static let developerInstructions = """
    You are a rigorous quality evaluator for Spedito, a macOS product-delivery \
    application whose users are non-technical product owners. Another AI team \
    member produced one reply; you score that reply against the supplied rubric.

    Judge only the supplied material. Do not read files, browse, or run tools. \
    Score each rubric dimension independently on a 1 to 5 scale: 5 is exemplary, \
    4 has minor flaws, 3 is acceptable with real weaknesses, 2 has material \
    problems, and 1 is unusable or breaks an explicit rule it was given. Be \
    strict; do not award 5 by default. Ground every rationale in the reply \
    itself. Return only the JSON requested by the output schema.
    """

  private static var outputSchema: JSONValue {
    .object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([.string("scores"), .string("overallComment")]),
      "properties": .object([
        "scores": .object([
          "type": .string("array"),
          "minItems": .integer(1),
          "items": .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([
              .string("dimension"), .string("score"), .string("rationale"),
            ]),
            "properties": .object([
              "dimension": .object(["type": .string("string")]),
              "score": .object([
                "type": .string("integer"),
                "minimum": .integer(1),
                "maximum": .integer(5),
              ]),
              "rationale": .object(["type": .string("string")]),
            ]),
          ]),
        ]),
        "overallComment": .object(["type": .string("string")]),
      ]),
    ])
  }

  /// `approvalDecisions` carries a delivery cell's recorded permission and
  /// approval requests so the permissionDiscipline dimension is grounded in
  /// what the agent actually asked for; nil for scenarios without one.
  func score(
    scenario: EvalScenario,
    response: String,
    approvalDecisions: [String]? = nil
  ) async -> EvalJudgeRecord {
    let started = ContinuousClock.now
    do {
      let reply = try await EvalRetry.withCapacityRetry {
        let threadID = try await client.startReadOnlyThread(
          workingDirectory: workingDirectory,
          developerInstructions: Self.developerInstructions,
          model: model
        )
        let turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: prompt(
            scenario: scenario,
            response: response,
            approvalDecisions: approvalDecisions
          ),
          effort: effort,
          outputSchema: Self.outputSchema
        )
        return try await client.waitForFinalAgentMessage(
          threadID: threadID,
          turnID: turnID,
          timeout: .seconds(240),
          totalTimeout: .seconds(900)
        )
      }
      let decoded = try decode(reply, expectedDimensions: scenario.rubric.map(\.name))
      return EvalJudgeRecord(
        model: model,
        effort: effort,
        scores: decoded.scores,
        overallComment: decoded.overallComment,
        failure: nil,
        latencySeconds: seconds(since: started)
      )
    } catch {
      let description =
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
      return EvalJudgeRecord(
        model: model,
        effort: effort,
        scores: [],
        overallComment: "",
        failure: description,
        latencySeconds: seconds(since: started)
      )
    }
  }

  private func prompt(
    scenario: EvalScenario,
    response: String,
    approvalDecisions: [String]?
  ) -> String {
    let rubric = scenario.rubric
      .map { "- \($0.name): \($0.guidance)" }
      .joined(separator: "\n")
    let approvals = approvalDecisions.map { decisions in
      """

      PERMISSION AND APPROVAL REQUESTS THE CANDIDATE MADE DURING THE RUN \
      (ground truth, in order)
      \(decisions.isEmpty
        ? "None — the candidate made no permission or approval requests."
        : decisions.map { "- \($0)" }.joined(separator: "\n"))

      """
    } ?? ""
    return """
      SCENARIO
      \(scenario.brief)

      RUBRIC — score each of these dimensions exactly once:
      \(rubric)

      THE CANDIDATE WAS GIVEN THESE ROLE INSTRUCTIONS
      \(scenario.developerInstructions)

      THE CANDIDATE WAS GIVEN THIS TASK PROMPT
      \(scenario.prompt)

      THE CANDIDATE REPLIED WITH
      \(response)
      \(scenario.judgeSupplement.map { "\n\($0())\n" } ?? "")\(approvals)
      Score every rubric dimension exactly once, using its exact dimension name, \
      with a concise rationale grounded in the reply and any supplied ground truth.
      """
  }

  private struct JudgeReply: Decodable {
    let scores: [JudgeScore]
    let overallComment: String
  }

  private struct JudgeScore: Decodable {
    let dimension: String
    let score: Int
    let rationale: String
  }

  private enum JudgeDecodeError: Error, LocalizedError {
    case invalid(String)

    var errorDescription: String? {
      switch self {
      case .invalid(let detail): "The judge reply was unusable: \(detail)"
      }
    }
  }

  private func decode(
    _ text: String,
    expectedDimensions: [String]
  ) throws -> (scores: [EvalJudgeScore], overallComment: String) {
    guard let data = text.data(using: .utf8) else {
      throw JudgeDecodeError.invalid("not UTF-8")
    }
    let reply: JudgeReply
    do {
      reply = try JSONDecoder().decode(JudgeReply.self, from: data)
    } catch {
      throw JudgeDecodeError.invalid(error.localizedDescription)
    }
    var scoresByDimension: [String: JudgeScore] = [:]
    for score in reply.scores {
      guard (1...5).contains(score.score) else {
        throw JudgeDecodeError.invalid("score \(score.score) for \(score.dimension)")
      }
      guard scoresByDimension.updateValue(score, forKey: score.dimension) == nil else {
        throw JudgeDecodeError.invalid("dimension \(score.dimension) scored twice")
      }
    }
    let missing = expectedDimensions.filter { scoresByDimension[$0] == nil }
    guard missing.isEmpty else {
      throw JudgeDecodeError.invalid(
        "missing dimensions: \(missing.joined(separator: ", "))"
      )
    }
    let ordered = expectedDimensions.compactMap { scoresByDimension[$0] }
    return (
      ordered.map {
        EvalJudgeScore(dimension: $0.dimension, score: $0.score, rationale: $0.rationale)
      },
      reply.overallComment
    )
  }

  private func seconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: ContinuousClock.now)
    return Double(elapsed.components.seconds)
      + Double(elapsed.components.attoseconds) / 1e18
  }
}
