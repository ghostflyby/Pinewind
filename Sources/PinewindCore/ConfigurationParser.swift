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

  /// The decoded document's identity, positioned at the node when one is available.
  func context(at node: Node? = nil) -> DocumentContext {
    let path = FilePath(source)
    let placement = node?.mark.map { Placement(line: $0.line, column: $0.column) }
    let url = (try? path.foundationURL) ?? URL(fileURLWithPath: source)
    return DocumentContext(path: path, url: url, placement: placement)
  }

  /// An anchored verdict carrying a typed fact.
  func fail(_ failure: Failure, at node: Node? = nil) -> PinewindError {
    .configuration(DocumentError(context: context(at: node), failure: failure))
  }

  /// An anchored decode failure; the detail carries the structural fact.
  func error(_ detail: String, at node: Node? = nil) -> PinewindError {
    fail(.declaration(.syntaxError(detail: detail)), at: node)
  }

  func document(_ yaml: String) throws(PinewindError) -> Node {
    do {
      let documents = Array(try compose_all(yaml: yaml))
      guard documents.count == 1 else { throw error("expected exactly one YAML document") }
      return documents[0]
    } catch let error as PinewindError { throw error } catch {
      throw self.error(String(describing: error))
    }
  }

  func mapping(_ node: Node, allowed: Set<String>? = nil) throws(PinewindError) -> [String: Node] {
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

  func string(_ node: Node) throws(PinewindError) -> String {
    guard node.tag == Tag(.str), let string = node.scalar?.string else {
      throw error("expected a string; quote numeric or boolean-looking values", at: node)
    }
    return string
  }

  func strings(_ node: Node) throws(PinewindError) -> [String] {
    guard let sequence = node.sequence else { throw error("expected a sequence", at: node) }
    return try sequence.map(string)
  }

  func stringMap(_ node: Node) throws(PinewindError) -> [String: String] {
    try mapping(node).mapValues(string)
  }

  func relativePath(_ text: String) throws(PinewindError) -> RelativePath {
    guard !text.contains("\0"), !text.contains("\\") else {
      throw fail(.file(.notPortable(FilePath(text))))
    }
    return try PinewindError.relay { try RelativePath(FilePath(text)) }
  }

  func version(_ fields: [String: Node]) throws(PinewindError) {
    guard let node = fields["version"], node.tag == Tag(.int), node.int == 1 else {
      throw error("version is required and must be integer 1", at: fields["version"])
    }
  }

  func filter(_ fields: [String: Node]) throws(PinewindError) -> FileFilter {
    let include = try PinewindError.relay {
      try fields["include"].flatMap { $0.tag == Tag(.null) ? nil : try strings($0) }
    }
    let exclude = try PinewindError.relay {
      try fields["exclude"].map { $0.tag == Tag(.null) ? [] : try strings($0) } ?? []
    }
    let filter = FileFilter(include: include, exclude: exclude)
    try PinewindError.relay { try filter.validate() }
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
  static func decodeOrderEntry(_ node: Node, reader: YAMLReader) throws(PinewindError)
    -> DecodedOrderEntry
  {
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
        try PinewindError.relay {
          try ConfImport(
            source: reader.string(value),
            variables: fields["variables"].map(reader.stringMap) ?? [:])
        })
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
  static func request(_ fields: PackageFields) throws(PinewindError) -> PackageRequest {
    guard let url = fields.url.value else {
      throw PinewindError.runtime(.declaration(.inlineURLRequired))
    }
    return try PinewindError.relay {
      try PackageRequest(
        url: url, revision: fields.revision.value, recipe: fields.recipe.value,
        options: fields.options.value ?? [:],
        filter: FileFilter(include: fields.include.value, exclude: fields.exclude.value ?? []))
    }
  }
  static func diagnostics(
    _ document: ManifestDocument, local: LocalOverridesDocument?,
    sharedContext: DocumentContext? = nil, localContext: DocumentContext? = nil
  ) -> [PinewindError] {
    var result: [PinewindError] = []
    var names = document.names
    func append(_ error: Error, anchoredBy context: DocumentContext?) {
      let typed =
        error as? PinewindError
        ?? PinewindError.runtime(
          .defect(.wrapped(detail: String(describing: error), origin: Origin())))
      result.append(context.map { typed.promoted($0) } ?? typed)
    }
    for (name, fields) in document.names.sorted(by: { $0.key < $1.key }) {
      do {
        guard name != "self" else {
          throw PinewindError.runtime(.declaration(.reservedName("self")))
        }
        try PinewindError.relay { try fields.validate() }
      } catch { append(error, anchoredBy: sharedContext) }
    }
    for (name, fields) in (local?.names ?? [:]).sorted(by: { $0.key < $1.key }) {
      do {
        guard name != "self" else {
          throw PinewindError.runtime(.declaration(.reservedName("self")))
        }
        try PinewindError.relay { try fields.validate() }
      } catch { append(error, anchoredBy: localContext ?? sharedContext) }
      names[name] = merge(fields, into: names[name] ?? PackageFields())
    }
    for entry in document.order {
      var usedNames: [String: PackageFields] = [:]
      if case .named(let name, _) = entry { usedNames[name] = names[name] }
      do { _ = try evaluate(ManifestDocument(names: usedNames, order: [entry]), local: nil) } catch
      { append(error, anchoredBy: sharedContext) }
    }
    return result
  }
  static func evaluate(_ document: ManifestDocument, local: LocalOverridesDocument?)
    throws(PinewindError)
    -> Manifest
  {
    var names = document.names
    for (name, fields) in names {
      guard name != "self" else { throw PinewindError.runtime(.declaration(.reservedName("self"))) }
      try PinewindError.relay { try fields.validate() }
    }
    for (name, fields) in local?.names ?? [:] {
      guard name != "self" else { throw PinewindError.runtime(.declaration(.reservedName("self"))) }
      try PinewindError.relay { try fields.validate() }
      names[name] = merge(fields, into: names[name] ?? PackageFields())
    }
    let entries = try PinewindError.relay {
      try document.order.enumerated().map { index, entry -> ManifestEntry in
        switch entry {
        case .userFiles(let filter):
          try PinewindError.relay { try filter.validate() }
          return .userFiles(filter)
        case .importConf(let request): return .importConf(request)
        case .package(let fields): return .package(try request(fields))
        case .named(let name, let fields):
          guard let definition = names[name] else {
            throw PinewindError.runtime(.declaration(.unknownName(name)))
          }
          return .package(try request(merge(fields, into: definition)))
        }
      }
    }
    return Manifest(entries: entries)
  }
}
