// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Crypto
import Foundation

/// Retained by all copies of a plan. The planner finishes capturing files before
/// exposing the plan; consumers only read them. Last-owner release removes them.
final class CompositionSnapshot: Sendable {
  let directory: URL

  init(root: URL) throws {
    guard root.isFileURL else { throw PinewindError("snapshot root must be a file URL") }
    directory = root.appendingPathComponent(".pinewind-snapshot-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  deinit { try? FileManager.default.removeItem(at: directory) }
}

enum SnapshotFiles {
  private static let chunkSize = 65_536

  static func sha256(_ file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hash = SHA256()
    while let bytes = try handle.read(upToCount: chunkSize), !bytes.isEmpty {
      hash.update(data: bytes)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func sameContents(_ first: URL, _ second: URL) throws -> Bool {
    let left = try FileHandle(forReadingFrom: first)
    defer { try? left.close() }
    let right = try FileHandle(forReadingFrom: second)
    defer { try? right.close() }
    guard try left.seekToEnd() == right.seekToEnd() else { return false }
    try left.seek(toOffset: 0)
    try right.seek(toOffset: 0)
    while true {
      let a = try left.read(upToCount: chunkSize) ?? Data()
      let b = try right.read(upToCount: chunkSize) ?? Data()
      guard a == b else { return false }
      if a.isEmpty { return true }
    }
  }
}
