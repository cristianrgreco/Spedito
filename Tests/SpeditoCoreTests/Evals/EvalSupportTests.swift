import Foundation
import SpeditoCore
import Testing

/// Ordinary-suite coverage for eval harness pieces with observable contracts
/// of their own; these tests never talk to Codex.
@Suite("Eval judge image attachments")
struct EvalJudgeImageAttachmentTests {
  @Test("Collects changed images bounded by count and size, naming every drop")
  func collectsBoundedImages() throws {
    let workspace = try EvalFixtureWorkspace.make()
    defer { workspace.remove() }
    let repository = try workspace.makeRepository(
      name: "image-attachments",
      files: ["README.md": "fixture"]
    )
    let baseSHA = try repository.headSHA()

    let smallImage = String(repeating: "x", count: 10)
    let oversizedImage = String(
      repeating: "y",
      count: EvalJudgeImageAttachments.maximumFileBytes + 1
    )
    try repository.write(files: [
      "design/a.png": smallImage,
      "design/b.jpg": smallImage,
      "design/c.jpeg": smallImage,
      "design/d.webp": smallImage,
      "design/e.gif": smallImage,
      "design/too-big.png": oversizedImage,
      "design/notes.md": "not an image",
      "prototype/index.html": "<p>markup</p>",
    ])

    let result = EvalJudgeImageAttachments.collect(
      worktreeURL: repository.rootURL,
      baseSHA: baseSHA
    )

    #expect(result.attached.count == EvalJudgeImageAttachments.maximumFileCount)
    for fileURL in result.attached {
      #expect(
        EvalJudgeImageAttachments.imageExtensions.contains(
          fileURL.pathExtension.lowercased()
        )
      )
    }
    // One image beyond the file bound and one over the size bound: both drops
    // are named, and non-image files are never candidates.
    #expect(result.dropped.count == 2)
    #expect(result.dropped.contains { $0.contains("too-big.png") })
    #expect(!result.dropped.contains { $0.contains("notes.md") })
    #expect(!result.attached.contains { $0.lastPathComponent == "index.html" })
  }

  @Test("A worktree without image work attaches nothing")
  func attachesNothingWithoutImages() throws {
    let workspace = try EvalFixtureWorkspace.make()
    defer { workspace.remove() }
    let repository = try workspace.makeRepository(
      name: "no-images",
      files: ["README.md": "fixture"]
    )
    let baseSHA = try repository.headSHA()
    try repository.write(files: ["prototype/index.html": "<p>markup</p>"])

    let result = EvalJudgeImageAttachments.collect(
      worktreeURL: repository.rootURL,
      baseSHA: baseSHA
    )

    #expect(result.attached.isEmpty)
    #expect(result.dropped.isEmpty)
  }
}
