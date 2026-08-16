import SpeditoCore
import SwiftUI

struct IncomingRepositoryReviewSheet: View {
  let sync: RemoteSafeSync
  let onAccept: () -> Void
  let onReject: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text(sync.kind == .fastForward ? "Review incoming changes" : "Review merged pull request")
          .font(.title2.bold())
        Text(
          "Only the accepted Product workspace will change. Spedito verified this exact candidate."
        )
        .foregroundStyle(.secondary)
      }
      .padding(22)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          remoteChangeList(title: "Commits", commits: sync.commits)
          remotePathList(title: "Files", paths: sync.paths)
        }
        .padding(22)
      }
      Divider()
      HStack {
        Button("Reject", role: .destructive, action: onReject)
          .buttonStyle(.bordered)
          .tint(.red)
        Spacer()
        Button(
          sync.kind == .fastForward ? "Accept incoming changes" : "Align merged history",
          action: onAccept
        )
        .buttonStyle(.borderedProminent)
      }
      .padding(18)
    }
    .frame(width: 680, height: 600)
    .accessibilityIdentifier("github.incoming-review.\(sync.id.uuidString)")
  }
}

@ViewBuilder
private func remoteChangeList(title: String, commits: [RemoteCommitSummary]) -> some View {
  VStack(alignment: .leading, spacing: 7) {
    Text(title)
      .font(.headline)
    if commits.isEmpty {
      Text("No commits to list")
        .foregroundStyle(.secondary)
    } else {
      ForEach(commits) { commit in
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(String(commit.sha.prefix(8)))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
          Text(commit.subject)
            .font(.callout)
        }
      }
    }
  }
}

@ViewBuilder
private func remotePathList(title: String, paths: [String]) -> some View {
  VStack(alignment: .leading, spacing: 7) {
    Text(title)
      .font(.headline)
    if paths.isEmpty {
      Text("No changed files to list")
        .foregroundStyle(.secondary)
    } else {
      ForEach(paths, id: \.self) { path in
        Text(path)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
      }
    }
  }
}
