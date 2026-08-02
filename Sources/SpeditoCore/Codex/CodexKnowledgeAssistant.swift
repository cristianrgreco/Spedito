import Foundation

public struct KnowledgeAnswer: Equatable, Sendable {
  public let answer: String
  public let citationPageIDs: [UUID]

  public init(answer: String, citationPageIDs: [UUID]) {
    self.answer = answer
    self.citationPageIDs = citationPageIDs
  }
}

public enum CodexKnowledgeAssistant {
  public static let developerInstructions = """
    You answer Product Owner questions only from the verified Spedito knowledge pages supplied
    in the prompt. Keep the response concise and business-readable. Do not use outside knowledge or
    infer missing facts. If the pages do not answer the question, say so plainly. Cite every material
    claim by returning the exact page IDs that support it. Format the answer as concise Markdown using
    short paragraphs and lists where useful. Return only the required JSON.
    """

  public static func prompt(question: String, pages: [KnowledgePage]) -> String {
    let context = pages.map { page in
      """
      PAGE ID: \(page.id.uuidString)
      TITLE: \(page.title)
      BODY:
      \(page.bodyMarkdown)
      """
    }.joined(separator: "\n\n---\n\n")
    return """
      QUESTION
      \(question)

      VERIFIED KNOWLEDGE
      \(context)
      """
  }

  public static var outputSchema: JSONValue {
    .object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([.string("answer"), .string("citationPageIDs")]),
      "properties": .object([
        "answer": .object(["type": .string("string")]),
        "citationPageIDs": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
        ]),
      ]),
    ])
  }

  public static func decode(_ text: String, allowedPageIDs: Set<UUID>) throws -> KnowledgeAnswer {
    guard let data = text.data(using: .utf8) else {
      throw TicketExecutionGenerationError.invalidResponse(
        "The knowledge answer was not UTF-8."
      )
    }
    let generated = try JSONDecoder().decode(GeneratedKnowledgeAnswer.self, from: data)
    let answer = generated.answer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !answer.isEmpty else {
      throw TicketExecutionGenerationError.invalidResponse(
        "The knowledge answer was empty."
      )
    }
    let citations = generated.citationPageIDs.compactMap(UUID.init(uuidString:))
    guard citations.allSatisfy(allowedPageIDs.contains) else {
      throw TicketExecutionGenerationError.invalidResponse(
        "The knowledge answer cited a page that was not supplied."
      )
    }
    return KnowledgeAnswer(answer: answer, citationPageIDs: citations)
  }
}

private struct GeneratedKnowledgeAnswer: Codable {
  let answer: String
  let citationPageIDs: [String]
}
