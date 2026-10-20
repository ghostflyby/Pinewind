// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0

import Crypto
import Foundation
import SystemPackage

/// One regular file in an exported output tree. Paths and hashes describe the
/// snapshot's actual bytes, including retained unmanaged files in managed mode.
public struct PublishedOutputFile: Sendable, Hashable, Codable {
  public let path: RelativePath
  public let sha256: String
  public let byteCount: UInt64
}

/// A detached, caller-owned directory. Pinewind does not delete it on release.
/// A later publication cannot alter its bytes. `revision` is a deterministic
/// SHA-256 identity of the complete tree's relative names, types and file bytes;
/// it is not the dependency lock's revision or a monotonically increasing ID.
/// Relative names encode with `/` on every platform; native root directories and
/// path separators do not participate in the identity.
public struct PublishedOutputSnapshot: Sendable {
  public let sourceDirectory: FilePath
  public let directory: FilePath
  public let revision: String
  public let files: [PublishedOutputFile]
}

/// Unlike source planning, published output must not silently skip .git trees,
/// symbolic links, special files, or empty directories.
struct PublishedTree {
  let directories: [RelativePath]
  let files: [RelativePath]

  static func inspect(_ root: FilePath) throws -> PublishedTree {
    let fm = FileManager.default
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    let values = try root.foundationURL.resourceValues(forKeys: keys)
    guard values.isSymbolicLink != true else {
      throw FileSystemFailure.symbolicLinkNotAllowed(root)
    }
    guard values.isDirectory == true else { throw FileSystemFailure.notADirectory(root) }
    var enumerationError: (any Error)?
    guard
      let enumerator = fm.enumerator(
        at: try root.foundationURL, includingPropertiesForKeys: Array(keys), options: [],
        errorHandler: { _, error in
          enumerationError = error
          return false
        })
    else { throw FileSystemFailure.enumerationFailed(root) }
    var directories: [RelativePath] = []
    var files: [RelativePath] = []
    let base = try NativePath.from(root.foundationURL.standardizedFileURL)
    for case let url as URL in enumerator {
      try Cancellation.check()
      let file = try NativePath.from(url)
      let values = try url.resourceValues(forKeys: keys)
      guard values.isSymbolicLink != true else {
        throw FileSystemFailure.symbolicLinkNotAllowed(file)
      }
      let native = try NativePath.from(url.standardizedFileURL)
      guard native.starts(with: base) else {
        throw FileSystemFailure.escapesRoot(path: native, root: base)
      }
      let path = try RelativePath(
        FilePath(root: nil, native.components.dropFirst(base.components.count)))
      if values.isDirectory == true {
        directories.append(path)
      } else if values.isRegularFile == true {
        files.append(path)
      } else {
        throw FileSystemFailure.notRegularFile(file)
      }
    }
    if let enumerationError {
      throw FileOperationFailure(operation: .enumerate, paths: [root], error: enumerationError)
    }
    return PublishedTree(directories: directories.sorted(), files: files.sorted())
  }

  func manifest(at root: FilePath) throws -> [PublishedOutputFile] {
    try files.map { path in
      try Cancellation.check()
      let file = try SafePath.file(path, in: root)
      return PublishedOutputFile(
        path: path, sha256: try SnapshotFiles.sha256(file),
        byteCount: try SnapshotFiles.byteCount(file))
    }
  }

  func revision(files: [PublishedOutputFile]) throws -> String {
    // A versioned, deterministic encoding avoids ambiguous path concatenations.
    struct Identity: Encodable {
      let version: Int
      let directories: [RelativePath]
      let files: [PublishedOutputFile]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try SHA256.hash(
      data: encoder.encode(Identity(version: 1, directories: directories, files: files))
    )
    .map { String(format: "%02x", $0) }.joined()
  }
}

/// Rime-owned locations are never configuration sources. Root names are
/// case-insensitive; user databases and their backups are protected at any depth.
public enum RuntimeOutputProtection {
  public static func isProtected(_ path: RelativePath) -> Bool {
    let parts = path.filePath.components.map { $0.string.lowercased() }
    guard let first = parts.first else { return true }
    return ["build", "sync", "trash", "log", "installation.yaml", "user.yaml"].contains(first)
      || parts.contains { $0.hasSuffix(".userdb") || $0.contains(".userdb.") }
  }

  static func validate(_ paths: [RelativePath]) throws {
    for path in paths where isProtected(path) {
      throw StateFailure.runtimeOutputPath(path)
    }
  }
}

struct PublishedOutputExporter {
  let stateRoot: FilePath
  let cacheRoot: FilePath

  func snapshot(output requested: FilePath, to destination: FilePath) throws
    -> PublishedOutputSnapshot
  {
    let output = try PublicationLock.output(requested)
    let destination = try SafePath.canonical(destination)
    try SafePath.validateRoots(input: output, output: destination, sources: [stateRoot, cacheRoot])
    return try NativeLock.withLock(PublicationLock.file(for: output)) {
      let publisher = ManagedFilePublisher(stateRoot: stateRoot, cacheRoot: cacheRoot)
      let sourceRoots = try publisher.requireCommitted(output: output)
      for root in sourceRoots where try SafePath.overlaps(root, destination) {
        throw FileSystemFailure.overlappingPaths(destination, root)
      }
      #if os(Windows)
        let source = try WindowsDirectoryPublisher.resolvedPath(output)
      #else
        let source = try SafePath.canonical(output)
      #endif
      guard try !SafePath.overlaps(source, destination) else {
        throw FileSystemFailure.overlappingPaths(source, destination)
      }
      let fm = FileManager.default
      guard !fm.fileExists(atPath: destination.string),
        (try? fm.attributesOfItem(atPath: destination.string)) == nil
      else { throw StateFailure.snapshotDestinationExists(destination) }
      let tree = try PublishedTree.inspect(source)
      try RuntimeOutputProtection.validate(tree.files + tree.directories)
      let files = try tree.manifest(at: source)
      let parent = destination.removingLastComponent()
      try fm.createDirectory(at: parent, withIntermediateDirectories: true)
      let candidate = parent.appending(".pinewind-export-" + UUID().uuidString)
      defer { try? fm.removeItem(at: candidate) }
      try Cancellation.check()
      try fm.copyItem(at: source, to: candidate)
      let copied = try PublishedTree.inspect(candidate)
      guard copied.directories == tree.directories, copied.files == tree.files,
        try copied.manifest(at: candidate) == files,
        try PublishedTree.inspect(source).directories == tree.directories,
        try PublishedTree.inspect(source).manifest(at: source) == files
      else { throw StateFailure.externallyModified }
      _ = try publisher.requireCommitted(output: output)
      try Cancellation.check()
      let revision = try tree.revision(files: files)
      // moveItem never overwrites an existing destination. Failure leaves the
      // previous caller data intact; only our temporary directory is removed.
      try fm.moveItem(at: candidate, to: destination)
      return PublishedOutputSnapshot(
        sourceDirectory: output, directory: destination,
        revision: revision, files: files)
    }
  }
}
