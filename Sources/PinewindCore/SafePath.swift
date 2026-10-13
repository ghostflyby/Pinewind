// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum SafePath {
  static func validate(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\"),
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw PinewindError("unsafe relative path '\(path)'") }
  }

  static func file(_ path: String, in root: URL) throws -> URL {
    try validate(path)
    let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
    let candidate = canonicalRoot.appendingPathComponent(path)
    let canonical = candidate.resolvingSymlinksInPath()
    guard canonical.path.hasPrefix(canonicalRoot.path + "/") else {
      throw PinewindError("path escapes its source root: \(path)")
    }
    return candidate
  }

  static func validateRoots(input: URL, output: URL, sources: [URL]) throws {
    let roots = [input] + sources
    let out = output.standardizedFileURL.resolvingSymlinksInPath().path
    for root in roots {
      let path = root.standardizedFileURL.resolvingSymlinksInPath().path
      guard path != out, !out.hasPrefix(path + "/"), !path.hasPrefix(out + "/") else {
        throw PinewindError("composition root must not overlap any input source")
      }
    }
  }

  static func files(in root: URL) throws -> [String] {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
    let values = try root.resourceValues(forKeys: [.isDirectoryKey])
    guard values.isDirectory == true else {
      throw PinewindError("source must be a directory", source: root.path)
    }
    var enumerationError: (any Error)?
    guard
      let iterator = fm.enumerator(
        at: root, includingPropertiesForKeys: keys,
        options: [],
        errorHandler: { _, error in
          enumerationError = error
          return false
        })
    else {
      throw PinewindError("cannot enumerate source", source: root.path)
    }
    var result: [String] = []
    let base = root.standardizedFileURL.path
    for case let file as URL in iterator {
      let values = try file.resourceValues(forKeys: Set(keys))
      if values.isSymbolicLink == true {
        throw PinewindError(
          "symbolic links are not supported in package sources", source: file.path)
      }
      if values.isDirectory == true && file.lastPathComponent == ".git" {
        iterator.skipDescendants()
        continue
      }
      if values.isRegularFile == true {
        let path = String(file.standardizedFileURL.path.dropFirst(base.count + 1))
        try validate(path)
        result.append(path)
      }
    }
    if let enumerationError { throw enumerationError }
    return result.sorted()
  }
}
