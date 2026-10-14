// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public struct PinnedResource: Hashable, Codable, Sendable {
  public let url: URL
  public let path: String
  public let sha256: String

  public init(url: URL, path: String, sha256: String) throws {
    try SafePath.validate(path)
    guard url.scheme == "https", sha256.count == 64,
      sha256.allSatisfy({ $0.isASCII && $0.isHexDigit })
    else {
      throw PinewindError("resource requires an HTTPS URL and a complete SHA-256 checksum")
    }
    self.url = url
    self.path = path
    self.sha256 = sha256.lowercased()
  }
}

/// Acquisition backends supply already prepared source views. No cache path is
/// persisted into the portable lock; working trees remain live local inputs.
public struct PreparedPackage: Sendable {
  public let request: PackageRequest
  public let directory: URL
  public let commit: String?
  public let resources: [PinnedResource]

  public init(
    request: PackageRequest, directory: URL, commit: String? = nil,
    resources: [PinnedResource] = []
  ) throws {
    guard directory.isFileURL else {
      throw PinewindError("prepared sources must be local directories")
    }
    if !request.url.isFileURL {
      guard let commit else { throw PinewindError("remote prepared source requires a commit") }
      _ = try SourceIdentity(url: request.url, commit: commit)
      if let requested = request.commit, requested != commit.lowercased() {
        throw PinewindError("prepared commit does not match the requested commit")
      }
    }
    self.request = request
    self.directory = directory
    self.commit = request.url.isFileURL ? nil : commit?.lowercased()
    self.resources = resources
  }
}

public struct CompositionOperation: Equatable, Sendable {
  public enum Action: Equatable, Sendable {
    /// A frozen file owned by the plan, valid for the lifetime of that plan.
    case write(URL)
    case patch(rx: String, body: String)
  }
  public let entryIndex: Int
  public let source: URL
  public let action: Action
}

public struct CompositionPlan: Sendable {
  public let files: [String: [CompositionOperation]]
  public let sourceRoots: [URL]
  public var paths: [String] { files.keys.sorted() }
  let snapshot: CompositionSnapshot
}

public struct CompositionPlanner: Sendable {
  public let snapshotRoot: URL

  public init(snapshotRoot: URL = FileManager.default.temporaryDirectory) {
    self.snapshotRoot = snapshotRoot
  }

  public func plan(
    _ manifest: Manifest, inputRoot: URL,
    packages: [PreparedPackage] = []
  ) throws -> CompositionPlan {
    var files: [String: [CompositionOperation]] = [:]
    var roots: [URL] = [inputRoot]
    let snapshot = try PlanningSnapshot(root: snapshotRoot)
    var available = packages
    for entry in manifest.entries {
      if case .package(let request) = entry, request.url.isFileURL,
        !available.contains(where: { $0.request == request })
      {
        available.append(try PreparedPackage(request: request, directory: request.url))
      }
    }
    try SafePath.validateRoots(
      input: inputRoot, output: snapshot.storage.directory, sources: available.map(\.directory))
    func add(_ path: String, source: URL, index: Int, action: CompositionOperation.Action) throws {
      try SafePath.validate(path)
      // Preserve all contributions, including overwritten files, for uninstall/reorder.
      files[path, default: []].append(
        CompositionOperation(entryIndex: index, source: source, action: action))
    }
    for (index, entry) in manifest.entries.enumerated() {
      switch entry {
      case .userFiles(let filter):
        for path in try snapshot.files(in: inputRoot) where !Self.isMetadata(path) {
          if try filter.accepts(path) {
            let file = try SafePath.file(path, in: inputRoot)
            try add(path, source: file, index: index, action: .write(snapshot.capture(file)))
          }
        }
      case .importConf:
        throw PinewindError("expand conf imports before planning composition")
      case .package(let request):
        guard let prepared = available.first(where: { $0.request == request }) else {
          throw PinewindError(
            "package has no prepared snapshot", source: request.url.absoluteString)
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
            throw PinewindError(
              "download resource has not been pinned and prepared",
              source: download.url.absoluteString)
          }
          let file = try snapshot.capture(SafePath.file(download.path, in: prepared.directory))
          let hash = try SnapshotFiles.sha256(file)
          guard hash == pinned.sha256 else {
            throw PinewindError(
              "download resource checksum mismatch", source: download.url.absoluteString)
          }
        }
        var selected: [(String, URL)] = []
        if let patterns = recipe?.patterns {
          for pattern in patterns {
            if pattern.hasPrefix("../") {
              let segments = pattern.split(separator: "/", maxSplits: 2).map(String.init)
              guard segments.count == 3, segments[0] == ".." else {
                throw PinewindError("cross-package pattern must be ../<package>/<pattern>")
              }
              let candidates = try available.filter {
                let sibling = try SourceIdentity.normalize($0.request.url)
                return sibling.deletingLastPathComponent()
                  == source.deletingLastPathComponent()
                  && Self.compatibilityName(sibling)
                    == segments[1]
              }
              let versions = try Dictionary(grouping: candidates) {
                SourceVersion(url: try SourceIdentity.normalize($0.request.url), commit: $0.commit)
              }
              guard versions.count == 1, let sibling = versions.values.first?.first else {
                throw PinewindError("cross-package source is missing or ambiguous: \(segments[1])")
              }
              roots.append(sibling.directory)
              let glob = try Glob.compile(segments[2])
              let matched = try snapshot.files(in: sibling.directory).filter { glob.match($0) }
              guard !matched.isEmpty else {
                throw PinewindError("install_files pattern matched no files: \(pattern)")
              }
              for path in matched {
                selected.append((path, try SafePath.file(path, in: sibling.directory)))
              }
            } else {
              let glob = try Glob.compile(pattern)
              let matched = candidates.filter { glob.match($0) }
              guard !matched.isEmpty else {
                throw PinewindError("install_files pattern matched no files: \(pattern)")
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
        var installed = Set<String>()
        for (path, file) in selected where installed.insert(path).inserted {
          if try request.filter.accepts(path) {
            try add(path, source: file, index: index, action: .write(snapshot.capture(file)))
          }
        }
        for patch in recipe?.patches ?? [] {
          if try request.filter.accepts(patch.target) {
            try add(
              patch.target, source: request.url, index: index,
              action: .patch(rx: patch.rx, body: patch.body))
          }
        }
      }
    }
    // Reject file/directory conflicts before publishing any candidate.
    let paths = Set(files.keys)
    for path in paths {
      var parent = (path as NSString).deletingLastPathComponent
      while !parent.isEmpty {
        guard !paths.contains(parent) else {
          throw PinewindError("file/directory output conflict at \(parent)")
        }
        parent = (parent as NSString).deletingLastPathComponent
      }
    }
    return CompositionPlan(files: files, sourceRoots: roots, snapshot: snapshot.storage)
  }

  private static func compatibilityName(_ url: URL) -> String {
    let name = url.lastPathComponent
    return name.hasPrefix("rime-") ? String(name.dropFirst(5)) : name
  }

  static func isMetadata(_ path: String) -> Bool {
    let components = path.split(separator: "/").map(String.init)
    return ["pinewind.yaml", "pinewind.local.yaml", "pinewind.lock"].contains(path)
      || components.contains(".DS_Store") || components.contains { $0.contains(".local.") }
  }

  static func isDefaultFile(_ path: String) -> Bool {
    let parts = path.split(separator: "/")
    if parts.count == 2, parts[0] == "opencc" {
      return ["json", "ocd", "ocd2", "txt"].contains((path as NSString).pathExtension)
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
  let commit: String?
}

/// Freeze each referenced file and directory membership once per synchronous plan.
/// Copies may clone on APFS but never hard-link mutable inputs. Local edits affect
/// the next plan; the current plan owns disk snapshots instead of retaining bytes.
private final class PlanningSnapshot {
  let storage: CompositionSnapshot
  private var directoryFiles: [URL: [String]] = [:]
  private var captured: [URL: URL] = [:]

  init(root: URL) throws { storage = try CompositionSnapshot(root: root) }

  func files(in root: URL) throws -> [String] {
    let key = root.standardizedFileURL.resolvingSymlinksInPath()
    if let cached = directoryFiles[key] { return cached }
    let files = try SafePath.files(in: root)
    directoryFiles[key] = files
    return files
  }

  func read(_ file: URL) throws -> Data {
    try Data(contentsOf: capture(file))
  }

  func capture(_ file: URL) throws -> URL {
    let key = file.standardizedFileURL.resolvingSymlinksInPath()
    if let cached = captured[key] { return cached }
    let destination = storage.directory.appendingPathComponent(String(captured.count))
    try FileManager.default.copyItem(at: key, to: destination)
    captured[key] = destination
    return destination
  }
}
