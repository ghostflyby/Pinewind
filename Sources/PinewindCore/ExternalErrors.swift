// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BashInterpreter
import Foundation
import SystemPackage
import Yams

// These types retain their original structure and existing Codable capabilities.
extension Errno: PinewindErrorProtocol {}
extension YamlError: PinewindErrorProtocol {}
extension FileSystemError: PinewindErrorProtocol {}
// Intentional standard-protocol adapters for the pinned external types.
// swift-format-ignore: AvoidRetroactiveConformances
extension URLError: PinewindErrorProtocol, @retroactive CustomStringConvertible {
  public var description: String { localizedDescription }
}

// Encode Yams' original cases and associated values. Context has no public
// construction API, so we deliberately add Encodable rather than promise Decodable.
// swift-format-ignore: AvoidRetroactiveConformances
extension Mark: @retroactive Encodable {
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: YAMLCodeKey.self)
    try values.encode(line, forKey: YAMLCodeKey("line"))
    try values.encode(column, forKey: YAMLCodeKey("column"))
  }
}
// swift-format-ignore: AvoidRetroactiveConformances
extension YamlError.Context: @retroactive Encodable {
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: YAMLCodeKey.self)
    try values.encode(text, forKey: YAMLCodeKey("text"))
    try values.encode(mark, forKey: YAMLCodeKey("mark"))
  }
}
// swift-format-ignore: AvoidRetroactiveConformances
extension YamlError: @retroactive Encodable {
  public func encode(to encoder: any Encoder) throws {
    var root = encoder.container(keyedBy: YAMLCodeKey.self)
    switch self {
    case .no: _ = root.nestedContainer(keyedBy: YAMLCodeKey.self, forKey: YAMLCodeKey("no"))
    case .memory: _ = root.nestedContainer(keyedBy: YAMLCodeKey.self, forKey: YAMLCodeKey("memory"))
    case .reader(let problem, let offset, let value, let yaml):
      var fields = root.nestedContainer(keyedBy: YAMLCodeKey.self, forKey: YAMLCodeKey("reader"))
      try fields.encode(problem, forKey: YAMLCodeKey("problem"))
      try fields.encodeIfPresent(offset, forKey: YAMLCodeKey("offset"))
      try fields.encode(value, forKey: YAMLCodeKey("value"))
      try fields.encode(yaml, forKey: YAMLCodeKey("yaml"))
    case .scanner(let context, let problem, let mark, let yaml),
      .parser(let context, let problem, let mark, let yaml),
      .composer(let context, let problem, let mark, let yaml):
      let name: String
      switch self {
      case .scanner: name = "scanner"
      case .parser: name = "parser"
      default: name = "composer"
      }
      var fields = root.nestedContainer(keyedBy: YAMLCodeKey.self, forKey: YAMLCodeKey(name))
      try fields.encodeIfPresent(context, forKey: YAMLCodeKey("context"))
      try fields.encode(problem, forKey: YAMLCodeKey("problem"))
      try fields.encode(mark, forKey: YAMLCodeKey("_2"))
      try fields.encode(yaml, forKey: YAMLCodeKey("yaml"))
    case .writer(let problem), .emitter(let problem), .representer(let problem):
      let name: String
      switch self {
      case .writer: name = "writer"
      case .emitter: name = "emitter"
      default: name = "representer"
      }
      var fields = root.nestedContainer(keyedBy: YAMLCodeKey.self, forKey: YAMLCodeKey(name))
      try fields.encode(problem, forKey: YAMLCodeKey("problem"))
    case .dataCouldNotBeDecoded(let encoding):
      var fields = root.nestedContainer(
        keyedBy: YAMLCodeKey.self, forKey: YAMLCodeKey("dataCouldNotBeDecoded"))
      try fields.encode(encoding.rawValue, forKey: YAMLCodeKey("encoding"))
    case .duplicatedKeysInMapping(let duplicates, let context):
      var fields = root.nestedContainer(
        keyedBy: YAMLCodeKey.self, forKey: YAMLCodeKey("duplicatedKeysInMapping"))
      try fields.encode(duplicates, forKey: YAMLCodeKey("duplicates"))
      try fields.encode(context, forKey: YAMLCodeKey("context"))
    }
  }
}
private struct YAMLCodeKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init(_ value: String) { stringValue = value }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}
