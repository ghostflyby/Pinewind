// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

/// Core's captured source layout is shared by preparation and offline inspection.
enum SourceCache {
  static func directory(_ identity: SourceIdentity, cacheRoot: FilePath) throws -> FilePath {
    let key = GitKitRepositoryProvider.cacheKey(try SourceIdentity.normalize(identity.url))
    return cacheRoot.appending("sources/" + key + "/" + identity.commit.string)
  }
  static func marker(_ directory: FilePath) -> FilePath {
    directory.removingLastComponent().appending(
      (directory.lastComponent?.string ?? "") + ".complete")
  }
  static func contents(_ identity: SourceIdentity) throws -> Data {
    Data(
      (try SourceIdentity.normalize(identity.url).absoluteString + "\n" + identity.commit.string)
        .utf8)
  }
  static func cached(_ identity: SourceIdentity, cacheRoot: FilePath) throws -> SourceSnapshot? {
    let target = try directory(identity, cacheRoot: cacheRoot)
    guard FileManager.default.fileExists(atPath: target.string),
      try ConfigurationStore.read(marker(target).foundationURL) == contents(identity)
    else { return nil }
    return try SourceSnapshot(identity: identity, directory: target)
  }
}
