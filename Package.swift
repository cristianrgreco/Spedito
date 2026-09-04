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
  dependencies: [
    // Pure-Swift tokeniser for diff syntax colouring. Pinned exactly: the
    // project is pre-1.0 and every token-kind change is owner-visible.
    .package(url: "https://github.com/onevcat/Chroma.git", exact: "0.3.1")
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
      dependencies: [
        "SpeditoCore",
        .product(name: "Chroma", package: "Chroma"),
      ],
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
