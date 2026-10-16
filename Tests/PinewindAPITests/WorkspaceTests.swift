// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import PinewindCore
import SystemPackage
import Testing

private func url(_ path: FilePath) -> URL {
  URL(filePath: path.string, directoryHint: .notDirectory)
}
private func fixtureText(_ path: String) throws -> String {
  let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
  return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}
private func write(_ path: FilePath, _ text: String) throws {
  try FileManager.default.createDirectory(
    at: url(path.removingLastComponent()), withIntermediateDirectories: true)
  try Data(text.utf8).write(to: url(path))
}
private func read(_ path: FilePath) throws -> String {
  try String(contentsOf: url(path), encoding: .utf8)
}
private func exists(_ path: FilePath) -> Bool {
  FileManager.default.fileExists(atPath: path.string)
}
private let firstID = String(repeating: "a", count: 40)
private let secondID = String(repeating: "b", count: 40)
private let endpoint = URL(string: "https://example.com/team/package.git")!

private actor Repositories: RepositoryProvider {
  let root: FilePath
  var current: CommitID
  var resolutions = 0
  var preparations = 0
  private var pause = false
  private var started = false
  private var continuation: CheckedContinuation<Void, Never>?
  init(root: FilePath) throws {
    self.root = root
    current = try CommitID(firstID)
  }
  func install(_ commit: String, files: [String: String]) throws {
    current = try CommitID(commit)
    for (path, text) in files { try write(root.appending(commit).appending(path), text) }
  }
  func resolve(_ request: RepositoryRequest) async throws -> SourceIdentity {
    resolutions += 1
    if pause {
      started = true
      await withCheckedContinuation { continuation = $0 }
    }
    return try SourceIdentity(url: request.url, commit: current)
  }
  func prepareSource(_ identity: SourceIdentity, cacheRoot: FilePath) async throws -> SourceSnapshot
  {
    preparations += 1
    return try SourceSnapshot(identity: identity, directory: root.appending(identity.commit.string))
  }
  func counts() -> (Int, Int) { (resolutions, preparations) }
  func pauseNext() { pause = true }
  func didStart() -> Bool { started }
  func release() {
    pause = false
    continuation?.resume()
    continuation = nil
  }
}
private actor Downloads: ResourceDownloader {
  var files: [URL: Data] = [:]
  var calls = 0
  func set(_ endpoint: URL, _ text: String) { files[endpoint] = Data(text.utf8) }
  func download(_ endpoint: URL, to destination: FilePath, maximumBytes: Int?) async throws {
    calls += 1
    guard let bytes = files[endpoint] else {
      throw PinewindError.runtime(.network(.rejected(status: 404, url: endpoint)))
    }
    try FileManager.default.createDirectory(
      at: url(destination.removingLastComponent()), withIntermediateDirectories: true)
    try bytes.write(to: url(destination))
  }
  func count() -> Int { calls }
}
private struct Fixture {
  let root: FilePath
  let locations: WorkspaceLocations
  let repositories: Repositories
  let downloads = Downloads()
  var input: FilePath { root.appending("user files") }
  var manifest: FilePath { root.appending("cloud A/configuration.yaml") }
  var overrides: FilePath { root.appending("machine/settings.yaml") }
  var lock: FilePath { root.appending("cloud B/resolved.lock") }
  var output: FilePath { root.appending("published") }
  init(local: Bool = true, colocatedManifest: Bool = false) throws {
    root = FilePath(
      FileManager.default.temporaryDirectory.appendingPathComponent(
        "pinewind-api-" + UUID().uuidString
      ).path)
    let input = root.appending("user files")
    let manifest = root.appending(
      colocatedManifest ? "user files/nested/custom.yaml" : "cloud A/configuration.yaml")
    locations = try WorkspaceLocations(
      userFilesRoot: .fileURL(url(input)),
      configuration: ConfigurationFiles(
        manifest: .fileURL(url(manifest)),
        localOverrides: local ? .fileURL(url(root.appending("machine/settings.yaml"))) : nil,
        lock: .fileURL(url(root.appending("cloud B/resolved.lock")))),
      stateRoot: root.appending("state"), cacheRoot: root.appending("cache"))
    repositories = try Repositories(root: root.appending("repository fixtures"))
    try FileManager.default.createDirectory(at: url(input), withIntermediateDirectories: true)
  }
  func remove() { try? FileManager.default.removeItem(at: url(root)) }
  func workspace() async throws -> Workspace {
    try await Workspace.open(
      locations: locations,
      services: WorkspaceServices(repositories: repositories, resources: downloads))
  }
  func remote(recipe: String? = nil, duplicate: Bool = false) throws {
    let fields = recipe.map { "\n    recipe: \($0)" } ?? ""
    try write(
      manifest,
      "version: 1\nnames:\n  package:\n    url: \(endpoint.absoluteString)\n    revision: {branch: main}\(fields)\norder: [package\(duplicate ? ", package" : ""), self]\n"
    )
  }
}

@Suite("Public Workspace API", .timeLimit(.minutes(1)))
struct WorkspaceTests {
  #if !os(Windows)
    @Test func publicationThroughDirectoryAliasKeepsTheAliasAndUpdatesItsTarget() async throws {
      let f = try Fixture()
      defer { f.remove() }
      try write(f.input.appending("schema.yaml"), "value: first\n")
      let workspace = try await f.workspace()
      _ = try await workspace.compose(to: f.output)
      let alias = f.root.appending("output alias")
      try FileManager.default.createSymbolicLink(at: url(alias), withDestinationURL: url(f.output))
      try write(f.input.appending("schema.yaml"), "value: next\n")
      _ = try await workspace.compose(to: alias)
      #expect(try read(f.output.appending("schema.yaml")) == "value: next\n")
      #expect(try url(alias).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }
  #endif
  @Test func publicationCannotReplaceManagedStorageOrItsChildren() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try write(f.input.appending("schema.yaml"), "value: local\n")
    try write(f.locations.stateRoot.appending("keep"), "state")
    try write(f.locations.cacheRoot.appending("keep"), "cache")
    let workspace = try await f.workspace()
    let plan = try await workspace.plan(workspace.cachedInputs())
    for root in [f.locations.stateRoot, f.locations.cacheRoot] {
      for output in [root, root.appending("child")] {
        do {
          _ = try await workspace.compose(plan, to: output)
          Issue.record("managed storage was accepted as a publication target")
        } catch {
          guard let error = error as? PinewindError,
            case .runtime(.file(.overlappingPaths)) = error
          else {
            Issue.record("unexpected error: \(error)")
            continue
          }
        }
      }
    }
    #expect(try read(f.locations.stateRoot.appending("keep")) == "state")
    #expect(try read(f.locations.cacheRoot.appending("keep")) == "cache")
  }
  @Test func independentLocationsAndPureLocalComposition() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try write(f.input.appending("schema.yaml"), "value: local\n")
    try write(f.input.appending("pinewind.yaml"), "ordinary user file")
    let workspace = try await f.workspace()
    let result = try await workspace.compose(to: f.output)
    #expect(try read(result.directory.appending("schema.yaml")) == "value: local\n")
    #expect(result.paths.map(\.string) == ["pinewind.yaml", "schema.yaml"])
    #expect(!exists(f.lock))
    #expect(await f.repositories.counts().0 == 0)
    #expect(await f.downloads.count() == 0)
  }
  @Test func configuredMetadataExcludedAtArbitraryNestedPath() async throws {
    let f = try Fixture(colocatedManifest: true)
    defer { f.remove() }
    let manifest = f.root.appending("user files/nested/custom.yaml")
    try write(manifest, "version: 1\norder: [self]\n")
    try write(f.input.appending("nested/data.yaml"), "value: user")
    let workspace = try await f.workspace()
    #expect(try await workspace.compose(to: f.output).paths.map(\.string) == ["nested/data.yaml"])
  }
  @Test func explicitRelativeBaseAndDisabledOverrides() async throws {
    let f = try Fixture(local: false)
    defer { f.remove() }
    let captured = FilePath(FileManager.default.currentDirectoryPath)
    let implicit = try WorkspaceLocations(
      userFilesRoot: .path("input"),
      configuration: ConfigurationFiles(manifest: .path("manifest"), lock: .path("lock")),
      stateRoot: "state", cacheRoot: "cache")
    #expect(implicit.relativeTo == captured)
    #expect(implicit.stateRoot == captured.appending("state"))
    #expect(implicit.cacheRoot == captured.appending("cache"))
    if case .path(let input) = implicit.userFilesRoot {
      #expect(input == captured.appending("input"))
    } else {
      Issue.record("native user path changed representation")
    }
    let identity = try SourceIdentity(
      url: #require(URL(string: "https://example.com/repository")),
      commit: CommitID(String(repeating: "a", count: 40)))
    #expect(
      try SourceSnapshot(identity: identity, directory: "source").directory
        == captured.appending("source"))
    let local = try PackageRequest(source: .directory(.path("package")))
    #expect(local.source == .directory(.path(captured.appending("package"))))
    let incompleteURL = try #require(URL(string: "file:relative"))
    #expect(throws: FileSystemFailure.self) {
      _ = try PackageRequest(source: .directory(.fileURL(incompleteURL)))
    }
    let locations = try WorkspaceLocations(
      userFilesRoot: .path("input"),
      configuration: ConfigurationFiles(
        manifest: .path("shared/config.yaml"), lock: .path("separate/lock")), stateRoot: "state",
      cacheRoot: "cache", relativeTo: f.root)
    try write(f.root.appending("input/schema.yaml"), "test")
    let workspace = try await Workspace.open(locations: locations)
    let session = try await workspace.configuration()
    await session.edit { $0.localOverrides = LocalOverridesDocument() }
    await #expect(throws: PinewindError.self) { _ = try await session.save(.local) }
    let result = try await workspace.compose(to: "relative-output")
    #expect(exists(result.directory))
    #expect(exists(f.root.appending("relative-output")))
  }
  @Test func snapshotEditingSavingAndReloadAreExplicit() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let workspace = try await f.workspace()
    let session = try await workspace.configuration()
    await session.edit { $0.manifest.order = [] }
    #expect(await session.snapshot().sharedIsDirty)
    await #expect(throws: PinewindError.self) { try await session.reload() }
    let receipt = try await session.save(.shared)
    #expect(receipt.revision == 1)
    #expect(await session.snapshot().sharedIsDirty == false)
    await session.edit { $0.localOverrides = LocalOverridesDocument() }
    #expect(await session.snapshot().localIsDirty)
    _ = try await session.save(.local)
    #expect(exists(f.overrides))
    await session.edit { $0.localOverrides = nil }
    _ = try await session.save(.local)
    #expect(!exists(f.overrides))
    await session.edit { $0.manifest.order = [.userFiles(FileFilter())] }
    try await session.discardChangesAndReload()
    #expect(await session.snapshot().manifest.order.isEmpty)
  }
  @Test func previewDoesNotWriteSharedDocumentsOrLock() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(firstID, files: ["default.yaml": "value: preview"])
    let workspace = try await f.workspace()
    let session = try await workspace.configuration()
    let request = try PackageRequest(
      source: .git(RepositoryRequest(url: endpoint, revision: .branch("main"))))
    try await session.edit { try $0.addPackage("package", request: request) }
    let snapshot = await session.snapshot()
    let resolution = try await workspace.resolve(preview: snapshot)
    let inputs = try await workspace.fetch(resolution)
    let plan = try await workspace.plan(inputs)
    #expect(try await workspace.compose(plan, to: f.output).paths.map(\.string) == ["default.yaml"])
    #expect(!exists(f.manifest))
    #expect(!exists(f.lock))
    #expect(await session.snapshot().sharedIsDirty)
  }
  @Test func savedOperationsIgnoreUnsavedDraftsAndDetectStalePublication() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try write(f.input.appending("schema.yaml"), "value: saved")
    let workspace = try await f.workspace()
    let session = try await workspace.configuration()
    _ = try await session.save(.shared)
    let inputs = try await workspace.cachedInputs()
    let plan = try await workspace.plan(inputs)
    await session.edit { $0.manifest.order = [] }
    #expect(try await workspace.compose(to: f.output).paths.count == 1)
    _ = try await session.save(.shared)
    await #expect(throws: PinewindError.self) {
      _ = try await workspace.compose(plan, to: f.output)
    }
    #expect(try read(f.output.appending("schema.yaml")) == "value: saved")
  }
  @Test func sourceResolutionDeduplicatesAndCachedCompositionIsOffline() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(firstID, files: ["default.yaml": "value: first"])
    try f.remote(duplicate: true)
    let workspace = try await f.workspace()
    await #expect(throws: PinewindError.self) { _ = try await workspace.compose(to: f.output) }
    let resolution = try await workspace.resolve()
    #expect(resolution.packages.count == 1)
    #expect(await f.repositories.counts().0 == 1)
    _ = try await workspace.fetch(resolution)
    let before = await f.repositories.counts()
    _ = try await workspace.compose(to: f.output)
    let after = await f.repositories.counts()
    #expect(before.0 == after.0 && before.1 == after.1)
    #expect(try read(f.output.appending("default.yaml")) == "value: first")
    let plan = try await workspace.plan(workspace.cachedInputs())
    #expect(try plan.contributions(for: RelativePath("default.yaml")).count == 2)
    #expect(
      try plan.contributions(for: RelativePath("default.yaml")).allSatisfy { $0.source == endpoint }
    )
  }
  @Test func resolvePreservesMatchingPinsWhileUpdateAdvances() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(firstID, files: ["default.yaml": "first"])
    try f.remote()
    let workspace = try await f.workspace()
    _ = try await workspace.resolve()
    try await f.repositories.install(secondID, files: ["default.yaml": "second"])
    #expect(try await workspace.resolve().packages.first?.commit.string == firstID)
    let session = try await workspace.configuration()
    await session.edit { $0.manifest.order.insert(.userFiles(FileFilter()), at: 0) }
    _ = try await session.save(.shared)
    #expect(try await workspace.resolve().packages.first?.commit.string == firstID)
    #expect(try await workspace.update().packages.first?.commit.string == secondID)
  }
  @Test func resourcesArePreparedPinnedAndUpdatedIndependently() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let resource = URL(string: "https://resources.test/extra.txt")!
    await f.downloads.set(resource, "first")
    try await f.repositories.install(
      firstID,
      files: [
        "recipe.yaml":
          try fixtureText("Recipes/explicit-download.recipe.yaml")
      ])
    try f.remote()
    let workspace = try await f.workspace()
    let resolution = try await workspace.resolve()
    #expect(resolution.packages[0].resources.count == 1)
    _ = try await workspace.fetchAndCompose(to: f.output)
    #expect(try read(f.output.appending("extra.txt")) == "first")
    await f.downloads.set(resource, "second")
    #expect(try await workspace.resolve().packages[0].resources == resolution.packages[0].resources)
    let updated = try await workspace.update(.resources(Set(resolution.packages[0].resourceIDs)))
    #expect(updated.packages[0].commit.string == firstID)
    #expect(updated.packages[0].resources != resolution.packages[0].resources)
    _ = try await workspace.compose(to: f.output)
    #expect(try read(f.output.appending("extra.txt")) == "second")
  }
  @Test func checksumFailureRetainsPublishedOutputAndLock() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let resource = URL(string: "https://resources.test/extra.txt")!
    await f.downloads.set(resource, "first")
    try await f.repositories.install(
      firstID,
      files: [
        "recipe.yaml":
          try fixtureText("Recipes/implicit-download.recipe.yaml")
      ])
    try f.remote()
    let workspace = try await f.workspace()
    _ = try await workspace.resolve()
    _ = try await workspace.fetchAndCompose(to: f.output)
    let lock = try Data(contentsOf: url(f.lock))
    try FileManager.default.removeItem(at: url(f.locations.cacheRoot.appending("resources")))
    await f.downloads.set(resource, "changed upstream")
    await #expect(throws: PinewindError.self) {
      _ = try await workspace.fetchAndCompose(to: f.output)
    }
    #expect(try Data(contentsOf: url(f.lock)) == lock)
    #expect(try read(f.output.appending("extra.txt")) == "first")
  }
  @Test func localOverrideIsLiveAtEachPlanAndRequiresNoLocalLock() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(firstID, files: ["default.yaml": "remote"])
    try f.remote()
    let workspace = try await f.workspace()
    _ = try await workspace.resolve()
    let originalLock = try Data(contentsOf: url(f.lock))
    let local = f.root.appending("development")
    try write(local.appending("default.yaml"), "local first")
    let session = try await workspace.configuration()
    try await session.edit { try $0.redirectPackage("package", to: .path(local)) }
    _ = try await session.save(.local)
    let prepared = try await workspace.cachedInputs()
    _ = try await workspace.compose(workspace.plan(prepared), to: f.output)
    try write(local.appending("default.yaml"), "local edited")
    _ = try await workspace.compose(workspace.plan(prepared), to: f.output)
    #expect(try read(f.output.appending("default.yaml")) == "local edited")
    #expect(try Data(contentsOf: url(f.lock)) == originalLock)
    await #expect(throws: PinewindError.self) {
      _ = try await workspace.compose(workspace.plan(prepared), to: local)
    }
  }
  @Test func remoteOverrideRequiresExplicitDevelopmentMode() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(firstID, files: ["default.yaml": "shared"])
    try f.remote()
    let workspace = try await f.workspace()
    _ = try await workspace.resolve()
    let originalLock = try Data(contentsOf: url(f.lock))
    try write(
      f.overrides,
      "version: 1\nnames:\n  package:\n    url: https://other.test/repository\n    revision: {branch: dev}\n"
    )
    await #expect(throws: PinewindError.self) { _ = try await workspace.fetch() }
    _ = try await workspace.fetchAndCompose(to: f.output, mode: .development)
    #expect(try Data(contentsOf: url(f.lock)) == originalLock)
  }
  @Test func remoteConfIncludesAreCapturedAndNotReevaluatedDuringCompose() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let root = URL(string: "https://conf.test/lists/main.conf")!
    let child = URL(string: "https://conf.test/lists/include.conf")!
    await f.downloads.set(root, try fixtureText("RemoteConf/Repeated/main.conf"))
    await f.downloads.set(child, try fixtureText("RemoteConf/Repeated/include.conf"))
    try await f.repositories.install(firstID, files: ["default.yaml": "imported"])
    try write(f.manifest, "version: 1\norder:\n  - import: \(root.absoluteString)\n")
    let workspace = try await f.workspace()
    let resolution = try await workspace.resolve()
    #expect(resolution.imports[0].packages.count == 2)
    #expect(resolution.imports[0].resources.count == 2)
    let before = await f.downloads.count()
    _ = try await workspace.compose(to: f.output)
    #expect(await f.downloads.count() == before)
    #expect(try read(f.output.appending("default.yaml")) == "imported")
  }
  @Test func localConfIsRelativeToManifestRatherThanUserFiles() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(firstID, files: ["default.yaml": "imported"])
    try write(f.manifest, "version: 1\norder: [{import: ./lists/test.conf}]\n")
    try write(
      f.manifest.removingLastComponent().appending("lists/test.conf"),
      "package_list=(rime/example)\n")
    let workspace = try await f.workspace()
    _ = try await workspace.resolve()
    _ = try await workspace.compose(to: f.output)
    #expect(try read(f.output.appending("default.yaml")) == "imported")
  }
  @Test func cancelledCompositionNeverPublishes() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try write(f.input.appending("schema.yaml"), "old")
    let workspace = try await f.workspace()
    _ = try await workspace.compose(to: f.output)
    try write(f.input.appending("schema.yaml"), "new")
    let plan = try await workspace.plan(workspace.cachedInputs())
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await workspace.compose(plan, to: f.output)
    }
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(try read(f.output.appending("schema.yaml")) == "old")
  }
  @Test func resolutionAbortsIfConfigurationChangesDuringNetworkWork() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(firstID, files: ["default.yaml": "remote"])
    try f.remote()
    let workspace = try await f.workspace()
    await f.repositories.pauseNext()
    let task = Task { try await workspace.resolve() }
    while !(await f.repositories.didStart()) { try await Task.sleep(for: .milliseconds(5)) }
    try write(f.manifest, "version: 1\norder: [self]\n")
    await f.repositories.release()
    await #expect(throws: PinewindError.self) { _ = try await task.value }
    #expect(!exists(f.lock))
  }
  @Test func invalidRevisionAndRelativeResourcePathsAreRejected() throws {
    for source in [
      "ref: main", "commit: abc", "revision: {branch: main, commit: abc}",
      "revision: {commit: abc}",
    ] {
      #expect {
        _ = try ManifestDocument.parse(
          "version: 1\norder: [{url: https://example.com/repo, \(source)}]"
        ).evaluate()
      } throws: { ($0 as? PinewindError) != nil || $0 is DeclarationFailure }
    }
    for path in [
      "", "/root", "../outside", "a/../../outside", ".", "a/..", "C:relative",
      "C:/../outside",
    ] {
      #expect(throws: FileSystemFailure.self) { _ = try RelativePath(FilePath(path)) }
    }
    #expect(try RelativePath("词典/emoji 😀.txt").string == "词典/emoji 😀.txt")
    let normalized = try RelativePath(FilePath("a//./nested/../emoji.txt/"))
    #expect(normalized.filePath == FilePath("a/emoji.txt"))
    #expect(normalized.string == "a/emoji.txt")
    #expect(try RelativePath("a/emoji.txt") == normalized)
    #expect(try Set([normalized, RelativePath("a/emoji.txt")]).count == 1)
    let composed = try RelativePath("caf\u{e9}.yaml")
    let decomposed = try RelativePath("cafe\u{301}.yaml")
    #expect(composed != decomposed)
    #expect((composed < decomposed) != (decomposed < composed))
    #if os(Windows)
      #expect(try RelativePath(FilePath("a\\b")).string == "a/b")
      for path in [
        FilePath("C:relative"), FilePath("\\relative"), FilePath("\\\\server\\share\\file"),
      ] {
        #expect(throws: FileSystemFailure.self) { _ = try RelativePath(path) }
      }
    #endif
  }
  @Test func snapshotsCannotBeUsedAcrossWorkspaces() async throws {
    let first = try Fixture()
    let second = try Fixture()
    defer {
      first.remove()
      second.remove()
    }
    let a = try await first.workspace()
    let b = try await second.workspace()
    let session = try await a.configuration()
    let snapshot = await session.snapshot()
    await #expect(throws: PinewindError.self) { _ = try await b.resolve(preview: snapshot) }
  }
  @Test func canonicalRepositoryAliasesResolveOnceAcrossDifferentApplications() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(
      firstID,
      files: [
        "default.yaml": "shared",
        "other.recipe.yaml": try fixtureText("RepositoryAliases/other.recipe.yaml"),
      ])
    try write(f.manifest, fixtureText("RepositoryAliases/manifest.yaml"))
    let workspace = try await f.workspace()
    let resolution = try await workspace.resolve()
    #expect(resolution.packages.count == 2)
    #expect(await f.repositories.counts().0 == 1)
    #expect(resolution.packages.allSatisfy { $0.commit.string == firstID })
  }
  @Test func oldPackageSelectorsAreRejectedAfterVersionUpdate() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(firstID, files: ["default.yaml": "first"])
    try f.remote()
    let workspace = try await f.workspace()
    let first = try await workspace.resolve()
    try await f.repositories.install(secondID, files: ["default.yaml": "second"])
    _ = try await workspace.update(.packages(Set(first.packages.map(\.id))))
    await #expect(throws: PinewindError.self) {
      _ = try await workspace.update(.packages(Set(first.packages.map(\.id))))
    }
  }
  @Test func fixedCommitDoesNotResolveReferencesDuringUpdate() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(firstID, files: ["default.yaml": "fixed"])
    try write(
      f.manifest,
      "version: 1\norder: [{url: \(endpoint.absoluteString), revision: {commit: \(firstID)}}]\n")
    let workspace = try await f.workspace()
    _ = try await workspace.resolve()
    _ = try await workspace.update()
    #expect(await f.repositories.counts().0 == 0)
    #expect(try await workspace.compose(to: f.output).paths.map(\.string) == ["default.yaml"])
  }
  @Test func importUpdatesRejectOldExpansionSelectors() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let remote = URL(string: "https://conf.test/packages.conf")!
    await f.downloads.set(remote, "package_list=(rime/first)\n")
    try await f.repositories.install(firstID, files: ["default.yaml": "imported"])
    try write(f.manifest, "version: 1\norder: [{import: \(remote.absoluteString)}]\n")
    let workspace = try await f.workspace()
    let initial = try await workspace.resolve()
    await f.downloads.set(remote, "package_list=(rime/first rime/second)\n")
    let updated = try await workspace.update(.imports(Set(initial.imports.map(\.id))))
    #expect(updated.imports[0].packages.count == 2)
    await #expect(throws: PinewindError.self) {
      _ = try await workspace.update(.imports(Set(initial.imports.map(\.id))))
    }
  }
  @Test func unsafeRemoteIncludeAndImportLimitsPreserveTheLock() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let remote = URL(string: "https://conf.test/main.conf")!
    await f.downloads.set(remote, "package_list=(rime/first)\n")
    try await f.repositories.install(firstID, files: ["default.yaml": "imported"])
    try write(f.manifest, "version: 1\norder: [{import: \(remote.absoluteString)}]\n")
    let workspace = try await f.workspace()
    let initial = try await workspace.resolve()
    let baseline = try Data(contentsOf: url(f.lock))
    await f.downloads.set(remote, "source \"${root_dir}/../outside.conf\"\n")
    await #expect {
      _ = try await workspace.update(.imports(Set(initial.imports.map(\.id))))
    } throws: { error in
      guard case .runtime(.defect(.wrapped(let detail, _))) = error as? PinewindError else {
        return false
      }
      return detail.contains("permission denied: /outside.conf")
    }
    #expect(try Data(contentsOf: url(f.lock)) == baseline)
    await f.downloads.set(remote, String(repeating: "#padding\n", count: 40))
    let bounded = try await Workspace.open(
      locations: f.locations,
      services: WorkspaceServices(repositories: f.repositories, resources: f.downloads),
      options: WorkspaceOptions(imports: ImportLimits(maximumFileBytes: 64)))
    await #expect {
      _ = try await bounded.update()
    } throws: {
      if case .runtime(.network(.sizeLimitExceeded)) = $0 as? PinewindError {
        return true
      } else {
        return false
      }
    }
    #expect(try Data(contentsOf: url(f.lock)) == baseline)
  }
  @Test func validationReportsIndependentEntryErrors() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let workspace = try await f.workspace()
    let session = try await workspace.configuration()
    await session.edit { $0.manifest.order = [.named("missing-a"), .named("missing-b")] }
    let diagnostics = await session.validate()
    #expect(diagnostics.count == 2)
    #expect(
      diagnostics.allSatisfy { diagnostic in
        if case .configuration(let document) = diagnostic,
          case .declaration(.unknownName) = document.failure
        {
          return true
        }
        return false
      })
  }

  @Test func concurrentPublishersProduceOneCompleteGeneration() async throws {
    let a = try Fixture()
    let b = try Fixture()
    defer {
      a.remove()
      b.remove()
    }
    try write(a.input.appending("default.yaml"), "first")
    try write(a.input.appending("first.txt"), "first")
    try write(b.input.appending("default.yaml"), "second")
    try write(b.input.appending("second.txt"), "second")
    let first = try await a.workspace()
    let second = try await b.workspace()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<8 {
        group.addTask {
          _ = try await (index.isMultiple(of: 2) ? first : second).compose(to: a.output)
        }
      }
      try await group.waitForAll()
    }
    let text = try read(a.output.appending("default.yaml"))
    #expect(text == "first" || text == "second")
    #expect(exists(a.output.appending("first.txt")) == (text == "first"))
    #expect(exists(a.output.appending("second.txt")) == (text == "second"))
  }
  @Test func incompatibleLockRequiresExplicitRebuild() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try write(f.input.appending("schema.yaml"), "value: local")
    try write(f.lock, "old unsupported encoding")
    let workspace = try await f.workspace()
    await #expect(throws: PinewindError.self) { _ = try await workspace.compose(to: f.output) }
    _ = try await workspace.resolve()
    #expect(try await workspace.compose(to: f.output).paths.map(\.string) == ["schema.yaml"])
  }

  @Test func remoteConfFileProbesPrepareResourcesWithoutDirectoryGuessing() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let root = URL(string: "https://conf.test/main.conf")!
    let include = URL(string: "https://conf.test/include.conf")!
    await f.downloads.set(root, try fixtureText("RemoteConf/Probes/main.conf"))
    await f.downloads.set(include, try fixtureText("RemoteConf/Probes/include.conf"))
    try await f.repositories.install(firstID, files: ["default.yaml": "probe"])
    try write(f.manifest, "version: 1\norder: [{import: \(root.absoluteString)}]\n")
    let workspace = try await f.workspace()
    let resolution = try await workspace.resolve()
    #expect(resolution.imports[0].packages.count == 1)
    #expect(resolution.imports[0].resources.count == 2)
  }

}
