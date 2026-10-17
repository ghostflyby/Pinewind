// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Crypto
import Foundation
import SystemPackage

#if os(Windows)
  import WinSDK
#else
  import CPinewindPlatform
#endif

/// Publishes configurations into an existing directory without enumerating or
/// replacing unrelated runtime data. Intent survives cancellation/process exit.
struct ManagedFilePublisher {
  let stateRoot: FilePath
  let cacheRoot: FilePath

  private struct Entry: Codable {
    let path: String
    let sha256: String
  }
  private struct Record: Codable {
    let version: Int
    let target: String
    let files: [Entry]
  }

  func compose(_ plan: CompositionPlan, inputRoot: FilePath, outputRoot: FilePath) throws
    -> CompositionResult
  {
    let output = try SafePath.canonical(outputRoot)
    try SafePath.validateRoots(
      input: inputRoot, output: output, sources: plan.sourceRoots + [plan.snapshot.directory])
    let staging = try CompositionSnapshot(root: cacheRoot.appending("publication"))
    defer { withExtendedLifetime(staging) {} }
    let rendered = staging.directory.appending("rendered")
    let result = try Composer().compose(plan, inputRoot: inputRoot, outputRoot: rendered)
    let files = try result.paths.map { path in
      Entry(path: path.string, sha256: try SnapshotFiles.sha256(SafePath.file(path, in: rendered)))
    }
    let key = SHA256.hash(data: Data(output.string.utf8)).map { String(format: "%02x", $0) }
      .joined()
    let record = stateRoot.appending("publications/" + key + ".plist")
    let pending = stateRoot.appending("publications/" + key + ".pending.plist")
    let lock = output.removingLastComponent().appending(
      "." + (output.lastComponent?.string ?? "") + ".pinewind-publication.lock")
    return try NativeLock.withLock(lock) {
      var previous: [RelativePath: Set<String>] = [:]
      for entry in try read(record, target: output) + read(pending, target: output) {
        previous[try RelativePath(FilePath(entry.path)), default: []].insert(entry.sha256)
      }
      let current = Set(result.paths)
      var changed: [RelativePath] = []
      var reused: [RelativePath] = []
      var removed: [RelativePath] = []
      var preserved: [RelativePath] = []
      var expected: [RelativePath: String] = [:]
      for path in Set(previous.keys).union(current).sorted() {
        try validateParents(path, in: output)
        let destination = try SafePath.file(path, in: output)
        if let hash = try hashIfPresent(destination) { expected[path] = hash }
        if current.contains(path) {
          let source = try SafePath.file(path, in: rendered)
          if try expected[path] == SnapshotFiles.sha256(source) {
            reused.append(path)
          } else {
            changed.append(path)
          }
        } else if let hash = expected[path] {
          if previous[path]?.contains(hash) == true {
            removed.append(path)
          } else {
            preserved.append(path)
          }
        }
      }
      try plan.binding?.validate()
      try Cancellation.check()
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      let intent =
        previous.flatMap { path, hashes in hashes.map { Entry(path: path.string, sha256: $0) } }
        + files
      try write(Record(version: 1, target: output.string, files: intent), to: pending)
      for path in changed {
        try Cancellation.check()
        let destination = try SafePath.file(path, in: output)
        guard try hashIfPresent(destination) == expected[path] else {
          throw PinewindError.runtime(.state(.externallyModified))
        }
        try replace(try SafePath.file(path, in: rendered), at: destination)
      }
      for path in removed {
        try Cancellation.check()
        let destination = try SafePath.file(path, in: output)
        guard try hashIfPresent(destination) == expected[path] else {
          throw PinewindError.runtime(.state(.externallyModified))
        }
        try removeFile(destination)
      }
      try write(Record(version: 1, target: output.string, files: files), to: record)
      try removeFile(pending)
      return CompositionResult(
        directory: output, paths: result.paths, changedPaths: changed, removedPaths: removed,
        reusedPaths: reused, preservedPaths: preserved)
    }
  }

  private func read(_ path: FilePath, target: FilePath) throws -> [Entry] {
    guard FileManager.default.fileExists(atPath: path.string) else { return [] }
    let record: Record
    do {
      record = try PropertyListDecoder().decode(Record.self, from: Data(contentsOf: path))
    } catch is DecodingError { throw StateFailure.invalidPublicationRecord(path) }
    guard record.version == 1, record.target == target.string else {
      throw StateFailure.invalidPublicationRecord(path)
    }
    for entry in record.files {
      guard let relative = try? RelativePath(FilePath(entry.path)), relative.string == entry.path,
        entry.sha256.count == 64, entry.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit })
      else {
        throw StateFailure.invalidPublicationRecord(path)
      }
    }
    return record.files
  }

  private func write(_ record: Record, to path: FilePath) throws {
    try FileManager.default.createDirectory(
      at: path.removingLastComponent(), withIntermediateDirectories: true)
    try FileIO.perform(.write, paths: [path]) {
      try PropertyListEncoder().encode(record).write(to: path, options: .atomic)
    }
  }

  private func hashIfPresent(_ path: FilePath) throws -> String? {
    guard FileManager.default.fileExists(atPath: path.string) else { return nil }
    let values = try FileIO.perform(.inspect, paths: [path]) {
      try path.foundationURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    }
    guard values.isSymbolicLink != true else {
      throw FileSystemFailure.symbolicLinkNotAllowed(path)
    }
    guard values.isRegularFile == true else { throw FileSystemFailure.notRegularFile(path) }
    return try SnapshotFiles.sha256(path)
  }

  private func validateParents(_ path: RelativePath, in root: FilePath) throws {
    var parent = root
    for component in path.filePath.components.dropLast() {
      parent.append(component)
      guard FileManager.default.fileExists(atPath: parent.string) else { continue }
      let values = try FileIO.perform(.inspect, paths: [parent]) {
        try parent.foundationURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      }
      guard values.isSymbolicLink != true else {
        throw FileSystemFailure.symbolicLinkNotAllowed(parent)
      }
      guard values.isDirectory == true else { throw FileSystemFailure.notADirectory(parent) }
    }
  }

  private func replace(_ source: FilePath, at destination: FilePath) throws {
    let parent = destination.removingLastComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let temporary = parent.appending(".pinewind-" + UUID().uuidString + ".tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.copyItem(at: source, to: temporary)
    try FileIO.perform(.move, paths: [temporary, destination]) {
      #if os(Windows)
        let success = temporary.withPlatformString { source in
          destination.withPlatformString { target in
            MoveFileExW(source, target, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
          }
        }
        guard success else {
          throw NSError(domain: "NSWin32ErrorDomain", code: Int(GetLastError()))
        }
      #else
        let status = temporary.withPlatformString { source in
          destination.withPlatformString { target in pinewind_replace_file(source, target) }
        }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
      #endif
    }
  }

  private func removeFile(_ path: FilePath) throws {
    try FileIO.perform(.remove, paths: [path]) {
      #if os(Windows)
        guard path.withPlatformString({ DeleteFileW($0) }) else {
          throw NSError(domain: "NSWin32ErrorDomain", code: Int(GetLastError()))
        }
      #else
        let status = path.withPlatformString { pinewind_remove_file($0) }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
      #endif
    }
  }
}
