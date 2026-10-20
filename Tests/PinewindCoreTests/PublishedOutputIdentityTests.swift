// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0

import Foundation
import SystemPackage
import Testing

@testable import PinewindCore

@Suite("Published output identity")
struct PublishedOutputIdentityTests {
  @Test func nestedNativePathsHavePortableEncodingAndAFixedRevision() throws {
    let directory = try RelativePath(FilePath("nested"))
    // appending uses the native separator, including a backslash on Windows.
    let path = try RelativePath(FilePath("nested").appending("schema.yaml"))
    let encoded = try JSONEncoder().encode(path)
    #expect(try JSONDecoder().decode(String.self, from: encoded) == "nested/schema.yaml")
    let file = PublishedOutputFile(
      path: path,
      sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
      byteCount: 5)
    let tree = PublishedTree(directories: [directory], files: [path])
    // Golden v1 identity for the nested file containing UTF-8 "hello".
    #expect(
      try tree.revision(files: [file])
        == "91c808f95fa244bd3d5167de414071da73373e773521fc0f72eeac80fcaa044c")
  }
}
