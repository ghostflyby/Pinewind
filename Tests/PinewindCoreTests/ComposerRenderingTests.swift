// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0

import Foundation
import SystemPackage
import Testing

@testable import PinewindCore

@Suite("Private composition candidates")
struct ComposerRenderingTests {
  @Test func privateRenderingUsesCapturedBytesWithoutPublicationArtifacts() throws {
    let fixture = try RenderingFixture()
    defer { fixture.remove() }
    try fixture.write("nested/config.yaml", "captured", in: fixture.input)
    let plan = try fixture.plan()
    try fixture.write("nested/config.yaml", "later edit", in: fixture.input)
    let candidate = fixture.root.appending("rendered")
    let paths = try Composer().renderCandidate(plan, inputRoot: fixture.input, to: candidate)
    #expect(paths.map(\.string) == ["nested/config.yaml"])
    #expect(
      try String(contentsOf: candidate.appending("nested/config.yaml"), encoding: .utf8)
        == "captured")
    let children = try FileManager.default.contentsOfDirectory(atPath: fixture.root.string)
    #expect(Set(children) == ["input", "planning", "rendered"])
    #if os(Windows)
      #expect(try WindowsDirectoryPublisher.currentTarget(candidate) == nil)
    #endif
    try fixture.write("nested/config.yaml", "caller edit", in: candidate)
    #expect(
      try String(contentsOf: fixture.input.appending("nested/config.yaml"), encoding: .utf8)
        == "later edit")
  }

  @Test func privateRenderingRejectsSourceOverlapAndPreservesExistingDestinations() throws {
    let fixture = try RenderingFixture()
    defer { fixture.remove() }
    try fixture.write("config.yaml", "source", in: fixture.input)
    let plan = try fixture.plan()
    let overlapping = fixture.input.appending("rendered")
    #expect(throws: FileSystemFailure.self) {
      _ = try Composer().renderCandidate(plan, inputRoot: fixture.input, to: overlapping)
    }
    #expect(!FileManager.default.fileExists(atPath: overlapping.string))
    let existing = fixture.root.appending("existing")
    try fixture.write("keep", "protected", in: existing)
    #expect(throws: FileSystemFailure.self) {
      _ = try Composer().renderCandidate(plan, inputRoot: fixture.input, to: existing)
    }
    #expect(try String(contentsOf: existing.appending("keep"), encoding: .utf8) == "protected")
  }

  @Test func staleBindingAndCancellationCannotLeavePrivateCandidates() async throws {
    let fixture = try RenderingFixture()
    defer { fixture.remove() }
    try fixture.write("nested/config.yaml", "source", in: fixture.input)
    let locations = try fixtureLocations(
      input: fixture.input.foundationURL, local: fixture.root.appending("local").foundationURL)
    let workspace = try await Workspace.open(locations: locations)
    let plan = try await workspace.plan(workspace.cachedInputs())
    try fixture.write("pinewind.yaml", "version: 1\norder: [self]\n", in: fixture.input)
    let stale = fixture.root.appending("stale")
    #expect(throws: StateFailure.staleInputs) {
      _ = try Composer().renderCandidate(plan, inputRoot: fixture.input, to: stale)
    }
    #expect(!FileManager.default.fileExists(atPath: stale.string))

    let cancelled = fixture.root.appending("cancelled")
    let signal = CancellationSignal()
    signal.cancel()
    #expect(throws: CancellationError.self) {
      _ = try Cancellation.$signal.withValue(signal) {
        try Composer().renderCandidate(plan, inputRoot: fixture.input, to: cancelled)
      }
    }
    #expect(!FileManager.default.fileExists(atPath: cancelled.string))
  }
}

private struct RenderingFixture {
  let root: FilePath
  var input: FilePath { root.appending("input") }

  init() throws {
    root = try NativePath.from(
      FileManager.default.temporaryDirectory.appendingPathComponent(
        "pinewind-rendering-" + UUID().uuidString))
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  func write(_ relative: String, _ text: String, in directory: FilePath) throws {
    let file = directory.appending(relative)
    try FileManager.default.createDirectory(
      at: file.removingLastComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
  }

  func plan() throws -> CompositionPlan {
    try CompositionPlanner(snapshotRoot: root.appending("planning")).plan(
      Manifest(entries: [.userFiles(FileFilter())]), inputRoot: input)
  }
}
