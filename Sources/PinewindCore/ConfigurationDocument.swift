// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Yams

/// An authored field: omission inherits, null clears, and a value replaces the whole field.
public enum Field<Value: Hashable & Sendable>: Hashable, Sendable {
  case inherit
  case clear
  case value(Value)
}

/// Partial package declarations retain their layer, including explicit nulls.
public struct PackageFields: Hashable, Sendable {
  public var url: Field<URL>
  public var ref: Field<String>
  public var commit: Field<String>
  public var recipe: Field<String>
  public var options: Field<[String: String]>
  public var include: Field<[String]>
  public var exclude: Field<[String]>

  public init(
    url: Field<URL> = .inherit, ref: Field<String> = .inherit,
    commit: Field<String> = .inherit, recipe: Field<String> = .inherit,
    options: Field<[String: String]> = .inherit,
    include: Field<[String]> = .inherit, exclude: Field<[String]> = .inherit
  ) {
    self.url = url
    self.ref = ref
    self.commit = commit
    self.recipe = recipe
    self.options = options
    self.include = include
    self.exclude = exclude
  }
}

public enum OrderEntry: Hashable, Sendable {
  case userFiles(FileFilter)
  case named(String, overrides: PackageFields = PackageFields())
  case package(PackageFields)
  case importConf(ConfImport)
}

/// Editable shared declarations. YAML round trips preserve semantics, not comments or layout.
/// Incomplete drafts are allowed; evaluate before deployment or saving.
public struct ManifestDocument: Hashable, Sendable {
  public var names: [String: PackageFields]
  public var order: [OrderEntry]

  public init(
    names: [String: PackageFields] = [:], order: [OrderEntry] = [.userFiles(FileFilter())]
  ) {
    self.names = names
    self.order = order
  }

  public static func parse(_ yaml: String, source: String = "pinewind.yaml") throws -> Self {
    try DocumentCodec.manifest(yaml, source: source)
  }

  /// Emits version 1. Invalid field combinations are diagnosed rather than discarded.
  public func yaml() throws -> String {
    try DocumentCodec.withoutSourceLines {
      let text = try DocumentCodec.emit(self)
      _ = try Self.parse(text)
      return text
    }
  }

  /// Diagnostics refer to the edited document, without line numbers from generated YAML.
  public func evaluate(localOverrides: LocalOverridesDocument? = nil) throws -> Manifest {
    try DocumentCodec.withoutSourceLines {
      try ConfigurationParser.parse(
        yaml(), overrides: localOverrides?.yaml(), source: "pinewind.yaml")
    }
  }

  public mutating func renamePackage(_ old: String, to new: String) throws {
    guard let fields = names[old] else { throw PinewindError("unknown package name '\(old)'") }
    if old == new { return }
    guard new != "self", names[new] == nil else {
      throw PinewindError("package name '\(new)' is reserved or already defined")
    }
    names.removeValue(forKey: old)
    names[new] = fields
    order = order.map {
      if case .named(let name, let overrides) = $0, name == old {
        return .named(new, overrides: overrides)
      }
      return $0
    }
  }

  public mutating func removePackage(_ name: String) throws {
    guard names[name] != nil else { throw PinewindError("unknown package name '\(name)'") }
    guard
      !order.contains(where: {
        if case .named(let reference, _) = $0 { return reference == name }
        return false
      })
    else { throw PinewindError("package name '\(name)' is still referenced") }
    names.removeValue(forKey: name)
  }

  /// Destination is the final index after moving; duplicate entries remain distinct positions.
  public mutating func moveEntry(from: Int, to: Int) throws {
    guard order.indices.contains(from), order.indices.contains(to) else {
      throw PinewindError("order entry index is out of bounds")
    }
    order.insert(order.remove(at: from), at: to)
  }
}

/// Editable local declarations, never flattened into the shared document or lock.
public struct LocalOverridesDocument: Hashable, Sendable {
  public var names: [String: PackageFields]

  public init(names: [String: PackageFields] = [:]) { self.names = names }

  public static func parse(_ yaml: String, source: String = "pinewind.local.yaml") throws -> Self {
    let reader = YAMLReader(source: source)
    let fields = try reader.mapping(reader.document(yaml), allowed: ["version", "names"])
    try reader.version(fields)
    return Self(names: try DocumentCodec.names(fields["names"], reader: reader))
  }

  public func yaml() throws -> String {
    try DocumentCodec.withoutSourceLines {
      let text = try serialize(node: DocumentCodec.root(names: names), allowUnicode: true)
      _ = try Self.parse(text)
      return text
    }
  }
}

enum DocumentCodec {
  // Nodes emitted from an edited value have no correspondence to the original file's lines.
  // Parsing original input still retains its source marks through YAMLReader.
  static func withoutSourceLines<T>(_ body: () throws -> T) throws -> T {
    do { return try body() } catch let error as PinewindError {
      throw PinewindError(error.message, source: error.source)
    }
  }

  static func manifest(_ yaml: String, source: String) throws -> ManifestDocument {
    let reader = YAMLReader(source: source)
    let fields = try reader.mapping(reader.document(yaml), allowed: ["version", "names", "order"])
    try reader.version(fields)
    let definitions = try names(fields["names"], reader: reader)
    guard let sequence = fields["order"]?.sequence else {
      throw reader.error("order must be a sequence", at: fields["order"])
    }
    let order = try sequence.map { node -> OrderEntry in
      switch try ConfigurationParser.decodeOrderEntry(node, reader: reader) {
      case .userFiles(let filter): return .userFiles(filter)
      case .importConf(let conf): return .importConf(conf)
      case .package(let name, let fields):
        let declaration = try package(fields, reader: reader)
        if let name { return .named(name, overrides: declaration) }
        return .package(declaration)
      }
    }
    return ManifestDocument(names: definitions, order: order)
  }

  static func names(_ node: Node?, reader: YAMLReader) throws -> [String: PackageFields] {
    guard let node else { return [:] }
    var result: [String: PackageFields] = [:]
    for (name, value) in try reader.mapping(node) {
      guard name != "self" else { throw reader.error("self is a reserved name", at: value) }
      result[name] = try package(
        reader.mapping(value, allowed: ConfigurationParser.packageKeys), reader: reader)
    }
    return result
  }

  static func package(_ fields: [String: Node], reader: YAMLReader) throws -> PackageFields {
    try ConfigurationParser.validateFields(fields, reader: reader)
    func field<T>(_ key: String, _ decode: (Node) throws -> T) throws -> Field<T> {
      guard let node = fields[key] else { return .inherit }
      return node.tag == Tag(.null) ? .clear : .value(try decode(node))
    }
    return try PackageFields(
      url: field("url") { node in
        let text = try reader.string(node)
        guard let url = URL(string: text), url.scheme != nil else {
          throw reader.error("package requires an absolute source URL", at: node)
        }
        return url
      },
      ref: field("ref", reader.string), commit: field("commit", reader.string),
      recipe: field("recipe", reader.string), options: field("options", reader.stringMap),
      include: field("include", reader.strings), exclude: field("exclude", reader.strings))
  }

  static func string(_ value: String) -> Node { Node(value, Tag(.str), .doubleQuoted) }
  static func mapping(_ pairs: [(String, Node)]) -> Node {
    Node(pairs.map { (Node($0.0, Tag(.str)), $0.1) })
  }
  static func strings(_ values: [String]) -> Node { Node(values.map(string)) }
  static func stringMap(_ values: [String: String]) -> Node {
    mapping(values.sorted { $0.key < $1.key }.map { ($0.key, string($0.value)) })
  }

  static func packageNode(_ fields: PackageFields) -> [(String, Node)] {
    var pairs: [(String, Node)] = []
    func append<T>(_ key: String, _ field: Field<T>, _ encode: (T) -> Node) {
      switch field {
      case .inherit: break
      case .clear: pairs.append((key, Node("null", Tag(.null))))
      case .value(let value): pairs.append((key, encode(value)))
      }
    }
    append("url", fields.url) { string($0.absoluteString) }
    append("ref", fields.ref, string)
    append("commit", fields.commit, string)
    append("recipe", fields.recipe, string)
    append("options", fields.options, stringMap)
    append("include", fields.include, strings)
    append("exclude", fields.exclude, strings)
    return pairs
  }

  static func filterNode(_ filter: FileFilter) -> Node {
    var pairs: [(String, Node)] = []
    if let include = filter.include { pairs.append(("include", strings(include))) }
    if !filter.exclude.isEmpty { pairs.append(("exclude", strings(filter.exclude))) }
    return mapping(pairs)
  }

  static func root(names: [String: PackageFields], order: [OrderEntry]? = nil) -> Node {
    var pairs: [(String, Node)] = [("version", Node("1", Tag(.int)))]
    if !names.isEmpty {
      pairs.append(
        (
          "names",
          mapping(names.sorted { $0.key < $1.key }.map { ($0.key, mapping(packageNode($0.value))) })
        ))
    }
    if let order {
      let entries = order.map { entry -> Node in
        switch entry {
        case .userFiles(let filter): return mapping([("self", filterNode(filter))])
        case .named(let name, let overrides):
          return mapping([("name", string(name))] + packageNode(overrides))
        case .package(let package): return mapping(packageNode(package))
        case .importConf(let conf):
          var fields = [("import", string(conf.source))]
          if !conf.variables.isEmpty { fields.append(("variables", stringMap(conf.variables))) }
          return mapping(fields)
        }
      }
      pairs.append(("order", Node(entries)))
    }
    return mapping(pairs)
  }

  static func emit(_ document: ManifestDocument) throws -> String {
    try serialize(node: root(names: document.names, order: document.order), allowUnicode: true)
  }
}
