// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Positions are one-based and point at the first character of a statement or word.
struct ConfPosition: Hashable, Sendable {
  let line: Int
  let column: Int
}

enum ConfSegment: Hashable, Sendable {
  case literal(String)
  case expansion(name: String, defaultValue: String?)
}

struct ConfWord: Hashable, Sendable {
  let segments: [ConfSegment]
  let position: ConfPosition
}

/// The package-list conf subset: `package_list` array assignments plus `source`.
/// Everything else is rejected with a positioned evaluation failure.
struct ConfStatement: Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case assign([ConfWord])
    case append([ConfWord])
    case source(ConfWord)
  }

  let kind: Kind
  let position: ConfPosition
}

struct ConfProgram: Hashable, Sendable {
  let statements: [ConfStatement]
}

enum ConfParser {
  static func parse(_ text: String, virtualPath: String) throws(InterpreterFailure)
    -> ConfProgram
  {
    var scanner = Scanner(text: text, virtualPath: virtualPath)
    return try scanner.parseProgram()
  }

  private struct Scanner {
    let characters: [Character]
    let virtualPath: String
    var index = 0
    var line = 1
    var column = 1

    init(text: String, virtualPath: String) {
      characters = Array(text)
      self.virtualPath = virtualPath
    }

    var isAtEnd: Bool { index >= characters.count }

    func peek(_ offset: Int = 0) -> Character? {
      let position = index + offset
      guard position < characters.count else { return nil }
      return characters[position]
    }

    @discardableResult
    mutating func advance() -> Character {
      let character = characters[index]
      index += 1
      if character == "\n" {
        line += 1
        column = 1
      } else {
        column += 1
      }
      return character
    }

    var position: ConfPosition { ConfPosition(line: line, column: column) }

    func failure(_ message: String) -> InterpreterFailure {
      .evaluationFailed(detail: "\(virtualPath):\(line):\(column): \(message)")
    }

    mutating func skipHorizontalWhitespace() {
      while let character = peek(), character == " " || character == "\t" {
        advance()
      }
    }

    mutating func skipWhitespace() {
      while let character = peek(), character == " " || character == "\t" || character == "\n" {
        advance()
      }
    }

    mutating func skipComment() {
      while let character = peek(), character != "\n" {
        advance()
      }
    }

    mutating func parseProgram() throws(InterpreterFailure) -> ConfProgram {
      var statements: [ConfStatement] = []
      while true {
        skipWhitespace()
        guard let character = peek() else { break }
        if character == "#" {
          skipComment()
          continue
        }
        if matchesIdentifier("package_list") {
          statements.append(try parseAssignment())
        } else if matchesIdentifier("source") {
          statements.append(try parseSource(length: "source".count))
        } else if character == ".", isDotSource() {
          statements.append(try parseSource(length: 1))
        } else {
          throw failure("only package_list assignments and source are supported")
        }
        try finishStatement()
      }
      return ConfProgram(statements: statements)
    }

    func matchesIdentifier(_ name: String) -> Bool {
      var offset = 0
      for expected in name {
        guard peek(offset) == expected else { return false }
        offset += 1
      }
      guard let next = peek(offset) else { return true }
      return !isIdentifierCharacter(next)
    }

    func isDotSource() -> Bool {
      guard peek() == "." else { return false }
      guard let next = peek(1) else { return false }
      return next == " " || next == "\t"
    }

    mutating func parseAssignment() throws(InterpreterFailure) -> ConfStatement {
      let start = position
      for _ in 0..<"package_list".count { advance() }
      var append = false
      if peek() == "+" {
        advance()
        append = true
      }
      guard peek() == "=" else { throw failure("expected '=' after package_list") }
      advance()
      skipHorizontalWhitespace()
      guard peek() == "(" else { throw failure("expected '(' after package_list=") }
      advance()

      var words: [ConfWord] = []
      while true {
        skipWhitespace()
        guard let character = peek() else {
          throw failure("unterminated package_list array")
        }
        if character == ")" {
          advance()
          break
        }
        if character == "#" {
          skipComment()
          continue
        }
        if character == "(" {
          throw failure("nested arrays and subshells are unsupported")
        }
        words.append(try parseWord(allowCloseParen: true))
      }
      return ConfStatement(kind: append ? .append(words) : .assign(words), position: start)
    }

    mutating func parseSource(length: Int) throws(InterpreterFailure) -> ConfStatement {
      let start = position
      for _ in 0..<length { advance() }
      guard let separator = peek(), separator == " " || separator == "\t" else {
        throw failure("source requires a path")
      }
      skipHorizontalWhitespace()
      guard let character = peek(), character != "\n", character != "#" else {
        throw failure("source requires a path")
      }
      let word = try parseWord(allowCloseParen: false)
      return ConfStatement(kind: .source(word), position: start)
    }

    mutating func parseWord(allowCloseParen: Bool) throws(InterpreterFailure) -> ConfWord {
      let start = position
      var segments: [ConfSegment] = []
      var literal = ""
      var sawToken = false

      func flushLiteral() {
        guard !literal.isEmpty else { return }
        segments.append(.literal(literal))
        literal = ""
      }

      while let character = peek() {
        if character == " " || character == "\t" || character == "\n" { break }
        if character == ")" {
          if allowCloseParen { break }
          throw failure("unexpected ')'")
        }
        if character == "(" {
          throw failure("nested arrays and subshells are unsupported")
        }
        if character == "\"" {
          sawToken = true
          advance()
          try parseDoubleQuoted(into: &segments, literal: &literal)
          continue
        }
        if character == "'" {
          throw failure("single quotes are unsupported")
        }
        if character == "$" {
          flushLiteral()
          sawToken = true
          segments.append(try parseExpansion())
          continue
        }
        if character == "\\" {
          advance()
          guard let next = peek() else { throw failure("trailing backslash") }
          if next == "\n" {
            advance()
            continue
          }
          literal.append(next)
          sawToken = true
          advance()
          continue
        }
        if ";|&<>`".contains(character) {
          throw failure("unsupported operator '\(character)'")
        }
        literal.append(character)
        sawToken = true
        advance()
      }

      flushLiteral()
      guard sawToken || !segments.isEmpty else { throw failure("expected a word") }
      if segments.isEmpty { segments = [.literal("")] }
      return ConfWord(segments: segments, position: start)
    }

    mutating func parseDoubleQuoted(
      into segments: inout [ConfSegment], literal: inout String
    ) throws(InterpreterFailure) {
      while let character = peek() {
        if character == "\"" {
          advance()
          return
        }
        if character == "$" {
          if !literal.isEmpty {
            segments.append(.literal(literal))
            literal = ""
          }
          segments.append(try parseExpansion())
          continue
        }
        if character == "`" {
          throw failure("command substitution is unsupported")
        }
        if character == "\\" {
          advance()
          guard let next = peek() else { throw failure("unterminated quoted string") }
          if next == "\n" {
            advance()
            continue
          }
          if next == "$" || next == "\"" || next == "\\" {
            literal.append(next)
            advance()
          } else {
            literal.append("\\")
            literal.append(next)
            advance()
          }
          continue
        }
        literal.append(character)
        advance()
      }
      throw failure("unterminated quoted string")
    }

    mutating func parseExpansion() throws(InterpreterFailure) -> ConfSegment {
      advance()
      guard peek() == "{" else {
        guard let first = peek(), isIdentifierStart(first) else {
          throw failure("unsupported expansion; use ${name} or ${name:-default}")
        }
        var name = ""
        while let character = peek(), isIdentifierCharacter(character) {
          name.append(character)
          advance()
        }
        return .expansion(name: name, defaultValue: nil)
      }
      advance()
      guard let first = peek(), isIdentifierStart(first) else {
        throw failure("invalid variable name in expansion")
      }
      var name = ""
      while let character = peek(), isIdentifierCharacter(character) {
        name.append(character)
        advance()
      }
      if peek() == "}" {
        advance()
        return .expansion(name: name, defaultValue: nil)
      }
      guard peek() == ":", peek(1) == "-" else {
        throw failure("unsupported expansion operator")
      }
      advance()
      advance()
      var defaultValue = ""
      while let character = peek(), character != "}" {
        if character == "$" {
          throw failure("nested expansions are unsupported")
        }
        defaultValue.append(character)
        advance()
      }
      guard peek() == "}" else { throw failure("unterminated expansion") }
      advance()
      return .expansion(name: name, defaultValue: defaultValue)
    }

    mutating func finishStatement() throws(InterpreterFailure) {
      skipHorizontalWhitespace()
      if peek() == "#" { skipComment() }
      guard let character = peek() else { return }
      guard character == "\n" else {
        throw failure("unexpected '\(character)' after statement")
      }
      advance()
    }

    func isIdentifierStart(_ character: Character) -> Bool {
      character == "_" || ("a"..."z").contains(character) || ("A"..."Z").contains(character)
    }

    func isIdentifierCharacter(_ character: Character) -> Bool {
      isIdentifierStart(character) || ("0"..."9").contains(character)
    }
  }
}
