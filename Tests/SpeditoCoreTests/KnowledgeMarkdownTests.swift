import SpeditoCore
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

  @Test("Pipe tables retain headers, rows, inline Markdown, and alignment")
  func parsesPipeTables() {
    let source = """
      ## Supported environments

      | Environment | Runtime | Status |
      | :---------- | :-----: | -----: |
      | Local | `macOS 14` | **Ready** |
      | CI | macOS 15 | Pending |
      """

    #expect(
      KnowledgeMarkdown.blocks(in: source, removesLeadingTitle: false)
        == [
          .heading(level: 2, text: "Supported environments"),
          .table(
            KnowledgeMarkdown.Table(
              header: ["Environment", "Runtime", "Status"],
              alignments: [.leading, .center, .trailing],
              rows: [
                ["Local", "`macOS 14`", "**Ready**"],
                ["CI", "macOS 15", "Pending"],
              ]
            )
          ),
        ]
    )
  }

  @Test("Table cells can contain escaped and code-span pipes")
  func preservesCellPipes() {
    let source = """
      Name | Value
      --- | ---
      Escaped | A \\| B
      Code | `A | B`
      """

    #expect(
      KnowledgeMarkdown.blocks(in: source, removesLeadingTitle: false)
        == [
          .table(
            KnowledgeMarkdown.Table(
              header: ["Name", "Value"],
              alignments: [.leading, .leading],
              rows: [
                ["Escaped", "A \\| B"],
                ["Code", "`A | B`"],
              ]
            )
          )
        ]
    )
  }

  @Test("A pipe paragraph without a delimiter row remains a paragraph")
  func preservesNonTablePipes() {
    #expect(
      KnowledgeMarkdown.blocks(
        in: "Use A | B when either option works.",
        removesLeadingTitle: false
      )
        == [.paragraph(["Use A | B when either option works."])]
    )
  }
}
