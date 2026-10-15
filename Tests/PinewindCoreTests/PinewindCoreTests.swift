// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
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
          throw PinewindError("test fixture bundle is missing")
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
  @Test(arguments: [
    "order: [self]",
    "version: true\norder: [self]",
    "version: \"1\"\norder: [self]",
    "version: 2\norder: [self]",
    "version: 1\nversion: 1\norder: [self]",
    "version: 1\nunknown: value\norder: [self]",
    "version: 1\norder: [{url: https://github.com/rime/rime-emoji, name: emoji}]",
    "version: 1\norder: [missing]",
    "version: 1\norder: [{url: https://github.com/rime/rime-emoji, options: {schema: true}}]",
    "version: 1\norder: [self]\n---\nversion: 1\norder: []",
    "version: 1\nnames: {unused: {url: true}}\norder: []",
  ])
  func invalidDocumentsFail(_ text: String) {
    #expect(throws: PinewindError.self) { try Manifest.parse(text) }
  }

  @Test func mergesFieldsAndClearsWithoutDeepMergingOptions() throws {
    let yaml = """
      version: 1
      names:
        emoji:
          url: https://github.com/rime/rime-emoji.git
          ref: master
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
          ref: null
          recipe: null
      """
    let manifest = try Manifest.parse(yaml, localOverrides: local)
    guard case .package(let request) = try #require(manifest.entries.first) else {
      Issue.record("expected package")
      return
    }
    #expect(request.url.absoluteString == "https://github.com/rime/rime-emoji")
    #expect(request.ref == nil)
    #expect(request.recipe == nil)
    #expect(request.options == ["schema": "new"])
  }

  @Test func localWorkingTreeIgnoresInheritedRefAndNeverWritesLock() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.write(
      "pinewind.yaml",
      """
      version: 1
      names:
        dev: {url: https://github.com/rime/rime-emoji, ref: master}
      order: [dev, self]
      """, in: fixture.input)
    try fixture.write(
      "pinewind.local.yaml",
      """
      version: 1
      names:
        dev: {url: \(fixture.a.absoluteString)}
      """, in: fixture.input)
    let manifest = try Manifest.load(inputRoot: fixture.input)
    guard case .package(let request) = manifest.entries[0] else {
      Issue.record("expected package")
      return
    }
    #expect(request.url == fixture.a)
    #expect(request.ref == nil && request.commit == nil)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.input.appendingPathComponent("pinewind.lock").path))
  }

  @Test func missingManifestDefaultsToSelfAndEmptyOrderStaysEmpty() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    #expect(try Manifest.load(inputRoot: fixture.input).entries == [.userFiles(FileFilter())])
    #expect(try Manifest.parse("version: 1\norder: []").entries.isEmpty)
  }

  @Test(arguments: ["ref", "commit"])
  func localSourcesRejectExplicitVersionsButClearInheritedVersions(_ key: String) throws {
    let f = try Fixture()
    defer { f.remove() }
    let value = key == "ref" ? "master" : String(repeating: "a", count: 40)
    #expect(throws: PinewindError.self) {
      try PackageRequest(
        url: f.a, ref: key == "ref" ? value : nil, commit: key == "commit" ? value : nil)
    }
    let remote = """
      version: 1
      names:
        dev: {url: https://github.com/rime/rime-emoji, \(key): \(value)}
      order: [dev]
      """
    let override = "version: 1\nnames: {dev: {url: \(f.a.absoluteString)}}"
    guard case .package(let local) = try Manifest.parse(remote, localOverrides: override).entries[0]
    else {
      Issue.record("expected a local package")
      return
    }
    #expect(local.url == f.a && local.ref == nil && local.commit == nil)
    for yaml in [
      "version: 1\norder: [{url: \(f.a.absoluteString), \(key): \(value)}]",
      "version: 1\nnames: {dev: {url: \(f.a.absoluteString), \(key): \(value)}}\norder: [dev]",
      "version: 1\nnames: {dev: {url: \(f.a.absoluteString)}}\norder: [{name: dev, \(key): \(value)}]",
    ] {
      #expect(throws: PinewindError.self) { try Manifest.parse(yaml) }
    }
    #expect(throws: PinewindError.self) {
      try Manifest.parse(
        remote,
        localOverrides:
          "version: 1\nnames: {dev: {url: \(f.a.absoluteString), \(key): \(value)}}")
    }
  }

  @Test func localVersionIsRequired() {
    #expect(throws: PinewindError.self) {
      try Manifest.parse("version: 1\norder: [self]", localOverrides: "names: {}")
    }
  }

  @Test func diagnosticReportsTheCorrectLine() {
    do {
      _ = try Manifest.parse("version: 1\norder: []\nbad: true", source: "fixture.yaml")
      Issue.record("expected diagnostic")
    } catch let error as PinewindError {
      #expect(error.source == "fixture.yaml")
      #expect(error.line == 3)
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
    let operations = try #require(plan?.files["words.txt"])
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
    #expect(!FileManager.default.fileExists(atPath: frozen.deletingLastPathComponent().path))
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
    #expect(plan.paths == ["opencc/emoji.txt", "schemas/test.yaml"])
    _ = try await Composer().compose(plan, inputRoot: f.input, outputRoot: f.output)
    #expect(try f.read("opencc/emoji.txt") == "emoji\n")
  }

  @Test func patchesCreateMissingTargetsAndParentDirectories() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write(
      "recipe.yaml", "patch_files: {nested/test.custom.yaml: [{schema: test}]}", in: f.a)
    let plan = try f.plan([.package(f.request(f.a))])
    #expect(plan.paths == ["nested/test.custom.yaml"])
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
    #expect(throws: PinewindError.self) {
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
    #expect(result.paths == ["lua/helper.lua", "nested/table.txt"])
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
    #expect(plan.paths == ["default.yaml", "model.gram", "opencc/data.ocd2", "words.txt"])
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
    #expect(both.files["default.yaml"]?.count == 2)
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
    #expect(unchanged.reusedPaths == ["default.yaml"])
    #expect(after == sentinel)
    try f.write("default.yaml", "value: new\n", in: f.a)
    let changed = try await composer.compose(
      f.plan(entries), inputRoot: f.input, outputRoot: f.output)
    #expect(changed.changedPaths == ["default.yaml"])
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
    #expect(throws: PinewindError.self) {
      try SafePath.validateRoots(input: f.input, output: URL(fileURLWithPath: "/"), sources: [])
    }
    #if os(Windows)
      let alias = URL(fileURLWithPath: f.input.path.uppercased())
      #expect(throws: PinewindError.self) {
        try SafePath.validateRoots(
          input: f.input, output: alias.appendingPathComponent("out"), sources: [])
      }
      try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: true)
      try f.write("keep.txt", "keep", in: f.output)
      #expect(throws: PinewindError.self) { try WindowsDirectoryPublisher.validate(f.output) }
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
      #expect(FileManager.default.fileExists(atPath: active.path))
    }

    @Test(arguments: ["https://example.com/output", "file:///C:/bad%00path"])
    func malformedJunctionPathsThrowTypedErrors(_ text: String) throws {
      let url = try #require(URL(string: text))
      #expect(throws: PinewindError.self) { try WindowsDirectoryPublisher.currentTarget(url) }
      let literal = FileManager.default.temporaryDirectory.appendingPathComponent(
        "pinewind-percent%00-" + UUID().uuidString)
      #expect(try WindowsDirectoryPublisher.currentTarget(literal) == nil)
    }

    @Test func ordinaryOutputFileReportsTypedErrorAndRemainsIntact() throws {
      let f = try Fixture()
      defer { f.remove() }
      let bytes = Data("keep".utf8)
      try bytes.write(to: f.output)
      #expect(throws: PinewindError.self) { try WindowsDirectoryPublisher.validate(f.output) }
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
      #expect(FileManager.default.fileExists(atPath: repaired.path))
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
      try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: false)
      try WindowsDirectoryPublisher.redirect(alias, to: f.root)
      defer { try? FileManager.default.removeItem(at: alias) }
      let aliasedTarget = alias.appendingPathComponent(
        active.deletingLastPathComponent().lastPathComponent
      )
      .appendingPathComponent(active.lastPathComponent)
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
    #expect(result.paths == ["dicts/new.yaml"])
    #expect(result.removedPaths == ["dicts/old.yaml"])
  }

  @Test func patchRunsImmediatelyAndLaterSelfCanReplaceIt() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write(
      "customize.recipe.yaml",
      """
      recipe:
        Rx: customize
        args: [schema=luna_pinyin]
      install_files: []
      patch_files:
        ${schema:-luna_pinyin}.custom.yaml:
          - patch/+:
              switch: true
      """, in: f.a)
    try f.write("luna_pinyin.custom.yaml", "patch:\n  user: true\n", in: f.input)
    let request = try f.request(f.a, recipe: "customize")
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
      request: request, directory: f.a, commit: String(repeating: "a", count: 40))
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
    await #expect(throws: PinewindError.self) {
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
    await #expect(throws: PinewindError.self) {
      try await Composer().compose(
        plan, inputRoot: f.input, outputRoot: f.input.appendingPathComponent("out"))
    }
    try FileManager.default.createSymbolicLink(
      at: f.input.appendingPathComponent("escape.yaml"), withDestinationURL: f.a)
    #expect(throws: PinewindError.self) { try f.plan([.userFiles(FileFilter())]) }
  }

  @Test func sourceTraversalAndFileDirectoryConflictsFailBeforePublishing() throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("recipe.yaml", "install_files: [\"../../escape.yaml\"]", in: f.a)
    #expect(throws: PinewindError.self) { try f.plan([.package(f.request(f.a))]) }
    try f.write("data", "file", in: f.input)
    try f.write("data/nested.yaml", "nested: true", in: f.a)
    try f.write("recipe.yaml", "install_files: [data/nested.yaml]", in: f.a)
    #expect(throws: PinewindError.self) {
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
    let commit = String(repeating: "a", count: 40)
    let views = try [
      PreparedPackage(request: consumer, directory: f.a, commit: commit),
      PreparedPackage(request: shared, directory: f.b, commit: commit),
      PreparedPackage(request: sharedAgain, directory: f.b, commit: commit),
    ]
    let plan = try f.plan([.package(consumer)], packages: views)
    #expect(plan.paths == ["consumer.custom.yaml", "shared.yaml"])
    let patch = try #require(plan.files["consumer.custom.yaml"]?.first)
    guard case .patch(let rx, _) = patch.action else {
      Issue.record("expected a recipe patch")
      return
    }
    #expect(rx == "rime/rime-consumer::")
    #expect(plan.files["shared.yaml"]?.first?.source == f.b.appendingPathComponent("shared.yaml"))
    let conflicting = try PreparedPackage(
      request: shared, directory: f.b, commit: String(repeating: "b", count: 40))
    #expect(throws: PinewindError.self) {
      try f.plan([.package(consumer)], packages: views + [conflicting])
    }
  }

  @Test func optionValuesAreLiteralAndFiltersAlsoApplyToPatchTargets() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write(
      "customize.recipe.yaml",
      """
      recipe: {Rx: customize, args: [schema=luna_pinyin]}
      install_files: []
      patch_files:
        ${schema:-luna_pinyin}.custom.yaml:
          - patch/+: {literal: true}
      """, in: f.a)
    let request = try PackageRequest(
      url: f.a, recipe: "customize", options: ["schema": "$(echo literal)"])
    let plan = try f.plan([.package(request)])
    #expect(plan.paths == ["$(echo literal).custom.yaml"])
    _ = try await Composer().compose(plan, inputRoot: f.input, outputRoot: f.output)
    #expect(
      !FileManager.default.fileExists(
        atPath: f.output.appendingPathComponent("literal.custom.yaml").path))
    let filtered = try PackageRequest(
      url: f.a, recipe: "customize", filter: FileFilter(exclude: ["*.custom.yaml"]))
    #expect(try f.plan([.package(filtered)]).paths.isEmpty)
  }

  @Test(arguments: ["https://example.org/extra.txt", "renamed.txt::https://example.org/extra.txt"])
  func validatesPinnedResourceBytes(_ descriptor: String) async throws {
    let f = try Fixture()
    defer { f.remove() }
    let request = try PackageRequest(url: #require(URL(string: "https://github.com/rime/resource")))
    let url = try #require(URL(string: "https://example.org/extra.txt"))
    let path = descriptor.contains("::") ? "renamed.txt" : "extra.txt"
    try f.write(
      "recipe.yaml", "download_files: [\"\(descriptor)\"]\ninstall_files: [\(path)]",
      in: f.a)
    try f.write(path, "abc", in: f.a)
    let resource = try PinnedResource(
      url: url, path: path,
      sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let prepared = try PreparedPackage(
      request: request, directory: f.a, commit: String(repeating: "a", count: 40),
      resources: [resource])
    let plan = try f.plan([.package(request)], packages: [prepared])
    #expect(plan.paths == [path])
    try f.write(path, "changed", in: f.a)
    _ = try await Composer().compose(plan, inputRoot: f.input, outputRoot: f.output)
    #expect(try f.read(path) == "abc")
    #expect(throws: PinewindError.self) { try f.plan([.package(request)], packages: [prepared]) }
  }
}

@Suite("Pinewind conf sandbox")
struct ConfTests {
  @Test(arguments: ["u/", "/repo", "u//repo", "/", "repo@", "@branch"])
  func descriptorsRejectEmptySourceSegments(_ descriptor: String) {
    #expect(throws: PinewindError.self) { try PlumImporter.package(descriptor) }
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
      #expect(error.message == "conf evaluation timed out")
    }
  }

  @Test func expandedImportsKeepSelfInterleavedWithPackages() async throws {
    let f = try Fixture("ImportOrder")
    defer { f.remove() }
    let manifest = try Manifest.load(inputRoot: f.input)
    let expanded = try await PlumImporter().expand(manifest, inputRoot: f.input)
    #expect(
      expanded.entries == [
        .package(try PlumImporter.package("emoji")), .package(try PlumImporter.package("essay")),
        .userFiles(FileFilter()), .package(try PlumImporter.package("emoji")),
      ])
    let prepared = try ["emoji", "essay"].map {
      try PreparedPackage(
        request: PlumImporter.package($0), directory: f.a, commit: String(repeating: "a", count: 40)
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
    let list = try await PlumImporter().evaluate(request, inputRoot: f.input)
    #expect(list == ["rimeinn/rime-moran@dev", "essay", "essay"])
  }

  @Test func builtinsAndDescriptorTranslationWork() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let preset = try await PlumImporter().evaluate(
      ConfImport(source: ":preset"), inputRoot: f.input)
    let extra = try await PlumImporter().evaluate(ConfImport(source: ":extra"), inputRoot: f.input)
    let all = try await PlumImporter().evaluate(ConfImport(source: ":all"), inputRoot: f.input)
    #expect(
      preset == [
        "bopomofo", "cangjie", "essay", "luna-pinyin", "prelude", "quick", "stroke", "terra-pinyin",
      ])
    #expect(extra.count == 14)
    #expect(all == preset + extra)
    await #expect(throws: PinewindError.self) {
      try await PlumImporter().evaluate(ConfImport(source: ":unknown"), inputRoot: f.input)
    }
    let request = try PlumImporter.package("emoji@master:customize:schema=terra_pinyin")
    #expect(request.url.absoluteString == "https://github.com/rime/rime-emoji")
    #expect(request.ref == "master")
    #expect(request.recipe == "customize")
    #expect(request.options == ["schema": "terra_pinyin"])
  }

  @Test func confCannotWriteHostFilesOrEscapeMount() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("write.conf", "echo stolen > /conf/stolen", in: f.input)
    await #expect(throws: (any Error).self) {
      try await PlumImporter().evaluate(ConfImport(source: "write.conf"), inputRoot: f.input)
    }
    #expect(!FileManager.default.fileExists(atPath: f.input.appendingPathComponent("stolen").path))
    try f.write("escape.conf", "source /etc/passwd", in: f.input)
    await #expect(throws: (any Error).self) {
      try await PlumImporter().evaluate(ConfImport(source: "escape.conf"), inputRoot: f.input)
    }
  }

  @Test func cyclicIncludesFailWithinResourceBudget() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("cycle.conf", "source /conf/cycle.conf", in: f.input)
    await #expect(throws: (any Error).self) {
      try await PlumImporter().evaluate(ConfImport(source: "cycle.conf"), inputRoot: f.input)
    }
  }
}

@Suite("Pinewind opaque lock")
struct LockTests {
  @Test func roundTripKeepsDuplicateUrlApplicationsAndDetectsChangedDeclarations() throws {
    let f = try Fixture()
    defer { f.remove() }
    let url = try #require(URL(string: "https://github.com/rime/rime-emoji"))
    let a = try PackageRequest(url: url, ref: "master", recipe: "one")
    let b = try PackageRequest(url: url, ref: "other", recipe: "two")
    let manifest = Manifest(entries: [.package(a), .package(b), .userFiles(FileFilter())])
    let packages = try [
      LockedPackage(request: a, commit: String(repeating: "a", count: 40)),
      LockedPackage(request: b, commit: String(repeating: "b", count: 40)),
    ]
    let resolution = try Resolution(declarations: manifest, expanded: manifest, packages: packages)
    let file = f.input.appendingPathComponent("pinewind.lock")
    try resolution.write(to: file)
    let loaded = try Resolution.read(from: file)
    #expect(loaded.expanded == manifest)
    #expect(loaded.packages == packages)
    try loaded.validate(against: manifest)
    #expect(throws: PinewindError.self) {
      try loaded.validate(against: Manifest(entries: [.package(a)]))
    }
  }

  @Test func workingTreesAndCorruptLocksFail() throws {
    let f = try Fixture()
    defer { f.remove() }
    #expect(throws: PinewindError.self) {
      try LockedPackage(request: f.request(f.a), commit: String(repeating: "a", count: 40))
    }
    let file = f.input.appendingPathComponent("pinewind.lock")
    try Data("not a lock".utf8).write(to: file)
    #expect(throws: PinewindError.self) { try Resolution.read(from: file) }
  }
}
