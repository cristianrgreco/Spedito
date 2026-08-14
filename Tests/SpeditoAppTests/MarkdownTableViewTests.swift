import SwiftUI
import Testing

@testable import SpeditoApp
@testable import SpeditoCore

@Suite("Markdown table view")
@MainActor
struct MarkdownTableViewTests {
  @Test("Wrapped table cells expand their rows")
  func wrappedCellsExpandRows() throws {
    let table = KnowledgeMarkdown.Table(
      header: [
        "Provider",
        "Seven-day forecast and place suggestions",
        "Cost/licensing",
      ],
      alignments: [.leading, .leading, .leading],
      rows: [
        [
          "WeatherAPI Starter — recommended",
          "Seven-day forecast; Search/Autocomplete; supports city, US ZIP, UK postcode, and Canadian postal code queries.",
          "US$7/month; commercial use; one subscription/key per online or mobile service.",
        ],
        [
          "OpenWeather One Call + Geocoding",
          "Eight daily forecast entries; direct geocoding supports city and postcode.",
          "First 1,000 One Call 4.0 calls/day are free; price beyond that is usage-based and not shown on the public pricing page reviewed.",
        ],
        [
          "Open-Meteo commercial API",
          "Seven days by default (up to 16); geocoding accepts city or postal-code search.",
          "Free endpoint is non-commercial and has no uptime guarantee; commercial use requires a paid customer API key.",
        ],
      ]
    )
    let renderer = ImageRenderer(
      content: MarkdownTableView(
        table: table,
        font: .body,
        inlineMarkdown: SafeURLPolicy.markdown
      )
    )
    renderer.proposedSize = ProposedViewSize(width: 780, height: nil)

    let renderedHeight = try #require(renderer.nsImage).size.height

    #expect(renderedHeight > 200)
  }
}
