import Foundation

/// Checks owner-facing text against the product-language and UX rules stated in
/// `CLAUDE.md`. These are the repository's own rules, so a violation is a defect
/// rather than a matter of taste, which is why the pilot is allowed to fix them.
enum PilotConventions {
  /// Words the product specification bans in owner-facing surfaces, with the
  /// term that should appear instead.
  private static let bannedVocabulary: [(term: String, replacement: String)] = [
    ("administrator", "product owner"),
    ("operator", "product owner"),
    ("persona", "team member"),
  ]

  /// Fragments that mean implementation machinery has reached the owner. The
  /// product intent is explicit that terminals, Git commands, and Codex threads
  /// stay hidden behind the owner-facing workflow.
  private static let leakedDiagnosticMarkers = [
    "Error Domain=",
    "NSLocalizedDescription",
    "Optional(",
    "Fatal error",
    "nil)",
    "traceback",
    "stack trace",
    "rpc error",
    "codex app-server",
    "thread/start",
    "turn/start",
    "sqlite",
    "execution result",
    "worktree",
    "candidate revision",
  ]

  struct Violation {
    let rule: String
    let text: String
    let suggestion: String?
  }

  static func check(ownerFacingText: [String]) -> [Violation] {
    var violations: [Violation] = []
    for text in ownerFacingText {
      violations.append(contentsOf: checkVocabulary(text))
      violations.append(contentsOf: checkDiagnostics(text))
    }
    return violations
  }

  /// Button and menu labels carry stricter rules than prose: sentence case, and
  /// "and" written out rather than an ampersand.
  static func checkActionLabels(_ labels: [String]) -> [Violation] {
    var violations: [Violation] = []
    for label in labels {
      if label.contains("&") {
        violations.append(
          Violation(
            rule: "Write out \"and\" in button and menu labels; do not use ampersands.",
            text: label,
            suggestion: label.replacingOccurrences(of: "&", with: "and")
          )
        )
      }
      if let titleCased = titleCaseOffender(label) {
        violations.append(
          Violation(
            rule: "Use sentence case for every button and menu label.",
            text: label,
            suggestion: titleCased
          )
        )
      }
    }
    return violations
  }

  /// A failure the owner is shown must be one explanation, not a chain of
  /// internal errors bolted together.
  ///
  /// A live native macOS run showed the banner "The delivery agent returned an
  /// invalid execution result: The demo could not be prepared safely: browser
  /// paths must be a loopback URL path beginning with “/”." Three layers of
  /// implementation detail, ending in a sentence about browsers for a product
  /// that is a Mac app. The failure contract asks for a stable category, a
  /// concise owner-facing explanation, and technical evidence kept separate.
  static func checkFailureText(_ text: String?) -> [Violation] {
    guard let text, !text.isEmpty else { return [] }
    var violations = check(ownerFacingText: [text])
    let chainedClauses = text.components(separatedBy: ": ").count - 1
    if chainedClauses >= 2 {
      violations.append(
        Violation(
          rule:
            "An owner-facing failure must be one explanation, not a chain of internal errors.",
          text: text,
          suggestion: nil
        )
      )
    }
    return violations
  }

  /// An alert title names the thing that needs attention. A title that finishes
  /// one sentence and then runs a clause on after it is two fragments glued
  /// together, which no choice of wording makes correct.
  ///
  /// A live run titled the first alert a product owner ever receives "A native
  /// Mac app for jotting short notes that stay there when I reopen it. needs
  /// your input". An Epic has no analysed title until the plan arrives, so the
  /// title falls back to the outcome the owner typed, and an outcome is a
  /// sentence with a full stop on the end.
  static func checkAlertTitles(_ titles: [String]) -> [Violation] {
    titles.compactMap { title in
      guard hasInternalSentenceBoundary(title) else { return nil }
      return Violation(
        rule:
          "An alert title must read as one phrase, not a finished sentence with a clause "
          + "appended.",
        text: title,
        suggestion: nil
      )
    }
  }

  /// A sentence terminator followed by a lowercase word. Version numbers and
  /// abbreviations are not matched, because what follows them is not a
  /// lowercase word starting a new clause.
  private static func hasInternalSentenceBoundary(_ title: String) -> Bool {
    let characters = Array(title)
    guard characters.count > 2 else { return false }
    for index in 0..<(characters.count - 2) {
      guard ".!?".contains(characters[index]), characters[index + 1] == " " else { continue }
      if characters[index + 2].isLowercase { return true }
    }
    return false
  }

  private static func checkVocabulary(_ text: String) -> [Violation] {
    let lowered = text.lowercased()
    return bannedVocabulary.compactMap { term, replacement in
      guard lowered.contains(term) else { return nil }
      return Violation(
        rule: "Use owner-facing language: say \"\(replacement)\", not \"\(term)\".",
        text: text,
        suggestion: nil
      )
    }
  }

  private static func checkDiagnostics(_ text: String) -> [Violation] {
    let lowered = text.lowercased()
    return leakedDiagnosticMarkers.compactMap { marker in
      guard lowered.contains(marker.lowercased()) else { return nil }
      return Violation(
        rule:
          "Owner-facing failures must be a concise explanation, not raw technical evidence.",
        text: text,
        suggestion: nil
      )
    }
  }

  /// Established initialisms and proper nouns keep their capitalization, so only
  /// flag a label whose non-initial words are capitalized ordinary words.
  private static let preservedWords: Set<String> = [
    "AI", "GitHub", "Codex", "Spedito", "Mac", "macOS", "URL", "API", "PR", "ID",
  ]

  private static func titleCaseOffender(_ label: String) -> String? {
    let words = label.split(separator: " ").map(String.init)
    guard words.count > 1 else { return nil }
    var corrected = [words[0]]
    var didCorrect = false
    for word in words.dropFirst() {
      let stripped = word.trimmingCharacters(in: .punctuationCharacters)
      guard
        !preservedWords.contains(stripped),
        let first = stripped.first,
        first.isUppercase,
        stripped.dropFirst().allSatisfy({ !$0.isUppercase })
      else {
        corrected.append(word)
        continue
      }
      didCorrect = true
      corrected.append(word.prefix(1).lowercased() + word.dropFirst())
    }
    return didCorrect ? corrected.joined(separator: " ") : nil
  }
}
