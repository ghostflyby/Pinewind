// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import Dispatch
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct GitCredentials: Sendable {
  public let username: String
  public let password: String

  public init(username: String, password: String) {
    self.username = username
    self.password = password
  }

  public static func token(_ token: String) -> GitCredentials {
    GitCredentials(username: "x-access-token", password: token)
  }
}

/// Called synchronously for an HTTPS authentication challenge. Return nil to decline.
public typealias GitCredentialProvider = @Sendable (URL) -> GitCredentials?

/// HTTPS Git acquisition without a git/ssh executable or GitHub REST API.
/// All instances share a blocking executor, serializing in-process cache writes.
public actor GitKitPackageFetcher: PackageFetcher {
  private let transport: any GitTransport
  private let session: URLSession

  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    GitIOExecutor.shared.asUnownedSerialExecutor()
  }

  public init(credentials: GitCredentialProvider? = nil, session: URLSession = .shared) {
    transport = GitKitTransport(credentials: credentials)
    self.session = session
  }

  init(transport: any GitTransport, session: URLSession = .shared) {
    self.transport = transport
    self.session = session
  }

  public func resolveDefaultBranch(url: URL) async throws -> String {
    try Task.checkCancellation()
    let source = try Self.sourceURL(url)
    let references = try transport.advertise(url: Self.remoteURL(source))
    return try RemoteReferences(references).defaultBranch()
  }

  public func resolveCommit(url: URL, ref: String) async throws -> String {
    try Task.checkCancellation()
    let source = try Self.sourceURL(url)
    if SourceIdentity.isCommit(ref) { return ref.lowercased() }
    guard !ref.isEmpty, !ref.contains("\0") else { throw PinewindError("invalid Git reference") }
    let references = try transport.advertise(url: Self.remoteURL(source))
    return try RemoteReferences(references).commit(for: ref)
  }

  public func prepareSource(url: URL, commit: String, cacheRoot: URL) async throws
    -> PackageSourceSnapshot
  {
    try Task.checkCancellation()
    let source = try Self.sourceURL(url)
    let identity = try SourceIdentity(url: source, commit: commit)
    guard cacheRoot.isFileURL else { throw PinewindError("cache root must be a file URL") }
    let key = Self.cacheKey(identity.url)
    let fm = FileManager.default
    let packages = cacheRoot.appendingPathComponent("packages", isDirectory: true)
      .appendingPathComponent(key, isDirectory: true)
    let directory = packages.appendingPathComponent(identity.commit, isDirectory: true)
    let marker = packages.appendingPathComponent(identity.commit + ".complete")
    if Self.isComplete(directory: directory, marker: marker, identity: identity) {
      return try PackageSourceSnapshot(identity: identity, directory: directory)
    }
    let repository = cacheRoot.appendingPathComponent("repositories", isDirectory: true)
      .appendingPathComponent(key + ".git", isDirectory: true)
    try fm.createDirectory(
      at: repository.deletingLastPathComponent(), withIntermediateDirectories: true)
    if try !transport.containsCommit(identity.commit, repository: repository) {
      try transport.fetch(
        url: Self.remoteURL(source), repository: repository, commit: identity.commit)
    }
    guard try transport.containsCommit(identity.commit, repository: repository) else {
      throw PinewindError(
        "locked commit is unavailable from the Git remote", source: identity.url.absoluteString)
    }
    try fm.createDirectory(at: packages, withIntermediateDirectories: true)
    let candidate = packages.appendingPathComponent(
      ".candidate-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: candidate) }
    try transport.export(commit: identity.commit, repository: repository, destination: candidate)
    try Task.checkCancellation()
    // An incomplete generation is disposable. A complete commit view is never overwritten.
    if fm.fileExists(atPath: marker.path) { try fm.removeItem(at: marker) }
    if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
    try fm.moveItem(at: candidate, to: directory)
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    try encoder.encode(Completion(version: 1, identity: identity)).write(
      to: marker, options: .atomic)
    return try PackageSourceSnapshot(identity: identity, directory: directory)
  }

  public func downloadFile(url: URL) async throws -> Data {
    guard url.scheme?.lowercased() == "https", url.host != nil else {
      throw PinewindError("download resources require HTTPS")
    }
    try Task.checkCancellation()
    let (data, response) = try await session.data(
      for: URLRequest(url: url), delegate: HTTPSRedirectGuard())
    guard let response = response as? HTTPURLResponse, response.url?.scheme?.lowercased() == "https"
    else {
      throw PinewindError("download did not return an HTTPS response", source: url.absoluteString)
    }
    guard (200..<300).contains(response.statusCode) else {
      throw PinewindError(
        "download returned HTTP \(response.statusCode)", source: url.absoluteString)
    }
    return data
  }

  private static func sourceURL(_ url: URL) throws -> URL {
    let source = try SourceIdentity.normalize(url, preservingGitSuffix: true)
    guard !source.isFileURL, !source.path.isEmpty, !source.path.contains("\0"),
      !source.path.split(separator: "/").contains("..")
    else {
      throw PinewindError("Git sources require an HTTPS repository URL")
    }
    if source.host == "github.com" {
      let parts = source.path.split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count == 3, parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else {
        throw PinewindError("GitHub repository URL requires an owner and repository")
      }
    }
    return source
  }

  private static func remoteURL(_ source: URL) -> URL {
    source.host == "github.com" ? source.appendingPathExtension("git") : source
  }

  // Hash URL metadata only for a portable cache key; never hash a source tree or archive.
  static func cacheKey(_ source: URL) -> String {
    SHA256.hash(data: Data(source.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private struct Completion: Codable {
    let version: Int
    let identity: SourceIdentity
  }

  private static func isComplete(directory: URL, marker: URL, identity: SourceIdentity) -> Bool {
    guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
      let bytes = try? Data(contentsOf: marker),
      let record = try? PropertyListDecoder().decode(Completion.self, from: bytes)
    else { return false }
    return record.version == 1 && record.identity == identity
  }
}

/// A dispatch-backed executor keeps blocking libgit2 I/O off cooperative workers.
private final class GitIOExecutor: SerialExecutor {
  static let shared = GitIOExecutor()
  private let queue = DispatchQueue(label: "pinewind.git.io", qos: .utility)

  // The protocol's default implementation requires iOS 17; the ordinary
  // executor initializer is available on our iOS 16 deployment target.
  func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(ordinary: self)
  }

  func enqueue(_ job: UnownedJob) {
    let executor = asUnownedSerialExecutor()
    queue.async { job.runSynchronously(on: executor) }
  }
}

private final class HTTPSRedirectGuard: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
  }
}

struct GitReference: Sendable {
  let name: String
  let commit: String
  let symbolicTarget: String?
}

struct RemoteReferences {
  let values: [GitReference]
  init(_ values: [GitReference]) { self.values = values }

  func defaultBranch() throws -> String {
    if let target = values.first(where: { $0.name == "HEAD" })?.symbolicTarget,
      target.hasPrefix("refs/heads/")
    {
      return String(target.dropFirst("refs/heads/".count))
    }
    let head = values.first { $0.name == "HEAD" }
    let candidates = values.filter { $0.name.hasPrefix("refs/heads/") && $0.commit == head?.commit }
    guard candidates.count == 1, let branch = candidates.first else {
      throw PinewindError("Git remote does not advertise an unambiguous default branch")
    }
    return String(branch.name.dropFirst("refs/heads/".count))
  }

  func commit(for ref: String) throws -> String {
    let names =
      ref == "HEAD" || ref.hasPrefix("refs/") ? [ref] : ["refs/heads/" + ref, "refs/tags/" + ref]
    let matches = names.compactMap { name in values.first { $0.name == name } }
    guard matches.count == 1, let found = matches.first else {
      throw PinewindError(
        matches.isEmpty
          ? "Git reference not found: \(ref)"
          : "ambiguous Git reference '\(ref)'; use refs/heads/ or refs/tags/")
    }
    let peeled = values.first { $0.name == found.name + "^{}" }
    let commit = (peeled ?? found).commit
    guard SourceIdentity.isCommit(commit) else {
      throw PinewindError("remote advertised an invalid commit ID")
    }
    return commit.lowercased()
  }
}
