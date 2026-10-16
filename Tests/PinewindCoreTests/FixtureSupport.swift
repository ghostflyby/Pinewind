// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage
import Testing

@testable import PinewindCore

func native(_ url: URL) -> FilePath { try! NativePath.from(url) }
func fixtureLocations(input: URL, local: URL) throws -> WorkspaceLocations {
  try WorkspaceLocations(
    userFilesRoot: .fileURL(input),
    configuration: ConfigurationFiles(
      manifest: .fileURL(input.appendingPathComponent("pinewind.yaml")),
      localOverrides: .fileURL(local.appendingPathComponent("pinewind.local.yaml")),
      lock: .fileURL(input.appendingPathComponent("pinewind.lock"))),
    stateRoot: native(local.appendingPathComponent("coordination")),
    cacheRoot: native(local.appendingPathComponent("cache")))
}
func loadConfiguration(
  inputRoot: URL, localStateRoot: URL, coordinator: (any FileAccessCoordinating)? = nil
) async throws -> ConfigurationSession {
  let store = ConfigurationStore(
    try fixtureLocations(input: inputRoot, local: localStateRoot), coordinator: coordinator)
  return ConfigurationSession(snapshot: try await store.load(), store: store)
}

func configurationSnapshot(_ document: ManifestDocument) throws -> ConfigurationSnapshot {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  return ConfigurationSnapshot(
    manifest: document, localOverrides: nil,
    sharedRevision: 0, localRevision: 0, sharedIsDirty: false, localIsDirty: false,
    locations: try fixtureLocations(
      input: root.appendingPathComponent("input"), local: root.appendingPathComponent("local")),
    baseline: DocumentBaseline(shared: nil, local: nil, lock: nil))
}

func fixtureURL(_ path: String) throws -> URL {
  let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
  return root.appendingPathComponent(path)
}
func fixtureText(_ path: String) throws -> String {
  try String(contentsOf: fixtureURL(path), encoding: .utf8)
}
extension PinnedResource {
  init(url: URL, path: String, sha256: String) throws {
    try self.init(url: url, path: RelativePath(path), sha256: sha256)
  }
}
extension PreparedPackage {
  init(
    request: PackageRequest, directory: URL, commit: CommitID? = nil,
    resources: [PinnedResource] = []
  ) throws {
    try self.init(
      request: request, directory: NativePath.from(directory), commit: commit, resources: resources)
  }
}
extension CompositionPlanner {
  init(snapshotRoot: URL) { self.init(snapshotRoot: native(snapshotRoot)) }
  func plan(_ manifest: EvaluatedManifest, inputRoot: URL, packages: [PreparedPackage] = []) throws
    -> CompositionPlan
  {
    let metadata = ["pinewind.yaml", "pinewind.local.yaml", "pinewind.lock"].map {
      native(inputRoot.appendingPathComponent($0))
    }
    return try plan(
      manifest, inputRoot: NativePath.from(inputRoot), packages: packages, excluding: metadata)
  }
}
extension Composer {
  func compose(_ plan: CompositionPlan, inputRoot: URL, outputRoot: URL) async throws
    -> CompositionResult
  {
    try await BlockingIO.run {
      try compose(
        plan, inputRoot: NativePath.from(inputRoot), outputRoot: NativePath.from(outputRoot))
    }
  }
}
extension PlumImporter {
  func expand(_ manifest: EvaluatedManifest, inputRoot: URL) async throws -> EvaluatedManifest {
    try await expand(manifest, inputRoot: NativePath.from(inputRoot))
  }
  func evaluate(_ request: ConfImport, inputRoot: URL) async throws -> [String] {
    try await evaluate(request, inputRoot: NativePath.from(inputRoot))
  }
}
extension SafePath {
  static func files(in root: URL) throws -> [RelativePath] { try files(in: NativePath.from(root)) }
}

extension SafePath {
  static func validateRoots(input: URL, output: URL, sources: [URL]) throws {
    try validateRoots(
      input: NativePath.from(input), output: NativePath.from(output),
      sources: sources.map { try NativePath.from($0) })
  }
}

#if os(Windows)
  extension WindowsDirectoryPublisher {
    static func validate(_ output: URL) throws { try validate(NativePath.from(output)) }
    static func currentTarget(_ output: URL) throws -> FilePath? {
      try currentTarget(NativePath.from(output))
    }
    static func redirect(_ output: URL, to candidate: URL) throws {
      try redirect(NativePath.from(output), to: NativePath.from(candidate))
    }
  }
#endif
