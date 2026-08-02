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
}
