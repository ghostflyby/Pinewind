// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

#if os(Windows)
  import WinSDK
#else
  import CPinewindPlatform
#endif

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
    try NativePath.requireAbsolute(file)
    try FileManager.default.createDirectory(
      at: file.removingLastComponent(), withIntermediateDirectories: true)
    #if os(Windows)
      let handle = file.withPlatformString {
        CreateFileW(
          $0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
          nil, DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw PinewindError(.io, "cannot open operation lock", source: file.string)
      }
      defer { _ = CloseHandle(handle) }
      var overlapped = OVERLAPPED()
      while !LockFileEx(
        handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY), 0, 1, 0, &overlapped)
      {
        guard GetLastError() == DWORD(ERROR_LOCK_VIOLATION) else {
          throw PinewindError(.io, "cannot acquire operation lock", source: file.string)
        }
        onContention?()
        try Cancellation.check()
        Thread.sleep(forTimeInterval: 0.02)
      }
      defer { _ = UnlockFileEx(handle, 0, 1, 0, &overlapped) }
    #else
      var descriptor: Int32 = -1
      while true {
        try Cancellation.check()
        let status = file.withPlatformString { pinewind_try_lock_file($0, &descriptor) }
        if status == 0 { break }
        guard status == EWOULDBLOCK || status == EAGAIN else {
          throw PinewindError(
            .io, "cannot acquire operation lock (errno \(status))", source: file.string)
        }
        onContention?()
        try Cancellation.check()
        Thread.sleep(forTimeInterval: 0.02)
      }
      defer { pinewind_unlock_file(descriptor) }
    #endif
    try Cancellation.check()
    return try body()
  }
}
