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

private struct BytesConfReader: ConfFileReader {
  let data: Data

  func read(_ path: RelativePath) async throws -> Data { data }
}

private struct FailingConfReader: ConfFileReader {
  func read(_ path: RelativePath) async throws -> Data {
    throw FileSystemFailure.notFound(FilePath(path.string))
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
    file: native(root.appendingPathComponent("list.conf")),
    resourceRoot: native(root), variables: variables,
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

  @Test func unquotedExpansionsSplitLikeTheShell() async throws {
    let list = try await evaluateConf(
      [
        "list.conf":
          #"package_list=(pre${v}post "${v}" ${v} $v "pre$v" pre${w}post "${w}")"# + "\n"
      ],
      variables: ["v": "a b", "w": " a "])
    #expect(
      list == ["prea", "bpost", "a b", "a", "b", "a", "b", "prea b", "pre", "a", "post", " a "])
  }

  @Test func defaultWordsUseShellQuoting() async throws {
    let list = try await evaluateConf([
      "list.conf":
        #"package_list=(${missing:-"a b"} ${missing:-a b} ${missing:-a\ b} "${missing:-a b}" ${missing:-''})"#
        + "\n"
    ])
    #expect(list == ["a b", "a", "b", "a b", "a b", ""])
  }

  @Test func emptyExpansionsFollowQuoting() async throws {
    let list = try await evaluateConf([
      "list.conf": #"package_list=(${missing} "${missing}" "" pre${missing}post)"# + "\n"
    ])
    #expect(list == ["", "", "prepost"])
  }

  @Test func quotedDefaultWordsKeepSingleQuotesAndBackslashes() async throws {
    let list = try await evaluateConf([
      "list.conf":
        ##"package_list=("${missing:-'a b'}" "${missing:-a\ b}" "${missing:-a\#b}" "${missing:-'}'}" "${missing:-}" "${missing:-""}")"##
        + "\n"
    ])
    #expect(list == ["'a b'", "a\\ b", "a\\#b", "'}'", "", ""])

    let escaped = try await evaluateConf([
      "list.conf":
        ##"package_list=("${missing:-'a\\b'}" "${missing:-'a\"b'}" "${missing:-'a\$HOME'}" "${missing:-'a\b'}")"##
        + "\n"
    ])
    #expect(escaped == ["'a\\b'", "'a\"b'", "'a$HOME'", "'a\\b'"])

    let nested = try await evaluateConf([
      "list.conf":
        ##"package_list=("${missing:-a"b\"c"d}" "${missing:-a"\$b"c}")"## + "\n"
    ])
    #expect(nested == ["ab\"cd", "a$bc"])
  }

  @Test func emptyQuotesKeepAQuotedNull() async throws {
    let list = try await evaluateConf([
      "list.conf":
        #"package_list=(${missing}"" ""${missing} ""${missing}"" ${missing}${missing}"")"# + "\n"
    ])
    #expect(list == ["", "", "", ""])
  }

  @Test func splittingUsesTabsAndNewlinesToo() async throws {
    let list = try await evaluateConf(
      ["list.conf": #"package_list=($v)"# + "\n"],
      variables: ["v": "a\tb\nc"])
    #expect(list == ["a", "b", "c"])
  }

  @Test func sourceRequiresExactlyOneExpandedPath() async throws {
    await #expect {
      try await evaluateConf(["list.conf": "source ${missing}\n"])
    } throws: { error in
      guard case .incident(let document) = error as? PinewindError else { return false }
      guard case .evaluationFailed(let detail) = document.underlyingError as? InterpreterFailure
      else { return false }
      return detail.contains("source requires exactly one non-empty path")
    }
    await #expect {
      try await evaluateConf(["list.conf": "source $paths\n"], variables: ["paths": "a b"])
    } throws: { error in
      guard case .incident(let document) = error as? PinewindError else { return false }
      guard case .evaluationFailed(let detail) = document.underlyingError as? InterpreterFailure
      else { return false }
      return detail.contains("source requires exactly one non-empty path")
    }
  }

  @Test func cyclicIncludesFailWithinResourceBudget() async throws {
    let limits = ImportLimits(timeout: .seconds(60), maximumSources: 8)
    await #expect {
      try await evaluateConf(["list.conf": "source /conf/list.conf\n"], limits: limits)
    } throws: { error in
      guard case .incident(let document) = error as? PinewindError else { return false }
      guard case .budgetExceeded(.sources) = document.underlyingError as? InterpreterFailure
      else { return false }
      return true
    }
  }

  @Test func entryReadFailuresAreAttributed() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinewind-conf-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    await #expect {
      try await PlumImporter().evaluate(
        file: native(root.appendingPathComponent("list.conf")),
        resourceRoot: native(root), variables: [:], reader: FailingConfReader())
    } throws: { error in
      guard case .incident(let document) = error as? PinewindError else { return false }
      guard case .evaluationFailed(let detail) = document.underlyingError as? InterpreterFailure
      else { return false }
      return detail.contains("/conf/list.conf")
    }
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
    #"package_list=("${missing:-$x}")"#,
    #"package_list=("${missing:-`x`}")"#,
    #"package_list=("${missing:-'a}")"#,
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

  @Test func missingSourceIsAnAttributedEvaluationFailure() async throws {
    await #expect {
      try await evaluateConf(["list.conf": "source \"${root_dir}/missing.conf\"\n"])
    } throws: { error in
      guard case .incident(let document) = error as? PinewindError else { return false }
      guard case .evaluationFailed(let detail) = document.underlyingError as? InterpreterFailure
      else { return false }
      return detail.contains("missing.conf")
    }
  }

  @Test func syntaxErrorsCarryPositions() async throws {
    await #expect {
      try await evaluateConf(["list.conf": "# comment\n\nif true\n"])
    } throws: { error in
      guard case .incident(let document) = error as? PinewindError else { return false }
      guard case .evaluationFailed(let detail) = document.underlyingError as? InterpreterFailure
      else { return false }
      return detail.contains("/conf/list.conf:3:1:")
    }
  }

  @Test func dotSourceTrailingCommentsAndContinuations() async throws {
    let list = try await evaluateConf([
      "list.conf": #"""
      package_list+=(a#b)
      . "${root_dir}/more.conf" # trailing comment
      package_list+=\
      (c)
      source "${root_dir}/sub/../more.conf"

      """#,
      "more.conf": "package_list+=(d)\n",
    ])
    #expect(list == ["a#b", "d", "c", "d"])
  }

  @Test func invalidUTF8IsRejected() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinewind-conf-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    await #expect {
      try await PlumImporter().evaluate(
        file: native(root.appendingPathComponent("list.conf")),
        resourceRoot: native(root), variables: [:],
        reader: BytesConfReader(data: Data([0xFF, 0xFE])))
    } throws: { error in
      guard case .incident(let document) = error as? PinewindError else { return false }
      guard case .evaluationFailed(let detail) = document.underlyingError as? InterpreterFailure
      else { return false }
      return detail.contains("not valid UTF-8")
    }
  }

  @Test(arguments: [
    #"source "https://conf.test/x.conf""#,
    #"source "a\b.conf""#,
  ])
  func unsafeSourcePathsAreForbidden(_ line: String) async throws {
    await #expect {
      try await evaluateConf(["list.conf": line + "\n"])
    } throws: { error in
      guard case .incident(let document) = error as? PinewindError else { return false }
      guard case .forbiddenOperation = document.underlyingError as? InterpreterFailure else {
        return false
      }
      return true
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

    let totalLimits = ImportLimits(
      timeout: .seconds(5), maximumSources: 64,
      maximumFileBytes: 1_048_576, maximumTotalBytes: 40)
    await #expect {
      try await evaluateConf(
        [
          "list.conf": "source \"${root_dir}/a.conf\"\n",
          "a.conf": "package_list+=(b)\n",
        ], limits: totalLimits)
    } throws: { error in
      guard case .incident(let document) = error as? PinewindError else { return false }
      guard case .budgetExceeded(.totalBytes) = document.underlyingError as? InterpreterFailure
      else { return false }
      return true
    }

    // A failed read is reported before the source budget is charged.
    let orderingLimits = ImportLimits(
      timeout: .seconds(5), maximumSources: 1,
      maximumFileBytes: 1_048_576, maximumTotalBytes: 4_194_304)
    await #expect {
      try await evaluateConf(
        ["list.conf": "source \"${root_dir}/missing.conf\"\n"], limits: orderingLimits)
    } throws: { error in
      guard case .incident(let document) = error as? PinewindError else { return false }
      guard case .evaluationFailed(let detail) = document.underlyingError as? InterpreterFailure
      else { return false }
      return detail.contains("missing.conf")
    }
  }
}
