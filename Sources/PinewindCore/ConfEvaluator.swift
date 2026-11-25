// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

/// Evaluates the package-list conf subset against one environment.
struct ConfEvaluator: Sendable {
  let reader: any ConfFileReader
  let limits: ImportLimits
  let variables: [String: String]

  func run(entry: RelativePath) async throws -> [String] {
    let state = State(variables: variables)
    try await evaluate(entry, state: state)
    return state.packageList
  }

  /// Owned by the single task running this evaluation; the evaluator never
  /// shares it between tasks.
  private final class State: @unchecked Sendable {
    var variables: [String: String]
    var packageList: [String] = []
    var sources = 0
    var bytes = 0

    init(variables: [String: String]) {
      var variables = variables
      variables["root_dir"] = ConfVirtualPath.root
      self.variables = variables
    }
  }

  private func evaluate(_ path: RelativePath, state: State) async throws {
    state.sources += 1
    guard state.sources <= limits.maximumSources else {
      throw InterpreterFailure.budgetExceeded(.sources)
    }
    let data = try await reader.read(path)
    guard data.count <= limits.maximumFileBytes else {
      throw InterpreterFailure.budgetExceeded(.fileBytes)
    }
    state.bytes += data.count
    guard state.bytes <= limits.maximumTotalBytes else {
      throw InterpreterFailure.budgetExceeded(.totalBytes)
    }

    let virtualPath = ConfVirtualPath.string(path)
    guard var text = String(data: data, encoding: .utf8) else {
      throw InterpreterFailure.evaluationFailed(detail: "\(virtualPath): not valid UTF-8")
    }
    if text.hasPrefix("\u{FEFF}") {
      text.removeFirst()
    }
    // CRLF is a single grapheme cluster, so test scalars rather than `contains("\r")`.
    if text.unicodeScalars.contains("\r") {
      text = text.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    }

    let program = try ConfParser.parse(text, virtualPath: virtualPath)
    for statement in program.statements {
      switch statement.kind {
      case .assign(let words):
        state.packageList = words.map { expand($0, in: state) }
      case .append(let words):
        state.packageList.append(contentsOf: words.map { expand($0, in: state) })
      case .source(let word):
        let target = try ConfVirtualPath.relative(expand(word, in: state))
        try await evaluate(target, state: state)
      }
    }
  }

  private func expand(_ word: ConfWord, in state: State) -> String {
    var result = ""
    for segment in word.segments {
      switch segment {
      case .literal(let text):
        result += text
      case .expansion(let name, let defaultValue):
        if let value = state.variables[name], !value.isEmpty {
          result += value
        } else if let defaultValue {
          result += defaultValue
        }
      }
    }
    return result
  }
}
