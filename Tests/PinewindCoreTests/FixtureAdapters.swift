// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Fixture-only adapters keep the established semantic regressions independent of URL-based fixture setup.
import Foundation
import SystemPackage

@testable import PinewindCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

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
typealias Configuration = ConfigurationSession
extension ConfigurationSession {
  static func load(
    inputRoot: URL, localStateRoot: URL, coordinator: (any FileAccessCoordinating)? = nil
  ) async throws -> ConfigurationSession {
    let locations = try fixtureLocations(input: inputRoot, local: localStateRoot)
    let store = ConfigurationStore(locations, coordinator: coordinator)
    return ConfigurationSession(snapshot: try await store.load(), store: store)
  }
  func edit(
    _ operation: @Sendable (inout ManifestDocument, inout LocalOverridesDocument?) throws -> Void
  ) rethrows {
    try edit { draft in try operation(&draft.manifest, &draft.localOverrides) }
  }
  func evaluateShared() throws -> EvaluatedManifest { try snapshot().evaluate(.shared) }
  func evaluateEffective() throws -> EvaluatedManifest { try snapshot().evaluate(.effective) }
  func saveShared() async throws { _ = try await save(.shared) }
  func saveLocalOverrides() async throws { _ = try await save(.local) }
  func renamePackage(_ old: String, to new: String) throws {
    try edit { try $0.renamePackage(old, to: new) }
  }
  func removePackage(_ name: String) throws { try edit { try $0.removePackage(name) } }
}
extension FileAccessCoordinator {
  static func platform(localStateRoot: URL) -> any FileAccessCoordinating {
    platform(stateRoot: native(localStateRoot.appendingPathComponent("coordination")))
  }
}
extension EvaluatedManifest {
  static func parse(_ yaml: String, localOverrides: String? = nil, source: String = "pinewind.yaml")
    throws -> Self
  {
    try ManifestDocument.parse(yaml, source: source).evaluate(
      localOverrides: localOverrides.map { try LocalOverridesDocument.parse($0) })
  }
  static func load(inputRoot: URL, localStateRoot: URL, applyLocalOverrides: Bool = true)
    async throws -> Self
  {
    let configuration = try await Configuration.load(
      inputRoot: inputRoot, localStateRoot: localStateRoot)
    return try await applyLocalOverrides
      ? configuration.evaluateEffective() : configuration.evaluateShared()
  }
}
extension PackageFields {
  init(
    url: FieldOverride<URL> = .inherit, ref: FieldOverride<String>,
    recipe: FieldOverride<String> = .inherit,
    options: FieldOverride<[String: String]> = .inherit,
    include: FieldOverride<[String]> = .inherit,
    exclude: FieldOverride<[String]> = .inherit
  ) {
    let revision: FieldOverride<GitRevision>
    switch ref {
    case .inherit: revision = .inherit
    case .reset: revision = .reset
    case .value(let value): revision = .value(.reference(value))
    }
    self.init(
      url: url, revision: revision, recipe: recipe, options: options, include: include,
      exclude: exclude)
  }
  var ref: FieldOverride<String> {
    get {
      switch revision {
      case .inherit: return .inherit
      case .reset: return .reset
      case .value(let revision): return revision.reference.map { .value($0) } ?? .reset
      }
    }
    set {
      switch newValue {
      case .inherit: revision = .inherit
      case .reset: revision = .reset
      case .value(let value): revision = .value(.reference(value))
      }
    }
  }
}
extension PackageRequest {
  init(
    url: URL, ref: String?, commit: String? = nil, recipe: String? = nil,
    options: [String: String] = [:], filter: FileFilter = FileFilter()
  ) throws {
    guard ref == nil || commit == nil else { throw PinewindError("revision is mutually exclusive") }
    let revision: GitRevision? =
      try commit.map { .commit(try CommitID($0)) } ?? ref.map(GitRevision.reference)
    try self.init(url: url, revision: revision, recipe: recipe, options: options, filter: filter)
  }
  init(
    url: URL, commit: String, recipe: String? = nil, options: [String: String] = [:],
    filter: FileFilter = FileFilter()
  ) throws {
    try self.init(
      url: url, revision: .commit(CommitID(commit)), recipe: recipe, options: options,
      filter: filter)
  }
}
extension PinnedResource {
  init(url: URL, path: String, sha256: String) throws {
    try self.init(url: url, path: RelativePath(path), sha256: sha256)
  }
}
extension PreparedPackage {
  init(
    request: PackageRequest, directory: URL, commit: String? = nil, resources: [PinnedResource] = []
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
struct GitKitPackageFetcher: Sendable {
  let provider: GitKitRepositoryProvider
  let downloader: HTTPSResourceDownloader
  init(transport: (any GitTransport)? = nil, session: URLSession = .shared) {
    provider =
      transport.map(GitKitRepositoryProvider.init(transport:)) ?? GitKitRepositoryProvider()
    downloader = HTTPSResourceDownloader(session: session)
  }
  func resolveDefaultBranch(url: URL) async throws -> String {
    let value = try await provider.defaultBranchForFixture(url)
    return value
  }
  func resolveCommit(url: URL, ref: String) async throws -> String {
    let revision: GitRevision =
      SourceIdentity.isCommit(ref) ? .commit(try CommitID(ref)) : .reference(ref)
    return try await provider.resolve(RepositoryRequest(url: url, revision: revision)).commit.string
  }
  func prepareSource(url: URL, commit: String, cacheRoot: URL) async throws -> SourceSnapshot {
    try await provider.prepareSource(
      SourceIdentity(url: url, commit: commit), cacheRoot: NativePath.from(cacheRoot))
  }
  func prepareSource(url: URL, commit: CommitID, cacheRoot: URL) async throws -> SourceSnapshot {
    try await provider.prepareSource(
      SourceIdentity(url: url, commit: commit), cacheRoot: NativePath.from(cacheRoot))
  }
  func downloadFile(url: URL) async throws -> Data {
    let file = native(
      FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: file) }
    try await downloader.download(url, to: file)
    return try Data(contentsOf: file)
  }
  static func cacheKey(_ url: URL) -> String { GitKitRepositoryProvider.cacheKey(url) }
}
extension LockedPackage {
  init(request: PackageRequest, commit: String, resources: [PinnedResource] = []) throws {
    try self.init(request: request, commit: CommitID(commit), resources: resources)
  }
}
func fixtureSnapshot(_ manifest: EvaluatedManifest) throws -> ConfigurationSnapshot {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("pinewind-lock-fixture")
  let locations = try fixtureLocations(
    input: root.appendingPathComponent("input"), local: root.appendingPathComponent("local"))
  let order = manifest.entries.map { entry -> OrderEntry in
    switch entry {
    case .userFiles(let filter): return .userFiles(filter)
    case .importConf(let request): return .importConf(request)
    case .package(let request):
      return .package(
        PackageFields(
          url: .value(request.url), revision: request.revision.map { .value($0) } ?? .inherit,
          recipe: request.recipe.map { .value($0) } ?? .inherit, options: .value(request.options),
          include: request.filter.include.map { .value($0) } ?? .inherit,
          exclude: .value(request.filter.exclude)))
    }
  }
  return ConfigurationSnapshot(
    manifest: ManifestDocument(order: order), localOverrides: nil,
    sharedRevision: 0, localRevision: 0, sharedIsDirty: false, localIsDirty: false,
    locations: locations,
    baseline: DocumentBaseline(shared: nil, local: nil, lock: nil))
}
extension Resolution {
  init(declarations: EvaluatedManifest, expanded: EvaluatedManifest, packages: [LockedPackage])
    throws
  {
    try self.init(
      declarations: declarations, expanded: expanded, packages: packages,
      snapshot: fixtureSnapshot(declarations), preview: false)
  }
  func validate(against manifest: EvaluatedManifest) throws {
    guard try ResolutionCodec.signature(declarations) == ResolutionCodec.signature(manifest) else {
      throw PinewindError(.needsResolution, "declarations changed")
    }
  }
  func write(to file: URL) throws { try ResolutionCodec.encode(self).write(to: file) }
  static func read(from file: URL) throws -> Resolution {
    let bytes = try Data(contentsOf: file)
    guard bytes.starts(with: ResolutionCodec.magic) else {
      throw PinewindError(.incompatibleFormat, "unsupported lock")
    }
    let payload = try PropertyListDecoder().decode(
      ResolutionCodec.Payload.self, from: bytes.dropFirst(ResolutionCodec.magic.count))
    let shared = EvaluatedManifest(
      entries: try payload.declarations.map {
        try $0.decode(shared: EvaluatedManifest(entries: []))
      })
    return try ResolutionCodec.decode(bytes, snapshot: fixtureSnapshot(shared))
  }
}

extension GitKitRepositoryProvider {
  func defaultBranchForFixture(_ url: URL) async throws -> String {
    try await BlockingIO.run {
      try RemoteReferences(transport.advertise(url: Self.remoteURL(Self.sourceURL(url))))
        .defaultBranch()
    }
  }
}

extension SafePath {
  static func files(in root: URL) throws -> [String] { try files(in: NativePath.from(root)) }
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
