// swift-tools-version: 6.2

import PackageDescription

// libgit2 arrives through pkg-config, with the supplier chosen by whoever
// builds: LIBGIT2_PKG_CONFIG must hold the absolute path of the libgit2.pc
// file to link against — any source works (vcpkg, Homebrew cellars,
// hand-built trees); see CONTRIBUTING.md for the recommended vcpkg
// manifest flow. One build session targets one destination: the manifest
// is re-evaluated on every build with fresh environment (the compiled
// manifest is cached, its execution is not), so pointing the variable at
// the matching pc — macOS or iOS Simulator — selects the right slice.
// Without the variable the target falls back to the bare pkg-config name
// (system paths, Homebrew, apt). Never point it at a library built for
// another destination: SwiftPM cannot detect the mismatch here.
func libgit2PkgConfig() -> String {
  Context.environment["LIBGIT2_PKG_CONFIG"] ?? "libgit2"
}

#if os(Linux)
let git2Targets: [Target] = [
  .systemLibrary(
    name: "Git2", pkgConfig: libgit2PkgConfig(), providers: [.apt(["libgit2-dev"])])
]
#else
let git2Targets: [Target] = [
  .systemLibrary(name: "Git2", pkgConfig: libgit2PkgConfig())
]
#endif

let package = Package(
  name: "Pinewind",
  platforms: [
    .macOS(.v15),
    .iOS(.v16),
  ],
  products: [
    .library(name: "PinewindCore", targets: ["PinewindCore"]),
    .library(name: "PinewindCommands", targets: ["PinewindCommands"]),
    .executable(name: "pinewind", targets: ["PinewindCLI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    .package(url: "https://github.com/apple/swift-system", .upToNextMinor(from: "1.8.1")),
    .package(url: "https://github.com/apple/swift-crypto", from: "3.15.1"),
    .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
    .package(
      url: "https://github.com/davbeck/swift-glob.git",
      revision: "db32ccb46de66f83afad415ccb1609d08dfa5266"),
    .package(
      url: "https://github.com/Cocoanetics/SwiftBash",
      .upToNextMinor(from: "0.1.0")),
  ],
  targets: [
    .executableTarget(
      name: "PinewindCLI",
      dependencies: ["PinewindCommands"]),
    .target(
      name: "PinewindCommands",
      dependencies: [
        "PinewindCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "SystemPackage", package: "swift-system"),
      ]),
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
        .target(name: "Git2"),
      ]),
    .testTarget(
      name: "PinewindCLITests",
      dependencies: [
        .target(name: "PinewindCLI", condition: .when(platforms: [.macOS, .linux, .windows])),
        "PinewindCommands", "PinewindCore",
        .product(name: "SystemPackage", package: "swift-system"),
      ],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "PinewindAPITests",
      dependencies: ["PinewindCore", .product(name: "SystemPackage", package: "swift-system")],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "PinewindCoreTests",
      dependencies: [
        "PinewindCore",
        .product(name: "BashInterpreter", package: "SwiftBash"),
        .target(name: "Git2"),
      ],
      resources: [.copy("Fixtures")]),
  ] + git2Targets
)
