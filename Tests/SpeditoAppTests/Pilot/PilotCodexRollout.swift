import Foundation

/// Reads what Codex itself recorded for a thread.
///
/// When the board says an agent is working and nothing is happening, the only
/// question that matters is whether the agent's turn actually ended. Spedito's
/// own state cannot answer it — that is precisely what is in doubt — and the
/// answer sits in Codex's rollout on disk the whole time.
///
/// Establishing this by hand cost the better part of a session: locating the
/// rollout, attributing it to a ticket, and reading its turn events. A finding
/// that already carries the answer costs nothing and cannot be misattributed,
/// which matters here because attributing a thread to the wrong ticket inverted
/// a conclusion once already.
enum PilotCodexRollout {
  /// One line describing the last turn Codex recorded for this thread, or nil
  /// when no rollout is readable. Absence is not evidence of anything, so the
  /// caller should say so rather than treating nil as "no turn".
  static func lastTurnSummary(
    threadID: String,
    sessionsRootURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/sessions", isDirectory: true)
  ) -> String? {
    guard let url = rolloutURL(threadID: threadID, sessionsRootURL: sessionsRootURL),
      let contents = try? String(contentsOf: url, encoding: .utf8)
    else { return nil }

    var lastEvent: (name: String, at: String)?
    for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let data = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let payload = object["payload"] as? [String: Any],
        let kind = payload["type"] as? String,
        turnEventNames.contains(kind)
      else { continue }
      let at = (object["timestamp"] as? String) ?? ""
      lastEvent = (kind, String(at.dropFirst(11).prefix(8)))
    }

    guard let lastEvent else { return nil }
    return switch lastEvent.name {
    case "task_complete":
      "Codex says this thread's last turn completed at \(lastEvent.at)Z."
    case "turn_aborted":
      "Codex says this thread's last turn was aborted at \(lastEvent.at)Z."
    default:
      "Codex says this thread's last turn started at \(lastEvent.at)Z and has not ended."
    }
  }

  private static let turnEventNames: Set<String> = [
    "task_started", "task_complete", "turn_aborted",
  ]

  /// Codex writes one rollout per thread under `~/.codex/sessions/<y>/<m>/<d>/`,
  /// and the file name embeds the thread identifier Spedito persists on the run.
  private static func rolloutURL(threadID: String, sessionsRootURL: URL) -> URL? {
    guard !threadID.isEmpty,
      let walker = FileManager.default.enumerator(
        at: sessionsRootURL,
        includingPropertiesForKeys: nil
      )
    else { return nil }
    for case let fileURL as URL in walker
    where fileURL.pathExtension == "jsonl"
      && fileURL.lastPathComponent.contains(threadID)
    {
      return fileURL
    }
    return nil
  }
}
