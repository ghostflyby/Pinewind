// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import PinewindCore
import SystemPackage
import Testing

private actor InspectionBackend: RepositoryProvider, RepositoryReferenceProvider {
  let directory: FilePath
  let commit = try! CommitID(String(repeating: "a", count: 40))
  var prepared = 0
  init(_ directory: FilePath) { self.directory = directory }
  func references(at repository: URL) async throws -> RepositoryReferences {
    RepositoryReferences(
      repository: repository,
      references: [
        .init(name: "refs/heads/main", commit: commit),
        .init(name: "refs/tags/main", commit: commit),
        .init(name: "refs/tags/v1", commit: commit),
      ], defaultBranch: "refs/heads/main")
  }
  func resolve(_ request: RepositoryRequest) async throws -> SourceIdentity {
    try SourceIdentity(url: request.url, commit: commit)
  }
  func prepareSource(_ identity: SourceIdentity, cacheRoot: FilePath) async throws -> SourceSnapshot
  {
    prepared += 1
    return try SourceSnapshot(identity: identity, directory: directory)
  }
}
private actor InspectionDownloads: ResourceDownloader {
  var calls = 0
  func download(_ url: URL, to destination: FilePath, maximumBytes: Int?) async throws {
    calls += 1
    throw NetworkFailure.rejected(status: 503, url: url)
  }
}

@Suite("Public metadata discovery") struct DiscoveryTests {
  @Test func referencesPreserveKindsAndRejectAmbiguousNames() throws {
    let commit = try CommitID(String(repeating: "a", count: 40))
    let repository = URL(string: "https://git.example/team/package")!
    let references = RepositoryReferences(
      repository: repository,
      references: [
        .init(name: "refs/heads/main", commit: commit),
        .init(name: "refs/tags/main", commit: commit),
        .init(name: "refs/tags/v1", commit: commit),
        .init(name: "refs/heads/version", commit: commit),
        .init(name: "refs/heads/refs/heads/main", commit: commit),
      ], defaultBranch: "refs/heads/main")
    #expect(throws: GitFailure.ambiguousReference("main")) { try references.revision(for: "main") }
    #expect(try references.revision(for: "refs/heads/main") == .branch("main"))
    #expect(try references.revision(for: "refs/tags/main") == .tag("main"))
    #expect(try references.revision(for: "v1") == .tag("v1"))
    #expect(try references.revision(for: "version") == .branch("version"))
    #expect(try references.revision(for: "") == .defaultBranch)
    #expect(try references.revision(for: commit.string) == .commit(commit))
    #expect(throws: GitFailure.referenceNotFound("aaaaaaa")) {
      try references.revision(for: "aaaaaaa")
    }
  }

  @Test func sourceAndRecipeDiscoveryDoNotNeedOptionsOrDownloadRecipeResources() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    try Data(
      "recipe: {args: [schema, language=zh, schema]}\ndownload_files: [https://example.com/large-resource]\npatch_files: {output.yaml: '$schema'}\n"
        .utf8
    ).write(to: source.appendingPathComponent("recipe.yaml"))
    try Data("recipe: {Rx: alternate, args: [other]}\n".utf8).write(
      to: source.appendingPathComponent("alternate.recipe.yaml"))
    try Data("recipe: [invalid]\n".utf8).write(
      to: source.appendingPathComponent("broken.recipe.yaml"))
    let base = FilePath(root.path)
    let locations = try WorkspaceLocations(
      userFilesRoot: .path(base.appending("input")),
      configuration: ConfigurationFiles(
        manifest: .path(base.appending("manifest.yaml")), lock: .path(base.appending("lock.yaml"))),
      stateRoot: base.appending("state"), cacheRoot: base.appending("cache"))
    let backend = InspectionBackend(FilePath(source.path))
    let downloads = InspectionDownloads()
    let workspace = try await Workspace.open(
      locations: locations, services: .init(repositories: backend, resources: downloads))
    let request = try RepositoryRequest(url: URL(string: "https://git.example/team/package")!)
    let refs = try await workspace.references(at: request.url)
    #expect(refs.references.count == 3)
    #expect(await backend.prepared == 0)
    let snapshot = try await workspace.source(request)
    let catalog = try await RecipeCatalog.read(in: snapshot.directory)
    #expect(catalog.recipes.count == 2)
    #expect(catalog.diagnostics.count == 1)
    let descriptor = try #require(catalog.recipes.first { $0.name == nil })
    #expect(descriptor.arguments == ["schema", "language"])
    try descriptor.validateOptions(["schema": "rime_ice"])
    #expect(throws: DeclarationFailure.undeclaredOption("unknown")) {
      try descriptor.validateOptions(["unknown": "value"])
    }
    _ = try await workspace.source(request)
    #expect(await backend.prepared == 1)
    #expect(await downloads.calls == 0)
    #expect(!fm.fileExists(atPath: root.appendingPathComponent("manifest.yaml").path))
    #expect(!fm.fileExists(atPath: root.appendingPathComponent("lock.yaml").path))
  }

  @Test func detachedEditsComposeAndRetainTheirOriginalBaselineAndDiagnostics() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(
      at: root.appendingPathComponent("source"), withIntermediateDirectories: true)
    let base = FilePath(root.path)
    let workspace = try await Workspace.open(
      locations: WorkspaceLocations(
        userFilesRoot: .path(base.appending("input")),
        configuration: .init(
          manifest: .path(base.appending("manifest.yaml")), lock: .path(base.appending("lock.yaml"))
        ),
        stateRoot: base.appending("state"), cacheRoot: base.appending("cache")))
    let baseline = try await workspace.configuration()
    let source = root.appendingPathComponent("source").absoluteString
    let first = baseline.editing { $0.addPackage("base", source: source) }
    let second = first.editing { _ in }
    _ = try await workspace.apply(second, preparation: .deferred)
    #expect(try await workspace.configuration().manifest.names["base"] != nil)
    // A new edit based on the original baseline must still reject the intervening apply.
    await #expect(throws: (any Error).self) {
      try await workspace.apply(first, preparation: .deferred)
    }
    let invalid = baseline.editing { $0.removePackage("missing") }
    #expect(invalid.editing { _ in }.validate().count == invalid.validate().count)
    #expect(!invalid.editing { _ in }.validate().isEmpty)
  }

  @Test func nestedRecipeNamesAndInvalidDeclarationsUseTheSameHeaderRules() throws {
    let path = try RelativePath(FilePath("nested/alternate.recipe.yaml"))
    let descriptor = try RecipeDescriptor.parse(
      "recipe: {Rx: nested/alternate, args: [schema=default]}", path: path)
    #expect(descriptor.name == "nested/alternate")
    #expect(descriptor.arguments == ["schema"])
    #expect(throws: (any Error).self) {
      try RecipeDescriptor.parse("recipe: {Rx: alternate}", path: path)
    }
    #expect(throws: (any Error).self) {
      try RecipeDescriptor.parse(
        "recipe: {args: ['=value']}", path: RelativePath(FilePath("recipe.yaml")))
    }
  }
}
