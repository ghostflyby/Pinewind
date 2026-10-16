// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Crypto
import Foundation
import SystemPackage

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

/// Prepares immutable commit snapshots under a FilePath-only cache boundary.
public struct GitKitRepositoryProvider: RepositoryProvider {
  let transport: any GitTransport
  public init(credentials: GitCredentialProvider? = nil) {
    transport = GitKitTransport(credentials: credentials)
  }
  init(transport: any GitTransport) { self.transport = transport }

  public func resolve(_ request: RepositoryRequest) async throws -> SourceIdentity {
    let transport = transport
    return try await BlockingIO.run {
      let url = try Self.sourceURL(request.url)
      if case .commit(let commit) = request.revision {
        return try SourceIdentity(url: url, commit: commit)
      }
      let refs = RemoteReferences(try transport.advertise(url: Self.remoteURL(url)), url: url)
      let reference = try request.revision.reference ?? refs.defaultBranch()
      return try SourceIdentity(url: url, commit: refs.commit(for: reference))
    }
  }

  public func prepareSource(_ identity: SourceIdentity, cacheRoot: FilePath) async throws
    -> SourceSnapshot
  {
    let cacheRoot = try NativePath.absolute(cacheRoot)
    let transport = transport
    return try await BlockingIO.run {
      let key = Self.cacheKey(identity.url)
      return try NativeLock.withLock(cacheRoot.appending("locks/" + key + ".lock")) {
        if let cached = try Self.cached(identity, cacheRoot: cacheRoot) { return cached }
        let repository = cacheRoot.appending("repositories/" + key + ".git")
        let directory = Self.directory(identity, cacheRoot: cacheRoot)
        let marker = directory.removingLastComponent().appending(
          identity.commit.string + ".complete")
        let fm = FileManager.default
        try fm.createDirectory(
          at: repository.removingLastComponent(), withIntermediateDirectories: true)
        if try !transport.containsCommit(identity.commit.string, repository: repository) {
          let url = try Self.sourceURL(identity.url)
          try transport.fetch(
            url: Self.remoteURL(url), repository: repository, commit: identity.commit.string)
        }
        guard try transport.containsCommit(identity.commit.string, repository: repository) else {
          throw PinewindError.runtime(
            .git(.commitUnavailable(commit: identity.commit.string, repository: identity.url)))
        }
        try fm.createDirectory(
          at: directory.removingLastComponent(), withIntermediateDirectories: true)
        let candidate = directory.removingLastComponent().appending(
          ".candidate-" + UUID().uuidString)
        try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: candidate) }
        try transport.export(
          commit: identity.commit.string, repository: repository, destination: candidate)
        try Cancellation.check()
        if fm.fileExists(atPath: marker.string) { try fm.removeItem(at: marker) }
        if fm.fileExists(atPath: directory.string) { try fm.removeItem(at: directory) }
        try fm.moveItem(at: candidate, to: directory)
        try PropertyListEncoder().encode(
          Completion(
            version: 1, url: try SourceIdentity.normalize(identity.url).absoluteString,
            commit: identity.commit.string)
        ).write(to: marker, options: .atomic)
        return try SourceSnapshot(identity: identity, directory: directory)
      }
    }
  }

  static func directory(_ identity: SourceIdentity, cacheRoot: FilePath) -> FilePath {
    cacheRoot.appending("packages/" + cacheKey(identity.url) + "/" + identity.commit.string)
  }
  static func cached(_ identity: SourceIdentity, cacheRoot: FilePath) throws -> SourceSnapshot? {
    let directory = directory(identity, cacheRoot: cacheRoot)
    let marker = directory.removingLastComponent().appending(identity.commit.string + ".complete")
    guard FileManager.default.fileExists(atPath: directory.string),
      let bytes = try? Data(contentsOf: marker),
      let record = try? PropertyListDecoder().decode(Completion.self, from: bytes),
      record.version == 1,
      record.url == (try SourceIdentity.normalize(identity.url).absoluteString),
      record.commit == identity.commit.string
    else { return nil }
    return try SourceSnapshot(identity: identity, directory: directory)
  }
  static func cacheKey(_ source: URL) -> String {
    SHA256.hash(data: Data((try! SourceIdentity.normalize(source)).absoluteString.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
  }
  private struct Completion: Codable {
    let version: Int
    let url: String
    let commit: String
  }
  static func sourceURL(_ url: URL) throws -> URL {
    let source = try SourceIdentity.normalize(url, preservingGitSuffix: true)
    guard !source.isFileURL, !source.path.isEmpty, !source.path.contains("\0"),
      !source.path.split(separator: "/").contains("..")
    else {
      throw PinewindError.runtime(.git(.unsupportedSourceURL(source)))
    }
    if source.host == "github.com" {
      let parts = source.path.split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count == 3, parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else {
        throw PinewindError.runtime(.git(.malformedRepositoryURL(source)))
      }
    }
    return source
  }

  static func remoteURL(_ source: URL) -> URL {
    source.host == "github.com" ? source.appendingPathExtension("git") : source
  }

}

public struct HTTPSResourceDownloader: ResourceDownloader {
  private let session: URLSession
  public init(session: URLSession = .shared) { self.session = session }
  public func download(_ url: URL, to destination: FilePath, maximumBytes: Int?) async throws {
    guard url.scheme?.lowercased() == "https", url.host != nil else {
      throw PinewindError.runtime(.network(.insecureScheme(url)))
    }
    let destination = try NativePath.absolute(destination)
    try Task.checkCancellation()
    let request = URLRequest(url: url)
    if let maximumBytes {
      try await downloadBounded(request, to: destination, maximumBytes: maximumBytes, url: url)
    } else {
      try await downloadUnbounded(request, to: destination, url: url)
    }
  }

  /// Uncapped downloads use the fast download-to-file path.
  private func downloadUnbounded(_ request: URLRequest, to destination: FilePath, url: URL)
    async throws
  {
    let temporary: URL
    let response: URLResponse
    do {
      (temporary, response) = try await session.download(
        for: request, delegate: HTTPSRedirectGuard())
    } catch {
      throw transportFailure(error, url: url)
    }
    defer { try? FileManager.default.removeItem(at: temporary) }
    _ = try validatedResponse(response, url: url)
    try Task.checkCancellation()
    let source = try NativePath.from(temporary)
    try await BlockingIO.run {
      try FileManager.default.createDirectory(
        at: destination.removingLastComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: source, to: destination)
    }
  }

  /// The size cap takes effect while bytes are in flight on platforms with a
  /// streaming bytes API, so an oversized transfer is aborted instead of
  /// written and inspected afterwards. Corelibs Foundation has no such API;
  /// there the cap is enforced right after the transfer, before caching.
  private func downloadBounded(
    _ request: URLRequest, to destination: FilePath, maximumBytes: Int, url: URL
  ) async throws {
    #if canImport(FoundationNetworking)
      try await downloadUnbounded(request, to: destination, url: url)
      let size = try await BlockingIO.run { try SnapshotFiles.byteCount(destination) }
      guard size <= maximumBytes else {
        try? FileManager.default.removeItem(at: destination)
        throw PinewindError.runtime(
          .network(.sizeLimitExceeded(url: url, maximumBytes: maximumBytes)))
      }
    #else
      let stream: URLSession.AsyncBytes
      let response: URLResponse
      do {
        (stream, response) = try await session.bytes(
          for: request, delegate: HTTPSRedirectGuard())
      } catch {
        throw transportFailure(error, url: url)
      }
      _ = try validatedResponse(response, url: url)
      try await BlockingIO.run {
        try FileManager.default.createDirectory(
          at: destination.removingLastComponent(), withIntermediateDirectories: true)
      }
      let handle = try FileDescriptor.open(
        destination, .writeOnly, options: [.create, .truncate],
        permissions: [.ownerReadWrite, .groupRead, .otherRead])
      defer { try? handle.close() }
      do {
        var pending: [UInt8] = []
        pending.reserveCapacity(65536)
        func flush() throws {
          _ = try handle.writeAll(pending)
          pending.removeAll(keepingCapacity: true)
        }
        var received = 0
        for try await byte in stream {
          try Task.checkCancellation()
          received += 1
          if received > maximumBytes {
            throw PinewindError.runtime(
              .network(.sizeLimitExceeded(url: url, maximumBytes: maximumBytes)))
          }
          pending.append(byte)
          if pending.count == 65536 { try flush() }
        }
        if !pending.isEmpty { try flush() }
      } catch let error as PinewindError {
        try? FileManager.default.removeItem(at: destination)
        throw error
      } catch {
        try? FileManager.default.removeItem(at: destination)
        throw transportFailure(error, url: url)
      }
    #endif
  }

  private func validatedResponse(_ response: URLResponse, url: URL) throws -> HTTPURLResponse {
    guard let response = response as? HTTPURLResponse,
      response.url?.scheme?.lowercased() == "https"
    else {
      throw PinewindError.runtime(.network(.insecureScheme(url)))
    }
    guard (200..<300).contains(response.statusCode) else {
      throw PinewindError.runtime(
        .network(.rejected(status: response.statusCode, url: url)))
    }
    return response
  }

  private func transportFailure(_ error: any Error, url: URL) -> any Error {
    if Task.isCancelled || (error as? URLError)?.code == .cancelled { return CancellationError() }
    return PinewindError.runtime(
      .network(.transportFailed(url: url, detail: String(describing: error))))
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
  let url: URL
  init(_ values: [GitReference], url: URL) {
    self.values = values
    self.url = url
  }

  func defaultBranch() throws -> String {
    if let target = values.first(where: { $0.name == "HEAD" })?.symbolicTarget,
      target.hasPrefix("refs/heads/")
    {
      return String(target.dropFirst("refs/heads/".count))
    }
    let head = values.first { $0.name == "HEAD" }
    let candidates = values.filter { $0.name.hasPrefix("refs/heads/") && $0.commit == head?.commit }
    guard candidates.count == 1, let branch = candidates.first else {
      throw PinewindError.runtime(.git(.defaultBranchIndeterminate(url)))
    }
    return String(branch.name.dropFirst("refs/heads/".count))
  }

  func commit(for ref: String) throws -> CommitID {
    let names =
      ref == "HEAD" || ref.hasPrefix("refs/") ? [ref] : ["refs/heads/" + ref, "refs/tags/" + ref]
    let matches = names.compactMap { name in values.first { $0.name == name } }
    guard matches.count == 1, let found = matches.first else {
      throw matches.isEmpty
        ? PinewindError.runtime(.git(.referenceNotFound(ref)))
        : PinewindError.runtime(.git(.ambiguousReference(ref)))
    }
    let peeled = values.first { $0.name == found.name + "^{}" }
    let commit = (peeled ?? found).commit
    return try CommitID(commit)
  }
}
