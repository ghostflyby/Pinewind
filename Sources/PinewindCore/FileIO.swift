// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

/// Native status captured at an I/O edge, without retaining a foreign error object.
public enum SystemErrorCode: Sendable, Hashable {
  case posix(Int32)
  case cocoa(Int)
  case windows(UInt32)
  case other(domain: String, code: Int)

  init(_ error: any Error) {
    if let error = error as? Errno {
      self = .posix(error.rawValue)
      return
    }
    let error = error as NSError
    switch error.domain {
    case NSPOSIXErrorDomain:
      if let code = Int32(exactly: error.code) {
        self = .posix(code)
      } else {
        self = .other(domain: error.domain, code: error.code)
      }
    case NSCocoaErrorDomain: self = .cocoa(error.code)
    case "NSWin32ErrorDomain": self = .windows(UInt32(truncatingIfNeeded: error.code))
    default: self = .other(domain: error.domain, code: error.code)
    }
  }
}

public enum FileOperation: String, Sendable, Hashable {
  case open, read, write, inspect, enumerate, createDirectory, copy, move, remove, coordinate
}

public struct FileOperationFailure: Sendable, Hashable, CustomStringConvertible {
  public let operation: FileOperation
  /// For copy/move, the source comes before the destination. Coordination lists all requests.
  public let paths: [FilePath]
  public let cause: SystemErrorCode
  public let detail: String

  public init(operation: FileOperation, paths: [FilePath], cause: SystemErrorCode, detail: String) {
    self.operation = operation
    self.paths = paths
    self.cause = cause
    self.detail = detail
  }

  init(operation: FileOperation, paths: [FilePath], error: any Error) {
    self.init(
      operation: operation, paths: paths, cause: SystemErrorCode(error),
      detail: String(describing: error))
  }

  public var description: String {
    "cannot \(operation.rawValue) \(paths.map(\.string).joined(separator: ", ")): \(detail)"
  }
}

enum FileIO {
  /// Translate native file errors where the operation and its objects are still known.
  static func perform<T>(
    _ operation: FileOperation, paths: [FilePath], _ body: () throws -> T
  ) throws -> T {
    do { return try body() } catch {
      if error is CancellationError || error is PinewindError || Failure.recognizing(error) != nil {
        throw error
      }
      let domain = (error as NSError).domain
      guard
        error is Errno
          || [NSPOSIXErrorDomain, NSCocoaErrorDomain, "NSWin32ErrorDomain"].contains(domain)
      else { throw error }
      throw FileSystemFailure.operationFailed(
        FileOperationFailure(operation: operation, paths: paths, error: error))
    }
  }
}
