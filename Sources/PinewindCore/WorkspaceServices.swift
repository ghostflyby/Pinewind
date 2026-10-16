// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

public protocol RepositoryProvider: Sendable {
  func resolve(_ request: RepositoryRequest) async throws -> SourceIdentity
  func prepareSource(_ identity: SourceIdentity, cacheRoot: FilePath) async throws -> SourceSnapshot
}
public protocol ResourceDownloader: Sendable {
  func download(_ url: URL, to destination: FilePath) async throws
}
public struct SourceSnapshot: Sendable {
  public let identity: SourceIdentity
  public let directory: FilePath
  public init(identity: SourceIdentity, directory: FilePath, relativeTo: FilePath? = nil) throws {
    self.identity = identity
    self.directory = try NativePath.absolute(directory, relativeTo: relativeTo)
  }
}
public struct WorkspaceServices: Sendable {
  public let repositories: any RepositoryProvider
  public let resources: any ResourceDownloader
  public init(repositories: any RepositoryProvider, resources: any ResourceDownloader) {
    self.repositories = repositories
    self.resources = resources
  }
  public static var live: Self {
    Self(repositories: GitKitRepositoryProvider(), resources: HTTPSResourceDownloader())
  }
}
