// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Pinewind",
  platforms: [
    .macOS(.v15),
    .iOS(.v16),
  ],
  products: [
    .library(name: "PinewindCore", targets: ["PinewindCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
    .package(url: "https://github.com/davbeck/swift-glob.git", from: "1.0.0"),
    .package(url: "https://github.com/Cocoanetics/GitKit", from: "2.2.0", traits: ["Archive"]),
    .package(
      url: "https://github.com/Cocoanetics/SwiftBash",
      .upToNextMinor(from: "0.1.0")),
  ],
  targets: [
    .target(
      name: "PinewindCore",
      dependencies: [
        .product(name: "Yams", package: "Yams"),
        .product(name: "BashInterpreter", package: "SwiftBash"),
        .product(name: "Glob", package: "swift-glob"),
        .product(name: "CGitKit", package: "GitKit"),
      ]),
    .testTarget(
      name: "PinewindCoreTests",
      dependencies: ["PinewindCore", .product(name: "CGitKit", package: "GitKit")],
      resources: [.copy("Fixtures")]),
  ]
)
