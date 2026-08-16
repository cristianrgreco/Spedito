import SpeditoCore
import SwiftUI

struct AppVersionsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var selectedVersionID: UUID?
  @State private var openingVersionID: UUID?
  @State private var isStopping = false

  private var appVersions: [AppVersion] {
    model.appVersions
  }

  private var emptyStateDescription: String {
    guard model.productRepository != nil else {
      return "Approve a ticket with a runnable app, then open or revisit its versions here."
    }
    guard let run = model.repositoryKnowledgeSnapshot?.run else {
      return
        "The imported source has not been checked for a complete browser or macOS app launch recipe."
    }
    if run.purpose == .importedAppLaunch {
      switch run.status {
      case .pendingAnalysis, .analyzing, .reviewing, .publishing:
        return
          "The business analyst and tech lead are checking the imported source for a complete, safe launch recipe."
      case .failed, .interrupted, .stale:
        return
          "The imported source launch check did not finish. Check it again, or approve a ticket with a runnable app."
      case .completed:
        return
          "Spedito did not find and independently verify a complete browser or macOS app launch recipe in the imported source. Approve a ticket with a runnable app to add a version."
      }
    }
    return
      "Spedito did not find and independently verify a complete browser or macOS app launch recipe during import. Check the imported source again, or approve a ticket with a runnable app."
  }

  private var importedLaunchCheckButtonTitle: String {
    guard let run = model.repositoryKnowledgeSnapshot?.run, run.purpose == .importedAppLaunch else {
      return "Check imported source"
    }
    switch run.status {
    case .failed, .interrupted, .stale, .completed:
      return "Check imported source again"
    default:
      return "Checking imported source"
    }
  }

  private var selectedVersion: AppVersion? {
    appVersions.first { $0.id == selectedVersionID } ?? appVersions.first
  }

  private var activeVersion: AppVersion? {
    appVersions.first { version in
      guard let status = model.currentAppVersionSession(id: version.id)?.status else {
        return false
      }
      return status == .preparing || status == .starting || status == .ready
    }
  }

  private var actionIsRunning: Bool {
    openingVersionID != nil || isStopping
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 20) {
        VStack(alignment: .leading, spacing: 4) {
          Text("App versions")
            .font(.largeTitle.bold())
            .accessibilityIdentifier("app.versions")
          Text("Open the imported source or any accepted app version.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let selectedVersion {
          VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
              Button(action: openSelectedVersion) {
                if openingVersionID == selectedVersion.id {
                  ProgressView()
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
                } else {
                  Image(systemName: "play.fill")
                    .font(.callout.weight(.semibold))
                    .frame(width: 18, height: 18)
                }
              }
              .buttonStyle(.bordered)
              .tint(.green)
              .disabled(actionIsRunning || selectedSessionIsOpening)
              .accessibilityLabel(openActionTitle(for: selectedVersion))
              .help(openActionHelp(for: selectedVersion))

              .accessibilityIdentifier("app.version.open")
              if let activeVersion {
                Button(role: .destructive, action: stopActiveVersion) {
                  Image(systemName: "stop.fill")
                    .font(.callout.weight(.semibold))
                    .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(actionIsRunning)
                .accessibilityLabel("Stop \(versionReference(for: activeVersion))")
                .help("Stop this app version and keep it ready to reopen")
              }
            }
            Text(versionReference(for: selectedVersion))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .workspaceHeaderLayout()

      Divider()

      if appVersions.isEmpty, model.productRepository != nil {
        ContentUnavailableView {
          Label("Nothing to open yet", systemImage: "macwindow")
        } description: {
          Text(emptyStateDescription)
        } actions: {
          Button {
            Task { await model.checkImportedAppLaunch() }
          } label: {
            HStack(spacing: 6) {
              if model.isCheckingImportedAppLaunch {
                ProgressView()
                  .controlSize(.small)
              } else {
                Image(systemName: "sparkles")
              }
              Text(importedLaunchCheckButtonTitle)
            }
          }
          .buttonStyle(.borderedProminent)
          .tint(.purple)
          .disabled(!model.canCheckImportedAppLaunch)
          .help(
            model.isCheckingImportedAppLaunch
              ? "The business analyst and tech lead are checking the imported source"
              : "Ask the business analyst and tech lead to identify and verify a launch recipe"
          )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if appVersions.isEmpty {
        ContentUnavailableView(
          "Nothing to open yet",
          systemImage: "macwindow",
          description: Text(emptyStateDescription)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 6) {
            ForEach(appVersions) { version in
              Button {
                selectedVersionID = version.id
              } label: {
                appVersionRow(
                  version,
                  isSelected: version.id == selectedVersionID
                )
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("app.version.\(version.id.uuidString)")
            }
          }
          .padding(20)
        }
      }
    }
    .onAppear(perform: selectLatestVersionIfNeeded)
    .onChange(of: appVersions.map(\.id)) { _, _ in
      selectLatestVersionIfNeeded()
    }
  }

  private var selectedSessionIsOpening: Bool {
    guard
      let selectedVersion,
      let status = model.currentAppVersionSession(id: selectedVersion.id)?.status
    else { return false }
    return status == .preparing || status == .starting
  }

  private func appVersionRow(
    _ version: AppVersion,
    isSelected: Bool
  ) -> some View {
    let session = model.currentAppVersionSession(id: version.id)
    let isLatest = version.id == appVersions.first?.id

    return HStack(spacing: 12) {
      Image(systemName: presentationSymbol(for: version))
        .font(.title3)
        .foregroundStyle(Color.accentColor)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Text(primaryDescription(for: version))
            .font(.body.weight(.semibold))
          if isLatest {
            versionLabel("Latest", tint: .accentColor)
          }
          if case .imported = version {
            versionLabel("Imported", tint: .secondary)
          }
          if let status = session?.status {
            statusLabel(status)
          }
        }
        Text(sourceDescription(for: version))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 3) {
        Text(version.acceptedAt.formatted(date: .abbreviated, time: .shortened))
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(shortRevision(for: version))
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
      }
    }
    .padding(14)
    .background(
      isSelected ? Color.accentColor.opacity(0.11) : .clear,
      in: RoundedRectangle(cornerRadius: 8)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(
          isSelected ? Color.accentColor.opacity(0.28) : .clear,
          lineWidth: 1
        )
    }
    .contentShape(RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  @ViewBuilder
  private func statusLabel(_ status: DemoSessionStatus) -> some View {
    switch status {
    case .preparing, .starting:
      versionLabel("Opening…", tint: .orange)
    case .ready:
      versionLabel("Running", tint: .green)
    case .failed:
      versionLabel("Needs retry", tint: .orange)
    case .stopped:
      EmptyView()
    }
  }

  private func versionLabel(_ title: String, tint: Color) -> some View {
    Text(title)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(tint.opacity(0.1), in: Capsule())
  }

  private func presentationSymbol(for version: AppVersion) -> String {
    switch version.specification.presentation.kind {
    case .browser: "globe"
    case .macApplication: "macwindow"
    case .artifact, .commandOutput: "doc"
    }
  }

  private func primaryDescription(for version: AppVersion) -> String {
    switch version {
    case .imported:
      return "Imported source"
    case .accepted(let launch):
      guard
        let item = model.workItems.first(where: {
          $0.id == launch.candidate.workItemID
        })
      else {
        return version.specification.title
      }
      return "\(item.key) · \(item.title)"
    }
  }

  private func sourceDescription(for version: AppVersion) -> String {
    "\(version.specification.title) · \(version.specification.presentation.kind.title)"
  }

  private func versionReference(for version: AppVersion) -> String {
    switch version {
    case .imported:
      return "Imported · \(shortRevision(for: version))"
    case .accepted(let launch):
      guard
        let item = model.workItems.first(where: {
          $0.id == launch.candidate.workItemID
        })
      else {
        return "accepted revision \(shortRevision(for: version))"
      }
      return "\(item.key) · \(shortRevision(for: version))"
    }
  }

  private func shortRevision(for version: AppVersion) -> String {
    String(version.revisionSHA.prefix(8))
  }

  private func openActionTitle(for version: AppVersion) -> String {
    if openingVersionID == version.id || selectedSessionIsOpening {
      return "Opening \(versionReference(for: version))"
    }
    switch model.currentAppVersionSession(id: version.id)?.status {
    case .ready:
      return "Show \(versionReference(for: version))"
    case .failed:
      return "Retry \(versionReference(for: version))"
    default:
      return "Open \(versionReference(for: version))"
    }
  }

  private func openActionHelp(for version: AppVersion) -> String {
    if activeVersion?.id != nil && activeVersion?.id != version.id {
      return "Stop the running version and open \(versionReference(for: version))"
    }
    return openActionTitle(for: version)
  }

  private func selectLatestVersionIfNeeded() {
    guard
      selectedVersionID == nil || !appVersions.contains(where: { $0.id == selectedVersionID })
    else { return }
    selectedVersionID = appVersions.first?.id
  }

  private func openSelectedVersion() {
    guard !actionIsRunning, let selectedVersion else { return }
    openingVersionID = selectedVersion.id
    Task {
      _ = await model.openAppVersion(id: selectedVersion.id)
      openingVersionID = nil
    }
  }

  private func stopActiveVersion() {
    guard !actionIsRunning, let activeVersion else { return }
    isStopping = true
    Task {
      await model.stopAppVersion(id: activeVersion.id)
      isStopping = false
    }
  }
}
