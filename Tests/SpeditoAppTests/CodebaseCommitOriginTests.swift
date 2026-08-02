import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

@Suite("Codebase commit origin")
struct CodebaseCommitOriginTests {
  @Test("Accepted worktree history remains distinct from direct trunk commits")
  func mergedWorktreeHistory() {
    let root = commit("root", parents: [], isOnTrunk: true)
    let worktreeFirst = commit("worktree-1", parents: [root.sha], isOnTrunk: true)
    let worktreeHead = commit("worktree-2", parents: [worktreeFirst.sha], isOnTrunk: true)
    let integration = commit(
      "integration",
      parents: [root.sha, worktreeHead.sha],
      isOnTrunk: true
    )
    let trunkFollowUp = commit("trunk-follow-up", parents: [integration.sha], isOnTrunk: true)
    let activeWorktree = commit("active-worktree", parents: [trunkFollowUp.sha], isOnTrunk: false)
    let preservedBranch = commit("preserved-branch", parents: [trunkFollowUp.sha], isOnTrunk: false)
    let snapshot = GitRepositorySnapshot(
      trunkSHA: trunkFollowUp.sha,
      branches: [
        branch(
          "ticket/T2",
          headSHA: activeWorktree.sha,
          worktreePath: "/tmp/ticket-T2",
          commitSHAs: [activeWorktree.sha]
        ),
        branch(
          "ticket/T3",
          headSHA: preservedBranch.sha,
          worktreePath: nil,
          commitSHAs: [preservedBranch.sha]
        ),
      ],
      commits: [
        trunkFollowUp,
        integration,
        worktreeHead,
        worktreeFirst,
        activeWorktree,
        preservedBranch,
        root,
      ]
    )

    let origins = CodebaseCommitOriginResolver.origins(
      in: snapshot,
      worktreeRevisions: [
        CodebaseWorktreeRevision(baseSHA: root.sha, headSHA: worktreeHead.sha)
      ]
    )

    #expect(origins[root.sha] == .trunk)
    #expect(origins[worktreeFirst.sha] == .worktree)
    #expect(origins[worktreeHead.sha] == .worktree)
    #expect(origins[integration.sha] == .trunk)
    #expect(origins[trunkFollowUp.sha] == .trunk)
    #expect(origins[activeWorktree.sha] == .worktree)
    #expect(origins[preservedBranch.sha] == .branch)
  }

  private func commit(
    _ sha: String,
    parents: [String],
    isOnTrunk: Bool
  ) -> GitCommitSummary {
    GitCommitSummary(
      sha: sha,
      parentSHAs: parents,
      authorName: "Agent",
      authorEmail: "agent@example.com",
      committedAt: Date(timeIntervalSince1970: 1),
      references: [],
      subject: sha,
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
