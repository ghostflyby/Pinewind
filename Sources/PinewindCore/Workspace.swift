// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BashInterpreter
import Foundation
import SystemPackage

public enum PreparationMode: Sendable { case locked, development }
public enum OperationPhase: Sendable { case resolving, updating, preparing, planning, composing }
public enum OperationEvent: Sendable {
  case started(OperationPhase)
  case item(URL)
  case completed(OperationPhase)
}
public typealias OperationProgress = @Sendable (OperationEvent) -> Void
public struct WorkspaceOptions: Sendable {
  public var imports: ImportLimits
  public init(imports: ImportLimits = ImportLimits()) { self.imports = imports }
}
public struct PreparedInputs: Sendable {
  public let manifest: EvaluatedManifest
  let packages: [PreparedPackage]
  let binding: InputBinding
}
struct InputBinding: Sendable {
  let snapshot: ConfigurationSnapshot
  let preview: Bool
  let lockBytes: Data?
  var coordinatedURLs: [URL]? = nil
  func validate() throws {
    guard !preview else { return }
    let urls =
      try coordinatedURLs
      ?? ConfigurationStore(snapshot.locations).documentLocations.map { try $0.url }
    guard try ConfigurationStore.read(urls[0]) == snapshot.baseline.shared,
      try ConfigurationStore.read(urls[1]) == lockBytes,
      try urls.count < 3 || ConfigurationStore.read(urls[2]) == snapshot.baseline.local
    else {
      throw PinewindError(.staleInput, "configuration or lock changed before publication")
    }
  }
}

public actor Workspace {
  public nonisolated let locations: WorkspaceLocations
  private let services: WorkspaceServices
  private let options: WorkspaceOptions
  private let store: ConfigurationStore
  private var resources: ResourceStore {
    ResourceStore(root: locations.cacheRoot, downloader: services.resources)
  }
  private init(
    locations: WorkspaceLocations, services: WorkspaceServices, options: WorkspaceOptions
  ) {
    self.locations = locations
    self.services = services
    self.options = options
    store = ConfigurationStore(locations)
  }
  public static func open(
    locations: WorkspaceLocations, services: WorkspaceServices = .live,
    options: WorkspaceOptions = WorkspaceOptions()
  ) async throws -> Workspace {
    try Task.checkCancellation()
    guard options.imports.maximumSources > 0, options.imports.maximumFileBytes > 0,
      options.imports.maximumTotalBytes > 0, options.imports.timeout > .zero
    else {
      throw PinewindError(.invalidConfiguration, "import limits must be positive")
    }
    return Workspace(locations: locations, services: services, options: options)
  }
  public func configuration() async throws -> ConfigurationSession {
    ConfigurationSession(snapshot: try await store.load(), store: store)
  }
  public func resolve(progress: OperationProgress? = nil) async throws -> Resolution {
    try await resolveSnapshot(store.load(), preview: false, update: nil, progress: progress)
  }
  public func resolve(preview: ConfigurationSnapshot, progress: OperationProgress? = nil)
    async throws -> Resolution
  {
    try check(preview)
    return try await resolveSnapshot(preview, preview: true, update: nil, progress: progress)
  }
  public func update(_ selection: UpdateSelection = .all, progress: OperationProgress? = nil)
    async throws -> Resolution
  {
    try await resolveSnapshot(store.load(), preview: false, update: selection, progress: progress)
  }
  public func update(
    _ selection: UpdateSelection = .all, preview: ConfigurationSnapshot,
    progress: OperationProgress? = nil
  ) async throws -> Resolution {
    try check(preview)
    return try await resolveSnapshot(preview, preview: true, update: selection, progress: progress)
  }
  private func check(_ snapshot: ConfigurationSnapshot) throws {
    guard snapshot.locations == locations else {
      throw PinewindError(.invalidConfiguration, "phase result belongs to another workspace")
    }
  }

  private func resolveSnapshot(
    _ snapshot: ConfigurationSnapshot, preview: Bool, update: UpdateSelection?,
    progress: OperationProgress?
  ) async throws -> Resolution {
    try check(snapshot)
    let phase: OperationPhase = update == nil ? .resolving : .updating
    progress?(.started(phase))
    let declarations = try snapshot.evaluate(.shared)
    let previous = snapshot.baseline.lock.flatMap { try? ResolutionCodec.reusable($0) }
    let oldPackages = previous?.packages ?? []
    let oldImports = previous?.imports ?? []
    try validateSelection(update, packages: oldPackages, imports: oldImports)
    let refreshAll: Bool = {
      if case .all = update { return true }
      return false
    }()
    let refreshedRepositories = Set(
      oldPackages.filter { selected($0.id, in: update) }.compactMap { repository($0.request)?.key })
    var imports: [ResolvedImport] = []
    var entries: [ManifestEntry] = []
    for (index, entry) in declarations.entries.enumerated() {
      try Task.checkCancellation()
      if case .importConf(let request) = entry {
        let id = ImportID(index: index, request: request)
        let force = refreshAll || selected(id, in: update)
        let imported: ResolvedImport
        if !force, let previous = oldImports.first(where: { $0.id.request == request }) {
          imported = ResolvedImport(
            id: id, packages: previous.packages, resources: previous.resources)
        } else {
          imported = try await expand(request, index: index, snapshot: snapshot)
        }
        imports.append(imported)
        entries += imported.packages.map(ManifestEntry.package)
      } else {
        entries.append(entry)
      }
    }
    var packages: [LockedPackage] = []
    var identities: [RepositoryKey: SourceIdentity] = [:]
    var requests = Set<PackageRequest>()
    for entry in entries {
      try Task.checkCancellation()
      guard case .package(let request) = entry, let repository = repository(request),
        requests.insert(request).inserted
      else { continue }
      progress?(.item(repository.url))
      let forceSource = refreshAll || refreshedRepositories.contains(repository.key)
      let identity: SourceIdentity
      if let prior = identities[repository.key] {
        identity = prior
      } else if !forceSource,
        let prior = oldPackages.first(where: { self.repository($0.request)?.key == repository.key })
      {
        identity = try SourceIdentity(url: repository.url, commit: prior.commit)
      } else if case .commit(let commit) = repository.revision {
        identity = try SourceIdentity(url: repository.url, commit: commit)
      } else {
        identity = try await services.repositories.resolve(repository)
      }
      try validate(identity, against: repository)
      identities[repository.key] = identity
      if !refreshAll, !selected(PackageID(request), in: update),
        !resourcesSelected(request, in: update),
        let old = oldPackages.first(where: { $0.request == request && $0.commit == identity.commit }
        )
      {
        packages.append(old)
        continue
      }
      let source = try await source(identity, network: true)
      let recipe = try await readRecipe(request, directory: source.directory)
      var pins: [PinnedResource] = []
      for download in recipe?.downloads ?? [] {
        let path = try RelativePath(download.path)
        let previous = oldPackages.filter { self.repository($0.request)?.key == repository.key }
          .flatMap(
            \.resources
          )
          .first { $0.url == download.url && $0.path == path }
        let force =
          refreshAll || selected(PackageID(request), in: update)
          || previous.map {
            selected(ResourceID(package: PackageID(request), resource: $0), in: update)
          } == true
        if !force, let previous {
          pins.append(previous)
        } else {
          pins.append(try await resources.pin(download.url, target: path))
        }
      }
      packages.append(try LockedPackage(request: request, commit: identity.commit, resources: pins))
    }
    var result = try Resolution(
      declarations: declarations, expanded: Manifest(entries: entries), packages: packages,
      imports: imports, snapshot: snapshot, preview: preview)
    if !preview {
      let bytes = try ResolutionCodec.encode(result)
      try await store.commitLock(bytes, expected: snapshot.baseline)
      result = try Resolution(
        declarations: declarations, expanded: result.expanded, packages: packages, imports: imports,
        snapshot: snapshot, preview: false, lockBytes: bytes)
    }
    progress?(.completed(phase))
    return result
  }

  public func fetch(
    _ resolution: Resolution? = nil, mode: PreparationMode = .locked,
    progress: OperationProgress? = nil
  ) async throws -> PreparedInputs {
    try await prepare(resolution, network: true, mode: mode, progress: progress)
  }
  public func cachedInputs(_ resolution: Resolution? = nil, progress: OperationProgress? = nil)
    async throws -> PreparedInputs
  {
    try await prepare(resolution, network: false, mode: .locked, progress: progress)
  }
  private func currentResolution() async throws -> Resolution {
    let snapshot = try await store.load()
    if let bytes = snapshot.baseline.lock {
      return try ResolutionCodec.decode(bytes, snapshot: snapshot)
    }
    let manifest = try snapshot.evaluate(.shared)
    guard
      !manifest.entries.contains(where: {
        if case .importConf = $0 { return true }
        if case .package(let request) = $0 { return !request.url.isFileURL }
        return false
      })
    else {
      throw PinewindError(.needsResolution, "resolve shared declarations before preparing packages")
    }
    return try Resolution(
      declarations: manifest, expanded: manifest, packages: [], snapshot: snapshot, preview: false)
  }
  private func prepare(
    _ supplied: Resolution?, network: Bool, mode: PreparationMode,
    progress: OperationProgress?
  ) async throws -> PreparedInputs {
    let resolution: Resolution
    if let supplied { resolution = supplied } else { resolution = try await currentResolution() }
    try check(resolution.snapshot)
    progress?(.started(.preparing))
    for imported in resolution.imports {
      for pin in imported.resources { try await resources.ensure(pin, network: network) }
    }
    let effective = try resolution.snapshot.evaluate(.effective)
    var entries: [ManifestEntry] = []
    var packages: [PreparedPackage] = []
    var identities: [RepositoryKey: SourceIdentity] = [:]
    var seen = Set<PackageRequest>()
    for (index, entry) in effective.entries.enumerated() {
      let expanded: [ManifestEntry]
      if case .importConf(let request) = entry {
        guard
          let imported = resolution.imports.first(where: {
            $0.id.index == index && $0.id.request == request
          })
        else { throw PinewindError(.needsResolution, "import has no locked expansion") }
        expanded = imported.packages.map(ManifestEntry.package)
      } else {
        expanded = [entry]
      }
      entries += expanded
      for entry in expanded {
        try Task.checkCancellation()
        guard case .package(let request) = entry, seen.insert(request).inserted else { continue }
        progress?(.item(request.url))
        let sharedRequest: PackageRequest? = {
          if resolution.declarations.entries.indices.contains(index),
            case .package(let package) = resolution.declarations.entries[index]
          {
            return package
          }
          return nil
        }()
        let locked =
          resolution.packages.first { $0.request == request }
          ?? sharedRequest.flatMap { original in
            resolution.packages.first { $0.request == original }
          }
          ?? resolution.packages.first {
            repository($0.request)?.key == repository(request)?.key && repository(request) != nil
          }
        let directory: FilePath
        let commit: String?
        if let repository = repository(request) {
          let identity: SourceIdentity
          if let locked, self.repository(locked.request)?.key == repository.key {
            identity = try SourceIdentity(url: repository.url, commit: locked.commit)
          } else {
            guard mode == .development, network else {
              throw PinewindError(
                .developmentRequired, "remote overrides require explicit development preparation")
            }
            if let cached = identities[repository.key] {
              identity = cached
            } else if case .commit(let pin) = repository.revision {
              identity = try SourceIdentity(url: repository.url, commit: pin)
            } else {
              identity = try await services.repositories.resolve(repository)
            }
          }
          try validate(identity, against: repository)
          identities[repository.key] = identity
          directory = try await source(identity, network: network).directory
          commit = identity.commit.string
        } else {
          directory = try NativePath.from(request.url)
          commit = nil
        }
        let recipe = try await readRecipe(request, directory: directory)
        var pins: [PinnedResource] = []
        for download in recipe?.downloads ?? [] {
          let path = try RelativePath(download.path)
          if let old = locked?.resources.first(where: { $0.url == download.url && $0.path == path }
          ),
            mode != .development || repository(request) != nil
          {
            try await resources.ensure(old, network: network)
            pins.append(old)
          } else {
            guard network, mode == .development else {
              throw PinewindError(
                .developmentRequired, "resource declaration requires development preparation",
                source: download.url.absoluteString)
            }
            pins.append(try await resources.pin(download.url, target: path))
          }
        }
        packages.append(
          try PreparedPackage(
            request: request, directory: directory, commit: commit, resources: pins))
      }
    }
    progress?(.completed(.preparing))
    return PreparedInputs(
      manifest: Manifest(entries: entries), packages: packages,
      binding: InputBinding(
        snapshot: resolution.snapshot, preview: resolution.preview, lockBytes: resolution.lockBytes)
    )
  }

  public func plan(_ inputs: PreparedInputs, progress: OperationProgress? = nil) async throws
    -> CompositionPlan
  {
    try check(inputs.binding.snapshot)
    progress?(.started(.planning))
    let localPackages = inputs.packages.filter { $0.request.url.isFileURL }
    let readLocations =
      [locations.userFilesRoot] + localPackages.map { FileLocation.fileURL($0.request.url) }
    let requests = try readLocations.map { FileAccessRequest(url: try $0.url, intent: .read) }
    let cache = locations.cacheRoot
    let excluded = try store.documentLocations.map { try $0.filePath }
    let result = try await store.coordinator.coordinate(requests) { urls in
      var prepared = inputs.packages
      for (index, package) in localPackages.enumerated() {
        if let position = prepared.firstIndex(where: { $0.request == package.request }) {
          prepared[position] = try PreparedPackage(
            request: package.request, directory: NativePath.from(urls[index + 1]), commit: nil,
            resources: package.resources)
        }
      }
      var views: [CompositionSnapshot] = []
      defer { withExtendedLifetime(views) {} }
      for index in prepared.indices where !prepared[index].resources.isEmpty {
        let package = prepared[index]
        let view = try CompositionSnapshot(root: cache.appending("views"))
        views.append(view)
        let destination = view.directory.appending("package")
        _ = try SafePath.files(in: package.directory)
        try FileManager.default.copyItem(at: package.directory, to: destination)
        for pin in package.resources {
          let resource = cache.appending("resources/" + pin.sha256)
          guard try SnapshotFiles.sha256(resource) == pin.sha256 else {
            throw PinewindError(.checksumMismatch, "cached resource checksum mismatch")
          }
          let file = try SafePath.file(pin.path.string, in: destination)
          try FileManager.default.createDirectory(
            at: file.removingLastComponent(), withIntermediateDirectories: true)
          if FileManager.default.fileExists(atPath: file.string) {
            try FileManager.default.removeItem(at: file)
          }
          try FileManager.default.copyItem(at: resource, to: file)
        }
        prepared[index] = try PreparedPackage(
          request: package.request, directory: destination, commit: package.commit,
          resources: package.resources)
      }
      var plan = try CompositionPlanner(snapshotRoot: cache.appending("planning")).plan(
        inputs.manifest,
        inputRoot: NativePath.from(urls[0]), packages: prepared, excluding: excluded)
      plan.binding = inputs.binding
      plan.sourceRoots += inputs.packages.map(\.directory)
      for (index, entry) in inputs.manifest.entries.enumerated() {
        if case .package(let request) = entry { plan.origins[index] = request.url }
      }
      return plan
    }
    progress?(.completed(.planning))
    return result
  }
  public func compose(
    _ plan: CompositionPlan, to output: FilePath, progress: OperationProgress? = nil
  ) async throws -> CompositionResult {
    if let binding = plan.binding { try check(binding.snapshot) }
    let output = try NativePath.absolute(output, relativeTo: locations.relativeTo)
    let protected =
      try store.documentLocations.map { try $0.filePath } + [
        locations.stateRoot, locations.cacheRoot,
      ]
    for path in protected {
      if try SafePath.overlaps(output, path) {
        throw PinewindError(.invalidPath, "output overlaps configuration or managed storage")
      }
    }
    progress?(.started(.composing))
    let requests = try store.documentLocations.map {
      FileAccessRequest(url: try $0.url, intent: .read)
    }
    let result = try await store.coordinator.coordinate(requests) { urls in
      var plan = plan
      plan.binding?.coordinatedURLs = urls
      try plan.binding?.validate()
      return try Composer().compose(plan, inputRoot: plan.sourceRoots[0], outputRoot: output)
    }
    progress?(.completed(.composing))
    return result
  }
  public func compose(to output: FilePath, progress: OperationProgress? = nil) async throws
    -> CompositionResult
  {
    let inputs = try await cachedInputs(progress: progress)
    let plan = try await self.plan(inputs, progress: progress)
    return try await compose(plan, to: output, progress: progress)
  }
  public func fetchAndCompose(
    to output: FilePath, mode: PreparationMode = .locked,
    progress: OperationProgress? = nil
  ) async throws -> CompositionResult {
    let inputs = try await fetch(mode: mode, progress: progress)
    let plan = try await self.plan(inputs, progress: progress)
    return try await compose(plan, to: output, progress: progress)
  }

  private func repository(_ request: PackageRequest) -> RepositoryRequest? {
    if case .git(let source) = request.source { return source }
    return nil
  }
  private func validate(_ identity: SourceIdentity, against request: RepositoryRequest) throws {
    guard try SourceIdentity.normalize(identity.url) == SourceIdentity.normalize(request.url),
      {
        if case .commit(let commit) = request.revision { return commit == identity.commit }
        return true
      }()
    else {
      throw PinewindError(
        .invalidConfiguration, "repository provider returned an unrelated source identity")
    }
  }
  private func source(_ identity: SourceIdentity, network: Bool) async throws -> SourceSnapshot {
    let cache = locations.cacheRoot
    let key = GitKitRepositoryProvider.cacheKey(try SourceIdentity.normalize(identity.url))
    let target = cache.appending("sources/" + key + "/" + identity.commit.string)
    let marker = FilePath(target.string + ".complete")
    let expected = Data(
      (try SourceIdentity.normalize(identity.url).absoluteString + "\n" + identity.commit.string)
        .utf8)
    if FileManager.default.fileExists(atPath: target.string),
      (try? Data(contentsOf: marker)) == expected
    {
      return try SourceSnapshot(identity: identity, directory: target)
    }
    guard network else {
      throw PinewindError(
        .contentMissing, "locked source is absent from cache", source: identity.url.absoluteString)
    }
    let supplied = try await services.repositories.prepareSource(identity, cacheRoot: cache)
    guard supplied.identity.commit == identity.commit,
      try SourceIdentity.normalize(supplied.identity.url) == SourceIdentity.normalize(identity.url)
    else { throw PinewindError(.invalidConfiguration, "provider snapshot identity mismatch") }
    try await BlockingIO.run {
      try NativeLock.withLock(cache.appending("locks/source-" + key + ".lock")) {
        if FileManager.default.fileExists(atPath: target.string),
          (try? Data(contentsOf: marker)) == expected
        {
          return
        }
        guard try !SafePath.overlaps(supplied.directory, target) else {
          throw PinewindError(.invalidPath, "provider source overlaps the managed source cache")
        }
        _ = try SafePath.files(in: supplied.directory)
        let candidate = target.removingLastComponent().appending(".candidate-" + UUID().uuidString)
        try FileManager.default.createDirectory(
          at: candidate.removingLastComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: candidate) }
        try FileManager.default.copyItem(at: supplied.directory, to: candidate)
        try Cancellation.check()
        if FileManager.default.fileExists(atPath: target.string) {
          try FileManager.default.removeItem(at: target)
        }
        if FileManager.default.fileExists(atPath: marker.string) {
          try FileManager.default.removeItem(at: marker)
        }
        try FileManager.default.moveItem(at: candidate, to: target)
        try expected.write(to: marker, options: .atomic)
      }
    }
    return try SourceSnapshot(identity: identity, directory: target)
  }
  private func readRecipe(_ request: PackageRequest, directory: FilePath) async throws -> Recipe? {
    try await store.coordinator.coordinate([
      FileAccessRequest(url: directory.foundationURL, intent: .read)
    ]) { urls in
      try Recipe.load(
        request: request, directory: NativePath.from(urls[0]), read: { try Data(contentsOf: $0) })
    }
  }
  private func expand(_ request: ConfImport, index: Int, snapshot: ConfigurationSnapshot)
    async throws -> ResolvedImport
  {
    do {
      let importer = PlumImporter(limits: options.imports)
      let descriptors: [String]
      let pins: [PinnedResource]
      if request.source.hasPrefix(":") {
        descriptors = try BuiltinPackageLists.descriptors(for: request.source)
        pins = []
      } else if let url = URL(string: request.source), url.scheme?.lowercased() == "https" {
        guard !url.lastPathComponent.isEmpty else {
          throw PinewindError(.invalidConfiguration, "remote conf URL requires a filename")
        }
        let view = try await BlockingIO.run {
          try CompositionSnapshot(root: self.locations.cacheRoot.appending("imports"))
        }
        defer { withExtendedLifetime(view) {} }
        let capture = RemoteConfCapture(
          url: url, directory: view.directory, store: resources, limits: options.imports)
        let file = view.directory.appending(url.lastPathComponent)
        descriptors = try await importer.evaluate(
          file: file, resourceRoot: view.directory, variables: request.variables,
          fileSystem: RemoteConfFileSystem(capture: capture, directory: view.directory))
        pins = await capture.resources()
      } else {
        guard !request.source.contains("://") else {
          throw PinewindError(
            .invalidConfiguration, "conf sources require HTTPS or a relative local path")
        }
        let manifest = try snapshot.locations.configuration.manifest.url
        let path =
          request.source.hasPrefix("./") ? String(request.source.dropFirst(2)) : request.source
        let source = try SafePath.file(
          path, in: NativePath.from(manifest.deletingLastPathComponent()))
        let view = try await BlockingIO.run {
          try CompositionSnapshot(root: snapshot.locations.cacheRoot.appending("imports"))
        }
        defer { withExtendedLifetime(view) {} }
        let rootURL = manifest.deletingLastPathComponent().appendingPathComponent(path)
          .deletingLastPathComponent()
        let capture = LocalConfCapture(
          root: rootURL, directory: view.directory, coordinator: store.coordinator,
          limits: options.imports)
        let original = MountedFileSystem(
          mounts: [
            .init(virtual: "/conf", host: source.removingLastComponent().string, readOnly: true)
          ], backing: RealFileSystem())
        descriptors = try await importer.evaluate(
          file: view.directory.appending(source.lastPathComponent), resourceRoot: view.directory,
          variables: request.variables,
          fileSystem: RemoteConfFileSystem(
            capture: capture, directory: view.directory, original: original))
        pins = []
      }
      return try ResolvedImport(
        id: ImportID(index: index, request: request),
        packages: descriptors.map(PlumImporter.package),
        resources: pins)
    } catch {
      throw PinewindError.wrap(error, source: request.source)
    }
  }
  private func selected(_ id: PackageID, in selection: UpdateSelection?) -> Bool {
    if case .packages(let ids) = selection { return ids.contains { $0.request == id.request } }
    return false
  }
  private func selected(_ id: ImportID, in selection: UpdateSelection?) -> Bool {
    if case .imports(let ids) = selection {
      return ids.contains { $0.index == id.index && $0.request == id.request }
    }
    return false
  }
  private func selected(_ id: ResourceID, in selection: UpdateSelection?) -> Bool {
    if case .resources(let ids) = selection {
      return ids.contains { $0.package.request == id.package.request && $0.resource == id.resource }
    }
    return false
  }
  private func resourcesSelected(_ request: PackageRequest, in selection: UpdateSelection?) -> Bool
  {
    if case .resources(let ids) = selection {
      return ids.contains { $0.package.request == request }
    }
    return false
  }
  private func validateSelection(
    _ selection: UpdateSelection?, packages: [LockedPackage], imports: [ResolvedImport]
  ) throws {
    let valid: Bool
    switch selection {
    case .packages(let ids): valid = ids.isSubset(of: Set(packages.map(\.id)))
    case .imports(let ids): valid = ids.isSubset(of: Set(imports.map(\.id)))
    case .resources(let ids): valid = ids.isSubset(of: Set(packages.flatMap(\.resourceIDs)))
    default: valid = true
    }
    guard valid else {
      throw PinewindError(.staleInput, "update selection does not belong to the current resolution")
    }
  }
}
