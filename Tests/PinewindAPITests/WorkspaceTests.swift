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
  var rejectResolution = false
  var rejectPreparation = false
  private var pause = false
  private var started = false
  private var continuations: [CheckedContinuation<Void, Never>] = []
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
    if rejectResolution { throw NetworkFailure.rejected(status: 503, url: request.url) }
    if pause {
      started = true
      await withCheckedContinuation { continuations.append($0) }
    }
    return try SourceIdentity(url: request.url, commit: current)
  }
  func prepareSource(_ identity: SourceIdentity, cacheRoot: FilePath) async throws -> SourceSnapshot
  {
    preparations += 1
    if rejectPreparation { throw NetworkFailure.rejected(status: 503, url: identity.url) }
    return try SourceSnapshot(identity: identity, directory: root.appending(identity.commit.string))
  }
  func counts() -> (Int, Int) { (resolutions, preparations) }
  func rejecting(resolution: Bool = false, preparation: Bool = false) {
    rejectResolution = resolution
    rejectPreparation = preparation
  }
  func pauseNext() { pause = true }
  func didStart() -> Bool { started }
  func release() {
    pause = false
    for continuation in continuations { continuation.resume() }
    continuations = []
  }
}
private actor Downloads: ResourceDownloader {
  var files: [URL: Data] = [:]
  var calls = 0
  var limits: [URL: [Int?]] = [:]
  func set(_ endpoint: URL, _ text: String) { files[endpoint] = Data(text.utf8) }
  func download(_ endpoint: URL, to destination: FilePath, maximumBytes: Int?) async throws {
    calls += 1
    limits[endpoint, default: []].append(maximumBytes)
    guard let bytes = files[endpoint] else {
      throw NetworkFailure.rejected(status: 404, url: endpoint)
    }
    try FileManager.default.createDirectory(
      at: url(destination.removingLastComponent()), withIntermediateDirectories: true)
    try bytes.write(to: url(destination))
  }
  func count() -> Int { calls }
  func requestedLimits(_ endpoint: URL) -> [Int?] { limits[endpoint, default: []] }
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
  // Functional tests share CI CPU and disk with the rest of the parallel suite.
  // Interpreter timeout behavior is tested separately with an explicit short budget.
  func workspace(
    options: WorkspaceOptions = WorkspaceOptions(imports: ImportLimits(timeout: .seconds(60)))
  ) async throws -> Workspace {
    try await Workspace.open(
      locations: locations,
      services: WorkspaceServices(repositories: repositories, resources: downloads),
      options: options)
  }
  func remote(recipe: String? = nil, duplicate: Bool = false) throws {
    let fields = recipe.map { "\n    recipe: \($0)" } ?? ""
    try write(
      manifest,
      "version: 1\nnames:\n  package:\n    url: \(endpoint.absoluteString)\n    revision: {branch: main}\(fields)\norder: [package\(duplicate ? ", package" : ""), self]\n"
    )
  }
}

@Suite("Public Workspace API", .timeLimit(.minutes(3)))
struct WorkspaceTests {
  @Test func lintCollectsIndependentOriginalYAMLPositionsWithoutResolving() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try write(
      f.manifest,
      """
      version: 1
      names:
        bad:
          url: http://example.test/repository
          revision: {branch: ""}
          include: ["../first", "../second"]
      order:
        - missingOne
        - missingTwo
        - bad
      """)
    let workspace = try await f.workspace()
    let report = try await workspace.lint()
    #expect(report.diagnostics.count == 6)
    #expect(
      report.diagnostics.allSatisfy { $0.context.path == f.manifest && $0.context.placement != nil }
    )
    #expect(Set(report.diagnostics.compactMap { $0.context.placement?.line }) == [4, 5, 6, 8, 9])
    let json = try JSONEncoder().encode(report)
    let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
    #expect((object["diagnostics"] as? [Any])?.count == 6)
    #expect(await f.repositories.counts().0 == 0)
    #expect(await f.downloads.count() == 0)
    #expect(!exists(f.lock) && !exists(f.output))
  }

  @Test func lintChecksBothDocumentsAndEveryFilterWithoutRequiringRemoteSources() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let missing = url(f.root.appending("absent package")).absoluteString
    try write(
      f.manifest,
      """
      version: 1
      order:
        - url: \(missing)
        - url: https://example.test/absent
        - self: {include: ["../one", "../two"], exclude: ["../three"]}
      """)
    try write(f.overrides, "version: 2\nnames: {bad: {url: true}}\nunknown: value\n")
    let workspace = try await f.workspace()
    let report = try await workspace.lint()
    #expect(report.diagnostics.count == 7)
    #expect(report.diagnostics.filter { $0.context.path == f.overrides }.count == 3)
    #expect(report.diagnostics.filter { $0.context.path == f.manifest }.count == 4)
    #expect(!exists(f.lock))
    #expect(await f.repositories.counts().0 == 0)
  }

  @Test func lintUsesCapturedSourceRecipesWithoutCallingInjectedBackends() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(firstID, files: ["recipe.yaml": "install_files: []\n"])
    try f.remote()
    let workspace = try await f.workspace()
    _ = try await workspace.resolve()
    let calls = await f.repositories.counts()
    let cache = url(f.locations.cacheRoot.appending("sources"))
    let key = try #require(
      FileManager.default.contentsOfDirectory(
        at: cache,
        includingPropertiesForKeys: nil
      ).first)
    let recipe = FilePath(key.appendingPathComponent(firstID + "/recipe.yaml").path)
    try write(recipe, "download_files: [http://insecure.test/resource]\n")
    let report = try await workspace.lint()
    #expect(report.diagnostics.count == 1)
    #expect(
      report.diagnostics.first?.context.path == FilePath(url(recipe).resolvingSymlinksInPath().path)
    )
    #expect(report.diagnostics.first?.context.placement?.line == 1)
    #expect(await f.repositories.counts().0 == calls.0)
    #expect(await f.repositories.counts().1 == calls.1)
    // Recipe metadata changes do not erase an already-known repository revision.
    let customized = FilePath(key.appendingPathComponent(firstID + "/customize.recipe.yaml").path)
    try write(customized, "recipe: {Rx: customize}\ndownload_files: [http://insecure.test/file]\n")
    try f.remote(recipe: "customize")
    let stale = try await workspace.lint()
    #expect(stale.diagnostics.count == 1)
    #expect(
      stale.diagnostics.first?.context.path
        == FilePath(url(customized).resolvingSymlinksInPath().path))
    #expect(await f.repositories.counts().0 == calls.0)
    try FileManager.default.removeItem(at: url(customized))
    let missing = try await workspace.lint()
    #expect(missing.diagnostics.count == 1)
    #expect(missing.diagnostics.first?.context.path == f.manifest)
    #expect(missing.diagnostics.first?.context.placement?.line == 6)
    #expect(await f.repositories.counts().0 == calls.0)
    #expect(await f.repositories.counts().1 == calls.1)
  }

  @Test func lintUsesOriginalUTF16ColumnsAndEncodesParserFailures() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let line = "order: [{options: {label: 😀}, name: missing}]"
    try write(f.manifest, "version: 1\n" + line + "\n")
    let workspace = try await f.workspace()
    let report = try await workspace.lint()
    let position = try #require(report.diagnostics.first?.context.placement)
    let prefix = line[..<line.range(of: "missing")!.lowerBound]
    #expect(position.line == 2 && position.column == prefix.utf16.count + 1)
    try write(f.manifest, "version: 1\norder: [self\n")
    let broken = try await workspace.lint()
    #expect(broken.diagnostics.count == 1)
    #expect(broken.diagnostics.first?.context.placement?.line == 3)
    let json = try JSONEncoder().encode(broken)
    let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
    let entries = try #require(object["diagnostics"] as? [[String: Any]])
    let cause = try #require(entries.first?["failure"] as? [String: Any])
    #expect(cause["parser"] != nil || cause["scanner"] != nil)
    let parser = try #require((cause["parser"] ?? cause["scanner"]) as? [String: Any])
    #expect(parser["mark"] is [String: Any])
    #expect(parser["_2"] == nil)
  }

  @Test(arguments: [
    "  - import: 5\n",
    "  - import: https://example.test/import.conf\n    variables: {a: [1]}\n",
  ])
  func lintImportDecodeErrorsKeepOnePositionAndRemainEncodable(_ entry: String) async throws {
    let f = try Fixture()
    defer { f.remove() }
    try write(f.manifest, "version: 1\norder:\n" + entry)
    let workspace = try await f.workspace()
    let report = try await workspace.lint()
    let diagnostic = try #require(report.diagnostics.first)
    #expect(report.diagnostics.count == 1)
    #expect(diagnostic.underlyingError is DeclarationFailure)
    #expect(diagnostic.context.placement?.line == (entry.contains("variables") ? 4 : 3))
    #expect(diagnostic.description.components(separatedBy: f.manifest.string).count == 2)
    let json = try JSONEncoder().encode(report)
    let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
    let entries = try #require(object["diagnostics"] as? [[String: Any]])
    let cause = try #require(entries.first?["failure"] as? [String: Any])
    #expect(cause["syntaxError"] != nil)
    #expect(await f.downloads.count() == 0)
  }

  @Test(arguments: [
    "version: 1\nnames: 5\norder: [pkg, other]\n",
    "version: 1\nnames: {pkg: hello}\norder: [pkg]\n",
  ])
  func lintSkipsNameAndURLChecksWhenTheirStructureIsUnreadable(_ yaml: String) async throws {
    let f = try Fixture()
    defer { f.remove() }
    try write(f.manifest, yaml)
    let workspace = try await f.workspace()
    let report = try await workspace.lint()
    #expect(report.diagnostics.count == 1)
    #expect(
      report.diagnostics.first?.underlyingError as? DeclarationFailure
        == .syntaxError(detail: "expected a mapping"))
    // Local overrides are an independent document, but an unreadable name table
    // still cannot establish whether another name exists in the effective manifest.
    try write(f.manifest, "version: 1\nnames: {}\norder: [pkg, other]\n")
    try write(f.overrides, "version: 1\nnames: 5\n")
    let local = try await workspace.lint()
    #expect(local.diagnostics.count == 3)
    #expect(local.diagnostics.filter { $0.context.path == f.manifest }.count == 2)
    #expect(local.diagnostics.filter { $0.context.path == f.overrides }.count == 1)
  }

  @Test(arguments: ["[self]\n", "hello\n", "null\n"])
  func lintStopsDependentRootChecksButContinuesOtherDocuments(_ yaml: String) async throws {
    let f = try Fixture()
    defer { f.remove() }
    try write(f.manifest, yaml)
    let workspace = try await f.workspace()
    let report = try await workspace.lint()
    #expect(report.diagnostics.count == 1)
    #expect(
      report.diagnostics.first?.underlyingError as? DeclarationFailure
        == .syntaxError(detail: "expected a mapping"))
    #expect(report.diagnostics.first?.context.placement?.line == 1)
    _ = try JSONEncoder().encode(report)
    try write(f.manifest, "version: 1\norder: [missing]\n")
    try write(f.overrides, yaml)
    let independent = try await workspace.lint()
    #expect(independent.diagnostics.count == 2)
    #expect(independent.diagnostics.filter { $0.context.path == f.overrides }.count == 1)
    #expect(independent.diagnostics.filter { $0.context.path == f.manifest }.count == 1)
  }

  @Test func lintChecksLocalSourceDirectoriesAtTheirAuthoredURLs() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let missing = f.root.appending("absent package")
    let file = f.root.appending("ordinary file")
    try write(file, "not a directory")
    try write(
      f.manifest,
      "version: 1\norder:\n  - url: \(url(missing).absoluteString)\n    recipe: custom\n  - url: \(url(missing).absoluteString)\n  - url: \(url(file).absoluteString)\n  - {url: https://example.test/absent, recipe: custom}\n"
    )
    let workspace = try await f.workspace()
    let report = try await workspace.lint()
    #expect(report.diagnostics.count == 3)
    #expect(report.diagnostics.compactMap { $0.context.placement?.line } == [3, 5, 6])
    #expect(report.diagnostics.allSatisfy { $0.context.path == f.manifest })
    #expect(
      report.diagnostics.prefix(2).allSatisfy {
        $0.underlyingError as? FileSystemFailure == .notFound(missing)
      })
    #expect(report.diagnostics.last?.underlyingError as? FileSystemFailure == .notADirectory(file))
    _ = try JSONEncoder().encode(report)
    // Named definitions and both override layers retain the URL's own origin.
    try write(
      f.manifest,
      "version: 1\nnames:\n  pkg: {url: \(url(missing).absoluteString)}\norder:\n  - pkg\n  - {name: pkg, url: \(url(file).absoluteString)}\n"
    )
    try write(f.overrides, "version: 1\nnames:\n  pkg: {url: \(url(missing).absoluteString)}\n")
    let layered = try await workspace.lint()
    #expect(layered.diagnostics.count == 3)
    #expect(layered.diagnostics.filter { $0.context.path == f.manifest }.count == 2)
    #expect(layered.diagnostics.filter { $0.context.path == f.overrides }.count == 1)
    #expect(await f.repositories.counts().0 == 0)
    #expect(await f.downloads.count() == 0)
  }

  @Test func lintImportedMissingRecipesUseTheUnpositionedOperationFailureChannel() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let endpoint = URL(string: "https://conf.test/packages.conf")!
    await f.downloads.set(endpoint, "package_list=(rime/example:customize)\n")
    try await f.repositories.install(
      firstID, files: ["customize.recipe.yaml": "recipe: {Rx: customize}\ninstall_files: []\n"])
    try write(f.manifest, "version: 1\norder: [{import: \(endpoint.absoluteString)}]\n")
    let workspace = try await f.workspace()
    let resolution = try await workspace.resolve()
    #expect(resolution.imports.first?.packages.first?.recipe == "customize")
    #expect(try await workspace.lint().isValid)
    let calls = await f.repositories.counts()
    let downloads = await f.downloads.count()
    let cache = url(f.locations.cacheRoot.appending("sources"))
    let key = try #require(
      FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first)
    let recipe = key.appendingPathComponent(firstID + "/customize.recipe.yaml")
    try FileManager.default.removeItem(at: recipe)
    try write(
      f.manifest,
      "version: 1\norder: [{import: \(endpoint.absoluteString)}, missing]\n")
    // This contract deliberately returns no partial report on an operation failure,
    // even if an independent YAML diagnostic has already been collected.
    await #expect { try await workspace.lint() } throws: { error in
      guard case .notFound(let path) = error as? FileSystemFailure else { return false }
      return path.lastComponent?.string == "customize.recipe.yaml"
    }
    #expect(await f.repositories.counts().0 == calls.0)
    #expect(await f.repositories.counts().1 == calls.1)
    #expect(await f.downloads.count() == downloads)
  }

  @Test func lintChecksExplicitMissingRecipesAtTheirAuthoredSelectors() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let source = url(f.input).absoluteString
    try write(f.input.appending("default.yaml"), "schema: {}\n")
    try write(
      f.manifest,
      "version: 1\norder:\n  - url: \(source)\n    recipe: custom\n  - url: \(source)\n    recipe: custom\n"
    )
    let workspace = try await f.workspace()
    let report = try await workspace.lint()
    #expect(report.diagnostics.count == 2)
    #expect(report.diagnostics.compactMap { $0.context.placement?.line } == [4, 6])
    #expect(report.diagnostics.allSatisfy { $0.context.path == f.manifest })
    for diagnostic in report.diagnostics {
      guard case .notFound(let path) = diagnostic.underlyingError as? FileSystemFailure else {
        Issue.record("expected the missing recipe path")
        continue
      }
      #expect(path.lastComponent?.string == "custom.recipe.yaml")
      // Native canonicalization may expand Windows short paths. Verify the target
      // directory through its existing content rather than requiring one path spelling.
      #expect(try read(path.removingLastComponent().appending("default.yaml")) == "schema: {}\n")
    }
    _ = try JSONEncoder().encode(report)
    // Check shared, local, and entry-level recipe origins independently.
    try write(
      f.manifest,
      "version: 1\nnames:\n  pkg: {url: \(source), recipe: shared}\norder:\n  - pkg\n  - {name: pkg, recipe: entry}\n"
    )
    try write(f.overrides, "version: 1\nnames:\n  pkg: {recipe: local}\n")
    let layered = try await workspace.lint()
    #expect(layered.diagnostics.count == 3)
    #expect(layered.diagnostics.filter { $0.context.path == f.overrides }.count == 1)
    #expect(layered.diagnostics.filter { $0.context.path == f.manifest }.count == 2)
    // Null clears an inherited explicit selector; unavailable remote sources remain optional.
    try write(f.overrides, "version: 1\nnames:\n  pkg: {recipe: null}\n")
    let reset = try await workspace.lint()
    #expect(reset.diagnostics.count == 2)
    #expect(reset.diagnostics.allSatisfy { $0.context.path == f.manifest })
    try write(
      f.manifest,
      "version: 1\nnames: {pkg: {url: \(source)}}\norder:\n  - pkg\n  - {url: https://example.test/absent, recipe: custom}\n"
    )
    #expect(try await workspace.lint().isValid)
    #expect(await f.repositories.counts().0 == 0)
    #expect(await f.downloads.count() == 0)
  }

  @Test func lintChecksIndependentRecipeSectionsWithoutPreparingMissingFiles() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try write(f.manifest, "version: 1\norder: [{url: \(url(f.input).absoluteString)}]\n")
    try write(
      f.input.appending("recipe.yaml"),
      """
      download_files: [http://insecure.test/file]
      patch_files:
        target.yaml: {not: a-sequence}
      install_files: [../bad]
      """)
    let workspace = try await f.workspace()
    let report = try await workspace.lint()
    #expect(report.diagnostics.count == 3)
    #expect(report.diagnostics.allSatisfy { $0.context.placement != nil })
    #expect(!exists(f.lock) && !exists(f.output))
  }

  @Test func lintUsesVerifiedCachedYAMLAndDoesNotBlameConfigurationForDamagedCache() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let endpoint = URL(string: "https://resources.test/schema.yaml")!
    await f.downloads.set(endpoint, "schema: [broken\n")
    try await f.repositories.install(
      firstID, files: ["recipe.yaml": "download_files: [\(endpoint)]\n"])
    try f.remote()
    let workspace = try await f.workspace()
    let resolution = try await workspace.resolve()
    let pin = try #require(resolution.packages.first?.resources.first)
    let report = try await workspace.lint()
    #expect(report.diagnostics.count == 1)
    #expect(report.diagnostics.first?.context.url == endpoint)
    let file = f.locations.cacheRoot.appending("resources/" + pin.sha256)
    try write(file, "different bytes")
    #expect(try await workspace.lint().isValid)
    try FileManager.default.removeItem(at: url(file))
    #expect(try await workspace.lint().isValid)
    #expect(await f.downloads.count() == 1)
  }

  @Test func lintCollectsMissingSourcesAlongsideIndependentErrorsWithoutInventingDependentOnes()
    async throws
  {
    let f = try Fixture()
    defer { f.remove() }
    try write(
      f.manifest,
      """
      version: 1
      names:
        incomplete: {include: [../bad]}
        invalid: {url: true, include: [../other]}
      order: [incomplete, invalid]
      """)
    let workspace = try await f.workspace()
    let report = try await workspace.lint()
    #expect(report.diagnostics.count == 4)
    #expect(
      report.diagnostics.filter { $0.underlyingError as? DeclarationFailure == .inlineURLRequired }
        .count == 1)
    #expect(report.diagnostics.allSatisfy { $0.context.placement != nil })
  }

  @Test func validationCollectsFailedEditsAndAllIndependentFieldsWithoutSideEffects() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let workspace = try await f.workspace()
    let badFields = PackageFields(
      url: .value(URL(string: "http://example.com/package")!), revision: .value(.branch("")),
      recipe: .value("../escape"), include: .value(["../first", "../second"]))
    let candidate = try await workspace.configuration { configuration in
      configuration.addPackage("bad", fields: badFields)
      configuration.addPackage("bad", fields: PackageFields())
      configuration.removePackage("absent")
      configuration.moveEntry(from: -1, to: 0)
    }
    let diagnostics = candidate.validate()
    #expect(diagnostics.count == 8)
    #expect(diagnostics.filter { $0.packageName == "bad" && $0.field == "include" }.count == 2)
    #expect(diagnostics.filter { $0.operationIndex == 0 }.count == 5)
    #expect(diagnostics.filter { $0.operationIndex == 1 }.count == 1)
    #expect(candidate.manifest.names["bad"] == badFields)
    await #expect { _ = try await workspace.apply(candidate) } throws: {
      guard let error = $0 as? any PinewindErrorProtocol else { return false }
      return (error as? ConfigurationValidationError)?.diagnostics.count == diagnostics.count
    }
    #expect(!exists(f.manifest) && !exists(f.lock) && !exists(f.overrides))
    #expect(await f.repositories.counts().0 == 0)
    #expect(await f.downloads.count() == 0)
    let again = try await workspace.validate { $0.removePackage("absent") }
    #expect(again.count == 1)
    #expect(try await workspace.configuration().manifest.names.isEmpty)
  }

  @Test func failedEditDoesNotPreventIndependentEditsBeingDiagnosed() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let workspace = try await f.workspace()
    let diagnostics = try await workspace.validate {
      $0.addPackage("self", fields: PackageFields())
      $0.addPackage("", fields: PackageFields())
      $0.addPackage("incomplete", fields: PackageFields())
      $0.addPackage("anchored", fields: PackageFields(), insertion: .before("absent"))
    }
    #expect(diagnostics.count == 4)
    #expect(Set(diagnostics.compactMap(\.operationIndex)) == [0, 1, 2, 3])
    #expect(diagnostics.allSatisfy { $0.error.description.isEmpty == false })
  }

  @Test func missingSourcesAndInvalidFiltersAreCollectedAlongsideOtherFieldProblems() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let workspace = try await f.workspace()
    let diagnostics = try await workspace.validate {
      $0.addPackage(
        "incomplete",
        fields: PackageFields(
          revision: .value(.branch("")), recipe: .value("../bad")))
      $0.manifest.order.append(.userFiles(FileFilter(include: ["../one", "../two"])))
    }
    #expect(diagnostics.count == 5)
    #expect(
      Set(diagnostics.filter { $0.packageName == "incomplete" }.compactMap(\.field)) == [
        "url", "revision", "recipe",
      ])
  }

  @Test func rawCommitInputIsValidatedAlongsideTheOtherFormFields() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(firstID, files: ["default.yaml": "pinned"])
    let workspace = try await f.workspace()
    let candidate = try await workspace.configuration {
      $0.addPackage(
        "bad", source: "http://example.com/repo", commit: "invalid",
        recipe: "../recipe", filter: FileFilter(include: ["../escape"]))
    }
    let diagnostics = candidate.validate()
    #expect(diagnostics.count == 4)
    #expect(Set(diagnostics.compactMap(\.field)) == ["url", "revision", "recipe", "include"])
    #expect(diagnostics.allSatisfy { $0.operationIndex == 0 && $0.packageName == "bad" })
    await #expect(throws: ConfigurationValidationError.self) {
      _ = try await workspace.apply(candidate)
    }
    #expect(!exists(f.lock) && !exists(f.manifest))
    let valid = try await workspace.configuration {
      $0.addPackage(source: "team/repo", commit: firstID)
    }
    #expect(valid.validate().isEmpty)
    #expect(valid.manifest.names["repo"]?.revision == .value(.commit(try CommitID(firstID))))
    let applied = try await workspace.update {
      $0.addPackage("pinned", source: endpoint.absoluteString, commit: firstID)
    }
    #expect(applied.inputs != nil)
    #expect(applied.resolution.packages[0].commit.string == firstID)
  }

  @Test func singleAndBatchUpdatesPrepareInputsWithoutPublishing() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(firstID, files: ["default.yaml": "remote"])
    let workspace = try await f.workspace()
    let fields = PackageFields(url: .value(endpoint))
    let applied = try await workspace.update { $0.addPackage("first", fields: fields) }
    #expect(applied.inputs != nil && applied.resolution.packages.count == 1)
    let batch = try await workspace.update {
      $0.renamePackage("first", to: "renamed")
      $0.addPackage("second", fields: fields, insertion: .after("self"))
      $0.moveEntry(from: 2, to: 0)
    }
    #expect(batch.inputs != nil)
    let saved = try await workspace.configuration()
    #expect(
      saved.manifest.order == [.named("second"), .named("renamed"), .userFiles(FileFilter())])
    #expect(saved.manifest.names["first"] == nil)
    #expect(!exists(f.output))
    _ = try await workspace.build(to: f.output)
    #expect(try read(f.output.appending("default.yaml")) == "remote")
  }

  @Test func preparationFailureExposesCommittedResolutionAndInstallRetriesIt() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(firstID, files: ["default.yaml": "remote"])
    try f.remote()
    let workspace = try await f.workspace()
    _ = try await workspace.resolve()
    await f.repositories.rejecting(preparation: true)
    let fields = PackageFields(url: .value(endpoint), revision: .value(.branch("main")))
    let progress: OperationProgress = { event in
      if case .completed(.resolving) = event {
        try? FileManager.default.removeItem(at: url(f.locations.cacheRoot))
      }
    }
    do {
      _ = try await workspace.update(progress: progress) { $0.addPackage("alias", fields: fields) }
      Issue.record("expected preparation failure")
    } catch let error as any PinewindErrorProtocol {
      let failure = try #require(error as? PreparationFailure)
      #expect(failure.resolution.packages.count == 1)
      #expect(String(describing: failure.cause).contains("503"))
    }
    #expect(try await workspace.configuration().manifest.names["alias"] == fields)
    let lock = try Data(contentsOf: url(f.lock))
    await f.repositories.rejecting()
    _ = try await workspace.install(locked: true)
    #expect(try Data(contentsOf: url(f.lock)) == lock)
  }

  @Test func cancellationAfterCommitKeepsTheBatchAndItsLock() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let workspace = try await f.workspace()
    let task = Task {
      try await workspace.update(progress: { event in
        if case .completed(.resolving) = event { withUnsafeCurrentTask { $0?.cancel() } }
      }) { $0.manifest.order = [] }
    }
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(try await workspace.configuration().manifest.order.isEmpty)
    _ = try await workspace.install(locked: true)
  }

  @Test func competingCandidatesCommitOneCompleteBatchAndNeverReplayEdits() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let workspace = try await f.workspace()
    let first = try await workspace.configuration {
      $0.manifest.order = []
      $0.localOverrides = LocalOverridesDocument()
    }
    let second = try await workspace.configuration {
      $0.manifest.order = [.userFiles(FileFilter(include: ["*.yaml"]))]
    }
    let successes = await withTaskGroup(of: Bool.self) { group in
      for candidate in [first, second] {
        group.addTask {
          do {
            _ = try await workspace.apply(candidate)
            return true
          } catch {
            #expect(error as? StateFailure == .externallyModified)
            return false
          }
        }
      }
      var successes = 0
      for await success in group { if success { successes += 1 } }
      return successes
    }
    #expect(successes == 1)
    let saved = try await workspace.configuration()
    if saved.manifest.order.isEmpty {
      #expect(saved.localOverrides != nil)
    } else {
      #expect(saved.localOverrides == nil)
    }
    _ = try await workspace.install(locked: true)
  }

  @Test func buildRuntimeProtectionAppliesToEveryCoreConsumerEvenWhenForced() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try write(f.input.appending("words.userdb/data"), "database")
    let workspace = try await f.workspace()
    await #expect(
      throws:
        StateFailure.runtimeOutputPath(try RelativePath("words.userdb/data"))
    ) {
      _ = try await workspace.build(to: f.output, overwriteUnmanaged: true)
    }
    #expect(!exists(f.output))
  }

  @Test func sourceConveniencesAndReadOnlyStatusWorkWithoutCLITypes() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let locations = try WorkspaceLocations(
      userFilesRoot: f.locations.userFilesRoot, configuration: f.locations.configuration,
      stateRoot: f.locations.stateRoot, cacheRoot: f.locations.cacheRoot, relativeTo: f.root)
    let workspace = try await Workspace.open(locations: locations)
    let candidate = try await workspace.configuration {
      $0.addPackage(source: "emoji")
      $0.addPackage(source: "team/rime-custom.git")
      $0.addPackage(source: "./local")
      $0.addPackage("explicit", source: "https://example.com/pkg.git")
    }
    #expect(candidate.validate().isEmpty)
    #expect(
      candidate.manifest.names["emoji"]?.url
        == .value(URL(string: "https://github.com/rime/rime-emoji")!))
    #expect(candidate.manifest.names["custom"] != nil)
    guard case .value(let localURL)? = candidate.manifest.names["local"]?.url else {
      Issue.record("expected an absolute local source")
      return
    }
    #expect(localURL.standardizedFileURL == url(f.root.appending("local")).standardizedFileURL)
    #expect(candidate.manifest.names["explicit"] != nil)
    let invalid = try await workspace.validate {
      $0.addPackage("bad", source: "owner/repo/extra")
      $0.addPackage("http", source: "http://example.com/repo")
    }
    #expect(invalid.count == 2)
    #expect(!exists(f.manifest) && !exists(f.lock))
    // Reading an unresolved remote declaration must not create a lock or make network calls.
    try f.remote()
    let status = try await workspace.status()
    #expect(status.resolution == nil)
    guard case .unavailable(let error) = status.inputs else {
      Issue.record("expected unresolved status")
      return
    }
    #expect(error as? LockFailure == .resolveRequired)
    #expect(!exists(f.lock))
    #expect(await f.repositories.counts().0 == 0)
  }

  @Test func platformDiscoveryReturnsCandidatesForGUISelection() throws {
    let f = try Fixture()
    defer { f.remove() }
    let directories = PlatformDirectories(environment: [:], home: f.root)
    #if os(macOS)
      let frontends: [RimeFrontend] = [.squirrel, .fcitx5]
    #elseif os(Windows)
      // Weasel may have an explicit registry override on a developer machine.
      let frontends: [RimeFrontend] = []
    #else
      let frontends: [RimeFrontend] = [.fcitx5, .ibus]
    #endif
    for frontend in frontends {
      try FileManager.default.createDirectory(
        at: url(directories.rimeDirectory(frontend)), withIntermediateDirectories: true)
    }
    if !frontends.isEmpty {
      let discovered = directories.discoverRimeDirectories()
      #expect(Set(discovered.map(\.frontend)) == Set(frontends))
      #expect(throws: StateFailure.self) { _ = try directories.output(frontend: nil) }
      #expect(
        try directories.output(frontend: frontends[0]) == directories.rimeDirectory(frontends[0]))
    }
    let locations = try directories.workspaceLocations(
      configurationDirectory: "custom/config", stateDirectory: "custom/state",
      cacheDirectory: "custom/cache", relativeTo: f.root)
    #expect(locations.stateRoot == f.root.appending("custom/state/managed"))
    #expect(
      locations.configuration.localOverrides
        == .path(f.root.appending("custom/state/pinewind.local.yaml")))
    #expect(locations.userFilesRoot == .path(f.root.appending("custom/config/user")))
    #expect(!exists(f.root.appending("custom")))
    _ = WorkspaceServices.live(credentials: { _ in nil })
  }

  @Test func concurrentIdenticalResolutionsCommitIdempotently() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(firstID, files: ["default.yaml": "remote"])
    try f.remote()
    let first = try await f.workspace()
    let second = try await f.workspace()
    await f.repositories.pauseNext()
    let a = Task { try await first.resolve() }
    let b = Task { try await second.resolve() }
    while await f.repositories.counts().0 < 2 { try await Task.sleep(for: .milliseconds(5)) }
    await f.repositories.release()
    #expect(try await a.value.packages[0].commit == b.value.packages[0].commit)
    _ = try await first.fetch()
  }
  @Test func redirectsUseTheWorkspaceBaseDuringEditingAndApplication() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let locations = try WorkspaceLocations(
      userFilesRoot: f.locations.userFilesRoot, configuration: f.locations.configuration,
      stateRoot: f.locations.stateRoot, cacheRoot: f.locations.cacheRoot, relativeTo: f.root)
    let workspace = try await Workspace.open(locations: locations)
    let request = try PackageRequest(source: .directory(.path(f.input)))
    _ = try await workspace.update(preparation: .deferred) {
      $0.addPackage("local", request: request)
      $0.redirectPackage("local", to: .path("relative package"))
    }
    func redirectedPath(_ snapshot: ConfigurationSnapshot) throws -> FilePath {
      let field = try #require(snapshot.localOverrides?.names["local"]?.url)
      guard case .value(let value) = field else { throw StateFailure.staleInputs }
      return FilePath(value.path)
    }
    #expect(
      try redirectedPath(await workspace.configuration()) == f.root.appending("relative package"))
    let candidate = try await workspace.configuration {
      $0.redirectPackage("local", to: .path("after reload"))
    }
    _ = try await workspace.apply(candidate, preparation: .deferred)
    #expect(try redirectedPath(await workspace.configuration()) == f.root.appending("after reload"))
  }

  @Test func managedPublicationRejectsUnmanagedCollisionsBeforeAnyWriteAndForceReportsThem()
    async throws
  {
    let f = try Fixture()
    defer { f.remove() }
    try write(f.input.appending("default.yaml"), "generated")
    try write(f.input.appending("new.txt"), "new")
    try write(f.input.appending("same.txt"), "same")
    try write(f.output.appending("default.yaml"), "personal")
    try write(f.output.appending("same.txt"), "same")
    let workspace = try await f.workspace()
    do {
      _ = try await workspace.compose(to: f.output, publication: .managedFiles())
      Issue.record("unmanaged collision was overwritten")
    } catch {
      guard
        case .unmanagedOutputFiles(let directory, let paths) = error as? StateFailure
      else {
        Issue.record("unexpected error: \(error)")
        return
      }
      #expect(directory.lastComponent == f.output.lastComponent)
      #expect(paths.map(\.string) == ["default.yaml"])
    }
    #expect(try read(f.output.appending("default.yaml")) == "personal")
    #expect(!exists(f.output.appending("new.txt")))
    #expect(!exists(f.locations.stateRoot.appending("publications")))
    let result = try await workspace.compose(
      to: f.output, publication: .managedFiles(overwriteUnmanaged: true))
    #expect(result.overwrittenUnmanagedPaths.map(\.string) == ["default.yaml"])
    #expect(result.reusedPaths.map(\.string) == ["same.txt"])
    #expect(try read(f.output.appending("default.yaml")) == "generated")
    try write(f.input.appending("default.yaml"), "updated")
    let subsequent = try await workspace.compose(to: f.output, publication: .managedFiles())
    #expect(subsequent.overwrittenUnmanagedPaths.isEmpty)
    #expect(try read(f.output.appending("default.yaml")) == "updated")
  }

  @Test func corruptPendingRecordRecoversConservativelyAndReportsWarning() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try write(f.input.appending("old.txt"), "old")
    let workspace = try await f.workspace()
    _ = try await workspace.compose(to: f.output, publication: .managedFiles())
    let records = try FileManager.default.contentsOfDirectory(
      at: url(f.locations.stateRoot.appending("publications")), includingPropertiesForKeys: nil)
    let record = try #require(records.first(where: { $0.pathExtension == "plist" }))
    let pending = record.deletingPathExtension().appendingPathExtension("pending.plist")
    try Data("truncated".utf8).write(to: pending)
    // A newly written but unrecorded file from an interrupted publication is
    // safe to adopt when its bytes already match this build; unrelated files stay unowned.
    try write(f.input.appending("new.txt"), "new")
    try write(f.output.appending("new.txt"), "new")
    try write(f.output.appending("orphan.txt"), "unknown ownership")
    try FileManager.default.removeItem(at: url(f.input.appending("old.txt")))
    let result = try await workspace.compose(to: f.output, publication: .managedFiles())
    #expect(result.removedPaths.map(\.string) == ["old.txt"])
    #expect(result.warnings.count == 1)
    guard case .discardedPendingRecord(let path) = try #require(result.warnings.first) else {
      return
    }
    #expect(
      path == f.locations.stateRoot.appending("publications").appending(pending.lastPathComponent))
    #expect(try read(f.output.appending("orphan.txt")) == "unknown ownership")
    #expect(!FileManager.default.fileExists(atPath: pending.path))
    #expect(
      try await workspace.compose(to: f.output, publication: .managedFiles()).warnings.isEmpty)
  }

  @Test func pendingReadFailuresRemainFileErrorsAndDoNotModifyOutput() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try write(f.input.appending("default.yaml"), "old")
    let workspace = try await f.workspace()
    _ = try await workspace.compose(to: f.output, publication: .managedFiles())
    let records = try FileManager.default.contentsOfDirectory(
      at: url(f.locations.stateRoot.appending("publications")), includingPropertiesForKeys: nil)
    let record = try #require(records.first { $0.pathExtension == "plist" })
    let pending = record.deletingPathExtension().appendingPathExtension("pending.plist")
    try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
    try write(f.input.appending("default.yaml"), "new")
    do {
      _ = try await workspace.compose(to: f.output, publication: .managedFiles())
      Issue.record("pending read failure was ignored")
    } catch {
      guard error is any FileOperationErrorProtocol || error is FileSystemFailure else {
        Issue.record("unexpected failure: \(error)")
        return
      }
    }
    #expect(try read(f.output.appending("default.yaml")) == "old")
  }

  #if os(Windows)
    @Test func managedFilesCannotMutateAReplaceableDirectoryGeneration() async throws {
      let f = try Fixture()
      defer { f.remove() }
      try write(f.input.appending("default.yaml"), "old")
      let workspace = try await f.workspace()
      _ = try await workspace.compose(to: f.output)
      try write(f.input.appending("default.yaml"), "new")
      do {
        _ = try await workspace.compose(
          to: f.output, publication: .managedFiles(overwriteUnmanaged: true))
        Issue.record("managed files wrote through a generation junction")
      } catch {
        guard case .publicationModeConflict = error as? StateFailure else {
          Issue.record("unexpected failure: \(error)")
          return
        }
      }
      #expect(try read(f.output.appending("default.yaml")) == "old")
      _ = try await workspace.compose(to: f.output)
      #expect(try read(f.output.appending("default.yaml")) == "new")
    }
  #endif

  @Test func previewUpdateRefreshesWithoutChangingSavedDeclarationsOrLock() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(firstID, files: ["default.yaml": "old"])
    try f.remote()
    let workspace = try await f.workspace()
    let initial = try await workspace.resolve()
    let manifest = try read(f.manifest)
    let lock = try Data(contentsOf: url(f.lock))
    let candidate = try await workspace.configuration {
      $0.manifest.order.removeAll {
        if case .userFiles = $0 { return true }
        return false
      }
    }
    try await f.repositories.install(secondID, files: ["default.yaml": "preview"])
    let preview = try await workspace.resolve(
      refreshing: .packages(Set(initial.packages.map(\.id))), preview: candidate)
    #expect(preview.packages[0].commit.string == secondID)
    let inputs = try await workspace.fetch(preview)
    let plan = try await workspace.plan(inputs)
    _ = try await workspace.compose(plan, to: f.output)
    #expect(try read(f.output.appending("default.yaml")) == "preview")
    #expect(try read(f.manifest) == manifest)
    #expect(try Data(contentsOf: url(f.lock)) == lock)
    #expect(candidate.validate().isEmpty)
    #expect(try await workspace.resolve().packages[0].commit.string == firstID)
  }

  @Test(arguments: [false, true])
  func phaseProductsCannotCrossWorkspaceBoundaries(_ preview: Bool) async throws {
    let f = try Fixture()
    let other = try Fixture()
    defer {
      f.remove()
      other.remove()
    }
    try write(f.input.appending("default.yaml"), "local")
    let a = try await f.workspace()
    let b = try await other.workspace()
    let resolution: Resolution
    if preview {
      let snapshot = try await a.configuration()
      resolution = try await a.resolve(preview: snapshot)
    } else {
      resolution = try await a.resolve()
    }
    let inputs = try await a.fetch(resolution)
    let plan = try await a.plan(inputs)
    let expected = StateFailure.foreignSnapshot
    await #expect(throws: expected) { _ = try await b.fetch(resolution) }
    await #expect(throws: expected) { _ = try await b.cachedInputs(resolution) }
    await #expect(throws: expected) { _ = try await b.plan(inputs) }
    await #expect(throws: expected) { _ = try await b.compose(plan, to: other.output) }
    #expect(!exists(other.lock) && !exists(other.output))
    #expect(await other.repositories.counts().0 == 0)
    #expect(await other.downloads.count() == 0)
  }

  @Test(arguments: [false, true])
  func alreadyCachedResourcesAreRejectedWhenTheHostLimitIsLowered(_ network: Bool) async throws {
    let f = try Fixture()
    defer { f.remove() }
    let resource = URL(string: "https://resources.test/extra.txt")!
    await f.downloads.set(resource, "cached bytes")
    try await f.repositories.install(
      firstID, files: ["recipe.yaml": fixtureText("Recipes/implicit-download.recipe.yaml")])
    try f.remote()
    let permissive = try await f.workspace()
    _ = try await permissive.resolve()
    _ = try await permissive.fetch()
    let before = await f.downloads.count()
    let lock = try Data(contentsOf: url(f.lock))
    let strict = try await f.workspace(options: WorkspaceOptions(maximumResourceBytes: 4))
    await #expect(
      throws: NetworkFailure.sizeLimitExceeded(url: resource, maximumBytes: 4)
    ) {
      if network { _ = try await strict.fetch() } else { _ = try await strict.cachedInputs() }
    }
    #expect(await f.downloads.count() == before)
    #expect(try Data(contentsOf: url(f.lock)) == lock)
  }
  @Test func editedResolutionFailureLeavesAllDocumentsUnchanged() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let workspace = try await f.workspace()
    let request = try PackageRequest(source: .git(RepositoryRequest(url: endpoint)))
    await f.repositories.rejecting(resolution: true)
    await #expect(throws: NetworkFailure.self) {
      _ = try await workspace.update(
        preparation: .deferred, { $0.addPackage("new", request: request) }
      ).resolution
    }
    #expect(!exists(f.manifest) && !exists(f.overrides) && !exists(f.lock))
    try write(f.manifest, ManifestDocument().yaml())
    _ = try await workspace.resolve()
    let originalManifest = try read(f.manifest)
    let originalLock = try Data(contentsOf: url(f.lock))
    await #expect(throws: PinewindError.self) {
      _ = try await workspace.update(
        preparation: .deferred, { $0.addPackage("new", request: request) }
      ).resolution
    }
    #expect(try read(f.manifest) == originalManifest)
    #expect(try Data(contentsOf: url(f.lock)) == originalLock)
  }

  @Test func committedEditsSurvivePreparationFailureAndRetryUsesTheirBinding() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(firstID, files: ["default.yaml": "remote"])
    let workspace = try await f.workspace()
    let request = try PackageRequest(source: .git(RepositoryRequest(url: endpoint)))
    let resolution = try await workspace.update(
      preparation: .deferred,
      {
        $0.addPackage("new", request: request)
      }
    ).resolution
    let manifest = try read(f.manifest)
    let lock = try Data(contentsOf: url(f.lock))
    try FileManager.default.removeItem(at: url(f.locations.cacheRoot))
    await f.repositories.rejecting(preparation: true)
    await #expect(throws: NetworkFailure.self) { _ = try await workspace.fetch(resolution) }
    #expect(try read(f.manifest) == manifest)
    #expect(try Data(contentsOf: url(f.lock)) == lock)
    #expect(!exists(f.output))
    await f.repositories.rejecting()
    _ = try await workspace.fetch(resolution)
    _ = try await workspace.compose(to: f.output)
    #expect(try read(f.output.appending("default.yaml")) == "remote")
  }

  @Test func editedResolutionPreflightsAllDocumentsBeforeSaving() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(firstID, files: ["default.yaml": "remote"])
    let workspace = try await f.workspace()
    let request = try PackageRequest(source: .git(RepositoryRequest(url: endpoint)))
    _ = try await workspace.resolve()
    let lock = try Data(contentsOf: url(f.lock))
    await f.repositories.pauseNext()
    let task = Task {
      try await workspace.update(preparation: .deferred, { $0.addPackage("new", request: request) })
        .resolution
    }
    while !(await f.repositories.didStart()) { try await Task.sleep(for: .milliseconds(5)) }
    let external = try ManifestDocument(order: []).yaml()
    try write(f.manifest, external)
    await f.repositories.release()
    await #expect(throws: StateFailure.self) { _ = try await task.value }
    #expect(try read(f.manifest) == external)
    #expect(try Data(contentsOf: url(f.lock)) == lock)
  }

  @Test func candidateInsertionAndRemovalCoordinateOrderAndOverrides() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let workspace = try await f.workspace()
    let request = try PackageRequest(source: .directory(.path(f.input)))
    let candidate = try await workspace.configuration { draft in
      draft.addPackage("first", request: request)
      draft.addPackage("last", request: request, insertion: .after("self"))
      draft.addPackage("middle", request: request, insertion: .before("self"))
      draft.manifest.order.append(.named("first"))
      draft.redirectPackage("first", to: .path(f.input))
      draft.removePackage("first")
    }
    #expect(
      candidate.manifest.order == [.named("middle"), .userFiles(FileFilter()), .named("last")])
    #expect(candidate.localOverrides?.names["first"] == nil)
    #expect(candidate.validate().isEmpty)
    let diagnostics = try await workspace.validate { draft in
      draft.addPackage("middle", request: request)
      draft.manifest.order.append(.named("middle"))
      draft.addPackage("new", request: request, insertion: .after("middle"))
      draft.addPackage("other", request: request, insertion: .before("absent"))
    }
    #expect(diagnostics.count == 2)
    #expect(!exists(f.manifest))
  }

  @Test func editedRemovalSavesSharedReferencesAndLocalOverridesTogether() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let workspace = try await f.workspace()
    let request = try PackageRequest(source: .directory(.path(f.input)))
    _ = try await workspace.update(
      preparation: .deferred,
      {
        $0.addPackage("local", request: request)
        $0.manifest.order.append(.named("local"))
        $0.redirectPackage("local", to: .path(f.input))
      }
    ).resolution
    #expect(exists(f.overrides))
    _ = try await workspace.update(preparation: .deferred, { $0.removePackage("local") }).resolution
    let snapshot = try await workspace.configuration()
    #expect(snapshot.manifest.names.isEmpty)
    #expect(snapshot.manifest.order == [.userFiles(FileFilter())])
    #expect(snapshot.localOverrides?.names.isEmpty == true)
    _ = try await workspace.fetch()
  }

  @Test func namedUpdateRefreshesResourcesAfterDeclarationMetadataChanges() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let resource = URL(string: "https://resources.test/extra.txt")!
    await f.downloads.set(resource, "first")
    try await f.repositories.install(
      firstID, files: ["recipe.yaml": fixtureText("Recipes/implicit-download.recipe.yaml")])
    try f.remote()
    let workspace = try await f.workspace()
    let first = try await workspace.resolve()
    _ = try await workspace.update(preparation: .deferred) {
      $0.manifest.names["package"]?.exclude = .value(["unused.txt"])
    }
    await f.downloads.set(resource, "second")
    let updated = try await workspace.resolve(refreshingPackagesNamed: ["package"])
    #expect(updated.packages[0].commit == first.packages[0].commit)
    #expect(updated.packages[0].resources != first.packages[0].resources)
  }

  @Test func namedUpdateHandlesEditedOrderAndPreservesOtherPins() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(firstID, files: ["default.yaml": "first"])
    let workspace = try await f.workspace()
    let first = try PackageRequest(
      source: .git(RepositoryRequest(url: endpoint, revision: .branch("main"))))
    let other = try PackageRequest(
      source: .git(
        RepositoryRequest(
          url: URL(string: "https://example.com/other.git")!, revision: .branch("main"))))
    _ = try await workspace.update(
      preparation: .deferred,
      {
        $0.addPackage("first", request: first)
        $0.addPackage("other", request: other)
      }
    ).resolution
    _ = try await workspace.update(preparation: .deferred) { $0.moveEntry(from: 0, to: 2) }
    try await f.repositories.install(secondID, files: ["default.yaml": "second"])
    let updated = try await workspace.resolve(refreshingPackagesNamed: ["first"])
    #expect(updated.packages.first(where: { $0.request == first })?.commit.string == secondID)
    #expect(updated.packages.first(where: { $0.request == other })?.commit.string == firstID)
    let lock = try Data(contentsOf: url(f.lock))
    await #expect(throws: DeclarationFailure.self) {
      _ = try await workspace.resolve(refreshingPackagesNamed: ["absent"])
    }
    #expect(try Data(contentsOf: url(f.lock)) == lock)
  }

  @Test func managedPublicationPreservesRuntimeIdentityAndModifiedObsoleteFiles() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try write(f.input.appending("schema.yaml"), "first")
    try write(f.input.appending("old.txt"), "owned")
    try write(f.input.appending("edited.txt"), "owned")
    let runtime = f.output.appending("words.userdb/data")
    try write(runtime, "runtime")
    try write(f.output.appending("installation.yaml"), "installation")
    let handle = try FileHandle(forWritingTo: url(runtime))
    defer { try? handle.close() }
    let workspace = try await f.workspace()
    _ = try await workspace.compose(to: f.output, publication: .managedFiles())
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(" appended".utf8))
    #expect(try read(runtime) == "runtime appended")
    try write(f.output.appending("edited.txt"), "external")
    try FileManager.default.removeItem(at: url(f.input.appending("old.txt")))
    try FileManager.default.removeItem(at: url(f.input.appending("edited.txt")))
    try write(f.input.appending("schema.yaml"), "second")
    let result = try await workspace.compose(to: f.output, publication: .managedFiles())
    #expect(result.removedPaths.map(\.string) == ["old.txt"])
    #expect(result.preservedPaths.map(\.string) == ["edited.txt"])
    #expect(try read(f.output.appending("edited.txt")) == "external")
    #expect(try read(f.output.appending("schema.yaml")) == "second")
    #expect(try read(f.output.appending("installation.yaml")) == "installation")
    #expect(try read(runtime) == "runtime appended")
    #expect(await f.repositories.counts().0 == 0)
    #expect(await f.downloads.count() == 0)
  }

  @Test func managedPublicationRecoversPendingOwnershipAndRejectsCorruptRecords() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try write(f.input.appending("old.txt"), "owned")
    let workspace = try await f.workspace()
    _ = try await workspace.compose(to: f.output, publication: .managedFiles())
    let records = try FileManager.default.contentsOfDirectory(
      at: url(f.locations.stateRoot.appending("publications")), includingPropertiesForKeys: nil)
    let record = try #require(records.first(where: { $0.pathExtension == "plist" }))
    let pending = record.deletingPathExtension().appendingPathExtension("pending.plist")
    try FileManager.default.moveItem(at: record, to: pending)
    try FileManager.default.removeItem(at: url(f.input.appending("old.txt")))
    let recovered = try await workspace.compose(to: f.output, publication: .managedFiles())
    #expect(recovered.removedPaths.map(\.string) == ["old.txt"])
    #expect(!FileManager.default.fileExists(atPath: pending.path))
    #expect(FileManager.default.fileExists(atPath: record.path))
    try Data("invalid".utf8).write(to: record)
    try write(f.input.appending("new.txt"), "new")
    do {
      _ = try await workspace.compose(to: f.output, publication: .managedFiles())
      Issue.record("invalid publication record accepted")
    } catch {
      guard case .invalidPublicationRecord = error as? StateFailure
      else {
        Issue.record("unexpected error: \(error)")
        return
      }
    }
    #expect(!exists(f.output.appending("new.txt")))
  }

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
          guard case .overlappingPaths = error as? FileSystemFailure
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
    await #expect(throws: ConfigurationValidationError.self) {
      _ = try await workspace.update { $0.localOverrides = LocalOverridesDocument() }
    }
    let result = try await workspace.compose(to: "relative-output")
    #expect(exists(result.directory))
    #expect(exists(f.root.appending("relative-output")))
  }
  @Test func candidatesAreDetachedAndOnlyAppliedExplicitly() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let workspace = try await f.workspace()
    let candidate = try await workspace.configuration { $0.manifest.order = [] }
    #expect(candidate.manifest.order.isEmpty)
    #expect(try await workspace.configuration().manifest.order == [.userFiles(FileFilter())])
    #expect(!exists(f.manifest) && !exists(f.lock))
    _ = try await workspace.apply(candidate)
    #expect(try await workspace.configuration().manifest.order.isEmpty)
    _ = try await workspace.update { $0.localOverrides = LocalOverridesDocument() }
    #expect(exists(f.overrides))
    _ = try await workspace.update { $0.localOverrides = nil }
    #expect(!exists(f.overrides))
    #expect(candidate.manifest.order.isEmpty)
  }
  @Test func previewDoesNotWriteSharedDocumentsOrLock() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try await f.repositories.install(firstID, files: ["default.yaml": "value: preview"])
    let workspace = try await f.workspace()
    let request = try PackageRequest(
      source: .git(RepositoryRequest(url: endpoint, revision: .branch("main"))))
    let snapshot = try await workspace.configuration { $0.addPackage("package", request: request) }
    let resolution = try await workspace.resolve(preview: snapshot)
    let inputs = try await workspace.fetch(resolution)
    let plan = try await workspace.plan(inputs)
    #expect(try await workspace.compose(plan, to: f.output).paths.map(\.string) == ["default.yaml"])
    #expect(!exists(f.manifest))
    #expect(!exists(f.lock))
    #expect(snapshot.validate().isEmpty)
  }
  @Test func savedOperationsIgnoreUnsavedDraftsAndDetectStalePublication() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try write(f.input.appending("schema.yaml"), "value: saved")
    let workspace = try await f.workspace()
    _ = try await workspace.update(preparation: .deferred) { _ in }
    let inputs = try await workspace.cachedInputs()
    let plan = try await workspace.plan(inputs)
    let candidate = try await workspace.configuration { $0.manifest.order = [] }
    #expect(try await workspace.compose(to: f.output).paths.count == 1)
    _ = try await workspace.apply(candidate)
    await #expect(throws: StateFailure.self) {
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
    await #expect(throws: LockFailure.self) { _ = try await workspace.compose(to: f.output) }
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
    _ = try await workspace.update(preparation: .deferred) {
      $0.manifest.order.insert(.userFiles(FileFilter()), at: 0)
    }
    #expect(try await workspace.resolve().packages.first?.commit.string == firstID)
    #expect(try await workspace.resolve(refreshing: .all).packages.first?.commit.string == secondID)
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
    let updated = try await workspace.resolve(
      refreshing: .resources(Set(resolution.packages[0].resourceIDs)))
    #expect(updated.packages[0].commit.string == firstID)
    #expect(updated.packages[0].resources != resolution.packages[0].resources)
    _ = try await workspace.compose(to: f.output)
    #expect(try read(f.output.appending("extra.txt")) == "second")
  }
  @Test(arguments: ["resolve", "update", "recovery", "development"])
  func recipeDownloadsRespectHostLimits(_ operation: String) async throws {
    let f = try Fixture()
    defer { f.remove() }
    let resource = URL(string: "https://resources.test/extra.txt")!
    let recipe = try fixtureText("Recipes/implicit-download.recipe.yaml")
    try await f.repositories.install(firstID, files: ["recipe.yaml": recipe])
    try f.remote()
    let workspace = try await f.workspace(options: WorkspaceOptions(maximumResourceBytes: 8))
    var resolution: Resolution?
    var baseline: Data?
    if operation == "update" || operation == "recovery" {
      await f.downloads.set(resource, "first")
      resolution = try await workspace.resolve()
      _ = try await workspace.fetchAndCompose(to: f.output)
      baseline = try Data(contentsOf: url(f.lock))
      if operation == "recovery" {
        try FileManager.default.removeItem(at: url(f.locations.cacheRoot.appending("resources")))
      }
    } else if operation == "development" {
      // Resolve the shared package first; only the local override introduces a download.
      try await f.repositories.install(secondID, files: ["default.yaml": "remote"])
      _ = try await workspace.resolve()
      baseline = try Data(contentsOf: url(f.lock))
      let local = f.root.appending("development")
      try write(local.appending("recipe.yaml"), recipe)
      _ = try await workspace.update(preparation: .deferred) {
        $0.redirectPackage("package", to: .path(local))
      }
    }
    // This injected downloader ignores its limit, so this also tests the store's final check.
    await f.downloads.set(resource, String(repeating: "x", count: 9))
    await #expect(
      throws: NetworkFailure.sizeLimitExceeded(url: resource, maximumBytes: 8)
    ) {
      switch operation {
      case "update":
        _ = try await workspace.resolve(
          refreshing: .resources(Set(try #require(resolution).packages[0].resourceIDs)))
      case "recovery": _ = try await workspace.fetchAndCompose(to: f.output)
      case "development": _ = try await workspace.fetch(mode: .development)
      default: _ = try await workspace.resolve()
      }
    }
    #expect(await f.downloads.requestedLimits(resource).allSatisfy { $0 == 8 })
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: f.locations.cacheRoot.appending("downloads").string
      ).isEmpty)
    if let baseline {
      #expect(try Data(contentsOf: url(f.lock)) == baseline)
      if operation == "development" {
        #expect(!exists(f.output))
      } else {
        #expect(try read(f.output.appending("extra.txt")) == "first")
      }
    } else {
      #expect(!exists(f.lock))
    }
  }
  @Test(arguments: [32, 128])
  func importCacheRecoveryRetainsItsStricterLimit(_ hostLimit: Int) async throws {
    let f = try Fixture()
    defer { f.remove() }
    let remote = URL(string: "https://conf.test/packages.conf")!
    await f.downloads.set(remote, "package_list=(rime/first)\n")
    try await f.repositories.install(firstID, files: ["default.yaml": "imported"])
    try write(f.manifest, "version: 1\norder: [{import: \(remote.absoluteString)}]\n")
    let workspace = try await f.workspace(
      options: WorkspaceOptions(
        imports: ImportLimits(timeout: .seconds(60), maximumFileBytes: 64),
        maximumResourceBytes: hostLimit))
    _ = try await workspace.resolve()
    _ = try await workspace.fetchAndCompose(to: f.output)
    let baseline = try Data(contentsOf: url(f.lock))
    try FileManager.default.removeItem(at: url(f.locations.cacheRoot.appending("resources")))
    await f.downloads.set(remote, String(repeating: "#", count: 65))
    let limit = min(hostLimit, 64)
    await #expect(
      throws: NetworkFailure.sizeLimitExceeded(url: remote, maximumBytes: limit)
    ) {
      _ = try await workspace.fetchAndCompose(to: f.output)
    }
    #expect(await f.downloads.requestedLimits(remote) == [limit, limit])
    #expect(try Data(contentsOf: url(f.lock)) == baseline)
    #expect(try read(f.output.appending("default.yaml")) == "imported")
  }
  @Test(arguments: [0, -1])
  func resourceLimitMustBePositive(_ maximumBytes: Int) async throws {
    let f = try Fixture()
    defer { f.remove() }
    await #expect(throws: StateFailure.invalidOptions) {
      _ = try await f.workspace(options: WorkspaceOptions(maximumResourceBytes: maximumBytes))
    }
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
    await #expect(throws: CacheFailure.self) {
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
    _ = try await workspace.update(preparation: .deferred) {
      $0.redirectPackage("package", to: .path(local))
    }
    let prepared = try await workspace.cachedInputs()
    _ = try await workspace.compose(workspace.plan(prepared), to: f.output)
    try write(local.appending("default.yaml"), "local edited")
    _ = try await workspace.compose(workspace.plan(prepared), to: f.output)
    #expect(try read(f.output.appending("default.yaml")) == "local edited")
    #expect(try Data(contentsOf: url(f.lock)) == originalLock)
    await #expect(throws: FileSystemFailure.self) {
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
    await #expect(throws: DeclarationFailure.self) { _ = try await workspace.fetch() }
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
    await #expect(throws: StateFailure.self) { _ = try await task.value }
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
    let snapshot = try await a.configuration()
    await #expect(throws: StateFailure.self) { _ = try await b.resolve(preview: snapshot) }
    await #expect(throws: StateFailure.foreignSnapshot) {
      _ = try await b.resolve(refreshing: .all, preview: snapshot)
    }
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
    _ = try await workspace.resolve(refreshing: .packages(Set(first.packages.map(\.id))))
    await #expect(throws: StateFailure.self) {
      _ = try await workspace.resolve(refreshing: .packages(Set(first.packages.map(\.id))))
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
    _ = try await workspace.resolve(refreshing: .all)
    #expect(await f.repositories.counts().0 == 0)
    #expect(try await workspace.compose(to: f.output).paths.map(\.string) == ["default.yaml"])
  }
  @Test(arguments: [false, true])
  func importSelectionFollowsRequestsAfterManifestEdits(_ duplicate: Bool) async throws {
    let f = try Fixture()
    defer { f.remove() }
    let selected = URL(string: "https://conf.test/selected.conf")!
    let other = URL(string: "https://conf.test/other.conf")!
    await f.downloads.set(selected, "package_list=(rime/first)\n")
    await f.downloads.set(other, "package_list=(rime/other)\n")
    try await f.repositories.install(firstID, files: ["default.yaml": "imported"])
    try write(f.manifest, "version: 1\norder: [{import: \(other)}, {import: \(selected)}]\n")
    let workspace = try await f.workspace()
    let initial = try await workspace.resolve()
    let id = initial.imports[1].id
    // Insert an unrelated package before the selected import; its old index is occupied by another import.
    let prefix = "{url: \(endpoint.absoluteString)}, {import: \(other)}"
    let suffix = duplicate ? ", {import: \(selected)}" : ""
    try write(f.manifest, "version: 1\norder: [\(prefix), {import: \(selected)}\(suffix)]\n")
    await f.downloads.set(selected, "package_list=(rime/first rime/second)\n")
    let updated = try await workspace.resolve(refreshing: .imports([id]))
    let refreshed = updated.imports.filter { $0.id.request == id.request }
    #expect(refreshed.count == (duplicate ? 2 : 1))
    #expect(refreshed.allSatisfy { $0.packages.count == 2 && $0.id.index >= 2 })
    #expect(updated.imports[0].packages == initial.imports[0].packages)
    #expect(await f.downloads.requestedLimits(other).count == 1)
    #expect(await f.downloads.requestedLimits(selected).count > 1)
    await #expect(throws: StateFailure.unknownSelection) {
      _ = try await workspace.resolve(refreshing: .imports([id]))
    }
  }
  @Test func removedImportSelectionFailsWithoutChangingTheLock() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let remote = URL(string: "https://conf.test/packages.conf")!
    await f.downloads.set(remote, "package_list=(rime/first)\n")
    try await f.repositories.install(firstID, files: ["default.yaml": "imported"])
    try write(f.manifest, "version: 1\norder: [{import: \(remote)}]\n")
    let workspace = try await f.workspace()
    let initial = try await workspace.resolve()
    let baseline = try Data(contentsOf: url(f.lock))
    try write(f.manifest, "version: 1\norder: []\n")
    await #expect(throws: StateFailure.unknownSelection) {
      _ = try await workspace.resolve(refreshing: .imports(Set(initial.imports.map(\.id))))
    }
    #expect(try Data(contentsOf: url(f.lock)) == baseline)
    #expect(await f.downloads.count() == 1)
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
    let updated = try await workspace.resolve(refreshing: .imports(Set(initial.imports.map(\.id))))
    #expect(updated.imports[0].packages.count == 2)
    await #expect(throws: StateFailure.self) {
      _ = try await workspace.resolve(refreshing: .imports(Set(initial.imports.map(\.id))))
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
      _ = try await workspace.resolve(refreshing: .imports(Set(initial.imports.map(\.id))))
    } throws: { error in
      return String(describing: error).contains("permission denied: /outside.conf")
    }
    #expect(try Data(contentsOf: url(f.lock)) == baseline)
    await f.downloads.set(remote, String(repeating: "#padding\n", count: 40))
    let bounded = try await Workspace.open(
      locations: f.locations,
      services: WorkspaceServices(repositories: f.repositories, resources: f.downloads),
      options: WorkspaceOptions(imports: ImportLimits(timeout: .seconds(60), maximumFileBytes: 64)))
    await #expect {
      _ = try await bounded.resolve(refreshing: .all)
    } throws: {
      if case .sizeLimitExceeded = $0 as? NetworkFailure {
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
    let diagnostics = try await workspace.validate {
      $0.manifest.order = [.named("missing-a"), .named("missing-b")]
    }
    #expect(diagnostics.count == 2)
    #expect(
      diagnostics.allSatisfy { diagnostic in
        if case .configuration(let document) = diagnostic.error,
          case .unknownName = document.underlyingError as? DeclarationFailure
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
