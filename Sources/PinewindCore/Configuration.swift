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
  public func accepts(_ path: RelativePath) throws(DeclarationFailure) -> Bool {
    if let include {
      var matched = false
      for pattern in include {
        if try Glob.matches(pattern, path: path) {
          matched = true
          break
        }
      }
      if !matched { return false }
    }
    for pattern in exclude {
      if try Glob.matches(pattern, path: path) { return false }
    }
    return true
  }
  func validate() throws(DeclarationFailure) {
    for pattern in (include ?? []) + exclude { _ = try Glob.compile(pattern) }
  }
}

public struct CommitID: Hashable, Sendable, CustomStringConvertible {
  public let string: String
  public init(_ string: String) throws(DeclarationFailure) {
    guard string.count == 40, string.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
      throw DeclarationFailure.invalidCommitID(string)
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
  func validate() throws(DeclarationFailure) {
    if let value = reference, value.isEmpty || value.contains("\0") || value.hasSuffix("/") {
      throw DeclarationFailure.invalidRevision
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
      throw GitFailure.unsupportedSourceURL(normalized)
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
  let recipePath: RelativePath
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
    filter: FileFilter = FileFilter(), relativeTo: FilePath? = nil
  ) throws {
    if let recipe, recipe.contains("\0") || recipe.contains("\\") {
      throw FileSystemFailure.notPortable(FilePath(recipe))
    }
    let recipePath = try RelativePath(FilePath(recipe.map { $0 + ".recipe.yaml" } ?? "recipe.yaml"))
    try filter.validate()
    switch source {
    case .git(let repository):
      self.url = repository.url
      self.source = source
    case .directory(let location):
      let resolved = try location.resolved(relativeTo: relativeTo)
      self.url = try resolved.url
      self.source = .directory(resolved)
    }
    self.recipe = recipe.map { _ in String(recipePath.string.dropLast(".recipe.yaml".count)) }
    self.recipePath = recipePath
    self.options = options
    self.filter = filter
  }
  init(
    url: URL, revision: GitRevision? = nil, recipe: String? = nil, options: [String: String] = [:],
    filter: FileFilter = FileFilter()
  ) throws {
    if url.isFileURL {
      guard revision == nil else {
        throw DeclarationFailure.revisionWithFileSource
      }
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
  let localPath: RelativePath?
  public init(source: String, variables: [String: String] = [:]) throws {
    guard variables["root_dir"] == nil else {
      throw DeclarationFailure.reservedVariable("root_dir")
    }
    guard !source.isEmpty else {
      throw DeclarationFailure.importSourceRequired
    }
    guard !source.contains("\0") else {
      throw FileSystemFailure.notPortable(FilePath(source))
    }
    if source.hasPrefix(":") || source.contains("://") {
      localPath = nil
    } else {
      guard !source.contains("\\") else {
        throw FileSystemFailure.notPortable(FilePath(source))
      }
      localPath = try RelativePath(FilePath(source))
    }
    if source.hasPrefix(":") {
      _ = try BuiltinPackageLists.descriptors(for: source)
    } else if source.contains("://") {
      guard let url = URL(string: source), url.scheme?.lowercased() == "https",
        url.host != nil, !url.lastPathComponent.isEmpty
      else {
        throw DeclarationFailure.invalidImportSource(source)
      }
    }
    self.source = localPath?.string ?? source
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
      throw GitFailure.unsupportedSourceURL(url)
    }
    self.commit = commit
  }
  init(url: URL, commit: String) throws {
    let id = try CommitID(commit)
    try self.init(url: url, commit: id)
  }
  static func normalize(_ url: URL, preservingGitSuffix: Bool = false) throws -> URL {
    if url.isFileURL {
      _ = try NativePath.from(url)
      // File URL spelling carries authority and provider information. Filesystem
      // identity checks use NativePath/SafePath rather than URL normalization.
      return url
    }
    guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
    else { throw DeclarationFailure.unsupportedSourceURL(url) }
    parts.scheme = "https"
    parts.host = host.lowercased()
    if parts.port == 443 { parts.port = nil }
    while parts.path.hasSuffix("/") { parts.path.removeLast() }
    if (!preservingGitSuffix || host.lowercased() == "github.com") && parts.path.hasSuffix(".git") {
      parts.path.removeLast(4)
    }
    if host.lowercased() == "github.com" { parts.path = parts.path.lowercased() }
    guard let normalized = parts.url else {
      throw GitFailure.malformedRepositoryURL(url)
    }
    return normalized
  }
}
