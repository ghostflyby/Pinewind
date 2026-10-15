// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

struct ResourceStore: Sendable {
  let root: FilePath
  let downloader: any ResourceDownloader
  func path(_ pin: PinnedResource) -> FilePath { root.appending("resources/" + pin.sha256) }
  func pin(_ url: URL, target: RelativePath) async throws -> PinnedResource {
    let candidate = root.appending("downloads/" + UUID().uuidString)
    try await BlockingIO.run {
      try FileManager.default.createDirectory(
        at: candidate.removingLastComponent(), withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: candidate) }
    try await downloader.download(url, to: candidate)
    let hash = try await BlockingIO.run { try SnapshotFiles.sha256(candidate) }
    let pin = try PinnedResource(url: url, path: target, sha256: hash)
    try await BlockingIO.run {
      try NativeLock.withLock(root.appending("locks/resource-" + hash + ".lock")) {
        let destination = path(pin)
        try FileManager.default.createDirectory(
          at: destination.removingLastComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.string) {
          guard try SnapshotFiles.sha256(destination) == hash else {
            try FileManager.default.removeItem(at: destination)
            try Cancellation.check()
            try FileManager.default.moveItem(at: candidate, to: destination)
            return
          }
        } else {
          try Cancellation.check()
          try FileManager.default.moveItem(at: candidate, to: destination)
        }
      }
    }
    return pin
  }
  func ensure(_ pin: PinnedResource, network: Bool) async throws {
    let cached = path(pin)
    if FileManager.default.fileExists(atPath: cached.string),
      try await BlockingIO.run({ try SnapshotFiles.sha256(cached) }) == pin.sha256
    {
      return
    }
    guard network else {
      throw PinewindError(
        .contentMissing, "locked resource is absent from cache", source: pin.url.absoluteString)
    }
    let actual = try await self.pin(pin.url, target: pin.path)
    guard actual.sha256 == pin.sha256 else {
      throw PinewindError(
        .checksumMismatch, "locked resource checksum mismatch", source: pin.url.absoluteString)
    }
  }
}
