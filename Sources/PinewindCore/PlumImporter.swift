// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

/// Conf evaluation uses the in-repo package-list interpreter over a read-only
/// `/conf` view. Built-in lists are native data; remote resources are supplied
/// by the acquisition layer.
struct PlumImporter: Sendable {
  let limits: ImportLimits
  var timeout: Duration { limits.timeout }
  init(timeout: Duration = .seconds(5)) { limits = ImportLimits(timeout: timeout) }
  init(limits: ImportLimits) { self.limits = limits }

  func expand(_ manifest: Manifest, inputRoot: FilePath) async throws -> Manifest {
    var entries: [ManifestEntry] = []
    for entry in manifest.entries {
      if case .importConf(let request) = entry {
        for descriptor in try await evaluate(request, inputRoot: inputRoot) {
          entries.append(.package(try Self.package(descriptor)))
        }
      } else {
        entries.append(entry)
      }
    }
    return Manifest(entries: entries)
  }

  func evaluate(_ request: ConfImport, inputRoot: FilePath) async throws -> [String] {
    if request.source.hasPrefix(":") {
      return try BuiltinPackageLists.descriptors(for: request.source)
    }
    // Remote conf imports are dispatched by the acquisition layer; the local
    // evaluator must never see them.
    guard let path = request.localPath else {
      throw Defect.invariant(
        detail: "remote conf requires the HTTP resource preparation layer",
        origin: Origin())
    }
    let file = try SafePath.file(path, in: inputRoot)
    return try await evaluate(
      file: file, resourceRoot: file.removingLastComponent(), variables: request.variables)
  }

  func evaluate(
    file: FilePath, resourceRoot: FilePath, variables: [String: String] = [:],
    reader: (any ConfFileReader)? = nil
  ) async throws
    -> [String]
  {
    guard variables["root_dir"] == nil else {
      throw DeclarationFailure.reservedVariable("root_dir")
    }
    guard
      (try SafePath.canonical(file.removingLastComponent()))
        == (try SafePath.canonical(resourceRoot))
    else {
      throw InterpreterFailure.forbiddenOperation(path: file.string)
    }
    let context = try DocumentContext(path: file)
    guard let name = file.lastComponent?.string else {
      throw InterpreterFailure.evaluationFailed(detail: "conf path has no file name")
    }
    let entry: RelativePath
    do {
      entry = try RelativePath(FilePath(name))
    } catch {
      throw InterpreterFailure.forbiddenOperation(path: file.string)
    }
    let evaluator = ConfEvaluator(
      reader: reader ?? DirectConfFileReader(root: resourceRoot),
      limits: limits, variables: variables)
    do {
      return try await withThrowingTaskGroup(of: [String].self) { group in
        group.addTask { try await evaluator.run(entry: entry) }
        group.addTask {
          try await Task.sleep(for: timeout)
          throw PinewindError.incident(
            DocumentError(context: context, failure: InterpreterFailure.timedOut))
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
          throw CancellationError()
        }
        return first
      }
    } catch let failure as InterpreterFailure {
      throw PinewindError.incident(DocumentError(context: context, failure: failure))
    }
  }

  static func package(_ descriptor: String) throws -> PackageRequest {
    let sections = descriptor.split(separator: ":", omittingEmptySubsequences: false).map(
      String.init)
    guard !sections[0].isEmpty else {
      throw InterpreterFailure.evaluationFailed(detail: "empty plum package descriptor")
    }
    let source = sections[0].split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
      .map(String.init)
    let segments = source[0].split(separator: "/", omittingEmptySubsequences: false).map(
      String.init)
    guard segments.count == 1 || segments.count == 2, segments.allSatisfy({ !$0.isEmpty }),
      source.count == 1 || !source[1].isEmpty
    else {
      throw InterpreterFailure.evaluationFailed(detail: "invalid plum package descriptor")
    }
    let owner = segments.count == 2 ? segments[0] : "rime"
    let repository =
      segments.count == 2
      ? segments[1] : (segments[0].hasPrefix("rime-") ? segments[0] : "rime-" + segments[0])
    guard let url = URL(string: "https://github.com/\(owner)/\(repository)") else {
      throw InterpreterFailure.evaluationFailed(detail: "invalid plum repository")
    }
    var options: [String: String] = [:]
    for token in sections.dropFirst(2).flatMap({ $0.split(separator: ",").map(String.init) }) {
      let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2, !pair[0].isEmpty, options[String(pair[0])] == nil else {
        throw InterpreterFailure.evaluationFailed(
          detail: "plum options must be unique key=value literals")
      }
      options[String(pair[0])] = String(pair[1])
    }
    return try PackageRequest(
      url: url, revision: source.count == 2 ? .reference(source[1]) : nil,
      recipe: sections.count > 1 && !sections[1].isEmpty ? sections[1] : nil, options: options)
  }
}
