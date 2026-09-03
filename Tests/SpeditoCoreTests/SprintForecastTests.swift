import Foundation
import Testing

@testable import SpeditoCore

@Suite("Sprint forecast")
struct SprintForecastTests {
  @Test("Cold-start duration treats token throughput as seconds")
  func tokenThroughputUsesSeconds() {
    let item = WorkItem(
      productID: UUID(),
      key: "T1",
      title: "",
      type: .story
    )

    let forecast = SprintForecast.estimate(for: item)

    #expect(forecast.tokenLow == 12_000)
    #expect(forecast.tokenHigh == 22_000)
    #expect(forecast.durationLowSeconds == 48)
    #expect(forecast.durationHighSeconds == 132)
  }

  @Test("Released ticket usage calibrates later forecasts without treating context as spend")
  func completedUsageCalibratesForecasts() {
    let productID = UUID()
    let released = WorkItem(
      productID: productID,
      key: "T1",
      title: "",
      type: .story,
      state: .released
    )
    let next = WorkItem(
      productID: productID,
      key: "T2",
      title: "",
      type: .story
    )
    let observed = AgentRun(
      productID: productID,
      workItemID: released.id,
      profileID: UUID(),
      status: .completed,
      contextUsedTokens: 25_000,
      contextWindowTokens: 258_400,
      compactionCount: 1,
      cumulativeUsedTokens: 170_000,
      activeDurationSeconds: 900
    )

    let calibrated = SprintForecast.estimate(
      for: next,
      historicalRuns: [observed],
      workItems: [released, next]
    )
    #expect(calibrated.tokenLow == 120_000)
    #expect(calibrated.tokenHigh == 220_000)
    #expect(calibrated.durationLowSeconds == 480)
    #expect(calibrated.durationHighSeconds == 1_320)

    let contextOnly = AgentRun(
      productID: productID,
      workItemID: released.id,
      profileID: UUID(),
      status: .completed,
      contextUsedTokens: 170_000,
      contextWindowTokens: 258_400
    )
    #expect(
      SprintForecast.estimate(
        for: next,
        historicalRuns: [contextOnly],
        workItems: [released, next]
      ) == SprintForecast.estimate(for: next)
    )
  }
}
