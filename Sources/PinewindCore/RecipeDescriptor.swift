// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage
import Yams

/// Declarative metadata only. Names retain recipe.args order; argument values
/// have no inferred type, enum or default. Inspection does not render templates.
public struct RecipeDescriptor: Hashable, Sendable {
  public let path: RelativePath
  public let arguments: [String]
  /// The value accepted by PackageRequest.recipe. nil identifies recipe.yaml.
  public var name: String? {
    path.string == "recipe.yaml" ? nil : String(path.string.dropLast(".recipe.yaml".count))
  }

  public static func parse(_ yaml: String, path: RelativePath, source: String? = nil) throws -> Self
  {
    do {
      guard path.string == "recipe.yaml" || path.string.hasSuffix(".recipe.yaml") else {
        throw FileSystemFailure.unsafeRelative(path.filePath)
      }
      var reader = YAMLReader(source: source ?? path.string, text: yaml)
      let document = try reader.document(yaml)
      reader.anchor = document
      let root = try reader.mapping(
        document, allowed: ["recipe", "download_files", "install_files", "patch_files"])
      let name =
        path.string == "recipe.yaml" ? nil : String(path.string.dropLast(".recipe.yaml".count))
      return Self(
        path: path, arguments: try declaredArguments(in: root, name: name, reader: reader))
    } catch { throw ErrorBoundary.normalize(error) }
  }

  /// Checks declared names only. Full template/value validation belongs to the
  /// normal preparation pipeline and may need source files and resource inputs.
  public func validateOptions(_ options: [String: String]) throws {
    if let unknown = options.keys.sorted().first(where: { !arguments.contains($0) }) {
      throw DeclarationFailure.undeclaredOption(unknown)
    }
  }

  static func declaredArguments(in root: [String: Node], name: String?, reader: YAMLReader) throws
    -> [String]
  {
    let info = try root["recipe"].map { try reader.mapping($0) } ?? [:]
    if let name {
      guard let value = info["Rx"], try reader.string(value) == name else {
        throw reader.error("recipe Rx must match the explicit recipe name")
      }
    }
    var names = [String]()
    if let args = info["args"] {
      for declaration in try reader.strings(args) {
        let name = String(
          declaration.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
        guard !name.isEmpty else {
          throw reader.error("recipe argument requires a nonempty option name")
        }
        if !names.contains(name) { names.append(name) }
      }
    }
    return names
  }
}

/// Reads recipe declarations from an already acquired source tree. One malformed
/// recipe does not hide other recipes. No downloads or template expansion occur.
public struct RecipeCatalog: Sendable {
  public let recipes: [RecipeDescriptor]
  public let diagnostics: [PinewindError]

  public static func read(in directory: FilePath) async throws -> Self {
    do {
      let directory = try NativePath.absolute(directory)
      return try await BlockingIO.run {
        var recipes = [RecipeDescriptor]()
        var diagnostics = [PinewindError]()
        for path in try SafePath.files(in: directory)
        where path.string == "recipe.yaml" || path.string.hasSuffix(".recipe.yaml") {
          try Cancellation.check()
          do {
            let file = try SafePath.file(path, in: directory)
            let data = try FileIO.perform(.read, paths: [file]) {
              try Data(contentsOf: file.foundationURL)
            }
            guard let yaml = String(data: data, encoding: .utf8) else {
              throw FileSystemFailure.undecodableText(file)
            }
            recipes.append(try RecipeDescriptor.parse(yaml, path: path, source: file.string))
          } catch is CancellationError { throw CancellationError() } catch {
            let normalized = ErrorBoundary.normalize(error)
            diagnostics.append((normalized as? PinewindError) ?? .runtime(normalized))
          }
        }
        return Self(recipes: recipes, diagnostics: diagnostics)
      }
    } catch { throw ErrorBoundary.normalize(error) }
  }
}
