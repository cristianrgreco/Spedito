import Foundation
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

  private func datum(
    sprintNumber: Int,
    cycleTime: TimeInterval? = 60,
    activeAgentTime: TimeInterval = 60,
    outcomes: Int = 1
  ) -> SprintReportDatum {
    SprintReportDatum(
      sprintNumber: sprintNumber,
      cycleTime: cycleTime,
      activeAgentTime: activeAgentTime,
      outcomes: outcomes,
      reviewCorrections: 0,
      interruptedRuns: 0
    )
  }
}
