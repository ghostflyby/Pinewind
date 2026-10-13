// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public struct PinewindError: Error, Sendable, CustomStringConvertible {
  public let message: String
  public let source: String?
  public let line: Int?

  public init(_ message: String, source: String? = nil, line: Int? = nil) {
    self.message = message
    self.source = source
    self.line = line
  }

  public var description: String {
    let location = source.map { $0 + (line.map { ":\($0)" } ?? "") + ": " } ?? ""
    return location + message
  }
}
