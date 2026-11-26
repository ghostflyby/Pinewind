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
    let virtualPath = ConfVirtualPath.string(path)
    let data: Data
    do {
      data = try await reader.read(path)
    } catch is CancellationError {
      throw CancellationError()
    } catch let failure as FileSystemFailure {
      throw InterpreterFailure.evaluationFailed(detail: "\(virtualPath): \(failure)")
    } catch let failure as any FileOperationErrorProtocol {
      throw InterpreterFailure.evaluationFailed(detail: "\(virtualPath): \(failure)")
    }
    // Charge only after a successful read, matching the old source builtin.
    state.sources += 1
    guard state.sources <= limits.maximumSources else {
      throw InterpreterFailure.budgetExceeded(.sources)
    }
    guard data.count <= limits.maximumFileBytes else {
      throw InterpreterFailure.budgetExceeded(.fileBytes)
    }
    state.bytes += data.count
    guard state.bytes <= limits.maximumTotalBytes else {
      throw InterpreterFailure.budgetExceeded(.totalBytes)
    }

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
        state.packageList = words.flatMap { expandWord($0, in: state) }
      case .append(let words):
        state.packageList.append(contentsOf: words.flatMap { expandWord($0, in: state) })
      case .source(let word):
        let fields = expandWord(word, in: state)
        guard fields.count == 1, let target = fields.first, !target.isEmpty else {
          throw InterpreterFailure.evaluationFailed(
            detail:
              "\(virtualPath):\(word.position.line):\(word.position.column): source requires exactly one non-empty path"
          )
        }
        try await evaluate(try ConfVirtualPath.relative(target), state: state)
      }
    }
  }

  /// Expands one word into the fields the shell would produce. Unquoted
  /// expansions are split on space, tab and newline; quoted expansions and
  /// quoted/escaped default text are not.
  private func expandWord(_ word: ConfWord, in state: State) -> [String] {
    var fields: [String] = []
    var current = ""
    var hasField = false

    func flush() {
      guard hasField else { return }
      fields.append(current)
      current = ""
      hasField = false
    }

    func appendProtected(_ text: String) {
      current += text
      hasField = true
    }

    func appendUnprotected(_ text: String) {
      let split = Self.splitFields(text)
      if split.parts.isEmpty {
        if split.hadSeparator { flush() }
        return
      }
      if split.leadingSeparator { flush() }
      current += split.parts[0]
      hasField = true
      for part in split.parts.dropFirst() {
        fields.append(current)
        current = part
        hasField = true
      }
      if split.trailingSeparator { flush() }
    }

    func appendDefault(_ segments: [ConfSegment]) {
      for segment in segments {
        switch segment {
        case .literal(let text, let protected):
          if protected { appendProtected(text) } else { appendUnprotected(text) }
        case .expansion:
          // The parser rejects nested expansions in defaults.
          break
        }
      }
    }

    func defaultText(_ segments: [ConfSegment]) -> String {
      var text = ""
      for segment in segments {
        if case .literal(let literal, _) = segment {
          text += literal
        }
      }
      return text
    }

    for segment in word.segments {
      switch segment {
      case .literal(let text, let protected):
        if protected { appendProtected(text) } else { appendUnprotected(text) }
      case .expansion(let name, let defaultValue, let quoted):
        if let value = state.variables[name], !value.isEmpty {
          if quoted { appendProtected(value) } else { appendUnprotected(value) }
        } else if let defaultValue, quoted {
          appendProtected(defaultText(defaultValue))
        } else if let defaultValue {
          appendDefault(defaultValue)
        } else if quoted {
          appendProtected("")
        }
      }
    }

    flush()
    return fields
  }

  private static func splitFields(
    _ text: String
  ) -> (leadingSeparator: Bool, parts: [String], trailingSeparator: Bool, hadSeparator: Bool) {
    let characters = Array(text)
    var index = 0

    func isSeparator(_ character: Character) -> Bool {
      character == " " || character == "\t" || character == "\n"
    }

    let leading = index < characters.count && isSeparator(characters[index])
    var parts: [String] = []
    var trailing = false
    while index < characters.count {
      while index < characters.count && isSeparator(characters[index]) {
        index += 1
      }
      if index >= characters.count {
        trailing = true
        break
      }
      var part = ""
      while index < characters.count && !isSeparator(characters[index]) {
        part.append(characters[index])
        index += 1
      }
      parts.append(part)
    }
    let hadSeparator = leading || trailing || parts.count > 1
    return (leading, parts, trailing, hadSeparator)
  }
}
