// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A detached value snapshot; editing its copies does not modify the configuration session.
public struct ConfigurationSnapshot: Sendable {
  public let manifest: ManifestDocument
  public let localOverrides: LocalOverridesDocument?
}

/// Serializes edits, evaluation and saving within one session. Saving is explicit and never
/// resolves packages or writes package locks. File access is coordinated by the platform;
/// each file is saved independently, retaining stale-file checks for changes between sessions.
public actor Configuration {
  private var manifest: ManifestDocument
  private var localOverrides: LocalOverridesDocument?
  public nonisolated let inputRoot: URL
  public nonisolated let localStateRoot: URL
  private let coordinator: any FileAccessCoordinating
  private var ioBusy = false
  private var ioWaiters: [CheckedContinuation<Void, Never>] = []
  private var sharedBytes: Data?
  private var localBytes: Data?

  private init(
    inputRoot: URL, localStateRoot: URL,
    manifest: ManifestDocument, localOverrides: LocalOverridesDocument?,
    sharedBytes: Data?, localBytes: Data?, coordinator: any FileAccessCoordinating
  ) {
    self.inputRoot = inputRoot
    self.localStateRoot = localStateRoot
    self.coordinator = coordinator
    self.manifest = manifest
    self.localOverrides = localOverrides
    self.sharedBytes = sharedBytes
    self.localBytes = localBytes
  }

  public func snapshot() -> ConfigurationSnapshot {
    ConfigurationSnapshot(manifest: manifest, localOverrides: localOverrides)
  }

  /// Applies a synchronous edit without actor suspension. A thrown error discards both drafts.
  public func edit(
    _ operation: @Sendable (inout ManifestDocument, inout LocalOverridesDocument?) throws -> Void
  ) rethrows {
    var shared = manifest
    var local = localOverrides
    try operation(&shared, &local)
    manifest = shared
    localOverrides = local
  }

  /// Configuration files remain absent until saved. Native coordination may create local state.
  public static func load(inputRoot: URL, localStateRoot: URL) async throws -> Configuration {
    try await load(
      inputRoot: inputRoot, localStateRoot: localStateRoot,
      coordinator: FileAccessCoordinator.platform(localStateRoot: localStateRoot))
  }

  // Internal injection enables deterministic coordination tests without exposing a platform protocol.
  static func load(
    inputRoot: URL, localStateRoot: URL, coordinator: any FileAccessCoordinating
  ) async throws -> Configuration {
    guard inputRoot.isFileURL, localStateRoot.isFileURL else {
      throw PinewindError("configuration roots must be file URLs")
    }
    guard try !SafePath.overlaps(inputRoot, localStateRoot) else {
      throw PinewindError("local state must not overlap the configuration input directory")
    }
    let root = inputRoot.standardizedFileURL
    let localRoot = localStateRoot.standardizedFileURL
    let sharedFile = root.appendingPathComponent("pinewind.yaml")
    let localFile = localRoot.appendingPathComponent("pinewind.local.yaml")
    let (shared, local) = try await coordinator.coordinate([
      FileAccessRequest(url: sharedFile, intent: .read),
      FileAccessRequest(url: localFile, intent: .read),
    ]) { urls in
      (try read(urls[0]), try read(urls[1]))
    }
    func text(_ bytes: Data, file: URL) throws -> String {
      guard let text = String(data: bytes, encoding: .utf8) else {
        throw PinewindError("configuration must be UTF-8 YAML", source: file.path)
      }
      return text
    }
    return try Configuration(
      inputRoot: root, localStateRoot: localRoot,
      manifest: shared.map {
        try ManifestDocument.parse(text($0, file: sharedFile), source: sharedFile.path)
      }
        ?? ManifestDocument(),
      localOverrides: local.map {
        try LocalOverridesDocument.parse(text($0, file: localFile), source: localFile.path)
      },
      sharedBytes: shared, localBytes: local, coordinator: coordinator)
  }

  /// Use shared declarations to generate or validate the shared resolution lock.
  public func evaluateShared() throws -> Manifest { try manifest.evaluate() }

  /// Local overrides affect deployment, never the shared lock's declarations.
  public func evaluateEffective() throws -> Manifest {
    try manifest.evaluate(localOverrides: localOverrides)
  }

  /// Renames shared definitions, all order references and the corresponding local override together.
  public func renamePackage(_ old: String, to new: String) throws {
    if old != new, localOverrides?.names[new] != nil {
      throw PinewindError("local package name '\(new)' is already defined")
    }
    var updated = manifest
    try updated.renamePackage(old, to: new)
    manifest = updated
    if old != new, let fields = localOverrides?.names.removeValue(forKey: old) {
      localOverrides?.names[new] = fields
    }
  }

  public func removePackage(_ name: String) throws {
    try manifest.removePackage(name)
    localOverrides?.names.removeValue(forKey: name)
  }

  /// Validates shared deployment declarations, then atomically replaces only pinewind.yaml.
  public func saveShared() async throws {
    await acquireIO()
    defer { releaseIO() }
    try Task.checkCancellation()
    _ = try evaluateShared()
    let bytes = Data(try manifest.yaml().utf8)
    let expected = sharedBytes
    try await coordinator.coordinate([
      FileAccessRequest(url: inputRoot.appendingPathComponent("pinewind.yaml"), intent: .write)
    ]) { urls in
      try Self.save(bytes, to: urls[0], expected: expected)
    }
    // Edits may proceed while coordination waits. Only advance the persisted byte baseline.
    sharedBytes = bytes
  }

  /// Saves only localStateRoot/pinewind.local.yaml. A nil local draft removes that file.
  /// Removal is a recovery action and does not require a valid deployment configuration.
  public func saveLocalOverrides() async throws {
    await acquireIO()
    defer { releaseIO() }
    try Task.checkCancellation()
    if localOverrides != nil { _ = try evaluateEffective() }
    let bytes = try localOverrides.map { Data(try $0.yaml().utf8) }
    let expected = localBytes
    try await coordinator.coordinate([
      FileAccessRequest(
        url: localStateRoot.appendingPathComponent("pinewind.local.yaml"),
        intent: bytes == nil ? .delete : .write)
    ]) { urls in
      try Self.save(bytes, to: urls[0], expected: expected)
    }
    localBytes = bytes
  }

  // Hold across asynchronous coordination and baseline update, despite actor reentrancy.
  private func acquireIO() async {
    if ioBusy {
      await withCheckedContinuation { ioWaiters.append($0) }
    } else {
      ioBusy = true
    }
  }

  private func releaseIO() {
    if ioWaiters.isEmpty {
      ioBusy = false
    } else {
      ioWaiters.removeFirst().resume()
    }
  }

  private static func save(_ bytes: Data?, to file: URL, expected: Data?) throws {
    guard try read(file) == expected else {
      throw PinewindError("configuration changed on disk; reload before saving", source: file.path)
    }
    if bytes == expected { return }
    if let bytes {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try bytes.write(to: file, options: .atomic)
    } else if expected != nil {
      try FileManager.default.removeItem(at: file)
    }
  }

  static func read(_ file: URL) throws -> Data? {
    do { return try Data(contentsOf: file) } catch CocoaError.fileReadNoSuchFile { return nil }
  }
}
