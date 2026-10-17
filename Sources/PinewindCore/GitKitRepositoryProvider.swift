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
    do {
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

    } catch { throw ErrorBoundary.normalize(error) }
  }

  public func prepareSource(_ identity: SourceIdentity, cacheRoot: FilePath) async throws
    -> SourceSnapshot
  {
    do {
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

    } catch { throw ErrorBoundary.normalize(error) }
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
  /// Downloads preserve the injected session delegate's authentication policy.
  /// Bounded Corelibs transfers use its configuration in a dedicated session.
  public init(session: URLSession = .shared) { self.session = session }
  public func download(_ url: URL, to destination: FilePath, maximumBytes: Int?) async throws {
    do {
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

    } catch { throw ErrorBoundary.normalize(error) }
  }

  /// Uncapped downloads use the fast download-to-file path.
  private func downloadUnbounded(_ request: URLRequest, to destination: FilePath, url: URL)
    async throws
  {
    let temporary: URL
    let response: URLResponse
    do {
      (temporary, response) = try await session.download(
        for: request, delegate: HTTPSResourceDelegate(session: session))
    } catch {
      throw transportFailure(error, url: url)
    }
    defer { try? FileManager.default.removeItem(at: temporary) }
    _ = try Self.validatedResponse(response, url: url)
    try Task.checkCancellation()
    let source = try NativePath.from(temporary)
    try await BlockingIO.run {
      try FileManager.default.createDirectory(
        at: destination.removingLastComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: source, to: destination)
    }
  }

  /// Check each chunk before writing it, including on Corelibs Foundation.
  private func downloadBounded(
    _ request: URLRequest, to destination: FilePath, maximumBytes: Int, url: URL
  ) async throws {
    try await BlockingIO.run {
      try FileManager.default.createDirectory(
        at: destination.removingLastComponent(), withIntermediateDirectories: true)
    }
    do {
      let handle = try FileIO.perform(.open, paths: [destination]) {
        try FileDescriptor.open(
          destination, .writeOnly, options: [.create, .truncate],
          permissions: [.ownerReadWrite, .groupRead, .otherRead])
      }
      defer { try? handle.close() }
      let transfer = BoundedResourceTransfer(
        session: session, destination: destination, handle: handle, url: url,
        maximumBytes: maximumBytes)
      try await transfer.run(request: request)
      try Task.checkCancellation()
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw transportFailure(error, url: url)
    }
  }

  fileprivate static func validatedResponse(_ response: URLResponse, url: URL) throws
    -> HTTPURLResponse
  {
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
    if error is CancellationError { return error }
    if let error = error as? PinewindError { return error }
    if let failure = Failure.recognizing(error) { return PinewindError.runtime(failure) }
    if (error as? URLError)?.code == .cancelled { return CancellationError() }
    return PinewindError.runtime(
      .network(
        .transportFailed(
          url: url, reason: TransportFailureReason(error), detail: String(describing: error))))
  }
}
// Corelibs routes native transport callbacks through the session delegate, so
// use a session with the caller's configuration and a dedicated streaming sink.
// The lock protects delegate callbacks and concurrent task cancellation.
private final class BoundedResourceTransfer: HTTPSResourceDelegate, URLSessionDataDelegate,
  @unchecked Sendable
{
  private let destination: FilePath
  private let handle: FileDescriptor
  private let url: URL
  private let maximumBytes: Int
  private let lock = NSLock()
  private var received = 0
  private var failure: (any Error)?
  private var cancelled = false
  private var task: URLSessionDataTask?
  private var continuation: CheckedContinuation<Void, any Error>?

  init(
    session: URLSession, destination: FilePath, handle: FileDescriptor, url: URL, maximumBytes: Int
  ) {
    self.destination = destination
    self.handle = handle
    self.url = url
    self.maximumBytes = maximumBytes
    super.init(session: session)
  }

  func run(request: URLRequest) async throws {
    #if canImport(FoundationNetworking)
      let session = URLSession(
        configuration: originalSession.configuration, delegate: self, delegateQueue: nil)
      defer { session.invalidateAndCancel() }
    #else
      let session = originalSession
    #endif
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let task = session.dataTask(with: request)
        task.delegate = self
        let start = lock.withLock {
          guard !cancelled else { return false }
          self.task = task
          self.continuation = continuation
          return true
        }
        if start {
          task.resume()
        } else {
          task.cancel()
          continuation.resume(throwing: CancellationError())
        }
      }
    } onCancel: {
      let task = self.lock.withLock {
        self.cancelled = true
        return self.task
      }
      task?.cancel()
    }
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    do {
      _ = try HTTPSResourceDownloader.validatedResponse(response, url: url)
      completionHandler(.allow)
    } catch {
      lock.withLock { failure = error }
      completionHandler(.cancel)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let stop = lock.withLock {
      guard failure == nil, !cancelled else { return true }
      do {
        guard data.count <= maximumBytes - received else {
          throw NetworkFailure.sizeLimitExceeded(url: url, maximumBytes: maximumBytes)
        }
        try FileIO.perform(.write, paths: [destination]) {
          try data.withUnsafeBytes { _ = try handle.writeAll($0) }
        }
        received += data.count
        return false
      } catch {
        failure = error
        return true
      }
    }
    if stop { dataTask.cancel() }
  }

  override func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    let completion = lock.withLock {
      let result: Result<Void, any Error>
      if let failure {
        result = .failure(failure)
      } else if cancelled {
        result = .failure(CancellationError())
      } else if let error {
        result = .failure(error)
      } else {
        result = .success(())
      }
      let continuation = self.continuation
      self.continuation = nil
      self.task = nil
      return (continuation, result)
    }
    completion.0?.resume(with: completion.1)
  }
}
/// Shared authentication and redirect policy for both resource transfer modes.
class HTTPSResourceDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let originalSession: URLSession

  init(session: URLSession) { originalSession = session }

  // A concrete witness lets streaming subclasses override completion on Corelibs;
  // inheriting the protocol's default implementation would bypass the override.
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {}

  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard let delegate = originalSession.delegate else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    #if canImport(FoundationNetworking)
      delegate.urlSession(
        originalSession, didReceive: challenge, completionHandler: completionHandler)
    #else
      delegate.urlSession?(
        originalSession, didReceive: challenge, completionHandler: completionHandler)
        ?? completionHandler(.performDefaultHandling, nil)
    #endif
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard let delegate = originalSession.delegate as? any URLSessionTaskDelegate else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    #if canImport(FoundationNetworking)
      delegate.urlSession(
        originalSession, task: task, didReceive: challenge, completionHandler: completionHandler)
    #else
      delegate.urlSession?(
        originalSession, task: task, didReceive: challenge, completionHandler: completionHandler)
        ?? completionHandler(.performDefaultHandling, nil)
    #endif
  }

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
      return target
    }
    let head = values.first { $0.name == "HEAD" }
    let candidates = values.filter { $0.name.hasPrefix("refs/heads/") && $0.commit == head?.commit }
    guard candidates.count == 1, let branch = candidates.first else {
      throw PinewindError.runtime(.git(.defaultBranchIndeterminate(url)))
    }
    return branch.name
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
