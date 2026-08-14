import Foundation

public struct RemotePublicationTextValidationContext: Equatable, Sendable {
  public let activeTokens: Set<String>
  public let protectedPaths: Set<String>
  public let codexIdentifiers: Set<String>
  public let sqliteRecordIdentifiers: Set<String>

  public init(
    activeTokens: Set<String> = [],
    protectedPaths: Set<String> = [],
    codexIdentifiers: Set<String> = [],
    sqliteRecordIdentifiers: Set<String> = []
  ) {
    self.activeTokens = activeTokens
    self.protectedPaths = protectedPaths
    self.codexIdentifiers = codexIdentifiers
    self.sqliteRecordIdentifiers = sqliteRecordIdentifiers
  }
}

public struct RemotePublicationCommitText: Equatable, Sendable {
  public let sha: String
  public let subject: String

  public init(sha: String, subject: String) {
    self.sha = sha
    self.subject = subject
  }
}

public enum RemotePublicationTextValidationError: Error, Equatable, LocalizedError, Sendable {
  case emptyTitle
  case titleTooLong
  case bodyTooLong
  case sensitiveContent

  public var errorDescription: String? {
    switch self {
    case .emptyTitle:
      "Enter a pull request title."
    case .titleTooLong:
      "The pull request title must be 256 characters or fewer."
    case .bodyTooLong:
      "The pull request description must be 65,000 bytes or fewer."
    case .sensitiveContent:
      "Remove credentials or private Spedito references before publishing."
    }
  }
}

public struct RemotePublicationTextValidator: Sendable {
  public init() {}

  public func validate(
    title: String,
    body: String,
    context: RemotePublicationTextValidationContext
  ) throws {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RemotePublicationTextValidationError.emptyTitle
    }
    guard title.unicodeScalars.count <= 256 else {
      throw RemotePublicationTextValidationError.titleTooLong
    }
    guard body.utf8.count <= 65_000 else {
      throw RemotePublicationTextValidationError.bodyTooLong
    }
    let combined = title + "\n" + body
    guard !containsSensitiveContent(combined, context: context) else {
      throw RemotePublicationTextValidationError.sensitiveContent
    }
  }

  public func defaultBody(
    commits: [RemotePublicationCommitText],
    localSHA: String,
    remoteSHA: String
  ) -> String {
    var lines = ["## Changes"]
    if commits.isEmpty {
      lines.append("- No new commits")
    } else {
      lines.append(
        contentsOf: commits.map { commit in
          "- `\(String(commit.sha.prefix(12)))` \(singleLine(commit.subject))"
        })
    }
    lines.append("")
    lines.append("## Revisions")
    lines.append("- Local: `\(String(localSHA.prefix(12)))`")
    lines.append("- GitHub base: `\(String(remoteSHA.prefix(12)))`")
    lines.append("")
    lines.append("Spedito created this pull request but did not merge it.")
    return lines.joined(separator: "\n")
  }

  private func containsSensitiveContent(
    _ value: String,
    context: RemotePublicationTextValidationContext
  ) -> Bool {
    let exactValues = context.activeTokens
      .union(context.protectedPaths)
      .union(context.codexIdentifiers)
      .union(context.sqliteRecordIdentifiers)
      .filter { !$0.isEmpty }
    if exactValues.contains(where: value.contains) {
      return true
    }
    return matches(
      #"(?i)\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"#, in: value)
      || matches(#"(?i)https://[^\s/@:]+(?::[^\s/@]*)?@"#, in: value)
      || matches(#"(?i)\b(?:thread|turn)[_-][A-Za-z0-9-]{8,}\b"#, in: value)
      || matches(#"(?i)(?:^|[/\\])\.spedito(?:[/\\]|$)"#, in: value)
      || matches(
        #"(?i)\b(?:product|work_item|agent_run|candidate_revision)_id\s*[:=]\s*[0-9a-f-]{16,}\b"#,
        in: value)
  }

  private func matches(_ pattern: String, in value: String) -> Bool {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return true
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.firstMatch(in: value, range: range) != nil
  }

  private func singleLine(_ value: String) -> String {
    value
      .components(separatedBy: .newlines)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      ?? ""
  }
}
