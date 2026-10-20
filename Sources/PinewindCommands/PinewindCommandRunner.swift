// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ArgumentParser
import Foundation
import PinewindCore
import SystemPackage

/// Runs Pinewind's command syntax inside another executable without terminating it.
/// Each invocation has its own immutable host configuration and output channels.
public struct PinewindCommandRunner: Sendable {
  public let commandName: String
  private let defaultWorkspace: (@Sendable () throws -> WorkspaceLocations)?
  private let defaultOutput: (@Sendable () throws -> FilePath)?
  private let defaultOutputPublication: PublicationMode
  private let standardOutput: @Sendable (Data) -> Void
  private let standardError: @Sendable (Data) -> Void

  /// Defaults are resolved only after parsing and validation, for commands that need them.
  /// Explicit location options override the corresponding workspace locations; explicit
  /// `--output` or `--frontend` bypasses `defaultOutput` entirely and retains the
  /// standard managed-files publication policy. Names use letters, digits, `.`, `_`
  /// or `-`, and cannot begin with `-`. Completion script generation currently
  /// supports only the default `pinewind` name. A host may choose `.directory`
  /// for its default generated-only output; `--force` is rejected in that mode.
  public init(
    commandName: String = "pinewind",
    defaultWorkspace: (@Sendable () throws -> WorkspaceLocations)? = nil,
    defaultOutput: (@Sendable () throws -> FilePath)? = nil,
    defaultOutputPublication: PublicationMode = .managedFiles(),
    standardOutput: @escaping @Sendable (Data) -> Void = { FileHandle.standardOutput.write($0) },
    standardError: @escaping @Sendable (Data) -> Void = { FileHandle.standardError.write($0) }
  ) {
    self.commandName = commandName
    self.defaultWorkspace = defaultWorkspace
    self.defaultOutput = defaultOutput
    self.defaultOutputPublication = defaultOutputPublication
    self.standardOutput = standardOutput
    self.standardError = standardError
  }

  /// Arguments exclude the executable name. Returns the process exit status for the caller
  /// to handle. Cancellation maps to 130; invalid lint reports retain their normal output.
  public func run(arguments: [String]) async -> Int32 {
    let context = CommandContext(
      commandName: commandName,
      workingDirectory: FilePath(FileManager.default.currentDirectoryPath),
      defaultWorkspace: defaultWorkspace, defaultOutput: defaultOutput,
      defaultOutputPublication: defaultOutputPublication,
      standardOutput: standardOutput, standardError: standardError)
    guard !commandName.isEmpty, commandName.first != "-",
      commandName.utf8.allSatisfy({
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
          || [45, 46, 95].contains($0)
      })
    else {
      return report(
        CommandFailure(
          "Command name must be a nonempty executable name using letters, digits, '.', '_' or '-'."),
        parsing: false)
    }
    if commandName != "pinewind",
      // ArgumentParser checks completion options before subcommand parsing, but
      // treats everything following `--` as positional input. Attached values
      // (for example `--name=--generate-completion-script`) stay ordinary values.
      arguments.prefix(while: { $0 != "--" }).contains(where: {
        $0 == "--generate-completion-script" || $0.hasPrefix("--generate-completion-script=")
      })
    {
      return report(
        CommandFailure(
          "Completion script generation is unavailable for a custom host command name."),
        parsing: false)
    }
    var command: any ParsableCommand
    do {
      command = try Pinewind.parseAsRoot(arguments)
    } catch {
      return report(error, parsing: true)
    }
    do {
      if var hosted = command as? any HostedCommand {
        try await hosted.run(in: context)
      } else if var asynchronous = command as? any AsyncParsableCommand {
        try await asynchronous.run()
      } else {
        try command.run()
      }
      return 0
    } catch is CancellationError {
      return 130
    } catch let error as PreparationFailure {
      return report(
        CommandFailure("\(error) Run '\(commandName) install' to retry preparation."),
        parsing: false)
    } catch {
      return report(error, parsing: !(command is any HostedCommand))
    }
  }

  private func report(_ error: any Error, parsing: Bool) -> Int32 {
    let code = Pinewind.exitCode(for: error).rawValue
    var message = Pinewind.fullMessage(for: error)
    // ArgumentParser's command metadata is static. Rename only its generated usage
    // and help references, never arbitrary error descriptions or user paths.
    if parsing, commandName != "pinewind" {
      // Parser diagnostics can contain user-supplied strings (including newlines).
      // Preserve that entire description and rename only the generated suffix.
      var diagnostic = ""
      let description = Pinewind.message(for: error)
      if code != 0, !description.isEmpty, let range = message.range(of: description) {
        diagnostic = String(message[..<range.upperBound])
        message = String(message[range.upperBound...])
      }
      message =
        diagnostic
        + message.split(separator: "\n", omittingEmptySubsequences: false).map { line in
          let text = String(line)
          if text.hasPrefix("USAGE: pinewind") {
            return text.replacingOccurrences(of: "USAGE: pinewind", with: "USAGE: \(commandName)")
          }
          if text.hasPrefix("Usage: pinewind") {
            return text.replacingOccurrences(of: "Usage: pinewind", with: "Usage: \(commandName)")
          }
          if text.hasPrefix("  See 'pinewind ") || text.hasPrefix("See 'pinewind ") {
            return text.replacingOccurrences(of: "See 'pinewind ", with: "See '\(commandName) ")
          }
          return text
        }.joined(separator: "\n")
    }
    if !message.isEmpty {
      let bytes = Data((message.hasSuffix("\n") ? message : message + "\n").utf8)
      if code == 0 { standardOutput(bytes) } else { standardError(bytes) }
    }
    return code
  }
}

struct CommandContext: Sendable {
  let commandName: String
  let workingDirectory: FilePath
  let defaultWorkspace: (@Sendable () throws -> WorkspaceLocations)?
  let defaultOutput: (@Sendable () throws -> FilePath)?
  let defaultOutputPublication: PublicationMode
  let standardOutput: @Sendable (Data) -> Void
  let standardError: @Sendable (Data) -> Void

  func print(_ text: String) { standardOutput(Data((text + "\n").utf8)) }
}

protocol HostedCommand: AsyncParsableCommand {
  mutating func run(in context: CommandContext) async throws
}

extension HostedCommand {
  mutating func run() async throws {
    // Public consumers use the runner so configuration is always passed explicitly.
    throw CommandFailure("Run this command through PinewindCommandRunner.")
  }
}
