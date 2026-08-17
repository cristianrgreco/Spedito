import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

@Suite("Codebase history presentation")
struct CodebaseCommitOriginTests {
  @Test("History scopes separate accepted and ticket activity")
  func historyScopes() {
    let ticketID = UUID()
    let root = commit("root", parents: [], isOnTrunk: true)
    let checkpoint = commit(
      "checkpoint",
      parents: [root.sha],
      subject: "Checkpoint before candidate integration",
      isOnTrunk: true
    )
    let candidate = commit("candidate", parents: [root.sha], isOnTrunk: false)
    let integration = commit(
      "integration",
      parents: [checkpoint.sha, candidate.sha],
      subject: "Integrate T2: Design the forecast experience",
      isOnTrunk: false
    )
    let knowledge = commit(
      "knowledge",
      parents: [integration.sha],
      subject: "T2: stage reviewed product knowledge",
      isOnTrunk: false
    )
    let unrelated = commit("unrelated", parents: [root.sha], isOnTrunk: false)
    let snapshot = GitRepositorySnapshot(
      trunkSHA: checkpoint.sha,
      branches: [
        branch(
          "ticket/T2",
          headSHA: candidate.sha,
          worktreePath: "/tmp/ticket-T2",
          commitSHAs: [candidate.sha]
        ),
        branch(
          "ticket/T3",
          headSHA: unrelated.sha,
          worktreePath: nil,
          commitSHAs: [unrelated.sha]
        ),
      ],
      commits: [knowledge, integration, checkpoint, candidate, unrelated, root]
    )
    let revision = revision(
      workItemID: ticketID,
      baseSHA: root.sha,
      headSHA: candidate.sha,
      integratedSHA: knowledge.sha,
      status: .readyForDemo
    )

    #expect(
      shas(
        CodebaseHistoryFilter.commits(
          in: snapshot,
          scope: .trunk,
          revisions: [revision],
          branchWorkItemIDs: ["ticket/T2": ticketID]
        )
      ) == [checkpoint.sha, root.sha]
    )
    #expect(
      shas(
        CodebaseHistoryFilter.commits(
          in: snapshot,
          scope: .ticket(ticketID),
          revisions: [revision],
          branchWorkItemIDs: ["ticket/T2": ticketID]
        )
      ) == [knowledge.sha, integration.sha, candidate.sha]
    )
    #expect(
      CodebaseHistoryFilter.commits(
        in: snapshot,
        scope: .allActivity,
        revisions: [revision],
        branchWorkItemIDs: ["ticket/T2": ticketID]
      ) == snapshot.commits
    )
  }

  @Test("Commit icons describe delivery activity instead of Git topology")
  func semanticCommitPresentation() {
    let ticketID = UUID()
    let root = commit(
      "root",
      parents: [],
      subject: "Initialize product workspace",
      isOnTrunk: true
    )
    let checkpoint = commit(
      "checkpoint",
      parents: [root.sha],
      subject: "Checkpoint before candidate integration",
      isOnTrunk: true
    )
    let candidate = commit("candidate", parents: [root.sha], isOnTrunk: false)
    let integration = commit(
      "integration",
      parents: [checkpoint.sha, candidate.sha],
      subject: "Integrate T2: Design the forecast experience",
      isOnTrunk: false
    )
    let knowledge = commit(
      "knowledge",
      parents: [integration.sha],
      subject: "T2: stage reviewed product knowledge",
      isOnTrunk: false
    )
    let snapshot = GitRepositorySnapshot(
      trunkSHA: checkpoint.sha,
      branches: [],
      commits: [knowledge, integration, checkpoint, candidate, root]
    )
    let revision = revision(
      workItemID: ticketID,
      baseSHA: root.sha,
      headSHA: candidate.sha,
      integratedSHA: knowledge.sha,
      status: .readyForDemo
    )

    let candidatePresentation = presentation(
      for: candidate,
      in: snapshot,
      revision: revision
    )
    #expect(candidatePresentation.kind == .candidate)
    #expect(candidatePresentation.kind.symbol == "doc.badge.plus")
    #expect(candidatePresentation.state == .readyForDemo)

    let integrationPresentation = presentation(
      for: integration,
      in: snapshot,
      revision: revision
    )
    #expect(integrationPresentation.kind == .integration)
    #expect(integrationPresentation.kind.symbol == "arrow.triangle.merge")
    #expect(integrationPresentation.state == .readyForDemo)

    let knowledgePresentation = presentation(
      for: knowledge,
      in: snapshot,
      revision: revision
    )
    #expect(knowledgePresentation.kind == .productKnowledge)
    #expect(knowledgePresentation.kind.symbol == "books.vertical.fill")

    let checkpointPresentation = CodebaseCommitPresentationResolver.presentation(
      for: checkpoint,
      revision: nil,
      hasTicket: false
    )
    #expect(checkpointPresentation.kind == .workspaceUpdate)
    #expect(checkpointPresentation.state == .onTrunk)

    let setupPresentation = CodebaseCommitPresentationResolver.presentation(
      for: root,
      revision: nil,
      hasTicket: false
    )
    #expect(setupPresentation.kind == .workspaceSetup)
    #expect(setupPresentation.state == .onTrunk)
  }

  @Test("A truncated integration history does not leak trunk commits into a ticket")
  func truncatedIntegrationHistory() {
    let ticketID = UUID()
    let root = commit("root", parents: [], isOnTrunk: true)
    let checkpoint = commit("checkpoint", parents: [root.sha], isOnTrunk: true)
    let candidate = commit("candidate", parents: [root.sha], isOnTrunk: false)
    let integrated = commit(
      "integrated",
      parents: [checkpoint.sha],
      isOnTrunk: false
    )
    let snapshot = GitRepositorySnapshot(
      trunkSHA: checkpoint.sha,
      branches: [],
      commits: [integrated, checkpoint, candidate, root]
    )
    let revision = revision(
      workItemID: ticketID,
      baseSHA: root.sha,
      headSHA: candidate.sha,
      integratedSHA: integrated.sha,
      status: .readyForDemo
    )

    let filtered = CodebaseHistoryFilter.commits(
      in: snapshot,
      scope: .ticket(ticketID),
      revisions: [revision],
      branchWorkItemIDs: [:]
    )

    #expect(shas(filtered) == [integrated.sha, candidate.sha])
  }

  @Test("Accepted ticket commits show accepted state without losing their change type")
  func acceptedCandidatePresentation() {
    let acceptedCandidate = commit(
      "accepted-candidate",
      parents: ["root"],
      isOnTrunk: true
    )
    let revision = revision(
      workItemID: UUID(),
      baseSHA: "root",
      headSHA: acceptedCandidate.sha,
      integratedSHA: nil,
      status: .accepted
    )

    let presentation = CodebaseCommitPresentationResolver.presentation(
      for: acceptedCandidate,
      revision: revision,
      hasTicket: true
    )

    #expect(presentation.kind == .candidate)
    #expect(presentation.state == .accepted)
  }

  @Test("[V04] Commit origins retain the exact Ticket and resolve its current detail mode")
  func v04CommitOriginAndDetailMode() throws {
    let productID = UUID()
    let workItem = WorkItem(
      productID: productID,
      key: "T7",
      title: "Explain the accepted change",
      state: .released,
      rank: 1
    )
    let root = commit("root", parents: [], isOnTrunk: true)
    let candidateCommit = commit("candidate", parents: [root.sha], isOnTrunk: true)
    let snapshot = GitRepositorySnapshot(
      trunkSHA: candidateCommit.sha,
      branches: [],
      commits: [candidateCommit, root]
    )
    let candidateRevision = revision(
      workItemID: workItem.id,
      baseSHA: root.sha,
      headSHA: candidateCommit.sha,
      integratedSHA: candidateCommit.sha,
      status: .accepted
    )
    let associatedRevision = try #require(
      CodebaseHistoryFilter.associatedRevision(
        with: candidateCommit,
        in: snapshot,
        revisions: [candidateRevision]
      )
    )
    let activeSprint = Sprint(
      productID: productID,
      number: 1,
      goal: "Deliver the accepted change",
      state: .active
    )
    let sprintItem = SprintItem(
      sprintID: activeSprint.id,
      workItemID: workItem.id,
      implementerProfileID: UUID(),
      estimatedTokens: 100
    )

    #expect(associatedRevision.workItemID == workItem.id)
    #expect(
      TicketDetailPresentation.existing(
        workItem,
        activeSprint: SprintPlan(sprint: activeSprint, items: [sprintItem])
      ).mode == .delivery
    )
    #expect(
      TicketDetailPresentation.existing(
        workItem,
        activeSprint: SprintPlan(
          sprint: Sprint(
            id: activeSprint.id,
            productID: productID,
            number: 1,
            goal: activeSprint.goal,
            state: .completed
          ),
          items: [sprintItem]
        )
      ).mode == .editable
    )
  }

  private func presentation(
    for commit: GitCommitSummary,
    in snapshot: GitRepositorySnapshot,
    revision: CodebaseTicketRevision
  ) -> CodebaseCommitPresentation {
    let associatedRevision = CodebaseHistoryFilter.associatedRevision(
      with: commit,
      in: snapshot,
      revisions: [revision]
    )
    return CodebaseCommitPresentationResolver.presentation(
      for: commit,
      revision: associatedRevision,
      hasTicket: associatedRevision != nil
    )
  }

  private func shas(_ commits: [GitCommitSummary]) -> [String] {
    commits.map(\.sha)
  }

  private func revision(
    workItemID: UUID,
    baseSHA: String,
    headSHA: String,
    integratedSHA: String?,
    status: CandidateRevisionStatus
  ) -> CodebaseTicketRevision {
    CodebaseTicketRevision(
      candidateID: UUID(),
      workItemID: workItemID,
      version: 1,
      branchName: "ticket/T2",
      baseSHA: baseSHA,
      headSHA: headSHA,
      integratedSHA: integratedSHA,
      status: status
    )
  }

  private func commit(
    _ sha: String,
    parents: [String],
    subject: String? = nil,
    isOnTrunk: Bool
  ) -> GitCommitSummary {
    GitCommitSummary(
      sha: sha,
      parentSHAs: parents,
      authorName: "Agent",
      authorEmail: "agent@example.com",
      committedAt: Date(timeIntervalSince1970: 1),
      references: [],
      subject: subject ?? sha,
      isOnTrunk: isOnTrunk
    )
  }

  private func branch(
    _ name: String,
    headSHA: String,
    worktreePath: String?,
    commitSHAs: [String]
  ) -> GitBranchSnapshot {
    GitBranchSnapshot(
      name: name,
      headSHA: headSHA,
      worktreePath: worktreePath,
      dirtyFileCount: 0,
      aheadOfTrunk: commitSHAs.count,
      behindTrunk: 0,
      commitSHAs: commitSHAs,
      lastCommitAt: Date(timeIntervalSince1970: 1),
      lastCommitSubject: headSHA
    )
  }
}
