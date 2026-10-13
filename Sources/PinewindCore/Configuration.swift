// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public struct FileFilter: Hashable, Codable, Sendable {
  public var include: [String]?
  public var exclude: [String]

  public init(include: [String]? = nil, exclude: [String] = []) {
    self.include = include
    self.exclude = exclude
  }

  public func accepts(_ path: String) throws -> Bool {
    let included =
      try include.map { patterns in
        try patterns.contains { try Glob.matches($0, path: path) }
      } ?? true
    guard included else { return false }
    return !(try exclude.contains { try Glob.matches($0, path: path) })
  }
}

public struct PackageRequest: Hashable, Codable, Sendable {
  public let url: URL
  public let ref: String?
  public let commit: String?
  public let recipe: String?
  public let options: [String: String]
  public let filter: FileFilter

  public init(
    url: URL, ref: String? = nil, commit: String? = nil,
    recipe: String? = nil, options: [String: String] = [:], filter: FileFilter = FileFilter()
  ) throws {
    self.url = try SourceIdentity.normalize(url)
    if url.isFileURL && (ref != nil || commit != nil) {
      throw PinewindError("file sources cannot specify ref or commit")
    }
    if ref != nil && commit != nil {
      throw PinewindError("ref and commit are mutually exclusive")
    }
    if let commit, !SourceIdentity.isCommit(commit) {
      throw PinewindError("commit must be a complete 40-character hexadecimal commit ID")
    }
    if let recipe { try SafePath.validate(recipe + ".recipe.yaml") }
    self.ref = ref
    self.commit = commit?.lowercased()
    self.recipe = recipe
    self.options = options
    self.filter = filter
  }
}

public struct ConfImport: Hashable, Codable, Sendable {
  public let source: String
  public let variables: [String: String]
  public init(source: String, variables: [String: String] = [:]) throws {
    guard variables["root_dir"] == nil else {
      throw PinewindError("root_dir is reserved for the conf resource view")
    }
    self.source = source
    self.variables = variables
  }
}

public enum ManifestEntry: Hashable, Codable, Sendable {
  case userFiles(FileFilter)
  case package(PackageRequest)
  case importConf(ConfImport)
}

/// The effective, ordered declarations. Shared and locally overridden configurations
/// are loaded separately; a local edit never writes a lock or hashes the working tree.
public struct Manifest: Hashable, Codable, Sendable {
  public let entries: [ManifestEntry]

  public init(entries: [ManifestEntry]) { self.entries = entries }

  public static func parse(
    _ yaml: String, localOverrides: String? = nil,
    source: String = "pinewind.yaml"
  ) throws -> Manifest {
    try ConfigurationParser.parse(yaml, overrides: localOverrides, source: source)
  }

  public static func load(inputRoot: URL, applyLocalOverrides: Bool = true) throws -> Manifest {
    let fm = FileManager.default
    let file = inputRoot.appendingPathComponent("pinewind.yaml")
    guard fm.fileExists(atPath: file.path) else {
      return Manifest(entries: [.userFiles(FileFilter())])
    }
    let local = inputRoot.appendingPathComponent("pinewind.local.yaml")
    let overrides =
      applyLocalOverrides && fm.fileExists(atPath: local.path)
      ? try String(contentsOf: local, encoding: .utf8) : nil
    return try parse(
      String(contentsOf: file, encoding: .utf8),
      localOverrides: overrides, source: file.path)
  }
}

public struct SourceIdentity: Hashable, Codable, Sendable {
  public let url: URL
  public let commit: String

  public init(url: URL, commit: String) throws {
    self.url = try Self.normalize(url)
    guard Self.isCommit(commit), !url.isFileURL else {
      throw PinewindError("a remote snapshot requires a complete commit ID")
    }
    self.commit = commit.lowercased()
  }

  static func isCommit(_ text: String) -> Bool {
    text.count == 40 && text.allSatisfy { $0.isASCII && $0.isHexDigit }
  }

  static func normalize(_ url: URL) throws -> URL {
    if url.isFileURL {
      guard url.path.hasPrefix("/") else {
        throw PinewindError("file sources require absolute paths")
      }
      guard url.host == nil || url.host == "" || url.host == "localhost" else {
        throw PinewindError("file URLs must refer to the local machine")
      }
      return url.standardizedFileURL
    }
    guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
    else { throw PinewindError("package sources must be local file URLs or HTTPS repository URLs") }
    parts.scheme = "https"
    parts.host = host.lowercased()
    if parts.port == 443 { parts.port = nil }
    while parts.path.hasSuffix("/") { parts.path.removeLast() }
    if parts.path.hasSuffix(".git") { parts.path.removeLast(4) }
    if host.lowercased() == "github.com" { parts.path = parts.path.lowercased() }
    guard let normalized = parts.url else { throw PinewindError("invalid package URL") }
    return normalized
  }
}
