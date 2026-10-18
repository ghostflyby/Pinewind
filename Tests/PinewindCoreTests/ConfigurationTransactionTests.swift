// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage
import Testing

@testable import PinewindCore

private actor RecordingTransactionCoordinator: FileAccessCoordinating {
  let base: any FileAccessCoordinating
  private(set) var batches: [[FileAccessRequest]] = []
  init(base: any FileAccessCoordinating) { self.base = base }
  func coordinate<Value: Sendable>(
    _ requests: [FileAccessRequest], accessor: @escaping @Sendable ([URL]) throws -> Value
  ) async throws -> Value {
    batches.append(requests)
    return try await base.coordinate(requests, accessor: accessor)
  }
}

@Suite("Configuration transactions")
struct ConfigurationTransactionTests {
  private struct Fixture {
    let root = FilePath(FileManager.default.temporaryDirectory.path).appending(UUID().uuidString)
    var locations: WorkspaceLocations {
      get throws {
        try WorkspaceLocations(
          userFilesRoot: .path(root.appending("user")),
          configuration: ConfigurationFiles(
            manifest: .path(root.appending("shared/manifest.yaml")),
            localOverrides: .path(root.appending("local/overrides.yaml")),
            lock: .path(root.appending("lock/resolution"))),
          stateRoot: root.appending("state"), cacheRoot: root.appending("cache"))
      }
    }
    var store: ConfigurationStore { get throws { ConfigurationStore(try locations) } }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func bytes(_ text: String) -> Data { Data(text.utf8) }
  }

  @Test(arguments: 0..<8)
  func recoveryCompletesEveryInterruptedSubsetBeforeAReaderObservesDocuments(_ mask: Int)
    async throws
  {
    let f = Fixture()
    defer { f.remove() }
    let store = try f.store
    let documents = try store.documentLocations.map { try $0.url }
    let identities = documents.map(\.absoluteString)
    let shared = Data(try ManifestDocument(order: []).yaml().utf8)
    let local = Data(try LocalOverridesDocument().yaml().utf8)
    let before: [Data?] = [nil, nil, nil]
    let after: [Data?] = [shared, f.bytes("locked"), local]
    let transaction = ConfigurationTransaction(
      version: 1, documents: identities, before: before, after: after)
    try DurableFile.write(
      PropertyListEncoder().encode(transaction), to: NativePath.from(store.transactionLocation))
    for index in documents.indices where mask & (1 << index) != 0 {
      try DurableFile.write(after[index], to: NativePath.from(documents[index]))
    }
    // New store instance models a caller after process termination.
    let recovered = try await ConfigurationStore(f.locations).load()
    #expect(recovered.manifest.order.isEmpty)
    #expect(recovered.localOverrides != nil)
    #expect(recovered.baseline.lock == f.bytes("locked"))
    #expect(try documents.map(ConfigurationStore.read) == after)
    #expect(try ConfigurationStore.read(store.transactionLocation) == nil)
  }

  @Test func recoveryReacquiresWriteIntentsBeforeChangingDocuments() async throws {
    let f = Fixture()
    defer { f.remove() }
    let locations = try f.locations
    let recorder = RecordingTransactionCoordinator(
      base: FileAccessCoordinator.platform(stateRoot: locations.stateRoot))
    let store = ConfigurationStore(locations, coordinator: recorder)
    _ = try await store.load()
    #expect(await recorder.batches.count == 1)
    #expect(await recorder.batches[0].dropLast().allSatisfy { $0.intent == .read })
    let documents = try store.documentLocations.map { try $0.url }
    let transaction = ConfigurationTransaction(
      version: 1, documents: documents.map(\.absoluteString), before: [nil, nil, nil],
      after: [Data(try ManifestDocument(order: []).yaml().utf8), f.bytes("locked"), nil])
    try DurableFile.write(
      PropertyListEncoder().encode(transaction), to: NativePath.from(store.transactionLocation))
    _ = try await store.load()
    let batches = await recorder.batches
    #expect(batches.count == 3)
    #expect(batches[1].dropLast().allSatisfy { $0.intent == .read })
    #expect(batches[2].dropLast().allSatisfy { $0.intent == .write })
  }

  @Test func recoveryDoesNotOverwriteExternalChangesOrTouchOtherDocuments() async throws {
    let f = Fixture()
    defer { f.remove() }
    let store = try f.store
    let documents = try store.documentLocations.map { try $0.url }
    let after: [Data?] = [f.bytes("proposed"), f.bytes("locked"), nil]
    let transaction = ConfigurationTransaction(
      version: 1, documents: documents.map(\.absoluteString), before: [nil, nil, nil], after: after)
    try DurableFile.write(
      PropertyListEncoder().encode(transaction), to: NativePath.from(store.transactionLocation))
    try DurableFile.write(f.bytes("external"), to: NativePath.from(documents[0]))
    await #expect(throws: StateFailure.externallyModified) { _ = try await store.load() }
    #expect(try ConfigurationStore.read(documents[0]) == f.bytes("external"))
    #expect(try ConfigurationStore.read(documents[1]) == nil)
    #expect(try ConfigurationStore.read(store.transactionLocation) != nil)
  }

  @Test func corruptOrForeignJournalsFailWithoutPublishingAnything() async throws {
    let f = Fixture()
    defer { f.remove() }
    let store = try f.store
    let journal = try store.transactionLocation
    try DurableFile.write(Data(), to: NativePath.from(journal))
    let expected = StateFailure.invalidConfigurationTransaction(try NativePath.from(journal))
    await #expect(throws: expected) { _ = try await store.load() }
    let foreign = ConfigurationTransaction(
      version: 1, documents: ["other"], before: [nil], after: [f.bytes("foreign")])
    try DurableFile.write(PropertyListEncoder().encode(foreign), to: NativePath.from(journal))
    await #expect(throws: expected) { _ = try await store.load() }
    for location in store.documentLocations {
      #expect(try ConfigurationStore.read(location.url) == nil)
    }
  }

  @Test func committedTransactionCanRemoveLocalOverridesAndIsDurableForTheNextReader() async throws
  {
    let f = Fixture()
    defer { f.remove() }
    let store = try f.store
    let documents = try store.documentLocations.map { try $0.url }
    let oldLocal = Data(try LocalOverridesDocument().yaml().utf8)
    try DurableFile.write(oldLocal, to: NativePath.from(documents[2]))
    let after: [Data?] = [
      Data(try ManifestDocument(order: []).yaml().utf8), f.bytes("locked"), nil,
    ]
    let transaction = ConfigurationTransaction(
      version: 1, documents: documents.map(\.absoluteString), before: [nil, nil, oldLocal],
      after: after)
    try transaction.commit(at: store.transactionLocation, documents: documents)
    let loaded = try await store.load()
    #expect(loaded.localOverrides == nil)
    #expect(loaded.manifest.order.isEmpty)
    #expect(try documents.map(ConfigurationStore.read) == after)
    #expect(try ConfigurationStore.read(store.transactionLocation) == nil)
  }
}
