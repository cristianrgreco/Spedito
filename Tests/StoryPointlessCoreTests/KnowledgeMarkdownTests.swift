import StoryPointlessCore
import Testing

@Suite("Knowledge Markdown")
struct KnowledgeMarkdownTests {
  @Test("A leading page title is removed without flattening the document")
  func removesLeadingTitle() {
    let source = """
      # Weather provider

      ## Decision

      Use the selected provider.

      - Reliable forecast data
      - Documented limits
      """

    #expect(
      KnowledgeMarkdown.normalizedBody(source)
        == """
          ## Decision

          Use the selected provider.

          - Reliable forecast data
          - Documented limits
          """
    )
  }

  @Test("Only a leading level-one heading is treated as the native page title")
  func preservesPageContent() {
    #expect(
      KnowledgeMarkdown.normalizedBody("## Architecture\n\nDetails")
        == "## Architecture\n\nDetails"
    )
    #expect(
      KnowledgeMarkdown.normalizedBody("A paragraph\non two lines")
        == "A paragraph\non two lines"
    )
    #expect(KnowledgeMarkdown.normalizedBody("\r\n# Title\r\n\r\nBody\r\n") == "Body")
  }

  @Test("Delivery notes retain block-level Markdown structure")
  func parsesDeliveryNoteBlocks() {
    let source = """
      # T-1 · Define weather requirements and select a data provider

      **Delivery evidence:** Prepared with the candidate revision  
      **Prepared by:** Business Analyst

      ## What changed
      Corrected the provider decision.

      ## How it works and why
      - The selected provider meets the forecast requirements.

      ## Checks performed
      - Verified the documented request limits.
      """

    #expect(
      KnowledgeMarkdown.blocks(in: source)
        == [
          .paragraph([
            "**Delivery evidence:** Prepared with the candidate revision  ",
            "**Prepared by:** Business Analyst",
          ]),
          .heading(level: 2, text: "What changed"),
          .paragraph(["Corrected the provider decision."]),
          .heading(level: 2, text: "How it works and why"),
          .unorderedList(["The selected provider meets the forecast requirements."]),
          .heading(level: 2, text: "Checks performed"),
          .unorderedList(["Verified the documented request limits."]),
        ]
    )
  }
}
