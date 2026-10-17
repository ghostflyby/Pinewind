// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(macOS) || os(Linux) || os(Windows)
  import Foundation
  import PinewindCore
  import SystemPackage
  import Testing

  @testable import PinewindCLI

  private struct CommandFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pinewind-cli-" + UUID().uuidString)
    var config: URL { root.appendingPathComponent("config") }
    var output: URL { root.appendingPathComponent("Rime") }
    var user: URL { root.appendingPathComponent("personal") }
    var manifest: URL { config.appendingPathComponent("pinewind.yaml") }
    var lock: URL { config.appendingPathComponent("pinewind.lock") }
    var options: [String] {
      [
        "--config-directory", config.path, "--state-directory",
        root.appendingPathComponent("state").path,
        "--cache-directory", root.appendingPathComponent("cache").path, "--user-files", user.path,
      ]
    }
    init() throws {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func fixture(_ path: String) throws -> URL {
      try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        .appendingPathComponent(path)
    }
    func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
      #if os(Windows)
        let name = "pinewind.exe"
      #else
        let name = "pinewind"
      #endif
      var directory = Bundle.module.bundleURL
      var found: URL?
      for _ in 0..<10 {
        let candidate = directory.appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
          found = candidate
          break
        }
        directory.deleteLastPathComponent()
      }
      let executable = try #require(found, "Cannot locate the built CLI beside the test products")
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      try process.run()
      let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
    }
  }

  @Suite("Command-line consumer", .timeLimit(.minutes(1)))
  struct CLITests {
    @Test func addPreparesBuildIsSeparateAndUserSourcesOverridePackages() throws {
      let f = try CommandFixture()
      defer { f.remove() }
      try FileManager.default.createDirectory(at: f.user, withIntermediateDirectories: true)
      try FileManager.default.copyItem(
        at: f.fixture("Personal/default.yaml"), to: f.user.appendingPathComponent("default.yaml"))
      try FileManager.default.createDirectory(
        at: f.output.appendingPathComponent("words.userdb"), withIntermediateDirectories: true)
      let runtime = f.output.appendingPathComponent("words.userdb/data")
      try Data("runtime".utf8).write(to: runtime)
      let added = try f.run(["add", f.fixture("Package").path, "--name", "sample"] + f.options)
      #expect(added.status == 0, "\(added.output)")
      #expect(FileManager.default.fileExists(atPath: f.lock.path))
      #expect(
        !FileManager.default.fileExists(
          atPath: f.output.appendingPathComponent("default.yaml").path))
      let manifest = try ManifestDocument.parse(String(contentsOf: f.manifest, encoding: .utf8))
      #expect(manifest.order == [.named("sample"), .userFiles(FileFilter())])
      let built = try f.run(["build", "--output", f.output.path] + f.options)
      #expect(built.status == 0, "\(built.output)")
      #expect(
        try Data(contentsOf: f.output.appendingPathComponent("default.yaml"))
          == Data(contentsOf: f.fixture("Personal/default.yaml")))
      #expect(try String(contentsOf: runtime, encoding: .utf8) == "runtime")
      let removed = try f.run(["remove", "sample"] + f.options)
      #expect(removed.status == 0, "\(removed.output)")
      #expect(
        try ManifestDocument.parse(String(contentsOf: f.manifest, encoding: .utf8)).names.isEmpty)
      #expect(try String(contentsOf: runtime, encoding: .utf8) == "runtime")
    }

    @Test func preparationFailureRetainsResolvedDependencyAndInstallRetries() throws {
      let f = try CommandFixture()
      defer { f.remove() }
      let package = f.root.appendingPathComponent("package")
      try FileManager.default.copyItem(at: f.fixture("Invalid"), to: package)
      let result = try f.run(["add", package.path, "--name", "broken"] + f.options)
      #expect(result.status != 0)
      #expect(result.output.contains("retained"))
      #expect(result.output.contains("pinewind install"))
      #expect(
        try ManifestDocument.parse(String(contentsOf: f.manifest, encoding: .utf8)).names["broken"]
          != nil)
      #expect(FileManager.default.fileExists(atPath: f.lock.path))
      let lock = try Data(contentsOf: f.lock)
      try FileManager.default.removeItem(at: package.appendingPathComponent("recipe.yaml"))
      try FileManager.default.copyItem(
        at: f.fixture("Package/recipe.yaml"), to: package.appendingPathComponent("recipe.yaml"))
      try FileManager.default.copyItem(
        at: f.fixture("Package/default.yaml"), to: package.appendingPathComponent("default.yaml"))
      let installed = try f.run(["install", "--locked"] + f.options)
      #expect(installed.status == 0, "\(installed.output)")
      #expect(try Data(contentsOf: f.lock) == lock)
      let duplicate = try f.run(["add", package.path, "--name", "broken"] + f.options)
      #expect(duplicate.status != 0)
      #expect(try Data(contentsOf: f.lock) == lock)
      let removed = try f.run(["remove", "broken"] + f.options)
      #expect(removed.status == 0, "\(removed.output)")
    }

    @Test func buildRejectsRuntimeInputsBeforePublishing() throws {
      let f = try CommandFixture()
      defer { f.remove() }
      try FileManager.default.createDirectory(at: f.user, withIntermediateDirectories: true)
      try Data("runtime".utf8).write(to: f.user.appendingPathComponent("user.yaml"))
      let result = try f.run(["build", "--output", f.output.path] + f.options)
      #expect(result.status != 0)
      #expect(result.output.contains("Rime runtime data"))
      #expect(!FileManager.default.fileExists(atPath: f.output.path))
    }

    @Test func invalidArgumentsDoNotWriteConfigurationAndPathsIsReadOnly() throws {
      let f = try CommandFixture()
      defer { f.remove() }
      let result = try f.run(["add", "emoji", "--before", "self", "--after", "self"] + f.options)
      #expect(result.status != 0)
      #expect(result.output.contains("mutually exclusive"))
      #expect(!FileManager.default.fileExists(atPath: f.config.path))
      let paths = try f.run(["paths", "--output", f.output.path] + f.options)
      #expect(paths.status == 0, "\(paths.output)")
      #expect(paths.output.contains("Manifest: " + FilePath(f.manifest.path).string))
      #expect(paths.output.contains("Rime output: " + FilePath(f.output.path).string))
      #expect(!FileManager.default.fileExists(atPath: f.config.path))
    }

    @Test func platformDefaultsAreIndependentOfTheWorkingDirectory() {
      let home = FilePath(FileManager.default.temporaryDirectory.path).appending("pinewind-home")
      let paths = PlatformDirectories(environment: [:], home: home)
      #if os(macOS)
        #expect(paths.configuration == home.appending("Library/Application Support/Pinewind"))
        #expect(paths.cache == home.appending("Library/Caches/Pinewind"))
      #elseif os(Windows)
        #expect(paths.configuration == home.appending("AppData/Roaming/Pinewind"))
        #expect(paths.cache == home.appending("AppData/Local/Pinewind/Cache"))
      #else
        #expect(paths.configuration == home.appending(".config/pinewind"))
        #expect(paths.state == home.appending(".local/state/pinewind"))
        #expect(paths.cache == home.appending(".cache/pinewind"))
        let configured = PlatformDirectories(
          environment: [
            "XDG_CONFIG_HOME": home.appending("config").string, "XDG_CACHE_HOME": "relative",
          ], home: home)
        #expect(configured.configuration == home.appending("config/pinewind"))
        #expect(configured.cache == paths.cache)
      #endif
      #expect(paths.rimeDirectory(.squirrel) == home.appending("Library/Rime"))
      #expect(paths.rimeDirectory(.fcitx5) == home.appending(".local/share/fcitx5/rime"))
    }
  }
#endif
