// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Yams

/// An authored field: omission inherits, null clears, and a value replaces the whole field.
public enum FieldOverride<Value: Hashable & Sendable>: Hashable, Sendable {
  case inherit
  case reset
  case value(Value)

  var value: Value? {
    if case .value(let value) = self { return value }
    return nil
  }
}

/// Partial package declarations retain their layer, including explicit nulls.
public struct PackageFields: Hashable, Sendable {
  public var url: FieldOverride<URL>
  public var revision: FieldOverride<GitRevision>
  public var recipe: FieldOverride<String>
  public var options: FieldOverride<[String: String]>
  public var include: FieldOverride<[String]>
  public var exclude: FieldOverride<[String]>

  public init(
    url: FieldOverride<URL> = .inherit, revision: FieldOverride<GitRevision> = .inherit,
    recipe: FieldOverride<String> = .inherit,
    options: FieldOverride<[String: String]> = .inherit,
    include: FieldOverride<[String]> = .inherit, exclude: FieldOverride<[String]> = .inherit
  ) {
    self.url = url
    self.revision = revision
    self.recipe = recipe
    self.options = options
    self.include = include
    self.exclude = exclude
  }

  func validate() throws {
    if let url = url.value, url.scheme == nil {
      throw PinewindError(
        .invalidConfiguration, "package requires an absolute source URL", field: "url")
    }
    try FileFilter(include: include.value, exclude: exclude.value ?? []).validate()
    try revision.value?.validate()
    if url.value?.isFileURL == true, revision.value != nil {
      throw PinewindError(
        .invalidConfiguration, "file sources cannot specify revision", field: "revision")
    }
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
    try serialize(node: DocumentCodec.root(names: names, order: order), allowUnicode: true)
  }

  /// Diagnostics refer to the edited document, without line numbers from generated YAML.
  public func evaluate(localOverrides: LocalOverridesDocument? = nil) throws -> EvaluatedManifest {
    try ConfigurationEvaluator.evaluate(self, local: localOverrides)
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
    try serialize(node: DocumentCodec.root(names: names), allowUnicode: true)
  }
}

enum DocumentCodec {
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
    func field<T>(_ key: String, _ decode: (Node) throws -> T) throws -> FieldOverride<T> {
      guard let node = fields[key] else { return .inherit }
      return node.tag == Tag(.null) ? .reset : .value(try decode(node))
    }
    let result = try PackageFields(
      url: field("url") { node in
        let text = try reader.string(node)
        guard let url = URL(string: text) else {
          throw reader.error("package requires an absolute source URL", at: node)
        }
        return url
      },
      revision: field("revision") { try revision($0, reader: reader) },
      recipe: field("recipe", reader.string), options: field("options", reader.stringMap),
      include: field("include", reader.strings), exclude: field("exclude", reader.strings))
    do { try result.validate() } catch let error as PinewindError {
      throw reader.error(error.message, at: error.field.flatMap { fields[$0] }, field: error.field)
    }
    return result
  }

  static func revision(_ node: Node, reader: YAMLReader) throws -> GitRevision {
    if node.tag == Tag(.str), try reader.string(node) == "default" { return .defaultBranch }
    let fields = try reader.mapping(node, allowed: ["branch", "tag", "ref", "commit"])
    guard fields.count == 1, let (key, value) = fields.first else {
      throw reader.error("revision requires exactly one selector", at: node)
    }
    let text = try reader.string(value)
    let result: GitRevision
    switch key {
    case "branch": result = .branch(text)
    case "tag": result = .tag(text)
    case "ref": result = .reference(text)
    default: result = .commit(try CommitID(text))
    }
    return result
  }
  static func revisionNode(_ value: GitRevision) -> Node {
    switch value {
    case .defaultBranch: return string("default")
    case .branch(let text): return mapping([("branch", string(text))])
    case .tag(let text): return mapping([("tag", string(text))])
    case .reference(let text): return mapping([("ref", string(text))])
    case .commit(let id): return mapping([("commit", string(id.string))])
    }
  }

  static func string(_ value: String) -> Node { Node(value, Tag(.str), .doubleQuoted) }
  static func mapping(_ pairs: [(String, Node)]) -> Node {
    Node(pairs.map { (Node($0.0, Tag(.str)), $0.1) })
  }
  static func strings(_ values: [String]) -> Node { Node(values.map(string)) }
  static func stringMap(_ values: [String: String]) -> Node {
    mapping(values.sorted { $0.key < $1.key }.map { ($0.key, string($0.value)) })
  }

  static func packageNode(_ fields: PackageFields) throws -> [(String, Node)] {
    try fields.validate()
    var pairs: [(String, Node)] = []
    func append<T>(_ key: String, _ field: FieldOverride<T>, _ encode: (T) -> Node) {
      switch field {
      case .inherit: break
      case .reset: pairs.append((key, Node("null", Tag(.null))))
      case .value(let value): pairs.append((key, encode(value)))
      }
    }
    append("url", fields.url) { string($0.absoluteString) }
    append("revision", fields.revision, revisionNode)
    append("recipe", fields.recipe, string)
    append("options", fields.options, stringMap)
    append("include", fields.include, strings)
    append("exclude", fields.exclude, strings)
    return pairs
  }

  static func filterNode(_ filter: FileFilter) throws -> Node {
    try filter.validate()
    var pairs: [(String, Node)] = []
    if let include = filter.include { pairs.append(("include", strings(include))) }
    if !filter.exclude.isEmpty { pairs.append(("exclude", strings(filter.exclude))) }
    return mapping(pairs)
  }

  static func root(names: [String: PackageFields], order: [OrderEntry]? = nil) throws -> Node {
    var pairs: [(String, Node)] = [("version", Node("1", Tag(.int)))]
    if !names.isEmpty {
      pairs.append(
        (
          "names",
          mapping(
            try names.sorted { $0.key < $1.key }.map { name, fields in
              guard name != "self" else { throw PinewindError("self is a reserved name") }
              return (name, mapping(try packageNode(fields)))
            })
        ))
    }
    if let order {
      let entries = try order.map { entry -> Node in
        switch entry {
        case .userFiles(let filter): return mapping([("self", try filterNode(filter))])
        case .named(let name, let overrides):
          guard case .inherit = overrides.url else {
            throw PinewindError(
              "named entries require a single name selector; override URLs in names")
          }
          return mapping([("name", string(name))] + (try packageNode(overrides)))
        case .package(let package):
          if case .inherit = package.url {
            throw PinewindError("inline package entries require a URL selector")
          }
          return mapping(try packageNode(package))
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
}
