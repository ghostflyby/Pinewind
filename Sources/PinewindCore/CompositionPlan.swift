// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

public struct PinnedResource: Hashable, Sendable {
  public let url: URL
  public let path: RelativePath
  public let sha256: String

  init(url: URL, path: RelativePath, sha256: String) throws {
    guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
      throw DeclarationFailure.unsupportedSourceURL(url)
    }
    guard sha256.count == 64, sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
      throw DeclarationFailure.invalidChecksum(sha256)
    }
    self.url = url
    self.path = path
    self.sha256 = sha256.lowercased()
  }
}

/// Acquisition backends supply already prepared source views. No cache path is
/// persisted into the portable lock; working trees remain live local inputs.
struct PreparedPackage: Sendable {
  let request: PackageRequest
  let directory: FilePath
  let commit: CommitID?
  let resources: [PinnedResource]

  init(
    request: PackageRequest, directory: FilePath, commit: CommitID? = nil,
    resources: [PinnedResource] = []
  ) throws {
    if case .git(let repository) = request.source {
      guard let commit else { throw DeclarationFailure.preparedCommitMissing }
      if case .commit(let requested) = repository.revision, requested != commit {
        throw DeclarationFailure.preparedCommitMismatch(
          requested: requested.string, prepared: commit.string)
      }
    }
    self.request = request
    self.directory = directory
    self.commit = request.url.isFileURL ? nil : commit
    self.resources = resources
  }
}

struct CompositionOperation: Equatable, Sendable {
  enum Action: Equatable, Sendable {
    /// A frozen file owned by the plan, valid for the lifetime of that plan.
    case write(FilePath)
    case patch(rx: String, body: String)
  }
  let entryIndex: Int
  let source: URL
  let action: Action
}

public struct CompositionContribution: Equatable, Sendable {
  public enum Kind: Sendable { case write, patch }
  public let entryIndex: Int
  public let source: URL
  public let kind: Kind
}

public struct CompositionPlan: Sendable {
  let files: [RelativePath: [CompositionOperation]]
  var sourceRoots: [FilePath]
  let snapshot: CompositionSnapshot
  var binding: InputBinding? = nil
  var origins: [Int: URL] = [:]
  public var paths: [RelativePath] { files.keys.sorted() }
  public func contributions(for path: RelativePath) -> [CompositionContribution] {
    (files[path] ?? []).map { operation in
      CompositionContribution(
        entryIndex: operation.entryIndex, source: origins[operation.entryIndex] ?? operation.source,
        kind: {
          if case .write = operation.action { return .write }
          return .patch
        }())
    }
  }
}

struct CompositionPlanner: Sendable {
  let snapshotRoot: FilePath

  func plan(
    _ manifest: Manifest, inputRoot: FilePath,
    packages: [PreparedPackage] = [], excluding: [FilePath] = []
  ) throws -> CompositionPlan {
    try Cancellation.check()
    var files: [RelativePath: [CompositionOperation]] = [:]
    var roots: [FilePath] = [inputRoot]
    let snapshot = try PlanningSnapshot(root: snapshotRoot)
    var available = packages
    for entry in manifest.entries {
      if case .package(let request) = entry, request.url.isFileURL,
        !available.contains(where: { $0.request == request })
      {
        available.append(
          try PreparedPackage(request: request, directory: NativePath.from(request.url)))
      }
    }
    try SafePath.validateRoots(
      input: inputRoot, output: snapshot.storage.directory, sources: available.map(\.directory))
    func add(_ path: RelativePath, source: URL, index: Int, action: CompositionOperation.Action) {
      // Preserve all contributions, including overwritten files, for uninstall/reorder.
      files[path, default: []].append(
        CompositionOperation(entryIndex: index, source: source, action: action))
    }
    let excluded = try Set(excluding.map { try SafePath.canonical($0) })
    for (index, entry) in manifest.entries.enumerated() {
      try Cancellation.check()
      switch entry {
      case .userFiles(let filter):
        for path in try snapshot.files(in: inputRoot) where !Self.isMetadata(path) {
          if try filter.accepts(path) {
            let file = try SafePath.file(path, in: inputRoot)
            if try excluded.contains(SafePath.canonical(file)) { continue }
            try add(
              path, source: file.foundationURL, index: index,
              action: .write(snapshot.capture(file))
            )
          }
        }
      case .importConf:
        throw DeclarationFailure.importNotExpanded
      case .package(let request):
        let matches = available.filter { $0.request == request }
        guard Set(matches.map { $0.commit }).count <= 1,
          Set(matches.map { $0.directory }).count <= 1
        else {
          throw DeclarationFailure.versionConflict
        }
        guard let prepared = matches.first else {
          throw DeclarationFailure.missingPreparedSnapshot
        }
        roots.append(prepared.directory)
        let source = try SourceIdentity.normalize(request.url)
        let candidates = try snapshot.files(in: prepared.directory)
        let recipe = try Recipe.load(
          request: request, directory: prepared.directory, read: snapshot.read)
        for download in recipe?.downloads ?? [] {
          guard
            let pinned = prepared.resources.first(where: {
              $0.url == download.url && $0.path == download.path
            })
          else {
            throw DeclarationFailure.unpreparedResource
          }
          let file = try snapshot.capture(SafePath.file(download.path, in: prepared.directory))
          let hash = try SnapshotFiles.sha256(file)
          guard hash == pinned.sha256 else {
            throw CacheFailure.checksumMismatch(
              url: download.url, expected: pinned.sha256, actual: hash)
          }
        }
        var selected: [(RelativePath, FilePath)] = []
        if let patterns = recipe?.patterns {
          for pattern in patterns {
            let selection = try Recipe.sourcePattern(pattern)
            if let name = selection.package {
              let candidates = try available.filter {
                let sibling = try SourceIdentity.normalize($0.request.url)
                return sibling.deletingLastPathComponent()
                  == source.deletingLastPathComponent()
                  && Self.compatibilityName(sibling)
                    == name
              }
              let versions = try Dictionary(grouping: candidates) {
                SourceVersion(url: try SourceIdentity.normalize($0.request.url), commit: $0.commit)
              }
              guard versions.count == 1, let sibling = versions.values.first?.first else {
                throw DeclarationFailure.crossPackageSourceUnresolved(name)
              }
              roots.append(sibling.directory)
              let glob = try Glob.compile(selection.glob)
              let matched = try snapshot.files(in: sibling.directory).filter {
                glob.match($0.string)
              }
              guard !matched.isEmpty else {
                throw DeclarationFailure.unmatchedPattern(pattern)
              }
              for path in matched {
                selected.append((path, try SafePath.file(path, in: sibling.directory)))
              }
            } else {
              let glob = try Glob.compile(selection.glob)
              let matched = candidates.filter { glob.match($0.string) }
              guard !matched.isEmpty else {
                throw DeclarationFailure.unmatchedPattern(pattern)
              }
              for path in matched {
                selected.append((path, try SafePath.file(path, in: prepared.directory)))
              }
            }
          }
        } else {
          for path in candidates where Self.isDefaultFile(path) {
            selected.append((path, try SafePath.file(path, in: prepared.directory)))
          }
        }
        var installed = Set<RelativePath>()
        for (path, file) in selected where installed.insert(path).inserted {
          if try request.filter.accepts(path) {
            try add(
              path, source: file.foundationURL, index: index,
              action: .write(snapshot.capture(file))
            )
          }
        }
        for patch in recipe?.patches ?? [] {
          if try request.filter.accepts(patch.target) {
            add(
              patch.target, source: request.url, index: index,
              action: .patch(rx: patch.rx, body: patch.body))
          }
        }
      }
    }
    // Reject file/directory conflicts before publishing any candidate.
    let paths = Set(files.keys.map(\.filePath))
    for path in paths {
      var parent = path.removingLastComponent()
      while !parent.isEmpty {
        guard !paths.contains(parent) else {
          throw DeclarationFailure.outputConflict
        }
        parent.removeLastComponent()
      }
    }
    return CompositionPlan(files: files, sourceRoots: roots, snapshot: snapshot.storage)
  }

  private static func compatibilityName(_ url: URL) -> String {
    let name = url.lastPathComponent
    return name.hasPrefix("rime-") ? String(name.dropFirst(5)) : name
  }

  static func isMetadata(_ path: RelativePath) -> Bool {
    let components = path.filePath.components.map(\.string)
    return components.contains(".DS_Store") || components.contains { $0.contains(".local.") }
  }

  static func isDefaultFile(_ relative: RelativePath) -> Bool {
    let path = relative.string
    let parts = relative.filePath.components
    if parts.count == 2, parts.first?.string == "opencc" {
      return ["json", "ocd", "ocd2", "txt"].contains(relative.filePath.extension ?? "")
    }
    guard parts.count == 1 else { return false }
    if path.hasSuffix(".yaml") {
      return !path.hasSuffix(".custom.yaml") && !path.hasSuffix(".recipe.yaml")
        && path != "recipe.yaml"
    }
    return path.hasSuffix(".txt") || path.hasSuffix(".gram")
  }
}

private struct SourceVersion: Hashable {
  let url: URL
  let commit: CommitID?
}

/// Freeze each referenced file and directory membership once per synchronous plan.
/// Copies may clone on APFS but never hard-link mutable inputs. Local edits affect
/// the next plan; the current plan owns disk snapshots instead of retaining bytes.
private final class PlanningSnapshot {
  let storage: CompositionSnapshot
  private var directoryFiles: [FilePath: [RelativePath]] = [:]
  private var captured: [FilePath: FilePath] = [:]

  init(root: FilePath) throws { storage = try CompositionSnapshot(root: root) }

  func files(in root: FilePath) throws -> [RelativePath] {
    let key = try SafePath.canonical(root)
    if let cached = directoryFiles[key] { return cached }
    let files = try SafePath.files(in: root)
    directoryFiles[key] = files
    return files
  }

  func read(_ file: FilePath) throws -> Data {
    try Data(contentsOf: capture(file))
  }

  func capture(_ file: FilePath) throws -> FilePath {
    let key = try SafePath.canonical(file)
    if let cached = captured[key] { return cached }
    let destination = storage.directory.appending(String(captured.count))
    try FileManager.default.copyItem(at: key, to: destination)
    captured[key] = destination
    return destination
  }
}
