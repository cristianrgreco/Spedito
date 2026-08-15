import Foundation
import SpeditoCore
import SwiftUI

private struct CodebaseFocusTaskID: Hashable {
  let productID: UUID?
  let workItemID: UUID?
  let trunkSHA: String?
}

struct CodebaseView: View {
  @EnvironmentObject private var model: AppModel
  let onOpenTicket: (WorkItem) -> Void

  @State private var snapshot: GitRepositorySnapshot?
  @State private var selectedBranchName: String?
  @State private var selectedBranchDetail: GitBranchDetail?
  @State private var selectedCommitSHA: String?
  @State private var selectedCommitDetail: GitCommitDetail?
  @State private var selectedFilePath: String?
  @State private var historyScope: CodebaseHistoryScope = .trunk
  @State private var isRefreshing = false
  @State private var isLoadingCommit = false
  @State private var isLoadingBranch = false
  @State private var errorMessage: String?
  @State private var detailErrorMessage: String?

  private var focusTaskID: CodebaseFocusTaskID {
    CodebaseFocusTaskID(
      productID: model.selectedProductID,
      workItemID: model.codebaseFocusWorkItemID,
      trunkSHA: snapshot?.trunkSHA
    )
  }

  private var commits: [GitCommitSummary] {
    guard let snapshot else { return [] }
    return CodebaseHistoryFilter.commits(
      in: snapshot,
      scope: historyScope,
      revisions: ticketRevisions,
      branchWorkItemIDs: branchWorkItemIDs
    )
  }

  private var ticketRevisions: [CodebaseTicketRevision] {
    model.candidateRevisions
      .filter(\.deliveryKind.changesRepository)
      .map(CodebaseTicketRevision.init)
  }

  private var branchWorkItemIDs: [String: UUID] {
    guard let snapshot else { return [:] }
    return Dictionary(
      uniqueKeysWithValues: snapshot.branches.compactMap { branch in
        item(for: branch).map { (branch.name, $0.id) }
      }
    )
  }

  private var historyTickets: [WorkItem] {
    guard let snapshot else { return [] }
    let revisionWorkItemIDs = Set(ticketRevisions.map(\.workItemID))
    let branchIDs = Set(branchWorkItemIDs.values)
    let relevantIDs = revisionWorkItemIDs.union(branchIDs)
    return model.workItems
      .filter { item in
        relevantIDs.contains(item.id)
          && (branchIDs.contains(item.id)
            || !CodebaseHistoryFilter.commits(
              in: snapshot,
              scope: .ticket(item.id),
              revisions: ticketRevisions,
              branchWorkItemIDs: branchWorkItemIDs
            ).isEmpty)
      }
      .sorted { lhs, rhs in
        lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
      }
  }

  private var remoteRepositoryObservedLocalSHA: String? {
    model.selectedRemoteRepositorySnapshot?.repositoryState.observation?.localSHA
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
      historyScope = .trunk
      snapshot = nil
      selectedBranchName = nil
      selectedBranchDetail = nil
      selectedCommitSHA = nil
      selectedCommitDetail = nil
      selectedFilePath = nil
      await refresh(selectInitialCommit: true)
    }
    .onChange(of: historyScope) { _, _ in
      selectInitialCommitForScope()
    }
    .task(id: selectedCommitSHA) {
      await loadSelectedCommit()
    }
    .task(id: selectedBranchName) {
      await loadSelectedBranch()
    }
    .task(id: remoteRepositoryObservedLocalSHA) {
      guard snapshot != nil else { return }
      await refresh(selectInitialCommit: false)
    }
    .task(id: focusTaskID) {
      guard
        let workItemID = focusTaskID.workItemID,
        focusTaskID.productID == model.selectedProductID,
        snapshot != nil
      else { return }
      await focusChanges(for: workItemID)
    }
  }

  private var header: some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Codebase")
          .font(.largeTitle.bold())
        Text("Choose the accepted product or a ticket to inspect its changes.")
          .foregroundStyle(.secondary)
      }
      Spacer()
      Picker("Codebase history", selection: $historyScope) {
        CodebaseHistoryPickerLabel(option: .trunk)
          .tag(CodebaseHistoryScope.trunk)
        ForEach(historyTickets) { ticket in
          let scope = CodebaseHistoryScope.ticket(ticket.id)
          CodebaseHistoryPickerLabel(option: historyOption(for: ticket))
            .tag(scope)
        }
        CodebaseHistoryPickerLabel(option: .allActivity)
          .tag(CodebaseHistoryScope.allActivity)
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .fixedSize()
    }
    .workspaceHeaderLayout()
  }

  private var commitTimeline: some View {
    VStack(spacing: 0) {
      if commits.isEmpty {
        ContentUnavailableView(
          emptyHistoryTitle,
          systemImage: "point.3.connected.trianglepath.dotted",
          description: Text(emptyHistoryDescription)
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
                  presentation: commitPresentation(for: commit),
                  showsState: historyScope != .trunk,
                  isSelected: selectedCommitSHA == commit.sha
                )
              }
              .buttonStyle(.plain)
              Divider()
            }
          }
        }
      }
    }
  }

  private var emptyHistoryTitle: String {
    switch historyScope {
    case .trunk: "No accepted changes"
    case .ticket: "No ticket changes"
    case .allActivity: "No activity"
    }
  }

  private func historyOption(for ticket: WorkItem) -> CodebaseHistoryOption {
    CodebaseHistoryOption(
      title: "\(ticket.key) — \(CodebaseTicketStateTitle.title(for: ticket.state))",
      symbol: "ticket.fill"
    )
  }

  private var emptyHistoryDescription: String {
    switch historyScope {
    case .trunk: "The accepted product has no recorded commits."
    case .ticket: "This ticket has not recorded a codebase change yet."
    case .allActivity: "The product repository has no commits."
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
      if let selectedBranchName,
        !newSnapshot.branches.contains(where: { $0.name == selectedBranchName })
      {
        self.selectedBranchName = nil
        selectedBranchDetail = nil
      }
      if case .ticket(let workItemID) = historyScope,
        !historyTickets.contains(where: { $0.id == workItemID })
      {
        historyScope = .trunk
      }
      if (selectInitialCommit || selectedCommitSHA == nil) && selectedBranchName == nil {
        selectedCommitSHA = commits.first?.sha
      } else if let selectedCommitSHA,
        !commits.contains(where: { $0.sha == selectedCommitSHA })
      {
        self.selectedCommitSHA = commits.first?.sha
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

  private func selectInitialCommitForScope() {
    selectedBranchName = nil
    selectedBranchDetail = nil
    selectedFilePath = nil
    selectedCommitDetail = nil
    if commits.isEmpty,
      case .ticket(let workItemID) = historyScope,
      let branchName = branchWorkItemIDs.first(where: { $0.value == workItemID })?.key
    {
      selectedCommitSHA = nil
      selectedBranchName = branchName
    } else {
      selectedCommitSHA = commits.first?.sha
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
    guard snapshot != nil else { return }
    let candidate = model.candidateRevisions
      .filter { $0.workItemID == workItemID }
      .max(by: { $0.version < $1.version })
    guard let candidate else { return }

    historyScope = .ticket(workItemID)

    let candidateSHAs = [candidate.integratedSHA, candidate.headSHA].compactMap { $0 }
    guard
      let commit = commits.first(where: { candidateSHAs.contains($0.sha) })
        ?? commits.first
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
    guard
      let snapshot,
      let revision = CodebaseHistoryFilter.associatedRevision(
        with: commit,
        in: snapshot,
        revisions: ticketRevisions
      )
    else { return nil }
    return model.candidateRevisions.first { $0.id == revision.candidateID }
  }

  private func ticket(for commit: GitCommitSummary) -> WorkItem? {
    if let candidate = candidate(for: commit) {
      return model.workItems.first { $0.id == candidate.workItemID }
    }
    if let branch = snapshot?.branches.first(where: { $0.commitSHAs.contains(commit.sha) }),
      let workItemID = branchWorkItemIDs[branch.name]
    {
      return model.workItems.first { $0.id == workItemID }
    }
    return model.workItems.first { item in
      commit.subject.hasPrefix("\(item.key):")
        || commit.subject.hasPrefix("\(item.key) ")
    }
  }

  private func authorProfile(for commit: GitCommitSummary) -> AgentProfile? {
    if commit.authorName != "Spedito" {
      return model.profiles.first { $0.name == commit.authorName }
    }
    if let candidate = candidate(for: commit),
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

  private func commitPresentation(for commit: GitCommitSummary) -> CodebaseCommitPresentation {
    let revision = snapshot.flatMap {
      CodebaseHistoryFilter.associatedRevision(
        with: commit,
        in: $0,
        revisions: ticketRevisions
      )
    }
    return CodebaseCommitPresentationResolver.presentation(
      for: commit,
      revision: revision,
      hasTicket: ticket(for: commit) != nil
    )
  }

  private func displaySubject(for commit: GitCommitSummary) -> String {
    let normalized = commit.subject.lowercased()
    if normalized == "checkpoint before candidate integration" {
      return "Prepared product workspace for integration"
    }
    if normalized == "checkpoint product workspace" {
      return "Saved product workspace changes"
    }
    if normalized == "initialize product workspace" {
      return "Created product workspace"
    }
    guard let ticket = ticket(for: commit) else { return commit.subject }
    if normalized.contains("candidate v") {
      return "\(ticket.key): \(ticket.title)"
    }
    if normalized.hasPrefix("merge commit ") {
      return "Integrate \(ticket.key): \(ticket.title)"
    }
    return commit.subject
  }
}

private struct CodebaseHistoryOption {
  let title: String
  let symbol: String

  static let trunk = CodebaseHistoryOption(
    title: "Trunk — Accepted product",
    symbol: "checkmark.circle.fill"
  )
  static let allActivity = CodebaseHistoryOption(
    title: "All activity",
    symbol: "list.bullet.rectangle"
  )
}

private struct CodebaseHistoryPickerLabel: View {
  let option: CodebaseHistoryOption

  var body: some View {
    Label {
      Text("\u{00A0}\(option.title)")
    } icon: {
      Image(systemName: option.symbol)
    }
    .accessibilityLabel(option.title)
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
          Label("Spedito", systemImage: "gearshape.2")
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

enum CodebaseHistoryScope: Hashable {
  case trunk
  case ticket(UUID)
  case allActivity
}

struct CodebaseTicketRevision: Equatable {
  let candidateID: UUID
  let workItemID: UUID
  let version: Int
  let branchName: String
  let baseSHA: String
  let headSHA: String
  let integratedSHA: String?
  let status: CandidateRevisionStatus

  init(
    candidateID: UUID,
    workItemID: UUID,
    version: Int,
    branchName: String,
    baseSHA: String,
    headSHA: String,
    integratedSHA: String?,
    status: CandidateRevisionStatus
  ) {
    self.candidateID = candidateID
    self.workItemID = workItemID
    self.version = version
    self.branchName = branchName
    self.baseSHA = baseSHA
    self.headSHA = headSHA
    self.integratedSHA = integratedSHA
    self.status = status
  }

  init(_ candidate: CandidateRevision) {
    self.init(
      candidateID: candidate.id,
      workItemID: candidate.workItemID,
      version: candidate.version,
      branchName: candidate.branchName,
      baseSHA: candidate.baseSHA,
      headSHA: candidate.headSHA,
      integratedSHA: candidate.integratedSHA,
      status: candidate.status
    )
  }
}

enum CodebaseHistoryFilter {
  static func commits(
    in snapshot: GitRepositorySnapshot,
    scope: CodebaseHistoryScope,
    revisions: [CodebaseTicketRevision],
    branchWorkItemIDs: [String: UUID]
  ) -> [GitCommitSummary] {
    switch scope {
    case .trunk:
      return snapshot.commits.filter(\.isOnTrunk)
    case .allActivity:
      return snapshot.commits
    case .ticket(let workItemID):
      let matchingRevisions = revisions.filter { $0.workItemID == workItemID }
      var includedSHAs = Set<String>()
      for revision in matchingRevisions {
        includedSHAs.formUnion(
          commitSHAs(for: revision, in: snapshot)
        )
      }
      let branchNames = Set(matchingRevisions.map(\.branchName)).union(
        branchWorkItemIDs.compactMap { name, branchWorkItemID in
          branchWorkItemID == workItemID ? name : nil
        }
      )
      for branch in snapshot.branches where branchNames.contains(branch.name) {
        includedSHAs.formUnion(branch.commitSHAs)
      }
      return snapshot.commits.filter { includedSHAs.contains($0.sha) }
    }
  }

  static func associatedRevision(
    with commit: GitCommitSummary,
    in snapshot: GitRepositorySnapshot,
    revisions: [CodebaseTicketRevision]
  ) -> CodebaseTicketRevision? {
    revisions
      .compactMap { revision -> (revision: CodebaseTicketRevision, score: Int)? in
        let candidateSHAs = candidateCommitSHAs(for: revision, in: snapshot)
        let integrationSHAs = integrationCommitSHAs(for: revision, in: snapshot)
        let score: Int
        if commit.sha == revision.headSHA || commit.sha == revision.integratedSHA {
          score = 4
        } else if commit.parentSHAs.contains(revision.headSHA) {
          score = 3
        } else if integrationSHAs.contains(commit.sha) {
          score = 2
        } else if candidateSHAs.contains(commit.sha) {
          score = 1
        } else {
          return nil
        }
        return (revision, score)
      }
      .max { lhs, rhs in
        lhs.score == rhs.score
          ? lhs.revision.version < rhs.revision.version
          : lhs.score < rhs.score
      }?
      .revision
  }

  private static func commitSHAs(
    for revision: CodebaseTicketRevision,
    in snapshot: GitRepositorySnapshot
  ) -> Set<String> {
    candidateCommitSHAs(for: revision, in: snapshot).union(
      integrationCommitSHAs(for: revision, in: snapshot)
    )
  }

  private static func candidateCommitSHAs(
    for revision: CodebaseTicketRevision,
    in snapshot: GitRepositorySnapshot
  ) -> Set<String> {
    firstParentPath(
      from: revision.headSHA,
      in: snapshot,
      stopBefore: { $0 == revision.baseSHA }
    )
  }

  private static func integrationCommitSHAs(
    for revision: CodebaseTicketRevision,
    in snapshot: GitRepositorySnapshot
  ) -> Set<String> {
    guard let integratedSHA = revision.integratedSHA else { return [] }
    let commitsBySHA = Dictionary(
      uniqueKeysWithValues: snapshot.commits.map { ($0.sha, $0) }
    )
    var includedSHAs = Set<String>()
    var visitedSHAs = Set<String>()
    var sha = integratedSHA
    while visitedSHAs.insert(sha).inserted {
      guard let commit = commitsBySHA[sha] else { break }
      includedSHAs.insert(sha)
      if commit.sha == revision.headSHA || commit.parentSHAs.contains(revision.headSHA) {
        return includedSHAs
      }
      guard let parentSHA = commit.parentSHAs.first else { break }
      sha = parentSHA
    }
    return commitsBySHA[integratedSHA] == nil ? [] : [integratedSHA]
  }

  private static func firstParentPath(
    from startSHA: String,
    in snapshot: GitRepositorySnapshot,
    stopBefore: (String) -> Bool
  ) -> Set<String> {
    let commitsBySHA = Dictionary(
      uniqueKeysWithValues: snapshot.commits.map { ($0.sha, $0) }
    )
    var includedSHAs = Set<String>()
    var visitedSHAs = Set<String>()
    var sha = startSHA
    while !stopBefore(sha), visitedSHAs.insert(sha).inserted {
      guard let commit = commitsBySHA[sha] else { break }
      includedSHAs.insert(sha)
      guard let parentSHA = commit.parentSHAs.first else { break }
      sha = parentSHA
    }
    return includedSHAs
  }
}

enum CodebaseCommitKind: Equatable {
  case candidate
  case integration
  case productKnowledge
  case workspaceUpdate
  case workspaceSetup
  case acceptedChange
  case commit

  var title: String {
    switch self {
    case .candidate: "Candidate"
    case .integration: "Integration"
    case .productKnowledge: "Product knowledge"
    case .workspaceUpdate: "Workspace update"
    case .workspaceSetup: "Workspace setup"
    case .acceptedChange: "Accepted change"
    case .commit: "Commit"
    }
  }

  var symbol: String {
    switch self {
    case .candidate: "doc.badge.plus"
    case .integration: "arrow.triangle.merge"
    case .productKnowledge: "books.vertical.fill"
    case .workspaceUpdate: "gearshape.fill"
    case .workspaceSetup: "folder.badge.plus"
    case .acceptedChange: "checkmark.circle.fill"
    case .commit: "doc.text"
    }
  }

  var tint: Color {
    switch self {
    case .candidate: .blue
    case .integration: .teal
    case .productKnowledge: .indigo
    case .acceptedChange: .green
    case .workspaceUpdate, .workspaceSetup, .commit: .secondary
    }
  }
}

enum CodebaseCommitState: Equatable {
  case accepted
  case onTrunk
  case inReview
  case integrating
  case resolvingConflict
  case changesRequested
  case readyForDemo
  case earlierVersion
  case failed
  case notAccepted

  var title: String {
    switch self {
    case .accepted: "Accepted"
    case .onTrunk: "On trunk"
    case .inReview: "In review"
    case .integrating: "Integrating"
    case .resolvingConflict: "Resolving conflict"
    case .changesRequested: "Changes requested"
    case .readyForDemo: "Ready for demo"
    case .earlierVersion: "Earlier version"
    case .failed: "Failed"
    case .notAccepted: "Not accepted"
    }
  }

  var tint: Color {
    switch self {
    case .accepted, .onTrunk: .green
    case .inReview, .integrating: .teal
    case .resolvingConflict, .changesRequested, .readyForDemo: .orange
    case .failed: .red
    case .earlierVersion, .notAccepted: .secondary
    }
  }
}

struct CodebaseCommitPresentation: Equatable {
  let kind: CodebaseCommitKind
  let state: CodebaseCommitState
}

enum CodebaseCommitPresentationResolver {
  static func presentation(
    for commit: GitCommitSummary,
    revision: CodebaseTicketRevision?,
    hasTicket: Bool
  ) -> CodebaseCommitPresentation {
    let normalizedSubject = commit.subject.lowercased()
    let kind: CodebaseCommitKind
    if normalizedSubject == "initialize product workspace" {
      kind = .workspaceSetup
    } else if normalizedSubject.hasPrefix("checkpoint") {
      kind = .workspaceUpdate
    } else if normalizedSubject.contains("product knowledge") {
      kind = .productKnowledge
    } else if normalizedSubject.hasPrefix("integrate ")
      || revision.map({ commit.sha == $0.integratedSHA }) == true
      || revision.map({ commit.parentSHAs.contains($0.headSHA) }) == true
    {
      kind = .integration
    } else if revision != nil || (hasTicket && !commit.isOnTrunk) {
      kind = .candidate
    } else if commit.isOnTrunk {
      kind = .acceptedChange
    } else {
      kind = .commit
    }

    let state: CodebaseCommitState
    if commit.isOnTrunk {
      state = hasTicket ? .accepted : .onTrunk
    } else if let revision {
      state = stateForStatus(revision.status)
    } else {
      state = .notAccepted
    }
    return CodebaseCommitPresentation(kind: kind, state: state)
  }

  private static func stateForStatus(
    _ status: CandidateRevisionStatus
  ) -> CodebaseCommitState {
    switch status {
    case .queuedForReview, .queuedForIntegration, .integrating, .promoting: .integrating
    case .reviewing: .inReview
    case .resolvingConflict: .resolvingConflict
    case .changesRequested: .changesRequested
    case .readyForDemo: .readyForDemo
    case .accepted: .accepted
    case .superseded: .earlierVersion
    case .failed: .failed
    }
  }
}

enum CodebaseTicketStateTitle {
  static func title(for state: WorkItemState) -> String {
    switch state {
    case .queued: "Ready to pick"
    case .running: "In progress"
    case .integrating, .verifying, .readyToRelease: "In review"
    case .acceptance: "Ready for demo"
    case .released: "Done"
    default: state.title
    }
  }
}

private struct CodebaseCommitRow: View {
  let commit: GitCommitSummary
  let subject: String
  let authorName: String
  let presentation: CodebaseCommitPresentation
  let showsState: Bool
  let isSelected: Bool
  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: presentation.kind.symbol)
        .foregroundStyle(presentation.kind.tint)
        .frame(width: 20)
        .help(presentation.kind.title)
        .accessibilityLabel(presentation.kind.title)
      VStack(alignment: .leading, spacing: 5) {
        Text(subject)
          .font(.callout.weight(.medium))
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 6) {
          if showsState {
            Text(presentation.state.title)
              .fontWeight(.semibold)
              .foregroundStyle(presentation.state.tint)
          }
          Text(commit.shortSHA)
            .font(.caption2.monospaced())
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        HStack(spacing: 6) {
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
      if groupedFiles.count == 1,
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
            .help("Open \(ticket.key) in the sprint board")
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

enum CodebaseDiffLayout: String, CaseIterable, Identifiable {
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

enum CodebaseDiffLayoutPreference {
  private static let key = "codebaseDiffLayout"

  static func load(defaults: UserDefaults = .standard) -> CodebaseDiffLayout {
    defaults.string(forKey: key)
      .flatMap(CodebaseDiffLayout.init(rawValue:))
      ?? .automatic
  }

  static func save(
    _ layout: CodebaseDiffLayout,
    defaults: UserDefaults = .standard
  ) {
    defaults.set(layout.rawValue, forKey: key)
  }
}

private struct CodebaseDiffViewer: View {
  let unifiedDiff: String
  let isTruncated: Bool
  let isLoading: Bool
  let emptyDescription: String
  @State private var layout = CodebaseDiffLayoutPreference.load()

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
          .onChange(of: layout) { _, layout in
            CodebaseDiffLayoutPreference.save(layout)
          }
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
          UnifiedDiffLineRow(line: line)
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
            let presentation = UnifiedDiffLinePresentation(line: metadata)
            Text(metadata.isEmpty ? " " : metadata)
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(presentation.foreground)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.horizontal, 10)
              .padding(.vertical, 2)
              .frame(width: minimumWidth, alignment: .leading)
              .background(presentation.background)
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

}

enum UnifiedDiffLinePresentation: Equatable {
  case context
  case metadata
  case hunk
  case added
  case removed

  init(line: String) {
    if line.hasPrefix("@@") {
      self = .hunk
    } else if line.hasPrefix("diff --git")
      || line.hasPrefix("index ")
      || line.hasPrefix("+++")
      || line.hasPrefix("---")
    {
      self = .metadata
    } else if line.hasPrefix("+") {
      self = .added
    } else if line.hasPrefix("-") {
      self = .removed
    } else {
      self = .context
    }
  }

  var foreground: Color {
    switch self {
    case .context: .primary
    case .metadata: .secondary
    case .hunk: .purple
    case .added: .green
    case .removed: .red
    }
  }

  var background: Color {
    switch self {
    case .context, .metadata: .clear
    case .hunk: .purple.opacity(0.07)
    case .added: .green.opacity(0.08)
    case .removed: .red.opacity(0.08)
    }
  }
}

struct UnifiedDiffLineRow: View {
  let line: String
  var fillsAvailableWidth = true

  private var presentation: UnifiedDiffLinePresentation {
    UnifiedDiffLinePresentation(line: line)
  }

  var body: some View {
    Text(line.isEmpty ? " " : line)
      .font(.system(size: 11, design: .monospaced))
      .foregroundStyle(presentation.foreground)
      .fixedSize(horizontal: !fillsAvailableWidth, vertical: true)
      .padding(.horizontal, 10)
      .padding(.vertical, 1)
      .frame(
        maxWidth: fillsAvailableWidth ? .infinity : nil,
        alignment: .leading
      )
      .background(presentation.background)
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
