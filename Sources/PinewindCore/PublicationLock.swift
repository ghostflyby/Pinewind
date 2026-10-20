// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0

import SystemPackage

/// All publishers and snapshot readers lock the normalized public directory entry,
/// never an inode or (on Windows) the replaceable generation behind its junction.
enum PublicationLock {
  static func output(_ requested: FilePath) throws -> FilePath {
    #if os(Windows)
      return try FilePath(WindowsDirectoryPublisher.publicationPath(requested).string.lowercased())
    #else
      return try SafePath.canonical(requested)
    #endif
  }

  static func file(for output: FilePath) -> FilePath {
    output.removingLastComponent().appending(
      "." + (output.lastComponent?.string ?? "") + ".pinewind-publication.lock")
  }
}
