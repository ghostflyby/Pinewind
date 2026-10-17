// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

final class CancellationSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}
enum Cancellation {
  @TaskLocal static var signal: CancellationSignal?
  static var isCancelled: Bool { Task.isCancelled || signal?.isCancelled == true }
  static func check() throws { if isCancelled { throw CancellationError() } }
}
enum BlockingIO {
  private static let queue = OperationQueue()
  static func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    let signal = CancellationSignal()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        queue.addOperation {
          do {
            let value = try Cancellation.$signal.withValue(signal) {
              try Cancellation.check()
              return try operation()
            }
            continuation.resume(returning: value)
          } catch { continuation.resume(throwing: PinewindError.wrap(error)) }
        }
      }
    } onCancel: {
      signal.cancel()
    }
  }
}

enum NativeLock {
  static func withLock<T>(
    _ file: FilePath, onContention: (@Sendable () -> Void)? = nil,
    _ body: () throws -> T
  ) throws -> T {
    try FileManager.default.createDirectory(
      at: file.removingLastComponent(), withIntermediateDirectories: true)
    let descriptor: FileDescriptor
    do { descriptor = try FileDescriptor.openLockFile(file) } catch {
      throw FileSystemFailure.unreadable(path: file, detail: String(describing: error))
    }
    // A close error must not turn a completed publication into a reported failure.
    defer { try? descriptor.close() }
    do {
      while true {
        try Cancellation.check()
        if try descriptor.tryLockExclusively() { break }
        onContention?()
        try Cancellation.check()
        Thread.sleep(forTimeInterval: 0.02)
      }
    } catch {
      throw PinewindError.wrap(error)
    }
    try Cancellation.check()
    return try body()
  }
}
