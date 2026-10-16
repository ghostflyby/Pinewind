// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BashInterpreter
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
    let endpoint =
      relative.string == url.lastPathComponent
      ? url : url.deletingLastPathComponent().appendingPathComponent(relative.string)
    let pin = try await store.pin(endpoint, target: relative)
    let dataPath = store.path(pin)
    let size = try SnapshotFiles.byteCount(dataPath)
    guard size <= limits.maximumFileBytes, totalBytes + size <= limits.maximumTotalBytes else {
      throw PinewindError(.resourceLimit, "conf file exceeds resource limit")
    }
    guard pins.count < limits.maximumSources else {
      throw PinewindError(.resourceLimit, "conf resource count exceeded")
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

/// Lazy reads are fulfilled by the acquisition layer; the shell only sees a read-only mount.
struct RemoteConfFileSystem: FileSystem {
  let capture: any ConfResourceCapture
  let original: MountedFileSystem?
  let mounted: MountedFileSystem
  init(capture: any ConfResourceCapture, directory: FilePath, original: MountedFileSystem? = nil) {
    self.capture = capture
    self.original = original
    mounted = MountedFileSystem(
      mounts: [.init(virtual: "/conf", host: directory.string, readOnly: true)],
      backing: RealFileSystem())
  }
  func metadata(_ path: String) async throws -> FileMetadata? {
    if let original { return try await original.metadata(path) }
    do { if let value = try await mounted.metadata(path) { return value } } catch FileSystemError
      .notFound
    {}
    do {
      try await capture.ensure(resourcePath(path))
      return try await mounted.metadata(path)
    } catch let error as PinewindError where error.code == .contentMissing { return nil }
  }

  func list(_ path: String) async throws -> [FileEntry] {
    if let original { return try await original.list(path) }
    throw PinewindError(
      .unsupportedOperation, "remote conf directory enumeration is unsupported", source: path)
  }
  func canonicalize(_ path: String, allowMissing: Bool) async throws -> String {
    // SourceCommand ultimately reads through readData; do not interpret metadata as a remote listing.
    try await mounted.canonicalize(path, allowMissing: true)
  }
  func readData(_ path: String) async throws -> Data {
    try await capture.ensure(resourcePath(path))
    return try await mounted.readData(path)
  }
  // SwiftBash exposes POSIX virtual paths as text even when the host is Windows.
  private func resourcePath(_ text: String) throws -> RelativePath {
    guard text.hasPrefix("/"), !text.contains("\0"), !text.contains("\\") else {
      throw FileSystemError.permissionDenied(text)
    }
    let path = FilePath(text).lexicallyNormalized()
    guard path.root == FilePath("/").root, path.components.first?.string == "conf" else {
      throw FileSystemError.permissionDenied(text)
    }
    return try RelativePath(FilePath(root: nil, path.components.dropFirst()))
  }
  func openRead(_ path: String) async throws -> InputSource { .data(try await readData(path)) }
  func writeData(_ data: Data, to path: String, append: Bool) async throws {
    throw FileSystemError.permissionDenied(path)
  }
  func openWrite(_ path: String, append: Bool) async throws -> OutputSink {
    throw FileSystemError.permissionDenied(path)
  }
  func touch(_ path: String) async throws { throw FileSystemError.permissionDenied(path) }
  func createDirectory(_ path: String, intermediates: Bool) async throws {
    throw FileSystemError.permissionDenied(path)
  }
  func remove(_ path: String, recursive: Bool) async throws {
    throw FileSystemError.permissionDenied(path)
  }
  func move(from source: String, to destination: String) async throws {
    throw FileSystemError.permissionDenied(destination)
  }
  func copy(from source: String, to destination: String) async throws {
    throw FileSystemError.permissionDenied(destination)
  }
  func chmod(_ path: String, mode: UInt16) async throws {
    throw FileSystemError.permissionDenied(path)
  }
  func chown(_ path: String, uid: UInt32?, gid: UInt32?) async throws {
    throw FileSystemError.permissionDenied(path)
  }
  func symlink(target: String, at path: String) async throws {
    throw FileSystemError.permissionDenied(path)
  }
  func hardlink(target: String, at path: String) async throws {
    throw FileSystemError.permissionDenied(path)
  }
  func listXattrs(_ path: String) async throws -> [String] { try await mounted.listXattrs(path) }
  func getXattr(_ path: String, name: String) async throws -> Data? {
    try await mounted.getXattr(path, name: name)
  }
  func setXattr(_ path: String, name: String, value: Data) async throws {
    throw FileSystemError.permissionDenied(path)
  }
  func removeXattr(_ path: String, name: String) async throws {
    throw FileSystemError.permissionDenied(path)
  }
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
      guard size <= maximum, size <= remaining else {
        throw PinewindError(.resourceLimit, "conf file exceeds resource limit")
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
