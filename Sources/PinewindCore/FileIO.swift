// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

public enum FileOperation: String, Codable, Sendable, Hashable {
  case open, read, write, inspect, enumerate, createDirectory, copy, move, remove, coordinate
}

/// Operation metadata adds information absent from the original error, without mirroring it.
public protocol FileOperationErrorProtocol: PinewindErrorProtocol {
  var operation: FileOperation { get }
  var paths: [FilePath] { get }
  var underlyingError: any Error { get }
}
public struct FileOperationFailure<E: Error>: FileOperationErrorProtocol {
  public let operation: FileOperation
  public let paths: [FilePath]
  public let cause: E
  public var underlyingError: any Error { cause }
  public init(operation: FileOperation, paths: [FilePath], error: E) {
    self.operation = operation
    self.paths = paths
    self.cause = error
  }
  public var description: String {
    "cannot \(operation.rawValue) \(paths.map(\.string).joined(separator: ", ")): \(cause)"
  }
}
extension FileOperationFailure: Encodable where E: Encodable {}
extension FileOperationFailure: Decodable where E: Decodable {}

/// URL and the original transport error remain separately inspectable.
public struct ResourceTransferFailure<E: Error>: PinewindErrorProtocol {
  public let url: URL
  public let cause: E
  public init(url: URL, cause: E) {
    self.url = url
    self.cause = cause
  }
  public var description: String { "download failed: \(url.absoluteString): \(cause)" }
}
extension ResourceTransferFailure: Encodable where E: Encodable {}
extension ResourceTransferFailure: Decodable where E: Decodable {}

enum FileIO {
  static func perform<T>(
    _ operation: FileOperation, paths: [FilePath], _ body: () throws -> T
  ) throws -> T {
    do { return try body() } catch {
      if error is CancellationError { throw error }
      let domain = (error as NSError).domain
      guard
        error is Errno
          || [NSPOSIXErrorDomain, NSCocoaErrorDomain, "NSWin32ErrorDomain"].contains(domain)
      else { throw error }
      func wrap<E: Error>(_ cause: E) -> any Error {
        FileOperationFailure(operation: operation, paths: paths, error: cause)
      }
      throw wrap(error)
    }
  }
}
