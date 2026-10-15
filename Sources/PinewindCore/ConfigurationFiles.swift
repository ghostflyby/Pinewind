// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// An editable configuration session. Saving is explicit and never resolves packages or writes locks.
/// Each file is saved independently. Callers must serialize writers; the external-change check
/// detects stale sessions, but is not a filesystem compare-and-swap against concurrent editors.
public struct Configuration: Sendable {
  public var manifest: ManifestDocument
  public var localOverrides: LocalOverridesDocument?
  public let inputRoot: URL
  private var sharedBytes: Data?
  private var localBytes: Data?

  private init(
    inputRoot: URL, manifest: ManifestDocument, localOverrides: LocalOverridesDocument?,
    sharedBytes: Data?, localBytes: Data?
  ) {
    self.inputRoot = inputRoot
    self.manifest = manifest
    self.localOverrides = localOverrides
    self.sharedBytes = sharedBytes
    self.localBytes = localBytes
  }

  /// Missing files remain absent until explicitly saved; no manifest means order: [self].
  public static func load(inputRoot: URL) throws -> Configuration {
    guard inputRoot.isFileURL else { throw PinewindError("configuration root must be a file URL") }
    let root = inputRoot.standardizedFileURL
    let sharedFile = root.appendingPathComponent("pinewind.yaml")
    let localFile = root.appendingPathComponent("pinewind.local.yaml")
    let shared = try read(sharedFile)
    let local = try read(localFile)
    func text(_ bytes: Data, file: URL) throws -> String {
      guard let text = String(data: bytes, encoding: .utf8) else {
        throw PinewindError("configuration must be UTF-8 YAML", source: file.path)
      }
      return text
    }
    return try Configuration(
      inputRoot: root,
      manifest: shared.map {
        try ManifestDocument.parse(text($0, file: sharedFile), source: sharedFile.path)
      }
        ?? ManifestDocument(),
      localOverrides: local.map {
        try LocalOverridesDocument.parse(text($0, file: localFile), source: localFile.path)
      },
      sharedBytes: shared, localBytes: local)
  }

  /// Use shared declarations to generate or validate the shared resolution lock.
  public func evaluateShared() throws -> Manifest { try manifest.evaluate() }

  /// Local overrides affect deployment, never the shared lock's declarations.
  public func evaluateEffective() throws -> Manifest {
    try manifest.evaluate(localOverrides: localOverrides)
  }

  /// Renames shared definitions, all order references and the corresponding local override together.
  public mutating func renamePackage(_ old: String, to new: String) throws {
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

  public mutating func removePackage(_ name: String) throws {
    try manifest.removePackage(name)
    localOverrides?.names.removeValue(forKey: name)
  }

  /// Validates shared deployment declarations, then atomically replaces only pinewind.yaml.
  public mutating func saveShared() throws {
    _ = try evaluateShared()
    let bytes = Data(try manifest.yaml().utf8)
    try save(bytes, name: "pinewind.yaml", expected: sharedBytes)
    sharedBytes = bytes
  }

  /// Saves only pinewind.local.yaml. Setting localOverrides to nil explicitly removes that file.
  /// Removal is a recovery action and does not require a valid deployment configuration.
  public mutating func saveLocalOverrides() throws {
    if localOverrides != nil { _ = try evaluateEffective() }
    let bytes = try localOverrides.map { Data(try $0.yaml().utf8) }
    try save(bytes, name: "pinewind.local.yaml", expected: localBytes)
    localBytes = bytes
  }

  private func save(_ bytes: Data?, name: String, expected: Data?) throws {
    let file = inputRoot.appendingPathComponent(name)
    guard try Self.read(file) == expected else {
      throw PinewindError("configuration changed on disk; reload before saving", source: file.path)
    }
    if bytes == expected { return }
    if let bytes {
      try FileManager.default.createDirectory(at: inputRoot, withIntermediateDirectories: true)
      try bytes.write(to: file, options: .atomic)
    } else if expected != nil {
      try FileManager.default.removeItem(at: file)
    }
  }

  private static func read(_ file: URL) throws -> Data? {
    do { return try Data(contentsOf: file) } catch CocoaError.fileReadNoSuchFile { return nil }
  }
}
