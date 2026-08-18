import SpeditoCore
import SwiftUI

struct CodexUsagePresentation {
  static func availablePercentage(for window: CodexRateLimitWindow) -> Int {
    Int(window.availablePercent.rounded())
  }

  static func windowTitle(minutes: Int) -> String {
    if minutes.isMultiple(of: 1_440) {
      let days = minutes / 1_440
      return "\(days)-day window"
    }
    if minutes.isMultiple(of: 60) {
      let hours = minutes / 60
      return "\(hours)-hour window"
    }
    return "\(minutes)-minute window"
  }

  static func accessibilitySummary(
    for snapshot: CodexRateLimitsSnapshot,
    isRefreshing: Bool = false,
    isStale: Bool = false
  ) -> String? {
    guard !snapshot.windows.isEmpty else { return nil }
    var parts = snapshot.windows.map {
      "\(windowTitle(minutes: $0.windowDurationMinutes)), \(availablePercentage(for: $0)) percent available"
    }
    if snapshot.reachedLimitType != nil {
      parts.append("limit reached")
    }
    if isRefreshing {
      parts.append("refreshing")
    } else if isStale {
      parts.append("usage may be out of date")
    }
    return parts.joined(separator: "; ")
  }

  static func resetDetail(
    resetAt: Date,
    now: Date,
    isRefreshing: Bool,
    calendar: Calendar = .current
  ) -> String {
    guard resetAt > now else {
      return isRefreshing
        ? "Reset reached · refreshing usage…"
        : "Reset reached · usage may be out of date"
    }
    let minutesRemaining = max(1, Int(ceil(resetAt.timeIntervalSince(now) / 60)))
    let relative: String
    if minutesRemaining < 60 {
      relative = "\(minutesRemaining)m"
    } else if minutesRemaining < 1_440 {
      let hours = minutesRemaining / 60
      let minutes = minutesRemaining % 60
      relative = minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    } else {
      let days = minutesRemaining / 1_440
      let hours = (minutesRemaining % 1_440) / 60
      relative = hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
    }

    let absolute: String
    if calendar.isDate(resetAt, inSameDayAs: now) {
      absolute = "today at \(resetAt.formatted(date: .omitted, time: .shortened))"
    } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
      calendar.isDate(resetAt, inSameDayAs: tomorrow)
    {
      absolute = "tomorrow at \(resetAt.formatted(date: .omitted, time: .shortened))"
    } else {
      absolute = resetAt.formatted(
        .dateTime
          .weekday(.abbreviated)
          .month(.abbreviated)
          .day()
          .hour()
          .minute()
      )
    }
    return "Resets \(absolute) · in \(relative)"
  }

}

private struct CodexUsageWindowRow: View {
  let window: CodexRateLimitWindow
  let now: Date
  let isRefreshing: Bool
  let limitReached: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(CodexUsagePresentation.windowTitle(minutes: window.windowDurationMinutes))
          .font(.caption.weight(.medium))
        Spacer()
        Text("\(CodexUsagePresentation.availablePercentage(for: window))% available")
          .font(.caption.monospacedDigit().weight(.semibold))
      }
      ProgressView(value: window.availablePercent, total: 100)
        .tint(limitReached ? .red : .accentColor)
      if let resetAt = window.resetsAt {
        Text(
          CodexUsagePresentation.resetDetail(
            resetAt: resetAt,
            now: now,
            isRefreshing: isRefreshing
          )
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      } else if isRefreshing {
        Text("Refreshing usage…")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }
}

struct SidebarCodexStatus: View {
  @EnvironmentObject private var model: AppModel
  @State private var showingConnectionPopover = false
  @State private var showingUsagePopover = false

  var body: some View {
    Button {
      showingUsagePopover = false
      showingConnectionPopover.toggle()
    } label: {
      statusLabel
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)
    .background(.bar)
    .help(model.codexConnectionState.diagnostic ?? "Choose the Codex installation")
    .accessibilityLabel("Codex connection")
    .accessibilityValue(model.codexConnectionState.detail)
    .accessibilityIdentifier("codex.connection")
    .popover(isPresented: $showingConnectionPopover, arrowEdge: .bottom) {
      connectionPopover
    }
  }

  private var statusLabel: some View {
    HStack(spacing: 9) {
      Image(systemName: model.codexConnectionState.symbolName)
        .foregroundStyle(model.codexConnectionState.tint)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text("Codex")
          .font(.caption.weight(.medium))
        Text(model.codexConnectionState.detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      if model.codexConnectionState.isConnected {
        codexUsageIndicator
      }
    }
    .padding(.horizontal, 14)
    .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)
    .contentShape(Rectangle())
  }

  private var connectionPopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Codex installation")
          .font(.headline)
        Text("Choose which local Codex installation Spedito uses.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(14)

      Divider()

      if model.codexInstallations.isEmpty {
        Text("No installations found")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(14)
      } else {
        ForEach(model.codexInstallations) { installation in
          HStack(spacing: 8) {
            Button {
              showingConnectionPopover = false
              Task {
                await model.selectCodexInstallation(id: installation.id)
              }
            } label: {
              HStack(spacing: 10) {
                Image(
                  systemName: installation.id == model.selectedCodexInstallationID
                    ? "checkmark.circle.fill" : "circle"
                )
                .foregroundStyle(
                  installation.id == model.selectedCodexInstallationID
                    ? Color.green : Color.secondary
                )
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                  Text(installation.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                  Text(installation.executableURL.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Spacer(minLength: 0)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canChangeCodexInstallation)
            .help(installation.executableURL.path)

            if installation.kind == .custom {
              Button(role: .destructive) {
                Task {
                  await model.removeCodexInstallation(id: installation.id)
                }
              } label: {
                Image(systemName: "trash")
                  .foregroundStyle(.red)
                  .frame(width: 24, height: 24)
              }
              .buttonStyle(.plain)
              .disabled(!model.canChangeCodexInstallation)
              .help("Remove \(installation.name)")
            }
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 9)
          .background(
            installation.id == model.selectedCodexInstallationID
              ? Color.accentColor.opacity(0.08) : Color.clear
          )
        }
      }

      Divider()

      VStack(alignment: .leading, spacing: 10) {
        Button {
          showingConnectionPopover = false
          chooseCodexInstallation()
        } label: {
          Label("Add Codex installation…", systemImage: "plus")
        }
        .disabled(!model.canChangeCodexInstallation)

        if model.codexConnectionState.showsRetryAction {
          Button {
            showingConnectionPopover = false
            Task {
              await model.retryCodexConnection()
            }
          } label: {
            Label("Retry connection", systemImage: "arrow.clockwise")
          }
          .disabled(!model.canChangeCodexInstallation)
        }

        if let diagnostic = model.codexConnectionState.diagnostic {
          Text(diagnostic)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(14)
    }
    .frame(width: 330)
  }

  @ViewBuilder
  private var codexUsageIndicator: some View {
    Group {
      if let snapshot = model.codexRateLimits,
        let availablePercent = snapshot.windows.map(\.availablePercent).min()
      {
        CircularProgressRing(
          fraction: availablePercent / 100,
          tint: snapshot.reachedLimitType == nil ? .accentColor : .red
        )
      } else if model.isRefreshingCodexUsage {
        ProgressView()
          .controlSize(.mini)
      } else {
        Image(systemName: "circle.dashed")
          .font(.system(size: 12))
          .foregroundStyle(.tertiary)
      }
    }
    .frame(width: 18, height: 18)
    .contentShape(Rectangle())
    .help("Show Codex usage")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Codex usage")
    .accessibilityValue(
      model.codexRateLimits.flatMap {
        CodexUsagePresentation.accessibilitySummary(
          for: $0,
          isRefreshing: model.isRefreshingCodexUsage,
          isStale: model.isCodexUsageStale
        )
      } ?? (model.isRefreshingCodexUsage ? "Loading" : "Unavailable")
    )
    .onHover { hovering in
      showingUsagePopover = hovering
    }
    .popover(isPresented: $showingUsagePopover, arrowEdge: .bottom) {
      codexUsageDetailsPopover
    }
  }

  private var codexUsageDetailsPopover: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let snapshot = model.codexRateLimits, !snapshot.windows.isEmpty {
        TimelineView(.periodic(from: .now, by: 60)) { context in
          VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(snapshot.windows.enumerated()), id: \.element.id) { index, window in
              if index > 0 {
                Divider()
              }
              CodexUsageWindowRow(
                window: window,
                now: context.date,
                isRefreshing: model.isRefreshingCodexUsage,
                limitReached: snapshot.reachedLimitType != nil
              )
            }
          }
        }
        if model.isCodexUsageStale {
          Text(
            model.codexUsageUpdatedAt.map {
              "Usage may be out of date · last updated \($0.formatted(date: .omitted, time: .shortened))"
            } ?? "Usage may be out of date"
          )
          .font(.caption2)
          .foregroundStyle(.orange)
        }
      } else if model.isRefreshingCodexUsage {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Loading usage…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        Text("Usage details are not available for this Codex account.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .frame(width: 290)
  }

  private func chooseCodexInstallation() {
    let panel = NSOpenPanel()
    panel.title = "Add Codex installation"
    panel.message = "Choose a Codex app or an executable named codex."
    panel.prompt = "Add"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false

    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      await model.addCodexInstallation(at: url)
    }
  }
}
