// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage
import Testing

@testable import PinewindCore

private struct CoordinationFixture {
  let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("pinewind-coordination-" + UUID().uuidString)
  var input: URL { root.appendingPathComponent("input") }
  var local: URL { root.appendingPathComponent("local") }
  func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor ControlledCoordinator: FileAccessCoordinating {
  let base: any FileAccessCoordinating
  private var pauseNextWrite = true
  private var pendingWrite: CheckedContinuation<Void, Never>?
  private var startedWaiters: [CheckedContinuation<Void, Never>] = []
  private var failNext = false
  private var activeWrites = 0
  private(set) var maximumWrites = 0

  init(base: any FileAccessCoordinating) { self.base = base }

  func waitForWrite() async {
    if pendingWrite == nil {
      await withCheckedContinuation { startedWaiters.append($0) }
    }
  }

  func releaseWrite() {
    pendingWrite?.resume()
    pendingWrite = nil
  }

  func failNextWrite() { failNext = true }

  func coordinate<Value: Sendable>(
    _ requests: [FileAccessRequest],
    accessor: @escaping @Sendable ([URL]) throws -> Value
  ) async throws -> Value {
    let writing = requests.contains { $0.intent != .read }
    if writing {
      activeWrites += 1
      maximumWrites = max(maximumWrites, activeWrites)
    }
    defer { if writing { activeWrites -= 1 } }
    if writing && pauseNextWrite {
      pauseNextWrite = false
      await withCheckedContinuation { continuation in
        pendingWrite = continuation
        for waiter in startedWaiters { waiter.resume() }
        startedWaiters.removeAll()
      }
    }
    if writing && failNext {
      failNext = false
      throw PinewindError("test coordination failure")
    }
    return try await base.coordinate(requests, accessor: accessor)
  }
}

private actor RedirectingCoordinator: FileAccessCoordinating {
  let directory: URL
  private(set) var requests: [FileAccessRequest] = []
  init(directory: URL) { self.directory = directory }

  func coordinate<Value: Sendable>(
    _ requests: [FileAccessRequest],
    accessor: @escaping @Sendable ([URL]) throws -> Value
  ) async throws -> Value {
    self.requests += requests
    return try accessor(requests.map { directory.appendingPathComponent($0.url.lastPathComponent) })
  }
}

@Suite("Platform file coordination")
struct FileAccessCoordinatorTests {
  @Test func accessorsUseCoordinatedURLsAndDistinctWriteDeleteIntents() async throws {
    let f = CoordinationFixture()
    defer { f.remove() }
    let actual = f.root.appendingPathComponent("relocated")
    let coordinator = RedirectingCoordinator(directory: actual)
    let configuration = try await loadConfiguration(
      inputRoot: f.input, localStateRoot: f.local, coordinator: coordinator)
    _ = try await configuration.save(.shared)
    await configuration.edit { draft in draft.localOverrides = LocalOverridesDocument() }
    _ = try await configuration.save(.local)
    let reloaded = try await loadConfiguration(
      inputRoot: f.input, localStateRoot: f.local, coordinator: coordinator)
    let snapshot = await reloaded.snapshot()
    #expect(snapshot.localOverrides != nil)
    #expect(!FileManager.default.fileExists(atPath: f.input.path))
    #expect(!FileManager.default.fileExists(atPath: f.local.path))
    #expect(
      FileManager.default.fileExists(atPath: actual.appendingPathComponent("pinewind.yaml").path))
    await configuration.edit { draft in draft.localOverrides = nil }
    _ = try await configuration.save(.local)
    #expect(
      !FileManager.default.fileExists(
        atPath: actual.appendingPathComponent("pinewind.local.yaml").path))
    let writes = await coordinator.requests.filter { $0.intent != .read }
    #expect(writes.map(\.intent) == [.write, .write, .delete])
    #expect(
      writes.map { $0.url.lastPathComponent } == [
        "pinewind.yaml", "pinewind.local.yaml", "pinewind.local.yaml",
      ])
  }

  @Test func saveWaitsSerializeIOButDoNotOverwriteNewEdits() async throws {
    let f = CoordinationFixture()
    defer { f.remove() }
    let coordinator = ControlledCoordinator(
      base: FileAccessCoordinator.platform(
        stateRoot: native(f.local.appendingPathComponent("coordination"))))
    let configuration = try await loadConfiguration(
      inputRoot: f.input, localStateRoot: f.local, coordinator: coordinator)
    let first = Task { _ = try await configuration.save(.shared) }
    await coordinator.waitForWrite()
    await configuration.edit { draft in draft.manifest.order = [] }
    let second = Task { _ = try await configuration.save(.shared) }
    let third = Task { _ = try await configuration.save(.shared) }
    let duringWait = await configuration.snapshot()
    #expect(duringWait.manifest.order.isEmpty)
    await coordinator.releaseWrite()
    try await first.value
    try await second.value
    try await third.value
    #expect(await coordinator.maximumWrites == 1)
    let saved = try await loadConfiguration(inputRoot: f.input, localStateRoot: f.local)
    #expect(await saved.snapshot().manifest.order.isEmpty)
    #expect(await configuration.snapshot().manifest.order.isEmpty)
  }

  @Test func coordinationFailureReleasesIOAndPreservesBaseline() async throws {
    let f = CoordinationFixture()
    defer { f.remove() }
    let coordinator = ControlledCoordinator(
      base: FileAccessCoordinator.platform(
        stateRoot: native(f.local.appendingPathComponent("coordination"))))
    let configuration = try await loadConfiguration(
      inputRoot: f.input, localStateRoot: f.local, coordinator: coordinator)
    await coordinator.failNextWrite()
    let save = Task { _ = try await configuration.save(.shared) }
    await coordinator.waitForWrite()
    await coordinator.releaseWrite()
    await #expect(throws: PinewindError.self) { try await save.value }
    #expect(
      !FileManager.default.fileExists(atPath: f.input.appendingPathComponent("pinewind.yaml").path))
    _ = try await configuration.save(.shared)
    let loaded = try await loadConfiguration(inputRoot: f.input, localStateRoot: f.local)
    #expect(await loaded.snapshot().manifest.order == [.userFiles(FileFilter())])
  }

  @Test func twoSessionsCannotBothOverwriteTheSameBaseline() async throws {
    let f = CoordinationFixture()
    defer { f.remove() }
    let first = try await loadConfiguration(inputRoot: f.input, localStateRoot: f.local)
    let second = try await loadConfiguration(inputRoot: f.input, localStateRoot: f.local)
    await second.edit { draft in draft.manifest.order = [] }
    let successes = try await withThrowingTaskGroup(of: Bool.self) { group in
      for configuration in [first, second] {
        group.addTask {
          do {
            _ = try await configuration.save(.shared)
            return true
          } catch let error as PinewindError {
            #expect(error.code == .configurationConflict)
            return false
          }
        }
      }
      var count = 0
      for try await succeeded in group { if succeeded { count += 1 } }
      return count
    }
    #expect(successes == 1)
  }

  @Test func localStateIsSeparateAndOldInTreeOverridesAreNotApplied() async throws {
    let f = CoordinationFixture()
    defer { f.remove() }
    try FileManager.default.createDirectory(at: f.input, withIntermediateDirectories: true)
    // This former location must not silently redirect the shared package anymore.
    try Data("not valid YAML: [".utf8).write(
      to: f.input.appendingPathComponent("pinewind.local.yaml"))
    let configuration = try await loadConfiguration(inputRoot: f.input, localStateRoot: f.local)
    #expect(await configuration.snapshot().localOverrides == nil)
    await configuration.edit { draft in draft.localOverrides = LocalOverridesDocument() }
    _ = try await configuration.save(.local)
    #expect(
      FileManager.default.fileExists(
        atPath: f.local.appendingPathComponent("pinewind.local.yaml").path))
    #expect(
      try String(contentsOf: f.input.appendingPathComponent("pinewind.local.yaml"), encoding: .utf8)
        == "not valid YAML: [")
    await #expect(throws: PinewindError.self) {
      try await loadConfiguration(
        inputRoot: f.input, localStateRoot: f.input.appendingPathComponent("local"))
    }
  }
  @Test func saveReceiptTracksOnlyTheCapturedDraftRevision() async throws {
    let f = CoordinationFixture()
    defer { f.remove() }
    let coordinator = ControlledCoordinator(
      base: FileAccessCoordinator.platform(
        stateRoot: native(f.local.appendingPathComponent("coordination"))))
    let session = try await loadConfiguration(
      inputRoot: f.input, localStateRoot: f.local, coordinator: coordinator)
    let saving = Task { try await session.save(.shared) }
    await coordinator.waitForWrite()
    await session.edit { draft in draft.manifest.order = [] }
    await coordinator.releaseWrite()
    let receipt = try await saving.value
    #expect(receipt.revision == 0)
    #expect(await session.snapshot().sharedRevision == 1)
    #expect(await session.snapshot().sharedIsDirty)
    _ = try await session.save(.shared)
    #expect(await session.snapshot().sharedIsDirty == false)
  }

}
