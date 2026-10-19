// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BashInterpreter
import Foundation
import SystemPackage

/// Conf evaluation uses a fresh SwiftBash shell and a read-only resource mount.
/// Built-in lists are native data; local confs use the interpreter. Remote resource views
/// will be supplied by the HTTP acquisition layer, never by enabling shell networking.
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
    fileSystem: (any FileSystem)? = nil
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
    let name = file.lastComponent?.string ?? ""
    let shell = BashInterpreter.Shell(
      environment: Environment(variables: variables, workingDirectory: "/conf"))
    shell.environment["root_dir"] = "/conf"
    shell.errexit = true
    shell.fileSystem =
      fileSystem
      ?? MountedFileSystem(
        mounts: [.init(virtual: "/conf", host: resourceRoot.string, readOnly: true)],
        backing: RealFileSystem())
    let budget = ConfSourceBudget(limits: limits)
    shell.installShellBuiltin(BoundedSource(name: "source", budget: budget))
    shell.installShellBuiltin(BoundedSource(name: ".", budget: budget))
    // No external command catalog or network permissions are installed.
    // source, array assignments, arithmetic and control flow are interpreter built-ins.
    let script = "source '" + "/conf/" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
    return try await withThrowingTaskGroup(of: [String].self) { group in
      group.addTask {
        let output = OutputSink(bufferingPolicy: .bufferingNewest(0))
        let errors = OutputSink(bufferingPolicy: .bufferingNewest(16))
        shell.stdout = output
        shell.stderr = errors
        let status = try await shell.run(script)
        output.finish()
        errors.finish()
        guard status == .success else {
          let message = await errors.readAllString()
          throw PinewindError.incident(
            DocumentError(
              context: context,
              failure: InterpreterFailure.evaluationFailed(
                detail: message.trimmingCharacters(in: .whitespacesAndNewlines))))
        }
        guard shell.environment.associativeArrays["package_list"] == nil else {
          throw PinewindError.configuration(
            DocumentError(
              context: context,
              failure: InterpreterFailure.evaluationFailed(
                detail: "package_list must be an indexed array")))
        }
        if shell.environment.variables["package_list"] != nil {
          throw PinewindError.configuration(
            DocumentError(
              context: context,
              failure: InterpreterFailure.evaluationFailed(
                detail: "package_list must be an indexed array")))
        }
        return shell.environment.arrays["package_list"]?.elementsInOrder ?? []
      }
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

/// Shared across interpreter subshell copies; a bounded include count also stops
/// cyclic source chains without changing the semantics of repeated includes.
private actor ConfSourceBudget {
  let limits: ImportLimits
  init(limits: ImportLimits) { self.limits = limits }
  private var calls = 0
  private var bytes = 0

  func charge(_ size: Int) throws(InterpreterFailure) {
    calls += 1
    bytes += size
    guard calls <= limits.maximumSources else {
      throw InterpreterFailure.budgetExceeded(.sources)
    }
    guard size <= limits.maximumFileBytes else {
      throw InterpreterFailure.budgetExceeded(.fileBytes)
    }
    guard bytes <= limits.maximumTotalBytes else {
      throw InterpreterFailure.budgetExceeded(.totalBytes)
    }
  }
}

private struct BoundedSource: Command {
  let name: String
  let budget: ConfSourceBudget

  func run(_ argv: [String]) async throws -> ExitStatus {
    try Task.checkCancellation()
    guard let path = argv.dropFirst().first else { return ExitStatus(2) }
    let data = try await BashInterpreter.Shell.bashCurrent.readDataAtPath(path)
    try await budget.charge(data.count)
    return try await SourceCommand(name: name).run(argv)
  }
}
