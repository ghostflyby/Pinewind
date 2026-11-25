// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

/// Reads a conf file through the `/conf` virtual root.
protocol ConfFileReader: Sendable {
  func read(_ path: RelativePath) async throws -> Data
}

enum ConfVirtualPath {
  static let root = "/conf"

  static func string(_ path: RelativePath) -> String {
    root + "/" + path.string
  }

  /// Resolves an expanded source path against `/conf`. Relative paths are
  /// relative to `/conf`, matching the old working directory.
  static func relative(_ text: String) throws(InterpreterFailure) -> RelativePath {
    guard !text.isEmpty, !text.contains("\0"), !text.contains("\\") else {
      throw InterpreterFailure.forbiddenOperation(path: text)
    }
    let path = FilePath(text)
    let absolute: FilePath
    if path.root != nil {
      absolute = path.lexicallyNormalized()
    } else {
      absolute = FilePath(root).appending(path.components).lexicallyNormalized()
    }
    guard absolute.root == FilePath("/").root,
      absolute.components.first?.string == "conf",
      absolute.components.count > 1
    else {
      throw InterpreterFailure.forbiddenOperation(path: text)
    }
    do {
      return try RelativePath(FilePath(root: nil, absolute.components.dropFirst()))
    } catch {
      throw InterpreterFailure.forbiddenOperation(path: text)
    }
  }
}

struct DirectConfFileReader: ConfFileReader {
  let root: FilePath

  func read(_ path: RelativePath) async throws -> Data {
    let file = try SafePath.file(path, in: root)
    return try await readConfFile(file)
  }
}

struct CapturedConfFileReader: ConfFileReader {
  let capture: any ConfResourceCapture
  let directory: FilePath

  func read(_ path: RelativePath) async throws -> Data {
    try await capture.ensure(path)
    let file = try SafePath.file(path, in: directory)
    return try await readConfFile(file)
  }
}

private func readConfFile(_ file: FilePath) async throws -> Data {
  try await BlockingIO.run {
    do {
      return try Data(contentsOf: file.foundationURL)
    } catch let failure as FileSystemFailure {
      throw failure
    } catch {
      throw FileSystemFailure.unreadable(path: file, detail: String(describing: error))
    }
  }
}
