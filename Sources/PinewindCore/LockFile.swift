// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

public struct PackageID: Hashable, Sendable {
  public let request: PackageRequest
  let commit: CommitID?
  let resources: [PinnedResource]
  init(_ request: PackageRequest, commit: CommitID? = nil, resources: [PinnedResource] = []) {
    self.request = request
    self.commit = commit
    self.resources = resources
  }
}
public struct ImportID: Hashable, Sendable {
  /// Position in the resolution that produced this ID, not a position in future manifests.
  public let index: Int
  public let request: ConfImport
  let packages: [PackageRequest]
  let resources: [PinnedResource]
  init(
    index: Int, request: ConfImport, packages: [PackageRequest] = [],
    resources: [PinnedResource] = []
  ) {
    self.index = index
    self.request = request
    self.packages = packages
    self.resources = resources
  }
}
public struct ResourceID: Hashable, Sendable {
  public let package: PackageID
  public let resource: PinnedResource
}
public enum UpdateSelection: Sendable {
  case all
  case packages(Set<PackageID>)
  /// Refreshes all current occurrences of each selected request. IDs must match the old lock.
  case imports(Set<ImportID>)
  case resources(Set<ResourceID>)
}
public struct LockedPackage: Hashable, Sendable {
  public var id: PackageID { PackageID(request, commit: commit, resources: resources) }
  public let request: PackageRequest
  public let commit: CommitID
  public let resources: [PinnedResource]
  init(request: PackageRequest, commit: CommitID, resources: [PinnedResource] = [])
    throws(LockFailure)
  {
    guard !request.url.isFileURL, request.commit == nil || request.commit == commit.string,
      Set(resources.map(\.path)).count == resources.count
    else {
      throw LockFailure.malformed(detail: "invalid or conflicting package resolution")
    }
    self.request = request
    self.commit = commit
    self.resources = resources
  }
  public var resourceIDs: [ResourceID] { resources.map { ResourceID(package: id, resource: $0) } }
}
public struct ResolvedImport: Sendable {
  public let id: ImportID
  public let packages: [PackageRequest]
  public let resources: [PinnedResource]
  init(id: ImportID, packages: [PackageRequest], resources: [PinnedResource]) {
    self.id = ImportID(
      index: id.index, request: id.request, packages: packages, resources: resources)
    self.packages = packages
    self.resources = resources
  }
}
public struct Resolution: Sendable {
  public let declarations: EvaluatedManifest
  public let expanded: EvaluatedManifest
  public let packages: [LockedPackage]
  public let imports: [ResolvedImport]
  let snapshot: ConfigurationSnapshot
  let preview: Bool
  let lockBytes: Data?
  init(
    declarations: Manifest, expanded: Manifest, packages: [LockedPackage],
    imports: [ResolvedImport] = [],
    snapshot: ConfigurationSnapshot, preview: Bool, lockBytes: Data? = nil
  ) throws {
    guard
      !expanded.entries.contains(where: {
        if case .importConf = $0 { return true }
        return false
      })
    else {
      throw LockFailure.malformed(detail: "resolution requires expanded imports")
    }
    var seen: [PackageRequest: LockedPackage] = [:]
    for package in packages {
      guard seen[package.request] == nil else {
        throw LockFailure.malformed(detail: "duplicate package resolution")
      }
      seen[package.request] = package
    }
    for entry in expanded.entries {
      if case .package(let request) = entry, !request.url.isFileURL, seen[request] == nil {
        throw LockFailure.malformed(detail: "resolution is missing a package")
      }
    }
    let requests = Set(
      expanded.entries.compactMap {
        if case .package(let request) = $0, !request.url.isFileURL { return request }
        return nil
      })
    guard Set(seen.keys) == requests else {
      throw LockFailure.malformed(detail: "resolution contains unrelated packages")
    }
    var sourceVersions: [RepositoryKey: CommitID] = [:]
    for package in packages {
      guard case .git(let repository) = package.request.source else {
        throw LockFailure.malformed(detail: "local source in shared package lock")
      }
      if let prior = sourceVersions[repository.key], prior != package.commit {
        throw LockFailure.malformed(detail: "conflicting commits for one repository revision")
      }
      sourceVersions[repository.key] = package.commit
    }
    var expected: [ManifestEntry] = []
    var consumed = Set<ImportID>()
    for (index, entry) in declarations.entries.enumerated() {
      if case .importConf(let request) = entry {
        let id = ImportID(index: index, request: request)
        guard
          let imported = imports.first(where: {
            $0.id.index == id.index && $0.id.request == id.request
          }),
          Set(imported.resources.map(\.path)).count == imported.resources.count
        else {
          throw LockFailure.malformed(detail: "missing or conflicting import resolution")
        }
        consumed.insert(imported.id)
        expected += imported.packages.map(ManifestEntry.package)
      } else {
        expected.append(entry)
      }
    }
    guard expected == expanded.entries, consumed.count == imports.count else {
      throw LockFailure.malformed(
        detail: "expanded entries disagree with locked imports and declarations")
    }
    self.declarations = declarations
    self.expanded = expanded
    self.packages = packages
    self.imports = imports
    self.snapshot = snapshot
    self.preview = preview
    self.lockBytes = lockBytes
  }
}

// Only private wire records conform to Codable. No FilePath storage is serialized.
enum ResolutionCodec {
  static let magic = Data("PINEWIND2\0".utf8)
  struct Pair: Codable {
    let key: String
    let value: String
  }
  struct Request: Codable {
    let url: String
    let revision: String?
    let value: String?
    let recipe: String?
    let options: [Pair]
    let include: [String]?
    let exclude: [String]
    init(_ request: PackageRequest) {
      url = request.url.isFileURL ? "local" : request.url.absoluteString
      let r = request.revision ?? .defaultBranch
      switch r {
      case .defaultBranch:
        revision = "default"
        value = nil
      case .branch(let text):
        revision = "branch"
        value = text
      case .tag(let text):
        revision = "tag"
        value = text
      case .reference(let text):
        revision = "ref"
        value = text
      case .commit(let id):
        revision = "commit"
        value = id.string
      }
      recipe = request.recipe
      options = request.options.sorted { $0.key < $1.key }.map {
        Pair(key: $0.key, value: $0.value)
      }
      include = request.filter.include
      exclude = request.filter.exclude
    }
    func decode() throws(LockFailure) -> PackageRequest {
      guard let endpoint = URL(string: url), !endpoint.isFileURL, url != "local",
        Set(options.map(\.key)).count == options.count
      else {
        throw LockFailure.malformed(detail: "invalid locked package record")
      }
      let selection: GitRevision
      switch revision {
      case "default": selection = .defaultBranch
      case "branch": selection = .branch(try required())
      case "tag": selection = .tag(try required())
      case "ref": selection = .reference(try required())
      case "commit":
        do { selection = .commit(try CommitID(required())) } catch {
          throw LockFailure.malformed(detail: String(describing: error))
        }
      default:
        throw LockFailure.malformed(detail: "invalid locked revision selector")
      }
      do {
        return try PackageRequest(
          url: endpoint, revision: selection, recipe: recipe,
          options: Dictionary(uniqueKeysWithValues: options.map { ($0.key, $0.value) }),
          filter: FileFilter(include: include, exclude: exclude))
      } catch {
        throw LockFailure.malformed(detail: String(describing: error))
      }
    }
    func required() throws(LockFailure) -> String {
      guard let value else {
        throw LockFailure.malformed(detail: "locked revision value is missing")
      }
      return value
    }
  }
  struct Entry: Codable {
    let kind: String
    var request: Request? = nil
    var localIndex: Int? = nil
    var include: [String]? = nil
    var exclude: [String]? = nil
    var source: String? = nil
    var variables: [Pair]? = nil
    init(_ entry: ManifestEntry, index: Int) {
      switch entry {
      case .userFiles(let filter):
        kind = "self"
        include = filter.include
        exclude = filter.exclude
      case .package(let package):
        kind = package.url.isFileURL ? "local" : "package"
        request = Request(package)
        if package.url.isFileURL { localIndex = index }
      case .importConf(let imported):
        kind = "import"
        source = imported.source
        variables = imported.variables.sorted { $0.key < $1.key }.map {
          Pair(key: $0.key, value: $0.value)
        }
      }
    }
    func decode(shared: Manifest) throws(LockFailure) -> ManifestEntry {
      switch kind {
      case "self":
        let filter = FileFilter(include: include, exclude: exclude ?? [])
        do { try filter.validate() } catch {
          throw LockFailure.malformed(detail: String(describing: error))
        }
        return .userFiles(filter)
      case "package":
        guard let request else {
          throw LockFailure.malformed(detail: "locked package entry has no request")
        }
        return .package(try request.decode())
      case "local":
        guard let localIndex, shared.entries.indices.contains(localIndex),
          case .package(let request) = shared.entries[localIndex], request.url.isFileURL
        else {
          throw LockFailure.malformed(
            detail: "locked local entry does not match the shared declarations")
        }
        return .package(request)
      default:
        throw LockFailure.malformed(detail: "unexpanded or invalid lock entry")
      }
    }
  }
  struct Resource: Codable {
    let url: String
    let path: String
    let sha256: String
    init(_ pin: PinnedResource) {
      url = pin.url.absoluteString
      path = pin.path.string
      sha256 = pin.sha256
    }
    func decode() throws(LockFailure) -> PinnedResource {
      guard let url = URL(string: url) else {
        throw LockFailure.malformed(detail: "locked resource URL is invalid")
      }
      guard !path.contains("\0"), !path.contains("\\") else {
        throw LockFailure.malformed(detail: "locked resource path is not portable")
      }
      do {
        return try PinnedResource(url: url, path: RelativePath(FilePath(path)), sha256: sha256)
      } catch {
        throw LockFailure.malformed(detail: String(describing: error))
      }
    }
  }
  struct Package: Codable {
    let request: Request
    let commit: String
    let resources: [Resource]
  }
  struct Import: Codable {
    let index: Int
    let source: String
    let variables: [Pair]
    let packages: [Request]
    let resources: [Resource]
  }
  struct Payload: Codable {
    let version: Int
    let declarations: [Entry]
    let expanded: [Entry]
    let packages: [Package]
    let imports: [Import]
  }
  static func signature(_ manifest: Manifest) throws(Failure) -> Data {
    try signature(manifest.entries.enumerated().map { Entry($0.element, index: $0.offset) })
  }
  private static func signature(_ entries: [Entry]) throws(Failure) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    do { return try encoder.encode(entries) } catch {
      throw .defect(.wrapped(detail: String(describing: error), origin: Origin()))
    }
  }
  static func encode(_ resolution: Resolution) throws(Failure) -> Data {
    let entries = resolution.expanded.entries.enumerated().map { index, entry -> Entry in
      var record = Entry(entry, index: index)
      if case .package(let request) = entry, request.url.isFileURL {
        record.localIndex = resolution.declarations.entries.firstIndex(of: entry)
      }
      return record
    }
    let payload = Payload(
      version: 1,
      declarations: resolution.declarations.entries.enumerated().map {
        Entry($0.element, index: $0.offset)
      }, expanded: entries,
      packages: resolution.packages.map {
        Package(
          request: Request($0.request), commit: $0.commit.string,
          resources: $0.resources.map(Resource.init))
      },
      imports: resolution.imports.map {
        Import(
          index: $0.id.index, source: $0.id.request.source,
          variables: $0.id.request.variables.sorted { $0.key < $1.key }.map {
            Pair(key: $0.key, value: $0.value)
          }, packages: $0.packages.map(Request.init), resources: $0.resources.map(Resource.init))
      })
    do { return magic + (try PropertyListEncoder().encode(payload)) } catch {
      throw Failure.defect(.wrapped(detail: String(describing: error), origin: Origin()))
    }
  }
  static func reusable(_ bytes: Data) throws(LockFailure) -> (
    packages: [LockedPackage], imports: [ResolvedImport]
  ) {
    guard bytes.starts(with: magic) else {
      throw LockFailure.incompatible(detail: "unsupported lock")
    }
    let payload: Payload
    do {
      payload = try PropertyListDecoder().decode(Payload.self, from: bytes.dropFirst(magic.count))
    } catch {
      throw LockFailure.malformed(detail: String(describing: error))
    }
    guard payload.version == 1 else {
      throw LockFailure.incompatible(detail: "unsupported lock version")
    }
    let packages: [LockedPackage]
    do {
      packages = try payload.packages.map {
        try LockedPackage(
          request: $0.request.decode(), commit: CommitID($0.commit),
          resources: $0.resources.map { try $0.decode() })
      }
    } catch let failure as LockFailure {
      throw failure
    } catch {
      throw LockFailure.malformed(detail: String(describing: error))
    }
    guard Set(packages.map(\.request)).count == packages.count else {
      throw LockFailure.malformed(detail: "conflicting locked package records")
    }
    let imports: [ResolvedImport]
    do {
      imports = try payload.imports.map { record -> ResolvedImport in
        guard Set(record.variables.map(\.key)).count == record.variables.count else {
          throw LockFailure.malformed(detail: "duplicate locked variables")
        }
        return try ResolvedImport(
          id: ImportID(
            index: record.index,
            request: ConfImport(
              source: record.source,
              variables: Dictionary(
                uniqueKeysWithValues: record.variables.map { ($0.key, $0.value) })
            )),
          packages: record.packages.map { try $0.decode() },
          resources: record.resources.map { try $0.decode() })
      }
    } catch let failure as LockFailure {
      throw failure
    } catch {
      throw LockFailure.malformed(detail: String(describing: error))
    }
    return (packages, imports)
  }
  static func decode(_ bytes: Data, snapshot: ConfigurationSnapshot) throws
    -> Resolution
  {
    let lock: DocumentContext
    do {
      lock = try DocumentContext(path: snapshot.locations.configuration.lock.filePath)
    } catch { throw ErrorBoundary.normalize(error) }
    guard bytes.starts(with: magic) else {
      throw PinewindError.configuration(
        DocumentError(
          context: lock,
          failure: .lock(.incompatible(detail: "unrecognized lock format; run resolve to rebuild")))
      )
    }
    do {
      let payload = try PropertyListDecoder().decode(
        Payload.self, from: bytes.dropFirst(magic.count))
      guard payload.version == 1 else {
        throw LockFailure.incompatible(detail: "unsupported lock version")
      }
      let declarations = try snapshot.evaluate(.shared)
      guard try signature(payload.declarations) == signature(declarations) else {
        throw LockFailure.declarationChanged
      }
      let packages = try payload.packages.map {
        try LockedPackage(
          request: $0.request.decode(), commit: CommitID($0.commit),
          resources: $0.resources.map { try $0.decode() })
      }
      let imports = try payload.imports.map { record -> ResolvedImport in
        guard Set(record.variables.map(\.key)).count == record.variables.count else {
          throw LockFailure.malformed(detail: "duplicate locked import variables")
        }
        let request = try ConfImport(
          source: record.source,
          variables: Dictionary(uniqueKeysWithValues: record.variables.map { ($0.key, $0.value) }))
        guard declarations.entries.indices.contains(record.index),
          declarations.entries[record.index] == .importConf(request)
        else {
          throw LockFailure.malformed(detail: "locked import does not match the declarations")
        }
        return try ResolvedImport(
          id: ImportID(index: record.index, request: request),
          packages: record.packages.map { try $0.decode() },
          resources: record.resources.map { try $0.decode() })
      }
      guard Set(imports.map(\.id)).count == imports.count else {
        throw LockFailure.malformed(detail: "duplicate locked import")
      }
      return try Resolution(
        declarations: declarations,
        expanded: Manifest(entries: payload.expanded.map { try $0.decode(shared: declarations) }),
        packages: packages, imports: imports, snapshot: snapshot, preview: false, lockBytes: bytes)
    } catch let failure as LockFailure {
      throw PinewindError.configuration(DocumentError(context: lock, failure: .lock(failure)))
    } catch let pinned as PinewindError {
      throw pinned
    } catch let failure as Failure {
      if case .defect = failure { throw PinewindError.runtime(failure) }
      throw PinewindError.configuration(
        DocumentError(context: lock, failure: .lock(.malformed(detail: failure.description))))
    } catch let failure as DeclarationFailure {
      throw PinewindError.configuration(
        DocumentError(context: lock, failure: .lock(.malformed(detail: failure.description))))
    } catch let error as DecodingError {
      throw PinewindError.configuration(
        DocumentError(context: lock, failure: .lock(.malformed(detail: String(describing: error)))))
    } catch { throw ErrorBoundary.normalize(error) }
  }
}
