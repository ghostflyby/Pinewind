// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage
import Yams

/// Decode the node graph instead of Any/Codable coercions: quoted string options,
/// duplicate fields, null clears, and source positions are part of the contract.
struct YAMLReader {
  let source: String

  func error(_ message: String, at node: Node? = nil, field: String? = nil) -> PinewindError {
    PinewindError(
      .invalidConfiguration, message, source: source, line: node?.mark.map { $0.line }, field: field
    )
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

  func relativePath(_ text: String) throws -> RelativePath {
    guard !text.contains("\0"), !text.contains("\\") else {
      throw PinewindError(
        .invalidPath, "document paths must use portable path syntax", source: source)
    }
    return try RelativePath(FilePath(text))
  }

  func version(_ fields: [String: Node]) throws {
    guard let node = fields["version"], node.tag == Tag(.int), node.int == 1 else {
      throw error("version is required and must be integer 1", at: fields["version"])
    }
  }

  func filter(_ fields: [String: Node]) throws -> FileFilter {
    let include = try fields["include"].flatMap { $0.tag == Tag(.null) ? nil : try strings($0) }
    let exclude = try fields["exclude"].map { $0.tag == Tag(.null) ? [] : try strings($0) } ?? []
    let filter = FileFilter(include: include, exclude: exclude)
    try filter.validate()
    return filter
  }
}

enum ConfigurationParser {
  static let packageKeys: Set<String> = [
    "url", "revision", "recipe", "options", "include", "exclude",
  ]

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
}

// A single typed evaluator serves document editing, snapshots, and deployment.
enum ConfigurationEvaluator {
  static func merge(_ updates: PackageFields, into base: PackageFields) -> PackageFields {
    func choose<T>(_ update: FieldOverride<T>, _ original: FieldOverride<T>) -> FieldOverride<T> {
      if case .inherit = update { return original }
      return update
    }
    var result = base
    if case .value(let url) = updates.url, url.isFileURL, case .inherit = updates.revision {
      result.revision = .reset
    }
    result.url = choose(updates.url, result.url)
    result.revision = choose(updates.revision, result.revision)
    result.recipe = choose(updates.recipe, result.recipe)
    result.options = choose(updates.options, result.options)
    result.include = choose(updates.include, result.include)
    result.exclude = choose(updates.exclude, result.exclude)
    return result
  }
  static func request(_ fields: PackageFields) throws -> PackageRequest {
    guard let url = fields.url.value else {
      throw PinewindError("package requires an absolute source URL")
    }
    return try PackageRequest(
      url: url, revision: fields.revision.value, recipe: fields.recipe.value,
      options: fields.options.value ?? [:],
      filter: FileFilter(include: fields.include.value, exclude: fields.exclude.value ?? []))
  }
  static func diagnostics(_ document: ManifestDocument, local: LocalOverridesDocument?)
    -> [Diagnostic]
  {
    var result: [Diagnostic] = []
    var names = document.names
    func append(_ error: Error, field: String, entry: Int? = nil) {
      let error =
        error as? PinewindError ?? PinewindError(.invalidConfiguration, String(describing: error))
      result.append(
        Diagnostic(
          PinewindError(
            error.code, error.message, source: error.source,
            line: error.line, field: field, entry: entry)))
    }
    for (name, fields) in document.names.sorted(by: { $0.key < $1.key }) {
      do {
        guard name != "self" else { throw PinewindError("self is a reserved name") }
        try fields.validate()
      } catch { append(error, field: "names." + name) }
    }
    for (name, fields) in (local?.names ?? [:]).sorted(by: { $0.key < $1.key }) {
      do {
        guard name != "self" else {
          throw PinewindError("self is a reserved name", source: "pinewind.local.yaml")
        }
        try fields.validate()
      } catch { append(error, field: "names." + name) }
      names[name] = merge(fields, into: names[name] ?? PackageFields())
    }
    for (index, entry) in document.order.enumerated() {
      var usedNames: [String: PackageFields] = [:]
      if case .named(let name, _) = entry { usedNames[name] = names[name] }
      do { _ = try evaluate(ManifestDocument(names: usedNames, order: [entry]), local: nil) } catch
      { append(error, field: "order[\(index)]", entry: index) }
    }
    return result
  }
  static func evaluate(_ document: ManifestDocument, local: LocalOverridesDocument?) throws
    -> Manifest
  {
    var names = document.names
    for (name, fields) in names {
      guard name != "self" else { throw PinewindError("self is a reserved name") }
      try fields.validate()
    }
    for (name, fields) in local?.names ?? [:] {
      guard name != "self" else {
        throw PinewindError("self is a reserved name", source: "pinewind.local.yaml")
      }
      try fields.validate()
      names[name] = merge(fields, into: names[name] ?? PackageFields())
    }
    let entries = try document.order.enumerated().map { index, entry -> ManifestEntry in
      do {
        switch entry {
        case .userFiles(let filter):
          try filter.validate()
          return .userFiles(filter)
        case .importConf(let request): return .importConf(request)
        case .package(let fields): return .package(try request(fields))
        case .named(let name, let fields):
          guard let definition = names[name] else {
            throw PinewindError("unknown package name '\(name)'")
          }
          return .package(try request(merge(fields, into: definition)))
        }
      } catch let error as PinewindError {
        throw PinewindError(
          error.code, error.message, source: error.source, field: "order[\(index)]", entry: index)
      }
    }
    return Manifest(entries: entries)
  }
}
