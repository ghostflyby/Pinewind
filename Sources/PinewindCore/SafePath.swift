// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

enum SafePath {
  static func validate(_ path: String) throws {
    _ = try RelativePath(path)
  }

  static func file(_ path: String, in root: FilePath) throws -> FilePath {
    try validate(path)
    let canonicalRoot = FilePath(try canonical(root))
    let candidate = canonicalRoot.appendingPathComponent(path)
    guard try canonical(candidate).hasPrefix(prefix(canonical(root))) else {
      throw PinewindError("path escapes its source root: \(path)")
    }
    return candidate
  }

  static func validateOutputRoot(_ output: FilePath) throws {
    guard !output.lastPathComponent.isEmpty, output.lastPathComponent != "/" else {
      throw PinewindError("composition output must not be a filesystem root")
    }
    #if os(Windows)
      guard !output.lastPathComponent.hasSuffix(":") else {
        throw PinewindError("composition output must not be a filesystem root")
      }
    #endif
  }

  static func validateRoots(input: FilePath, output: FilePath, sources: [FilePath]) throws {
    try validateOutputRoot(output)
    let roots = [input] + sources
    let out = try canonical(output)
    for root in roots {
      let path = try canonical(root)
      guard path != out, !out.hasPrefix(prefix(path)), !path.hasPrefix(prefix(out)) else {
        throw PinewindError("composition root must not overlap any input source")
      }
    }
  }

  static func overlaps(_ first: FilePath, _ second: FilePath) throws -> Bool {
    let a = try canonical(first)
    let b = try canonical(second)
    return a == b || a.hasPrefix(prefix(b)) || b.hasPrefix(prefix(a))
  }

  private static func prefix(_ path: String) -> String {
    path.hasSuffix("/") ? path : path + "/"
  }

  static func canonical(_ url: FilePath) throws -> String {
    #if os(Windows)
      return try WindowsDirectoryPublisher.canonicalPath(url)
    #else
      try NativePath.requireAbsolute(url)
      var ancestor = url
      var missing: [String] = []
      while !FileManager.default.fileExists(atPath: ancestor.string) {
        let parent = ancestor.removingLastComponent()
        guard parent != ancestor, let component = ancestor.lastComponent else {
          throw PinewindError(.invalidPath, "cannot resolve filesystem path", source: url.string)
        }
        missing.append(component.string)
        ancestor = parent
      }
      var resolved = try NativePath.from(
        ancestor.foundationURL.resolvingSymlinksInPath().standardizedFileURL)
      for component in missing.reversed() { resolved.append(component) }
      let normalized = resolved.lexicallyNormalized()
      if normalized != resolved { return try canonical(normalized) }
      return resolved.string
    #endif
  }

  static func files(in root: FilePath) throws -> [String] {
    #if os(Windows)
      let root = try WindowsDirectoryPublisher.resolvedURL(root)
    #endif
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
    try NativePath.requireAbsolute(root)
    let values = try root.foundationURL.resourceValues(forKeys: [.isDirectoryKey])
    guard values.isDirectory == true else {
      throw PinewindError("source must be a directory", source: root.path)
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
      throw PinewindError("cannot enumerate source", source: root.path)
    }
    var result: [String] = []
    let base = try NativePath.from(root.foundationURL.standardizedFileURL)
    for case let file as URL in iterator {
      try Cancellation.check()
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
        let native = try NativePath.from(file.standardizedFileURL)
        let path = native.components.dropFirst(base.components.count).map(\.string).joined(
          separator: "/")
        try validate(path)
        result.append(path)
      }
    }
    if let enumerationError { throw enumerationError }
    return result.sorted()
  }
}
