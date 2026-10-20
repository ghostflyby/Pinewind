// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import PinewindCommands
import PinewindCore
import SystemPackage
import Testing

private final class CommandOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  func write(_ bytes: Data) {
    lock.lock()
    defer { lock.unlock() }
    data.append(bytes)
  }
  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: data, as: UTF8.self)
  }
}

private struct HostFixture: Sendable {
  let root = FilePath(FileManager.default.temporaryDirectory.path)
    .appending("pinewind-host-" + UUID().uuidString)
  var locations: WorkspaceLocations {
    get throws {
      try PlatformDirectories().workspaceLocations(
        configurationDirectory: root.appending("config"),
        stateDirectory: root.appending("state"), cacheDirectory: root.appending("cache"),
        userFilesRoot: .path(root.appending("personal")))
    }
  }
  func remove() { try? FileManager.default.removeItem(atPath: root.string) }
  func writeManifest(_ text: String) throws {
    try FileManager.default.createDirectory(
      atPath: root.appending("config").string, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: URL(filePath: root.appending("config/pinewind.yaml").string))
  }
  func runner(_ output: CommandOutput, _ errors: CommandOutput) -> PinewindCommandRunner {
    PinewindCommandRunner(
      commandName: "pteromyini", defaultWorkspace: { try locations },
      defaultOutput: { root.appending("generated") },
      standardOutput: { output.write($0) }, standardError: { errors.write($0) })
  }
}

@Suite("Hosted command consumer")
struct HostedCommandTests {
  @Test func helpAndValidationAreLazyAndUseTheHostName() async {
    for arguments in [
      ["--help"], ["build", "--help"], ["help", "paths"],
      ["add", "emoji", "--branch", "main", "--tag", "v1"], ["--unknown"],
    ] {
      let output = CommandOutput()
      let errors = CommandOutput()
      let runner = PinewindCommandRunner(
        commandName: "pteromyini",
        defaultWorkspace: {
          Issue.record("Help or validation resolved workspace")
          throw CancellationError()
        },
        defaultOutput: {
          Issue.record("Help or validation resolved output")
          throw CancellationError()
        },
        standardOutput: { output.write($0) }, standardError: { errors.write($0) })
      let status = await runner.run(arguments: arguments)
      let text = output.text + errors.text
      #expect(text.contains("pteromyini"))
      #expect(!text.contains("USAGE: pinewind"))
      if arguments.contains("--help") || arguments.first == "help" {
        #expect(status == 0)
        #expect(errors.text.isEmpty)
      } else {
        #expect(status != 0)
        #expect(output.text.isEmpty)
      }
    }
  }

  @Test func pathsUsesInjectedDefaultsWithoutCreatingDirectories() async throws {
    let fixture = HostFixture()
    defer { fixture.remove() }
    let output = CommandOutput()
    let errors = CommandOutput()
    let status = await fixture.runner(output, errors).run(arguments: ["paths"])
    #expect(status == 0)
    #expect(
      output.text.contains("Manifest: " + fixture.root.appending("config/pinewind.yaml").string))
    #expect(output.text.contains("Personal sources: " + fixture.root.appending("personal").string))
    #expect(output.text.contains("State: " + fixture.root.appending("state/managed").string))
    #expect(output.text.contains("Generated output: " + fixture.root.appending("generated").string))
    #expect(errors.text.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.string))
  }

  @Test func explicitFlagsBypassDiscoveryAndResolveRelativeToTheCaller() async {
    let output = CommandOutput()
    let errors = CommandOutput()
    let cwd = FilePath(FileManager.default.currentDirectoryPath)
    let runner = PinewindCommandRunner(
      defaultWorkspace: {
        Issue.record("Explicit workspace resolved host")
        throw CancellationError()
      },
      defaultOutput: {
        Issue.record("Explicit output resolved host")
        throw CancellationError()
      },
      standardOutput: { output.write($0) }, standardError: { errors.write($0) })
    let status = await runner.run(arguments: [
      "paths", "--config-directory", "host-config", "--state-directory", "host-state",
      "--cache-directory", "host-cache", "--user-files", "host-user", "--output", "host-output",
    ])
    #expect(status == 0)
    #expect(output.text.contains("Manifest: " + cwd.appending("host-config/pinewind.yaml").string))
    #expect(output.text.contains("Rime output: " + cwd.appending("host-output").string))
    #expect(!output.text.contains("Generated output:"))
    #expect(errors.text.isEmpty)
  }

  @Test func partialFlagsOverrideOnlyTheirHostDefaults() async throws {
    let fixture = HostFixture()
    defer { fixture.remove() }
    let output = CommandOutput()
    let errors = CommandOutput()
    let configuration = fixture.root.appending("alternative")
    let status = await fixture.runner(output, errors).run(arguments: [
      "paths", "--config-directory", configuration.string, "--output", "./out",
    ])
    #expect(status == 0)
    #expect(output.text.contains("Manifest: " + configuration.appending("pinewind.yaml").string))
    #expect(output.text.contains("Personal sources: " + configuration.appending("user").string))
    #expect(output.text.contains("Cache: " + fixture.root.appending("cache").string))
    #expect(errors.text.isEmpty)
  }

  @Test func explicitFrontendBypassesHostOutput() async throws {
    let fixture = HostFixture()
    let output = CommandOutput()
    let errors = CommandOutput()
    let runner = PinewindCommandRunner(
      defaultWorkspace: { try fixture.locations },
      defaultOutput: {
        Issue.record("Explicit frontend resolved host output")
        throw CancellationError()
      },
      standardOutput: { output.write($0) }, standardError: { errors.write($0) })
    #if os(macOS)
      let frontend = "squirrel"
    #elseif os(Windows)
      let frontend = "weasel"
    #else
      let frontend = "fcitx5"
    #endif
    #expect(await runner.run(arguments: ["paths", "--frontend", frontend]) == 0)
    #expect(output.text.contains("Rime output:"))
    #expect(!output.text.contains("Generated output:"))
    #expect(errors.text.isEmpty)
  }

  @Test func lintJSONFailureHasNoErrorTextAndDoesNotCreatePersonalSources() async throws {
    let fixture = HostFixture()
    defer { fixture.remove() }
    try fixture.writeManifest("version: 1\norder: [missing]\n")
    let output = CommandOutput()
    let errors = CommandOutput()
    let status = await fixture.runner(output, errors).run(arguments: ["lint", "--format", "json"])
    #expect(status == 1)
    #expect(errors.text.isEmpty)
    let report = try #require(
      JSONSerialization.jsonObject(with: Data(output.text.utf8)) as? [String: Any])
    #expect((report["diagnostics"] as? [Any])?.count == 1)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appending("personal").string))
  }

  @Test func installUsesHostNameAndCancellationReturns130() async throws {
    let fixture = HostFixture()
    defer { fixture.remove() }
    try fixture.writeManifest("version: 1\norder: []\n")
    let output = CommandOutput()
    let errors = CommandOutput()
    #expect(await fixture.runner(output, errors).run(arguments: ["install"]) == 0)
    #expect(output.text.contains("Run 'pteromyini build'"))
    #expect(errors.text.isEmpty)
    let cancelled = PinewindCommandRunner(
      defaultWorkspace: { throw CancellationError() },
      standardOutput: { _ in Issue.record("Cancellation printed output") },
      standardError: { _ in Issue.record("Cancellation printed error") })
    #expect(await cancelled.run(arguments: ["install"]) == 130)
  }

  @Test func preparationFailureUsesHostRetryAndKeepsUserErrorText() async throws {
    let fixture = HostFixture()
    defer { fixture.remove() }
    let fixtureURL = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    let package = fixtureURL.appendingPathComponent("Invalid").path
    let output = CommandOutput()
    let errors = CommandOutput()
    let status = await fixture.runner(output, errors).run(arguments: [
      "add", package, "--name", "broken",
    ])
    #expect(status != 0)
    #expect(output.text.isEmpty)
    #expect(errors.text.contains("Run 'pteromyini install' to retry preparation."))
    #expect(!errors.text.contains("Run 'pinewind install'"))
  }

  @Test func hostDirectoryPublicationAndExplicitManagedDestinationStaySeparate() async throws {
    let fixture = HostFixture()
    defer { fixture.remove() }
    try fixture.writeManifest("version: 1\norder: [self]\n")
    let personal = fixture.root.appending("personal")
    try FileManager.default.createDirectory(
      atPath: personal.string, withIntermediateDirectories: true)
    try Data("schema: generated\n".utf8).write(
      to: URL(filePath: personal.appending("default.yaml").string))
    let output = CommandOutput()
    let errors = CommandOutput()
    let generated = fixture.root.appending("generated")
    let runner = PinewindCommandRunner(
      commandName: "pteromyini", defaultWorkspace: { try fixture.locations },
      defaultOutput: { generated }, defaultOutputPublication: .directory,
      standardOutput: { output.write($0) }, standardError: { errors.write($0) })
    #expect(await runner.run(arguments: ["build"]) == 0, "\(errors.text)")
    let foreign = URL(filePath: generated.appending("foreign.yaml").string)
    try Data("personal".utf8).write(to: foreign)
    #expect(await runner.run(arguments: ["build"]) != 0)
    #expect(await runner.run(arguments: ["build", "--force"]) != 0)
    #expect(errors.text.contains("--force is unavailable"))
    #expect(try String(contentsOf: foreign, encoding: .utf8) == "personal")

    let explicit = fixture.root.appending("explicit")
    try FileManager.default.createDirectory(
      atPath: explicit.string, withIntermediateDirectories: true)
    let explicitForeign = URL(filePath: explicit.appending("foreign.yaml").string)
    try Data("personal".utf8).write(to: explicitForeign)
    #expect(await runner.run(arguments: ["build", "--output", explicit.string]) == 0)
    #expect(try String(contentsOf: explicitForeign, encoding: .utf8) == "personal")
  }

  @Test func invalidHostNamesAndCustomCompletionFailWithoutResolvingLocations() async {
    for (name, arguments) in [
      ("bad name", ["paths"]), ("pteromyini", ["--generate-completion-script", "zsh"]),
      ("pteromyini", ["--generate-completion-script=zsh"]),
      ("pteromyini", ["build", "--generate-completion-script", "zsh"]),
    ] {
      let output = CommandOutput()
      let errors = CommandOutput()
      let runner = PinewindCommandRunner(
        commandName: name,
        defaultWorkspace: {
          Issue.record("Invalid host invocation resolved workspace")
          throw CancellationError()
        },
        standardOutput: { output.write($0) }, standardError: { errors.write($0) })
      #expect(await runner.run(arguments: arguments) != 0)
      #expect(output.text.isEmpty)
      #expect(!errors.text.isEmpty)
    }
  }

  @Test func postTerminatorCompletionSpellingIsAPositionalSource() async {
    for source in ["--generate-completion-script", "--generate-completion-script=zsh"] {
      let output = CommandOutput()
      let errors = CommandOutput()
      let runner = PinewindCommandRunner(
        commandName: "pteromyini",
        // Reaching workspace discovery proves Add was parsed and dispatched;
        // cancel before package preparation to avoid accessing any remote source.
        defaultWorkspace: { throw CancellationError() },
        standardOutput: { output.write($0) }, standardError: { errors.write($0) })
      #expect(await runner.run(arguments: ["add", "--", source]) == 130)
      #expect(output.text.isEmpty)
      #expect(errors.text.isEmpty)
    }
  }

  @Test func optionOperandsContainingCompletionSpellingArePreserved() async throws {
    let fixture = HostFixture()
    defer { fixture.remove() }
    let package = fixture.root.appending("source")
    try FileManager.default.createDirectory(
      atPath: package.string, withIntermediateDirectories: true)
    try Data("recipe:\n  args: [KEY, OTHER]\ninstall_files: [default.yaml]\n".utf8)
      .write(to: URL(filePath: package.appending("recipe.yaml").string))
    try Data("schema: test\n".utf8)
      .write(to: URL(filePath: package.appending("default.yaml").string))
    let output = CommandOutput()
    let errors = CommandOutput()
    let runner = fixture.runner(output, errors)
    let status = await runner.run(arguments: [
      "add", package.string, "--name=--generate-completion-script",
      "--option", "KEY=--generate-completion-script",
      "--option=OTHER=--generate-completion-script=zsh",
    ])
    #expect(status == 0, "\(errors.text)")
    let manifest = try ManifestDocument.parse(
      String(
        contentsOf: URL(filePath: fixture.root.appending("config/pinewind.yaml").string),
        encoding: .utf8))
    #expect(
      manifest.names["--generate-completion-script"]?.options
        == .value([
          "KEY": "--generate-completion-script", "OTHER": "--generate-completion-script=zsh",
        ]))
    // The literal name also remains usable by commands accepting positional names.
    #expect(await runner.run(arguments: ["remove", "--", "--generate-completion-script"]) == 0)
    #expect(errors.text.isEmpty)
  }

  @Test func standardDefaultOutputRetainsTheRimeLabel() async throws {
    let fixture = HostFixture()
    let output = CommandOutput()
    let errors = CommandOutput()
    let runner = PinewindCommandRunner(
      defaultWorkspace: { try fixture.locations },
      standardOutput: { output.write($0) }, standardError: { errors.write($0) })
    #if os(macOS) || os(Windows)
      #expect(await runner.run(arguments: ["paths"]) == 0)
      #expect(output.text.contains("Rime output:"))
      #expect(!output.text.contains("Generated output:"))
      #expect(errors.text.isEmpty)
    #else
      // A Linux host may require an explicit frontend, but its label stays stable.
      #expect(await runner.run(arguments: ["paths", "--frontend", "fcitx5"]) == 0)
      #expect(output.text.contains("Rime output:"))
      #expect(!output.text.contains("Generated output:"))
      #expect(errors.text.isEmpty)
    #endif
  }

}
