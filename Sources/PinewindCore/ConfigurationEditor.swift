// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

/// A diagnostic in an edited configuration. Operation indices are zero-based;
/// field names locate form controls, never fabricated YAML line numbers.
public struct ConfigurationDiagnostic: Hashable, Sendable, CustomStringConvertible {
  public let operationIndex: Int?
  public let packageName: String?
  public let field: String?
  public let error: PinewindError
  public var description: String {
    let label = [packageName, field].compactMap { $0 }.joined(separator: ".")
    return label.isEmpty ? error.description : "\(label): \(error)"
  }
}

/// The apply operation was rejected before acquisition or persistence.
/// Each item retains the same PinewindError vocabulary used by single failures.
public struct ConfigurationValidationError: PinewindErrorProtocol, Hashable {
  public let diagnostics: [ConfigurationDiagnostic]
  public var description: String {
    diagnostics.map(\.description).joined(separator: "\n")
  }
}

/// A private candidate exposed only through Workspace's synchronous editing closure.
/// Failed edits leave the candidate unchanged and retain their diagnostics.
public struct ConfigurationEditor: Sendable {
  public var manifest: ManifestDocument
  public var localOverrides: LocalOverridesDocument?
  private let relativeTo: FilePath
  private var operationIndex = 0
  private var diagnostics: [ConfigurationDiagnostic] = []
  private var origins: [String: Int] = [:]
  private var localOrigins: [String: Int] = [:]
  private let localContext: DocumentContext?

  init(_ snapshot: ConfigurationSnapshot) {
    manifest = snapshot.manifest
    localOverrides = snapshot.localOverrides
    relativeTo = snapshot.locations.relativeTo
    localContext = snapshot.locations.configuration.localOverrides.flatMap {
      try? DocumentContext(path: $0.filePath)
    }
  }

  private mutating func edit(
    package: String? = nil, field: String? = nil, local: Bool = false,
    _ operation: (inout ConfigurationDraft) throws -> Void
  ) {
    let index = operationIndex
    operationIndex += 1
    var draft = ConfigurationDraft(
      manifest: manifest, localOverrides: localOverrides, relativeTo: relativeTo)
    do {
      try operation(&draft)
      manifest = draft.manifest
      localOverrides = draft.localOverrides
    } catch {
      // All operations here are synchronous configuration transformations.
      let normalized = configurationError(error)
      let error =
        local
        ? localContext.map { normalized.attributed(to: $0, as: .configuration) } ?? normalized
        : normalized
      diagnostics.append(
        ConfigurationDiagnostic(
          operationIndex: index, packageName: package, field: field, error: error))
    }
  }

  /// Accepts incomplete fields so every independent problem can be diagnosed on apply.
  public mutating func addPackage(
    _ name: String, fields: PackageFields, insertion: PackageInsertion = .beforeUserFiles
  ) {
    let index = operationIndex
    let before = diagnostics.count
    edit(package: name, field: "name") { draft in
      guard !name.isEmpty else { throw DeclarationFailure.emptyName }
      guard name != "self" else { throw DeclarationFailure.reservedName(name) }
      guard draft.manifest.names[name] == nil else { throw DeclarationFailure.duplicateName(name) }
      let index: Int
      switch insertion {
      case .beforeUserFiles:
        index =
          draft.manifest.order.firstIndex {
            if case .userFiles = $0 { return true }
            return false
          } ?? draft.manifest.order.endIndex
      case .end: index = draft.manifest.order.endIndex
      case .before(let anchor), .after(let anchor):
        let matches = draft.manifest.order.indices.filter {
          switch draft.manifest.order[$0] {
          case .named(let name, _): return name == anchor
          case .userFiles: return anchor == "self"
          default: return false
          }
        }
        guard let match = matches.first else {
          throw DeclarationFailure.orderAnchorNotFound(anchor)
        }
        guard matches.count == 1 else { throw DeclarationFailure.ambiguousOrderAnchor(anchor) }
        if case .after = insertion { index = match + 1 } else { index = match }
      }
      draft.manifest.names[name] = fields
      draft.manifest.order.insert(.named(name), at: index)
    }
    if diagnostics.count == before { origins[name] = index }
  }

  public mutating func addPackage(
    _ name: String, request: PackageRequest, insertion: PackageInsertion = .beforeUserFiles
  ) {
    var fields = PackageFields(
      url: .value(request.url), revision: request.revision.map { .value($0) } ?? .reset,
      recipe: request.recipe.map { .value($0) } ?? .reset, options: .value(request.options),
      include: request.filter.include.map { .value($0) } ?? .reset,
      exclude: .value(request.filter.exclude))
    if request.url.isFileURL { fields.revision = .reset }
    addPackage(name, fields: fields, insertion: insertion)
  }

  /// User-facing source syntax shared by CLI and GUI. Parsing and field failures
  /// are retained for validation, never thrown from the editing closure.
  public mutating func addPackage(
    _ name: String? = nil, source: String, revision: GitRevision? = nil,
    recipe: String? = nil, options: [String: String] = [:], filter: FileFilter = FileFilter(),
    insertion: PackageInsertion = .beforeUserFiles
  ) {
    do {
      let (derivedName, url) = try PackageLocator.parse(source, relativeTo: relativeTo)
      addPackage(
        name ?? derivedName,
        fields: PackageFields(
          url: .value(url), revision: revision.map { .value($0) } ?? .inherit,
          recipe: recipe.map { .value($0) } ?? .inherit, options: .value(options),
          include: filter.include.map { .value($0) } ?? .inherit, exclude: .value(filter.exclude)),
        insertion: insertion)
    } catch {
      diagnostics.append(
        ConfigurationDiagnostic(
          operationIndex: operationIndex, packageName: name, field: "url",
          error: configurationError(error)))
      operationIndex += 1
    }
  }

  /// Accepts the raw commit text from a form without requiring a throwing
  /// CommitID initializer before the rest of the candidate can be validated.
  public mutating func addPackage(
    _ name: String? = nil, source: String, commit: String,
    recipe: String? = nil, options: [String: String] = [:], filter: FileFilter = FileFilter(),
    insertion: PackageInsertion = .beforeUserFiles
  ) {
    let index = operationIndex
    let revision: GitRevision?
    let failure: PinewindError?
    do {
      revision = .commit(try CommitID(commit))
      failure = nil
    } catch {
      revision = nil
      failure = configurationError(error)
    }
    addPackage(
      name, source: source, revision: revision, recipe: recipe,
      options: options, filter: filter, insertion: insertion)
    if let failure {
      diagnostics.append(
        ConfigurationDiagnostic(
          operationIndex: index, packageName: name ?? origins.first { $0.value == index }?.key,
          field: "revision", error: failure))
    }
  }

  public mutating func renamePackage(_ old: String, to new: String) {
    let before = diagnostics.count
    edit(package: old, field: "name") { draft in
      guard !new.isEmpty else { throw DeclarationFailure.emptyName }
      try draft.renamePackage(old, to: new)
    }
    if old != new, diagnostics.count == before {
      origins[new] = origins.removeValue(forKey: old)
      localOrigins[new] = localOrigins.removeValue(forKey: old)
    }
  }
  public mutating func removePackage(_ name: String) {
    edit(package: name, field: "name") { try $0.removePackage(name) }
  }
  public mutating func redirectPackage(_ name: String, to location: FileLocation) {
    let index = operationIndex
    let before = diagnostics.count
    edit(package: name, field: "url", local: true) { try $0.redirectPackage(name, to: location) }
    if diagnostics.count == before { localOrigins[name] = index }
  }
  public mutating func moveEntry(from: Int, to: Int) {
    edit(field: "order") { try $0.moveEntry(from: from, to: to) }
  }

  func snapshot(baseline: ConfigurationSnapshot) -> ConfigurationSnapshot {
    var snapshot = ConfigurationSnapshot(
      manifest: manifest, localOverrides: localOverrides,
      sharedRevision: 0, localRevision: 0,
      sharedIsDirty: manifest != baseline.manifest,
      localIsDirty: localOverrides != baseline.localOverrides,
      locations: baseline.locations, baseline: baseline.baseline)
    let context = try? DocumentContext(path: baseline.locations.configuration.manifest.filePath)
    snapshot.editingDiagnostics = diagnostics.map { diagnostic in
      ConfigurationDiagnostic(
        operationIndex: diagnostic.operationIndex, packageName: diagnostic.packageName,
        field: diagnostic.field,
        error: context.map { diagnostic.error.attributed(to: $0, as: .configuration) }
          ?? diagnostic.error)
    }
    snapshot.editingOrigins = origins
    snapshot.editingLocalOrigins = localOrigins
    return snapshot
  }
}

extension ConfigurationSnapshot {
  /// Collects independent configuration problems without network or persistence.
  public func validate(scope: ConfigurationScope? = nil) -> [ConfigurationDiagnostic] {
    guard let scope else {
      var diagnostics = validate(scope: .shared)
      for diagnostic in validate(scope: .effective) where !diagnostics.contains(diagnostic) {
        diagnostics.append(diagnostic)
      }
      return diagnostics
    }
    var result = editingDiagnostics
    func append(_ error: any Error, name: String? = nil, field: String? = nil, local: Bool = false)
    {
      let normalized = configurationError(error)
      let location =
        local ? locations.configuration.localOverrides : locations.configuration.manifest
      let context = location.flatMap { try? DocumentContext(path: $0.filePath) }
      result.append(
        ConfigurationDiagnostic(
          operationIndex: name.flatMap { local ? editingLocalOrigins[$0] : editingOrigins[$0] },
          packageName: name, field: field,
          error: context.map { normalized.attributed(to: $0, as: .configuration) } ?? normalized))
    }
    func check(
      _ name: String?, _ fields: PackageFields, local: Bool = false, checkingName: Bool = true
    ) -> Bool {
      let before = result.count
      if checkingName, let name, name.isEmpty {
        append(DeclarationFailure.emptyName, name: name, field: "name", local: local)
      }
      if checkingName, name == "self" {
        append(DeclarationFailure.reservedName("self"), name: name, field: "name", local: local)
      }
      for problem in fields.problems() {
        append(problem.failure, name: name, field: problem.field, local: local)
      }
      return before == result.count
    }
    var invalidNames = Set<String>()
    for (name, fields) in manifest.names.sorted(by: { $0.key < $1.key }) {
      if !check(name, fields) { invalidNames.insert(name) }
    }
    let local = scope == .effective ? localOverrides : nil
    for (name, fields) in (local?.names ?? [:]).sorted(by: { $0.key < $1.key }) {
      if !check(name, fields, local: true) { invalidNames.insert(name) }
    }
    if locations.configuration.localOverrides == nil, localOverrides != nil {
      append(StateFailure.overridesDisabled, field: "localOverrides")
    }
    // Keep these collecting structural checks aligned with ConfigurationEvaluator.evaluate
    // and document schema validation when order-entry rules change. Invalid entries are
    // diagnosed here before valid entries proceed through the shared evaluator.
    for (index, entry) in manifest.order.enumerated() {
      let before = result.count
      var name: String?
      switch entry {
      case .named(let reference, let overrides):
        name = reference
        _ = check(reference, overrides, checkingName: false)
        if overrides.url != .inherit {
          append(
            DeclarationFailure.namedURLForbidden, name: reference, field: "order[\(index)].url")
        }
        var definition = manifest.names[reference]
        if let updates = local?.names[reference] {
          definition = ConfigurationEvaluator.merge(updates, into: definition ?? PackageFields())
        }
        if definition == nil {
          append(
            DeclarationFailure.unknownName(reference), name: reference,
            field: "order[\(index)].name")
        }
        if let definition, overrides.url == .inherit,
          ConfigurationEvaluator.merge(overrides, into: definition).url.value == nil
        {
          append(DeclarationFailure.inlineURLRequired, name: reference, field: "url")
        }
        if invalidNames.contains(reference) || result.count != before { continue }
      case .package(let fields):
        _ = check(nil, fields)
        if fields.url.value == nil {
          append(DeclarationFailure.inlineURLRequired, field: "order[\(index)].url")
        }
        if result.count != before { continue }
      case .userFiles(let filter):
        let fields = PackageFields(
          include: filter.include.map { .value($0) } ?? .inherit, exclude: .value(filter.exclude))
        for problem in fields.problems() {
          append(problem.failure, field: "order[\(index)].\(problem.field)")
        }
        if result.count != before { continue }
      case .importConf: break
      }
      do {
        _ = try ConfigurationEvaluator.evaluate(
          ManifestDocument(
            names: name.flatMap { name in manifest.names[name].map { [name: $0] } } ?? [:],
            order: [entry]),
          local: name.flatMap { name in
            local?.names[name].map { LocalOverridesDocument(names: [name: $0]) }
          })
      } catch { append(error, name: name, field: "order[\(index)]") }
    }
    return result
  }
}

private func configurationError(_ error: any Error) -> PinewindError {
  if let normalized = ErrorBoundary.normalize(error) as? PinewindError { return normalized }
  return .runtime(.defect(.wrapped(detail: String(describing: error), origin: Origin())))
}

private enum PackageLocator {
  static func parse(_ source: String, relativeTo base: FilePath) throws -> (String, URL) {
    guard !source.isEmpty, !source.contains("\0") else {
      throw DeclarationFailure.invalidPackageSource(source)
    }
    let url: URL
    let path = FilePath((source as NSString).expandingTildeInPath)
    if source.hasPrefix("file:") {
      guard let parsed = URL(string: source) else {
        throw DeclarationFailure.invalidPackageSource(source)
      }
      url = parsed
    } else if path.isAbsolute || path.root != nil || source.hasPrefix(".") || source.hasPrefix("~")
      || FileManager.default.fileExists(atPath: base.appending(path.components).string)
    {
      url = try NativePath.absolute(path, relativeTo: base).foundationURL
    } else if source.contains("://") {
      guard let parsed = URL(string: source) else {
        throw DeclarationFailure.invalidPackageSource(source)
      }
      url = parsed
    } else {
      let parts = source.split(separator: "/", omittingEmptySubsequences: false)
      guard (1...2).contains(parts.count),
        parts.allSatisfy({
          !$0.isEmpty && $0 != "." && $0 != ".."
            && $0.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
        })
      else { throw DeclarationFailure.invalidPackageSource(source) }
      let repository =
        parts.count == 1
        ? "rime/" + (source.hasPrefix("rime-") ? source : "rime-" + source) : source
      guard let parsed = URL(string: "https://github.com/" + repository) else {
        throw DeclarationFailure.invalidPackageSource(source)
      }
      url = parsed
    }
    var name = url.lastPathComponent
    if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
    if name.hasPrefix("rime-") { name = String(name.dropFirst(5)) }
    return (name, url)
  }
}
