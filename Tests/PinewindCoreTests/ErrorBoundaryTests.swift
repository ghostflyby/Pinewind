// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage
import Testing
import Yams

@testable import PinewindCore

@Suite("Error boundaries")
struct ErrorBoundaryTests {
  private let endpoint = URL(string: "https://example.test/package")!

  @Test func concreteErrorsRemainConcreteAndNormalizationIsIdempotent() throws {
    let original = GitFailure.authenticationRequired(endpoint)
    let once = ErrorBoundary.normalize(original)
    #expect(once as? GitFailure == original)
    #expect(ErrorBoundary.normalize(once) as? GitFailure == original)
    let native = Errno.permissionDenied
    #expect(ErrorBoundary.normalize(native) as? Errno == native)
  }

  @Test func unknownFailuresKeepTheirOriginalTypeAndIdentity() throws {
    let original = NSError(domain: "foreign", code: 9, userInfo: ["extra": "original"])
    #expect(ErrorBoundary.normalize(original) as NSError === original)
    enum Foreign: Error, Equatable { case unexpected }
    #expect(ErrorBoundary.normalize(Foreign.unexpected) as? Foreign == .unexpected)
  }

  @Test func documentWrappersPreserveConcreteCodableCauses() throws {
    let context = try DocumentContext(
      path: "declaration.yaml", placement: Placement(line: 3, column: 7))
    let original = DocumentError(context: context, failure: DeclarationFailure.unknownName("x"))
    let erased: any DocumentErrorProtocol = original
    #expect(erased.underlyingError as? DeclarationFailure == .unknownName("x"))
    let serializable: any CodablePinewindError = original
    let encoded = try JSONEncoder().encode(serializable)
    #expect(
      try JSONDecoder().decode(DocumentError<DeclarationFailure>.self, from: encoded) == original)
    enum Foreign: Error { case opaque }
    let opaque: any DocumentErrorProtocol = DocumentError(context: context, failure: Foreign.opaque)
    #expect(!(opaque is any Encodable))
  }

  @Test func reportRejectsOpaqueCausesRatherThanLosingTheirStructure() throws {
    enum Opaque: Error { case value }
    let context = try DocumentContext(path: "actual.yaml", placement: Placement(line: 1, column: 1))
    let report = LintReport(diagnostics: [DocumentError(context: context, failure: Opaque.value)])
    #expect(throws: EncodingError.self) { _ = try JSONEncoder().encode(report) }
  }

  @Test func cancellationBypassesNormalizationAttributionAndHashing() throws {
    let context = try DocumentContext(path: "declaration.yaml")
    #expect(ErrorBoundary.normalize(CancellationError()) is CancellationError)
    #expect(
      ErrorBoundary.attribute(CancellationError(), to: context, as: .configuration)
        is CancellationError)
    let file = native(try fixtureURL("Configuration/round-trip.yaml"))
    let signal = CancellationSignal()
    signal.cancel()
    #expect(throws: CancellationError.self) {
      try Cancellation.$signal.withValue(signal) { try SnapshotFiles.sha256(file) }
    }
  }

  @Test func attributionIsAnExplicitDecisionAtTheOperationBoundary() throws {
    let context = try DocumentContext(
      path: "declaration.yaml", placement: Placement(line: 3, column: 7))
    let cause = GitFailure.referenceNotFound("missing")
    guard
      case .configuration(let verdict) = ErrorBoundary.attribute(
        cause, to: context, as: .configuration) as? PinewindError,
      case .incident(let observation) = ErrorBoundary.attribute(cause, to: context, as: .incident)
        as? PinewindError
    else {
      Issue.record("lost explicit attribution")
      return
    }
    #expect(verdict.underlyingError as? GitFailure == cause)
    #expect(observation.underlyingError as? GitFailure == cause)
  }

  @Test func enclosingFramesKeepThePrimaryLocationAndTheirOrder() throws {
    let inner = try DocumentContext(path: "included.conf", placement: Placement(line: 9, column: 2))
    let middle = try DocumentContext(path: "import.conf", placement: Placement(line: 4, column: 1))
    let outer = try DocumentContext(path: "manifest.yaml", placement: Placement(line: 6, column: 3))
    let original = PinewindError.configuration(
      DocumentError(context: inner, failure: DeclarationFailure.unknownName("x")))
    #expect(sameError(try #require(ErrorBoundary.normalize(original) as? PinewindError), original))
    #expect(sameError(original.attributed(to: outer, as: .incident), original))
    let error = original.addingDerivation(middle).addingDerivation(outer)
    guard case .configuration(let document) = error else {
      Issue.record("lost verdict")
      return
    }
    #expect(document.context.path == inner.path)
    #expect(document.context.placement == inner.placement)
    #expect(document.context.derivation == [outer, middle])
  }

  @Test func executionQueueRelaysForeignErrorsUntilTheOwningBoundary() async {
    enum Foreign: Error, Equatable { case unexpected }
    await #expect(throws: Foreign.unexpected) {
      try await BlockingIO.run { throw Foreign.unexpected }
    }
  }

  @Test func fileTranslationPreservesOperationPathsAndNativeCode() throws {
    let file = FilePath("output.yaml")
    do {
      try FileIO.perform(.write, paths: [file]) { throw Errno.permissionDenied }
      Issue.record("expected a file failure")
    } catch let failure as FileOperationFailure<Errno> {
      #expect(failure.operation == .write)
      #expect(failure.paths == [file])
      #expect(failure.cause == Errno.permissionDenied)
      let encoded = try JSONEncoder().encode(failure)
      let decoded = try JSONDecoder().decode(FileOperationFailure<Errno>.self, from: encoded)
      #expect(decoded.cause == failure.cause && decoded.paths == failure.paths)
    }
    enum Foreign: Error, Equatable { case unexpected }
    #expect(throws: Foreign.unexpected) {
      try FileIO.perform(.read, paths: [file]) { throw Foreign.unexpected }
    }
    #expect(throws: CancellationError.self) {
      try FileIO.perform(.read, paths: [file]) { throw CancellationError() }
    }
  }

  @Test func yamlSyntaxErrorsKeepStructuredPositions() throws {
    do {
      _ = try ManifestDocument.parse("version: 1\norder: [self", source: "broken.yaml")
      Issue.record("expected a syntax error")
    } catch let error as PinewindError {
      guard case .configuration(let document) = error else {
        Issue.record("lost verdict")
        return
      }
      #expect(document.context.path == FilePath("broken.yaml"))
      #expect(document.context.placement != nil)
      #expect(document.context.placement?.line == 2)
    }
  }

  @Test func aMalformedSecondDocumentCannotBeSilentlyIgnored() {
    #expect(throws: PinewindError.self) {
      _ = try ManifestDocument.parse("version: 1\norder: []\n---\ninvalid: [")
    }
  }

  @Test func semanticYamlColumnsUseUTF16AndKeepTheInvalidField() throws {
    let line = "names: {demo: {options: {label: 😀}, revision: {commit: invalid}}}"
    do {
      _ = try ManifestDocument.parse("version: 1\n\(line)\norder: [demo]", source: "unicode.yaml")
      Issue.record("expected an invalid commit")
    } catch let error as PinewindError {
      guard case .configuration(let document) = error else {
        Issue.record("lost verdict")
        return
      }
      #expect(
        (document.underlyingError as? DeclarationFailure)
          == DeclarationFailure.invalidCommitID("invalid"))
      let prefix = String(line[..<line.range(of: "invalid")!.lowerBound])
      #expect(document.context.placement == Placement(line: 2, column: prefix.utf16.count + 1))
    }
  }
  @Test(arguments: ["RecipeTarget", "RecipeOption", "RecipeExpanded"])
  func recipeFailuresPointToTheAuthoredTemplate(_ name: String) throws {
    let directory = native(try fixtureURL("Errors/" + name))
    let options = name == "RecipeExpanded" ? ["schema": "["] : [:]
    let request = try PackageRequest(url: directory.foundationURL, options: options)
    do {
      _ = try Recipe.load(
        request: request, directory: directory, read: { try Data(contentsOf: $0) })
      Issue.record("expected a recipe error")
    } catch let error as PinewindError {
      guard case .configuration(let document) = error else {
        Issue.record("lost recipe verdict")
        return
      }
      #expect(document.context.path == directory.appending("recipe.yaml"))
      #expect(document.context.placement?.line == (name == "RecipeTarget" ? 2 : 5))
      switch name {
      case "RecipeTarget":
        #expect(
          (document.underlyingError as? DeclarationFailure)
            == DeclarationFailure.undeclaredOption("missing"))
      case "RecipeOption":
        #expect(
          (document.underlyingError as? DeclarationFailure)
            == DeclarationFailure.optionValueMissing("schema"))
      default:
        guard document.underlyingError is YamlError else {
          Issue.record("lost YAML syntax failure")
          return
        }
      }
    }
  }

  @Test func corruptedLockValuesRemainAnchoredLockFailures() throws {
    let request = try PackageRequest(url: endpoint)
    let snapshot = try configurationSnapshot(
      ManifestDocument(order: [.package(PackageFields(url: .value(endpoint)))]))
    let entry = ResolutionCodec.Entry(.package(request), index: 0)
    let payload = ResolutionCodec.Payload(
      version: 1, declarations: [entry], expanded: [entry],
      packages: [
        ResolutionCodec.Package(
          request: ResolutionCodec.Request(request), commit: "invalid", resources: [])
      ], imports: [])
    let encoded = ResolutionCodec.magic + (try PropertyListEncoder().encode(payload))
    let undecodable = ResolutionCodec.magic + Data("invalid property list".utf8)
    for bytes in [encoded, undecodable] {
      do {
        _ = try ResolutionCodec.decode(bytes, snapshot: snapshot)
        Issue.record("expected a malformed lock")
      } catch let error as PinewindError {
        guard case .configuration(let document) = error,
          case .malformed = document.underlyingError as? LockFailure
        else {
          Issue.record("lost lock attribution: \(error)")
          return
        }
        #expect(document.context.path == (try snapshot.locations.configuration.lock.filePath))
      }
    }
  }

  @Test func corruptOfflineCacheReportsBothChecksums() async throws {
    let root = native(
      FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: root) }
    let pin = try PinnedResource(
      url: endpoint, path: RelativePath("resource"), sha256: String(repeating: "a", count: 64))
    let store = ResourceStore(root: root, downloader: RejectingServices(), maximumBytes: 1024)
    let path = store.path(pin)
    try FileManager.default.createDirectory(
      at: path.removingLastComponent(), withIntermediateDirectories: true)
    try Data().write(to: path)
    do {
      try await store.ensure(pin, network: false)
      Issue.record("expected a checksum mismatch")
    } catch let error as CacheFailure {
      #expect(
        error
          == .checksumMismatch(
            url: endpoint, expected: pin.sha256,
            actual: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
    }
  }

  @Test func workspaceBoxesInjectedDomainFailuresAndKeepsTheDocumentAsAnIncident() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = try fixtureLocations(
      input: root.appendingPathComponent("input"), local: root.appendingPathComponent("local"))
    let manifest = try locations.configuration.manifest.filePath
    try FileManager.default.createDirectory(
      at: manifest.removingLastComponent(), withIntermediateDirectories: true)
    try Data("version: 1\norder: [{url: https://example.test/package}]\n".utf8).write(to: manifest)
    let workspace = try await Workspace.open(
      locations: locations,
      services: WorkspaceServices(repositories: RejectingServices(), resources: RejectingServices())
    )
    do {
      _ = try await workspace.resolve()
      Issue.record("expected an authentication incident")
    } catch let error as PinewindError {
      guard case .incident(let document) = error else {
        Issue.record("lost incident: \(error)")
        return
      }
      #expect(document.context.path == manifest)
      #expect(
        (document.underlyingError as? GitFailure) == GitFailure.authenticationRequired(endpoint))
    }
  }

}

private struct RejectingServices: RepositoryProvider, ResourceDownloader {
  func resolve(_ request: RepositoryRequest) async throws -> SourceIdentity {
    throw GitFailure.authenticationRequired(request.url)
  }
  func prepareSource(_ identity: SourceIdentity, cacheRoot: FilePath) async throws -> SourceSnapshot
  {
    Issue.record("unexpected source preparation")
    throw CancellationError()
  }
  func download(_ url: URL, to destination: FilePath, maximumBytes: Int?) async throws {
    Issue.record("unexpected resource download")
    throw CancellationError()
  }
}
