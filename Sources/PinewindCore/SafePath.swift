// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

enum SafePath {
  static func file(_ path: RelativePath, in root: FilePath) throws(FileSystemFailure) -> FilePath {
    let rootIdentity = try canonical(root)
    #if os(Windows)
      let canonicalRoot = try WindowsDirectoryPublisher.resolvedPath(root)
    #else
      let canonicalRoot = rootIdentity
    #endif
    let candidate = canonicalRoot.appending(path.filePath.components)
    guard try canonical(candidate).starts(with: rootIdentity) else {
      throw FileSystemFailure.escapesRoot(path: candidate, root: rootIdentity)
    }
    return candidate
  }

  static func validateOutputRoot(_ output: FilePath) throws(FileSystemFailure) {
    guard output.lastComponent != nil else {
      throw FileSystemFailure.isFilesystemRoot(output)
    }
  }

  static func validateRoots(input: FilePath, output: FilePath, sources: [FilePath])
    throws(FileSystemFailure)
  {
    try validateOutputRoot(output)
    let roots = [input] + sources
    let out = try canonical(output)
    for root in roots {
      let path = try canonical(root)
      guard !out.starts(with: path), !path.starts(with: out) else {
        throw FileSystemFailure.overlappingPaths(out, path)
      }
    }
  }

  static func overlaps(_ first: FilePath, _ second: FilePath) throws(FileSystemFailure) -> Bool {
    let a = try canonical(first)
    let b = try canonical(second)
    return a.starts(with: b) || b.starts(with: a)
  }

  static func canonical(_ url: FilePath) throws(FileSystemFailure) -> FilePath {
    #if os(Windows)
      return try WindowsDirectoryPublisher.canonicalPath(url)
    #else
      var ancestor = url
      var missing: [FilePath.Component] = []
      while !FileManager.default.fileExists(atPath: ancestor.string) {
        let parent = ancestor.removingLastComponent()
        guard parent != ancestor, let component = ancestor.lastComponent else {
          throw FileSystemFailure.unresolvable(url)
        }
        missing.append(component)
        ancestor = parent
      }
      var resolved = try NativePath.from(
        ancestor.foundationURL.resolvingSymlinksInPath().standardizedFileURL)
      for component in missing.reversed() { resolved.append(component) }
      let normalized = resolved.lexicallyNormalized()
      if normalized != resolved { return try canonical(normalized) }
      return resolved
    #endif
  }

  static func files(in root: FilePath) throws -> [RelativePath] {
    #if os(Windows)
      let root = try WindowsDirectoryPublisher.resolvedPath(root)
    #endif
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
    let values = try root.foundationURL.resourceValues(forKeys: [.isDirectoryKey])
    guard values.isDirectory == true else {
      throw FileSystemFailure.notADirectory(root)
    }
    var enumerationError: (any Error)?
    guard
      let iterator = fm.enumerator(
        at: try root.foundationURL, includingPropertiesForKeys: keys,
        options: [],
        errorHandler: { _, error in
          enumerationError = error
          return false
        })
    else {
      throw FileSystemFailure.enumerationFailed(root)
    }
    var result: [RelativePath] = []
    let base = try NativePath.from(root.foundationURL.standardizedFileURL)
    for case let file as URL in iterator {
      try Cancellation.check()
      let values = try file.resourceValues(forKeys: Set(keys))
      if values.isSymbolicLink == true {
        throw FileSystemFailure.symbolicLinkNotAllowed(FilePath(file.path))
      }
      if values.isDirectory == true && file.lastPathComponent == ".git" {
        iterator.skipDescendants()
        continue
      }
      if values.isRegularFile == true {
        let native = try NativePath.from(file.standardizedFileURL)
        let path = FilePath(root: nil, native.components.dropFirst(base.components.count))
        result.append(try RelativePath(path))
      }
    }
    if let enumerationError { throw enumerationError }
    return result.sorted()
  }
}
