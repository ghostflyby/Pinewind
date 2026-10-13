// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Path globs are deterministic and independent of the host shell and locale.
public enum Glob {
  static func expression(_ pattern: String) throws -> String {

    guard !pattern.isEmpty, !pattern.hasPrefix("/"), !pattern.contains("\\"),
      !pattern.split(separator: "/").contains("..")
    else {
      throw PinewindError("unsafe glob '\(pattern)'")
    }
    let chars = Array(pattern)
    var result = "^"
    var i = 0
    while i < chars.count {
      switch chars[i] {
      case "*":
        if i + 1 < chars.count && chars[i + 1] == "*" {
          if i + 2 < chars.count && chars[i + 2] == "/" {
            result += "(?:.*/)?"
            i += 3
          } else {
            result += ".*"
            i += 2
          }
        } else {
          result += "[^/]*"
          i += 1
        }
      case "?":
        result += "[^/]"
        i += 1
      case "[":
        guard let end = chars[(i + 1)...].firstIndex(of: "]"), end > i + 1 else {
          throw PinewindError("unterminated glob character class '\(pattern)'")
        }
        var content = String(chars[(i + 1)..<end])
        if content.hasPrefix("!") { content = "^" + content.dropFirst() }
        guard !content.contains("/") else {
          throw PinewindError("glob character class cannot contain '/' ")
        }
        result += "[" + content + "]"
        i = end + 1
      default:
        result += NSRegularExpression.escapedPattern(for: String(chars[i]))
        i += 1
      }
    }
    result += "$"
    _ = try NSRegularExpression(pattern: result)
    return result
  }

  public static func matches(_ pattern: String, path: String) throws -> Bool {
    let regex = try NSRegularExpression(pattern: expression(pattern))
    return regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
  }
}
