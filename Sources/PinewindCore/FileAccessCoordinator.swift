// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

#if os(Windows)
  import WinSDK
#elseif os(Linux)
  import CPinewindPlatform
#endif

struct FileAccessRequest: Sendable {
  enum Intent: Sendable { case read, write, delete }
  let url: URL
  let intent: Intent
}

/// Internal platform boundary. Accessors run once, synchronously, using the returned URLs in
/// request order. They must finish all file access before returning a disconnected result.
protocol FileAccessCoordinating: Sendable {
  func coordinate<Value>(
    _ requests: [FileAccessRequest],
    accessor: @escaping @Sendable ([URL]) throws -> sending Value
  ) async throws -> sending Value
}

enum FileAccessCoordinator {
  static func platform(localStateRoot: URL) -> any FileAccessCoordinating {
    #if canImport(Darwin)
      AppleFileAccessCoordinator()
    #else
      LockedFileAccessCoordinator(localStateRoot: localStateRoot)
    #endif
  }
}

#if canImport(Darwin)
  struct AppleFileAccessCoordinator: FileAccessCoordinating {
    func coordinate<Value>(
      _ requests: [FileAccessRequest],
      accessor: @escaping @Sendable ([URL]) throws -> sending Value
    ) async throws -> sending Value {
      try Task.checkCancellation()
      let coordinator = NSFileCoordinator()
      let intents = requests.map { request in
        switch request.intent {
        case .read: return NSFileAccessIntent.readingIntent(with: request.url, options: [])
        // Ordinary saves remain content updates even when implemented by atomic replacement.
        case .write: return NSFileAccessIntent.writingIntent(with: request.url, options: [])
        case .delete:
          return NSFileAccessIntent.writingIntent(with: request.url, options: .forDeleting)
        }
      }
      defer { withExtendedLifetime(coordinator) {} }
      return try await withCheckedThrowingContinuation { continuation in
        coordinator.coordinate(with: intents, queue: OperationQueue()) { error in
          if let error {
            continuation.resume(throwing: error)
            return
          }
          do { continuation.resume(returning: try accessor(intents.map(\.url))) } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }
  }
#else
  struct LockedFileAccessCoordinator: FileAccessCoordinating {
    let localStateRoot: URL

    func coordinate<Value>(
      _ requests: [FileAccessRequest],
      accessor: @escaping @Sendable ([URL]) throws -> sending Value
    ) async throws -> sending Value {
      try Task.checkCancellation()
      // Native lock waits and disk I/O run off the cooperative executor.
      return try await withCheckedThrowingContinuation { continuation in
        OperationQueue().addOperation {
          do {
            try FileManager.default.createDirectory(
              at: localStateRoot, withIntermediateDirectories: true)
            let lock = localStateRoot.appendingPathComponent("configuration.lock")
            try Self.withLock(lock) {
              continuation.resume(returning: try accessor(requests.map(\.url)))
            }
          } catch { continuation.resume(throwing: error) }
        }
      }
    }

    private static func withLock(_ file: URL, _ body: () throws -> Void) throws {
      #if os(Windows)
        let handle = try windowsNativePath(file).withCString(encodedAs: UTF16.self) {
          CreateFileW(
            $0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
            DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil,
            DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
          throw PinewindError("cannot open configuration lock (Windows error \(GetLastError()))")
        }
        defer { _ = CloseHandle(handle) }
        var overlapped = OVERLAPPED()
        guard LockFileEx(handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK), 0, 1, 0, &overlapped) else {
          throw PinewindError("cannot lock configuration (Windows error \(GetLastError()))")
        }
        defer { _ = UnlockFileEx(handle, 0, 1, 0, &overlapped) }
      #else
        var descriptor: Int32 = -1
        let status = file.withUnsafeFileSystemRepresentation { path in
          path.map { pinewind_lock_file($0, &descriptor) }
        }
        guard let status else {
          throw PinewindError("configuration lock has no filesystem representation")
        }
        guard status == 0 else {
          throw PinewindError(
            "cannot lock configuration: \(String(cString: strerror(status))) (errno \(status))",
            source: file.path)
        }
        defer { pinewind_unlock_file(descriptor) }
      #endif
      try body()
    }
  }
#endif
