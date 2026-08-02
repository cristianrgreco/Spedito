import Foundation
import Testing

@Suite("Release packaging")
struct ReleasePackagingTests {
  @Test("The DMG layout uses the Finder-visible mounted disk")
  func dmgLayoutMountContract() throws {
    let script = try buildDMGScript()

    #expect(script.contains("-mountrandom /Volumes"))
    #expect(script.contains("finder_disk_name=${mount_dir:t}"))
    #expect(script.contains("sleep 5"))
    #expect(
      script.contains(
        "osascript \"$layout_script\" \"$finder_disk_name\""
      )
    )
    #expect(!script.contains("-mountpoint \"$mount_dir\""))
  }

  @Test("The volume icon is prepared on the mounted DMG before Finder")
  func dmgVolumeIconContract() throws {
    let script = try buildDMGScript()
    let resizeLimits = try #require(
      script.range(of: "hdiutil resize -limits \"$read_write_dmg\"")
    )
    let resize = try #require(
      script.range(
        of: "hdiutil resize -sectors \"$expanded_sectors\" \"$read_write_dmg\""
      )
    )
    let iconInstall = try #require(
      script.range(
        of: "install -m 644 \"$volume_icon_path\" \"$mount_dir/.VolumeIcon.icns\""
      )
    )
    let iconMetadata = try #require(
      script.range(
        of: "xcrun SetFile -c icnC \"$mount_dir/.VolumeIcon.icns\""
      )
    )
    let finderLayout = try #require(
      script.range(
        of: "osascript \"$layout_script\" \"$finder_disk_name\""
      )
    )

    #expect(resizeLimits.lowerBound < resize.lowerBound)
    #expect(resize.lowerBound < iconInstall.lowerBound)
    #expect(iconInstall.lowerBound < iconMetadata.lowerBound)
    #expect(iconMetadata.lowerBound < finderLayout.lowerBound)
    #expect(script.contains("expanded_sectors=$((current_sectors + 10240))"))
    #expect(!script.contains("-size +5m"))
    #expect(!script.contains("$staging_dir/.VolumeIcon.icns"))
  }

  private func buildDMGScript() throws -> String {
    let projectRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let scriptURL = projectRoot.appendingPathComponent("scripts/build_dmg.sh")
    return try String(contentsOf: scriptURL, encoding: .utf8)
  }
}
