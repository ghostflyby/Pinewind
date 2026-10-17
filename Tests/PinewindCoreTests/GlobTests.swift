// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SystemPackage
import Testing

@testable import PinewindCore

@Suite("Pinewind path globs")
struct GlobTests {
  @Test(arguments: [
    ("*.yaml", "a.yaml", true),
    ("*.yaml", "a/b.yaml", false),
    ("**/*.yaml", "a.yaml", true),
    ("**/*.yaml", "a/b/c.yaml", true),
    ("a/**/b.yaml", "a/b.yaml", true),
    ("a/**/b.yaml", "a/c/d/b.yaml", true),
    ("a/**", "a/file.yaml", true),
    ("a/**", "a", false),
    ("?.yaml", "汉.yaml", true),
    ("?.yaml", "ab.yaml", false),
    ("a/[0-9].yaml", "a/7.yaml", true),
    ("a/[0-9].yaml", "a/77.yaml", false),
    ("a/[!0-9].yaml", "a/x.yaml", true),
    ("a/[^0-9].yaml", "a/x.yaml", true),
    ("a/[!x]b", "a//b", false),
    ("[[:digit:]].yaml", "3.yaml", true),
    ("*.yaml", ".hidden.yaml", true),
    ("**/*.yaml", ".hidden/file.yaml", true),
    ("*.yaml", "a.yaml/", true),
    ("A.yaml", "a.yaml", false),
    ("*.{yaml,txt}", "a.yaml", false),
    ("*.{yaml,txt}", "a.{yaml,txt}", true),
    ("@(foo|bar).yaml", "foo.yaml", false),
  ])
  func preservesPathMatchingContract(pattern: String, path: String, expected: Bool) throws {
    #expect(try Glob.matches(pattern, path: RelativePath(FilePath(path))) == expected)
  }

  @Test(arguments: [
    "", "/foo", "../foo", "a/../*", "a\\*.yaml", "bad\0pattern", "[", "[]", "[z-a]",
  ])
  func rejectsUnsafeOrMalformedPatterns(_ pattern: String) {
    #expect(throws: DeclarationFailure.self) { try Glob.compile(pattern) }
  }

  @Test func includeAndExcludeUseTheSameMatcher() throws {
    let filter = FileFilter(include: ["**/*.yaml"], exclude: ["**/*.custom.yaml"])
    #expect(try filter.accepts(RelativePath("default.yaml")))
    #expect(try filter.accepts(RelativePath("schemas/.hidden.yaml")))
    #expect(try !filter.accepts(RelativePath("schemas/test.custom.yaml")))
    #expect(try !filter.accepts(RelativePath("words.txt")))
    #expect(throws: PinewindError.self) {
      try ManifestDocument.parse("version: 1\norder: [{self: {include: ['[']}}]").evaluate()
    }
  }
}
