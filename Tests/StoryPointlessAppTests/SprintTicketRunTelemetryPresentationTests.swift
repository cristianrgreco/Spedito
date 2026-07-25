import Foundation
import StoryPointlessCore
import Testing
@testable import StoryPointlessApp

@Suite("Sprint ticket run telemetry presentation")
struct SprintTicketRunTelemetryPresentationTests {
  @Test("Completed runs retain their persisted context footer")
  func completedRunRetainsContextFooter() {
    let presentation = SprintTicketRunTelemetryPresentation(
      run: run(
        status: .completed,
        contextUsedTokens: 47_132,
        contextWindowTokens: 258_400
      ),
      hasLiveActivity: false
    )

    #expect(presentation.showsFooter)
    #expect(!presentation.showsLiveActivity)
    #expect(presentation.contextPercentage == 18)
  }

  @Test("A run without telemetry does not create an empty footer")
  func runWithoutTelemetryHasNoFooter() {
    let presentation = SprintTicketRunTelemetryPresentation(
      run: run(status: .completed),
      hasLiveActivity: false
    )

    #expect(!presentation.showsFooter)
    #expect(presentation.contextPercentage == nil)
  }

  @Test("Live activity is presented only while its run is running")
  func liveActivityRequiresRunningRun() {
    let running = SprintTicketRunTelemetryPresentation(
      run: run(status: .running),
      hasLiveActivity: true
    )
    let completed = SprintTicketRunTelemetryPresentation(
      run: run(status: .completed),
      hasLiveActivity: true
    )

    #expect(running.showsFooter)
    #expect(running.showsLiveActivity)
    #expect(!completed.showsFooter)
    #expect(!completed.showsLiveActivity)
  }

  @Test("Completed delivery selects the newest run with persisted context")
  func completedDeliverySelectsPersistedContextRun() throws {
    let contextRun = run(
      status: .completed,
      contextUsedTokens: 42_000,
      contextWindowTokens: 258_400,
      updatedAt: Date(timeIntervalSince1970: 100)
    )
    let newerRunWithoutContext = run(
      status: .completed,
      updatedAt: Date(timeIntervalSince1970: 200)
    )

    let selected = try #require(
      SprintTicketRunDetailsSelection.run(
        for: .released,
        latestRun: newerRunWithoutContext,
        allRuns: [contextRun, newerRunWithoutContext]
      )
    )

    #expect(selected.id == contextRun.id)
  }

  @Test("Active delivery keeps its latest run")
  func activeDeliveryKeepsLatestRun() throws {
    let historicalRun = run(
      status: .completed,
      contextUsedTokens: 42_000,
      contextWindowTokens: 258_400,
      updatedAt: Date(timeIntervalSince1970: 100)
    )
    let runningRun = run(
      status: .running,
      updatedAt: Date(timeIntervalSince1970: 200)
    )

    let selected = try #require(
      SprintTicketRunDetailsSelection.run(
        for: .running,
        latestRun: runningRun,
        allRuns: [historicalRun, runningRun]
      )
    )

    #expect(selected.id == runningRun.id)
  }

  private func run(
    status: AgentRunStatus,
    contextUsedTokens: Int? = nil,
    contextWindowTokens: Int? = nil,
    updatedAt: Date = Date()
  ) -> AgentRun {
    AgentRun(
      productID: UUID(),
      workItemID: UUID(),
      profileID: UUID(),
      status: status,
      contextUsedTokens: contextUsedTokens,
      contextWindowTokens: contextWindowTokens,
      createdAt: updatedAt,
      updatedAt: updatedAt
    )
  }
}
