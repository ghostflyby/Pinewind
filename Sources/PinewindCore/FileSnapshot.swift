// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Crypto
import Foundation
import SystemPackage

/// Retained by all copies of a plan. The planner finishes capturing files before
/// exposing the plan; consumers only read them. Last-owner release removes them.
final class CompositionSnapshot: Sendable {
  let directory: FilePath

  init(root: FilePath) throws {
    directory = root.appending(".pinewind-snapshot-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  deinit { try? FileManager.default.removeItem(at: directory) }
}

enum SnapshotFiles {
  private static let chunkSize = 65_536

  static func byteCount(_ file: FilePath) throws(FileSystemFailure) -> UInt64 {
    let descriptor: FileDescriptor
    do { descriptor = try FileDescriptor.open(file, .readOnly) } catch {
      throw FileSystemFailure.unreadable(path: file, detail: String(describing: error))
    }
    do {
      return try descriptor.closeAfter { UInt64(try descriptor.seek(offset: 0, from: .end)) }
    } catch {
      throw FileSystemFailure.unreadable(path: file, detail: String(describing: error))
    }
  }

  static func sha256(_ file: FilePath) throws(FileSystemFailure) -> String {
    let descriptor: FileDescriptor
    do { descriptor = try FileDescriptor.open(file, .readOnly) } catch {
      throw FileSystemFailure.unreadable(path: file, detail: String(describing: error))
    }
    do {
      return try descriptor.closeAfter {
        var hash = SHA256()
        var buffer = Data(count: chunkSize)
        while true {
          let count = try readChunk(descriptor, into: &buffer)
          if count == 0 { break }
          buffer.withUnsafeBytes { bytes in
            hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[..<count]))
          }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
      }
    } catch {
      throw FileSystemFailure.unreadable(path: file, detail: String(describing: error))
    }
  }

  static func sameContents(_ first: FilePath, _ second: FilePath) throws -> Bool {
    let left = try FileDescriptor.open(first, .readOnly)
    return try left.closeAfter {
      let right = try FileDescriptor.open(second, .readOnly)
      return try right.closeAfter {
        guard try left.seek(offset: 0, from: .end) == right.seek(offset: 0, from: .end) else {
          return false
        }
        _ = try left.seek(offset: 0, from: .start)
        _ = try right.seek(offset: 0, from: .start)
        var a = Data(count: chunkSize)
        var b = Data(count: chunkSize)
        while true {
          let leftCount = try readChunk(left, into: &a)
          let rightCount = try readChunk(right, into: &b)
          guard leftCount == rightCount, a.prefix(leftCount) == b.prefix(rightCount) else {
            return false
          }
          if leftCount == 0 { return true }
        }
      }
    }
  }

  // read() may return fewer bytes than requested without reaching EOF. Fill a
  // chunk before comparing so different short-read boundaries do not imply a change.
  private static func readChunk(_ descriptor: FileDescriptor, into buffer: inout Data) throws
    -> Int
  {
    try buffer.withUnsafeMutableBytes { bytes in
      var count = 0
      while count < bytes.count {
        try Cancellation.check()
        let read = try descriptor.read(
          into: UnsafeMutableRawBufferPointer(rebasing: bytes[count...]))
        if read == 0 { break }
        count += read
      }
      return count
    }
  }
}
