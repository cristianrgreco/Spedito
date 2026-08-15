import Charts
import SpeditoCore
import SwiftUI

struct ReportsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var sprintRange: SprintReportRange = .latestTwelve
  @State private var selectedSprintNumber: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Reports")
            .font(.largeTitle.bold())
          Text("Is delivery becoming cheaper, faster, clearer, and more reliable?")
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !completedSprints.isEmpty {
          Text(
            "\(completedSprints.count) completed sprint\(completedSprints.count == 1 ? "" : "s")"
          )
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
        }
      }
      .workspaceHeaderLayout()

      Divider()

      if completedSprints.isEmpty {
        ContentUnavailableView {
          Label("No report data yet", systemImage: "chart.xyaxis.line")
        } description: {
          Text(
            "Complete a sprint and Spedito will report delivery time, outcomes, and review effort."
          )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
              Text("Measured delivery signals")
                .font(.title3.bold())
              LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                ReportMetricCard(
                  title: "Delivered outcomes",
                  value: deliveredOutcomes.formatted(),
                  detail: "Tickets accepted across completed sprints",
                  symbol: "shippingbox",
                  tint: .blue
                )
                ReportMetricCard(
                  title: "Median cycle time",
                  value: medianCycleTime ?? "—",
                  detail: "Wall time from start sprint to the final accepted ticket",
                  symbol: "clock",
                  tint: .purple
                )
                ReportMetricCard(
                  title: "Agent time per outcome",
                  value: agentTimePerOutcome ?? "—",
                  detail: "Recorded active delivery and review time; queues excluded",
                  symbol: "timer",
                  tint: .indigo
                )
                ReportMetricCard(
                  title: "First-pass review",
                  value: firstPassRate,
                  detail: "Accepted candidates that needed no correction cycle",
                  symbol: "checkmark.bubble",
                  tint: .green
                )
                ReportMetricCard(
                  title: "Review corrections",
                  value: reviewCorrectionCount.formatted(),
                  detail: "Additional candidate revisions before acceptance",
                  symbol: "arrow.clockwise",
                  tint: .pink
                )
              }
            }

            if !sprintData.isEmpty {
              VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                  Text("Sprint performance")
                    .font(.title3.bold())
                  Spacer()
                  if sprintData.count > SprintReportPresentation.recentSprintLimit {
                    Picker("Sprint range", selection: $sprintRange) {
                      ForEach(SprintReportRange.allCases) { range in
                        Text(range.title).tag(range)
                      }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                    .accessibilityLabel("Sprint range")
                  }
                }
                Text(
                  "Choose one delivery signal at a time. Agent effort is normalized per delivered outcome so larger sprints do not automatically look more expensive. Select a sprint for exact values."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                SprintPerformanceChart(
                  data: visibleSprintData,
                  selectedSprintNumber: $selectedSprintNumber
                )
              }
            }

            Text(
              "Treat one sprint as a baseline, not a trend. Compare similar work and connect changes to an adopted retrospective practice before attributing an improvement."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          .padding(24)
        }
      }
    }
    .onAppear {
      selectLatestVisibleSprintIfNeeded()
    }
    .onChange(of: visibleSprintData.map(\.sprintNumber)) { _, _ in
      selectLatestVisibleSprintIfNeeded()
    }
  }

  private var completedSprints: [SprintPlan] {
    model.sprintHistory
      .filter { $0.sprint.state == .completed }
      .sorted { $0.sprint.number < $1.sprint.number }
  }

  private var completedSprintIDs: Set<UUID> {
    Set(completedSprints.map(\.sprint.id))
  }

  private var acceptedCandidates: [CandidateRevision] {
    model.candidateRevisions.filter {
      completedSprintIDs.contains($0.sprintID) && $0.status == .accepted
    }
  }

  private var deliveredOutcomes: Int {
    Set(acceptedCandidates.map(\.workItemID)).count
  }

  private var medianCycleTime: String? {
    let durations = completedSprints.compactMap { plan -> TimeInterval? in
      guard let started = plan.sprint.startedAt, let completed = plan.sprint.completedAt else {
        return nil
      }
      return max(0, completed.timeIntervalSince(started))
    }.sorted()
    guard !durations.isEmpty else { return nil }
    let middle = durations.count / 2
    let value =
      durations.count.isMultiple(of: 2)
      ? (durations[middle - 1] + durations[middle]) / 2
      : durations[middle]
    return RunDurationFormatter.duration(value)
  }

  private var totalAgentTime: TimeInterval {
    model.runs
      .filter { $0.sprintID.map(completedSprintIDs.contains) == true }
      .reduce(0) { $0 + $1.activeDuration() }
  }

  private var agentTimePerOutcome: String? {
    guard deliveredOutcomes > 0, totalAgentTime > 0 else { return nil }
    return RunDurationFormatter.duration(totalAgentTime / Double(deliveredOutcomes))
  }

  private var firstPassRate: String {
    guard !acceptedCandidates.isEmpty else { return "—" }
    let firstPass = acceptedCandidates.filter { $0.version == 1 }.count
    return (Double(firstPass) / Double(acceptedCandidates.count))
      .formatted(.percent.precision(.fractionLength(0)))
  }

  private var reviewCorrectionCount: Int {
    acceptedCandidates.reduce(0) { $0 + max(0, $1.version - 1) }
  }

  private var sprintData: [SprintReportDatum] {
    completedSprints.map { plan in
      let candidates = acceptedCandidates.filter { $0.sprintID == plan.sprint.id }
      let cycleTime =
        if let started = plan.sprint.startedAt,
          let completed = plan.sprint.completedAt
        {
          Optional(max(0, completed.timeIntervalSince(started)))
        } else {
          Optional<TimeInterval>.none
        }
      let runs = model.runs.filter { $0.sprintID == plan.sprint.id }
      return SprintReportDatum(
        sprintNumber: plan.sprint.number,
        cycleTime: cycleTime,
        activeAgentTime: runs.reduce(0) { $0 + $1.activeDuration() },
        outcomes: Set(candidates.map(\.workItemID)).count,
        reviewCorrections: candidates.reduce(0) { $0 + max(0, $1.version - 1) },
        interruptedRuns: runs.filter {
          $0.status == .failed || $0.status == .interrupted
        }.count
      )
    }
  }

  private var visibleSprintData: [SprintReportDatum] {
    SprintReportPresentation.visibleData(sprintData, range: sprintRange)
  }

  private func selectLatestVisibleSprintIfNeeded() {
    let visibleSprintNumbers = Set(visibleSprintData.map(\.sprintNumber))
    if selectedSprintNumber.map(visibleSprintNumbers.contains) != true {
      selectedSprintNumber = visibleSprintData.last?.sprintNumber
    }
  }
}

enum SprintReportRange: String, CaseIterable, Identifiable {
  case latestTwelve
  case all

  var id: Self { self }

  var title: String {
    switch self {
    case .latestTwelve: "Latest 12"
    case .all: "All"
    }
  }
}

struct SprintReportDatum: Identifiable, Equatable {
  let sprintNumber: Int
  let cycleTime: TimeInterval?
  let activeAgentTime: TimeInterval
  let outcomes: Int
  let reviewCorrections: Int
  let interruptedRuns: Int

  var id: Int { sprintNumber }

  var agentTimePerOutcome: TimeInterval? {
    guard outcomes > 0, activeAgentTime > 0 else { return nil }
    return activeAgentTime / Double(outcomes)
  }
}

enum SprintReportMetric {
  case cycleTime
  case agentTimePerOutcome

  func value(in datum: SprintReportDatum) -> TimeInterval? {
    switch self {
    case .cycleTime: datum.cycleTime
    case .agentTimePerOutcome: datum.agentTimePerOutcome
    }
  }
}

enum SprintReportChartType: String, CaseIterable, Identifiable {
  case cycleTime
  case agentEffort
  case outcomesAndReview

  var id: Self { self }

  var title: String {
    switch self {
    case .cycleTime: "Cycle time"
    case .agentEffort: "Agent effort"
    case .outcomesAndReview: "Outcomes and review"
    }
  }
}

struct SprintReportTrendPoint: Identifiable, Equatable {
  let sprintNumber: Int
  let value: TimeInterval
  let segment: Int

  var id: String {
    "\(segment)-\(sprintNumber)"
  }
}

enum SprintReportPresentation {
  static let recentSprintLimit = 12

  static func visibleData(
    _ data: [SprintReportDatum],
    range: SprintReportRange
  ) -> [SprintReportDatum] {
    switch range {
    case .latestTwelve:
      Array(data.suffix(recentSprintLimit))
    case .all:
      data
    }
  }

  static func trendPoints(
    in data: [SprintReportDatum],
    metric: SprintReportMetric
  ) -> [SprintReportTrendPoint] {
    var segment = 0
    var previousMeasuredSprint: Int?
    var points: [SprintReportTrendPoint] = []

    for datum in data {
      guard let value = metric.value(in: datum) else {
        previousMeasuredSprint = nil
        segment += 1
        continue
      }

      if let previousMeasuredSprint,
        datum.sprintNumber != previousMeasuredSprint + 1
      {
        segment += 1
      }
      points.append(
        SprintReportTrendPoint(
          sprintNumber: datum.sprintNumber,
          value: value,
          segment: segment
        )
      )
      previousMeasuredSprint = datum.sprintNumber
    }
    return points
  }

  static func median(_ values: [TimeInterval]) -> TimeInterval? {
    let sortedValues = values.sorted()
    guard !sortedValues.isEmpty else { return nil }
    let middle = sortedValues.count / 2
    return sortedValues.count.isMultiple(of: 2)
      ? (sortedValues[middle - 1] + sortedValues[middle]) / 2
      : sortedValues[middle]
  }

  static func axisSprintNumbers(
    in data: [SprintReportDatum],
    maximumLabelCount: Int = 8
  ) -> [Int] {
    let sprintNumbers = data.map(\.sprintNumber)
    guard maximumLabelCount > 1, sprintNumbers.count > maximumLabelCount else {
      return sprintNumbers
    }

    let step = Int(
      ceil(Double(sprintNumbers.count - 1) / Double(maximumLabelCount - 1))
    )
    var labels = stride(from: 0, to: sprintNumbers.count, by: step)
      .map { sprintNumbers[$0] }
    if let last = sprintNumbers.last, labels.last != last {
      labels.append(last)
    }
    return labels
  }

  static func sprintAxisDomain(
    in data: [SprintReportDatum]
  ) -> ClosedRange<Double>? {
    let sprintNumbers = data.map(\.sprintNumber)
    guard
      let firstSprintNumber = sprintNumbers.min(),
      let lastSprintNumber = sprintNumbers.max()
    else {
      return nil
    }
    return (Double(firstSprintNumber) - 0.5)...(Double(lastSprintNumber) + 0.5)
  }

  static func countAxisValues(
    maximumCount: Int,
    desiredIntervals: Int = 4
  ) -> [Int] {
    let maximumCount = max(1, maximumCount)
    let desiredIntervals = max(1, desiredIntervals)
    let step = max(
      1,
      Int(ceil(Double(maximumCount) / Double(desiredIntervals)))
    )
    var values = Array(stride(from: 0, through: maximumCount, by: step))
    if values.last != maximumCount {
      values.append(maximumCount)
    }
    return values
  }

  static func retainedSelection(current: Int?, proposed: Int?) -> Int? {
    proposed ?? current
  }
}

private struct SprintPerformanceChart: View {
  let data: [SprintReportDatum]
  @Binding var selectedSprintNumber: Int?
  @State private var chartType: SprintReportChartType = .cycleTime

  private var persistentSelectedSprintNumber: Binding<Int?> {
    Binding(
      get: { selectedSprintNumber },
      set: { proposedSelection in
        selectedSprintNumber = SprintReportPresentation.retainedSelection(
          current: selectedSprintNumber,
          proposed: proposedSelection
        )
      }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Picker("Chart type", selection: $chartType) {
        ForEach(SprintReportChartType.allCases) { chartType in
          Text(chartType.title).tag(chartType)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 520)
      .accessibilityLabel("Chart type")

      switch chartType {
      case .cycleTime:
        SprintTimeTrendChart(
          title: "Cycle time",
          detail: "Wall time from sprint start to completion",
          metric: .cycleTime,
          tint: .purple,
          data: data,
          selectedSprintNumber: persistentSelectedSprintNumber
        )
      case .agentEffort:
        SprintTimeTrendChart(
          title: "Agent time per outcome",
          detail: "Active delivery and review time divided by delivered outcomes",
          metric: .agentTimePerOutcome,
          tint: .indigo,
          data: data,
          selectedSprintNumber: persistentSelectedSprintNumber
        )
      case .outcomesAndReview:
        SprintOutcomeChart(
          data: data,
          selectedSprintNumber: persistentSelectedSprintNumber
        )
      }

      if let selectedSprint = data.first(where: {
        $0.sprintNumber == selectedSprintNumber
      }) {
        SprintReportSelectionSummary(sprint: selectedSprint)
      }
    }
  }
}

private struct SprintTimeTrendChart: View {
  let title: String
  let detail: String
  let metric: SprintReportMetric
  let tint: Color
  let data: [SprintReportDatum]
  @Binding var selectedSprintNumber: Int?

  private var points: [SprintReportTrendPoint] {
    SprintReportPresentation.trendPoints(in: data, metric: metric)
  }

  private var median: TimeInterval? {
    SprintReportPresentation.median(points.map(\.value))
  }

  private var durationScale: SprintReportDurationScale {
    SprintReportDurationScale(
      maximumDuration: points.map(\.value).max() ?? 0
    )
  }

  private var maximumPlottedValue: Double {
    max(
      1,
      durationScale.plottedValue(points.map(\.value).max() ?? 0) * 1.12
    )
  }

  private var axisSprintNumbers: [Int] {
    SprintReportPresentation.axisSprintNumbers(in: data)
  }

  private var sprintAxisDomain: ClosedRange<Double> {
    SprintReportPresentation.sprintAxisDomain(in: data) ?? 0.5...1.5
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.headline)
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let median {
          VStack(alignment: .trailing, spacing: 2) {
            Text("Median")
              .font(.caption2)
              .foregroundStyle(.secondary)
            Text(RunDurationFormatter.duration(median))
              .font(.caption.monospacedDigit().weight(.semibold))
          }
        }
      }

      if points.isEmpty {
        Text("No measured \(title.lowercased()) yet")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 150)
      } else {
        Chart {
          if let median {
            RuleMark(
              y: .value("Median", durationScale.plottedValue(median))
            )
            .foregroundStyle(.secondary.opacity(0.45))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
          }

          ForEach(points) { point in
            LineMark(
              x: .value("Sprint", point.sprintNumber),
              y: .value(title, durationScale.plottedValue(point.value)),
              series: .value("Measured segment", point.segment)
            )
            .foregroundStyle(tint.opacity(0.8))
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.linear)
          }

          ForEach(points) { point in
            PointMark(
              x: .value("Sprint", point.sprintNumber),
              y: .value(title, durationScale.plottedValue(point.value))
            )
            .foregroundStyle(tint)
            .symbolSize(48)
            .accessibilityLabel("Sprint \(point.sprintNumber), \(title)")
            .accessibilityValue(RunDurationFormatter.duration(point.value))
          }

          if let selectedSprintNumber,
            data.contains(where: { $0.sprintNumber == selectedSprintNumber })
          {
            RuleMark(x: .value("Selected sprint", selectedSprintNumber))
              .foregroundStyle(.secondary.opacity(0.55))
              .lineStyle(StrokeStyle(lineWidth: 1))
          }
        }
        .chartXScale(domain: sprintAxisDomain)
        .chartYScale(domain: 0...maximumPlottedValue)
        .chartYAxis {
          AxisMarks(position: .leading) { value in
            AxisGridLine()
              .foregroundStyle(.quaternary)
            AxisValueLabel {
              if let plottedValue = value.as(Double.self) {
                Text(durationScale.axisLabel(plottedValue))
              }
            }
          }
        }
        .chartXAxis {
          AxisMarks(values: axisSprintNumbers) { value in
            AxisGridLine()
              .foregroundStyle(.quaternary.opacity(0.7))
            AxisTick()
            AxisValueLabel {
              if let sprintNumber = value.as(Int.self) {
                Text("S\(sprintNumber)")
              }
            }
          }
        }
        .chartXSelection(value: $selectedSprintNumber)
        .frame(height: 190)
      }
    }
    .padding(16)
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.quaternary, lineWidth: 1)
    }
  }
}

private struct SprintOutcomeChart: View {
  let data: [SprintReportDatum]
  @Binding var selectedSprintNumber: Int?

  private var maximumCount: Int {
    max(
      1,
      data.flatMap { [$0.outcomes, $0.reviewCorrections] }.max() ?? 1
    )
  }

  private var axisSprintNumbers: [Int] {
    SprintReportPresentation.axisSprintNumbers(in: data)
  }

  private var sprintAxisDomain: ClosedRange<Double> {
    SprintReportPresentation.sprintAxisDomain(in: data) ?? 0.5...1.5
  }

  private var countAxisValues: [Int] {
    SprintReportPresentation.countAxisValues(maximumCount: maximumCount)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Outcomes and review")
          .font(.headline)
        Text("Delivered outcomes and additional candidate correction cycles")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 14) {
        Label("Accepted outcomes", systemImage: "square.fill")
          .foregroundStyle(.blue)
        Label("Correction cycles", systemImage: "circle.fill")
          .foregroundStyle(.orange)
        Spacer()
      }
      .font(.caption)

      Chart {
        ForEach(data) { sprint in
          BarMark(
            x: .value("Sprint", sprint.sprintNumber),
            y: .value("Accepted outcomes", sprint.outcomes)
          )
          .foregroundStyle(Color.blue.gradient)
          .accessibilityLabel("Sprint \(sprint.sprintNumber), accepted outcomes")
          .accessibilityValue(sprint.outcomes.formatted())
        }

        ForEach(data) { sprint in
          LineMark(
            x: .value("Sprint", sprint.sprintNumber),
            y: .value("Correction cycles", sprint.reviewCorrections)
          )
          .foregroundStyle(.orange)
          .lineStyle(StrokeStyle(lineWidth: 2))
          .interpolationMethod(.linear)
        }

        ForEach(data) { sprint in
          PointMark(
            x: .value("Sprint", sprint.sprintNumber),
            y: .value("Correction cycles", sprint.reviewCorrections)
          )
          .foregroundStyle(.orange)
          .symbolSize(45)
          .accessibilityLabel("Sprint \(sprint.sprintNumber), correction cycles")
          .accessibilityValue(sprint.reviewCorrections.formatted())
        }

        if let selectedSprintNumber,
          data.contains(where: { $0.sprintNumber == selectedSprintNumber })
        {
          RuleMark(x: .value("Selected sprint", selectedSprintNumber))
            .foregroundStyle(.secondary.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1))
        }
      }
      .chartXScale(domain: sprintAxisDomain)
      .chartYScale(domain: 0...Double(maximumCount) * 1.12)
      .chartYAxis {
        AxisMarks(position: .leading, values: countAxisValues) { value in
          AxisGridLine()
            .foregroundStyle(.quaternary)
          AxisValueLabel {
            if let count = value.as(Int.self) {
              Text(count.formatted())
            }
          }
        }
      }
      .chartXAxis {
        AxisMarks(values: axisSprintNumbers) { value in
          AxisGridLine()
            .foregroundStyle(.quaternary.opacity(0.7))
          AxisTick()
          AxisValueLabel {
            if let sprintNumber = value.as(Int.self) {
              Text("S\(sprintNumber)")
            }
          }
        }
      }
      .chartXSelection(value: $selectedSprintNumber)
      .frame(height: 190)
    }
    .padding(16)
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.quaternary, lineWidth: 1)
    }
  }
}

private struct SprintReportSelectionSummary: View {
  let sprint: SprintReportDatum

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Sprint \(sprint.sprintNumber)")
        .font(.headline)
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 130), spacing: 18)],
        alignment: .leading,
        spacing: 10
      ) {
        ReportSelectionValue(
          title: "Cycle time",
          value: sprint.cycleTime.map(RunDurationFormatter.duration) ?? "Unavailable"
        )
        ReportSelectionValue(
          title: "Agent time per outcome",
          value: sprint.agentTimePerOutcome.map(RunDurationFormatter.duration) ?? "Unavailable"
        )
        ReportSelectionValue(
          title: "Delivered outcomes",
          value: sprint.outcomes.formatted()
        )
        ReportSelectionValue(
          title: "Correction cycles",
          value: sprint.reviewCorrections.formatted()
        )
        ReportSelectionValue(
          title: "Interrupted runs",
          value: sprint.interruptedRuns.formatted()
        )
      }
    }
    .padding(14)
    .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
  }
}

private struct ReportSelectionValue: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.caption.monospacedDigit().weight(.semibold))
    }
  }
}

enum SprintReportDurationUnit: Equatable {
  case seconds
  case minutes
  case hours

  var seconds: TimeInterval {
    switch self {
    case .seconds: 1
    case .minutes: 60
    case .hours: 3_600
    }
  }

  var suffix: String {
    switch self {
    case .seconds: "s"
    case .minutes: "m"
    case .hours: "h"
    }
  }
}

struct SprintReportDurationScale: Equatable {
  let unit: SprintReportDurationUnit

  init(maximumDuration: TimeInterval) {
    if maximumDuration >= 7_200 {
      unit = .hours
    } else if maximumDuration >= 120 {
      unit = .minutes
    } else {
      unit = .seconds
    }
  }

  func plottedValue(_ duration: TimeInterval) -> Double {
    max(0, duration) / unit.seconds
  }

  func axisLabel(_ plottedValue: Double) -> String {
    let roundedValue = plottedValue.rounded()
    let value =
      if abs(plottedValue - roundedValue) < 0.01 {
        roundedValue.formatted(.number.precision(.fractionLength(0)))
      } else {
        plottedValue.formatted(.number.precision(.fractionLength(1)))
      }
    return value + unit.suffix
  }
}

private struct ImprovementLens: Identifiable {
  let title: String
  let detail: String
  let symbol: String
  let tint: Color

  var id: String { title }
}

private struct ImprovementLensCard: View {
  let lens: ImprovementLens

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: lens.symbol)
        .font(.title3)
        .foregroundStyle(lens.tint)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 4) {
        Text(lens.title)
          .font(.headline)
        Text(lens.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct RetrospectiveSprintRow: View {
  let plan: SprintPlan

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
        .font(.title2)
        .foregroundStyle(.purple)
      VStack(alignment: .leading, spacing: 3) {
        Text("Sprint \(plan.sprint.number)")
          .font(.headline)
        Text(plan.sprint.goal)
          .lineLimit(1)
        Text("\(plan.items.count) tickets · evidence ready for retrospective")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if let completedAt = plan.sprint.completedAt {
        Text(completedAt, style: .date)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(15)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct ReportMetricCard: View {
  let title: String
  let value: String
  let detail: String
  let symbol: String
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Image(systemName: symbol)
          .foregroundStyle(tint)
        Spacer()
        Text(value)
          .font(.title2.monospacedDigit().weight(.semibold))
      }
      Text(title)
        .font(.headline)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
  }
}

struct SprintLane: Identifiable {
  let title: String
  let states: Set<WorkItemState>

  var id: String { title }
}
