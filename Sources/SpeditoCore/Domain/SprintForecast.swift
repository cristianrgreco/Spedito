import Foundation

public struct TicketForecast: Equatable, Sendable {
  public let tokenLow: Int
  public let tokenHigh: Int
  public let durationLowSeconds: Int
  public let durationHighSeconds: Int

  public var tokenMidpoint: Int {
    (tokenLow + tokenHigh) / 2
  }

  public init(
    tokenLow: Int,
    tokenHigh: Int,
    durationLowSeconds: Int,
    durationHighSeconds: Int
  ) {
    self.tokenLow = tokenLow
    self.tokenHigh = tokenHigh
    self.durationLowSeconds = durationLowSeconds
    self.durationHighSeconds = durationHighSeconds
  }
}

public enum SprintForecast {
  /// A deliberately broad first-pass range used until completed delivery runs
  /// provide product-local evidence for this ticket type.
  public static func estimate(for item: WorkItem) -> TicketForecast {
    let base: Int
    switch item.type {
    case .story: base = 12_000
    case .task: base = 9_000
    case .bug: base = 11_000
    }
    let words = ([item.title, item.body] + item.acceptanceCriteria)
      .joined(separator: " ")
      .split(whereSeparator: \.isWhitespace)
      .count
    let detail = min(6_000, words * 35 + item.acceptanceCriteria.count * 650)
    let low = ((base + detail + 499) / 500) * 500
    let high = ((Int(Double(low) * 1.8) + 999) / 1_000) * 1_000
    let lowSeconds = max(15, (low / 500) * 2)
    let highSeconds = max(lowSeconds + 15, (high / 500) * 3)
    return TicketForecast(
      tokenLow: low,
      tokenHigh: high,
      durationLowSeconds: lowSeconds,
      durationHighSeconds: highSeconds
    )
  }

  public static func estimate(
    for item: WorkItem,
    historicalRuns: [AgentRun],
    workItems: [WorkItem]
  ) -> TicketForecast {
    let baseline = estimate(for: item)
    let historicalItems = Dictionary(
      uniqueKeysWithValues: workItems
        .filter { $0.type == item.type && $0.id != item.id && $0.state == .released }
        .map { ($0.id, $0) }
    )
    guard !historicalItems.isEmpty else { return baseline }

    let completedRuns = historicalRuns.filter {
      $0.status == .completed && historicalItems[$0.workItemID] != nil
    }
    let runsByItem = Dictionary(grouping: completedRuns, by: \.workItemID)
    let tokenRatios = historicalItems.values.compactMap { historicalItem -> Double? in
      let observed = runsByItem[historicalItem.id, default: []]
        .compactMap(\.cumulativeUsedTokens)
        .reduce(0, +)
      guard observed > 0 else { return nil }
      let historicalBaseline = estimate(for: historicalItem).tokenMidpoint
      return Double(observed) / Double(max(1, historicalBaseline))
    }
    let durationRatios = historicalItems.values.compactMap { historicalItem -> Double? in
      let runs = runsByItem[historicalItem.id, default: []]
      guard !runs.isEmpty else { return nil }
      let observed = runs.reduce(0) {
        $0 + $1.activeDuration(at: $1.updatedAt)
      }
      guard observed > 0 else { return nil }
      let forecast = estimate(for: historicalItem)
      let midpoint = Double(forecast.durationLowSeconds + forecast.durationHighSeconds) / 2
      return observed / max(1, midpoint)
    }
    guard let tokenRatio = median(tokenRatios) else { return baseline }
    let boundedTokenRatio = min(20, max(0.5, tokenRatio))
    let boundedDurationRatio = min(20, max(0.5, median(durationRatios) ?? 1))

    return TicketForecast(
      tokenLow: rounded(baseline.tokenLow, by: boundedTokenRatio, step: 500),
      tokenHigh: rounded(baseline.tokenHigh, by: boundedTokenRatio, step: 1_000),
      durationLowSeconds: rounded(
        baseline.durationLowSeconds,
        by: boundedDurationRatio,
        step: 15
      ),
      durationHighSeconds: rounded(
        baseline.durationHighSeconds,
        by: boundedDurationRatio,
        step: 15
      )
    )
  }

  private static func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
  }

  private static func rounded(_ value: Int, by ratio: Double, step: Int) -> Int {
    max(step, Int(ceil(Double(value) * ratio / Double(step))) * step)
  }
}
