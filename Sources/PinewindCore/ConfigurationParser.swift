// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Yams

/// Decode the node graph instead of Any/Codable coercions: quoted string options,
/// duplicate fields, null clears, and source positions are part of the contract.
struct YAMLReader {
  let source: String

  func error(_ message: String, at node: Node? = nil) -> PinewindError {
    PinewindError(message, source: source, line: node?.mark.map { $0.line })
  }

  func document(_ yaml: String) throws -> Node {
    do {
      let documents = Array(try compose_all(yaml: yaml))
      guard documents.count == 1 else { throw error("expected exactly one YAML document") }
      return documents[0]
    } catch let error as PinewindError { throw error } catch {
      throw self.error(String(describing: error))
    }
  }

  func mapping(_ node: Node, allowed: Set<String>? = nil) throws -> [String: Node] {
    guard let mapping = node.mapping else { throw error("expected a mapping", at: node) }
    var fields: [String: Node] = [:]
    for (keyNode, value) in mapping {
      let key = try string(keyNode)
      guard fields[key] == nil else { throw error("duplicate field '\(key)'", at: keyNode) }
      if let allowed, !allowed.contains(key) { throw error("unknown field '\(key)'", at: keyNode) }
      fields[key] = value
    }
    return fields
  }

  func string(_ node: Node) throws -> String {
    guard node.tag == Tag(.str), let string = node.scalar?.string else {
      throw error("expected a string; quote numeric or boolean-looking values", at: node)
    }
    return string
  }

  func strings(_ node: Node) throws -> [String] {
    guard let sequence = node.sequence else { throw error("expected a sequence", at: node) }
    return try sequence.map(string)
  }

  func stringMap(_ node: Node) throws -> [String: String] {
    try mapping(node).mapValues(string)
  }

  func version(_ fields: [String: Node]) throws {
    guard let node = fields["version"], node.tag == Tag(.int), node.int == 1 else {
      throw error("version is required and must be integer 1", at: fields["version"])
    }
  }

  func filter(_ fields: [String: Node]) throws -> FileFilter {
    let include = try fields["include"].flatMap { $0.tag == Tag(.null) ? nil : try strings($0) }
    let exclude = try fields["exclude"].map { $0.tag == Tag(.null) ? [] : try strings($0) } ?? []
    for pattern in (include ?? []) + exclude { _ = try Glob.compile(pattern) }
    return FileFilter(include: include, exclude: exclude)
  }
}

enum ConfigurationParser {
  static let packageKeys: Set<String> = [
    "url", "ref", "commit", "recipe", "options", "include", "exclude",
  ]

  static func parse(_ yaml: String, overrides: String?, source: String) throws -> Manifest {
    let reader = YAMLReader(source: source)
    let root = try reader.mapping(reader.document(yaml), allowed: ["version", "names", "order"])
    try reader.version(root)
    var names = try root["names"].map { try reader.mapping($0) } ?? [:]
    // Validate unused definitions too, so typos do not become latent failures.
    for (name, node) in names {
      guard name != "self" else { throw reader.error("self is a reserved name", at: node) }
      try validateFields(reader.mapping(node, allowed: packageKeys), reader: reader)
    }
    if let overrides {
      let local = YAMLReader(source: "pinewind.local.yaml")
      let fields = try local.mapping(local.document(overrides), allowed: ["version", "names"])
      try local.version(fields)
      if let definitions = fields["names"] {
        for (name, node) in try local.mapping(definitions) {
          guard name != "self" else { throw local.error("self is a reserved name", at: node) }
          try validateFields(local.mapping(node, allowed: packageKeys), reader: local)
          var merged = try names[name].map { try reader.mapping($0, allowed: packageKeys) } ?? [:]
          merge(try local.mapping(node, allowed: packageKeys), into: &merged)
          names[name] = Node(
            merged.sorted { $0.key < $1.key }.map { (Node($0.key, Tag(.str)), $0.value) })
        }
      }
    }
    guard let order = root["order"]?.sequence else {
      throw reader.error("order must be a sequence")
    }
    let entries = try order.map { node -> ManifestEntry in
      switch try decodeOrderEntry(node, reader: reader) {
      case .userFiles(let filter): return .userFiles(filter)
      case .importConf(let conf): return .importConf(conf)
      case .package(let name, let fields):
        return .package(
          try package(name: name, inline: fields, names: names, reader: reader, at: node))
      }
    }
    return Manifest(entries: entries)
  }

  enum DecodedOrderEntry {
    case userFiles(FileFilter)
    case importConf(ConfImport)
    case package(name: String?, fields: [String: Node])
  }

  // Both editable documents and effective manifests use the same authored selector grammar.
  static func decodeOrderEntry(_ node: Node, reader: YAMLReader) throws -> DecodedOrderEntry {
    if node.tag == Tag(.str) {
      let name = try reader.string(node)
      if name == "self" { return .userFiles(FileFilter()) }
      return .package(name: name, fields: [:])
    }
    let allowed = packageKeys.union(["self", "name", "import", "variables"])
    let fields = try reader.mapping(node, allowed: allowed)
    let selectors = ["self", "name", "url", "import"].filter { fields[$0] != nil }
    guard selectors.count == 1, let selector = selectors.first else {
      throw reader.error("each entry requires exactly one of self, name, url, import", at: node)
    }
    switch selector {
    case "self":
      guard fields.count == 1, let value = fields["self"] else {
        throw reader.error("self filters belong inside the self mapping", at: node)
      }
      return .userFiles(
        try reader.filter(reader.mapping(value, allowed: ["include", "exclude"])))
    case "import":
      guard Set(fields.keys).isSubset(of: ["import", "variables"]), let value = fields["import"]
      else {
        throw reader.error("conf imports only accept import and variables", at: node)
      }
      return .importConf(
        try ConfImport(
          source: reader.string(value),
          variables: fields["variables"].map(reader.stringMap) ?? [:]))
    default:
      guard fields["variables"] == nil else {
        throw reader.error("variables is only valid on imports", at: node)
      }
      let name = try fields["name"].map(reader.string)
      return .package(name: name, fields: fields.filter { $0.key != "name" })
    }
  }

  static func validateFields(_ fields: [String: Node], reader: YAMLReader) throws {
    for key in ["url", "ref", "commit", "recipe"] {
      if let node = fields[key], node.tag != Tag(.null) { _ = try reader.string(node) }
    }
    if let options = fields["options"], options.tag != Tag(.null) {
      _ = try reader.stringMap(options)
    }
    _ = try reader.filter(fields)
    if let node = fields["url"], node.tag != Tag(.null),
      URL(string: try reader.string(node))?.isFileURL == true
    {
      try validateLocalVersion(fields, reader: reader)
    }
  }

  // Changing a remote source to a working tree clears inherited version selectors.
  // Explicit selectors in the overriding layer remain errors, never silently dropped.
  static func merge(_ updates: [String: Node], into fields: inout [String: Node]) {
    if let text = updates["url"]?.scalar?.string, URL(string: text)?.isFileURL == true {
      for key in ["ref", "commit"] where updates[key] == nil { fields.removeValue(forKey: key) }
    }
    for (key, value) in updates { fields[key] = value }
  }

  static func validateLocalVersion(_ fields: [String: Node], reader: YAMLReader) throws {
    for key in ["ref", "commit"] {
      if let node = fields[key], node.tag != Tag(.null) {
        throw reader.error("file sources cannot specify \(key)", at: node)
      }
    }
  }

  static func package(
    name: String?, inline: [String: Node], names: [String: Node],
    reader: YAMLReader, at node: Node
  ) throws -> PackageRequest {
    var fields: [String: Node] = [:]
    if let name {
      guard let definition = names[name] else {
        throw reader.error("unknown package name '\(name)'", at: node)
      }
      fields = try reader.mapping(definition, allowed: packageKeys)
    }
    merge(inline, into: &fields)
    func optional(_ key: String) throws -> String? {
      try fields[key].flatMap { $0.tag == Tag(.null) ? nil : try reader.string($0) }
    }
    guard let text = try optional("url"), let url = URL(string: text), url.scheme != nil else {
      throw reader.error("package requires an absolute source URL", at: node)
    }
    if url.isFileURL { try validateLocalVersion(fields, reader: reader) }
    let options =
      try fields["options"].map { $0.tag == Tag(.null) ? [:] : try reader.stringMap($0) } ?? [:]
    return try PackageRequest(
      url: url, ref: optional("ref"), commit: optional("commit"),
      recipe: optional("recipe"), options: options, filter: reader.filter(fields))
  }
}
