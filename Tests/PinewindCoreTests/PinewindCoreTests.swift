// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BashInterpreter
import Foundation
import SystemPackage
import Testing

@testable import PinewindCore

private struct Fixture {
  let root: URL
  var input: URL { root.appendingPathComponent("input") }
  var output: URL { root.appendingPathComponent("output") }
  var a: URL { root.appendingPathComponent("a") }
  var b: URL { root.appendingPathComponent("b") }

  init(_ name: String? = nil) throws {
    root = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
      .appendingPathComponent(
        "pinewind-test-" + UUID().uuidString)
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    do {
      if let name {
        guard let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
          throw FileSystemFailure.notFound(FilePath("Fixtures"))
        }
        let source = fixtures.appendingPathComponent(name)
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
          try fm.copyItem(at: item, to: root.appendingPathComponent(item.lastPathComponent))
        }
      }
      for directory in [input, a, b] {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      }
    } catch {
      try? fm.removeItem(at: root)
      throw error
    }
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
  func write(_ path: String, _ contents: String, in directory: URL) throws {
    let file = directory.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: file)
  }
  func read(_ path: String) throws -> String {
    try String(contentsOf: output.appendingPathComponent(path), encoding: .utf8)
  }
  func request(_ directory: URL, recipe: String? = nil) throws -> PackageRequest {
    try PackageRequest(url: directory, recipe: recipe)
  }
  func plan(_ entries: [ManifestEntry], packages: [PreparedPackage] = []) throws -> CompositionPlan
  {
    try CompositionPlanner(snapshotRoot: root.appendingPathComponent("snapshots")).plan(
      Manifest(entries: entries), inputRoot: input, packages: packages)
  }
}

@Suite("Pinewind configuration")
struct ConfigurationTests {
  @Test func missingPackageDefinitionCannotBeEvaluated() throws {
    let document = try ManifestDocument.parse("version: 1\norder: [missing]")
    #expect(throws: DeclarationFailure.self) { _ = try document.evaluate() }
  }

  @Test func mergesFieldsAndClearsWithoutDeepMergingOptions() throws {
    let yaml = """
      version: 1
      names:
        emoji:
          url: https://github.com/rime/rime-emoji.git
          revision: {ref: master}
          recipe: customize
          options: {schema: old, other: value}
      order:
        - name: emoji
          options: {schema: new}
      """
    let local = """
      version: 1
      names:
        emoji:
          revision: null
          recipe: null
      """
    let manifest = try ManifestDocument.parse(yaml).evaluate(
      localOverrides: LocalOverridesDocument.parse(local))
    guard case .package(let request) = try #require(manifest.entries.first) else {
      Issue.record("expected package")
      return
    }
    #expect(request.url.absoluteString == "https://github.com/rime/rime-emoji")
    #expect(request.revision == .defaultBranch)
    #expect(request.recipe == nil)
    #expect(request.options == ["schema": "new"])
  }

  @Test func localWorkingTreeIgnoresInheritedRefAndNeverWritesLock() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.write(
      "pinewind.yaml",
      """
      version: 1
      names:
        dev: {url: https://github.com/rime/rime-emoji, revision: {ref: master}}
      order: [dev, self]
      """, in: fixture.input)
    try fixture.write(
      "pinewind.local.yaml",
      """
      version: 1
      names:
        dev: {url: \(fixture.a.absoluteString)}
      """, in: fixture.root.appendingPathComponent("state"))
    let manifest = try await loadConfiguration(
      inputRoot: fixture.input, localStateRoot: fixture.root.appendingPathComponent("state")
    ).snapshot().evaluate()
    guard case .package(let request) = manifest.entries[0] else {
      Issue.record("expected package")
      return
    }
    #expect(request.url == fixture.a)
    #expect(request.revision == nil)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.input.appendingPathComponent("pinewind.lock").path))
  }

  @Test func missingManifestDefaultsToSelfAndEmptyOrderStaysEmpty() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    #expect(
      try await loadConfiguration(
        inputRoot: fixture.input, localStateRoot: fixture.root.appendingPathComponent("state")
      ).snapshot().evaluate().entries == [.userFiles(FileFilter())])
    #expect(try ManifestDocument.parse("version: 1\norder: []").evaluate().entries.isEmpty)
  }

  @Test(arguments: ["ref", "commit"])
  func localSourcesRejectExplicitVersionsButClearInheritedVersions(_ key: String) throws {
    let f = try Fixture()
    defer { f.remove() }
    let value = key == "ref" ? "master" : String(repeating: "a", count: 40)
    #expect(throws: DeclarationFailure.self) {
      try PackageRequest(
        url: f.a, revision: key == "ref" ? .reference(value) : .commit(CommitID(value)))
    }
    let remote = """
      version: 1
      names:
        dev: {url: https://github.com/rime/rime-emoji, revision: {\(key): \(value)}}
      order: [dev]
      """
    let override = "version: 1\nnames: {dev: {url: \(f.a.absoluteString)}}"
    guard
      case .package(let local) = try ManifestDocument.parse(remote).evaluate(
        localOverrides: LocalOverridesDocument.parse(override)
      ).entries[0]
    else {
      Issue.record("expected a local package")
      return
    }
    #expect(local.url == f.a && local.revision == nil)
    for yaml in [
      "version: 1\norder: [{url: \(f.a.absoluteString), revision: {\(key): \(value)}}]",
      "version: 1\nnames: {dev: {url: \(f.a.absoluteString), revision: {\(key): \(value)}}}\norder: [dev]",
      "version: 1\nnames: {dev: {url: \(f.a.absoluteString)}}\norder: [{name: dev, revision: {\(key): \(value)}}]",
    ] {
      #expect { try ManifestDocument.parse(yaml).evaluate() } throws: { error in
        if let direct = error as? DeclarationFailure { return direct == .revisionWithFileSource }
        guard case .configuration(let document) = error as? PinewindError else { return false }
        return document.underlyingError as? DeclarationFailure == .revisionWithFileSource
      }
    }
    #expect(throws: PinewindError.self) {
      try ManifestDocument.parse(remote).evaluate(
        localOverrides: LocalOverridesDocument.parse(
          "version: 1\nnames: {dev: {url: \(f.a.absoluteString), revision: {\(key): \(value)}}}"))
    }
  }

  @Test func localVersionIsRequired() {
    #expect(throws: PinewindError.self) {
      try ManifestDocument.parse("version: 1\norder: [self]").evaluate(
        localOverrides: LocalOverridesDocument.parse("names: {}"))
    }
  }

  @Test func diagnosticReportsTheCorrectLine() {
    do {
      _ = try ManifestDocument.parse("version: 1\norder: []\nbad: true", source: "fixture.yaml")
        .evaluate()
      Issue.record("expected diagnostic")
    } catch let error as PinewindError {
      guard case .configuration(let document) = error else {
        Issue.record("expected a document verdict: \(error)")
        return
      }
      #expect(document.context.path == FilePath("fixture.yaml"))
      #expect(document.context.placement?.line == 3)
    } catch { Issue.record("unexpected error: \(error)") }
  }
}

@Suite("Pinewind composition")
struct CompositionTests {
  @Test func plansFreezeFilesAndRecipesAndReleaseDiskSnapshots() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("words.txt", "before", in: f.a)
    try f.write(
      "recipe.yaml", "install_files: [words.txt]\npatch_files: {custom.yaml: [{value: before}]}",
      in: f.a)
    let entries: [ManifestEntry] = [.package(try f.request(f.a)), .package(try f.request(f.a))]
    var plan: CompositionPlan? = try f.plan(entries)
    let operations = try #require(plan?.files[RelativePath("words.txt")])
    guard case .write(let frozen) = operations[0].action,
      case .write(let repeated) = operations[1].action
    else {
      Issue.record("expected frozen file references")
      return
    }
    #expect(frozen == repeated)
    #expect(operations[0].source == f.a.appendingPathComponent("words.txt"))
    // Mutate the original inode: an unsafe hard-link snapshot would also change.
    let handle = try FileHandle(forWritingTo: f.a.appendingPathComponent("words.txt"))
    try handle.write(contentsOf: Data("after!".utf8))
    try handle.close()
    try f.write(
      "recipe.yaml", "install_files: [words.txt]\npatch_files: {custom.yaml: [{value: after}]}",
      in: f.a)
    let composer = Composer()
    _ = try await composer.compose(try #require(plan), inputRoot: f.input, outputRoot: f.output)
    #expect(try f.read("words.txt") == "before")
    #expect(try f.read("custom.yaml").contains("value: before"))
    plan = nil
    #expect(!FileManager.default.fileExists(atPath: frozen.removingLastComponent().string))
    _ = try await composer.compose(f.plan(entries), inputRoot: f.input, outputRoot: f.output)
    #expect(try f.read("words.txt") == "after!")
    #expect(try f.read("custom.yaml").contains("value: after"))
  }

  @Test func composesLargeDictionariesFromFileReferences() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let size: UInt64 = 64 * 1_024 * 1_024
    for index in 0..<4 {
      let file = f.a.appendingPathComponent("dict\(index).txt")
      #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
      let handle = try FileHandle(forWritingTo: file)
      try handle.truncate(atOffset: size)
      try handle.seek(toOffset: size - 1)
      try handle.write(contentsOf: Data([UInt8(index + 1)]))
      try handle.close()
    }
    let plan = try f.plan([.package(f.request(f.a))])
    let composer = Composer()
    _ = try await composer.compose(plan, inputRoot: f.input, outputRoot: f.output)
    for index in 0..<4 {
      let handle = try FileHandle(
        forReadingFrom: f.output.appendingPathComponent("dict\(index).txt"))
      #expect(try handle.seekToEnd() == size)
      try handle.seek(toOffset: size - 1)
      #expect(try handle.read(upToCount: 1) == Data([UInt8(index + 1)]))
      try handle.close()
    }
    let unchanged = try await composer.compose(plan, inputRoot: f.input, outputRoot: f.output)
    #expect(unchanged.changedPaths.isEmpty && unchanged.reusedPaths.count == 4)
  }

  @Test func foldedInstallFilesSelectMultiplePatterns() async throws {
    let f = try Fixture("FoldedInstall")
    defer { f.remove() }
    let plan = try f.plan([.package(f.request(f.a))])
    #expect(plan.paths.map(\.string) == ["opencc/emoji.txt", "schemas/test.yaml"])
    _ = try await Composer().compose(plan, inputRoot: f.input, outputRoot: f.output)
    #expect(try f.read("opencc/emoji.txt") == "emoji\n")
  }

  @Test func patchesCreateMissingTargetsAndParentDirectories() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write(
      "recipe.yaml", "patch_files: {nested/test.custom.yaml: [{schema: test}]}", in: f.a)
    let plan = try f.plan([.package(f.request(f.a))])
    #expect(plan.paths.map(\.string) == ["nested/test.custom.yaml"])
    _ = try await Composer().compose(plan, inputRoot: f.input, outputRoot: f.output)
    let text = try f.read("nested/test.custom.yaml")
    #expect(text.hasPrefix("__patch:\n"))
    #expect(text.contains("schema: test"))
  }

  @Test func explicitEmptyOptionsExpandWithoutDefaultsAndUseColonDefaults() throws {
    for template in ["${value}", "$value"] {
      #expect(try Template.expand(template, options: ["value": ""], declared: ["value"]) == "")
    }
    for options in [["value": ""], [:]] {
      #expect(
        try Template.expand("${value:-default}", options: options, declared: ["value"]) == "default"
      )
    }
    #expect(throws: DeclarationFailure.optionValueMissing("value")) {
      try Template.expand("${value}", options: [:], declared: ["value"])
    }
  }

  @Test func copiesArbitrarySelfStructureAndExcludesMetadata() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("lua/helper.lua", "return 1", in: f.input)
    try f.write("nested/table.txt", "table", in: f.input)
    try f.write("pinewind.yaml", "version: 1\norder: [self]", in: f.input)
    try f.write("pinewind.lock", "private", in: f.input)
    try f.write(".git/config", "git", in: f.input)
    try f.write("scratch.local.yaml", "local", in: f.input)
    let plan = try f.plan([.userFiles(FileFilter())])
    let result = try await Composer().compose(plan, inputRoot: f.input, outputRoot: f.output)
    #expect(result.paths.map(\.string) == ["lua/helper.lua", "nested/table.txt"])
    #expect(try f.read("lua/helper.lua") == "return 1")
  }

  @Test func whitelistIncludesOcd2AndDoesNotRecursivelyInstallLua() throws {
    let f = try Fixture()
    defer { f.remove() }
    for path in [
      "default.yaml", "test.custom.yaml", "recipe.recipe.yaml", "words.txt", "model.gram",
      "opencc/data.ocd2", "opencc/nested/data.txt", "lua/a.lua",
    ] {
      try f.write(path, "data", in: f.a)
    }
    let plan = try f.plan([.package(f.request(f.a))])
    #expect(
      plan.paths.map(\.string) == ["default.yaml", "model.gram", "opencc/data.ocd2", "words.txt"])
  }

  @Test func uninstallRestoresEarlierProviderAndReorderChangesWinner() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("default.yaml", "source: A\n", in: f.a)
    try f.write("default.yaml", "source: B\n", in: f.b)
    let a = try ManifestEntry.package(f.request(f.a))
    let b = try ManifestEntry.package(f.request(f.b))
    let composer = Composer()
    let both = try f.plan([a, b])
    #expect(try both.files[RelativePath("default.yaml")]?.count == 2)
    _ = try await composer.compose(both, inputRoot: f.input, outputRoot: f.output)
    #expect(try f.read("default.yaml") == "source: B\n")
    _ = try await composer.compose(f.plan([a]), inputRoot: f.input, outputRoot: f.output)
    #expect(try f.read("default.yaml") == "source: A\n")
    _ = try await composer.compose(f.plan([b, a]), inputRoot: f.input, outputRoot: f.output)
    #expect(try f.read("default.yaml") == "source: A\n")
  }

  @Test func localEditChangesOutputAndUnchangedRunDoesNotRepublish() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("default.yaml", "value: old\n", in: f.a)
    let entries = try [ManifestEntry.package(f.request(f.a))]
    let composer = Composer()
    _ = try await composer.compose(f.plan(entries), inputRoot: f.input, outputRoot: f.output)
    let file = f.output.appendingPathComponent("default.yaml")
    let sentinel = Date(timeIntervalSince1970: 946_684_800)
    try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: file.path)
    let unchanged = try await composer.compose(
      f.plan(entries), inputRoot: f.input, outputRoot: f.output)
    let after =
      try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    #expect(unchanged.changedPaths.isEmpty)
    #expect(unchanged.reusedPaths.map(\.string) == ["default.yaml"])
    #expect(after == sentinel)
    try f.write("default.yaml", "value: new\n", in: f.a)
    let changed = try await composer.compose(
      f.plan(entries), inputRoot: f.input, outputRoot: f.output)
    #expect(changed.changedPaths.map(\.string) == ["default.yaml"])
    #expect(try f.read("default.yaml") == "value: new\n")
  }

  @Test func crlfPatchMarkersAreReplacedAndLineEndingsArePreserved() throws {
    let original = Data("__patch:\r\n# Rx: demo {\r\n  - old: true\r\n# }\r\n".utf8)
    let bytes = try PatchRenderer.apply(original, rx: "demo", body: "- new: true")
    let text = try #require(String(data: bytes, encoding: .utf8))
    #expect(!text.contains("old: true"))
    #expect(text.components(separatedBy: "# Rx:").count == 2)
    #expect(text.contains("  - new: true\r\n"))
    #expect(try PatchRenderer.apply(bytes, rx: "demo", body: "- new: true") == bytes)
  }

  @Test func compositionRejectsFilesystemRootAndCaseAliases() throws {
    let f = try Fixture()
    defer { f.remove() }
    #expect(throws: FileSystemFailure.self) {
      try SafePath.validateRoots(input: f.input, output: URL(fileURLWithPath: "/"), sources: [])
    }
    let alias = URL(fileURLWithPath: f.input.path.uppercased())
    if FileManager.default.fileExists(atPath: alias.path) {
      #expect(throws: FileSystemFailure.self) {
        try SafePath.validateRoots(
          input: f.input, output: alias.appendingPathComponent("out"), sources: [])
      }
    }
    #if os(Windows)
      try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: true)
      try f.write("keep.txt", "keep", in: f.output)
      #expect(throws: FileSystemFailure.self) { try WindowsDirectoryPublisher.validate(f.output) }
      #expect(try f.read("keep.txt") == "keep")
    #endif
  }

  @Test func publishingNeverRemovesTheVisibleGeneration() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let composer = Composer()
    let entries = [ManifestEntry.userFiles(FileFilter())]
    try f.write("default.yaml", "value: a\n", in: f.input)
    _ = try await composer.compose(f.plan(entries), inputRoot: f.input, outputRoot: f.output)
    let file = f.output.appendingPathComponent("default.yaml")
    let reader = Task.detached { () -> (failures: [String], reads: Int) in
      var failures: [String] = []
      var reads = 0
      while !Task.isCancelled {
        do {
          let value = try String(contentsOf: file, encoding: .utf8)
          reads += 1
          if value != "value: a\n" && value != "value: b\n" { failures.append(value) }
        } catch { failures.append(String(describing: error)) }
        await Task.yield()
      }
      return (failures, reads)
    }
    defer { reader.cancel() }
    for index in 0..<20 {
      try f.write(
        "default.yaml", index.isMultiple(of: 2) ? "value: b\n" : "value: a\n", in: f.input)
      _ = try await composer.compose(f.plan(entries), inputRoot: f.input, outputRoot: f.output)
    }
    reader.cancel()
    let observations = await reader.value
    #expect(observations.reads > 0)
    #expect(observations.failures.isEmpty)
  }

  #if os(Windows)
    @Test func independentComposersKeepPublishedAndPendingGenerations() async throws {
      let f = try Fixture()
      defer { f.remove() }
      let entries = [ManifestEntry.userFiles(FileFilter())]
      let bytesA = String(repeating: "a", count: 256 * 1024)
      let bytesB = String(repeating: "b", count: 256 * 1024)
      for index in 0..<8 { try f.write("dicts/\(index).txt", bytesA, in: f.input) }
      let planA = try f.plan(entries)
      for index in 0..<8 { try f.write("dicts/\(index).txt", bytesB, in: f.input) }
      let planB = try f.plan(entries)
      _ = try await Composer().compose(planA, inputRoot: f.input, outputRoot: f.output)
      try await withThrowingTaskGroup(of: Void.self) { group in
        for plan in [planA, planB] {
          group.addTask {
            let composer = Composer()
            for _ in 0..<20 {
              _ = try await composer.compose(plan, inputRoot: f.input, outputRoot: f.output)
            }
          }
        }
        try await group.waitForAll()
      }
      let first = try f.read("dicts/0.txt")
      #expect(first == bytesA || first == bytesB)
      for index in 1..<8 { #expect(try f.read("dicts/\(index).txt") == first) }
      let active = try #require(try WindowsDirectoryPublisher.currentTarget(f.output))
      #expect(FileManager.default.fileExists(atPath: active.string))
    }

    @Test(arguments: ["https://example.com/output", "file:///C:/bad%00path"])
    func malformedJunctionPathsThrowTypedErrors(_ text: String) throws {
      let url = try #require(URL(string: text))
      #expect(throws: FileSystemFailure.self) { try WindowsDirectoryPublisher.currentTarget(url) }
      let literal = FileManager.default.temporaryDirectory.appendingPathComponent(
        "pinewind-percent%00-" + UUID().uuidString)
      #expect(try WindowsDirectoryPublisher.currentTarget(literal) == nil)
    }

    @Test func ordinaryOutputFileReportsTypedErrorAndRemainsIntact() throws {
      let f = try Fixture()
      defer { f.remove() }
      let bytes = Data("keep".utf8)
      try bytes.write(to: f.output)
      #expect(throws: FileSystemFailure.self) { try WindowsDirectoryPublisher.validate(f.output) }
      #expect(try Data(contentsOf: f.output) == bytes)
    }

    @Test func emptyOutputDirectoryIsAdoptedAsAJunction() async throws {
      let f = try Fixture()
      defer { f.remove() }
      try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: false)
      try f.write("default.yaml", "value: adopted\n", in: f.input)
      _ = try await Composer().compose(
        f.plan([.userFiles(FileFilter())]), inputRoot: f.input, outputRoot: f.output)
      #expect(try WindowsDirectoryPublisher.currentTarget(f.output) != nil)
      #expect(try f.read("default.yaml") == "value: adopted\n")
    }

    @Test(arguments: [false, true])
    func danglingManagedJunctionIsRepaired(hasFiles: Bool) async throws {
      let f = try Fixture()
      defer { f.remove() }
      if hasFiles { try f.write("default.yaml", "value: repaired\n", in: f.input) }
      let plan = try f.plan([.userFiles(FileFilter())])
      _ = try await Composer().compose(plan, inputRoot: f.input, outputRoot: f.output)
      let old = try #require(try WindowsDirectoryPublisher.currentTarget(f.output))
      try FileManager.default.removeItem(at: old)
      #expect(!FileManager.default.fileExists(atPath: f.output.path))
      _ = try await Composer().compose(plan, inputRoot: f.input, outputRoot: f.output)
      let repaired = try #require(try WindowsDirectoryPublisher.currentTarget(f.output))
      #expect(repaired != old)
      #expect(FileManager.default.fileExists(atPath: repaired.string))
      if hasFiles { #expect(try f.read("default.yaml") == "value: repaired\n") }
    }

    @Test func managedJunctionTargetAcceptsAncestorJunctionAliases() async throws {
      let f = try Fixture()
      defer { f.remove() }
      try f.write("default.yaml", "value: alias\n", in: f.input)
      let plan = try f.plan([.userFiles(FileFilter())])
      _ = try await Composer().compose(plan, inputRoot: f.input, outputRoot: f.output)
      let active = try #require(try WindowsDirectoryPublisher.currentTarget(f.output))
      let alias = f.root.appendingPathComponent("parent-alias")
      let logical = try WindowsDirectoryPublisher.publicationPath(NativePath.from(f.output))
      #expect(logical.lastComponent?.string == f.output.lastPathComponent)
      #expect(
        try SafePath.canonical(logical.removingLastComponent())
          == SafePath.canonical(NativePath.from(f.root)))
      #expect(try WindowsDirectoryPublisher.currentTarget(logical) == active)
      try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: false)
      try WindowsDirectoryPublisher.redirect(alias, to: f.root)
      defer { try? FileManager.default.removeItem(at: alias) }
      let aliasedTarget = alias.appendingPathComponent(
        try #require(active.removingLastComponent().lastComponent).string
      )
      .appendingPathComponent(try #require(active.lastComponent).string)
      try WindowsDirectoryPublisher.redirect(f.output, to: aliasedTarget)
      try WindowsDirectoryPublisher.validate(f.output)
      let result = try await Composer().compose(plan, inputRoot: f.input, outputRoot: f.output)
      #expect(result.changedPaths.isEmpty)
      #expect(try f.read("default.yaml") == "value: alias\n")
    }
  #endif

  @Test func globDetectsNewFilesAndRemovesDeletedOutputs() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("recipe.yaml", "install_files: [\"dicts/*.yaml\"]", in: f.a)
    try f.write("dicts/old.yaml", "old: true", in: f.a)
    let entries = try [ManifestEntry.package(f.request(f.a))]
    let composer = Composer()
    _ = try await composer.compose(f.plan(entries), inputRoot: f.input, outputRoot: f.output)
    try f.write("dicts/new.yaml", "new: true", in: f.a)
    try FileManager.default.removeItem(at: f.a.appendingPathComponent("dicts/old.yaml"))
    let result = try await composer.compose(
      f.plan(entries), inputRoot: f.input, outputRoot: f.output)
    #expect(result.paths.map(\.string) == ["dicts/new.yaml"])
    #expect(result.removedPaths.map(\.string) == ["dicts/old.yaml"])
  }

  @Test(arguments: ["customize", "./nested/../customize"])
  func patchRunsImmediatelyAndLaterSelfCanReplaceIt(_ recipe: String) async throws {
    let f = try Fixture("PatchOrder")
    defer { f.remove() }
    let request = try f.request(f.a, recipe: recipe)
    #expect(request.recipe == "customize")
    let composer = Composer()
    _ = try await composer.compose(
      f.plan([.userFiles(FileFilter()), .package(request)]), inputRoot: f.input,
      outputRoot: f.output)
    #expect(try f.read("luna_pinyin.custom.yaml").contains("__patch:"))
    _ = try await composer.compose(
      f.plan([.package(request), .userFiles(FileFilter())]), inputRoot: f.input,
      outputRoot: f.output)
    #expect(try f.read("luna_pinyin.custom.yaml") == "patch:\n  user: true\n")
  }

  @Test func replacesRxInheritedFromSelfAndRepeatedPackageOnlyLeavesOneBlock() async throws {
    let f = try Fixture("RxReplacement")
    defer { f.remove() }
    let request = try PackageRequest(
      url: #require(URL(string: "https://github.com/rime/rime-emoji")), recipe: "customize")
    let prepared = try PreparedPackage(
      request: request, directory: f.a, commit: CommitID(String(repeating: "a", count: 40)))
    let plan = try f.plan(
      [.userFiles(FileFilter()), .package(request), .package(request)], packages: [prepared])
    _ = try await Composer().compose(plan, inputRoot: f.input, outputRoot: f.output)
    let text = try f.read("luna_pinyin.custom.yaml")
    #expect(!text.contains("old: true"))
    #expect(text.components(separatedBy: "# Rx:").count == 2)
    #expect(text.contains("new: true"))
  }

  @Test func invalidPatchLeavesPublishedOutputUntouched() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("luna_pinyin.custom.yaml", "__patch:\n  - old: true\n", in: f.input)
    let composer = Composer()
    _ = try await composer.compose(
      f.plan([.userFiles(FileFilter())]), inputRoot: f.input, outputRoot: f.output)
    let old = try f.read("luna_pinyin.custom.yaml")
    try f.write("luna_pinyin.custom.yaml", "__patch: wrong", in: f.input)
    try f.write("recipe.yaml", "patch_files:\n  luna_pinyin.custom.yaml:\n    - new: true", in: f.a)
    await #expect(throws: DeclarationFailure.self) {
      try await composer.compose(
        f.plan([.userFiles(FileFilter()), .package(f.request(f.a))]), inputRoot: f.input,
        outputRoot: f.output)
    }
    #expect(try f.read("luna_pinyin.custom.yaml") == old)
  }

  @Test func overlappingRootsAndSymlinksFail() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("default.yaml", "value: true", in: f.input)
    let plan = try f.plan([.userFiles(FileFilter())])
    await #expect(throws: FileSystemFailure.self) {
      try await Composer().compose(
        plan, inputRoot: f.input, outputRoot: f.input.appendingPathComponent("out"))
    }
    try FileManager.default.createSymbolicLink(
      at: f.input.appendingPathComponent("escape.yaml"), withDestinationURL: f.a)
    #expect(throws: FileSystemFailure.self) { try f.plan([.userFiles(FileFilter())]) }
  }

  @Test func sourceTraversalAndFileDirectoryConflictsFailBeforePublishing() throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("recipe.yaml", "install_files: [\"../../escape.yaml\"]", in: f.a)
    #expect(throws: DeclarationFailure.self) { try f.plan([.package(f.request(f.a))]) }
    try f.write("data", "file", in: f.input)
    try f.write("data/nested.yaml", "nested: true", in: f.a)
    try f.write("recipe.yaml", "install_files: [data/nested.yaml]", in: f.a)
    #expect(throws: DeclarationFailure.self) {
      try f.plan([.userFiles(FileFilter()), .package(f.request(f.a))])
    }
  }

  @Test(arguments: ["github.com", "git.example"])
  func crossPackageReadsDeduplicateTheSameSourceVersionAndTrackItsFile(_ host: String) throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write(
      "recipe.yaml",
      "install_files: [\"../essay/shared.yaml\"]\npatch_files: {consumer.custom.yaml: [{schema: test}]}",
      in: f.a)
    try f.write("shared.yaml", "source: essay", in: f.b)
    let consumer = try PackageRequest(
      url: #require(URL(string: "https://\(host)/rime/rime-consumer.git")))
    let shared = try PackageRequest(
      url: #require(URL(string: "https://\(host)/rime/rime-essay.git")))
    let sharedAgain = try PackageRequest(
      url: #require(URL(string: "https://\(host)/rime/rime-essay")), recipe: "other")
    let commit = try CommitID(String(repeating: "a", count: 40))
    let views = try [
      PreparedPackage(request: consumer, directory: f.a, commit: commit),
      PreparedPackage(request: shared, directory: f.b, commit: commit),
      PreparedPackage(request: sharedAgain, directory: f.b, commit: commit),
    ]
    let plan = try f.plan([.package(consumer)], packages: views)
    #expect(plan.paths.map(\.string) == ["consumer.custom.yaml", "shared.yaml"])
    let patch = try #require(plan.files[RelativePath("consumer.custom.yaml")]?.first)
    guard case .patch(let rx, _) = patch.action else {
      Issue.record("expected a recipe patch")
      return
    }
    #expect(rx == "rime/rime-consumer::")
    #expect(
      try plan.files[RelativePath("shared.yaml")]?.first?.source
        == f.b.appendingPathComponent("shared.yaml"))
    let conflicting = try PreparedPackage(
      request: shared, directory: f.b, commit: CommitID(String(repeating: "b", count: 40)))
    #expect(throws: DeclarationFailure.self) {
      try f.plan([.package(consumer)], packages: views + [conflicting])
    }
  }

  @Test func optionValuesAreLiteralAndFiltersAlsoApplyToPatchTargets() async throws {
    let f = try Fixture("LiteralOptions")
    defer { f.remove() }
    let request = try PackageRequest(
      url: f.a, recipe: "customize", options: ["schema": "$(echo literal)"])
    let plan = try f.plan([.package(request)])
    #expect(plan.paths.map(\.string) == ["$(echo literal).custom.yaml"])
    _ = try await Composer().compose(plan, inputRoot: f.input, outputRoot: f.output)
    #expect(
      !FileManager.default.fileExists(
        atPath: f.output.appendingPathComponent("literal.custom.yaml").path))
    let filtered = try PackageRequest(
      url: f.a, recipe: "customize", filter: FileFilter(exclude: ["*.custom.yaml"]))
    #expect(try f.plan([.package(filtered)]).paths.isEmpty)
  }

  @Test func planningPreservesDistinctNativeUnicodePathIdentities() throws {
    let f = try Fixture("LiteralOptions")
    defer { f.remove() }
    let names = ["caf\u{e9}", "cafe\u{301}"]
    let entries = try names.map { name in
      ManifestEntry.package(
        try PackageRequest(url: f.a, recipe: "customize", options: ["schema": name]))
    }
    let plan = try f.plan(entries)
    #expect(plan.paths.count == 2)
    for (index, name) in names.enumerated() {
      let path = try RelativePath(FilePath(name + ".custom.yaml"))
      #expect(plan.contributions(for: path).map(\.entryIndex) == [index])
    }
  }

  @Test func normalizedPatchTargetsAppearOnceInThePlanAndOutput() async throws {
    let f = try Fixture("NormalizedPaths")
    defer { f.remove() }
    let plan = try f.plan([.package(f.request(f.a))])
    #expect(plan.paths.map(\.string) == ["target.custom.yaml"])
    _ = try await Composer().compose(plan, inputRoot: f.input, outputRoot: f.output)
    #expect(try f.read("target.custom.yaml").contains("schema: normalized"))
  }

  @Test(arguments: ["../escape", "/absolute", "bad\\name", "bad\0name"])
  func recipeTargetTextCannotLoseOrReinterpretInvalidCharacters(_ target: String) throws {
    let f = try Fixture("LiteralOptions")
    defer { f.remove() }
    let request = try PackageRequest(url: f.a, recipe: "customize", options: ["schema": target])
    #expect {
      _ = try f.plan([.package(request)])
    } throws: { error in
      if error is FileSystemFailure || error is DeclarationFailure { return true }
      switch error as? PinewindError {
      case .configuration(let document):
        if document.underlyingError is FileSystemFailure { return true }
        return false
      default: return false
      }
    }
  }

  @Test(arguments: [
    "download_files: [nested/../same.txt::https://example.org/first, same.txt::https://example.org/second]",
    "patch_files: {nested/../same.yaml: [{value: first}], same.yaml: [{value: second}]}",
  ])
  func normalizedRecipeAliasesCannotDeclareTheSameTargetTwice(_ recipe: String) throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("recipe.yaml", recipe, in: f.a)
    #expect {
      _ = try Recipe.load(
        request: f.request(f.a), directory: native(f.a), read: { try Data(contentsOf: $0) })
    } throws: { error in
      guard case .configuration(let document) = error as? PinewindError else { return false }
      switch document.underlyingError as? DeclarationFailure {
      case .duplicateTarget: return true
      case .syntaxError(let detail): return detail.contains("targets must be unique")
      default: return false
      }
    }
  }

  @Test(arguments: [
    ("https://example.org/extra.txt", "extra.txt"),
    ("renamed.txt::https://example.org/extra.txt", "renamed.txt"),
    ("nested/../extra.txt::https://example.org/extra.txt", "extra.txt"),
  ])
  func validatesPinnedResourceBytes(_ descriptor: String, _ path: String) async throws {
    let f = try Fixture()
    defer { f.remove() }
    let request = try PackageRequest(url: #require(URL(string: "https://github.com/rime/resource")))
    let url = try #require(URL(string: "https://example.org/extra.txt"))
    try f.write(
      "recipe.yaml", "download_files: [\"\(descriptor)\"]\ninstall_files: [\(path)]",
      in: f.a)
    try f.write(path, "abc", in: f.a)
    let resource = try PinnedResource(
      url: url, path: RelativePath(FilePath(path)),
      sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let prepared = try PreparedPackage(
      request: request, directory: f.a, commit: CommitID(String(repeating: "a", count: 40)),
      resources: [resource])
    let plan = try f.plan([.package(request)], packages: [prepared])
    #expect(plan.paths.map(\.string) == [path])
    try f.write(path, "changed", in: f.a)
    _ = try await Composer().compose(plan, inputRoot: f.input, outputRoot: f.output)
    #expect(try f.read(path) == "abc")
    #expect {
      try f.plan([.package(request)], packages: [prepared])
    } throws: {
      ($0 as? PinewindError) != nil || $0 is DeclarationFailure || $0 is CacheFailure
    }
  }
}

@Suite("Pinewind conf sandbox")
struct ConfTests {
  // Leave headroom for parallel CI load; the timeout regression below uses 50 ms.
  private let importer = PlumImporter(timeout: .seconds(60))

  @Test(arguments: ["u/", "/repo", "u//repo", "/", "repo@", "@branch"])
  func descriptorsRejectEmptySourceSegments(_ descriptor: String) {
    #expect(throws: InterpreterFailure.self) { try PlumImporter.package(descriptor) }
  }

  @Test(.timeLimit(.minutes(1))) func longLoopsTimeOutAndCancelInterpreter() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("loop.conf", "while :; do :; done", in: f.input)
    do {
      _ = try await PlumImporter(timeout: .milliseconds(50)).evaluate(
        ConfImport(source: "loop.conf"), inputRoot: f.input)
      Issue.record("expected timeout")
    } catch let error as PinewindError {
      guard case .incident(let document) = error else {
        Issue.record("\(error)")
        return
      }
      guard case .timedOut = document.underlyingError as? InterpreterFailure else {
        Issue.record("\(error)")
        return
      }
    }
  }

  @Test func expandedImportsKeepSelfInterleavedWithPackages() async throws {
    let f = try Fixture("ImportOrder")
    defer { f.remove() }
    let manifest = try await loadConfiguration(
      inputRoot: f.input, localStateRoot: f.root.appendingPathComponent("state")
    ).snapshot().evaluate()
    let expanded = try await importer.expand(manifest, inputRoot: f.input)
    #expect(
      expanded.entries == [
        .package(try PlumImporter.package("emoji")), .package(try PlumImporter.package("essay")),
        .userFiles(FileFilter()), .package(try PlumImporter.package("emoji")),
      ])
    let prepared = try ["emoji", "essay"].map {
      try PreparedPackage(
        request: PlumImporter.package($0), directory: f.a,
        commit: CommitID(String(repeating: "a", count: 40))
      )
    }
    let composer = Composer()
    _ = try await composer.compose(
      f.plan(expanded.entries, packages: prepared), inputRoot: f.input, outputRoot: f.output)
    #expect(try f.read("value.txt") == "package\n")
    _ = try await composer.compose(
      f.plan(Array(expanded.entries.dropLast()), packages: prepared),
      inputRoot: f.input, outputRoot: f.output)
    #expect(try f.read("value.txt") == "self\n")
  }

  @Test func resetAppendExpansionAndRepeatedIncludeUseInterpreterSemantics() async throws {
    let f = try Fixture("ConfInclude")
    defer { f.remove() }
    let request = try ConfImport(source: "test.conf", variables: ["branch": "dev"])
    let list = try await importer.evaluate(request, inputRoot: f.input)
    #expect(list == ["rimeinn/rime-moran@dev", "essay", "essay"])
  }

  @Test func builtinsAndDescriptorTranslationWork() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let preset = try await importer.evaluate(
      ConfImport(source: ":preset"), inputRoot: f.input)
    let extra = try await importer.evaluate(ConfImport(source: ":extra"), inputRoot: f.input)
    let all = try await importer.evaluate(ConfImport(source: ":all"), inputRoot: f.input)
    #expect(
      preset == [
        "bopomofo", "cangjie", "essay", "luna-pinyin", "prelude", "quick", "stroke", "terra-pinyin",
      ])
    #expect(extra.count == 14)
    #expect(all == preset + extra)
    await #expect(throws: InterpreterFailure.self) {
      try await importer.evaluate(ConfImport(source: ":unknown"), inputRoot: f.input)
    }
    let request = try PlumImporter.package("emoji@master:customize:schema=terra_pinyin")
    #expect(request.url.absoluteString == "https://github.com/rime/rime-emoji")
    #expect(request.revision == .reference("master"))
    #expect(request.recipe == "customize")
    #expect(request.options == ["schema": "terra_pinyin"])
  }

  @Test func confCannotWriteHostFilesOrEscapeMount() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("write.conf", "echo stolen > /conf/stolen", in: f.input)
    await #expect {
      try await importer.evaluate(ConfImport(source: "write.conf"), inputRoot: f.input)
    } throws: { error in
      guard case .incident(let document) = error as? PinewindError else { return false }
      guard case .evaluationFailed(let detail) = document.underlyingError as? InterpreterFailure
      else {
        return false
      }
      return detail.contains("/conf/stolen: Permission denied")
    }
    #expect(!FileManager.default.fileExists(atPath: f.input.appendingPathComponent("stolen").path))
    try f.write("escape.conf", "source /etc/passwd", in: f.input)
    await #expect(throws: FileSystemError.notFound("/etc/passwd")) {
      try await importer.evaluate(ConfImport(source: "escape.conf"), inputRoot: f.input)
    }
  }

  @Test func cyclicIncludesFailWithinResourceBudget() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("cycle.conf", "source /conf/cycle.conf", in: f.input)
    await #expect {
      try await importer.evaluate(ConfImport(source: "cycle.conf"), inputRoot: f.input)
    } throws: { $0 is InterpreterFailure }
  }
}

@Suite("Pinewind opaque lock")
struct LockTests {
  @Test func roundTripKeepsDuplicateUrlApplicationsAndDetectsChangedDeclarations() throws {
    let url = try #require(URL(string: "https://github.com/rime/rime-emoji"))
    let document = ManifestDocument(order: [
      .package(
        PackageFields(
          url: .value(url), revision: .value(.reference("master")), recipe: .value("one"))),
      .package(
        PackageFields(
          url: .value(url), revision: .value(.reference("other")), recipe: .value("two"))),
      .userFiles(FileFilter()),
    ])
    let snapshot = try configurationSnapshot(document)
    let manifest = try snapshot.evaluate(.shared)
    let packages = try manifest.entries.compactMap { entry -> LockedPackage? in
      guard case .package(let request) = entry else { return nil }
      let digit = request.recipe == "one" ? "a" : "b"
      return try LockedPackage(
        request: request, commit: CommitID(String(repeating: digit, count: 40)))
    }
    let resolution = try Resolution(
      declarations: manifest, expanded: manifest, packages: packages, snapshot: snapshot,
      preview: false)
    let bytes = try ResolutionCodec.encode(resolution)
    let loaded = try ResolutionCodec.decode(bytes, snapshot: snapshot)
    #expect(loaded.expanded == manifest)
    #expect(loaded.packages == packages)
    var changed = document
    changed.order.removeLast()
    let changedSnapshot = try configurationSnapshot(changed)
    #expect {
      try ResolutionCodec.decode(bytes, snapshot: changedSnapshot)
    } throws: {
      guard case .configuration(let document) = $0 as? PinewindError else { return false }
      if case .declarationChanged = document.underlyingError as? LockFailure { return true }
      return false
    }
  }

  @Test func workingTreesAndCorruptLocksFail() throws {
    let directory = native(FileManager.default.temporaryDirectory)
    #expect(throws: LockFailure.self) {
      try LockedPackage(
        request: PackageRequest(source: .directory(.path(directory))),
        commit: CommitID(String(repeating: "a", count: 40)))
    }
    let snapshot = try configurationSnapshot(ManifestDocument())
    #expect {
      try ResolutionCodec.decode(Data("not a lock".utf8), snapshot: snapshot)
    } throws: { error in
      guard case .configuration(let document) = error as? PinewindError else { return false }
      if case .incompatible = document.underlyingError as? LockFailure { return true }
      return false
    }
  }
}
