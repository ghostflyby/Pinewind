// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Pinewind",
  platforms: [
    .macOS(.v15),
    .iOS(.v16),
  ],
  products: [
    .library(name: "PinewindCore", targets: ["PinewindCore"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-system", .upToNextMinor(from: "1.8.1")),
    .package(url: "https://github.com/apple/swift-crypto", from: "3.15.1"),
    .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
    .package(
      url: "https://github.com/davbeck/swift-glob.git",
      revision: "db32ccb46de66f83afad415ccb1609d08dfa5266"),
    .package(url: "https://github.com/Cocoanetics/GitKit", from: "2.2.0", traits: ["Archive"]),
    .package(
      url: "https://github.com/Cocoanetics/SwiftBash",
      .upToNextMinor(from: "0.1.0")),
  ],
  targets: [
    .target(name: "CPinewindPlatform"),
    .target(
      name: "PinewindCore",
      dependencies: [
        .target(name: "CPinewindPlatform", condition: .when(platforms: [.macOS, .iOS, .linux])),
        .product(name: "SystemPackage", package: "swift-system"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "Yams", package: "Yams"),
        .product(name: "BashInterpreter", package: "SwiftBash"),
        .product(name: "Glob", package: "swift-glob"),
        .product(name: "CGitKit", package: "GitKit"),
      ]),
    .testTarget(
      name: "PinewindAPITests",
      dependencies: ["PinewindCore", .product(name: "SystemPackage", package: "swift-system")],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "PinewindCoreTests",
      dependencies: [
        "PinewindCore", .product(name: "CGitKit", package: "GitKit"),
        .product(name: "BashInterpreter", package: "SwiftBash"),
      ],
      resources: [.copy("Fixtures")]),
  ]
)
