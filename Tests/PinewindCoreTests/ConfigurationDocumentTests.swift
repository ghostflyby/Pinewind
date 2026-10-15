// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage
import Testing

@testable import PinewindCore

@Suite("Editable configuration documents")
struct ConfigurationDocumentTests {
  private let remote = URL(string: "https://github.com/rime/rime-emoji.git")!

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("pinewind-documents-" + UUID().uuidString)
  }

  private func localStateRoot(_ input: URL) -> URL {
    input.deletingLastPathComponent().appendingPathComponent(input.lastPathComponent + "-local")
  }

  private func remove(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: localStateRoot(root))
  }

  private func diagnostic(_ operation: () throws -> Void) -> PinewindError? {
    do {
      try operation()
      Issue.record("expected a configuration diagnostic")
    } catch let error as PinewindError {
      return error
    } catch { Issue.record("unexpected error: \(error)") }
    return nil
  }

  @Test func roundTripRetainsAuthoredLayersAndStringTypes() throws {
    let text = """
      version: 1
      names:
        emoji:
          url: https://github.com/rime/rime-emoji.git
          revision: {ref: main}
          options: {enabled: "true", count: "123", empty: "", text: "松风"}
      order:
        - emoji
        - self
        - name: emoji
          revision: {commit: "0123456789012345678901234567890123456789"}
          options: {}
          include: []
          exclude: null
        - import: ":preset"
          variables: {value: "false"}
        - url: https://example.com/repo.git
          recipe: "null"
        - self: {include: ["*.yaml"], exclude: ["scratch/**"]}
      """
    let document = try ManifestDocument.parse(text)
    #expect(document.order.count == 6)
    #expect(document.names["emoji"]?.url == .value(remote))
    #expect(try ManifestDocument.parse(document.yaml()) == document)
    #expect(try document.evaluate() == Manifest.parse(text))
  }

  @Test func localFieldsPreserveNullOmissionAndWholeMapReplacement() throws {
    let shared = ManifestDocument(
      names: [
        "emoji": PackageFields(
          url: .value(remote), ref: .value("main"), recipe: .value("customize"),
          options: .value(["a": "1", "b": "2"]), include: .value(["*.yaml"]))
      ],
      order: [.named("emoji")])
    let local = try LocalOverridesDocument.parse(
      """
      version: 1
      names:
        emoji:
          recipe: null
          options: {b: "false"}
          include: null
          exclude: []
      """)
    #expect(local.names["emoji"]?.url == .inherit)
    #expect(local.names["emoji"]?.recipe == .reset)
    #expect(local.names["emoji"]?.exclude == .value([]))
    #expect(try LocalOverridesDocument.parse(local.yaml()) == local)
    let manifest = try shared.evaluate(localOverrides: local)
    guard case .package(let request) = manifest.entries[0] else {
      Issue.record("expected package")
      return
    }
    #expect(request.options == ["b": "false"])
    #expect(request.recipe == nil)
    #expect(request.filter.include == nil)
    #expect(request.ref == "main")
  }

  @Test func localRedirectClearsInheritedVersionButNotExplicitSelectors() throws {
    let document = ManifestDocument(
      names: ["emoji": PackageFields(url: .value(remote), ref: .value("main"))],
      order: [.named("emoji")])
    let directory = temporaryRoot()
    let local = LocalOverridesDocument(names: ["emoji": PackageFields(url: .value(directory))])
    let effective = try document.evaluate(localOverrides: local)
    #expect(effective.entries == [.package(try PackageRequest(url: directory))])
    #expect(throws: PinewindError.self) {
      try document.evaluate(
        localOverrides: LocalOverridesDocument(names: [
          "emoji": PackageFields(url: .value(directory), ref: .value("main"))
        ]))
    }
  }

  @Test func incompleteDraftCanBeReadAndEditedBeforeEvaluation() throws {
    var document = try ManifestDocument.parse(
      """
      version: 1
      names: {emoji: {revision: {ref: main}}}
      order: [emoji]
      """)
    #expect(throws: PinewindError.self) { try document.evaluate() }
    document.names["emoji"]?.url = .value(remote)
    #expect(try document.evaluate().entries.count == 1)
    #expect(throws: PinewindError.self) {
      try ManifestDocument(order: [.named("emoji", overrides: PackageFields(url: .value(remote)))])
        .yaml()
    }
  }

  @Test(arguments: [
    "order: [self]", "version: 2\norder: []", "version: 1\norder: []\norder: []",
    "version: 1\norder: [{self: {}, revision: {ref: main}}]",
    "version: 1\norder: [{import: ':x', revision: {ref: main}}]",
    "version: 1\nnames: {self: {}}\norder: []",
    "version: 1\nnames: {a: {options: {x: true}}}\norder: []",
    "version: 1\norder: [{name: a, variables: {}}]",
    "version: 1\nnames: {a: {unknown: x}}\norder: []",
  ])
  func malformedDocumentsAreRejected(_ text: String) {
    let document = diagnostic { _ = try ManifestDocument.parse(text, source: "original.yaml") }
    let manifest = diagnostic { _ = try Manifest.parse(text, source: "original.yaml") }
    #expect(document?.message == manifest?.message)
    #expect(document?.source == manifest?.source)
    #expect(document?.line == manifest?.line)
  }

  @Test func evaluationDoesNotReportGeneratedLinesAsOriginalSourcePositions() async throws {
    let text = """
      # Original layout
      version: 1
      order:
        - missing
      """
    let original = try #require(
      diagnostic {
        _ = try Manifest.parse(text, source: "original.yaml")
      })
    #expect(original.source == nil)
    #expect(original.line == nil)
    let document = try ManifestDocument.parse(text, source: "original.yaml")
    let evaluated = try #require(diagnostic { _ = try document.evaluate() })
    #expect(evaluated.message == original.message)
    #expect(evaluated.line == nil)

    let root = temporaryRoot()
    defer { remove(root) }
    let configuration = try await Configuration.load(
      inputRoot: root, localStateRoot: localStateRoot(root))
    await configuration.edit { shared, _ in shared = document }
    do {
      _ = try await configuration.evaluateShared()
      Issue.record("expected evaluation error")
    } catch let error as PinewindError { #expect(error.line == nil) }
    await configuration.edit { shared, local in
      shared = ManifestDocument()
      local = LocalOverridesDocument(names: ["self": PackageFields()])
    }
    do {
      _ = try await configuration.evaluateEffective()
      Issue.record("expected local evaluation error")
    } catch let error as PinewindError {
      #expect(error.source == "pinewind.local.yaml")
      #expect(error.line == nil)
    }
  }

  @Test func removingLocalOverridesIsAllowedWhileSharedDocumentIsIncomplete() async throws {
    let root = temporaryRoot()
    defer { remove(root) }
    let configuration = try await Configuration.load(
      inputRoot: root, localStateRoot: localStateRoot(root))
    await configuration.edit { _, local in local = LocalOverridesDocument() }
    try await configuration.saveLocalOverrides()
    await configuration.edit { shared, _ in shared.order = [.named("unfinished")] }
    await #expect(throws: PinewindError.self) { try await configuration.saveLocalOverrides() }
    await configuration.edit { _, local in local = nil }
    try await configuration.saveLocalOverrides()
    #expect(
      !FileManager.default.fileExists(
        atPath: localStateRoot(root).appendingPathComponent("pinewind.local.yaml").path))
    try await configuration.saveLocalOverrides()
    await #expect(throws: PinewindError.self) { try await configuration.evaluateShared() }
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("pinewind.yaml").path))
  }

  @Test func editsCoordinateReferencesAndLocalOverrides() async throws {
    let root = temporaryRoot()
    defer { remove(root) }
    let configuration = try await Configuration.load(
      inputRoot: root, localStateRoot: localStateRoot(root))
    await configuration.edit { shared, local in
      shared = ManifestDocument(
        names: ["old": PackageFields(url: .value(remote))],
        order: [
          .named("old"), .userFiles(FileFilter()),
          .named("old", overrides: PackageFields(recipe: .reset)),
        ])
      local = LocalOverridesDocument(names: ["old": PackageFields(ref: .value("dev"))])
    }
    try await configuration.renamePackage("old", to: "new")
    let renamed = await configuration.snapshot()
    #expect(renamed.manifest.names["old"] == nil)
    #expect(renamed.localOverrides?.names["new"]?.ref == .value("dev"))
    #expect(renamed.manifest.order[0] == .named("new"))
    #expect(renamed.manifest.order[2] == .named("new", overrides: PackageFields(recipe: .reset)))
    await #expect(throws: PinewindError.self) { try await configuration.removePackage("new") }
    try await configuration.edit { shared, _ in try shared.moveEntry(from: 2, to: 0) }
    let moved = await configuration.snapshot()
    #expect(moved.manifest.order[0] == .named("new", overrides: PackageFields(recipe: .reset)))
    await configuration.edit { _, local in local?.names["taken"] = PackageFields() }
    await #expect(throws: PinewindError.self) {
      try await configuration.renamePackage("new", to: "taken")
    }
    await #expect(throws: PinewindError.self) {
      try await configuration.renamePackage("new", to: "self")
    }
    await #expect(throws: PinewindError.self) {
      try await configuration.edit { shared, _ in try shared.moveEntry(from: -1, to: 0) }
    }
    let unchanged = await configuration.snapshot()
    #expect(unchanged.manifest == moved.manifest)
    await configuration.edit { shared, _ in shared.order = [] }
    try await configuration.removePackage("new")
    let removed = await configuration.snapshot()
    #expect(removed.localOverrides?.names["new"] == nil)
  }

  @Test func savingKeepsLayersSeparateAndUpdatesBaselines() async throws {
    let root = temporaryRoot()
    defer { remove(root) }
    let configuration = try await Configuration.load(
      inputRoot: root, localStateRoot: localStateRoot(root))
    #expect(!FileManager.default.fileExists(atPath: root.path))
    let initial = try await configuration.evaluateShared()
    #expect(initial.entries == [.userFiles(FileFilter())])
    await configuration.edit { shared, local in
      shared = ManifestDocument(
        names: ["emoji": PackageFields(url: .value(remote), ref: .value("main"))],
        order: [.named("emoji")])
      local = LocalOverridesDocument(names: [
        "emoji": PackageFields(url: .value(root.appendingPathComponent("package")))
      ])
    }
    let shared = try await configuration.evaluateShared()
    let effective = try await configuration.evaluateEffective()
    #expect(effective != shared)
    try await configuration.saveShared()
    #expect(
      !FileManager.default.fileExists(
        atPath: localStateRoot(root).appendingPathComponent("pinewind.local.yaml").path))
    let savedShared = try Data(contentsOf: root.appendingPathComponent("pinewind.yaml"))
    try await configuration.saveLocalOverrides()
    #expect(try Data(contentsOf: root.appendingPathComponent("pinewind.yaml")) == savedShared)
    let reloaded = try await Configuration.load(
      inputRoot: root, localStateRoot: localStateRoot(root))
    let reloadedEffective = try await reloaded.evaluateEffective()
    #expect(reloadedEffective == effective)
    await configuration.edit { _, local in local?.names["emoji"]?.recipe = .value("customize") }
    try await configuration.saveLocalOverrides()
    await configuration.edit { _, local in local = nil }
    try await configuration.saveLocalOverrides()
    let withoutLocal = try await Configuration.load(
      inputRoot: root, localStateRoot: localStateRoot(root))
    let withoutLocalSnapshot = await withoutLocal.snapshot()
    #expect(withoutLocalSnapshot.localOverrides == nil)
    await configuration.edit { shared, _ in shared.names["emoji"]?.ref = .value("dev") }
    try await configuration.saveShared()
    try await configuration.saveShared()
    let saved = try await Configuration.load(inputRoot: root, localStateRoot: localStateRoot(root))
    let savedSnapshot = await saved.snapshot()
    let current = await configuration.snapshot()
    #expect(savedSnapshot.manifest == current.manifest)
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("pinewind.lock").path))
  }

  @Test func staleSessionsDetectCreatedModifiedAndDeletedFiles() async throws {
    let root = temporaryRoot()
    defer { remove(root) }
    var first = try await Configuration.load(inputRoot: root, localStateRoot: localStateRoot(root))
    var stale = try await Configuration.load(inputRoot: root, localStateRoot: localStateRoot(root))
    try await first.saveShared()
    await #expect(throws: PinewindError.self) { try await stale.saveShared() }
    stale = try await Configuration.load(inputRoot: root, localStateRoot: localStateRoot(root))
    let external = Data("version: 1\norder: []\n".utf8)
    try external.write(to: root.appendingPathComponent("pinewind.yaml"))
    await #expect(throws: PinewindError.self) { try await stale.saveShared() }
    #expect(try Data(contentsOf: root.appendingPathComponent("pinewind.yaml")) == external)
    stale = try await Configuration.load(inputRoot: root, localStateRoot: localStateRoot(root))
    try FileManager.default.removeItem(at: root.appendingPathComponent("pinewind.yaml"))
    await #expect(throws: PinewindError.self) { try await stale.saveShared() }
    first = try await Configuration.load(inputRoot: root, localStateRoot: localStateRoot(root))
    await first.edit { _, local in local = LocalOverridesDocument() }
    try await first.saveLocalOverrides()
    stale = try await Configuration.load(inputRoot: root, localStateRoot: localStateRoot(root))
    try Data("version: 1\nnames: {new: {revision: {ref: dev}}}\n".utf8).write(
      to: localStateRoot(root).appendingPathComponent("pinewind.local.yaml"))
    await stale.edit { _, local in local = nil }
    await #expect(throws: PinewindError.self) { try await stale.saveLocalOverrides() }
  }

  @Test func invalidEditsNeverReplaceSavedConfiguration() async throws {
    let root = temporaryRoot()
    defer { remove(root) }
    let configuration = try await Configuration.load(
      inputRoot: root, localStateRoot: localStateRoot(root))
    try await configuration.saveShared()
    let file = root.appendingPathComponent("pinewind.yaml")
    let original = try Data(contentsOf: file)
    await configuration.edit { shared, _ in shared.order = [.named("missing")] }
    await #expect(throws: PinewindError.self) { try await configuration.saveShared() }
    #expect(try Data(contentsOf: file) == original)
  }

  @Test func editedDocumentFeedsDeploymentWithoutSaving() async throws {
    let root = temporaryRoot()
    defer { remove(root) }
    let input = root.appendingPathComponent("input")
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    try Data("schema: test\n".utf8).write(to: input.appendingPathComponent("test.yaml"))
    try Data("ignored".utf8).write(to: input.appendingPathComponent("scratch.txt"))
    let configuration = try await Configuration.load(
      inputRoot: input, localStateRoot: localStateRoot(input))
    await configuration.edit { shared, _ in
      shared.order = [.userFiles(FileFilter(include: ["*.yaml"]))]
    }
    let effective = try await configuration.evaluateEffective()
    let plan = try CompositionPlanner(snapshotRoot: root.appendingPathComponent("snapshots")).plan(
      effective, inputRoot: input)
    let output = root.appendingPathComponent("output")
    let result = try await Composer().compose(plan, inputRoot: input, outputRoot: output)
    #expect(result.paths.map(\.string) == ["test.yaml"])
    #expect(
      try String(contentsOf: output.appendingPathComponent("test.yaml"), encoding: .utf8)
        == "schema: test\n")
    #expect(
      !FileManager.default.fileExists(atPath: input.appendingPathComponent("pinewind.yaml").path))
  }

  @Test func throwingEditsDiscardBothDraftsAndSnapshotsAreDetached() async throws {
    let root = temporaryRoot()
    defer { remove(root) }
    let configuration = try await Configuration.load(
      inputRoot: root, localStateRoot: localStateRoot(root))
    let before = await configuration.snapshot()
    await #expect(throws: PinewindError.self) {
      try await configuration.edit { shared, local in
        shared.order = []
        local = LocalOverridesDocument()
        throw PinewindError("abort edit")
      }
    }
    let after = await configuration.snapshot()
    #expect(after.manifest == before.manifest)
    #expect(after.localOverrides == before.localOverrides)
    var detached = after.manifest
    detached.order = []
    let current = await configuration.snapshot()
    #expect(current.manifest.order == [.userFiles(FileFilter())])
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }

  @Test func concurrentEditsAndSavesDoNotLoseUpdatesOrRaceBaselines() async throws {
    let root = temporaryRoot()
    defer { remove(root) }
    let configuration = try await Configuration.load(
      inputRoot: root, localStateRoot: localStateRoot(root))
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<32 {
        group.addTask {
          await configuration.edit { shared, local in
            let name = "package-\(index)"
            shared.names[name] = PackageFields(url: .value(remote))
            shared.order.append(.named(name))
            if local == nil { local = LocalOverridesDocument() }
            local?.names[name] = PackageFields(ref: .value("branch-\(index)"))
          }
          try await configuration.saveShared()
          try await configuration.saveLocalOverrides()
        }
      }
      try await group.waitForAll()
    }
    let current = await configuration.snapshot()
    #expect(current.manifest.names.count == 32)
    #expect(current.manifest.order.count == 33)
    #expect(current.localOverrides?.names.count == 32)
    let saved = try await Configuration.load(inputRoot: root, localStateRoot: localStateRoot(root))
    let savedSnapshot = await saved.snapshot()
    #expect(savedSnapshot.manifest == current.manifest)
    #expect(savedSnapshot.localOverrides == current.localOverrides)
    let evaluated = try await configuration.evaluateEffective()
    #expect(evaluated.entries.count == 33)
  }
}
