// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CGitKit
import Foundation
import SystemPackage
import Testing

@testable import PinewindCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite("Pinewind GitKit acquisition")
struct GitKitRepositoryProviderTests {
  @Test(arguments: [
    (
      "https://GIT.EXAMPLE:443/team/Project.git/", "https://git.example/team/Project.git",
      "https://git.example/team/Project.git", "https://git.example/team/Project"
    ),
    (
      "https://git.example/team/Project", "https://git.example/team/Project",
      "https://git.example/team/Project", "https://git.example/team/Project"
    ),
    (
      "https://GitHub.com/Example/Package.git/", "https://github.com/example/package",
      "https://github.com/example/package.git", "https://github.com/example/package"
    ),
  ])
  func preservesTransportAddressesThroughManifestAndLock(
    input: String, requestURL: String, remoteURL: String, identityURL: String
  ) async throws {
    let f = try GitFixture()
    defer { f.remove() }
    let commit = try f.commit("first")
    let document = try ManifestDocument.parse(
      "version: 1\nnames: {package: {url: \(input), revision: {ref: main}}}\norder: [package]")
    let configuration = try configurationSnapshot(document)
    let manifest = try configuration.evaluate(.shared)
    guard case .package(let request) = try #require(manifest.entries.first) else {
      Issue.record("expected a package declaration")
      return
    }
    #expect(request.url.absoluteString == requestURL)
    let resolution = try Resolution(
      declarations: manifest, expanded: manifest,
      packages: [LockedPackage(request: request, commit: CommitID(commit))],
      snapshot: configuration, preview: false)
    let restored = try ResolutionCodec.decode(
      ResolutionCodec.encode(resolution), snapshot: configuration)
    let locked = try #require(restored.packages.first)
    #expect(locked.request.url.absoluteString == requestURL)
    let backend = GitKitRepositoryProvider(
      transport: LocalGitTransport(origin: f.origin, expectedURL: URL(string: remoteURL)!))
    #expect(
      try await backend.resolve(RepositoryRequest(url: locked.request.url)).commit.string == commit)
    #expect(
      try await backend.resolve(
        RepositoryRequest(url: locked.request.url, revision: .branch("main"))
      ).commit.string == commit)
    let snapshot = try await backend.prepareSource(
      SourceIdentity(url: locked.request.url, commit: locked.commit), cacheRoot: native(f.cache))
    #expect(try SourceIdentity.normalize(snapshot.identity.url).absoluteString == identityURL)
    #expect(
      snapshot.directory.removingLastComponent().lastComponent?.string
        == GitKitRepositoryProvider.cacheKey(URL(string: identityURL)!))
    #expect(
      try String(
        contentsOf: snapshot.directory.appending("default.yaml"), encoding: .utf8)
        == "value: first\n")
    try FileManager.default.removeItem(at: f.origin)
    let reused = try await backend.prepareSource(
      SourceIdentity(url: URL(string: identityURL)!, commit: commit), cacheRoot: native(f.cache))
    #expect(reused.directory == snapshot.directory)
  }

  @Test func resolvesBranchesAndPeeledTagsThroughGitAdvertisements() async throws {
    let f = try GitFixture()
    defer { f.remove() }
    let first = try f.commit("first")
    try f.tag("v1", commit: first)
    let backend = f.backend()
    #expect(try await backend.resolve(RepositoryRequest(url: f.url)).commit.string == first)
    #expect(
      try await backend.resolve(RepositoryRequest(url: f.url, revision: .branch("main"))).commit
        .string == first)
    #expect(
      try await backend.resolve(
        RepositoryRequest(url: f.url, revision: .reference("refs/heads/main"))
      ).commit.string == first)
    #expect(
      try await backend.resolve(RepositoryRequest(url: f.url, revision: .reference("v1"))).commit
        .string == first)
    #expect(
      try await backend.resolve(RepositoryRequest(url: f.url, revision: .tag("v1"))).commit.string
        == first)
    await #expect(throws: PinewindError.self) {
      try await backend.resolve(RepositoryRequest(url: f.url, revision: .reference("missing")))
        .commit.string
    }
    try f.branch("v1", commit: first)
    await #expect(throws: PinewindError.self) {
      try await backend.resolve(RepositoryRequest(url: f.url, revision: .reference("v1"))).commit
        .string
    }
  }

  @Test func fetchesNewCommitsAndKeepsOldViewsWithoutGitMetadataOrEOLFilters() async throws {
    let f = try GitFixture()
    defer { f.remove() }
    let first = try f.commit("first")
    let backend = f.backend()
    let old = try await backend.prepareSource(
      SourceIdentity(url: f.url, commit: first), cacheRoot: native(f.cache))
    #expect(
      try String(contentsOf: old.directory.appending("default.yaml"), encoding: .utf8)
        == "value: first\n")
    #expect(
      !FileManager.default.fileExists(atPath: old.directory.appending(".git").string))
    try Data("value: second\n".utf8).write(to: f.origin.appendingPathComponent("default.yaml"))
    let second = try f.commit("second")
    #expect(
      try await backend.resolve(RepositoryRequest(url: f.url, revision: .branch("main"))).commit
        .string == second)
    let new = try await backend.prepareSource(
      SourceIdentity(url: f.url, commit: second), cacheRoot: native(f.cache))
    #expect(old.identity.commit.string == first && new.identity.commit.string == second)
    #expect(old.directory != new.directory)
    #expect(
      try String(contentsOf: old.directory.appending("default.yaml"), encoding: .utf8)
        == "value: first\n")
    #expect(
      try String(contentsOf: new.directory.appending("default.yaml"), encoding: .utf8)
        == "value: second\n")
    let request = try PackageRequest(url: f.url, revision: .commit(CommitID(first)))
    let prepared = try PreparedPackage(
      request: request, directory: old.directory, commit: CommitID(first))
    let input = f.root.appendingPathComponent("input")
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    let plan = try CompositionPlanner(snapshotRoot: f.root.appendingPathComponent("planning")).plan(
      Manifest(entries: [.package(request)]), inputRoot: input, packages: [prepared])
    let output = f.root.appendingPathComponent("output")
    _ = try await Composer().compose(plan, inputRoot: input, outputRoot: output)
    #expect(
      try String(contentsOf: output.appendingPathComponent("default.yaml"), encoding: .utf8)
        == "value: first\n")
  }

  @Test func reusesCompleteViewsAndRebuildsFromCachedObjectsOffline() async throws {
    let f = try GitFixture()
    defer { f.remove() }
    let commit = try f.commit("first")
    let backend = f.backend()
    let initial = try await backend.prepareSource(
      SourceIdentity(url: f.url, commit: commit), cacheRoot: native(f.cache))
    try FileManager.default.removeItem(at: f.origin)
    let reused = try await backend.prepareSource(
      SourceIdentity(url: f.url, commit: commit), cacheRoot: native(f.cache))
    #expect(initial.directory == reused.directory)
    try FileManager.default.removeItem(at: initial.directory)
    let rebuilt = try await backend.prepareSource(
      SourceIdentity(url: f.url, commit: commit), cacheRoot: native(f.cache))
    #expect(
      try String(
        contentsOf: rebuilt.directory.appending("default.yaml"), encoding: .utf8)
        == "value: first\n")
  }

  @Test func pinsAnOlderCommitAlreadyPresentInTheObjectCache() async throws {
    let f = try GitFixture()
    defer { f.remove() }
    let ancestor = try f.commit("ancestor")
    try Data("value: descendant\n".utf8).write(to: f.origin.appendingPathComponent("default.yaml"))
    let descendant = try f.commit("descendant")
    let backend = f.backend()
    _ = try await backend.prepareSource(
      SourceIdentity(url: f.url, commit: descendant), cacheRoot: native(f.cache))
    _ = try await backend.prepareSource(
      SourceIdentity(url: f.url, commit: ancestor), cacheRoot: native(f.cache))
    let directory = f.cache.appendingPathComponent("repositories")
      .appendingPathComponent(GitKitRepositoryProvider.cacheKey(f.url) + ".git")
    var repository: OpaquePointer?
    #expect(git_repository_open(&repository, directory.path) == 0)
    defer { git_repository_free(repository) }
    var reference: OpaquePointer?
    #expect(git_reference_lookup(&reference, repository, "refs/pinewind/commits/" + ancestor) == 0)
    defer { git_reference_free(reference) }
    var oid = try #require(git_reference_target(reference)).pointee
    #expect(String(cString: git_oid_tostr_s(&oid)!) == ancestor)
  }

  @Test func incompleteViewsAreReplacedAndSeparateInstancesShareSafeCacheAccess() async throws {
    let f = try GitFixture()
    defer { f.remove() }
    let commit = try f.commit("first")
    let directory = f.cache.appendingPathComponent("packages").appendingPathComponent(
      GitKitRepositoryProvider.cacheKey(f.url)
    ).appendingPathComponent(commit)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("partial".utf8).write(to: directory.appendingPathComponent("partial.txt"))
    let a = f.backend()
    let b = f.backend()
    async let left = a.prepareSource(
      SourceIdentity(url: f.url, commit: commit), cacheRoot: native(f.cache))
    async let right = b.prepareSource(
      SourceIdentity(url: f.url, commit: commit), cacheRoot: native(f.cache))
    let (first, second) = try await (left, right)
    #expect(first.directory == second.directory)
    #expect(
      !FileManager.default.fileExists(atPath: directory.appendingPathComponent("partial.txt").path))
    #expect(
      try SafePath.files(in: directory).map(\.string) == [
        ".gitattributes", "default.yaml", "dicts/words.txt",
      ])
  }

  @Test func unavailableCommitsNeverFallBackToBranchTips() async throws {
    let f = try GitFixture()
    defer { f.remove() }
    _ = try f.commit("first")
    let missing = String(repeating: "a", count: 40)
    await #expect(throws: PinewindError.self) {
      try await f.backend().prepareSource(
        SourceIdentity(url: f.url, commit: missing), cacheRoot: native(f.cache))
    }
    let directory = f.cache.appendingPathComponent("packages").appendingPathComponent(
      GitKitRepositoryProvider.cacheKey(f.url)
    ).appendingPathComponent(missing)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }

  @Test func symlinkCommitsFailWithoutPublishingOrDamagingEarlierViews() async throws {
    let f = try GitFixture()
    defer { f.remove() }
    let first = try f.commit("first")
    let backend = f.backend()
    let good = try await backend.prepareSource(
      SourceIdentity(url: f.url, commit: first), cacheRoot: native(f.cache))
    try FileManager.default.createSymbolicLink(
      atPath: f.origin.appendingPathComponent("link").path, withDestinationPath: "default.yaml")
    let bad = try f.commit("symlink", extra: ["link"])
    await #expect(throws: PinewindError.self) {
      try await backend.prepareSource(
        SourceIdentity(url: f.url, commit: bad), cacheRoot: native(f.cache))
    }
    #expect(
      try String(contentsOf: good.directory.appending("default.yaml"), encoding: .utf8)
        == "value: first\n")
    let parent = good.directory.removingLastComponent()
    #expect(!FileManager.default.fileExists(atPath: parent.appending(bad).string))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: parent.string).allSatisfy {
        !$0.hasPrefix(".candidate-")
      })
  }

  @Test(arguments: [
    "file:///tmp/repository", "http://github.com/u/r", "ssh://git@github.com/u/r",
    "https://github.com/u", "https://github.com/u/r/extra",
  ])
  func rejectsNonHTTPSAndMalformedSources(_ text: String) async throws {
    let url = try #require(URL(string: text))
    await #expect {
      try await GitKitRepositoryProvider().resolve(RepositoryRequest(url: url)).commit.string
    } throws: { ($0 as? PinewindError) != nil || $0 is Failure }
  }

  @Test func explicitCommitResolutionIsOfflineAndNormalizesCase() async throws {
    let commit = String(repeating: "A", count: 40)
    let backend = GitKitRepositoryProvider()
    let downloader = HTTPSResourceDownloader()
    #expect(
      try await backend.resolve(
        RepositoryRequest(
          url: URL(string: "https://github.com/u/r")!, revision: .commit(CommitID(commit)))
      ).commit.string
        == commit.lowercased())
    await #expect(throws: PinewindError.self) {
      try await downloadedData(using: downloader, from: URL(string: "http://example.org/file")!)
    }
  }

  #if canImport(FoundationNetworking)
    @Test(.disabled("Corelibs Foundation does not create download files for custom URLProtocol"))
  #else
    @Test
  #endif
  func downloadsHTTPSResourcesAndReportsHTTPFailures() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ResourceProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let downloader = HTTPSResourceDownloader(session: session)
    #expect(
      try await downloadedData(using: downloader, from: URL(string: "https://resource.test/ok")!)
        == Data("resource".utf8))
    await #expect(throws: PinewindError.self) {
      try await downloadedData(
        using: downloader, from: URL(string: "https://resource.test/missing")!)
    }
  }

  #if canImport(FoundationNetworking)
    @Test(.disabled("Corelibs Foundation download tasks trap with custom URLProtocol"))
  #else
    @Test
  #endif
  func downloadAbortsMidTransferWhenByteCapIsExceeded() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ResourceProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let downloader = HTTPSResourceDownloader(session: session)
    let file = native(
      FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: file) }
    await #expect {
      try await downloader.download(
        URL(string: "https://resource.test/ok")!, to: file, maximumBytes: 2)
    } throws: { error in
      guard case .runtime(.network(.sizeLimitExceeded(let url, _))) = error as? PinewindError else {
        return false
      }
      return url.absoluteString == "https://resource.test/ok"
    }
    #expect(!FileManager.default.fileExists(atPath: file.string))
    try await downloader.download(
      URL(string: "https://resource.test/ok")!, to: file, maximumBytes: 8)
    #expect(try Data(contentsOf: file) == Data("resource".utf8))
  }

  @Test func downloadTransportFailuresKeepErrorCodesAndCancellation() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ResourceProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let downloader = HTTPSResourceDownloader(session: session)
    do {
      _ = try await downloadedData(
        using: downloader, from: URL(string: "https://resource.test/offline")!)
      Issue.record("expected a transport failure")
    } catch let error as PinewindError {
      guard case .runtime(.network(.transportFailed(let url, .connection, _))) = error,
        url == URL(string: "https://resource.test/offline")
      else {
        Issue.record("\(error)")
        return
      }
    }
    await #expect(throws: CancellationError.self) {
      try await downloadedData(
        using: downloader, from: URL(string: "https://resource.test/cancelled")!)
    }
  }

  #if canImport(FoundationNetworking)
    @Test(
      .disabled("Corelibs Foundation does not create download files for custom URLProtocol"),
      arguments: [nil, 8] as [Int?])
  #else
    @Test(arguments: [nil, 8] as [Int?])
  #endif
  func destinationFailuresKeepTheirFileDomain(_ maximumBytes: Int?) async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ResourceProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let root = native(
      FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let blocker = root.appending("not-a-directory")
    try Data().write(to: blocker)
    do {
      try await HTTPSResourceDownloader(session: session).download(
        URL(string: "https://resource.test/ok")!, to: blocker.appending("resource"),
        maximumBytes: maximumBytes)
      Issue.record("expected a destination failure")
    } catch let error as PinewindError {
      guard case .runtime(.file(.operationFailed(let failure))) = error else {
        Issue.record("destination failure left the file domain: \(error)")
        return
      }
      #expect(failure.operation == .createDirectory)
      #expect(failure.paths == [blocker])
    }
  }

  @Test func cancelledPreparationDoesNotWriteCacheOrPublish() async throws {
    let f = try GitFixture()
    defer { f.remove() }
    let commit = try f.commit("first")
    let backend = f.backend()
    let gate = StartGate()
    let task = Task {
      await gate.wait()
      return try await backend.prepareSource(
        SourceIdentity(url: f.url, commit: commit), cacheRoot: native(f.cache))
    }
    task.cancel()
    await gate.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: f.cache.path))
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["PINEWIND_NETWORK_TESTS"] == "1"))
  func githubHTTPSGitFetchesLockedCommitAndIndependentResource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pinewind-network-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let backend = GitKitRepositoryProvider()
    let downloader = HTTPSResourceDownloader()
    let url = URL(string: "https://github.com/rime/rime-prelude")!
    let commit = try await backend.resolve(RepositoryRequest(url: url)).commit.string
    let snapshot = try await backend.prepareSource(
      SourceIdentity(url: url, commit: commit), cacheRoot: native(root))
    let bytes = try Data(contentsOf: snapshot.directory.appending("default.yaml"))
    #expect(!bytes.isEmpty)
    #expect(
      !FileManager.default.fileExists(
        atPath: snapshot.directory.appending(".git").string))
    let resource = try await downloadedData(
      using: downloader,
      from: URL(
        string: "https://raw.githubusercontent.com/rime/rime-prelude/\(commit)/default.yaml")!)
    #expect(resource == bytes)
  }
}

private func downloadedData(using downloader: HTTPSResourceDownloader, from url: URL) async throws
  -> Data
{
  let file = native(
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
  defer { try? FileManager.default.removeItem(at: file) }
  try await downloader.download(url, to: file, maximumBytes: nil)
  return try Data(contentsOf: file)
}

private struct LocalGitTransport: GitTransport {
  let origin: URL
  var expectedURL: URL? = nil
  private let client = GitKitTransport(credentials: nil)
  func advertise(url: URL) throws -> [GitReference] {
    try validate(url)
    return try client.advertise(url: origin)
  }
  func containsCommit(_ commit: String, repository: FilePath) throws -> Bool {
    try client.containsCommit(commit, repository: repository)
  }
  func fetch(url: URL, repository: FilePath, commit: String) throws {
    try validate(url)
    try client.fetch(url: origin, repository: repository, commit: commit)
  }
  func export(commit: String, repository: FilePath, destination: FilePath) throws {
    try client.export(commit: commit, repository: repository, destination: destination)
  }
  private func validate(_ url: URL) throws {
    if let expectedURL, url != expectedURL {
      throw PinewindError.runtime(
        .git(
          .operationFailed(
            repository: url, operation: "validate", status: -1,
            detail: "unexpected Git transport URL; expected \(expectedURL)")))
    }
  }
}

private struct GitFixture {
  let root: URL
  var origin: URL { root.appendingPathComponent("origin") }
  var cache: URL { root.appendingPathComponent("cache") }
  let url = URL(string: "https://github.com/example/package")!

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pinewind-git-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = Self.initialized
    var repository: OpaquePointer?
    try Self.check(git_repository_init(&repository, origin.path, 0))
    defer { git_repository_free(repository) }
    try Self.check(git_repository_set_head(repository, "refs/heads/main"))
    let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    let source = fixtures.appendingPathComponent("GitFetch/package")
    for item in try FileManager.default.contentsOfDirectory(
      at: source, includingPropertiesForKeys: nil)
    {
      try FileManager.default.copyItem(
        at: item, to: origin.appendingPathComponent(item.lastPathComponent))
    }
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
  func backend() -> GitKitRepositoryProvider {
    GitKitRepositoryProvider(transport: LocalGitTransport(origin: origin))
  }

  func commit(_ message: String, extra: [String] = []) throws -> String {
    try withRepository { repository in
      var index: OpaquePointer?
      try Self.check(git_repository_index(&index, repository))
      defer { git_index_free(index) }
      for path in ["default.yaml", "dicts/words.txt", ".gitattributes"] + extra {
        try Self.check(git_index_add_bypath(index, path))
      }
      try Self.check(git_index_write(index))
      var treeID = git_oid()
      try Self.check(git_index_write_tree(&treeID, index))
      var tree: OpaquePointer?
      try Self.check(git_tree_lookup(&tree, repository, &treeID))
      defer { git_tree_free(tree) }
      var signature: UnsafeMutablePointer<git_signature>?
      try Self.check(git_signature_now(&signature, "Pinewind fixture", "fixture@example.invalid"))
      defer { git_signature_free(signature) }
      var head: OpaquePointer?
      let status = git_repository_head(&head, repository)
      defer { git_reference_free(head) }
      var parents: [OpaquePointer?] = []
      if status == 0, let target = git_reference_target(head) {
        var parent: OpaquePointer?
        try Self.check(git_commit_lookup(&parent, repository, target))
        parents.append(parent)
      } else if status != GIT_EUNBORNBRANCH.rawValue {
        try Self.check(status)
      }
      defer { for parent in parents { git_commit_free(parent) } }
      var id = git_oid()
      try parents.withUnsafeMutableBufferPointer {
        try Self.check(
          git_commit_create(
            &id, repository, "HEAD", signature, signature, nil, message, tree, $0.count,
            $0.baseAddress))
      }
      return String(cString: git_oid_tostr_s(&id)!)
    }
  }

  func tag(_ name: String, commit: String) throws {
    try withRepository { repository in
      var oid = git_oid()
      try Self.check(git_oid_fromstr(&oid, commit))
      var target: OpaquePointer?
      try Self.check(git_commit_lookup(&target, repository, &oid))
      defer { git_commit_free(target) }
      var signature: UnsafeMutablePointer<git_signature>?
      try Self.check(git_signature_now(&signature, "Pinewind fixture", "fixture@example.invalid"))
      defer { git_signature_free(signature) }
      var tag = git_oid()
      try Self.check(git_tag_create(&tag, repository, name, target, signature, "fixture tag", 0))
    }
  }

  func branch(_ name: String, commit: String) throws {
    try withRepository { repository in
      var oid = git_oid()
      try Self.check(git_oid_fromstr(&oid, commit))
      var target: OpaquePointer?
      try Self.check(git_commit_lookup(&target, repository, &oid))
      defer { git_commit_free(target) }
      var reference: OpaquePointer?
      try Self.check(git_branch_create(&reference, repository, name, target, 0))
      git_reference_free(reference)
    }
  }

  private func withRepository<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    var repository: OpaquePointer?
    try Self.check(git_repository_open(&repository, origin.path))
    defer { git_repository_free(repository) }
    return try body(try #require(repository))
  }

  private static let initialized = git_libgit2_init()
  private static func check(_ status: Int32) throws {
    guard status >= 0 else {
      throw PinewindError.runtime(
        .defect(
          .wrapped(
            detail: git_error_last().flatMap { $0.pointee.message }.map { String(cString: $0) }
              ?? "fixture Git operation failed", origin: Origin())))
    }
  }
}

private final class ResourceProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "resource.test"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    if request.url?.path == "/offline" || request.url?.path == "/cancelled" {
      client?.urlProtocol(
        self,
        didFailWithError: URLError(
          request.url?.path == "/cancelled" ? .cancelled : .cannotConnectToHost))
      return
    }
    let status = request.url?.path == "/ok" ? 200 : 404
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("resource".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

private actor StartGate {
  private var released = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    if !released { await withCheckedContinuation { continuation = $0 } }
  }
  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
