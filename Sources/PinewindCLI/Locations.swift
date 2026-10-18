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

  func locations() throws -> WorkspaceLocations {
    let defaults = PlatformDirectories()
    let config = FilePath(configDirectory ?? defaults.configuration.string)
    let state = FilePath(stateDirectory ?? defaults.state.string)
    return try WorkspaceLocations(
      userFilesRoot: .path(FilePath(userFiles ?? config.appending("user").string)),
      configuration: ConfigurationFiles(
        manifest: .path(config.appending("pinewind.yaml")),
        localOverrides: .path(state.appending("pinewind.local.yaml")),
        lock: .path(config.appending("pinewind.lock"))),
      stateRoot: state.appending("managed"),
      cacheRoot: FilePath(cacheDirectory ?? defaults.cache.string))
  }

  func open() async throws -> Workspace {
    let locations = try locations()
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
  func directory() throws -> FilePath {
    if let output {
      let path = FilePath(output)
      if path.isAbsolute { return path }
      guard path.root == nil else {
        throw ValidationError("Output must be an absolute path or an unambiguous relative path.")
      }
      return FilePath(FileManager.default.currentDirectoryPath).appending(path.components)
        .lexicallyNormalized()
    }
    return try PlatformDirectories().output(frontend: frontend)
  }
}
