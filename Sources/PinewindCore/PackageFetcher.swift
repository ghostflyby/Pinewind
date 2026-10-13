// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The backend prepares an immutable complete snapshot; archive transport and git
/// object deltas remain backend details. M1 consumers can provide prepared views.
public protocol PackageFetcher: Sendable {
  func resolveDefaultBranch(url: URL) async throws -> String
  func resolveCommit(url: URL, ref: String) async throws -> String
  func prepareSource(url: URL, commit: String, cacheRoot: URL) async throws -> PackageSourceSnapshot
  func downloadFile(url: URL) async throws -> Data
}

public struct PackageSourceSnapshot: Sendable {
  public let identity: SourceIdentity
  public let directory: URL

  public init(identity: SourceIdentity, directory: URL) throws {
    guard directory.isFileURL else {
      throw PinewindError("source snapshots must be local directories")
    }
    self.identity = identity
    self.directory = directory
  }
}
