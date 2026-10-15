// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

public enum ConfigurationScope: Sendable { case shared, effective }
public enum ConfigurationLayer: Sendable { case shared, local }
public struct SaveReceipt: Sendable {
  public let layer: ConfigurationLayer
  public let revision: UInt64
}
public struct ConfigurationDraft: Hashable, Sendable {
  public var manifest: ManifestDocument
  public var localOverrides: LocalOverridesDocument?
  public init(
    manifest: ManifestDocument = ManifestDocument(), localOverrides: LocalOverridesDocument? = nil
  ) {
    self.manifest = manifest
    self.localOverrides = localOverrides
  }
  public mutating func addPackage(_ name: String, request: PackageRequest) throws {
    guard name != "self", manifest.names[name] == nil else {
      throw PinewindError("package name is reserved or already defined")
    }
    var fields = PackageFields(
      url: .value(request.url), recipe: request.recipe.map { .value($0) } ?? .reset,
      options: .value(request.options),
      include: request.filter.include.map { .value($0) } ?? .reset,
      exclude: .value(request.filter.exclude))
    if let revision = request.revision { fields.revision = .value(revision) }
    manifest.names[name] = fields
    manifest.order.append(.named(name))
  }
  public mutating func renamePackage(_ old: String, to new: String) throws {
    guard old == new || localOverrides?.names[new] == nil else {
      throw PinewindError("local package name already exists")
    }
    try manifest.renamePackage(old, to: new)
    if old != new, let fields = localOverrides?.names.removeValue(forKey: old) {
      localOverrides?.names[new] = fields
    }
  }
  public mutating func removePackage(_ name: String) throws {
    try manifest.removePackage(name)
    localOverrides?.names.removeValue(forKey: name)
  }
  public mutating func redirectPackage(_ name: String, to location: FileLocation) throws {
    guard manifest.names[name] != nil else { throw PinewindError("unknown package name '\(name)'") }
    if localOverrides == nil { localOverrides = LocalOverridesDocument() }
    var fields = localOverrides?.names[name] ?? PackageFields()
    fields.url = .value(try location.url)
    fields.revision = .reset
    localOverrides?.names[name] = fields
  }
  public mutating func moveEntry(from: Int, to: Int) throws {
    try manifest.moveEntry(from: from, to: to)
  }
}
public struct ConfigurationSnapshot: Sendable {
  public let manifest: ManifestDocument
  public let localOverrides: LocalOverridesDocument?
  public let sharedRevision: UInt64
  public let localRevision: UInt64
  public let sharedIsDirty: Bool
  public let localIsDirty: Bool
  let locations: WorkspaceLocations
  let baseline: DocumentBaseline
  public func evaluate(_ scope: ConfigurationScope = .effective) throws -> EvaluatedManifest {
    try manifest.evaluate(localOverrides: scope == .shared ? nil : localOverrides)
  }
  public func validate(scope: ConfigurationScope = .effective) -> [Diagnostic] {
    ConfigurationEvaluator.diagnostics(manifest, local: scope == .shared ? nil : localOverrides)
  }
}

struct DocumentBaseline: Sendable {
  var shared: Data?
  var local: Data?
  var lock: Data?
}
struct ConfigurationStore: Sendable {
  let locations: WorkspaceLocations
  let coordinator: any FileAccessCoordinating
  init(_ locations: WorkspaceLocations, coordinator: (any FileAccessCoordinating)? = nil) {
    self.locations = locations
    self.coordinator = coordinator ?? FileAccessCoordinator.platform(stateRoot: locations.stateRoot)
  }
  var documentLocations: [FileLocation] {
    [locations.configuration.manifest, locations.configuration.lock]
      + (locations.configuration.localOverrides.map { [$0] } ?? [])
  }
  func load() async throws -> ConfigurationSnapshot {
    let requests = try documentLocations.map { FileAccessRequest(url: try $0.url, intent: .read) }
    let values = try await coordinator.coordinate(requests) { urls in
      try urls.map { try Self.read($0) }
    }
    func text(_ bytes: Data, location: FileLocation) throws -> String {
      guard let value = String(data: bytes, encoding: .utf8) else {
        throw PinewindError(
          .invalidConfiguration, "configuration must be UTF-8 YAML", source: try location.url.path)
      }
      return value
    }
    let shared =
      try values[0].map {
        try ManifestDocument.parse(
          text($0, location: locations.configuration.manifest),
          source: locations.configuration.manifest.url.path)
      } ?? ManifestDocument()
    let local = try locations.configuration.localOverrides.flatMap { location in
      try values[2].map {
        try LocalOverridesDocument.parse(text($0, location: location), source: location.url.path)
      }
    }
    return ConfigurationSnapshot(
      manifest: shared, localOverrides: local, sharedRevision: 0, localRevision: 0,
      sharedIsDirty: false, localIsDirty: false, locations: locations,
      baseline: DocumentBaseline(
        shared: values[0], local: values.count > 2 ? values[2] : nil, lock: values[1]))
  }
  static func read(_ url: URL) throws -> Data? {
    #if canImport(Darwin)
      if let values = try? url.resourceValues(forKeys: [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
      ]),
        values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current,
        values.ubiquitousItemDownloadingStatus != .downloaded
      {
        throw PinewindError(
          .contentMissing, "cloud document must be downloaded before access", source: url.path)
      }
    #endif
    do { return try Data(contentsOf: NativePath.from(url)) } catch CocoaError.fileReadNoSuchFile {
      return nil
    }
  }
  static func replace(_ bytes: Data?, at url: URL, expected: Data?) throws {
    guard try read(url) == expected else {
      throw PinewindError(
        .configurationConflict, "configuration changed on disk; reload before saving",
        source: url.path)
    }
    if bytes == expected { return }
    let path = try NativePath.from(url)
    try Cancellation.check()
    if let bytes {
      try FileManager.default.createDirectory(
        at: path.removingLastComponent(), withIntermediateDirectories: true)
      try bytes.write(to: path, options: .atomic)
    } else if expected != nil {
      try FileManager.default.removeItem(at: path)
    }
  }
  func commitLock(_ bytes: Data, expected: DocumentBaseline) async throws {
    let requests = try documentLocations.enumerated().map { index, location in
      FileAccessRequest(url: try location.url, intent: index == 1 ? .write : .read)
    }
    try await coordinator.coordinate(requests) { urls in
      guard try Self.read(urls[0]) == expected.shared,
        try urls.count < 3 || Self.read(urls[2]) == expected.local
      else {
        throw PinewindError(.staleInput, "configuration changed during resolution")
      }
      try Self.replace(bytes, at: urls[1], expected: expected.lock)
    }
  }
}

public actor ConfigurationSession {
  private let store: ConfigurationStore
  private var draft: ConfigurationDraft
  private var baseline: DocumentBaseline
  private var saved: ConfigurationDraft
  private var sharedRevision: UInt64 = 0
  private var localRevision: UInt64 = 0
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  init(snapshot: ConfigurationSnapshot, store: ConfigurationStore) {
    self.store = store
    baseline = snapshot.baseline
    draft = ConfigurationDraft(manifest: snapshot.manifest, localOverrides: snapshot.localOverrides)
    saved = draft
  }
  public func snapshot() -> ConfigurationSnapshot {
    ConfigurationSnapshot(
      manifest: draft.manifest, localOverrides: draft.localOverrides,
      sharedRevision: sharedRevision, localRevision: localRevision,
      sharedIsDirty: draft.manifest != saved.manifest,
      localIsDirty: draft.localOverrides != saved.localOverrides,
      locations: store.locations, baseline: baseline)
  }
  public func edit(_ operation: @Sendable (inout ConfigurationDraft) throws -> Void) rethrows {
    var next = draft
    try operation(&next)
    if next.manifest != draft.manifest { sharedRevision += 1 }
    if next.localOverrides != draft.localOverrides { localRevision += 1 }
    draft = next
  }
  public func validate(scope: ConfigurationScope = .effective) -> [Diagnostic] {
    snapshot().validate(scope: scope)
  }
  public func save(_ layer: ConfigurationLayer) async throws -> SaveReceipt {
    await acquire()
    defer { release() }
    try Task.checkCancellation()
    let captured = draft
    let location: FileLocation
    let bytes: Data?
    let expected: Data?
    let revision: UInt64
    switch layer {
    case .shared:
      _ = try captured.manifest.evaluate()
      location = store.locations.configuration.manifest
      bytes = Data(try captured.manifest.yaml().utf8)
      expected = baseline.shared
      revision = sharedRevision
    case .local:
      guard let configured = store.locations.configuration.localOverrides else {
        throw PinewindError(.unsupportedOperation, "local overrides are disabled")
      }
      if captured.localOverrides != nil {
        _ = try captured.manifest.evaluate(localOverrides: captured.localOverrides)
      }
      location = configured
      bytes = try captured.localOverrides.map { Data(try $0.yaml().utf8) }
      expected = baseline.local
      revision = localRevision
    }
    try await store.coordinator.coordinate([
      FileAccessRequest(url: try location.url, intent: bytes == nil ? .delete : .write)
    ]) { urls in
      try ConfigurationStore.replace(bytes, at: urls[0], expected: expected)
    }
    switch layer {
    case .shared:
      baseline.shared = bytes
      saved.manifest = captured.manifest
    case .local:
      baseline.local = bytes
      saved.localOverrides = captured.localOverrides
    }
    return SaveReceipt(layer: layer, revision: revision)
  }
  public func reload() async throws {
    await acquire()
    defer { release() }
    guard draft == saved else {
      throw PinewindError(.configurationConflict, "reload would discard unsaved changes")
    }
    let capturedShared = sharedRevision
    let capturedLocal = localRevision
    let loaded = try await store.load()
    guard sharedRevision == capturedShared, localRevision == capturedLocal else {
      throw PinewindError(.configurationConflict, "configuration edited while reloading")
    }
    apply(loaded)
  }
  public func discardChangesAndReload() async throws {
    await acquire()
    defer { release() }
    let capturedShared = sharedRevision
    let capturedLocal = localRevision
    let loaded = try await store.load()
    guard sharedRevision == capturedShared, localRevision == capturedLocal else {
      throw PinewindError(.configurationConflict, "configuration edited while reloading")
    }
    apply(loaded)
  }
  private func apply(_ loaded: ConfigurationSnapshot) {
    draft = ConfigurationDraft(manifest: loaded.manifest, localOverrides: loaded.localOverrides)
    saved = draft
    baseline = loaded.baseline
    sharedRevision += 1
    localRevision += 1
  }
  private func acquire() async {
    if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
  }
  private func release() {
    if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
  }
}
