// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
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

  func coordinate<Value>(
    _ requests: [FileAccessRequest],
    accessor: @escaping @Sendable ([URL]) throws -> sending Value
  ) async throws -> sending Value {
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
  private(set) var intents: [FileAccessRequest.Intent] = []
  init(directory: URL) { self.directory = directory }

  func coordinate<Value>(
    _ requests: [FileAccessRequest],
    accessor: @escaping @Sendable ([URL]) throws -> sending Value
  ) async throws -> sending Value {
    intents += requests.map(\.intent)
    return try accessor(requests.map { directory.appendingPathComponent($0.url.lastPathComponent) })
  }
}

// Deliberately non-Sendable: the accessor transfers a freshly constructed result exactly once.
private final class CoordinatedValue {
  var count = 1
}

@Suite("Platform file coordination")
struct FileAccessCoordinatorTests {
  @Test func accessorCanTransferANonSendableResult() async throws {
    let f = CoordinationFixture()
    defer { f.remove() }
    let coordinator = FileAccessCoordinator.platform(localStateRoot: f.local)
    let value = try await coordinator.coordinate([
      FileAccessRequest(url: f.input.appendingPathComponent("absent.yaml"), intent: .read)
    ]) { _ in CoordinatedValue() }
    value.count += 1
    #expect(value.count == 2)
  }

  @Test func accessorsUseCoordinatedURLsAndDistinctWriteDeleteIntents() async throws {
    let f = CoordinationFixture()
    defer { f.remove() }
    let actual = f.root.appendingPathComponent("relocated")
    let coordinator = RedirectingCoordinator(directory: actual)
    let configuration = try await Configuration.load(
      inputRoot: f.input, localStateRoot: f.local, coordinator: coordinator)
    try await configuration.saveShared()
    await configuration.edit { _, local in local = LocalOverridesDocument() }
    try await configuration.saveLocalOverrides()
    let reloaded = try await Configuration.load(
      inputRoot: f.input, localStateRoot: f.local, coordinator: coordinator)
    let snapshot = await reloaded.snapshot()
    #expect(snapshot.localOverrides != nil)
    #expect(!FileManager.default.fileExists(atPath: f.input.path))
    #expect(!FileManager.default.fileExists(atPath: f.local.path))
    #expect(
      FileManager.default.fileExists(atPath: actual.appendingPathComponent("pinewind.yaml").path))
    await configuration.edit { _, local in local = nil }
    try await configuration.saveLocalOverrides()
    #expect(
      !FileManager.default.fileExists(
        atPath: actual.appendingPathComponent("pinewind.local.yaml").path))
    let intents = await coordinator.intents
    #expect(intents == [.read, .read, .write, .write, .read, .read, .delete])
  }

  @Test func saveWaitsSerializeIOButDoNotOverwriteNewEdits() async throws {
    let f = CoordinationFixture()
    defer { f.remove() }
    let coordinator = ControlledCoordinator(
      base: FileAccessCoordinator.platform(localStateRoot: f.local))
    let configuration = try await Configuration.load(
      inputRoot: f.input, localStateRoot: f.local, coordinator: coordinator)
    let first = Task { try await configuration.saveShared() }
    await coordinator.waitForWrite()
    await configuration.edit { shared, _ in shared.order = [] }
    let second = Task { try await configuration.saveShared() }
    let third = Task { try await configuration.saveShared() }
    let duringWait = await configuration.snapshot()
    #expect(duringWait.manifest.order.isEmpty)
    await coordinator.releaseWrite()
    try await first.value
    try await second.value
    try await third.value
    #expect(await coordinator.maximumWrites == 1)
    let saved = try await Configuration.load(inputRoot: f.input, localStateRoot: f.local)
    #expect(await saved.snapshot().manifest.order.isEmpty)
    #expect(await configuration.snapshot().manifest.order.isEmpty)
  }

  @Test func coordinationFailureReleasesIOAndPreservesBaseline() async throws {
    let f = CoordinationFixture()
    defer { f.remove() }
    let coordinator = ControlledCoordinator(
      base: FileAccessCoordinator.platform(localStateRoot: f.local))
    let configuration = try await Configuration.load(
      inputRoot: f.input, localStateRoot: f.local, coordinator: coordinator)
    await coordinator.failNextWrite()
    let save = Task { try await configuration.saveShared() }
    await coordinator.waitForWrite()
    await coordinator.releaseWrite()
    await #expect(throws: PinewindError.self) { try await save.value }
    #expect(
      !FileManager.default.fileExists(atPath: f.input.appendingPathComponent("pinewind.yaml").path))
    try await configuration.saveShared()
    let loaded = try await Configuration.load(inputRoot: f.input, localStateRoot: f.local)
    #expect(await loaded.snapshot().manifest.order == [.userFiles(FileFilter())])
  }

  @Test func twoSessionsCannotBothOverwriteTheSameBaseline() async throws {
    let f = CoordinationFixture()
    defer { f.remove() }
    let first = try await Configuration.load(inputRoot: f.input, localStateRoot: f.local)
    let second = try await Configuration.load(inputRoot: f.input, localStateRoot: f.local)
    await second.edit { shared, _ in shared.order = [] }
    let successes = try await withThrowingTaskGroup(of: Bool.self) { group in
      for configuration in [first, second] {
        group.addTask {
          do {
            try await configuration.saveShared()
            return true
          } catch let error as PinewindError {
            #expect(error.message.contains("changed on disk"))
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
    let configuration = try await Configuration.load(inputRoot: f.input, localStateRoot: f.local)
    #expect(await configuration.snapshot().localOverrides == nil)
    await configuration.edit { _, local in local = LocalOverridesDocument() }
    try await configuration.saveLocalOverrides()
    #expect(
      FileManager.default.fileExists(
        atPath: f.local.appendingPathComponent("pinewind.local.yaml").path))
    #expect(
      try String(contentsOf: f.input.appendingPathComponent("pinewind.local.yaml"), encoding: .utf8)
        == "not valid YAML: [")
    await #expect(throws: PinewindError.self) {
      try await Configuration.load(
        inputRoot: f.input, localStateRoot: f.input.appendingPathComponent("local"))
    }
  }
}
