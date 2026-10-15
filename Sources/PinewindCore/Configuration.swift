// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

public struct FileFilter: Hashable, Sendable {
  public var include: [String]?
  public var exclude: [String]
  public init(include: [String]? = nil, exclude: [String] = []) {
    self.include = include
    self.exclude = exclude
  }
  public func accepts(_ path: String) throws -> Bool {
    let included = try include.map { try $0.contains { try Glob.matches($0, path: path) } } ?? true
    return try included && !(exclude.contains { try Glob.matches($0, path: path) })
  }
  func validate() throws {
    for pattern in (include ?? []) + exclude { _ = try Glob.compile(pattern) }
  }
}

public struct CommitID: Hashable, Sendable, CustomStringConvertible {
  public let string: String
  public init(_ string: String) throws {
    guard SourceIdentity.isCommit(string) else {
      throw PinewindError(
        .invalidConfiguration, "commit must be a complete 40-character hexadecimal commit ID")
    }
    self.string = string.lowercased()
  }
  public var description: String { string }
}

public enum GitRevision: Hashable, Sendable {
  case defaultBranch
  case branch(String)
  case tag(String)
  case reference(String)
  case commit(CommitID)
  var reference: String? {
    switch self {
    case .defaultBranch, .commit: return nil
    case .branch(let value): return "refs/heads/" + value
    case .tag(let value): return "refs/tags/" + value
    case .reference(let value): return value
    }
  }
  func validate() throws {
    if let value = reference, value.isEmpty || value.contains("\0") || value.hasSuffix("/") {
      throw PinewindError(.invalidConfiguration, "invalid Git revision", field: "revision")
    }
  }
}

struct RepositoryKey: Hashable, Sendable {
  let url: URL
  let revision: GitRevision
}

public struct RepositoryRequest: Hashable, Sendable {
  public let url: URL
  public let revision: GitRevision
  let canonicalURL: URL
  var key: RepositoryKey { RepositoryKey(url: canonicalURL, revision: revision) }
  public init(url: URL, revision: GitRevision = .defaultBranch) throws {
    let normalized = try SourceIdentity.normalize(url, preservingGitSuffix: true)
    guard !normalized.isFileURL else {
      throw PinewindError(.invalidConfiguration, "repositories require HTTPS URLs")
    }
    try revision.validate()
    self.url = normalized
    self.canonicalURL = try SourceIdentity.normalize(normalized)
    self.revision = revision
  }
}

public enum PackageSource: Hashable, Sendable {
  case git(RepositoryRequest)
  case directory(FileLocation)
}

public struct PackageRequest: Hashable, Sendable {
  public let source: PackageSource
  public let recipe: String?
  public let options: [String: String]
  public let filter: FileFilter
  let url: URL
  var revision: GitRevision? {
    if case .git(let repository) = source { return repository.revision }
    return nil
  }
  var ref: String? { revision?.reference }
  var commit: String? {
    if case .commit(let id) = revision { return id.string }
    return nil
  }

  public init(
    source: PackageSource, recipe: String? = nil, options: [String: String] = [:],
    filter: FileFilter = FileFilter()
  ) throws {
    if let recipe { try SafePath.validate(recipe + ".recipe.yaml") }
    try filter.validate()
    switch source {
    case .git(let repository): self.url = repository.url
    case .directory(let location): self.url = try location.url
    }
    self.source = source
    self.recipe = recipe
    self.options = options
    self.filter = filter
  }
  init(
    url: URL, revision: GitRevision? = nil, recipe: String? = nil, options: [String: String] = [:],
    filter: FileFilter = FileFilter()
  ) throws {
    if url.isFileURL {
      guard revision == nil else { throw PinewindError("file sources cannot specify revision") }
      try self.init(
        source: .directory(.fileURL(url)), recipe: recipe, options: options, filter: filter)
    } else {
      try self.init(
        source: .git(RepositoryRequest(url: url, revision: revision ?? .defaultBranch)),
        recipe: recipe, options: options, filter: filter)
    }
  }
}

public struct ConfImport: Hashable, Sendable {
  public let source: String
  public let variables: [String: String]
  public init(source: String, variables: [String: String] = [:]) throws {
    guard !source.isEmpty, variables["root_dir"] == nil else {
      throw PinewindError("root_dir is reserved and an import source is required")
    }
    self.source = source
    self.variables = variables
  }
}
public enum ManifestEntry: Hashable, Sendable {
  case userFiles(FileFilter)
  case package(PackageRequest)
  case importConf(ConfImport)
}
public struct EvaluatedManifest: Hashable, Sendable {
  public let entries: [ManifestEntry]
}
typealias Manifest = EvaluatedManifest

public struct SourceIdentity: Hashable, Sendable {
  public let url: URL
  public let commit: CommitID
  public init(url: URL, commit: CommitID) throws {
    self.url = try Self.normalize(url, preservingGitSuffix: true)
    guard !url.isFileURL else {
      throw PinewindError("a remote snapshot requires an HTTPS repository")
    }
    self.commit = commit
  }
  init(url: URL, commit: String) throws { try self.init(url: url, commit: CommitID(commit)) }
  static func isCommit(_ text: String) -> Bool {
    text.count == 40 && text.allSatisfy { $0.isASCII && $0.isHexDigit }
  }

  static func normalize(_ url: URL, preservingGitSuffix: Bool = false) throws -> URL {
    if url.isFileURL {
      _ = try NativePath.from(url)
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
    if (!preservingGitSuffix || host.lowercased() == "github.com") && parts.path.hasSuffix(".git") {
      parts.path.removeLast(4)
    }
    if host.lowercased() == "github.com" { parts.path = parts.path.lowercased() }
    guard let normalized = parts.url else { throw PinewindError("invalid package URL") }
    return normalized
  }
}
