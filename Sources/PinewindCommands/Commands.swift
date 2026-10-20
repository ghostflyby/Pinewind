// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ArgumentParser
import Foundation
import PinewindCore
import SystemPackage

struct Pinewind: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pinewind", abstract: "Manage Rime packages and build configuration.",
    discussion:
      "Pinewind uses platform user directories. Install prepares dependencies; build publishes configuration to your Rime frontend without accessing the network.",
    subcommands: [
      Add.self, Remove.self, Install.self, Update.self, Build.self, Lint.self, Paths.self,
    ])
}

struct Add: HostedCommand {
  static let configuration = CommandConfiguration(
    abstract: "Add, resolve, and prepare a dependency without building.")
  @OptionGroup var locations: LocationOptions
  @Argument(help: "HTTPS Git URL, owner/repository, Rime package name, or local directory.")
  var source: String
  @Option(help: "Dependency name (derived from the source by default).") var name: String?
  @Option(help: "Git branch to follow.") var branch: String?
  @Option(help: "Git tag to select.") var tag: String?
  @Option(help: "Git reference to select.") var ref: String?
  @Option(help: "Full Git commit ID to pin.") var commit: String?
  @Option(help: "Named recipe to apply.") var recipe: String?
  @Option(
    name: .customLong("option"), parsing: .singleValue,
    help: "Recipe argument KEY=VALUE; repeat for multiple arguments.")
  var arguments: [String] = []
  @Option(help: "Include glob; repeat for multiple patterns.") var include: [String] = []
  @Option(help: "Exclude glob; repeat for multiple patterns.") var exclude: [String] = []
  @Option(help: "Insert before this active dependency name or self.") var before: String?
  @Option(help: "Insert after this active dependency name or self.") var after: String?

  mutating func validate() throws {
    guard before == nil || after == nil else {
      throw ValidationError("--before and --after are mutually exclusive.")
    }
    guard [branch, tag, ref, commit].compactMap({ $0 }).count <= 1 else {
      throw ValidationError("Choose only one of --branch, --tag, --ref, or --commit.")
    }
    _ = try dependency()
  }

  func dependency() throws -> (revision: GitRevision?, options: [String: String]) {
    var options: [String: String] = [:]
    for argument in arguments {
      let pair = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2, !pair[0].isEmpty, options[String(pair[0])] == nil else {
        throw ValidationError("Recipe arguments must be unique KEY=VALUE pairs.")
      }
      options[String(pair[0])] = String(pair[1])
    }
    let selection: GitRevision?
    if let branch {
      selection = .branch(branch)
    } else if let tag {
      selection = .tag(tag)
    } else if let ref {
      selection = .reference(ref)
    } else {
      selection = nil
    }
    return (selection, options)
  }

  mutating func run(in context: CommandContext) async throws {
    let dependency = try dependency()
    let insertion: PackageInsertion =
      before.map(PackageInsertion.before)
      ?? after.map(PackageInsertion.after) ?? .beforeUserFiles
    let workspace = try await locations.open(in: context)
    let name = name
    let source = source
    let recipe = recipe
    let commit = commit
    let filter = FileFilter(include: include.isEmpty ? nil : include, exclude: exclude)
    _ = try await workspace.update {
      if let commit {
        $0.addPackage(
          name, source: source, commit: commit,
          recipe: recipe, options: dependency.options, filter: filter, insertion: insertion)
      } else {
        $0.addPackage(
          name, source: source, revision: dependency.revision,
          recipe: recipe, options: dependency.options, filter: filter, insertion: insertion)
      }
    }
    context.print(
      "Added and prepared \(name ?? source). Run '\(context.commandName) build' to apply configuration."
    )
  }
}

struct Remove: HostedCommand {
  static let configuration = CommandConfiguration(
    abstract: "Remove named dependencies and update the lock; keep shared caches.")
  @OptionGroup var locations: LocationOptions
  @Argument(help: "Dependency names to remove.") var names: [String]
  mutating func validate() throws {
    guard !names.isEmpty else { throw ValidationError("Specify at least one dependency name.") }
  }
  mutating func run(in context: CommandContext) async throws {
    let names = Set(names).sorted()
    let workspace = try await locations.open(in: context)
    _ = try await workspace.update(preparation: .deferred) { draft in
      for name in names { draft.removePackage(name) }
    }
    context.print(
      "Removed \(names.joined(separator: ", ")). Run '\(context.commandName) build' to apply configuration."
    )
  }
}

struct Install: HostedCommand {
  static let configuration = CommandConfiguration(
    abstract: "Prepare declared dependencies without building or upgrading matching locks.")
  @OptionGroup var locations: LocationOptions
  @Flag(help: "Require the saved lock to match declarations; do not change the lock.") var locked =
    false
  mutating func run(in context: CommandContext) async throws {
    let workspace = try await locations.open(in: context)
    _ = try await workspace.install(locked: locked)
    context.print(
      "Dependencies are ready. Run '\(context.commandName) build' to apply configuration.")
  }
}

struct Update: HostedCommand {
  static let configuration = CommandConfiguration(
    abstract: "Refresh selected named dependencies, or all dependencies, and prepare them.")
  @OptionGroup var locations: LocationOptions
  @Argument(help: "Dependency names; omit to refresh all packages, imports, and resources.")
  var names: [String] = []
  mutating func run(in context: CommandContext) async throws {
    let workspace = try await locations.open(in: context)
    _ =
      names.isEmpty
      ? try await workspace.refresh()
      : try await workspace.refresh(packagesNamed: Set(names))
    context.print(
      "Dependencies updated and prepared. Run '\(context.commandName) build' to apply configuration."
    )
  }
}

struct Build: HostedCommand {
  static let configuration = CommandConfiguration(
    abstract:
      "Build Rime configuration from locked dependencies and local files, without network access.")
  @OptionGroup var locations: LocationOptions
  @OptionGroup var output: OutputOptions
  @Flag(help: "Allow replacing unmanaged files listed as conflicts in the Rime directory.")
  var force = false
  mutating func run(in context: CommandContext) async throws {
    let publication: PublicationMode
    if output.output == nil, output.frontend == nil, context.defaultOutput != nil {
      if case .directory = context.defaultOutputPublication, force {
        throw CommandFailure(
          "--force is unavailable for this host's directory publication policy. Preserve personal files in your sources before building."
        )
      }
      if case .managedFiles(let overwrite) = context.defaultOutputPublication {
        publication = .managedFiles(overwriteUnmanaged: overwrite || force)
      } else {
        publication = context.defaultOutputPublication
      }
    } else {
      publication = .managedFiles(overwriteUnmanaged: force)
    }
    let directory = try output.directory(in: context)
    let workspace = try await locations.open(in: context)
    let result: CompositionResult
    do {
      result = try await workspace.build(to: directory, publication: publication)
    } catch StateFailure.unmanagedOutputFiles(let directory, let paths) {
      let advice: String
      if case .directory = publication {
        advice =
          "Preserve these files in your personal sources and remove them from the generated directory before retrying."
      } else {
        advice =
          "Preserve these files in your personal sources first, or review the list and use '\(context.commandName) build --force' to replace them."
      }
      throw CommandFailure(
        "Unmanaged files in \(directory.string) were left unchanged:\n"
          + paths.map { "  " + $0.string }.joined(separator: "\n") + "\n" + advice)

    }
    context.print("Built \(result.paths.count) files in \(result.directory.string).")
    func warning(_ text: String) {
      context.standardError(Data((text + "\n").utf8))
    }
    for path in result.preservedPaths { warning("Kept externally modified file: \(path.string)") }
    for path in result.overwrittenUnmanagedPaths {
      warning("Replaced unmanaged file: \(path.string)")
    }
    for value in result.warnings { warning("Warning: \(value)") }
  }
}

struct Lint: HostedCommand {
  static let configuration = CommandConfiguration(
    abstract: "Check original YAML using available local information, without downloading.")
  enum Format: String, ExpressibleByArgument { case text, json }
  @OptionGroup var locations: LocationOptions
  @Option(help: "Output format: text or json.") var format: Format = .text
  mutating func run(in context: CommandContext) async throws {
    var options = WorkspaceOptions()
    if let limit = locations.maximumResourceBytes { options.maximumResourceBytes = limit }
    // Opening a workspace directly avoids creating personal sources just to lint.
    let workspace = try await Workspace.open(
      locations: locations.locations(in: context), options: options)
    let report = try await workspace.lint()
    switch format {
    case .text:
      if report.isValid { context.print("No configuration issues found.") }
      for diagnostic in report.diagnostics { context.print(diagnostic.description) }
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(report)
      context.standardOutput(data + Data([10]))
    }
    if !report.isValid { throw ExitCode.failure }
  }
}

struct Paths: HostedCommand {
  static let configuration = CommandConfiguration(
    abstract: "Show platform locations and the selected Rime output directory.")
  @OptionGroup var locations: LocationOptions
  @OptionGroup var output: OutputOptions
  mutating func run(in context: CommandContext) async throws {
    let value = try locations.locations(in: context)
    func describe(_ location: FileLocation) -> String {
      switch location {
      case .path(let path): return path.string
      case .fileURL(let url): return url.path
      }
    }
    context.print("Manifest: \(describe(value.configuration.manifest))")
    context.print("Lock: \(describe(value.configuration.lock))")
    if let local = value.configuration.localOverrides {
      context.print("Local overrides: \(describe(local))")
    }
    context.print("Personal sources: \(describe(value.userFilesRoot))")
    context.print("State: \(value.stateRoot.string)")
    context.print("Cache: \(value.cacheRoot.string)")
    let label =
      output.output == nil && output.frontend == nil && context.defaultOutput != nil
      ? "Generated output" : "Rime output"
    context.print("\(label): \(try output.directory(in: context).string)")
  }
}

struct CommandFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
