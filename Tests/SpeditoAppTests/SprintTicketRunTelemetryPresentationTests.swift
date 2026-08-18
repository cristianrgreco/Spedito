import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

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
    #expect(presentation.compactionCount == nil)
  }

  @Test("A run without telemetry does not create an empty footer")
  func runWithoutTelemetryHasNoFooter() {
    let presentation = SprintTicketRunTelemetryPresentation(
      run: run(status: .completed),
      hasLiveActivity: false
    )

    #expect(!presentation.showsFooter)
    #expect(presentation.contextPercentage == nil)
    #expect(presentation.compactionCount == nil)
  }

  @Test("The context donut displays only positive compaction counts")
  func contextDonutCompactionCount() {
    let withoutCompactions = SprintTicketRunTelemetryPresentation(
      run: run(
        status: .running,
        contextUsedTokens: 120_000,
        contextWindowTokens: 258_400
      ),
      hasLiveActivity: false
    )
    let withCompactions = SprintTicketRunTelemetryPresentation(
      run: run(
        status: .running,
        contextUsedTokens: 120_000,
        contextWindowTokens: 258_400,
        compactionCount: 3
      ),
      hasLiveActivity: false
    )

    #expect(withoutCompactions.compactionCount == nil)
    #expect(withCompactions.compactionCount == 3)
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

  @Test("[D22] Capacity wait explains recovery without reporting failure")
  func d22CapacityWaitExplainsRecoveryWithoutFailure() throws {
    let retryAt = Date(timeIntervalSince1970: 1_800_001_800)
    let presentation = try #require(
      SprintTicketExecutionConstraintPresentation(
        run: run(
          status: .queued,
          executionConstraint: AgentRunExecutionConstraint(
            kind: .accountRateLimit,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            retryAt: retryAt,
            technicalEvidence: "primary"
          )
        )
      )
    )

    #expect(presentation.title == "Waiting for Codex capacity")
    #expect(presentation.explanation.contains("continue automatically"))
    #expect(presentation.retryAt == retryAt)
    #expect(presentation.technicalEvidence == "primary")
  }

  @Test("[D23] Board lanes, activity, and run health share one presentation snapshot")
  func d23BoardSnapshotPresentation() {
    #expect(
      SprintLane.board.map(\.title)
        == ["Ready to pick", "In progress", "In review", "Ready for demo", "Done"]
    )
    #expect(
      SprintLane.board.map(\.states) == [
        [.queued],
        [.running],
        [.integrating, .verifying, .readyToRelease],
        [.acceptance],
        [.released],
      ]
    )

    let workingRun = run(
      status: .running,
      contextUsedTokens: 129_200,
      contextWindowTokens: 258_400,
      compactionCount: 2
    )
    #expect(activityTitle(run: workingRun, itemState: .running) == "Working")
    #expect(
      activityTitle(
        run: run(
          status: .queued,
          executionConstraint: AgentRunExecutionConstraint(
            kind: .accountRateLimit,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            retryAt: nil,
            technicalEvidence: nil
          )
        ),
        itemState: .queued
      ) == "Waiting for Codex capacity"
    )
    #expect(
      activityTitle(
        run: nil,
        itemState: .queued,
        isDependencyBlocked: true
      ) == "Blocked"
    )
    #expect(
      activityTitle(
        run: workingRun,
        itemState: .verifying,
        candidateStatus: .reviewing
      ) == "Reviewing"
    )
    #expect(
      activityTitle(
        run: run(status: .awaitingOwner),
        itemState: .running
      ) == "Needs your input"
    )

    let telemetry = SprintTicketRunTelemetryPresentation(
      run: workingRun,
      hasLiveActivity: true
    )
    #expect(telemetry.contextPercentage == 50)
    #expect(telemetry.compactionCount == 2)
    #expect(telemetry.showsLiveActivity)
  }

  private func activityTitle(
    run: AgentRun?,
    itemState: WorkItemState,
    candidateStatus: CandidateRevisionStatus? = nil,
    isDependencyBlocked: Bool = false
  ) -> String {
    SprintTicketActivityPresentation.resolve(
      run: run,
      itemState: itemState,
      candidateStatus: candidateStatus,
      isDependencyBlocked: isDependencyBlocked,
      isAcceptanceInProgress: false,
      planningIssue: nil
    ).title
  }

  private func run(
    status: AgentRunStatus,
    contextUsedTokens: Int? = nil,
    contextWindowTokens: Int? = nil,
    compactionCount: Int = 0,
    executionConstraint: AgentRunExecutionConstraint? = nil,
    updatedAt: Date = Date()
  ) -> AgentRun {
    AgentRun(
      productID: UUID(),
      workItemID: UUID(),
      profileID: UUID(),
      status: status,
      contextUsedTokens: contextUsedTokens,
      contextWindowTokens: contextWindowTokens,
      compactionCount: compactionCount,
      executionConstraint: executionConstraint,
      createdAt: updatedAt,
      updatedAt: updatedAt
    )
  }
}
