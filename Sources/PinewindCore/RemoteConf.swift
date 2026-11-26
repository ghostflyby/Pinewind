// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

public struct ImportLimits: Sendable {
  public let timeout: Duration
  public let maximumSources: Int
  public let maximumFileBytes: Int
  public let maximumTotalBytes: Int
  public init(
    timeout: Duration = .seconds(5), maximumSources: Int = 64,
    maximumFileBytes: Int = 1_048_576, maximumTotalBytes: Int = 4_194_304
  ) {
    self.timeout = timeout
    self.maximumSources = maximumSources
    self.maximumFileBytes = maximumFileBytes
    self.maximumTotalBytes = maximumTotalBytes
  }
}

protocol ConfResourceCapture: Sendable {
  func ensure(_ path: RelativePath) async throws
}

actor RemoteConfCapture: ConfResourceCapture {
  let url: URL
  let directory: FilePath
  let store: ResourceStore
  let limits: ImportLimits
  private var pins: [RelativePath: PinnedResource] = [:]
  private var totalBytes: UInt64 = 0
  init(url: URL, directory: FilePath, store: ResourceStore, limits: ImportLimits) {
    self.url = url
    self.directory = directory
    self.store = store
    self.limits = limits
  }
  func ensure(_ relative: RelativePath) async throws {
    try Task.checkCancellation()
    if pins[relative] != nil { return }
    guard pins.count < limits.maximumSources else {
      throw InterpreterFailure.budgetExceeded(.sources)
    }
    guard totalBytes < limits.maximumTotalBytes else {
      throw InterpreterFailure.budgetExceeded(.totalBytes)
    }
    let endpoint =
      relative.string == url.lastPathComponent
      ? url : url.deletingLastPathComponent().appendingPathComponent(relative.string)
    let pin = try await store.pin(endpoint, target: relative, maximumBytes: limits.maximumFileBytes)
    let dataPath = store.path(pin)
    let size = try SnapshotFiles.byteCount(dataPath)
    guard totalBytes + size <= limits.maximumTotalBytes else {
      throw InterpreterFailure.budgetExceeded(.totalBytes)
    }
    let destination = try SafePath.file(relative, in: directory)
    try FileManager.default.createDirectory(
      at: destination.removingLastComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: dataPath, to: destination)
    totalBytes += size
    pins[relative] = pin
  }
  func resources() -> [PinnedResource] { pins.values.sorted { $0.path < $1.path } }
}

actor LocalConfCapture: ConfResourceCapture {
  let root: URL
  let directory: FilePath
  let coordinator: any FileAccessCoordinating
  let limits: ImportLimits
  private var captured = Set<RelativePath>()
  private var totalBytes: UInt64 = 0
  init(
    root: URL, directory: FilePath, coordinator: any FileAccessCoordinating, limits: ImportLimits
  ) {
    self.root = root
    self.directory = directory
    self.coordinator = coordinator
    self.limits = limits
  }
  func ensure(_ relative: RelativePath) async throws {
    if captured.contains(relative) { return }
    let source = root.appendingPathComponent(relative.string)
    let destination = try SafePath.file(relative, in: directory)
    let maximum = limits.maximumFileBytes
    let remaining = UInt64(limits.maximumTotalBytes) - totalBytes
    _ = try SafePath.file(relative, in: NativePath.from(root))
    let size = try await coordinator.coordinate([FileAccessRequest(url: source, intent: .read)]) {
      urls in
      let source = try NativePath.from(urls[0])
      let size = try SnapshotFiles.byteCount(source)
      guard size <= maximum else {
        throw InterpreterFailure.budgetExceeded(.fileBytes)
      }
      guard size <= remaining else {
        throw InterpreterFailure.budgetExceeded(.totalBytes)
      }
      try FileManager.default.createDirectory(
        at: destination.removingLastComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: source, to: destination)
      return size
    }
    totalBytes += size
    captured.insert(relative)
  }
}
