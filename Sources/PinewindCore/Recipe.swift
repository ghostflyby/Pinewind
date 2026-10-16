// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage
import Yams

struct Recipe {
  struct Patch {
    let target: RelativePath
    let rx: String
    let body: String
  }
  struct Download {
    let url: URL
    let path: RelativePath
  }
  let patterns: [String]?
  let patches: [Patch]
  let downloads: [Download]

  static func load(request: PackageRequest, directory: FilePath, read: (FilePath) throws -> Data)
    throws
    -> Recipe?
  {
    let file = try SafePath.file(request.recipePath, in: directory)
    guard FileManager.default.fileExists(atPath: file.string) else {
      if request.recipe != nil {
        throw PinewindError("explicit recipe not found", source: file.string)
      }
      return nil
    }
    let reader = YAMLReader(source: file.string)
    guard let text = String(data: try read(file), encoding: .utf8) else {
      throw reader.error("recipe must be UTF-8")
    }
    let root = try reader.mapping(
      reader.document(text),
      allowed: ["recipe", "download_files", "install_files", "patch_files"])
    let info = try root["recipe"].map { try reader.mapping($0) } ?? [:]
    if let explicit = request.recipe {
      guard let value = info["Rx"], try reader.string(value) == explicit else {
        throw reader.error("recipe Rx must match the explicit recipe name")
      }
    }
    var declared = Set<String>()
    if let args = info["args"] {
      for arg in try reader.strings(args) {
        guard
          let first = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            .first, !first.isEmpty
        else {
          throw reader.error("recipe argument requires a nonempty option name")
        }
        declared.insert(String(first))
      }
    }
    guard Set(request.options.keys).isSubset(of: declared) else {
      throw reader.error("options must be declared in recipe.args")
    }
    func list(_ node: Node) throws -> [String] {
      if node.tag == Tag(.null) { return [] }
      if node.sequence != nil { return try reader.strings(node) }
      return try reader.string(node).split(separator: "\n").flatMap { line in
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { return [String]() }
        return text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
      }
    }
    let patterns = try root["install_files"].map(list) ?? []
    let downloads = try root["download_files"].map(list) ?? []
    let resources = try downloads.map { text -> Download in
      let parts = text.components(separatedBy: "::")
      guard parts.count <= 2, let url = URL(string: parts.last ?? ""), url.scheme == "https" else {
        throw reader.error("download_files requires HTTPS resources")
      }
      let path = parts.count == 2 ? parts[0] : url.lastPathComponent
      return try Download(url: url, path: RelativePath(path))
    }
    guard Set(resources.map(\.path)).count == resources.count else {
      throw reader.error("download_files targets must be unique")
    }
    let source = try SourceIdentity.normalize(request.url)
    let components = source.path.split(separator: "/").suffix(2).joined(separator: "/")
    let options = request.options.keys.sorted().map { "\($0)=\(request.options[$0] ?? "")" }.joined(
      separator: ",")
    let rx = components + ":" + (request.recipe ?? "") + ":" + options
    guard !rx.contains("\n"), !rx.contains("\r") else {
      throw reader.error("Rx identity cannot contain newlines")
    }
    var patchTargets = Set<RelativePath>()
    let patches: [Patch] =
      try root["patch_files"].map { node in
        try reader.mapping(node).sorted { $0.key < $1.key }.map { target, body in
          let expanded = try Template.expand(target, options: request.options, declared: declared)
          let target = try RelativePath(expanded)
          guard patchTargets.insert(target).inserted else {
            throw reader.error("patch_files targets must be unique after normalization")
          }
          guard body.sequence != nil else {
            throw reader.error("patch body must be a YAML sequence", at: body)
          }
          let text = try serialize(node: body)
            .replacingOccurrences(of: "---\n", with: "")
            .trimmingCharacters(in: .newlines)
          let substituted = try Template.expand(text, options: request.options, declared: declared)
          guard let parsed = try compose(yaml: substituted), parsed.sequence != nil else {
            throw reader.error("expanded patch body must be a YAML sequence")
          }
          return Patch(target: target, rx: rx, body: substituted)
        }
      } ?? []
    return Recipe(patterns: patterns, patches: patches, downloads: resources)
  }
}

enum Template {
  static func expand(_ text: String, options: [String: String], declared: Set<String>) throws
    -> String
  {
    let expression = try NSRegularExpression(
      pattern: #"\$\{([A-Za-z_][A-Za-z_0-9]*)(?::-(.*?))?\}|\$([A-Za-z_][A-Za-z_0-9]*)"#)
    var result = text
    for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
      .reversed()
    {
      func capture(_ index: Int) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
      }
      let key = capture(1) ?? capture(3) ?? ""
      guard declared.contains(key) else { throw PinewindError("undeclared recipe option '\(key)'") }
      let fallback = capture(2)
      let value: String
      if let supplied = options[key], fallback == nil || !supplied.isEmpty {
        value = supplied
      } else if let fallback {
        value = fallback
      } else {
        throw PinewindError("recipe option '\(key)' has no value")
      }
      guard let range = Range(match.range, in: result) else {
        throw PinewindError("invalid template range")
      }
      // Literal replacement: substituted values are never reparsed as shell code.
      result.replaceSubrange(range, with: value)
    }
    return result
  }
}
