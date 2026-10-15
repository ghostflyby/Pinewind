// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

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
/// request order. They must finish all file access before returning the result.
protocol FileAccessCoordinating: Sendable {
  func coordinate<Value: Sendable>(
    _ requests: [FileAccessRequest],
    accessor: @escaping @Sendable ([URL]) throws -> Value
  ) async throws -> Value
}

enum FileAccessCoordinator {
  static func platform(stateRoot: FilePath) -> any FileAccessCoordinating {
    #if canImport(Darwin)
      AppleFileAccessCoordinator()
    #else
      LockedFileAccessCoordinator(stateRoot: stateRoot)
    #endif
  }
}

#if canImport(Darwin)
  private final class CoordinationCancellation: @unchecked Sendable {
    let coordinator: NSFileCoordinator
    let signal = CancellationSignal()
    init(_ coordinator: NSFileCoordinator) { self.coordinator = coordinator }
    func cancel() {
      signal.cancel()
      coordinator.cancel()
    }
  }
  struct AppleFileAccessCoordinator: FileAccessCoordinating {
    func coordinate<Value: Sendable>(
      _ requests: [FileAccessRequest],
      accessor: @escaping @Sendable ([URL]) throws -> Value
    ) async throws -> Value {
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
      let cancellation = CoordinationCancellation(coordinator)
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          coordinator.coordinate(with: intents, queue: OperationQueue()) { error in
            if cancellation.signal.isCancelled {
              continuation.resume(throwing: CancellationError())
              return
            }
            if let error {
              continuation.resume(throwing: PinewindError.wrap(error))
              return
            }
            do {
              let value = try Cancellation.$signal.withValue(cancellation.signal) {
                try Cancellation.check()
                return try accessor(intents.map(\.url))
              }
              continuation.resume(returning: value)
            } catch { continuation.resume(throwing: PinewindError.wrap(error)) }
          }
        }
      } onCancel: {
        cancellation.cancel()
      }
    }
  }
#else
  struct LockedFileAccessCoordinator: FileAccessCoordinating {
    let stateRoot: FilePath

    func coordinate<Value: Sendable>(
      _ requests: [FileAccessRequest],
      accessor: @escaping @Sendable ([URL]) throws -> Value
    ) async throws -> Value {
      try await BlockingIO.run {
        try NativeLock.withLock(stateRoot.appending("configuration.lock")) {
          try accessor(requests.map(\.url))
        }
      }
    }
  }
#endif
