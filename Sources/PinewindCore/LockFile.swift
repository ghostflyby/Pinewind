// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public struct LockedPackage: Hashable, Codable, Sendable {
  public let request: PackageRequest
  public let commit: String
  public let resources: [PinnedResource]

  public init(request: PackageRequest, commit: String, resources: [PinnedResource] = []) throws {
    guard !request.url.isFileURL else {
      throw PinewindError("working trees do not have content locks")
    }
    let identity = try SourceIdentity(url: request.url, commit: commit)
    guard request.commit == nil || request.commit == identity.commit else {
      throw PinewindError("locked commit differs from the explicit commit request")
    }
    self.request = request
    self.commit = identity.commit
    self.resources = resources
  }
}

/// An inspectable semantic result. The storage encoding is private and may change.
public struct Resolution: Sendable {
  public let declarations: Manifest
  public let expanded: Manifest
  public let packages: [LockedPackage]

  public init(declarations: Manifest, expanded: Manifest, packages: [LockedPackage]) throws {
    guard
      !expanded.entries.contains(where: {
        if case .importConf = $0 { return true }
        return false
      })
    else {
      throw PinewindError("lock requires completely expanded conf imports")
    }
    for entry in expanded.entries {
      if case .package(let request) = entry {
        guard !request.url.isFileURL else {
          throw PinewindError("local sources are not persisted in a shared lock")
        }
        guard packages.contains(where: { $0.request == request }) else {
          throw PinewindError("lock is missing a package resolution")
        }
      }
    }
    self.declarations = declarations
    self.expanded = expanded
    self.packages = packages
  }

  public func validate(against manifest: Manifest) throws {
    guard declarations == manifest else {
      throw PinewindError("declarations changed; run resolve before composing")
    }
  }

  public func write(to file: URL) throws {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let payload = Payload(
      version: 1, declarations: declarations, expanded: expanded, packages: packages)
    var bytes = Self.magic
    bytes.append(try encoder.encode(payload))
    try bytes.write(to: file, options: .atomic)
  }

  public static func read(from file: URL) throws -> Resolution {
    let bytes = try Data(contentsOf: file)
    guard bytes.starts(with: magic) else {
      throw PinewindError("unsupported or corrupt Pinewind lock", source: file.path)
    }
    let payload: Payload
    do {
      payload = try PropertyListDecoder().decode(Payload.self, from: bytes.dropFirst(magic.count))
    } catch { throw PinewindError("corrupt Pinewind lock: \(error)", source: file.path) }
    guard payload.version == 1 else {
      throw PinewindError("unsupported Pinewind lock version", source: file.path)
    }
    let packages = try payload.packages.map {
      try LockedPackage(
        request: PackageRequest(
          url: $0.request.url, ref: $0.request.ref,
          commit: $0.request.commit, recipe: $0.request.recipe, options: $0.request.options,
          filter: $0.request.filter),
        commit: $0.commit,
        resources: $0.resources.map {
          try PinnedResource(url: $0.url, path: $0.path, sha256: $0.sha256)
        })
    }
    return try Resolution(
      declarations: payload.declarations, expanded: payload.expanded, packages: packages)
  }

  private static let magic = Data("PINEWIND\0".utf8)
  private struct Payload: Codable {
    let version: Int
    let declarations: Manifest
    let expanded: Manifest
    let packages: [LockedPackage]
  }
}
