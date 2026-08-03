import AppKit
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
    let backgroundGenerator = try String(
      contentsOf: projectRoot().appendingPathComponent("scripts/generate_dmg_background.swift"),
      encoding: .utf8
    )

    #expect(script.contains("create-dmg \\"))
    #expect(script.contains("--background \"$background_path\""))
    #expect(script.contains("DMGBackground.tiff"))
    #expect(script.contains("--window-size 660 468"))
    #expect(script.contains("--icon \"Spedito.app\" 180 240"))
    #expect(script.contains("--app-drop-link 480 240"))
    #expect(script.contains("--no-internet-enable"))
    #expect(workflow.contains("brew install create-dmg"))
    #expect(!script.contains("hdiutil"))
    #expect(!script.contains("osascript"))
    #expect(!script.contains("--volicon"))
    #expect(!verification.contains(".VolumeIcon.icns"))
    #expect(verification.contains("DMGBackground.tiff"))
    #expect(backgroundGenerator.contains("private let scaleFactors = [1, 2]"))
    #expect(backgroundGenerator.contains("image.tiffRepresentation"))
    #expect(!backgroundGenerator.contains("EARLY PREVIEW"))
  }

  @Test("The DMG background includes standard and Retina artwork")
  @MainActor
  func backgroundResolutionContract() throws {
    let backgroundURL = projectRoot()
      .appendingPathComponent("Distribution/DMGBackground.tiff")
    let image = try #require(NSImage(contentsOf: backgroundURL))

    #expect(image.size == NSSize(width: 660, height: 440))
    #expect(
      image.representations.contains {
        $0.pixelsWide == 660 && $0.pixelsHigh == 440
      }
    )
    #expect(
      image.representations.contains {
        $0.pixelsWide == 1_320 && $0.pixelsHigh == 880
      }
    )
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
