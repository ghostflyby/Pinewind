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
    subcommands: [Add.self, Remove.self, Install.self, Update.self, Build.self, Paths.self])
}

@main
enum EntryPoint {
  static func main() async {
    do {
      var command = try Pinewind.parseAsRoot()
      if var asynchronous = command as? any AsyncParsableCommand {
        try await asynchronous.run()
      } else {
        try command.run()
      }
    } catch is CancellationError {
      Pinewind.exit(withError: ExitCode(130))
    } catch { Pinewind.exit(withError: error) }
  }
}

struct Add: AsyncParsableCommand {
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

  func dependency() throws -> (name: String, request: PackageRequest) {
    var options: [String: String] = [:]
    for argument in arguments {
      let pair = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2, !pair[0].isEmpty, options[String(pair[0])] == nil else {
        throw ValidationError("Recipe arguments must be unique KEY=VALUE pairs.")
      }
      options[String(pair[0])] = String(pair[1])
    }
    let selection: GitRevision
    if let branch {
      selection = .branch(branch)
    } else if let tag {
      selection = .tag(tag)
    } else if let ref {
      selection = .reference(ref)
    } else if let commit {
      selection = .commit(try CommitID(commit))
    } else {
      selection = .defaultBranch
    }
    let packageSource: PackageSource
    let basename: String
    if source.hasPrefix("file:"), let url = URL(string: source) {
      packageSource = .directory(.fileURL(url))
      basename = url.lastPathComponent
    } else if FilePath(source).isAbsolute || source.hasPrefix(".") || source.hasPrefix("~")
      || FileManager.default.fileExists(atPath: source)
    {
      let path = FilePath((source as NSString).expandingTildeInPath)
      packageSource = .directory(.path(path))
      let namingPath =
        path.isAbsolute
        ? path : FilePath(FileManager.default.currentDirectoryPath).appending(path.components)
      basename = namingPath.lexicallyNormalized().lastComponent?.string ?? ""
    } else {
      let url: URL
      if source.contains("://") {
        guard let value = URL(string: source) else {
          throw ValidationError("Invalid repository URL.")
        }
        url = value
      } else {
        let parts = source.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count),
          parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".."
              && $0.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
          })
        else {
          throw ValidationError(
            "Use an HTTPS URL, owner/repository, package name, or local directory.")
        }
        let repository =
          parts.count == 1
          ? "rime/" + (source.hasPrefix("rime-") ? source : "rime-" + source) : source
        url = URL(string: "https://github.com/" + repository)!
      }
      packageSource = .git(try RepositoryRequest(url: url, revision: selection))
      let repository = url.lastPathComponent
      basename = repository.hasSuffix(".git") ? String(repository.dropLast(4)) : repository
    }
    if case .directory = packageSource, [branch, tag, ref, commit].contains(where: { $0 != nil }) {
      throw ValidationError("Local directory dependencies cannot select a Git revision.")
    }
    let derived = basename.hasPrefix("rime-") ? String(basename.dropFirst(5)) : basename
    let name = name ?? derived
    guard !name.isEmpty, name != "self" else {
      throw ValidationError("Provide a nonempty dependency --name other than self.")
    }
    let request = try PackageRequest(
      source: packageSource, recipe: recipe, options: options,
      filter: FileFilter(include: include.isEmpty ? nil : include, exclude: exclude))
    return (name, request)
  }

  mutating func run() async throws {
    let dependency = try dependency()
    let insertion: PackageInsertion =
      before.map(PackageInsertion.before)
      ?? after.map(PackageInsertion.after) ?? .beforeUserFiles
    let workspace = try await locations.open()
    let resolution = try await workspace.resolve(editing: {
      try $0.addPackage(dependency.name, request: dependency.request, insertion: insertion)
    })
    FileHandle.standardError.write(
      Data("Saved dependency declaration and lock. Preparing files…\n".utf8))
    try await prepare(workspace, resolution: resolution)
    print("Added and prepared \(dependency.name). Run 'pinewind build' to apply configuration.")
  }
}

struct Remove: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Remove named dependencies and update the lock; keep shared caches.")
  @OptionGroup var locations: LocationOptions
  @Argument(help: "Dependency names to remove.") var names: [String]
  mutating func validate() throws {
    guard !names.isEmpty else { throw ValidationError("Specify at least one dependency name.") }
  }
  mutating func run() async throws {
    let names = Set(names).sorted()
    let workspace = try await locations.open()
    _ = try await workspace.resolve(editing: { draft in
      for name in names { try draft.removePackage(name) }
    })
    print("Removed \(names.joined(separator: ", ")). Run 'pinewind build' to apply configuration.")
  }
}

struct Install: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Prepare declared dependencies without building or upgrading matching locks.")
  @OptionGroup var locations: LocationOptions
  @Flag(help: "Require the saved lock to match declarations; do not change the lock.") var locked =
    false
  mutating func run() async throws {
    let workspace = try await locations.open()
    let resolution = locked ? nil : try await workspace.resolve()
    try await prepare(workspace, resolution: resolution)
    print("Dependencies are ready. Run 'pinewind build' to apply configuration.")
  }
}

struct Update: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Refresh selected named dependencies, or all dependencies, and prepare them.")
  @OptionGroup var locations: LocationOptions
  @Argument(help: "Dependency names; omit to refresh all packages, imports, and resources.")
  var names: [String] = []
  mutating func run() async throws {
    let workspace = try await locations.open()
    let resolution =
      names.isEmpty
      ? try await workspace.update()
      : try await workspace.update(packagesNamed: Set(names))
    try await prepare(workspace, resolution: resolution)
    print("Dependencies updated and prepared. Run 'pinewind build' to apply configuration.")
  }
}

struct Build: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract:
      "Build Rime configuration from locked dependencies and local files, without network access.")
  @OptionGroup var locations: LocationOptions
  @OptionGroup var output: OutputOptions
  mutating func run() async throws {
    let directory = try output.directory()
    let workspace = try await locations.open()
    let plan = try await workspace.plan(workspace.cachedInputs())
    for path in plan.paths {
      let parts = path.filePath.components.map { $0.string.lowercased() }
      guard let first = parts.first,
        !["build", "sync", "trash", "installation.yaml", "user.yaml"].contains(first),
        !parts.contains(where: { $0.hasSuffix(".userdb") || $0.contains(".userdb.") })
      else {
        throw CommandFailure(
          "Build contains Rime runtime data at '\(path.string)'; remove it from the package or personal sources."
        )
      }
    }
    let result = try await workspace.compose(plan, to: directory, publication: .managedFiles)
    print("Built \(result.paths.count) files in \(result.directory.string).")
    for path in result.preservedPaths { print("Kept externally modified file: \(path.string)") }
  }
}

struct Paths: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Show platform locations and the selected Rime output directory.")
  @OptionGroup var locations: LocationOptions
  @OptionGroup var output: OutputOptions
  mutating func run() throws {
    let value = try locations.locations()
    func describe(_ location: FileLocation) -> String {
      switch location {
      case .path(let path): return path.string
      case .fileURL(let url): return url.path
      }
    }
    print("Manifest: \(describe(value.configuration.manifest))")
    print("Lock: \(describe(value.configuration.lock))")
    if let local = value.configuration.localOverrides {
      print("Local overrides: \(describe(local))")
    }
    print("Personal sources: \(describe(value.userFilesRoot))")
    print("State: \(value.stateRoot.string)")
    print("Cache: \(value.cacheRoot.string)")
    print("Rime output: \(try output.directory().string)")
  }
}

private struct CommandFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

private func prepare(_ workspace: Workspace, resolution: Resolution?) async throws {
  do { _ = try await workspace.fetch(resolution) } catch is CancellationError {
    throw CancellationError()
  } catch {
    let state =
      resolution == nil
      ? "No dependency declarations or lock were changed."
      : "Dependency declarations and lock are retained."
    throw CommandFailure(
      "\(error)\n\(state) Run 'pinewind install' to retry preparation."
    )
  }
}
