import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

struct SprintReportPresentationTests {
  @Test("The latest range keeps the newest twelve completed sprints")
  func latestRange() {
    let data = (1...15).map { datum(sprintNumber: $0) }

    #expect(
      SprintReportPresentation.visibleData(data, range: .latestTwelve)
        .map(\.sprintNumber) == Array(4...15)
    )
    #expect(
      SprintReportPresentation.visibleData(data, range: .all)
        .map(\.sprintNumber) == Array(1...15)
    )
  }

  @Test("Agent time is normalized by delivered outcomes")
  func normalizedAgentTime() {
    let measured = datum(
      sprintNumber: 1,
      activeAgentTime: 900,
      outcomes: 3
    )
    let noOutcomes = datum(
      sprintNumber: 2,
      activeAgentTime: 900,
      outcomes: 0
    )

    #expect(measured.agentTimePerOutcome == 300)
    #expect(noOutcomes.agentTimePerOutcome == nil)
  }

  @Test("Missing measurements create a visible break in a trend")
  func missingMeasurementGap() {
    let data = [
      datum(sprintNumber: 1, cycleTime: 120),
      datum(sprintNumber: 2, cycleTime: nil),
      datum(sprintNumber: 3, cycleTime: 180),
    ]

    let points = SprintReportPresentation.trendPoints(
      in: data,
      metric: .cycleTime
    )

    #expect(points.map(\.sprintNumber) == [1, 3])
    #expect(points.map(\.segment) == [0, 1])
  }

  @Test("Median supports odd and even report windows")
  func median() {
    #expect(SprintReportPresentation.median([20, 10, 30]) == 20)
    #expect(SprintReportPresentation.median([40, 10, 20, 30]) == 25)
    #expect(SprintReportPresentation.median([]) == nil)
  }

  @Test("Long report axes retain the first and latest visible sprints")
  func axisLabels() {
    let data = (4...15).map { datum(sprintNumber: $0) }
    let labels = SprintReportPresentation.axisSprintNumbers(
      in: data,
      maximumLabelCount: 5
    )

    #expect(labels.first == 4)
    #expect(labels.last == 15)
    #expect(labels.count <= 5)
  }

  @Test("Sprint axes pad the first and latest sprint by half an interval")
  func sprintAxisDomain() {
    let data = (1...8).map { datum(sprintNumber: $0) }

    #expect(
      SprintReportPresentation.sprintAxisDomain(in: data) == 0.5...8.5
    )
    #expect(
      SprintReportPresentation.sprintAxisDomain(
        in: [datum(sprintNumber: 7)]
      ) == 6.5...7.5
    )
    #expect(SprintReportPresentation.sprintAxisDomain(in: []) == nil)
  }

  @Test("Duration axes plot in a natural unit before choosing ticks")
  func durationScale() {
    let seconds = SprintReportDurationScale(maximumDuration: 45)
    let minutes = SprintReportDurationScale(maximumDuration: 5_400)
    let hours = SprintReportDurationScale(maximumDuration: 78_000)

    #expect(seconds.unit == .seconds)
    #expect(seconds.axisLabel(seconds.plottedValue(30)) == "30s")
    #expect(minutes.unit == .minutes)
    #expect(minutes.axisLabel(minutes.plottedValue(1_800)) == "30m")
    #expect(hours.unit == .hours)
    #expect(hours.axisLabel(hours.plottedValue(18_000)) == "5h")
  }

  @Test("Count axes use distinct whole-number labels")
  func countAxisLabels() {
    #expect(
      SprintReportPresentation.countAxisValues(maximumCount: 1) == [0, 1]
    )
    #expect(
      SprintReportPresentation.countAxisValues(maximumCount: 100)
        == [0, 25, 50, 75, 100]
    )
  }

  @Test("Report chart tabs use concise owner-facing labels")
  func chartTabs() {
    #expect(
      SprintReportChartType.allCases.map(\.title)
        == ["Cycle time", "Agent effort", "Outcomes and review"]
    )
  }

  @Test("The selected sprint remains visible after chart interaction ends")
  func persistentSelection() {
    #expect(
      SprintReportPresentation.retainedSelection(current: 3, proposed: nil) == 3
    )
    #expect(
      SprintReportPresentation.retainedSelection(current: 3, proposed: 4) == 4
    )
  }

  @Test("[I09] Reports admit only completed sprint evidence and preserve range selection")
  func i09ReportsExcludeIncompleteWork() {
    let productID = UUID()
    let active = SprintPlan(
      sprint: Sprint(
        productID: productID,
        number: 1,
        goal: "Still delivering",
        state: .active,
        startedAt: Date(timeIntervalSince1970: 100)
      ),
      items: []
    )
    let completed = SprintPlan(
      sprint: Sprint(
        productID: productID,
        number: 2,
        goal: "Accepted outcome",
        state: .completed,
        startedAt: Date(timeIntervalSince1970: 200),
        completedAt: Date(timeIntervalSince1970: 500)
      ),
      items: []
    )

    #expect(
      SprintReportEvidence.completedData(
        plans: [],
        candidates: [],
        runs: [],
        retrospectiveNotes: []
      ).isEmpty
    )
    let data = SprintReportEvidence.completedData(
      plans: [active, completed],
      candidates: [],
      runs: [],
      retrospectiveNotes: []
    )
    #expect(data.map(\.sprintNumber) == [2])
    #expect(data.first?.cycleTime == 300)
    #expect(SprintReportPresentation.visibleData(data, range: .all) == data)
  }

  @Test("[I10] Every report metric is derived from the same completed sprint evidence")
  func i10ReportMetricsShareCompletedSprintEvidence() throws {
    let productID = UUID()
    let sprintID = UUID()
    let sprintItemID = UUID()
    let workItemID = UUID()
    let profileID = UUID()
    let plan = SprintPlan(
      sprint: Sprint(
        id: sprintID,
        productID: productID,
        number: 7,
        goal: "Measure accepted delivery",
        state: .completed,
        startedAt: Date(timeIntervalSince1970: 1_000),
        completedAt: Date(timeIntervalSince1970: 1_600)
      ),
      items: [
        SprintItem(
          id: sprintItemID,
          sprintID: sprintID,
          workItemID: workItemID,
          estimatedTokens: 40_000
        )
      ]
    )
    let runID = UUID()
    let candidates = [
      CandidateRevision(
        productID: productID,
        sprintID: sprintID,
        sprintItemID: sprintItemID,
        workItemID: workItemID,
        implementationRunID: runID,
        version: 3,
        branchName: "ticket/T7",
        baseSHA: "base",
        headSHA: "head",
        worktreePath: "/tmp/ticket-T7",
        status: .accepted,
        commitCount: 1,
        executionResultJSON: "{}"
      )
    ]
    let runs = [
      AgentRun(
        id: runID,
        productID: productID,
        sprintID: sprintID,
        sprintItemID: sprintItemID,
        workItemID: workItemID,
        profileID: profileID,
        status: .completed,
        contextUsedTokens: 24_000,
        activeDurationSeconds: 120
      ),
      AgentRun(
        productID: productID,
        sprintID: sprintID,
        sprintItemID: sprintItemID,
        workItemID: workItemID,
        profileID: profileID,
        status: .failed,
        activeDurationSeconds: 30
      ),
    ]
    let notes = [
      RetrospectiveNote(
        productID: productID,
        sprintID: sprintID,
        authorName: "Product owner",
        category: .suggestedAction,
        body: "Keep the smaller review batches.",
        isActionCandidate: true,
        actionStatus: .accepted,
        actionDestination: .teamPractice
      ),
      RetrospectiveNote(
        productID: productID,
        sprintID: sprintID,
        authorName: "Product owner",
        category: .suggestedAction,
        body: "Do not adopt this.",
        isActionCandidate: true,
        actionStatus: .dismissed,
        actionDestination: .backlog
      ),
    ]

    let datum = try #require(
      SprintReportEvidence.completedData(
        plans: [plan],
        candidates: candidates,
        runs: runs,
        retrospectiveNotes: notes
      ).first
    )
    #expect(datum.plannedTokens == 40_000)
    #expect(datum.reportedContextTokens == 24_000)
    #expect(datum.cycleTime == 600)
    #expect(datum.activeAgentTime == 150)
    #expect(datum.outcomes == 1)
    #expect(datum.reviewCorrections == 2)
    #expect(datum.blockers == 1)
    #expect(datum.acceptedImprovements == 1)
    #expect(
      SprintReportEvidenceMetric.allCases.map(\.title) == [
        "Forecast and context",
        "Cycle time",
        "Delivered outcomes",
        "Correction cycles",
        "Delivery blockers",
        "Adopted improvements",
      ]
    )
    #expect(
      SprintReportEvidenceMetric.allCases.allSatisfy {
        !$0.value(in: datum).isEmpty
      }
    )
  }

  private func datum(
    sprintNumber: Int,
    cycleTime: TimeInterval? = 60,
    activeAgentTime: TimeInterval = 60,
    outcomes: Int = 1
  ) -> SprintReportDatum {
    SprintReportDatum(
      sprintNumber: sprintNumber,
      plannedTokens: 0,
      reportedContextTokens: nil,
      cycleTime: cycleTime,
      activeAgentTime: activeAgentTime,
      outcomes: outcomes,
      reviewCorrections: 0,
      interruptedRuns: 0,
      blockers: 0,
      acceptedImprovements: 0
    )
  }
}
