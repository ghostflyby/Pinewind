// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import PinewindCore

@Suite("Editable configuration documents")
struct ConfigurationDocumentTests {
  private let remote = URL(string: "https://github.com/rime/rime-emoji.git")!

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("pinewind-documents-" + UUID().uuidString)
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
          ref: main
          options: {enabled: "true", count: "123", empty: "", text: "松风"}
      order:
        - emoji
        - self
        - name: emoji
          ref: null
          commit: "0123456789012345678901234567890123456789"
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
    #expect(local.names["emoji"]?.recipe == .clear)
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
      names: {emoji: {ref: main}}
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
    "version: 1\norder: [{self: {}, ref: main}]", "version: 1\norder: [{import: ':x', ref: main}]",
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

  @Test func evaluationDoesNotReportGeneratedLinesAsOriginalSourcePositions() throws {
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
    #expect(original.source == "original.yaml")
    #expect(original.line == 4)
    let document = try ManifestDocument.parse(text, source: "original.yaml")
    let evaluated = try #require(diagnostic { _ = try document.evaluate() })
    #expect(evaluated.message == original.message)
    #expect(evaluated.line == nil)

    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var configuration = try Configuration.load(inputRoot: root)
    configuration.manifest = document
    #expect(try #require(diagnostic { _ = try configuration.evaluateShared() }).line == nil)
    configuration.manifest = ManifestDocument()
    configuration.localOverrides = LocalOverridesDocument(names: ["self": PackageFields()])
    let local = try #require(diagnostic { _ = try configuration.evaluateEffective() })
    #expect(local.source == "pinewind.local.yaml")
    #expect(local.line == nil)
  }

  @Test func removingLocalOverridesIsAllowedWhileSharedDocumentIsIncomplete() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var configuration = try Configuration.load(inputRoot: root)
    configuration.localOverrides = LocalOverridesDocument()
    try configuration.saveLocalOverrides()
    configuration.manifest.order = [.named("unfinished")]
    #expect(throws: PinewindError.self) { try configuration.saveLocalOverrides() }
    configuration.localOverrides = nil
    try configuration.saveLocalOverrides()
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appendingPathComponent("pinewind.local.yaml").path))
    try configuration.saveLocalOverrides()
    #expect(throws: PinewindError.self) { try configuration.evaluateShared() }
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("pinewind.yaml").path))
  }

  @Test func editsCoordinateReferencesAndLocalOverrides() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var configuration = try Configuration.load(inputRoot: root)
    configuration.manifest = ManifestDocument(
      names: ["old": PackageFields(url: .value(remote))],
      order: [
        .named("old"), .userFiles(FileFilter()),
        .named("old", overrides: PackageFields(recipe: .clear)),
      ])
    configuration.localOverrides = LocalOverridesDocument(names: [
      "old": PackageFields(ref: .value("dev"))
    ])
    try configuration.renamePackage("old", to: "new")
    #expect(configuration.manifest.names["old"] == nil)
    #expect(configuration.localOverrides?.names["new"]?.ref == .value("dev"))
    #expect(configuration.manifest.order[0] == .named("new"))
    #expect(
      configuration.manifest.order[2] == .named("new", overrides: PackageFields(recipe: .clear)))
    #expect(throws: PinewindError.self) { try configuration.removePackage("new") }
    try configuration.manifest.moveEntry(from: 2, to: 0)
    #expect(
      configuration.manifest.order[0] == .named("new", overrides: PackageFields(recipe: .clear)))
    let before = configuration.manifest
    configuration.localOverrides?.names["taken"] = PackageFields()
    #expect(throws: PinewindError.self) { try configuration.renamePackage("new", to: "taken") }
    #expect(throws: PinewindError.self) { try configuration.renamePackage("new", to: "self") }
    #expect(throws: PinewindError.self) { try configuration.manifest.moveEntry(from: -1, to: 0) }
    #expect(configuration.manifest == before)
    configuration.manifest.order = []
    try configuration.removePackage("new")
    #expect(configuration.localOverrides?.names["new"] == nil)
  }

  @Test func savingKeepsLayersSeparateAndUpdatesBaselines() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var configuration = try Configuration.load(inputRoot: root)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    #expect(try configuration.evaluateShared().entries == [.userFiles(FileFilter())])
    configuration.manifest = ManifestDocument(
      names: ["emoji": PackageFields(url: .value(remote), ref: .value("main"))],
      order: [.named("emoji")])
    configuration.localOverrides = LocalOverridesDocument(names: [
      "emoji": PackageFields(url: .value(root.appendingPathComponent("package")))
    ])
    let shared = try configuration.evaluateShared()
    #expect(try configuration.evaluateEffective() != shared)
    try configuration.saveShared()
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appendingPathComponent("pinewind.local.yaml").path))
    let savedShared = try Data(contentsOf: root.appendingPathComponent("pinewind.yaml"))
    try configuration.saveLocalOverrides()
    #expect(try Data(contentsOf: root.appendingPathComponent("pinewind.yaml")) == savedShared)
    #expect(
      try Configuration.load(inputRoot: root).evaluateEffective()
        == configuration.evaluateEffective())
    configuration.localOverrides?.names["emoji"]?.recipe = .value("customize")
    try configuration.saveLocalOverrides()
    configuration.localOverrides = nil
    try configuration.saveLocalOverrides()
    #expect(try Configuration.load(inputRoot: root).localOverrides == nil)
    configuration.manifest.names["emoji"]?.ref = .value("dev")
    try configuration.saveShared()
    try configuration.saveShared()
    #expect(try Configuration.load(inputRoot: root).manifest == configuration.manifest)
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("pinewind.lock").path))
  }

  @Test func staleSessionsDetectCreatedModifiedAndDeletedFiles() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var first = try Configuration.load(inputRoot: root)
    var stale = first
    try first.saveShared()
    #expect(throws: PinewindError.self) { try stale.saveShared() }
    stale = try Configuration.load(inputRoot: root)
    let external = Data("version: 1\norder: []\n".utf8)
    try external.write(to: root.appendingPathComponent("pinewind.yaml"))
    #expect(throws: PinewindError.self) { try stale.saveShared() }
    #expect(try Data(contentsOf: root.appendingPathComponent("pinewind.yaml")) == external)
    stale = try Configuration.load(inputRoot: root)
    try FileManager.default.removeItem(at: root.appendingPathComponent("pinewind.yaml"))
    #expect(throws: PinewindError.self) { try stale.saveShared() }
    first = try Configuration.load(inputRoot: root)
    first.localOverrides = LocalOverridesDocument()
    try first.saveLocalOverrides()
    stale = try Configuration.load(inputRoot: root)
    try Data("version: 1\nnames: {new: {ref: dev}}\n".utf8)
      .write(to: root.appendingPathComponent("pinewind.local.yaml"))
    stale.localOverrides = nil
    #expect(throws: PinewindError.self) { try stale.saveLocalOverrides() }
  }

  @Test func invalidEditsNeverReplaceSavedConfiguration() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var configuration = try Configuration.load(inputRoot: root)
    try configuration.saveShared()
    let file = root.appendingPathComponent("pinewind.yaml")
    let original = try Data(contentsOf: file)
    configuration.manifest.order = [.named("missing")]
    #expect(throws: PinewindError.self) { try configuration.saveShared() }
    #expect(try Data(contentsOf: file) == original)
  }

  @Test func editedDocumentFeedsDeploymentWithoutSaving() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("input")
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    try Data("schema: test\n".utf8).write(to: input.appendingPathComponent("test.yaml"))
    try Data("ignored".utf8).write(to: input.appendingPathComponent("scratch.txt"))
    var configuration = try Configuration.load(inputRoot: input)
    configuration.manifest.order = [.userFiles(FileFilter(include: ["*.yaml"]))]
    let plan = try CompositionPlanner(snapshotRoot: root.appendingPathComponent("snapshots")).plan(
      configuration.evaluateEffective(), inputRoot: input)
    let output = root.appendingPathComponent("output")
    let result = try await Composer().compose(plan, inputRoot: input, outputRoot: output)
    #expect(result.paths == ["test.yaml"])
    #expect(
      try String(contentsOf: output.appendingPathComponent("test.yaml"), encoding: .utf8)
        == "schema: test\n")
    #expect(
      !FileManager.default.fileExists(atPath: input.appendingPathComponent("pinewind.yaml").path))
  }
}
