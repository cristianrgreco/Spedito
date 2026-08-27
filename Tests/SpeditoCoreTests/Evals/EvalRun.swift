import Foundation
import SpeditoCore
import Testing

/// Runs the prompt eval suite against real Codex: every scenario is the exact
/// developer-instruction, prompt, and output-schema triple production sends,
/// scored deterministically by the production decoder and validators (tier 1)
/// and by an LLM judge against a scenario rubric (tier 2).
///
/// This costs real Codex usage, so `swift test` skips it unless
/// `SPEDITO_EVALS=1`. `scripts/evals.sh` sets this. The run reports; it does
/// not fail the build on low scores — only on infrastructure failures such as
/// a missing Codex runtime.
nonisolated let evalsAreEnabled = ProcessInfo.processInfo.environment["SPEDITO_EVALS"] == "1"

@Suite("Evals", .serialized)
struct EvalRunTests {
  @Test(
    "Prompt evals produce a scored run bundle",
    .enabled(if: evalsAreEnabled),
    .timeLimit(.minutes(180))
  )
  func runEvals() async throws {
    let configuration = EvalConfiguration.fromEnvironment()
    let bundle = try EvalRunBundle(runsRootURL: configuration.runsRootURL)
    let workspace = try EvalFixtureWorkspace.make()
    defer { workspace.remove() }

    let descriptor = try EvalCodexRuntime.resolveExecutable(
      overridePath: configuration.codexOverridePath
    )
    let client = EvalCodexRuntime.makeClient(descriptor: descriptor)
    _ = try await client.connect()
    defer { Task { await client.disconnect() } }

    let availableModels = try await client.listModels()
    var effortsByModel: [String: [String]] = [:]
    var supportedEffortsByModel: [String: [String]] = [:]
    for model in configuration.models {
      guard let option = availableModels.first(where: { $0.model == model }) else {
        throw EvalRuntimeError.modelNotAvailable(
          model,
          available: availableModels.map(\.model)
        )
      }
      let supported = option.supportedReasoningEfforts.map(\.id)
      supportedEffortsByModel[model] = supported
      effortsByModel[model] = configuration.efforts.filter { effort in
        let isSupported = supported.contains(effort)
        if !isSupported {
          print("Skipping unsupported effort \(effort) for \(model)")
        }
        return isSupported
      }
      try #require(
        !(effortsByModel[model] ?? []).isEmpty,
        "No requested effort is supported by \(model)"
      )
    }

    var scenarios = try await EvalScenarioCatalog.scenarios(workspace: workspace)
    if !configuration.scenarioFilter.isEmpty {
      scenarios = scenarios.filter { scenario in
        configuration.scenarioFilter.contains { scenario.id.hasPrefix($0) }
      }
    }
    try #require(!scenarios.isEmpty, "The scenario filter matched nothing")

    var metadata = EvalRunMetadata(
      startedAt: Date(),
      finishedAt: nil,
      models: configuration.models,
      efforts: configuration.efforts,
      repetitions: configuration.repetitions,
      judgeModel: configuration.judgeModel,
      judgeEffort: configuration.judgeEffort,
      skipsJudge: configuration.skipsJudge,
      codexExecutablePath: descriptor.executableURL.path,
      codexVersion: descriptor.version,
      supportedReasoningEfforts: supportedEffortsByModel,
      rateLimitUsedPercentBefore: nil,
      rateLimitUsedPercentAfter: nil
    )
    metadata.rateLimitUsedPercentBefore = await primaryWindowUsedPercent(client: client)
    try bundle.write(metadata: metadata)

    let judge = EvalJudge(
      client: client,
      workingDirectory: workspace.sharedRepository.rootURL,
      model: configuration.judgeModel,
      effort: configuration.judgeEffort
    )

    let totalCells = scenarios.count
      * configuration.models.reduce(0) { $0 + (effortsByModel[$1]?.count ?? 0) }
      * configuration.repetitions
    print("Eval run: \(totalCells) cell(s) → \(bundle.bundleURL.path)")

    var records: [EvalCellRecord] = []
    var cellIndex = 0
    for scenario in scenarios {
      for model in configuration.models {
        for effort in effortsByModel[model] ?? [] {
          for repetition in 1...configuration.repetitions {
            cellIndex += 1
            print("[\(cellIndex)/\(totalCells)] \(scenario.id) · \(model) at \(effort) effort…")
            let record = await runCell(
              scenario: scenario,
              model: model,
              effort: effort,
              repetition: repetition,
              configuration: configuration,
              client: client,
              workspace: workspace,
              judge: judge
            )
            records.append(record)
            try bundle.write(records: records)
            summarize(record)
          }
        }
      }
    }

    metadata.rateLimitUsedPercentAfter = await primaryWindowUsedPercent(client: client)
    metadata.finishedAt = Date()
    try bundle.write(metadata: metadata)
    try bundle.write(report: EvalReport.markdown(metadata: metadata, records: records))
    print("Eval bundle: \(bundle.bundleURL.path)")
  }

  private func runCell(
    scenario: EvalScenario,
    model: String,
    effort: String,
    repetition: Int,
    configuration: EvalConfiguration,
    client: CodexAppServerClient,
    workspace: EvalFixtureWorkspace,
    judge: EvalJudge
  ) async -> EvalCellRecord {
    let startedAt = Date()
    let started = ContinuousClock.now
    let response: String
    do {
      response = try await EvalRetry.withCapacityRetry {
        let threadID: String
        switch scenario.threadKind {
        case .readOnly(let workingDirectoryURL):
          threadID = try await client.startReadOnlyThread(
            workingDirectory: workingDirectoryURL ?? workspace.sharedRepository.rootURL,
            developerInstructions: scenario.developerInstructions,
            model: model
          )
        case .repositoryAnalysis(let snapshotURL):
          threadID = try await client.startRepositoryAnalysisThread(
            snapshotURL: snapshotURL,
            developerInstructions: scenario.developerInstructions,
            model: model
          )
        }
        let turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: scenario.prompt,
          effort: effort,
          outputSchema: scenario.outputSchema
        )
        return try await client.waitForFinalAgentMessage(
          threadID: threadID,
          turnID: turnID,
          timeout: .seconds(240),
          totalTimeout: .seconds(900)
        )
      }
    } catch {
      let description =
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
      return EvalCellRecord(
        scenarioID: scenario.id,
        generator: scenario.generator,
        model: model,
        effort: effort,
        repetition: repetition,
        startedAt: startedAt,
        latencySeconds: seconds(since: started),
        turnFailure: description,
        responseCharacterCount: nil,
        decodePassed: false,
        decodeFailure: nil,
        checks: [],
        facts: [:],
        judge: nil,
        rawResponse: nil
      )
    }
    let latency = seconds(since: started)

    let outcome = scenario.evaluate(response)
    var checks = outcome.checks
    if scenario.generator == "sprintGoal" {
      // Production generates the sprint goal at the lightest supported effort
      // under a hard 15-second deadline; latency decides usability there.
      checks.append(
        EvalCheck(
          name: "meetsProductionDeadline",
          passed: latency <= 15,
          detail: String(format: "took %.1fs against the 15s production deadline", latency)
        )
      )
    }

    var judgeRecord: EvalJudgeRecord?
    if !configuration.skipsJudge {
      judgeRecord = await judge.score(scenario: scenario, response: response)
    }

    return EvalCellRecord(
      scenarioID: scenario.id,
      generator: scenario.generator,
      model: model,
      effort: effort,
      repetition: repetition,
      startedAt: startedAt,
      latencySeconds: latency,
      turnFailure: nil,
      responseCharacterCount: response.count,
      decodePassed: outcome.decodePassed,
      decodeFailure: outcome.decodeFailure,
      checks: checks,
      facts: outcome.facts,
      judge: judgeRecord,
      rawResponse: response
    )
  }

  private func summarize(_ record: EvalCellRecord) {
    if let turnFailure = record.turnFailure {
      print("  turn failed: \(turnFailure)")
      return
    }
    let decode = record.decodePassed ? "decode pass" : "decode FAIL"
    let checksPassed = record.checks.filter(\.passed).count
    var parts = [
      decode,
      "checks \(checksPassed)/\(record.checks.count)",
      String(format: "%.0fs", record.latencySeconds),
    ]
    if let judge = record.judge {
      if judge.failure != nil {
        parts.append("judge failed")
      } else if !judge.scores.isEmpty {
        let mean = Double(judge.scores.map(\.score).reduce(0, +)) / Double(judge.scores.count)
        parts.append(String(format: "judge %.1f", mean))
      }
    }
    print("  " + parts.joined(separator: ", "))
  }

  private func primaryWindowUsedPercent(client: CodexAppServerClient) async -> Double? {
    guard let snapshot = try? await client.readRateLimits() else { return nil }
    return snapshot.windows.first?.usedPercent
  }

  private func seconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: ContinuousClock.now)
    return Double(elapsed.components.seconds)
      + Double(elapsed.components.attoseconds) / 1e18
  }
}
