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
    let text = try fixtureText("Configuration/round-trip.yaml")
    let document = try ManifestDocument.parse(text)
    #expect(document.order.count == 6)
    #expect(document.names["emoji"]?.url == .value(remote))
    #expect(
      document.names["emoji"]?.options
        == .value([
          "enabled": "true", "count": "123", "empty": "", "text": "松风",
        ]))
    #expect(try ManifestDocument.parse(document.yaml()) == document)
  }

  @Test func localFieldsPreserveNullOmissionAndWholeMapReplacement() throws {
    let shared = ManifestDocument(
      names: [
        "emoji": PackageFields(
          url: .value(remote), revision: .value(.reference("main")), recipe: .value("customize"),
          options: .value(["a": "1", "b": "2"]), include: .value(["*.yaml"]))
      ],
      order: [.named("emoji")])
    let local = try LocalOverridesDocument.parse(fixtureText("Configuration/local-overrides.yaml"))
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
    #expect(request.revision == .reference("main"))
  }

  @Test func localRedirectClearsInheritedVersionButNotExplicitSelectors() throws {
    let document = ManifestDocument(
      names: ["emoji": PackageFields(url: .value(remote), revision: .value(.reference("main")))],
      order: [.named("emoji")])
    let directory = temporaryRoot()
    let local = LocalOverridesDocument(names: ["emoji": PackageFields(url: .value(directory))])
    let effective = try document.evaluate(localOverrides: local)
    #expect(effective.entries == [.package(try PackageRequest(url: directory))])
    #expect(throws: PinewindError.self) {
      try document.evaluate(
        localOverrides: LocalOverridesDocument(names: [
          "emoji": PackageFields(url: .value(directory), revision: .value(.reference("main")))
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
    #expect(try ManifestDocument.parse(document.yaml()) == document)
    document.names["emoji"]?.url = .value(remote)
    #expect(try document.evaluate().entries.count == 1)
    #expect(throws: PinewindError.self) {
      try ManifestDocument(order: [.named("emoji", overrides: PackageFields(url: .value(remote)))])
        .yaml()
    }
  }

  @Test(arguments: [
    PackageFields(url: .value(URL(string: "relative")!)),
    PackageFields(
      url: .value(URL(fileURLWithPath: "/package")), revision: .value(.branch("main"))),
    PackageFields(revision: .value(.reference(""))),
    PackageFields(include: .value(["../escape"])),
  ])
  func invalidDraftFieldsAreRejectedConsistently(_ fields: PackageFields) {
    let document = ManifestDocument(names: ["unused": fields], order: [])
    #expect(throws: PinewindError.self) { _ = try document.evaluate() }
    #expect(throws: PinewindError.self) { _ = try document.yaml() }
    #expect(throws: PinewindError.self) {
      _ = try LocalOverridesDocument(names: ["unused": fields]).yaml()
    }
  }

  @Test(arguments: [
    "order: [self]",
    "version: 2\norder: []",
    "version: 1\norder: []\norder: []",
    "version: 1\norder: [{self: {}, revision: {ref: main}}]",
    "version: 1\norder: [{import: ':x', revision: {ref: main}}]",
    "version: 1\nnames: {self: {}}\norder: []",
    "version: 1\nnames: {a: {options: {x: true}}}\norder: []",
    "version: 1\norder: [{name: a, variables: {}}]",
    "version: 1\nnames: {a: {unknown: x}}\norder: []",
    "version: true\norder: [self]",
    "version: \"1\"\norder: [self]",
    "version: 2\norder: [self]",
    "version: 1\nversion: 1\norder: [self]",
    "version: 1\nunknown: value\norder: [self]",
    "version: 1\norder: [{url: https://github.com/rime/rime-emoji, name: emoji}]",
    "version: 1\norder: [{url: https://github.com/rime/rime-emoji, options: {schema: true}}]",
    "version: 1\norder: [self]\n---\nversion: 1\norder: []",
    "version: 1\nnames: {unused: {url: true}}\norder: []",
  ])
  func malformedDocumentsAreRejected(_ text: String) {
    #expect(throws: PinewindError.self) {
      _ = try ManifestDocument.parse(text, source: "original.yaml")
    }
  }

  @Test func evaluationDoesNotReportGeneratedLinesAsOriginalSourcePositions() async throws {
    let text = """
      # Original layout
      version: 1
      order:
        - missing
      """
    let document = try ManifestDocument.parse(text, source: "original.yaml")
    let evaluated = try #require(diagnostic { _ = try document.evaluate() })
    #expect(evaluated.code == .invalidConfiguration)
    #expect(evaluated.source == nil)
    #expect(evaluated.line == nil)

    let root = temporaryRoot()
    defer { remove(root) }
    let configuration = try await loadConfiguration(
      inputRoot: root, localStateRoot: localStateRoot(root))
    await configuration.edit { draft in draft.manifest = document }
    do {
      _ = try await configuration.snapshot().evaluate(.shared)
      Issue.record("expected evaluation error")
    } catch let error as PinewindError { #expect(error.line == nil) }
    await configuration.edit { draft in
      draft.manifest = ManifestDocument()
      draft.localOverrides = LocalOverridesDocument(names: ["self": PackageFields()])
    }
    do {
      _ = try await configuration.snapshot().evaluate(.effective)
      Issue.record("expected local evaluation error")
    } catch let error as PinewindError {
      #expect(error.source == "pinewind.local.yaml")
      #expect(error.line == nil)
    }
  }

  @Test func removingLocalOverridesIsAllowedWhileSharedDocumentIsIncomplete() async throws {
    let root = temporaryRoot()
    defer { remove(root) }
    let configuration = try await loadConfiguration(
      inputRoot: root, localStateRoot: localStateRoot(root))
    await configuration.edit { draft in draft.localOverrides = LocalOverridesDocument() }
    _ = try await configuration.save(.local)
    await configuration.edit { draft in draft.manifest.order = [.named("unfinished")] }
    await #expect(throws: PinewindError.self) { _ = try await configuration.save(.local) }
    await configuration.edit { draft in draft.localOverrides = nil }
    _ = try await configuration.save(.local)
    #expect(
      !FileManager.default.fileExists(
        atPath: localStateRoot(root).appendingPathComponent("pinewind.local.yaml").path))
    _ = try await configuration.save(.local)
    await #expect(throws: PinewindError.self) {
      try await configuration.snapshot().evaluate(.shared)
    }
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("pinewind.yaml").path))
  }

  @Test func editsCoordinateReferencesAndLocalOverrides() async throws {
    let root = temporaryRoot()
    defer { remove(root) }
    let configuration = try await loadConfiguration(
      inputRoot: root, localStateRoot: localStateRoot(root))
    await configuration.edit { draft in
      draft.manifest = ManifestDocument(
        names: ["old": PackageFields(url: .value(remote))],
        order: [
          .named("old"), .userFiles(FileFilter()),
          .named("old", overrides: PackageFields(recipe: .reset)),
        ])
      draft.localOverrides = LocalOverridesDocument(names: [
        "old": PackageFields(revision: .value(.reference("dev")))
      ])
    }
    try await configuration.edit { try $0.renamePackage("old", to: "new") }
    let renamed = await configuration.snapshot()
    #expect(renamed.manifest.names["old"] == nil)
    #expect(renamed.localOverrides?.names["new"]?.revision == .value(.reference("dev")))
    #expect(renamed.manifest.order[0] == .named("new"))
    #expect(renamed.manifest.order[2] == .named("new", overrides: PackageFields(recipe: .reset)))
    await #expect(throws: PinewindError.self) {
      try await configuration.edit { try $0.removePackage("new") }
    }
    try await configuration.edit { draft in try draft.manifest.moveEntry(from: 2, to: 0) }
    let moved = await configuration.snapshot()
    #expect(moved.manifest.order[0] == .named("new", overrides: PackageFields(recipe: .reset)))
    await configuration.edit { draft in draft.localOverrides?.names["taken"] = PackageFields() }
    await #expect(throws: PinewindError.self) {
      try await configuration.edit { try $0.renamePackage("new", to: "taken") }
    }
    await #expect(throws: PinewindError.self) {
      try await configuration.edit { try $0.renamePackage("new", to: "self") }
    }
    await #expect(throws: PinewindError.self) {
      try await configuration.edit { draft in try draft.manifest.moveEntry(from: -1, to: 0) }
    }
    let unchanged = await configuration.snapshot()
    #expect(unchanged.manifest == moved.manifest)
    await configuration.edit { draft in draft.manifest.order = [] }
    try await configuration.edit { try $0.removePackage("new") }
    let removed = await configuration.snapshot()
    #expect(removed.localOverrides?.names["new"] == nil)
  }

  @Test func savingKeepsLayersSeparateAndUpdatesBaselines() async throws {
    let root = temporaryRoot()
    defer { remove(root) }
    let configuration = try await loadConfiguration(
      inputRoot: root, localStateRoot: localStateRoot(root))
    #expect(!FileManager.default.fileExists(atPath: root.path))
    let initial = try await configuration.snapshot().evaluate(.shared)
    #expect(initial.entries == [.userFiles(FileFilter())])
    await configuration.edit { draft in
      draft.manifest = ManifestDocument(
        names: ["emoji": PackageFields(url: .value(remote), revision: .value(.reference("main")))],
        order: [.named("emoji")])
      draft.localOverrides = LocalOverridesDocument(names: [
        "emoji": PackageFields(url: .value(root.appendingPathComponent("package")))
      ])
    }
    let shared = try await configuration.snapshot().evaluate(.shared)
    let effective = try await configuration.snapshot().evaluate(.effective)
    #expect(effective != shared)
    _ = try await configuration.save(.shared)
    #expect(
      !FileManager.default.fileExists(
        atPath: localStateRoot(root).appendingPathComponent("pinewind.local.yaml").path))
    let savedShared = try Data(contentsOf: root.appendingPathComponent("pinewind.yaml"))
    _ = try await configuration.save(.local)
    #expect(try Data(contentsOf: root.appendingPathComponent("pinewind.yaml")) == savedShared)
    let reloaded = try await loadConfiguration(
      inputRoot: root, localStateRoot: localStateRoot(root))
    let reloadedEffective = try await reloaded.snapshot().evaluate(.effective)
    #expect(reloadedEffective == effective)
    await configuration.edit { draft in
      draft.localOverrides?.names["emoji"]?.recipe = .value("customize")
    }
    _ = try await configuration.save(.local)
    await configuration.edit { draft in draft.localOverrides = nil }
    _ = try await configuration.save(.local)
    let withoutLocal = try await loadConfiguration(
      inputRoot: root, localStateRoot: localStateRoot(root))
    let withoutLocalSnapshot = await withoutLocal.snapshot()
    #expect(withoutLocalSnapshot.localOverrides == nil)
    await configuration.edit { draft in
      draft.manifest.names["emoji"]?.revision = .value(.reference("dev"))
    }
    _ = try await configuration.save(.shared)
    _ = try await configuration.save(.shared)
    let saved = try await loadConfiguration(inputRoot: root, localStateRoot: localStateRoot(root))
    let savedSnapshot = await saved.snapshot()
    let current = await configuration.snapshot()
    #expect(savedSnapshot.manifest == current.manifest)
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("pinewind.lock").path))
  }

  @Test func staleSessionsDetectCreatedModifiedAndDeletedFiles() async throws {
    let root = temporaryRoot()
    defer { remove(root) }
    var first = try await loadConfiguration(inputRoot: root, localStateRoot: localStateRoot(root))
    var stale = try await loadConfiguration(inputRoot: root, localStateRoot: localStateRoot(root))
    _ = try await first.save(.shared)
    await #expect(throws: PinewindError.self) { _ = try await stale.save(.shared) }
    stale = try await loadConfiguration(inputRoot: root, localStateRoot: localStateRoot(root))
    let external = Data("version: 1\norder: []\n".utf8)
    try external.write(to: root.appendingPathComponent("pinewind.yaml"))
    await #expect(throws: PinewindError.self) { _ = try await stale.save(.shared) }
    #expect(try Data(contentsOf: root.appendingPathComponent("pinewind.yaml")) == external)
    stale = try await loadConfiguration(inputRoot: root, localStateRoot: localStateRoot(root))
    try FileManager.default.removeItem(at: root.appendingPathComponent("pinewind.yaml"))
    await #expect(throws: PinewindError.self) { _ = try await stale.save(.shared) }
    first = try await loadConfiguration(inputRoot: root, localStateRoot: localStateRoot(root))
    await first.edit { draft in draft.localOverrides = LocalOverridesDocument() }
    _ = try await first.save(.local)
    stale = try await loadConfiguration(inputRoot: root, localStateRoot: localStateRoot(root))
    try Data("version: 1\nnames: {new: {revision: {ref: dev}}}\n".utf8).write(
      to: localStateRoot(root).appendingPathComponent("pinewind.local.yaml"))
    await stale.edit { draft in draft.localOverrides = nil }
    await #expect(throws: PinewindError.self) { _ = try await stale.save(.local) }
  }

  @Test func invalidEditsNeverReplaceSavedConfiguration() async throws {
    let root = temporaryRoot()
    defer { remove(root) }
    let configuration = try await loadConfiguration(
      inputRoot: root, localStateRoot: localStateRoot(root))
    _ = try await configuration.save(.shared)
    let file = root.appendingPathComponent("pinewind.yaml")
    let original = try Data(contentsOf: file)
    await configuration.edit { draft in draft.manifest.order = [.named("missing")] }
    await #expect(throws: PinewindError.self) { _ = try await configuration.save(.shared) }
    #expect(try Data(contentsOf: file) == original)
  }

  @Test func editedDocumentFeedsDeploymentWithoutSaving() async throws {
    let root = temporaryRoot()
    defer { remove(root) }
    let input = root.appendingPathComponent("input")
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    try Data("schema: test\n".utf8).write(to: input.appendingPathComponent("test.yaml"))
    try Data("ignored".utf8).write(to: input.appendingPathComponent("scratch.txt"))
    let configuration = try await loadConfiguration(
      inputRoot: input, localStateRoot: localStateRoot(input))
    await configuration.edit { draft in
      draft.manifest.order = [.userFiles(FileFilter(include: ["*.yaml"]))]
    }
    let effective = try await configuration.snapshot().evaluate(.effective)
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
    let configuration = try await loadConfiguration(
      inputRoot: root, localStateRoot: localStateRoot(root))
    let before = await configuration.snapshot()
    await #expect(throws: PinewindError.self) {
      try await configuration.edit { draft in
        draft.manifest.order = []
        draft.localOverrides = LocalOverridesDocument()
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
    let configuration = try await loadConfiguration(
      inputRoot: root, localStateRoot: localStateRoot(root))
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<32 {
        group.addTask {
          await configuration.edit { draft in
            let name = "package-\(index)"
            draft.manifest.names[name] = PackageFields(url: .value(remote))
            draft.manifest.order.append(.named(name))
            if draft.localOverrides == nil { draft.localOverrides = LocalOverridesDocument() }
            draft.localOverrides?.names[name] = PackageFields(
              revision: .value(.reference("branch-\(index)")))
          }
          _ = try await configuration.save(.shared)
          _ = try await configuration.save(.local)
        }
      }
      try await group.waitForAll()
    }
    let current = await configuration.snapshot()
    #expect(current.manifest.names.count == 32)
    #expect(current.manifest.order.count == 33)
    #expect(current.localOverrides?.names.count == 32)
    let saved = try await loadConfiguration(inputRoot: root, localStateRoot: localStateRoot(root))
    let savedSnapshot = await saved.snapshot()
    #expect(savedSnapshot.manifest == current.manifest)
    #expect(savedSnapshot.localOverrides == current.localOverrides)
    let evaluated = try await configuration.snapshot().evaluate(.effective)
    #expect(evaluated.entries.count == 33)
  }
}
