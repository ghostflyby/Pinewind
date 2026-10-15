// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage
import Testing

@testable import PinewindCore

@Suite("Native filesystem contracts")
struct NativeIOTests {
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

  @Test func waitingForNativeLockIsCancellableAcrossInstances() async throws {
    let root = native(
      FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: root) }
    let lock = root.appending("operation.lock")
    let state = LockTestState()
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
        try NativeLock.withLock(lock) { Issue.record("cancelled waiter acquired the lock") }
      }
    }
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
      child.arguments = [
        "-c",
        "import fcntl,sys; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); print('ready',flush=True); sys.stdin.read(1)",
        lock.string,
      ]
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
      #expect(ready == Data("ready\n".utf8))
      let waiter = Task {
        try await BlockingIO.run {
          try NativeLock.withLock(lock) { Issue.record("cross-process lock was bypassed") }
        }
      }
      try await Task.sleep(for: .milliseconds(30))
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
