// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ArgumentParser
import Foundation
import PinewindCore
import SystemPackage

extension RimeFrontend: ExpressibleByArgument {}

struct LocationOptions: ParsableArguments {
  @Option(
    help:
      "Directory containing Pinewind's declarations and lock (platform configuration directory by default)."
  )
  var configDirectory: String?
  @Option(help: "Pinewind's machine-local state directory.") var stateDirectory: String?
  @Option(help: "Pinewind's package and resource cache directory.") var cacheDirectory: String?
  @Option(
    help:
      "Personal configuration sources, inserted by self (Pinewind configuration directory/user by default)."
  )
  var userFiles: String?
  @Option(help: "Maximum bytes per downloaded resource (default: 67108864).")
  var maximumResourceBytes: Int?

  func validate() throws {
    if let maximumResourceBytes, maximumResourceBytes <= 0 {
      throw ValidationError("--maximum-resource-bytes must be positive.")
    }
  }

  func locations(in context: CommandContext) throws -> WorkspaceLocations {
    // A fully explicit invocation never needs to discover the host application.
    if configDirectory != nil, stateDirectory != nil, cacheDirectory != nil, userFiles != nil {
      return try PlatformDirectories().workspaceLocations(
        configurationDirectory: configDirectory.map { FilePath($0) },
        stateDirectory: stateDirectory.map { FilePath($0) },
        cacheDirectory: cacheDirectory.map { FilePath($0) },
        userFilesRoot: userFiles.map { .path(FilePath($0)) },
        relativeTo: context.workingDirectory)
    }
    guard let defaults = context.defaultWorkspace else {
      return try PlatformDirectories().workspaceLocations(
        configurationDirectory: configDirectory.map { FilePath($0) },
        stateDirectory: stateDirectory.map { FilePath($0) },
        cacheDirectory: cacheDirectory.map { FilePath($0) },
        userFilesRoot: userFiles.map { .path(FilePath($0)) },
        relativeTo: context.workingDirectory)
    }
    let base = try defaults()
    let configuration = configDirectory.map { FilePath($0) }
    let state = stateDirectory.map { FilePath($0) }
    return try WorkspaceLocations(
      userFilesRoot: userFiles.map { .path(FilePath($0)) }
        ?? configuration.map { .path($0.appending("user")) } ?? base.userFilesRoot,
      configuration: ConfigurationFiles(
        manifest: configuration.map { .path($0.appending("pinewind.yaml")) }
          ?? base.configuration.manifest,
        localOverrides: state.map { .path($0.appending("pinewind.local.yaml")) }
          ?? base.configuration.localOverrides,
        lock: configuration.map { .path($0.appending("pinewind.lock")) }
          ?? base.configuration.lock),
      stateRoot: state?.appending("managed") ?? base.stateRoot,
      cacheRoot: cacheDirectory.map { FilePath($0) } ?? base.cacheRoot,
      relativeTo: context.workingDirectory)
  }

  func open(in context: CommandContext) async throws -> Workspace {
    let locations = try locations(in: context)
    if case .path(let user) = locations.userFilesRoot {
      try FileManager.default.createDirectory(
        at: URL(filePath: user.string, directoryHint: .isDirectory),
        withIntermediateDirectories: true)
    }
    var options = WorkspaceOptions()
    if let maximumResourceBytes { options.maximumResourceBytes = maximumResourceBytes }
    return try await Workspace.open(locations: locations, options: options)
  }
}

struct OutputOptions: ParsableArguments {
  @Option(help: "Rime frontend whose user configuration directory receives the build.")
  var frontend: RimeFrontend?
  @Option(name: .shortAndLong, help: "Override the Rime configuration output directory.")
  var output: String?
  func directory(in context: CommandContext) throws -> FilePath {
    if let output {
      let path = FilePath(output)
      if path.isAbsolute { return path }
      guard path.root == nil else {
        throw ValidationError("Output must be an absolute path or an unambiguous relative path.")
      }
      return context.workingDirectory.appending(path.components)
        .lexicallyNormalized()
    }
    if let frontend { return try PlatformDirectories().output(frontend: frontend) }
    if let directory = context.defaultOutput {
      let path = try directory()
      if path.isAbsolute { return path }
      guard path.root == nil else {
        throw ValidationError("Output must be an absolute path or an unambiguous relative path.")
      }
      return context.workingDirectory.appending(path.components).lexicallyNormalized()
    }
    return try PlatformDirectories().output(frontend: nil)
  }
}
