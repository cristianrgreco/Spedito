import Foundation
import Testing

@Suite("Release packaging")
struct ReleasePackagingTests {
  @Test("The DMG delegates disk-image handling to create-dmg")
  func createDMGContract() throws {
    let script = try buildDMGScript()
    let workflow = try String(
      contentsOf: projectRoot().appendingPathComponent(".github/workflows/release.yml"),
      encoding: .utf8
    )
    let verification = try String(
      contentsOf: projectRoot().appendingPathComponent("scripts/verify_dmg.sh"),
      encoding: .utf8
    )

    #expect(script.contains("create-dmg \\"))
    #expect(script.contains("--background \"$background_path\""))
    #expect(script.contains("--window-size 660 440"))
    #expect(script.contains("--icon \"Spedito.app\" 180 240"))
    #expect(script.contains("--app-drop-link 480 240"))
    #expect(script.contains("--no-internet-enable"))
    #expect(workflow.contains("brew install create-dmg"))
    #expect(!script.contains("hdiutil"))
    #expect(!script.contains("osascript"))
    #expect(!script.contains("--volicon"))
    #expect(!verification.contains(".VolumeIcon.icns"))
  }

  @Test("The release and website use a stable latest-download DMG")
  func stableLatestDownloadContract() throws {
    let projectRoot = projectRoot()
    let workflow = try String(
      contentsOf: projectRoot.appendingPathComponent(".github/workflows/release.yml"),
      encoding: .utf8
    )
    let website = try String(
      contentsOf: projectRoot.appendingPathComponent("Website/index.html"),
      encoding: .utf8
    )
    let downloadURL =
      "https://github.com/cristianrgreco/spedito/releases/latest/download/Spedito.dmg"

    #expect(workflow.contains("dmg=\"Spedito.dmg\""))
    #expect(!workflow.contains("macOS-Apple-Silicon.dmg"))
    #expect(website.components(separatedBy: downloadURL).count - 1 == 2)
    #expect(!website.contains("/Spedito/releases/latest\""))
  }

  private func buildDMGScript() throws -> String {
    let scriptURL = projectRoot().appendingPathComponent("scripts/build_dmg.sh")
    return try String(contentsOf: scriptURL, encoding: .utf8)
  }

  private func projectRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
