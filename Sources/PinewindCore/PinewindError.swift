// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public struct PinewindError: Error, Sendable, CustomStringConvertible, LocalizedError {
  public enum Code: String, Sendable {
    case invalidConfiguration, invalidPath, needsResolution, contentMissing, developmentRequired
    case configurationConflict, staleInput, checksumMismatch, authenticationFailed
    case incompatibleFormat, unsupportedFilesystem, unsupportedOperation, resourceLimit, io
  }
  public let code: Code
  public let message: String
  public let source: String?
  public let line: Int?
  public let field: String?
  public let entry: Int?
  public init(
    _ code: Code, _ message: String, source: String? = nil, line: Int? = nil,
    field: String? = nil, entry: Int? = nil
  ) {
    self.code = code
    self.message = message
    self.source = source
    self.line = line
    self.field = field
    self.entry = entry
  }
  init(_ message: String, source: String? = nil, line: Int? = nil) {
    self.init(.invalidConfiguration, message, source: source, line: line)
  }
  public var description: String {
    (source.map { $0 + (line.map { ":\($0)" } ?? "") + ": " } ?? "") + message
  }
  public var errorDescription: String? { description }
}

public struct Diagnostic: Hashable, Sendable {
  public let code: PinewindError.Code
  public let message: String
  public let source: String?
  public let line: Int?
  public let field: String?
  public let entry: Int?
  init(_ error: PinewindError) {
    code = error.code
    message = error.message
    source = error.source
    line = error.line
    field = error.field
    entry = error.entry
  }
}

extension PinewindError {
  static func wrap(_ error: Error, source: String? = nil) -> Error {
    if error is CancellationError || error is PinewindError { return error }
    return PinewindError(.io, String(describing: error), source: source)
  }
}
