// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage
import Yams

/// Only configuration verdicts anchored in original YAML enter this report.
/// Encoding preserves each concrete document error's own Codable structure.
public struct LintReport: Sendable, Encodable {
  public let diagnostics: [any DocumentErrorProtocol]
  public var isValid: Bool { diagnostics.isEmpty }
  public let version = 1

  public func encode(to encoder: any Encoder) throws {
    var root = encoder.container(keyedBy: CodingKeys.self)
    try root.encode(version, forKey: .version)
    var values = root.nestedUnkeyedContainer(forKey: .diagnostics)
    for diagnostic in diagnostics {
      guard let value = diagnostic as? any Encodable else {
        throw EncodingError.invalidValue(
          diagnostic,
          .init(
            codingPath: values.codingPath,
            debugDescription: "The diagnostic does not support Encodable"))
      }
      try value.encode(to: values.superEncoder())
    }
  }
  private enum CodingKeys: String, CodingKey { case version, diagnostics }
}

/// Nodes stay beside their decoded values while linting, never reconstructed from emitted YAML.
final class YAMLLinter {
  private var diagnostics: [any DocumentErrorProtocol] = []
  private struct Definition {
    let fields: PackageFields
    let node: Node
    let reader: YAMLReader
    let valid: Bool
  }
  private struct Entry {
    let value: OrderEntry
    let node: Node
    let reader: YAMLReader
  }
  private struct Document {
    var definitions: [String: Definition] = [:]
    var entries: [Entry] = []
    var namesValid = true
  }
  private struct Request {
    let value: PackageRequest
    let sourceContext: DocumentContext?
    let recipeContext: DocumentContext?
  }

  private func record(_ error: any Error) throws {
    guard case .configuration(let document) = error as? PinewindError,
      document.context.placement != nil
    else { throw error }
    if diagnostics.contains(where: {
      $0.context == document.context
        && sameError(.configuration($0), .configuration(document))
    }) {
      return
    }
    diagnostics.append(document)
  }
  private func record<E: Error>(_ failure: E, at context: DocumentContext?) throws {
    if let failure = failure as? PinewindError {
      try record(failure)
      return
    }
    // Imported Plum descriptors can select a recipe without a YAML selector.
    // Such failures use the operation channel, like other unpositioned I/O errors.
    guard let context else { throw failure }
    try record(PinewindError.configuration(DocumentError(context: context, failure: failure)))
  }
  private func emit<E: Error>(_ error: E, reader: YAMLReader, at node: Node) throws {
    try record(reader.fail(error, at: node))
  }
  private func attempt<T>(_ body: () throws -> T) throws -> T? {
    do { return try body() } catch {
      try record(error)
      return nil
    }
  }
  private func mapping(_ node: Node, reader: YAMLReader, allowed: Set<String>? = nil) throws
    -> [String: Node]
  {
    guard let pairs = node.mapping else {
      try record(reader.error("expected a mapping", at: node))
      return [:]
    }
    var fields: [String: Node] = [:]
    for (keyNode, value) in pairs {
      try Cancellation.check()
      guard let key = try attempt({ try reader.string(keyNode) }) else { continue }
      if fields[key] != nil {
        try record(reader.error("duplicate field '\(key)'", at: keyNode))
        continue
      }
      if let allowed, !allowed.contains(key) {
        try record(reader.error("unknown field '\(key)'", at: keyNode))
        continue
      }
      fields[key] = value
    }
    return fields
  }
  private func package(_ node: Node, reader: YAMLReader, namedEntry: Bool = false) throws
    -> (PackageFields, Bool)
  {
    let initial = diagnostics.count
    let allowed = ConfigurationParser.packageKeys.union(namedEntry ? ["name"] : [])
    let fields = try mapping(node, reader: reader, allowed: allowed)
    var result = PackageFields()
    for key in ConfigurationParser.packageKeys.sorted() {
      guard let value = fields[key] else { continue }
      if let decoded = try attempt({
        try DocumentCodec.package([key: value], reader: reader, anchor: node, validating: false)
      }) {
        switch key {
        case "url": result.url = decoded.url
        case "revision": result.revision = decoded.revision
        case "recipe": result.recipe = decoded.recipe
        case "options": result.options = decoded.options
        case "include": result.include = decoded.include
        case "exclude": result.exclude = decoded.exclude
        default: break
        }
      }
    }
    for problem in result.problems() {
      var anchor = fields[problem.field] ?? node
      if case .invalidPattern(let pattern, _) = problem.failure as? DeclarationFailure,
        let element = anchor.sequence?.first(where: { $0.scalar?.string == pattern })
      {
        anchor = element
      }
      try emit(problem.failure, reader: reader, at: anchor)
    }
    return (result, diagnostics.count == initial)
  }
  private func document(_ bytes: Data?, path: FilePath, local: Bool) throws -> Document {
    guard let bytes else { return Document() }
    guard let text = String(data: bytes, encoding: .utf8) else {
      throw FileSystemFailure.undecodableText(path)
    }
    var reader = YAMLReader(source: path.string, text: text)
    guard let root = try attempt({ try reader.document(text) }) else {
      return Document(namesValid: false)
    }
    reader.anchor = root
    guard root.mapping != nil else {
      try record(reader.error("expected a mapping", at: root))
      return Document(namesValid: false)
    }
    let fields = try mapping(
      root, reader: reader,
      allowed: local ? ["version", "names"] : ["version", "names", "order"])
    _ = try attempt { try reader.version(fields) }
    var result = Document()
    if let names = fields["names"] {
      let initial = diagnostics.count
      let definitions = try mapping(names, reader: reader)
      result.namesValid = diagnostics.count == initial
      for (name, node) in definitions.sorted(by: { $0.key < $1.key }) {
        let (value, valid) = try package(node, reader: reader)
        do { try ConfigurationEvaluator.validateName(name) } catch {
          try emit(error, reader: reader, at: node)
        }
        result.definitions[name] = Definition(
          fields: value, node: node, reader: reader,
          valid: valid && !name.isEmpty && name != "self")
      }
    }
    guard !local else { return result }
    guard let sequence = fields["order"]?.sequence else {
      try record(reader.error("order must be a sequence", at: fields["order"] ?? root))
      return result
    }
    for node in sequence {
      try Cancellation.check()
      if let pairs = node.mapping, pairs.count == 1,
        let pair = pairs.first, pair.key.scalar?.string == "self"
      {
        let fields = try mapping(pair.value, reader: reader, allowed: ["include", "exclude"])
        for key in ["include", "exclude"] {
          guard let value = fields[key], value.tag != Tag(.null) else { continue }
          guard let items = value.sequence else {
            try record(reader.error("expected a sequence", at: value))
            continue
          }
          for item in items {
            guard let pattern = try attempt({ try reader.string(item) }) else { continue }
            do { _ = try Glob.compile(pattern) } catch { try emit(error, reader: reader, at: item) }
          }
        }
        continue
      }
      guard
        let decoded = try attempt({ try ConfigurationParser.decodeOrderEntry(node, reader: reader) }
        )
      else { continue }
      switch decoded {
      case .userFiles(let filter):
        result.entries.append(Entry(value: .userFiles(filter), node: node, reader: reader))
      case .importConf(let request):
        result.entries.append(Entry(value: .importConf(request), node: node, reader: reader))
      case .package(let name, _):
        if node.tag == Tag(.str), let name {
          result.entries.append(Entry(value: .named(name), node: node, reader: reader))
          continue
        }
        let (value, valid) = try package(node, reader: reader, namedEntry: name != nil)
        guard valid else { continue }
        if let name {
          result.entries.append(
            Entry(value: .named(name, overrides: value), node: node, reader: reader))
        } else if value.url.value == nil {
          try emit(DeclarationFailure.inlineURLRequired, reader: reader, at: node)
        } else {
          result.entries.append(Entry(value: .package(value), node: node, reader: reader))
        }
      }
    }
    return result
  }
  private func hasInvalidURL(_ definition: Definition?) -> Bool {
    guard let definition else { return false }
    if definition.fields.problems().contains(where: { $0.field == "url" }) { return true }
    let authored = definition.node.mapping?.first { $0.key.scalar?.string == "url" }?.value
    return authored != nil && authored?.tag != Tag(.null) && definition.fields.url == .inherit
  }

  private func fieldContext<Value: Hashable & Sendable>(
    _ field: FieldOverride<Value>, key: String, node: Node, reader: YAMLReader,
    inheriting: DocumentContext? = nil
  ) -> DocumentContext? {
    switch field {
    case .inherit: return inheriting
    case .reset: return nil
    case .value:
      return node.mapping?.first { $0.key.scalar?.string == key }
        .map { reader.context(at: $0.value) }
    }
  }

  private func requests(_ shared: Document, local: Document?) throws -> [Request] {
    var requests: [Request] = []
    for entry in shared.entries {
      var value: PackageFields
      var sourceContext: DocumentContext?
      var recipeContext: DocumentContext?
      switch entry.value {
      case .package(let fields):
        value = fields
        sourceContext = fieldContext(fields.url, key: "url", node: entry.node, reader: entry.reader)
        recipeContext = fieldContext(
          fields.recipe, key: "recipe", node: entry.node, reader: entry.reader)
      case .named(let name, let overrides):
        let definition = shared.definitions[name]
        let update = local?.definitions[name]
        guard definition != nil || update != nil else {
          guard shared.namesValid, local?.namesValid != false else { continue }
          let node =
            entry.node.mapping?.first(where: { $0.key.scalar?.string == "name" })?.value
            ?? entry.node
          try emit(DeclarationFailure.unknownName(name), reader: entry.reader, at: node)
          continue
        }
        // An unreadable definition cannot establish whether a URL is missing.
        // Other field errors (for example a bad glob) do not prevent that independent check.
        guard definition?.node.mapping != nil || definition == nil,
          update?.node.mapping != nil || update == nil
        else { continue }
        value = definition?.fields ?? PackageFields()
        if let definition {
          sourceContext = fieldContext(
            definition.fields.url, key: "url", node: definition.node, reader: definition.reader)
          recipeContext = fieldContext(
            definition.fields.recipe, key: "recipe", node: definition.node,
            reader: definition.reader)
        }
        if let update {
          value = ConfigurationEvaluator.merge(update.fields, into: value)
          sourceContext = fieldContext(
            update.fields.url, key: "url", node: update.node, reader: update.reader,
            inheriting: sourceContext)
          recipeContext = fieldContext(
            update.fields.recipe, key: "recipe", node: update.node, reader: update.reader,
            inheriting: recipeContext)
        }
        value = ConfigurationEvaluator.merge(overrides, into: value)
        sourceContext = fieldContext(
          overrides.url, key: "url", node: entry.node, reader: entry.reader,
          inheriting: sourceContext)
        recipeContext = fieldContext(
          overrides.recipe, key: "recipe", node: entry.node, reader: entry.reader,
          inheriting: recipeContext)
        if value.url.value == nil, !hasInvalidURL(definition), !hasInvalidURL(update) {
          let origin = update ?? definition
          try emit(
            DeclarationFailure.inlineURLRequired,
            reader: origin?.reader ?? entry.reader, at: origin?.node ?? entry.node)
          continue
        }
        guard definition?.valid != false, update?.valid != false else { continue }
      case .userFiles, .importConf: continue
      }
      do {
        requests.append(
          Request(
            value: try ConfigurationEvaluator.request(value), sourceContext: sourceContext,
            recipeContext: recipeContext))
      } catch {
        try emit(error, reader: entry.reader, at: entry.node)
      }
    }
    return requests
  }

  func run(locations: WorkspaceLocations, urls: [URL], maximumResourceBytes: Int) throws
    -> LintReport
  {
    let bytes = try urls.map(ConfigurationStore.read)
    let shared = try document(bytes[0], path: NativePath.from(urls[0]), local: false)
    let local =
      try urls.count > 2 ? document(bytes[2], path: NativePath.from(urls[2]), local: true) : nil
    let declared = try requests(shared, local: nil)
    var all = declared
    if let local {
      // Shared Git requests still participate in lock resolution. Local file
      // evidence belongs to the effective configuration on this machine.
      all = declared.filter { !$0.value.url.isFileURL }
      all += try requests(shared, local: local)
    }
    // A lock is optional evidence, not a requirement to install before linting.
    // Invalid/stale binary records cannot establish a YAML verdict.
    let locked = bytes[1].flatMap { try? ResolutionCodec.reusable($0) }
    if let locked {
      for imported in locked.imports
      where shared.entries.contains(where: {
        if case .importConf(let request) = $0.value { return request == imported.id.request }
        return false
      }) {
        all += imported.packages.map { Request(value: $0, sourceContext: nil, recipeContext: nil) }
      }
    }
    var seen = Set<PackageRequest>()
    for evidence in all {
      try Cancellation.check()
      let request = evidence.value
      let directory: FilePath
      if request.url.isFileURL {
        directory = try NativePath.from(request.url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.string, isDirectory: &isDirectory)
        else {
          try record(FileSystemFailure.notFound(directory), at: evidence.sourceContext)
          continue
        }
        guard isDirectory.boolValue else {
          try record(FileSystemFailure.notADirectory(directory), at: evidence.sourceContext)
          continue
        }
      } else {
        let pin =
          locked?.packages.first(where: { $0.request == request })
          ?? locked?.packages.first(where: {
            guard case .git(let previous) = $0.request.source,
              case .git(let current) = request.source
            else { return false }
            return previous.key == current.key
          })
        let commit: CommitID?
        if case .commit(let value) = request.revision {
          commit = value
        } else {
          commit = pin?.commit
        }
        guard let commit else { continue }
        let identity = try SourceIdentity(url: request.url, commit: commit)
        guard
          let source = try SourceCache.cached(identity, cacheRoot: locations.cacheRoot)
            ?? GitKitRepositoryProvider.cached(identity, cacheRoot: locations.cacheRoot)
        else { continue }
        directory = source.directory
      }
      // A remote source that has not been acquired is optional evidence. Once present,
      // an explicitly selected recipe can be checked against its authored selector.
      guard FileManager.default.fileExists(atPath: directory.string) else { continue }
      let path = try SafePath.file(request.recipePath, in: directory)
      guard FileManager.default.fileExists(atPath: path.string) else {
        guard request.recipe != nil else { continue }
        try record(FileSystemFailure.notFound(path), at: evidence.recipeContext)
        continue
      }
      guard seen.insert(request).inserted else { continue }
      guard let bytes = try ConfigurationStore.read(path.foundationURL) else { continue }
      guard let text = String(data: bytes, encoding: .utf8) else {
        throw FileSystemFailure.undecodableText(path)
      }
      var reader = YAMLReader(source: path.string, text: text)
      guard let node = try attempt({ try reader.document(text) }) else { continue }
      reader.anchor = node
      let root = try mapping(
        node, reader: reader,
        allowed: ["recipe", "install_files", "download_files", "patch_files"])
      let sections = ["install_files", "download_files", "patch_files"].filter { root[$0] != nil }
      for section in sections.isEmpty ? ["recipe"] : sections {
        let selected = root.filter { $0.key == "recipe" || $0.key == section }
        _ = try attempt {
          try Recipe.decode(request: request, file: path, reader: reader, root: selected)
        }
      }
    }
    let active = Set(all.map(\.value))
    let pins =
      (locked?.packages.filter { active.contains($0.request) }.flatMap(\.resources) ?? [])
      + (locked?.imports.filter { imported in
        shared.entries.contains {
          if case .importConf(let request) = $0.value { return request == imported.id.request }
          return false
        }
      }.flatMap(\.resources) ?? [])
    var checked = Set<String>()
    for pin in pins where checked.insert(pin.sha256).inserted {
      guard ["yaml", "yml"].contains(pin.path.filePath.extension?.lowercased() ?? "") else {
        continue
      }
      let file = locations.cacheRoot.appending("resources/" + pin.sha256)
      guard FileManager.default.fileExists(atPath: file.string),
        try SnapshotFiles.byteCount(file) <= maximumResourceBytes,
        try SnapshotFiles.sha256(file) == pin.sha256
      else { continue }
      guard let bytes = try ConfigurationStore.read(file.foundationURL) else { continue }
      guard let text = String(data: bytes, encoding: .utf8) else {
        throw FileSystemFailure.undecodableText(file)
      }
      let reader = YAMLReader(source: file.string, text: text, sourceURL: pin.url)
      _ = try attempt { try reader.document(text) }
    }
    diagnostics.sort {
      let a = $0.context
      let b = $1.context
      if a.path != b.path { return a.path.string < b.path.string }
      if a.placement?.line != b.placement?.line {
        return (a.placement?.line ?? 0) < (b.placement?.line ?? 0)
      }
      return (a.placement?.column ?? 0) < (b.placement?.column ?? 0)
    }
    return LintReport(diagnostics: diagnostics)
  }
}
