// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage
import Testing

@testable import PinewindCore

@Suite("Native filesystem contracts", .timeLimit(.minutes(1)))
struct NativeIOTests {
  #if os(Windows)
    @Test func windowsRootsAndUNCFileURLsUseNativePathSemantics() throws {
      let base = FilePath("C:\\workspace")
      for path in [FilePath("C:package"), FilePath("\\package")] {
        #expect(throws: PinewindError.self) { _ = try NativePath.absolute(path, relativeTo: base) }
      }
      let endpoint = URL(string: "file://server/share/package")!
      let path = try NativePath.from(endpoint)
      try NativePath.requireAbsolute(path)
      #expect(try SourceIdentity.normalize(endpoint).host == "server")
      #expect(try NativePath.from(path.foundationURL) == path)
    }
  #endif
  @Test func unicodeURLBridgePreservesLiteralPercentAndFragmentCharacters() throws {
    let root = native(
      FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let file = root.appending("词典 😀 %20 #?.yaml")
    let endpoint = try file.foundationURL
    #expect(try NativePath.from(endpoint) == file)
    let location = try FileLocation.fileURL(endpoint).resolved(relativeTo: nil)
    guard case .fileURL(let preserved) = location else {
      Issue.record("file URL was discarded")
      return
    }
    #expect(preserved == endpoint)
    #expect(throws: PinewindError.self) {
      _ = try NativePath.from(URL(string: "https://example.com/path")!)
    }
    #expect(throws: PinewindError.self) {
      _ = try NativePath.from(URL(string: "file:///tmp/a%00b")!)
    }
  }

  @Test func lexicalContainmentDoesNotPermitSymlinkEscape() throws {
    let root = native(
      FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appending("source"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appending("outside"), withIntermediateDirectories: true)
    try Data("protected".utf8).write(to: root.appending("outside/value"))
    #expect(
      try SafePath.overlaps(
        root.appending("source"), root.appending("missing/../source/output")))
    try FileManager.default.createSymbolicLink(
      at: root.appending("source/link").foundationURL,
      withDestinationURL: root.appending("outside").foundationURL)
    #expect(throws: PinewindError.self) {
      _ = try SafePath.file("link/value", in: root.appending("source"))
    }
    #expect(throws: PinewindError.self) { _ = try SafePath.files(in: root.appending("source")) }
  }

  @Test func descriptorLocksContendAndReleaseOnCloseOrThrow() throws {
    let root = native(
      FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending("operation.lock")
    let second = try FileDescriptor.openLockFile(file)
    try second.closeAfter {
      let first = try FileDescriptor.openLockFile(file)
      try first.closeAfter { () throws -> Void in
        #expect(try first.tryLockExclusively())
        #expect(try !second.tryLockExclusively())
      }
      #expect(try second.tryLockExclusively())
    }
    enum Failure: Error { case aborted }
    #expect(throws: Failure.self) {
      try NativeLock.withLock(file) { throw Failure.aborted }
    }
    try NativeLock.withLock(file) {}
    #expect(FileManager.default.fileExists(atPath: file.string))
  }

  @Test func operationLocksRejectDirectoriesAndSymbolicLinks() throws {
    let root = native(
      FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appending("directory"), withIntermediateDirectories: true)
    let target = root.appending("target")
    try Data("unchanged".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: root.appending("link").foundationURL, withDestinationURL: target.foundationURL)
    for name in ["directory", "link"] {
      #expect(throws: PinewindError.self) {
        try NativeLock.withLock(root.appending(name)) { Issue.record("locked a nonregular file") }
      }
    }
    #expect(try Data(contentsOf: target) == Data("unchanged".utf8))
  }

  @Test func chunkedFileChecksPreserveBinaryBytesAndDetectTailChanges() throws {
    let root = native(
      FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let first = root.appending("first")
    let second = root.appending("second")
    var bytes = Data(repeating: 65, count: 65_537)
    bytes.replaceSubrange(0..<5, with: [0, 13, 10, 26, 255])
    try bytes.write(to: first)
    try bytes.write(to: second)
    #expect(try SnapshotFiles.byteCount(first) == UInt64(bytes.count))
    #expect(
      try SnapshotFiles.sha256(first)
        == "0c33c7aa1c0f8af4691b10a02daeabb0cd1d7377044540444ba3849a9b40fb5a")
    #expect(try SnapshotFiles.sameContents(first, second))
    bytes[bytes.count - 1] = 66
    try bytes.write(to: second)
    #expect(try !SnapshotFiles.sameContents(first, second))
    try Data().write(to: first)
    #expect(try !SnapshotFiles.sameContents(first, second))
    try Data().write(to: second)
    #expect(try SnapshotFiles.sameContents(first, second))
  }

  @Test func waitingForNativeLockIsCancellableAcrossInstances() async throws {
    let root = native(
      FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: root) }
    let lock = root.appending("operation.lock")
    let state = LockTestState()
    defer { state.release() }
    let holder = Task {
      try await BlockingIO.run {
        try NativeLock.withLock(lock) {
          state.markHeld()
          while !state.shouldRelease { Thread.sleep(forTimeInterval: 0.005) }
        }
      }
    }
    while !state.isHeld { try await Task.sleep(for: .milliseconds(5)) }
    let waiter = Task {
      try await BlockingIO.run {
        try NativeLock.withLock(lock, onContention: { state.markContended() }) {
          Issue.record("cancelled waiter acquired the lock")
        }
      }
    }
    defer { waiter.cancel() }
    while !state.isContended { try await Task.sleep(for: .milliseconds(5)) }
    waiter.cancel()
    await #expect(throws: CancellationError.self) { try await waiter.value }
    state.release()
    try await holder.value
    #expect(FileManager.default.fileExists(atPath: lock.string))
  }

  #if os(macOS) || os(Linux)
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func nativeLockCoordinatesWithAnotherProcess() async throws {
      let root = native(
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
      defer { try? FileManager.default.removeItem(at: root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let lock = root.appending("process.lock")
      let child = Process()
      child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
      child.arguments = [try fixtureURL("ProcessLock/hold_lock.py").path, lock.string]
      let output = Pipe()
      let input = Pipe()
      child.standardOutput = output
      child.standardInput = input
      try child.run()
      defer {
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
      }
      let ready = try output.fileHandleForReading.read(upToCount: 6)
      try #require(ready == Data("ready\n".utf8))
      let state = LockTestState()
      let waiter = Task {
        try await BlockingIO.run {
          try NativeLock.withLock(lock, onContention: { state.markContended() }) {
            Issue.record("cross-process lock was bypassed")
          }
        }
      }
      defer { waiter.cancel() }
      while !state.isContended { try await Task.sleep(for: .milliseconds(5)) }
      waiter.cancel()
      await #expect(throws: CancellationError.self) { try await waiter.value }
      try input.fileHandleForWriting.write(contentsOf: Data("x".utf8))
      child.waitUntilExit()
      try await BlockingIO.run { try NativeLock.withLock(lock) {} }
    }
  #endif
}

private final class LockTestState: @unchecked Sendable {
  private let mutex = NSLock()
  private var held = false
  private var released = false
  private var contended = false
  func markContended() {
    mutex.lock()
    contended = true
    mutex.unlock()
  }
  var isContended: Bool {
    mutex.lock()
    defer { mutex.unlock() }
    return contended
  }
  func markHeld() {
    mutex.lock()
    held = true
    mutex.unlock()
  }
  func release() {
    mutex.lock()
    released = true
    mutex.unlock()
  }
  var isHeld: Bool {
    mutex.lock()
    defer { mutex.unlock() }
    return held
  }
  var shouldRelease: Bool {
    mutex.lock()
    defer { mutex.unlock() }
    return released
  }
}
