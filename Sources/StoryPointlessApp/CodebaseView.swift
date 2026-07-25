import StoryPointlessCore
import SwiftUI

struct CodebaseView: View {
  @EnvironmentObject private var model: AppModel
  let onOpenTicket: (WorkItem) -> Void

  @State private var snapshot: GitRepositorySnapshot?
  @State private var selectedBranchName: String?
  @State private var selectedBranchDetail: GitBranchDetail?
  @State private var selectedCommitSHA: String?
  @State private var selectedCommitDetail: GitCommitDetail?
  @State private var selectedFilePath: String?
  @State private var isRefreshing = false
  @State private var isLoadingCommit = false
  @State private var isLoadingBranch = false
  @State private var errorMessage: String?
  @State private var detailErrorMessage: String?

  private var commits: [GitCommitSummary] {
    snapshot?.commits ?? []
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if snapshot != nil {
        VStack(spacing: 0) {
          GeometryReader { geometry in
            let dividerWidth: CGFloat = 2
            let availableWidth = max(geometry.size.width - dividerWidth, 1)
            let desiredCommitWidth = min(max(availableWidth * 0.20, 220), 270)
            let desiredFileWidth = min(max(availableWidth * 0.14, 150), 195)
            let desiredSidebars = desiredCommitWidth + desiredFileWidth
            let sidebarScale = min(
              1,
              max(availableWidth - 360, 1) / desiredSidebars
            )
            let commitWidth = desiredCommitWidth * sidebarScale
            let fileWidth = desiredFileWidth * sidebarScale
            let detailWidth = max(
              availableWidth - commitWidth - fileWidth,
              1
            )

            HStack(spacing: 0) {
              commitTimeline
                .frame(width: commitWidth)
                .frame(maxHeight: .infinity)
                .clipped()
              Divider()
              fileNavigator
                .frame(width: fileWidth)
                .frame(maxHeight: .infinity)
                .clipped()
              Divider()
              commitDetail
                .frame(width: detailWidth)
                .frame(maxHeight: .infinity)
                .clipped()
            }
            .frame(
              width: geometry.size.width,
              height: geometry.size.height,
              alignment: .leading
            )
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let errorMessage {
        ContentUnavailableView(
          "Codebase unavailable",
          systemImage: "exclamationmark.triangle",
          description: Text(errorMessage)
        )
      } else {
        ProgressView("Reading the product workspace…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: model.selectedProductID) {
      await refresh(selectInitialCommit: true)
    }
    .task(id: selectedCommitSHA) {
      await loadSelectedCommit()
    }
    .task(id: selectedBranchName) {
      await loadSelectedBranch()
    }
    .task(id: model.codebaseFocusWorkItemID) {
      guard let workItemID = model.codebaseFocusWorkItemID else { return }
      for _ in 0..<30 where snapshot == nil {
        try? await Task.sleep(for: .milliseconds(100))
      }
      if snapshot == nil {
        await refresh(selectInitialCommit: false)
      }
      await focusChanges(for: workItemID)
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Codebase")
          .font(.largeTitle.bold())
        Text("Accepted history, in-flight work, and the exact changes behind each commit.")
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 20)
  }

  private var commitTimeline: some View {
    VStack(spacing: 0) {
      if commits.isEmpty {
        ContentUnavailableView(
          "No commits",
          systemImage: "point.3.connected.trianglepath.dotted",
          description: Text("The product repository has no commits.")
        )
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(commits) { commit in
              Button {
                selectedBranchName = nil
                selectedCommitSHA = commit.sha
              } label: {
                CodebaseCommitRow(
                  commit: commit,
                  subject: displaySubject(for: commit),
                  authorName: displayAuthor(for: commit),
                  authorProfile: authorProfile(for: commit),
                  ticket: ticket(for: commit),
                  isSelected: selectedCommitSHA == commit.sha
                )
              }
              .buttonStyle(.plain)
              Divider().padding(.leading, 18)
            }
          }
        }
      }
    }
  }

  private var activeDetailFiles: [GitChangedFile] {
    if selectedCommitSHA != nil {
      return selectedCommitDetail?.files ?? []
    }
    if selectedBranchName != nil {
      return selectedBranchDetail?.files ?? []
    }
    return []
  }

  private var fileNavigator: some View {
    CodebaseFileNavigator(
      files: activeDetailFiles,
      isLoading: isLoadingCommit || isLoadingBranch,
      errorMessage: detailErrorMessage,
      selectedPath: $selectedFilePath
    )
  }

  @ViewBuilder
  private var commitDetail: some View {
    if selectedCommitSHA != nil {
      if let detail = selectedCommitDetail {
        CodebaseCommitDetailView(
          detail: detail,
          subject: displaySubject(for: detail.commit),
          authorName: displayAuthor(for: detail.commit),
          authorProfile: authorProfile(for: detail.commit),
          ticket: ticket(for: detail.commit),
          selectedFilePath: selectedFilePath,
          isLoading: isLoadingCommit,
          onOpenTicket: onOpenTicket
        )
      } else {
        selectionLoadingState(title: "Loading commit…")
      }
    } else if selectedBranchName != nil {
      if let detail = selectedBranchDetail {
        CodebaseBranchDetailView(
          detail: detail,
          profile: profile(for: detail.branch),
          item: item(for: detail.branch),
          selectedFilePath: selectedFilePath,
          isLoading: isLoadingBranch
        )
      } else {
        selectionLoadingState(title: "Loading branch changes…")
      }
    } else {
      ContentUnavailableView(
        "Select a commit",
        systemImage: "doc.text.magnifyingglass",
        description: Text("Choose a commit to inspect its files and coloured diff.")
      )
    }
  }

  @ViewBuilder
  private func selectionLoadingState(title: String) -> some View {
    if let detailErrorMessage {
      ContentUnavailableView(
        "Changes unavailable",
        systemImage: "exclamationmark.triangle",
        description: Text(detailErrorMessage)
      )
    } else {
      ProgressView(title)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func refresh(selectInitialCommit: Bool) async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    do {
      let newSnapshot = try await model.codebaseSnapshot()
      snapshot = newSnapshot
      errorMessage = nil
      if
        let selectedBranchName,
        !newSnapshot.branches.contains(where: { $0.name == selectedBranchName })
      {
        self.selectedBranchName = nil
        selectedBranchDetail = nil
      }
      if (selectInitialCommit || selectedCommitSHA == nil) && selectedBranchName == nil {
        selectedCommitSHA = newSnapshot.commits.first?.sha
      } else if
        let selectedCommitSHA,
        !newSnapshot.commits.contains(where: { $0.sha == selectedCommitSHA })
      {
        self.selectedCommitSHA = newSnapshot.commits.first?.sha
      }
      if selectedBranchName != nil {
        await loadSelectedBranch()
      }
    } catch {
      if snapshot == nil {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func loadSelectedCommit() async {
    guard let requestedSHA = selectedCommitSHA else {
      isLoadingCommit = false
      return
    }
    isLoadingCommit = true
    detailErrorMessage = nil
    defer {
      if selectedCommitSHA == requestedSHA {
        isLoadingCommit = false
      }
    }
    do {
      let detail = try await model.codebaseCommitDetail(sha: requestedSHA)
      guard selectedCommitSHA == requestedSHA else { return }
      if let selectedFilePath,
        !detail.files.contains(where: { $0.path == selectedFilePath })
      {
        self.selectedFilePath = nil
      }
      selectedCommitDetail = detail
    } catch {
      guard selectedCommitSHA == requestedSHA else { return }
      detailErrorMessage = error.localizedDescription
    }
  }

  private func loadSelectedBranch() async {
    guard
      let selectedBranchName,
      let branch = snapshot?.branches.first(where: { $0.name == selectedBranchName })
    else {
      isLoadingBranch = false
      return
    }
    let requestedBranchName = selectedBranchName
    isLoadingBranch = true
    detailErrorMessage = nil
    defer {
      if selectedBranchName == requestedBranchName {
        isLoadingBranch = false
      }
    }
    do {
      let detail = try await model.codebaseBranchDetail(branch: branch)
      guard selectedBranchName == requestedBranchName else { return }
      if let selectedFilePath,
        !detail.files.contains(where: { $0.path == selectedFilePath })
      {
        self.selectedFilePath = nil
      }
      selectedBranchDetail = detail
    } catch {
      guard selectedBranchName == requestedBranchName else { return }
      detailErrorMessage = error.localizedDescription
    }
  }

  private func focusChanges(for workItemID: UUID) async {
    defer {
      model.consumeCodebaseFocus(workItemID: workItemID)
    }
    guard let snapshot else { return }
    let candidate = model.candidateRevisions
      .filter { $0.workItemID == workItemID }
      .max(by: { $0.version < $1.version })
    guard let candidate else { return }

    if let branch = snapshot.branches.first(where: { $0.name == candidate.branchName }) {
      selectedCommitSHA = nil
      selectedBranchName = branch.name
      await loadSelectedBranch()
      return
    }

    let candidateSHAs = [candidate.integratedSHA, candidate.headSHA].compactMap { $0 }
    guard
      let commit = snapshot.commits.first(where: { candidateSHAs.contains($0.sha) })
    else { return }
    selectedBranchName = nil
    selectedCommitSHA = commit.sha
    await loadSelectedCommit()
  }

  private func run(for branch: GitBranchSnapshot) -> AgentRun? {
    if let path = branch.worktreePath {
      return model.runs
        .filter { $0.worktreePath == path }
        .max { $0.updatedAt < $1.updatedAt }
    }
    let candidate = model.candidateRevisions
      .filter { $0.branchName == branch.name }
      .max(by: { $0.version < $1.version })
    guard let candidate else { return nil }
    return model.runs.first { $0.id == candidate.implementationRunID }
  }

  private func item(for branch: GitBranchSnapshot) -> WorkItem? {
    guard let run = run(for: branch) else { return nil }
    return model.workItems.first { $0.id == run.workItemID }
  }

  private func profile(for branch: GitBranchSnapshot) -> AgentProfile? {
    guard let run = run(for: branch) else { return nil }
    return model.profiles.first { $0.id == run.profileID }
  }

  private func candidate(for commit: GitCommitSummary) -> CandidateRevision? {
    model.candidateRevisions
      .filter {
        $0.headSHA == commit.sha || $0.integratedSHA == commit.sha
          || commit.parentSHAs.contains($0.headSHA)
      }
      .max { $0.version < $1.version }
  }

  private func ticket(for commit: GitCommitSummary) -> WorkItem? {
    if let candidate = candidate(for: commit) {
      return model.workItems.first { $0.id == candidate.workItemID }
    }
    return model.workItems.first { item in
      commit.subject.hasPrefix("\(item.key):")
        || commit.subject.hasPrefix("\(item.key) ")
    }
  }

  private func authorProfile(for commit: GitCommitSummary) -> AgentProfile? {
    if commit.authorName != "StoryPointless" {
      return model.profiles.first { $0.name == commit.authorName }
    }
    if
      let candidate = candidate(for: commit),
      let run = model.runs.first(where: { $0.id == candidate.implementationRunID })
    {
      return model.profiles.first { $0.id == run.profileID }
    }
    guard let workItem = ticket(for: commit) else { return nil }
    let deliveryRun = model.runs
      .filter { $0.workItemID == workItem.id }
      .filter { run in
        model.profiles.first { $0.id == run.profileID }?.role != .lead
      }
      .min { $0.createdAt < $1.createdAt }
    guard let deliveryRun else { return nil }
    return model.profiles.first { $0.id == deliveryRun.profileID }
  }

  private func displayAuthor(for commit: GitCommitSummary) -> String {
    authorProfile(for: commit)?.name ?? commit.authorName
  }

  private func displaySubject(for commit: GitCommitSummary) -> String {
    guard let ticket = ticket(for: commit) else { return commit.subject }
    let normalized = commit.subject.lowercased()
    if normalized.contains("candidate v") {
      return "\(ticket.key): \(ticket.title)"
    }
    if normalized.hasPrefix("merge commit ") {
      return "Integrate \(ticket.key): \(ticket.title)"
    }
    return commit.subject
  }
}

private struct CodebaseBranchCard: View {
  let branch: GitBranchSnapshot
  let run: AgentRun?
  let profile: AgentProfile?
  let item: WorkItem?
  let isSelected: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 7) {
        Circle()
          .fill(profile.map { roleTint($0.role) } ?? .secondary)
          .frame(width: 8, height: 8)
        Text(item?.key ?? branch.name.replacingOccurrences(of: "ticket/", with: ""))
          .font(.caption.monospaced().weight(.semibold))
        Text(runStatus)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(runTint)
        Spacer()
      }

      if let item {
        Text(item.title)
          .font(.callout.weight(.semibold))
          .lineLimit(1)
      } else {
        Text(branch.lastCommitSubject)
          .font(.callout.weight(.semibold))
          .lineLimit(1)
      }

      HStack(spacing: 6) {
        if let profile {
          Label(profile.name, systemImage: roleSymbol(profile.role))
            .foregroundStyle(roleTint(profile.role))
        } else {
          Label("StoryPointless", systemImage: "gearshape.2")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text("\(branch.aheadOfTrunk) ahead")
        if branch.dirtyFileCount > 0 {
          Text("· \(branch.dirtyFileCount) changed")
        }
      }
      .font(.caption2)

    }
    .padding(9)
    .frame(width: 250, height: 82, alignment: .leading)
    .background(.background, in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(
          isSelected
            ? Color.accentColor
            : Color(nsColor: .separatorColor).opacity(0.65),
          lineWidth: isSelected ? 1.5 : 1
        )
    }
    .contentShape(RoundedRectangle(cornerRadius: 10))
  }

  private var runStatus: String {
    guard let run else { return "Branch open" }
    switch run.status {
    case .queued: return "Queued"
    case .running: return "Working"
    case .awaitingOwner: return "Needs your input"
    case .interrupted: return "Interrupted"
    case .completed: return "Candidate ready"
    case .failed: return "Failed"
    case .cancelled: return "Cancelled"
    }
  }

  private var runTint: Color {
    guard let run else { return .secondary }
    switch run.status {
    case .running: return .blue
    case .awaitingOwner: return .orange
    case .failed: return .red
    case .completed: return .green
    default: return .secondary
    }
  }
}

private struct CodebaseCommitRow: View {
  let commit: GitCommitSummary
  let subject: String
  let authorName: String
  let authorProfile: AgentProfile?
  let ticket: WorkItem?
  let isSelected: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: authorProfile.map { roleSymbol($0.role) } ?? "point.3.connected.trianglepath.dotted")
        .foregroundStyle(authorProfile.map { roleTint($0.role) } ?? .secondary)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 5) {
        Text(subject)
          .font(.callout.weight(.medium))
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 6) {
          Text(commit.shortSHA)
            .font(.caption2.monospaced())
          if let ticket {
            Text(ticket.key)
              .font(.caption2.monospaced().weight(.semibold))
              .foregroundStyle(.blue)
          }
          Text(authorName)
          Text("·")
          Text(commit.committedAt.formatted(date: .numeric, time: .omitted))
            .help(
              commit.committedAt.formatted(
                date: .numeric,
                time: .shortened
              )
            )
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        if !commit.references.isEmpty {
          Text(commit.references.joined(separator: " · "))
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .background(isSelected ? Color.accentColor.opacity(0.11) : .clear)
    .contentShape(Rectangle())
  }
}

private struct CodebaseFileNavigator: View {
  let files: [GitChangedFile]
  let isLoading: Bool
  let errorMessage: String?
  @Binding var selectedPath: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Files")
          .font(.headline)
        Text(files.count.formatted())
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(.quaternary, in: Capsule())
        Spacer()
      }
      .padding(.horizontal, 13)
      .frame(height: 50)

      Divider()

      if files.isEmpty && isLoading {
        Text("Loading files…")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if files.isEmpty, let errorMessage {
        ContentUnavailableView(
          "Files unavailable",
          systemImage: "exclamationmark.triangle",
          description: Text(errorMessage)
        )
      } else if files.isEmpty {
        ContentUnavailableView(
          "No files",
          systemImage: "doc",
          description: Text("Choose a commit or branch with file changes.")
        )
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            Button {
              selectedPath = nil
            } label: {
              Label("All changes", systemImage: "square.stack.3d.up")
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                  selectedPath == nil ? Color.accentColor.opacity(0.12) : .clear,
                  in: RoundedRectangle(cornerRadius: 7)
                )
            }
            .buttonStyle(.plain)

            ForEach(CodebaseFileTreeNode.roots(for: files)) { node in
              CodebaseFileTreeNodeView(
                node: node,
                selectedPath: $selectedPath,
                depth: 0
              )
            }
          }
          .padding(8)
        }
      }
    }
    .background(.quaternary.opacity(0.08))
  }
}

private struct CodebaseFileTreeNode: Identifiable {
  let id: String
  let name: String
  let file: GitChangedFile?
  let children: [Self]

  static func roots(for files: [GitChangedFile]) -> [Self] {
    nodes(for: files, depth: 0, prefix: "")
  }

  private static func nodes(
    for files: [GitChangedFile],
    depth: Int,
    prefix: String
  ) -> [Self] {
    let grouped = Dictionary(grouping: files) { file in
      let components = displayPath(for: file).split(separator: "/").map(String.init)
      return depth < components.count ? components[depth] : displayPath(for: file)
    }
    return grouped.keys.sorted().compactMap { component in
      guard let groupedFiles = grouped[component] else { return nil }
      let nodePath = prefix.isEmpty ? component : "\(prefix)/\(component)"
      if
        groupedFiles.count == 1,
        displayPath(for: groupedFiles[0]).split(separator: "/").count == depth + 1
      {
        let file = groupedFiles[0]
        return Self(
          id: "file:\(file.path)",
          name: component,
          file: file,
          children: []
        )
      }
      return Self(
        id: "directory:\(nodePath)",
        name: component,
        file: nil,
        children: nodes(
          for: groupedFiles,
          depth: depth + 1,
          prefix: nodePath
        )
      )
    }
  }

  private static func displayPath(for file: GitChangedFile) -> String {
    file.path.components(separatedBy: " → ").last ?? file.path
  }
}

private struct CodebaseFileTreeNodeView: View {
  let node: CodebaseFileTreeNode
  @Binding var selectedPath: String?
  let depth: Int
  @State private var isExpanded = true

  var body: some View {
    if let file = node.file {
      Button {
        selectedPath = file.path
      } label: {
        HStack(spacing: 7) {
          Image(systemName: fileSymbol(file.status))
            .frame(width: 15)
            .foregroundStyle(fileTint(file.status))
          Text(node.name)
            .lineLimit(1)
          Spacer()
        }
        .font(.caption)
        .padding(.leading, CGFloat(depth) * 13)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
          selectedPath == file.path ? Color.accentColor.opacity(0.12) : .clear,
          in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(file.path)
    } else {
      DisclosureGroup(isExpanded: $isExpanded) {
        ForEach(node.children) { child in
          CodebaseFileTreeNodeView(
            node: child,
            selectedPath: $selectedPath,
            depth: depth + 1
          )
        }
      } label: {
        Label(node.name, systemImage: isExpanded ? "folder.fill" : "folder")
          .font(.caption.weight(.medium))
          .lineLimit(1)
          .padding(.leading, CGFloat(depth) * 13)
          .padding(.vertical, 5)
      }
      .disclosureGroupStyle(.automatic)
    }
  }

  private func fileSymbol(_ status: String) -> String {
    switch status.first {
    case "A": "doc.badge.plus"
    case "D": "doc.badge.minus"
    case "R": "arrow.right.doc.on.clipboard"
    default: "doc.text"
    }
  }

  private func fileTint(_ status: String) -> Color {
    switch status.first {
    case "A": .green
    case "D": .red
    case "R": .blue
    default: .secondary
    }
  }
}

private enum CodebaseDiffSelection {
  static func diff(_ unifiedDiff: String, for filePath: String?) -> String {
    guard let filePath else { return unifiedDiff }
    let candidatePaths = filePath.components(separatedBy: " → ")
    var matchingSections: [String] = []
    var currentSection: [String] = []

    func sectionMatches(_ section: [String]) -> Bool {
      guard let header = section.first else { return false }
      return candidatePaths.contains { path in
        header.contains("a/\(path)") || header.contains("b/\(path)")
      }
    }

    for line in unifiedDiff.components(separatedBy: "\n") {
      if line.hasPrefix("diff --git "), !currentSection.isEmpty {
        if sectionMatches(currentSection) {
          matchingSections.append(currentSection.joined(separator: "\n"))
        }
        currentSection.removeAll(keepingCapacity: true)
      }
      currentSection.append(line)
    }
    if sectionMatches(currentSection) {
      matchingSections.append(currentSection.joined(separator: "\n"))
    }
    return matchingSections.joined(separator: "\n")
  }
}

private struct CodebaseCommitDetailView: View {
  let detail: GitCommitDetail
  let subject: String
  let authorName: String
  let authorProfile: AgentProfile?
  let ticket: WorkItem?
  let selectedFilePath: String?
  let isLoading: Bool
  let onOpenTicket: (WorkItem) -> Void

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 5) {
            Text(subject)
              .font(.title2.bold())
              .textSelection(.enabled)
            HStack(spacing: 7) {
              Label(
                authorName,
                systemImage: authorProfile.map { roleSymbol($0.role) } ?? "gearshape.2"
              )
              .foregroundStyle(authorProfile.map { roleTint($0.role) } ?? .secondary)
              Text(
                detail.commit.committedAt.formatted(
                  date: .numeric,
                  time: .shortened
                )
              )
                .foregroundStyle(.secondary)
              Text("·")
                .foregroundStyle(.tertiary)
              Text(detail.commit.shortSHA)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            .font(.caption)
          }
          Spacer()
          if let ticket {
            Button {
              onOpenTicket(ticket)
            } label: {
              Label("Open \(ticket.key)", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
            .help("Open \(ticket.key) in the Sprint Board")
          }
        }

      }
      .padding(18)

      Divider()

      CodebaseDiffViewer(
        unifiedDiff: CodebaseDiffSelection.diff(
          detail.unifiedDiff,
          for: selectedFilePath
        ),
        isTruncated: detail.isDiffTruncated,
        isLoading: isLoading,
        emptyDescription: selectedFilePath == nil
          ? "This commit records repository state without a patch."
          : "This file has no textual patch."
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .clipped()
  }
}

private struct CodebaseBranchDetailView: View {
  let detail: GitBranchDetail
  let profile: AgentProfile?
  let item: WorkItem?
  let selectedFilePath: String?
  let isLoading: Bool

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 5) {
            Text(item.map { "\($0.key) · \($0.title)" } ?? detail.branch.name)
              .font(.title2.bold())
              .textSelection(.enabled)
            HStack(spacing: 7) {
              Label(
                profile?.name ?? "Active ticket branch",
                systemImage: profile.map { roleSymbol($0.role) }
                  ?? "point.3.connected.trianglepath.dotted"
              )
              .foregroundStyle(profile.map { roleTint($0.role) } ?? .secondary)
              Text("\(detail.branch.aheadOfTrunk) commits ahead")
              if detail.branch.dirtyFileCount > 0 {
                Text("· \(detail.branch.dirtyFileCount) uncommitted")
              }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer()
          Text(detail.branch.name)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }

      }
      .padding(18)

      Divider()

      CodebaseDiffViewer(
        unifiedDiff: CodebaseDiffSelection.diff(
          detail.unifiedDiff,
          for: selectedFilePath
        ),
        isTruncated: detail.isDiffTruncated,
        isLoading: isLoading,
        emptyDescription: selectedFilePath == nil
          ? "This branch has no changes relative to its trunk base."
          : "This file has no textual patch."
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .clipped()
  }
}

private enum CodebaseDiffLayout: String, CaseIterable, Identifiable {
  case automatic
  case unified
  case split

  var id: String { rawValue }

  var title: String {
    switch self {
    case .automatic: "Auto"
    case .unified: "Unified"
    case .split: "Side by side"
    }
  }
}

private struct CodebaseDiffViewer: View {
  let unifiedDiff: String
  let isTruncated: Bool
  let isLoading: Bool
  let emptyDescription: String
  @State private var layout = CodebaseDiffLayout.automatic

  var body: some View {
    if unifiedDiff.isEmpty {
      ContentUnavailableView(
        "No file changes",
        systemImage: "doc",
        description: Text(emptyDescription)
      )
    } else {
      VStack(spacing: 0) {
        HStack {
          Text("Changes")
            .font(.headline)
          if isLoading {
            ProgressView()
              .controlSize(.small)
              .help("Loading the selected revision")
          }
          Spacer()
          Picker("Diff layout", selection: $layout) {
            ForEach(CodebaseDiffLayout.allCases) { option in
              Text(option.title).tag(option)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(width: 260)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)

        Divider()

        GeometryReader { geometry in
          let effectiveLayout: CodebaseDiffLayout =
            layout == .automatic
              ? (geometry.size.width >= 900 ? .split : .unified)
              : layout
          if effectiveLayout == .split {
            splitDiff(
              minimumWidth: geometry.size.width,
              minimumHeight: geometry.size.height
            )
          } else {
            unifiedDiffView(
              minimumWidth: geometry.size.width,
              minimumHeight: geometry.size.height
            )
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .background(Color(nsColor: .textBackgroundColor))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
    }
  }

  private func unifiedDiffView(
    minimumWidth: CGFloat,
    minimumHeight: CGFloat
  ) -> some View {
    let lines = unifiedDiff.components(separatedBy: "\n")
    return ScrollView(.vertical) {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          Text(line.isEmpty ? " " : line)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(diffForeground(line))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(diffBackground(line))
        }
        truncationNotice
      }
      .frame(width: minimumWidth, alignment: .leading)
      .frame(minHeight: minimumHeight, alignment: .topLeading)
      .textSelection(.enabled)
    }
    .defaultScrollAnchor(.top)
    .scrollIndicators(.visible)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipped()
  }

  private func splitDiff(
    minimumWidth: CGFloat,
    minimumHeight: CGFloat
  ) -> some View {
    let rows = SideBySideDiffRow.rows(from: unifiedDiff)
    let dividerWidth: CGFloat = 1
    let paneWidth = max((minimumWidth - dividerWidth) / 2, 0)
    return ScrollView(.vertical) {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(rows) { row in
          if let metadata = row.metadata {
            Text(metadata.isEmpty ? " " : metadata)
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(diffForeground(metadata))
              .fixedSize(horizontal: false, vertical: true)
              .padding(.horizontal, 10)
              .padding(.vertical, 2)
              .frame(width: minimumWidth, alignment: .leading)
              .background(diffBackground(metadata))
          } else {
            HStack(spacing: 0) {
              splitCell(
                row.left,
                kind: row.leftKind,
                width: paneWidth
              )
              Divider()
              splitCell(
                row.right,
                kind: row.rightKind,
                width: paneWidth
              )
            }
            .fixedSize(horizontal: false, vertical: true)
          }
        }
        truncationNotice
      }
      .frame(width: minimumWidth, alignment: .leading)
      .frame(minHeight: minimumHeight, alignment: .topLeading)
      .textSelection(.enabled)
    }
    .defaultScrollAnchor(.top)
    .scrollIndicators(.visible)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipped()
  }

  private func splitCell(
    _ text: String?,
    kind: SideBySideDiffRow.Kind,
    width: CGFloat
  ) -> some View {
    Text(text?.isEmpty == false ? text! : " ")
      .font(.system(size: 11, design: .monospaced))
      .foregroundStyle(kind == .removed ? .red : kind == .added ? .green : .primary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 10)
      .padding(.vertical, 1)
      .frame(width: width, alignment: .topLeading)
      .frame(maxHeight: .infinity, alignment: .topLeading)
      .background(
        kind == .removed
          ? Color.red.opacity(0.08)
          : kind == .added ? Color.green.opacity(0.08) : .clear
      )
  }

  @ViewBuilder
  private var truncationNotice: some View {
    if isTruncated {
      Text("Diff truncated for performance.")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.orange)
        .padding(12)
    }
  }

  private func diffForeground(_ line: String) -> Color {
    if line.hasPrefix("@@") { return .purple }
    if line.hasPrefix("diff --git") || line.hasPrefix("index ") { return .secondary }
    if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
    if line.hasPrefix("+") { return .green }
    if line.hasPrefix("-") { return .red }
    return .primary
  }

  private func diffBackground(_ line: String) -> Color {
    if line.hasPrefix("+"), !line.hasPrefix("+++") { return .green.opacity(0.08) }
    if line.hasPrefix("-"), !line.hasPrefix("---") { return .red.opacity(0.08) }
    if line.hasPrefix("@@") { return .purple.opacity(0.07) }
    return .clear
  }
}

private struct SideBySideDiffRow: Identifiable {
  enum Kind {
    case context
    case added
    case removed
    case empty
  }

  let id = UUID()
  let metadata: String?
  let left: String?
  let right: String?
  let leftKind: Kind
  let rightKind: Kind

  static func rows(from diff: String) -> [Self] {
    var rows: [Self] = []
    var removals: [String] = []
    var additions: [String] = []

    func flushChanges() {
      let count = max(removals.count, additions.count)
      guard count > 0 else { return }
      for index in 0..<count {
        rows.append(
          Self(
            metadata: nil,
            left: index < removals.count ? removals[index] : nil,
            right: index < additions.count ? additions[index] : nil,
            leftKind: index < removals.count ? .removed : .empty,
            rightKind: index < additions.count ? .added : .empty
          )
        )
      }
      removals.removeAll(keepingCapacity: true)
      additions.removeAll(keepingCapacity: true)
    }

    for line in diff.components(separatedBy: "\n") {
      if line.hasPrefix("-"), !line.hasPrefix("---") {
        removals.append(String(line.dropFirst()))
      } else if line.hasPrefix("+"), !line.hasPrefix("+++") {
        additions.append(String(line.dropFirst()))
      } else {
        flushChanges()
        if line.hasPrefix(" ") {
          let content = String(line.dropFirst())
          rows.append(
            Self(
              metadata: nil,
              left: content,
              right: content,
              leftKind: .context,
              rightKind: .context
            )
          )
        } else {
          rows.append(
            Self(
              metadata: line,
              left: nil,
              right: nil,
              leftKind: .empty,
              rightKind: .empty
            )
          )
        }
      }
    }
    flushChanges()
    return rows
  }
}

private func roleTint(_ role: AgentRole) -> Color {
  switch role {
  case .businessAnalyst: .purple
  case .uxDesigner: .pink
  case .lead: .orange
  case .implementer: .blue
  case .frontendEngineer: .cyan
  case .backendEngineer: .indigo
  case .reviewer: .green
  case .qualityAssurance: .mint
  case .knowledgeCurator: .brown
  }
}

private func roleSymbol(_ role: AgentRole) -> String {
  switch role {
  case .businessAnalyst: "text.magnifyingglass"
  case .uxDesigner: "paintbrush.pointed"
  case .lead: "point.3.connected.trianglepath.dotted"
  case .implementer: "hammer"
  case .frontendEngineer: "macwindow"
  case .backendEngineer: "server.rack"
  case .reviewer: "checkmark.seal"
  case .qualityAssurance: "checkmark.diamond"
  case .knowledgeCurator: "books.vertical"
  }
}
