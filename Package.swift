// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Spedito",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "SpeditoCore",
      targets: ["SpeditoCore"]
    ),
    .executable(
      name: "Spedito",
      targets: ["SpeditoApp"]
    ),
  ],
  targets: [
    .target(
      name: "SpeditoCore",
      linkerSettings: [
        .linkedLibrary("sqlite3"),
        .linkedFramework("Security")
      ]
    ),
    .executableTarget(
      name: "SpeditoApp",
      dependencies: ["SpeditoCore"],
      resources: [
        .copy("Resources/AppIcon.icns"),
        .copy("Resources/AppIcon.png"),
        .copy("Resources/ticket-attention.wav")
      ]
    ),
    .target(
      name: "SpeditoTestSupport",
      dependencies: ["SpeditoCore"],
      path: "Tests/SpeditoTestSupport"
    ),
    .testTarget(
      name: "SpeditoCoreTests",
      dependencies: ["SpeditoCore", "SpeditoTestSupport"],
      resources: [
        .copy("Fixtures/product-schema-v1.sql")
      ]
    ),
    .testTarget(
      name: "SpeditoAppTests",
      dependencies: ["SpeditoApp", "SpeditoTestSupport"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
