// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A fully qualified advertised reference. Annotated tags use their peeled target.
public struct RepositoryReference: Hashable, Sendable {
  public enum Kind: Hashable, Sendable { case branch, tag, other }
  public let name: String
  public let commit: CommitID
  public init(name: String, commit: CommitID) {
    self.name = name
    self.commit = commit
  }
  public var kind: Kind {
    if name.hasPrefix("refs/heads/") { return .branch }
    if name.hasPrefix("refs/tags/") { return .tag }
    return .other
  }
  public var shortName: String {
    switch kind {
    case .branch: String(name.dropFirst("refs/heads/".count))
    case .tag: String(name.dropFirst("refs/tags/".count))
    case .other: name
    }
  }
}

/// An immutable advertisement, not a live repository or a guarantee that refs
/// will still point at the same commits on a later network request.
public struct RepositoryReferences: Sendable {
  public let repository: URL
  public let references: [RepositoryReference]
  /// Fully qualified branch name, or nil when the advertisement is indeterminate.
  public let defaultBranch: String?
  public init(repository: URL, references: [RepositoryReference], defaultBranch: String?) {
    self.repository = repository
    self.references = references.sorted { $0.name < $1.name }
    self.defaultBranch = defaultBranch
  }

  /// Classifies an exact name against this advertisement. It never guesses from
  /// prefixes such as "v", and never silently chooses a branch over a tag.
  /// Unadvertised full commit IDs remain valid requests; acquisition verifies them.
  public func revision(for input: String) throws -> GitRevision {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return .defaultBranch }
    if value == "HEAD" {
      guard defaultBranch != nil else { throw GitFailure.defaultBranchIndeterminate(repository) }
      return .defaultBranch
    }
    let matches = references.filter {
      if value.hasPrefix("refs/") { return $0.name == value }
      return $0.name == value || ($0.kind != .other && $0.shortName == value)
    }
    guard matches.count <= 1 else { throw GitFailure.ambiguousReference(value) }
    if let match = matches.first {
      switch match.kind {
      case .branch: return .branch(match.shortName)
      case .tag: return .tag(match.shortName)
      case .other: return .reference(match.name)
      }
    }
    if let commit = try? CommitID(value) { return .commit(commit) }
    throw GitFailure.referenceNotFound(value)
  }
}

/// Optional capability independent of acquisition. Hosts and other backends may
/// provide reference advertisements without adopting a GUI or hosting-service API.
public protocol RepositoryReferenceProvider: Sendable {
  func references(at repository: URL) async throws -> RepositoryReferences
}
