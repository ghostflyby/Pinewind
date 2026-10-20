// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0

#if os(Windows)
  import Foundation
  import SystemPackage
  import Testing
  import WinSDK

  @testable import PinewindCore

  @Suite("Windows legacy managed publication identity")
  struct WindowsLegacyPublicationTests {
    @Test func nativePathsStripExtendedDOSAndUNCPrefixes() throws {
      #expect(
        try windowsNativePath(FilePath("\\\\?\\C:\\Users\\Example\\Output"))
          == FilePath("C:\\Users\\Example\\Output"))
      #expect(
        try windowsNativePath(FilePath("\\\\?\\UNC\\server\\share\\Output"))
          == FilePath("\\\\server\\share\\Output"))
      #expect(
        try windowsNativePath(FilePath("\\\\server\\share\\Output"))
          == FilePath("\\\\server\\share\\Output"))
    }

    @Test(arguments: [false, true])
    func legacyCommittedAndPendingRecordsAreReusedWithoutForce(caseAlias: Bool) throws {
      let fixture = try LegacyPublicationFixture()
      defer { fixture.remove() }
      let requested =
        caseAlias
        ? fixture.output.removingLastComponent().appending(
          fixture.output.lastComponent!.string.uppercased())
        : fixture.output
      try fixture.verifyLegacyRecovery(requested: requested)
    }

    @Test func legacyRecordsAreReusedThroughAnAvailableShortNameAlias() throws {
      let fixture = try LegacyPublicationFixture()
      defer { fixture.remove() }
      // 8.3 name creation is disabled on some Windows filesystems. This branch
      // exercises the alias only when the filesystem supplies a distinct one;
      // the ordinary/case-alias regression above runs unconditionally.
      var buffer = [WCHAR](repeating: 0, count: 32_768)
      let count = fixture.output.withPlatformString {
        GetShortPathNameW($0, &buffer, DWORD(buffer.count))
      }
      guard count > 0, Int(count) < buffer.count else { return }
      let short = FilePath(platformString: buffer)
      guard short.string.lowercased() != fixture.output.string.lowercased() else { return }
      try fixture.verifyLegacyRecovery(requested: short)
    }
  }

  private struct LegacyPublicationFixture {
    let root: FilePath
    var input: FilePath { root.appending("input") }
    var output: FilePath { root.appending("Long Output Configuration") }
    var state: FilePath { root.appending("state") }
    var cache: FilePath { root.appending("cache") }

    init() throws {
      root = try NativePath.from(
        FileManager.default.temporaryDirectory.appendingPathComponent(
          "pinewind-legacy-" + UUID().uuidString))
      for directory in [input, output, state, cache] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private func write(_ relative: String, _ bytes: String, in directory: FilePath) throws {
      try Data(bytes.utf8).write(to: directory.appending(relative))
    }

    func verifyLegacyRecovery(requested: FilePath) throws {
      try write("keep.yaml", "same", in: output)
      try write("config.yaml", "old", in: output)
      try write("obsolete.yaml", "committed obsolete", in: output)
      try write("pending-obsolete.yaml", "pending obsolete", in: output)
      try write("keep.yaml", "same", in: input)
      try write("config.yaml", "new", in: input)

      // Reproduce the old implementation independently: it hashed the UTF-8
      // spelling returned by SafePath.canonical(publication), which already
      // strips extended-length prefixes and resolves case/short-name aliases.
      let oldTarget = try SafePath.canonical(requested)
      let keyBytes = root.appending("old-key-bytes")
      try Data(oldTarget.string.utf8).write(to: keyBytes)
      let oldKey = try SnapshotFiles.sha256(keyBytes)
      let directory = state.appending("publications")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let committed = directory.appending(oldKey + ".plist")
      let pending = directory.appending(oldKey + ".pending.plist")

      func legacyRecord(_ names: [String]) throws -> Data {
        let entries = try names.map { name in
          ["path": name, "sha256": try SnapshotFiles.sha256(output.appending(name))]
        }
        // Deliberately not the new Codable Record: old v1 files had no sourceRoots.
        return try PropertyListSerialization.data(
          fromPropertyList: ["version": 1, "target": oldTarget.string, "files": entries],
          format: .xml, options: 0)
      }
      try legacyRecord(["keep.yaml", "config.yaml", "obsolete.yaml"]).write(to: committed)
      try legacyRecord(["pending-obsolete.yaml"]).write(to: pending)
      #expect(try PublicationLock.output(requested) == oldTarget)

      let plan = try CompositionPlanner(snapshotRoot: cache.appending("planning")).plan(
        Manifest(entries: [.userFiles(FileFilter())]), inputRoot: input)
      let publisher = ManagedFilePublisher(stateRoot: state, cacheRoot: cache)
      let result = try publisher.compose(plan, inputRoot: input, outputRoot: requested)
      #expect(result.reusedPaths.map(\.string) == ["keep.yaml"])
      #expect(result.changedPaths.map(\.string) == ["config.yaml"])
      #expect(result.removedPaths.map(\.string) == ["obsolete.yaml", "pending-obsolete.yaml"])
      #expect(result.overwrittenUnmanagedPaths.isEmpty)
      #expect(result.warnings.isEmpty)
      #expect(try String(contentsOf: output.appending("config.yaml"), encoding: .utf8) == "new")
      #expect(!FileManager.default.fileExists(atPath: pending.string))
      #expect(!FileManager.default.fileExists(atPath: output.appending("obsolete.yaml").string))
      #expect(
        !FileManager.default.fileExists(atPath: output.appending("pending-obsolete.yaml").string))

      let record = try #require(
        PropertyListSerialization.propertyList(from: Data(contentsOf: committed), format: nil)
          as? [String: Any])
      #expect(record["target"] as? String == oldTarget.string)
      #expect(record["sourceRoots"] as? [String] != nil)
      let children = try FileManager.default.contentsOfDirectory(atPath: directory.string)
      #expect(children == [oldKey + ".plist"])

      let repeated = try publisher.compose(plan, inputRoot: input, outputRoot: requested)
      #expect(repeated.changedPaths.isEmpty)
      #expect(repeated.removedPaths.isEmpty)
      #expect(repeated.reusedPaths.map(\.string) == ["config.yaml", "keep.yaml"])
      #expect(repeated.overwrittenUnmanagedPaths.isEmpty)
    }
  }
#endif
