// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

/// Errors may opt into standard presentation without joining a closed vocabulary.
public protocol PinewindErrorProtocol: Error, Sendable, CustomStringConvertible {}
public typealias CodablePinewindError = PinewindErrorProtocol & Codable

/// Read-only access to a document wrapper without knowing its concrete cause type.
public protocol DocumentErrorProtocol: PinewindErrorProtocol {
  var context: DocumentContext { get }
  var underlyingError: any Error { get }
}

/// A contextual wrapper preserves its cause's concrete type and capabilities.
public struct DocumentError<E: Error>: DocumentErrorProtocol {
  public let context: DocumentContext
  public let failure: E
  public var underlyingError: any Error { failure }
  public init(context: DocumentContext, failure: E) {
    self.context = context
    self.failure = failure
  }
  public var description: String { context.description + ": " + String(describing: failure) }
}
extension DocumentError: Encodable where E: Encodable {}
extension DocumentError: Decodable where E: Decodable {}
extension DocumentError: Equatable where E: Equatable {}
extension DocumentError: Hashable where E: Hashable {}

/// Attribution is independent of the open set of underlying error types.
public enum PinewindError: PinewindErrorProtocol {
  case configuration(any DocumentErrorProtocol)
  case incident(any DocumentErrorProtocol)
  case runtime(any Error)

  public var description: String {
    switch self {
    case .configuration(let error): return error.description
    case .incident(let error): return "incident: " + error.description
    case .runtime(let error): return String(describing: error)
    }
  }

  func attributed(to context: DocumentContext, as attribution: DocumentAttribution) -> PinewindError
  {
    guard case .runtime(let failure) = self else { return self }
    if failure is Defect { return self }
    func wrap<E: Error>(_ cause: E) -> any DocumentErrorProtocol {
      DocumentError(context: context, failure: cause)
    }
    let document = wrap(failure)
    return attribution == .configuration ? .configuration(document) : .incident(document)
  }

  func addingDerivation(_ frame: DocumentContext) -> PinewindError {
    func adding(to error: any DocumentErrorProtocol) -> any DocumentErrorProtocol {
      var context = error.context
      var anchor = frame
      anchor.derivation = []
      context.derivation = frame.derivation + [anchor] + context.derivation
      func wrap<E: Error>(_ cause: E) -> any DocumentErrorProtocol {
        DocumentError(context: context, failure: cause)
      }
      return wrap(error.underlyingError)
    }
    switch self {
    case .configuration(let error): return .configuration(adding(to: error))
    case .incident(let error): return .incident(adding(to: error))
    case .runtime: return self
    }
  }
}

enum DocumentAttribution: Sendable { case configuration, incident }

/// Unknown and external errors retain their concrete values; cancellation passes through.
enum ErrorBoundary {
  static func normalize(_ error: any Error) -> any Error {
    error
  }
  static func attribute(
    _ error: any Error, to context: DocumentContext, as attribution: DocumentAttribution
  ) -> any Error {
    if error is CancellationError || error is Defect { return error }
    let value = (error as? PinewindError) ?? .runtime(error)
    return value.attributed(to: context, as: attribution)
  }
}

/// Where a document lives and where in it the failure points.
public struct DocumentContext: Codable, Sendable, Hashable, CustomStringConvertible {
  /// Local path of the document (or of its captured view).
  public var path: FilePath
  /// Identity of the document: local file URL or remote source.
  public var url: URL
  /// Position inside the document, when the fact points into the text.
  public var placement: Placement?
  /// How this document was reached: enclosing frames, outermost first.
  public var derivation: [DocumentContext]

  public init(
    path: FilePath, url: URL, placement: Placement? = nil, derivation: [DocumentContext] = []
  ) {
    self.path = path
    self.url = url.absoluteURL
    self.placement = placement
    self.derivation = derivation
  }
  public init(path: FilePath, placement: Placement? = nil) throws {
    self.init(path: path, url: try path.foundationURL, placement: placement)
  }

  private enum CodingKeys: String, CodingKey { case path, url, placement, derivation }
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    guard let path = String(validating: path) else {
      throw EncodingError.invalidValue(
        path,
        .init(
          codingPath: values.codingPath,
          debugDescription: "The document path cannot be represented as Unicode"))
    }
    try values.encode(path, forKey: .path)
    try values.encode(url, forKey: .url)
    try values.encodeIfPresent(placement, forKey: .placement)
    try values.encode(derivation, forKey: .derivation)
  }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      path: FilePath(try values.decode(String.self, forKey: .path)),
      url: try values.decode(URL.self, forKey: .url),
      placement: try values.decodeIfPresent(Placement.self, forKey: .placement),
      derivation: try values.decode([DocumentContext].self, forKey: .derivation))
  }

  public var description: String {
    var text = path.string
    if let placement { text += ": " + placement.description }
    for frame in derivation { text += " (via " + frame.description + ")" }
    return text
  }
}

/// A position inside a document: one-based lines and UTF-16 columns.
public struct Placement: Codable, Sendable, Hashable, CustomStringConvertible {
  public var line: Int
  public var column: Int
  public var endLine: Int?
  public var endColumn: Int?
  public init(line: Int, column: Int, endLine: Int? = nil, endColumn: Int? = nil) {
    self.line = line
    self.column = column
    self.endLine = endLine
    self.endColumn = endColumn
  }
  public var description: String {
    var text = "\(line):\(column)"
    if let endLine, let endColumn { text += "-\(endLine):\(endColumn)" }
    return text
  }
}

/// Origin of an error inside the library itself, for the developer audience.
public struct Origin: Codable, Sendable, Hashable, CustomStringConvertible {
  public var file: String
  public var line: UInt
  public init(file: String, line: UInt) {
    self.file = file
    self.line = line
  }
  public init(fileID: String = #fileID, line: UInt = #line) {
    self.file = fileID
    self.line = line
  }
  public var description: String { file + ":\(line)" }
}

public enum GitFailure: PinewindErrorProtocol, Codable, Hashable {
  case referenceNotFound(String)
  case ambiguousReference(String)
  case defaultBranchIndeterminate(URL)
  case authenticationRequired(URL)
  case commitUnavailable(commit: String, repository: URL)
  case operationFailed(repository: URL, operation: String, status: Int32, detail: String)
  case unsupportedSourceURL(URL)
  case malformedRepositoryURL(URL)
  case treeEntryInvalid(TreeEntry)

  public var description: String {
    switch self {
    case .referenceNotFound(let name): return "Git reference not found: \(name)"
    case .ambiguousReference(let name):
      return "ambiguous Git reference '\(name)'; use refs/heads/ or refs/tags/"
    case .defaultBranchIndeterminate(let url):
      return "Git remote does not advertise an unambiguous default branch: \(url.absoluteString)"
    case .authenticationRequired(let url): return "authentication required: \(url.absoluteString)"
    case .commitUnavailable(let commit, let repository):
      return "locked commit \(commit) is unavailable: \(repository.absoluteString)"
    case .operationFailed(let repository, let operation, let status, let detail):
      return "Git \(operation) failed (\(status)) on \(repository.absoluteString): \(detail)"
    case .unsupportedSourceURL(let url):
      return "Git sources require an HTTPS repository URL: \(url.absoluteString)"
    case .malformedRepositoryURL(let url): return "malformed repository URL: \(url.absoluteString)"
    case .treeEntryInvalid(let entry): return "Git tree entry invalid: \(entry.description)"
    }
  }
}

public enum TreeEntry: Codable, Sendable, Hashable, CustomStringConvertible {
  case undecodableName
  case notASingleComponent(String)
  case reservedMetadata(String)
  case symbolicLink(String)

  public var description: String {
    switch self {
    case .undecodableName: return "entry name is not valid UTF-8"
    case .notASingleComponent(let name): return "entry must be a single filename: \(name)"
    case .reservedMetadata(let name): return "entry uses reserved metadata: \(name)"
    case .symbolicLink(let name):
      return "symbolic links are not supported in package sources: \(name)"
    }
  }
}

public enum FileSystemFailure: PinewindErrorProtocol, Codable, Hashable {
  case notFound(FilePath)
  case notRegularFile(FilePath)
  case notADirectory(FilePath)
  case symbolicLinkNotAllowed(FilePath)
  case unreadable(path: FilePath, detail: String)
  case unwritable(path: FilePath, detail: String)
  case unresolvable(FilePath)
  case escapesRoot(path: FilePath, root: FilePath)
  case enumerationFailed(FilePath)
  case exchangeFailed(errno: Int32)
  case publicationFailed(detail: String)
  case undecodableText(FilePath)
  case notPortable(FilePath)
  case unsafeRelative(FilePath)
  case notAbsoluteFileURL(URL)
  case unrepresentableFileURL(URL)
  case nonLocalFileURL(URL)
  case ambiguousForm(FilePath)
  case isFilesystemRoot(FilePath)
  case overlappingPaths(FilePath, FilePath)
  case duplicatePath(FilePath)
  case lockFailed(detail: String)

  public var description: String {
    switch self {
    case .notFound(let path): return "no such file: \(path.string)"
    case .notRegularFile(let path): return "not a regular file: \(path.string)"
    case .notADirectory(let path): return "not a directory: \(path.string)"
    case .symbolicLinkNotAllowed(let path):
      return "symbolic links are not supported: \(path.string)"
    case .unreadable(let path, let detail): return "cannot read \(path.string): \(detail)"
    case .unwritable(let path, let detail): return "cannot write \(path.string): \(detail)"
    case .unresolvable(let path): return "cannot resolve filesystem path: \(path.string)"
    case .escapesRoot(let path, let root):
      return "path escapes its source root: \(path.string) (root \(root.string))"
    case .enumerationFailed(let path): return "cannot enumerate source: \(path.string)"
    case .exchangeFailed(let status):
      return "cannot atomically exchange composition directories (errno \(status))"
    case .publicationFailed(let detail): return "composition publication failed: \(detail)"
    case .undecodableText(let path): return "file is not valid UTF-8 text: \(path.string)"
    case .notPortable(let path):
      return "resource paths require portable relative components: \(path.string)"
    case .unsafeRelative(let path): return "unsafe relative path: \(path.string)"
    case .notAbsoluteFileURL(let url):
      return "external document URLs must identify an absolute location: \(url.absoluteString)"
    case .unrepresentableFileURL(let url):
      return "expected a representable file URL: \(url.absoluteString)"
    case .nonLocalFileURL(let url):
      return "file URL must address the local filesystem: \(url.absoluteString)"
    case .ambiguousForm(let path):
      return
        "drive-relative and root-relative paths require a fully qualified location: \(path.string)"
    case .isFilesystemRoot(let path): return "path is a filesystem root: \(path.string)"
    case .overlappingPaths(let first, let second):
      return "paths must not overlap: \(first.string), \(second.string)"
    case .duplicatePath(let path): return "duplicate location: \(path.string)"
    case .lockFailed(let detail): return "cannot acquire file lock: \(detail)"
    }
  }
}

public enum NetworkFailure: PinewindErrorProtocol, Codable, Hashable {
  case rejected(status: Int, url: URL)
  case insecureScheme(URL)
  case sizeLimitExceeded(url: URL, maximumBytes: Int)

  public var description: String {
    switch self {
    case .rejected(let status, let url):
      return "download returned HTTP \(status): \(url.absoluteString)"
    case .insecureScheme(let url): return "download did not return HTTPS: \(url.absoluteString)"
    case .sizeLimitExceeded(let url, let maximumBytes):
      return
        "download exceeds the resource size limit (\(maximumBytes) bytes): \(url.absoluteString)"
    }
  }
}

public enum InterpreterFailure: PinewindErrorProtocol, Codable, Hashable {
  case evaluationFailed(detail: String)
  case timedOut
  case budgetExceeded(Budget)
  case forbiddenOperation(path: String)
  case enumerationUnsupported
  case unknownBuiltIn(String)

  public var description: String {
    switch self {
    case .evaluationFailed(let detail): return "conf evaluation failed: \(detail)"
    case .timedOut: return "conf evaluation timed out"
    case .budgetExceeded(let budget):
      return "conf include resource limit exceeded: \(budget.description)"
    case .forbiddenOperation(let path): return "forbidden operation: \(path)"
    case .enumerationUnsupported: return "remote conf directory enumeration is unsupported"
    case .unknownBuiltIn(let name): return "unknown built-in conf '\(name)'"
    }
  }
}

public enum Budget: Codable, Sendable, Hashable, CustomStringConvertible {
  case sources
  case fileBytes
  case totalBytes
  public var description: String {
    switch self {
    case .sources: return "source count"
    case .fileBytes: return "single-file size"
    case .totalBytes: return "total size"
    }
  }
}

public enum DeclarationFailure: PinewindErrorProtocol, Codable, Hashable {
  case invalidPackageSource(String)
  case emptyName
  case reservedName(String)
  case unknownName(String)
  case nameStillReferenced(String)
  case duplicateName(String)
  case invalidCommitID(String)
  case invalidRevision
  case revisionWithFileSource
  case relativeSourceURL(URL)
  case unsupportedSourceURL(URL)
  case reservedVariable(String)
  case invalidPattern(pattern: String, detail: String)
  case duplicateTarget(String)
  case unmatchedPattern(String)
  case outputConflict
  case versionConflict
  case missingPreparedSnapshot
  case unpreparedResource
  case importNotExpanded
  case inlineURLRequired
  case namedURLForbidden
  case undecodablePatchTarget
  case nestedRxMarker(String)
  case unterminatedRxMarker(String)
  case patchNotASequence
  case patchRequiresBlockStyle
  case syntaxError(detail: String)
  case developmentRequired
  case importSourceRequired
  case orderIndexOutOfBounds
  case orderAnchorNotFound(String)
  case ambiguousOrderAnchor(String)
  case undeclaredOption(String)
  case optionValueMissing(String)
  case invalidChecksum(String)
  case preparedCommitMissing
  case preparedCommitMismatch(requested: String, prepared: String)
  case crossPackageSourceUnresolved(String)
  case invalidImportSource(String)

  public var description: String {
    switch self {
    case .invalidPackageSource(let source): return "invalid package source: \(source)"
    case .emptyName: return "dependency name must not be empty"
    case .reservedName(let name): return "'\(name)' is a reserved name"
    case .unknownName(let name): return "unknown package name '\(name)'"
    case .nameStillReferenced(let name): return "package name '\(name)' is still referenced"
    case .duplicateName(let name): return "duplicate package name '\(name)'"
    case .invalidCommitID(let value):
      return "commit must be a complete 40-character hexadecimal commit ID: \(value)"
    case .invalidRevision: return "invalid Git revision"
    case .revisionWithFileSource: return "file sources cannot specify revision"
    case .relativeSourceURL(let url):
      return "package requires an absolute source URL: \(url.absoluteString)"
    case .unsupportedSourceURL(let url):
      return
        "package sources must be local file URLs or HTTPS repository URLs: \(url.absoluteString)"
    case .reservedVariable(let name): return "'\(name)' is a reserved variable"
    case .invalidPattern(let pattern, let detail): return "invalid glob '\(pattern)': \(detail)"
    case .duplicateTarget(let target): return "recipe targets must be unique: \(target)"
    case .unmatchedPattern(let pattern): return "no files match pattern '\(pattern)'"
    case .outputConflict: return "conflicting output kinds for the same target"
    case .versionConflict: return "conflicting prepared package versions"
    case .missingPreparedSnapshot: return "package has no prepared snapshot"
    case .unpreparedResource: return "download resource has not been pinned and prepared"
    case .importNotExpanded: return "expand conf imports before planning composition"
    case .inlineURLRequired: return "inline package entries require a URL selector"
    case .namedURLForbidden:
      return "named entries require a single name selector; override URLs in names"
    case .undecodablePatchTarget: return "patch target is not valid UTF-8 YAML"
    case .nestedRxMarker(let rx): return "nested Rx marker: '\(rx)'"
    case .unterminatedRxMarker(let rx): return "unterminated Rx block: '\(rx)'"
    case .patchNotASequence: return "existing __patch must be a sequence"
    case .patchRequiresBlockStyle: return "existing __patch must use block-style YAML"
    case .syntaxError(let detail): return detail
    case .developmentRequired: return "declaration requires development preparation"
    case .importSourceRequired: return "conf import requires a source"
    case .orderIndexOutOfBounds: return "order entry index is out of bounds"
    case .orderAnchorNotFound(let name): return "order anchor '\(name)' was not found"
    case .ambiguousOrderAnchor(let name): return "order anchor '\(name)' matches multiple entries"
    case .undeclaredOption(let name):
      return "recipe option '\(name)' is not declared in recipe args"
    case .optionValueMissing(let name): return "recipe option '\(name)' has no value"
    case .invalidChecksum(let value): return "checksum must be a complete SHA-256 digest: \(value)"
    case .preparedCommitMissing: return "remote prepared source requires a commit"
    case .preparedCommitMismatch(let requested, let prepared):
      return "prepared commit \(prepared) does not match the requested commit \(requested)"
    case .crossPackageSourceUnresolved(let name):
      return "cross-package source is missing or ambiguous: \(name)"
    case .invalidImportSource(let source): return "invalid conf import source: \(source)"
    }
  }
}

public enum LockFailure: PinewindErrorProtocol, Codable, Hashable {
  case incompatible(detail: String)
  case malformed(detail: String)
  case declarationChanged
  case importUnresolved
  case resolveRequired

  public var description: String {
    switch self {
    case .incompatible(let detail): return "lock is incompatible: \(detail)"
    case .malformed(let detail): return "lock is malformed: \(detail)"
    case .declarationChanged: return "declarations changed; run resolve before composing"
    case .importUnresolved: return "import has no locked expansion"
    case .resolveRequired: return "resolve shared declarations before preparing packages"
    }
  }
}

public enum StateFailure: PinewindErrorProtocol, Codable, Hashable {
  case unsupportedFrontend(String)
  case ambiguousOutputDirectories([FilePath])
  case frontendRequired
  case runtimeOutputPath(RelativePath)
  case invalidConfigurationTransaction(FilePath)
  case publicationModeConflict(FilePath)
  case unmanagedOutputFiles(directory: FilePath, paths: [RelativePath])
  case invalidPublicationRecord(FilePath)
  case externallyModified
  case staleSnapshot
  case staleInputs
  case unknownSelection
  case overridesDisabled
  case invalidOptions
  case foreignSnapshot

  public var description: String {
    switch self {
    case .unsupportedFrontend(let name):
      return "frontend \(name) is unsupported on this platform; select a custom output directory"
    case .ambiguousOutputDirectories(let paths):
      return
        "multiple Rime directories found: \(paths.map(\.string).joined(separator: ", ")); select a destination"
    case .frontendRequired: return "cannot identify a Rime frontend; select a destination"
    case .runtimeOutputPath(let path): return "build contains Rime runtime data at \(path.string)"
    case .invalidConfigurationTransaction(let path):
      return
        "invalid configuration transaction: \(path.string). Restore the transaction from backup before accessing configuration."
    case .publicationModeConflict(let path):
      return
        "managed-file publication cannot target a Windows junction: \(path.string). Use a real directory rather than a replaceable generation."
    case .unmanagedOutputFiles(let directory, let paths):
      return
        "unmanaged files would be overwritten in \(directory.string): \(paths.map(\.string).joined(separator: ", ")). Preserve them as personal sources or explicitly approve replacement."
    case .invalidPublicationRecord(let path):
      return
        "invalid publication record: \(path.string). Restore a known-good backup, or move this record aside to reset ownership; existing files will be protected as unmanaged on the next build."
    case .externallyModified: return "configuration changed on disk; reload before saving"
    case .staleSnapshot: return "snapshot is stale; reload before editing"
    case .staleInputs: return "configuration or lock changed before publication"
    case .unknownSelection: return "update selection does not belong to the current resolution"
    case .overridesDisabled: return "local overrides are disabled"
    case .invalidOptions: return "workspace limits and timeouts must be positive"
    case .foreignSnapshot: return "phase result belongs to another workspace"
    }
  }
}

public enum CacheFailure: PinewindErrorProtocol, Codable, Hashable {
  case contentMissing(URL)
  case checksumMismatch(url: URL, expected: String, actual: String)

  public var description: String {
    switch self {
    case .contentMissing(let url):
      return "locked resource is absent from cache: \(url.absoluteString)"
    case .checksumMismatch(let url, let expected, let actual):
      return
        "resource checksum mismatch: \(url.absoluteString) (expected \(expected), actual \(actual))"
    }
  }
}

/// Failures of the library's own reasoning or of its foreign-error boundaries.
/// The audience is the library developer; the origin is the payload.
public enum Defect: PinewindErrorProtocol, Codable, Hashable {
  case invariant(detail: String, origin: Origin)
  case wrapped(detail: String, origin: Origin)

  public var description: String {
    switch self {
    case .invariant(let detail, let origin):
      return "internal invariant violated at \(origin.description): \(detail)"
    case .wrapped(let detail, let origin):
      return "unhandled failure at \(origin.description): \(detail)"
    }
  }
}

/// Equality is optional and used only when the concrete cause supports it.
func sameError(_ left: PinewindError, _ right: PinewindError) -> Bool {
  func same(_ a: any Error, _ b: any Error) -> Bool {
    guard let a = a as? AnyHashable, let b = b as? AnyHashable else { return false }
    return a == b
  }
  switch (left, right) {
  case (.configuration(let a), .configuration(let b)), (.incident(let a), .incident(let b)):
    return a.context == b.context && same(a.underlyingError, b.underlyingError)
  case (.runtime(let a), .runtime(let b)): return same(a, b)
  default: return false
  }
}
