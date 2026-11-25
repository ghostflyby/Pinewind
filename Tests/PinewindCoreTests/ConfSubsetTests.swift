// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage
import Testing

@testable import PinewindCore

private struct MemoryConfReader: ConfFileReader {
  let files: [String: String]

  func read(_ path: RelativePath) async throws -> Data {
    guard let text = files[path.string] else {
      throw FileSystemFailure.notFound(FilePath(path.string))
    }
    return Data(text.utf8)
  }
}

private func evaluateConf(
  _ files: [String: String], variables: [String: String] = [:],
  limits: ImportLimits = ImportLimits()
) async throws -> [String] {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("pinewind-conf-" + UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  return try await PlumImporter(limits: limits).evaluate(
    file: FilePath(root.appendingPathComponent("list.conf").path),
    resourceRoot: FilePath(root.path), variables: variables,
    reader: MemoryConfReader(files: files))
}

@Suite("Pinewind package-list conf subset")
struct ConfSubsetTests {
  @Test func arraysAppendExpansionsAndComments() async throws {
    let list = try await evaluateConf([
      "list.conf": """
      #!/usr/bin/env bash
      package_list=(one "two" ${root_dir}/x)
      package_list+=(three) # trailing comment
      package_list+=(
        # leading comment
        four
      )

      """
    ])
    #expect(list == ["one", "two", "/conf/x", "three", "four"])
  }

  @Test func sourceResolvesRootDirAndRepeats() async throws {
    let list = try await evaluateConf([
      "list.conf": """
      package_list=()
      source "${root_dir:-.}"/more.conf
      source "${root_dir:-.}"/more.conf

      """,
      "more.conf": "package_list+=(essay)\n",
    ])
    #expect(list == ["essay", "essay"])
  }

  @Test func variableDefaultsAndEmptyValues() async throws {
    let withValue = try await evaluateConf(
      ["list.conf": #"package_list=("${branch:-trad}" "$branch")"# + "\n"],
      variables: ["branch": "dev"])
    #expect(withValue == ["dev", "dev"])

    let withDefault = try await evaluateConf(
      ["list.conf": #"package_list=("${branch:-trad}" "$branch")"# + "\n"])
    #expect(withDefault == ["trad", ""])
  }

  @Test func crlfAndBOMAreAccepted() async throws {
    let list = try await evaluateConf([
      "list.conf": "\u{FEFF}package_list=(a)\r\npackage_list+=(b)\r\n"
    ])
    #expect(list == ["a", "b"])
  }

  @Test(arguments: [
    "if true; then package_list=(a); fi",
    "package_list=($(echo a))",
    "package_list=(a | b)",
    "package_list[0]=a",
    "package_list=a",
    "source 'x'",
    "echo hi",
    "package_list=(`echo a`)",
  ])
  func unsupportedSyntaxFails(_ text: String) async throws {
    await #expect {
      try await evaluateConf(["list.conf": text + "\n"])
    } throws: { error in
      guard case .incident(let document) = error as? PinewindError else { return false }
      return document.underlyingError is InterpreterFailure
    }
  }

  @Test func sourceOutsideRootIsForbidden() async throws {
    await #expect {
      try await evaluateConf(["list.conf": "source /etc/passwd\n"])
    } throws: { error in
      guard case .incident(let document) = error as? PinewindError else { return false }
      guard case .forbiddenOperation(let path) = document.underlyingError as? InterpreterFailure
      else { return false }
      return path == "/etc/passwd"
    }
  }

  @Test func missingSourcePropagatesFileSystemFailure() async throws {
    await #expect(throws: FileSystemFailure.self) {
      try await evaluateConf(["list.conf": "source \"${root_dir}/missing.conf\"\n"])
    }
  }

  @Test func sourceCountAndByteBudgetsAreEnforced() async throws {
    let limits = ImportLimits(
      timeout: .seconds(5), maximumSources: 2,
      maximumFileBytes: 1_048_576, maximumTotalBytes: 4_194_304)
    await #expect {
      try await evaluateConf(
        [
          "list.conf": "source \"${root_dir}/a.conf\"\n",
          "a.conf": "source \"${root_dir}/b.conf\"\n",
          "b.conf": "package_list=(b)\n",
        ], limits: limits)
    } throws: { error in
      guard case .incident(let document) = error as? PinewindError else { return false }
      guard case .budgetExceeded(.sources) = document.underlyingError as? InterpreterFailure
      else { return false }
      return true
    }

    let byteLimits = ImportLimits(
      timeout: .seconds(5), maximumSources: 64,
      maximumFileBytes: 8, maximumTotalBytes: 4_194_304)
    await #expect {
      try await evaluateConf(["list.conf": "package_list=(a)\n"], limits: byteLimits)
    } throws: { error in
      guard case .incident(let document) = error as? PinewindError else { return false }
      guard case .budgetExceeded(.fileBytes) = document.underlyingError as? InterpreterFailure
      else { return false }
      return true
    }
  }
}
