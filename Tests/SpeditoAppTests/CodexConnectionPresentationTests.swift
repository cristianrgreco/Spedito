import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

@Suite("Codex connection presentation")
struct CodexConnectionPresentationTests {
  @Test("Retry is offered only when a connection can be attempted again")
  func retryVisibility() {
    #expect(CodexConnectionState.notChecked.showsRetryAction)
    #expect(CodexConnectionState.unavailable("Missing").showsRetryAction)
    #expect(CodexConnectionState.incompatible("Unsupported").showsRetryAction)
    #expect(!CodexConnectionState.checking.showsRetryAction)
    #expect(
      !CodexConnectionState.connected(
        version: "1.2.3",
        userAgent: "codex-cli/1.2.3"
      ).showsRetryAction
    )
  }

  @Test("Usage accessibility follows the windows returned by Codex")
  func dynamicUsageAccessibility() {
    let snapshot = CodexRateLimitsSnapshot(
      windows: [
        CodexRateLimitWindow(
          id: "primary",
          usedPercent: 28,
          windowDurationMinutes: 10_080,
          resetsAt: nil
        ),
        CodexRateLimitWindow(
          id: "secondary",
          usedPercent: 12,
          windowDurationMinutes: 300,
          resetsAt: nil
        ),
      ],
      reachedLimitType: nil
    )

    #expect(
      CodexUsagePresentation.accessibilitySummary(for: snapshot)
        == "5-hour window, 88 percent available; 7-day window, 72 percent available"
    )
    #expect(CodexUsagePresentation.windowTitle(minutes: 10_080) == "7-day window")
    #expect(CodexUsagePresentation.windowTitle(minutes: 15) == "15-minute window")
  }

  @Test("Reset detail distinguishes refreshes from stale usage")
  func resetDetails() {
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let future = now.addingTimeInterval((2 * 60 * 60) + (12 * 60))

    #expect(
      CodexUsagePresentation.resetDetail(
        resetAt: future,
        now: now,
        isRefreshing: false
      ).contains("in 2h 12m")
    )
    #expect(
      CodexUsagePresentation.resetDetail(
        resetAt: now,
        now: now,
        isRefreshing: true
      ) == "Reset reached · refreshing usage…"
    )
    #expect(
      CodexUsagePresentation.resetDetail(
        resetAt: now,
        now: now,
        isRefreshing: false
      ) == "Reset reached · usage may be out of date"
    )
  }

  @Test("[S07] Usage windows keep separate limits and expose refresh transitions")
  func s07UsageWindowsAndRefreshTransitions() throws {
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let snapshot = CodexRateLimitsSnapshot(
      windows: [
        CodexRateLimitWindow(
          id: "five-hour",
          usedPercent: 100,
          windowDurationMinutes: 300,
          resetsAt: now.addingTimeInterval(600)
        ),
        CodexRateLimitWindow(
          id: "weekly",
          usedPercent: 40,
          windowDurationMinutes: 10_080,
          resetsAt: now.addingTimeInterval(3_600)
        ),
      ],
      reachedLimitType: "five-hour"
    )

    #expect(
      CodexUsagePresentation.accessibilitySummary(
        for: snapshot,
        isRefreshing: true
      )
        == "5-hour window, 0 percent available; 7-day window, 60 percent available; limit reached; refreshing"
    )
    #expect(
      CodexUsagePresentation.accessibilitySummary(
        for: snapshot,
        isStale: true
      )?.hasSuffix("usage may be out of date") == true
    )
    #expect(
      CodexUsagePresentation.resetDetail(
        resetAt: try #require(snapshot.windows.first?.resetsAt),
        now: now,
        isRefreshing: false
      ).contains("in 10m")
    )
    #expect(Set(snapshot.windows.map(\.id)) == ["five-hour", "weekly"])
  }
}
