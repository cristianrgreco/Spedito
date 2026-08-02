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
  /// A deliberately broad first-pass range. Historic run data can replace this
  /// heuristic once the product has enough evidence to calibrate forecasts.
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
}
