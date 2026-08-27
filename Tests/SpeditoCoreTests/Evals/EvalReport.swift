import Foundation

struct EvalRunMetadata: Codable {
  let startedAt: Date
  var finishedAt: Date?
  let models: [String]
  let efforts: [String]
  let repetitions: Int
  let judgeModel: String
  let judgeEffort: String
  let skipsJudge: Bool
  let codexExecutablePath: String
  let codexVersion: String
  let supportedReasoningEfforts: [String: [String]]
  var rateLimitUsedPercentBefore: Double?
  var rateLimitUsedPercentAfter: Double?
}

struct EvalCheck: Codable, Sendable {
  let name: String
  let passed: Bool
  let detail: String
}

struct EvalDeterministicOutcome: Sendable {
  let decodePassed: Bool
  let decodeFailure: String?
  let checks: [EvalCheck]
  let facts: [String: String]
}

struct EvalJudgeScore: Codable, Sendable {
  let dimension: String
  let score: Int
  let rationale: String
}

struct EvalJudgeRecord: Codable, Sendable {
  let model: String
  let effort: String
  let scores: [EvalJudgeScore]
  let overallComment: String
  let failure: String?
  let latencySeconds: Double
}

struct EvalCellRecord: Codable, Sendable {
  let scenarioID: String
  let generator: String
  let model: String
  let effort: String
  let repetition: Int
  let startedAt: Date
  let latencySeconds: Double
  let turnFailure: String?
  let responseCharacterCount: Int?
  let decodePassed: Bool
  let decodeFailure: String?
  let checks: [EvalCheck]
  let facts: [String: String]
  let judge: EvalJudgeRecord?
  let rawResponse: String?
}

enum EvalReport {
  static func markdown(metadata: EvalRunMetadata, records: [EvalCellRecord]) -> String {
    var lines: [String] = []
    lines.append("# Prompt eval run")
    lines.append("")
    lines.append(
      "- Models: \(metadata.models.map { "`\($0)`" }.joined(separator: ", ")) "
        + "at efforts \(metadata.efforts.joined(separator: ", "))"
    )
    lines.append("- Judge: `\(metadata.judgeModel)` at \(metadata.judgeEffort)\(metadata.skipsJudge ? " (skipped)" : "")")
    lines.append("- Codex: \(metadata.codexVersion) (\(metadata.codexExecutablePath))")
    lines.append("- Repetitions per cell: \(metadata.repetitions)")
    if let before = metadata.rateLimitUsedPercentBefore,
      let after = metadata.rateLimitUsedPercentAfter
    {
      lines.append(
        "- Primary rate-limit window: \(format(before))% used before, \(format(after))% after"
      )
    }
    if metadata.repetitions == 1 {
      lines.append("")
      lines.append(
        "> Single sample per cell: treat differences as directional, not significant."
      )
    }

    let generators = orderedUnique(records.map(\.generator))
    for generator in generators {
      let generatorRecords = records.filter { $0.generator == generator }
      lines.append("")
      lines.append("## \(generator)")
      lines.append("")
      lines.append(
        "| Scenario | Model | Effort | Turn | Decode | Checks | Latency | Judge mean | Lowest dimension |"
      )
      lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
      for record in generatorRecords {
        let turn = record.turnFailure == nil ? "ok" : "FAILED"
        let decode = record.turnFailure != nil ? "—" : (record.decodePassed ? "pass" : "FAIL")
        let checksPassed = record.checks.filter(\.passed).count
        let checks = record.checks.isEmpty ? "—" : "\(checksPassed)/\(record.checks.count)"
        let latency = "\(format(record.latencySeconds))s"
        var judgeMean = "—"
        var lowest = "—"
        if let judge = record.judge, judge.failure == nil, !judge.scores.isEmpty {
          let mean =
            Double(judge.scores.map(\.score).reduce(0, +)) / Double(judge.scores.count)
          judgeMean = format(mean)
          if let low = judge.scores.min(by: { $0.score < $1.score }) {
            lowest = "\(low.dimension) (\(low.score))"
          }
        } else if record.judge?.failure != nil {
          judgeMean = "judge failed"
        }
        lines.append(
          "| \(record.scenarioID) | \(record.model) | \(record.effort) | \(turn) | \(decode) "
            + "| \(checks) | \(latency) | \(judgeMean) | \(lowest) |"
        )
      }

      let columns = orderedUnique(
        records.map { "\($0.model) \($0.effort)" }
      )
      let dimensionRows = dimensionAverages(for: generatorRecords, columns: columns)
      if !dimensionRows.isEmpty {
        lines.append("")
        lines.append("Judge dimensions (mean per model and effort):")
        lines.append("")
        lines.append("| Dimension | " + columns.joined(separator: " | ") + " |")
        lines.append("| --- | " + columns.map { _ in "---" }.joined(separator: " | ") + " |")
        for row in dimensionRows {
          let cells = columns.map { column in
            row.meanByColumn[column].map(format) ?? "—"
          }
          lines.append("| \(row.dimension) | " + cells.joined(separator: " | ") + " |")
        }
      }
    }

    lines.append("")
    lines.append("## Failures and failed checks")
    lines.append("")
    var hasFailureLines = false
    for record in records {
      var details: [String] = []
      if let turnFailure = record.turnFailure {
        details.append("turn failed: \(turnFailure)")
      }
      if record.turnFailure == nil, !record.decodePassed {
        details.append("decode failed: \(record.decodeFailure ?? "unknown")")
      }
      for check in record.checks where !check.passed {
        details.append("check \(check.name): \(check.detail)")
      }
      if let judgeFailure = record.judge?.failure {
        details.append("judge failed: \(judgeFailure)")
      }
      for detail in details {
        lines.append("- \(record.scenarioID) [\(record.model) \(record.effort)]: \(detail)")
        hasFailureLines = true
      }
    }
    if !hasFailureLines {
      lines.append("None.")
    }
    lines.append("")
    return lines.joined(separator: "\n")
  }

  private struct DimensionRow {
    let dimension: String
    let meanByColumn: [String: Double]
  }

  private static func dimensionAverages(
    for records: [EvalCellRecord],
    columns: [String]
  ) -> [DimensionRow] {
    var scoresByDimension: [String: [String: [Int]]] = [:]
    var dimensionOrder: [String] = []
    for record in records {
      guard let judge = record.judge, judge.failure == nil else { continue }
      let column = "\(record.model) \(record.effort)"
      for score in judge.scores {
        if scoresByDimension[score.dimension] == nil {
          dimensionOrder.append(score.dimension)
        }
        scoresByDimension[score.dimension, default: [:]][column, default: []]
          .append(score.score)
      }
    }
    return dimensionOrder.map { dimension in
      let byColumn = scoresByDimension[dimension] ?? [:]
      var means: [String: Double] = [:]
      for column in columns {
        if let scores = byColumn[column], !scores.isEmpty {
          means[column] = Double(scores.reduce(0, +)) / Double(scores.count)
        }
      }
      return DimensionRow(dimension: dimension, meanByColumn: means)
    }
  }

  private static func orderedUnique(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { seen.insert($0).inserted }
  }

  private static func format(_ value: Double) -> String {
    String(format: "%.1f", value)
  }
}
