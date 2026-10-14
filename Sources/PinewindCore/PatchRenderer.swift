// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Yams

enum PatchRenderer {
  static func apply(_ bytes: Data?, rx: String, body: String) throws -> Data {
    let text: String
    if let bytes {
      guard let decoded = String(data: bytes, encoding: .utf8) else {
        throw PinewindError("patch target must be UTF-8 YAML")
      }
      text = decoded
    } else {
      text = ""
    }
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    var lines = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    // Match Rx markers literally, including metacharacters and option ordering.
    let start = "# Rx: " + rx + " {"
    var kept: [String] = []
    var removing = false
    for line in lines {
      if line == start {
        guard !removing else { throw PinewindError("nested Rx marker") }
        removing = true
      } else if removing && line == "# }" {
        removing = false
      } else if !removing {
        kept.append(line)
      }
    }
    guard !removing else { throw PinewindError("unterminated existing Rx block") }
    lines = kept
    let textWithoutBlock = lines.joined(separator: "\n")
    let reader = YAMLReader(source: "patch target")
    if !textWithoutBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let mapping = try reader.mapping(reader.document(textWithoutBlock))
      if let patch = mapping["__patch"], patch.tag != Tag(.null), patch.sequence == nil {
        throw PinewindError("existing __patch must be a sequence")
      }
    }
    let headers = lines.indices.filter {
      lines[$0].trimmingCharacters(in: .whitespaces) == "__patch:"
        && !lines[$0].hasPrefix(" ") && !lines[$0].hasPrefix("\t")
    }
    let header: Int
    if let found = headers.first {
      header = found
    } else {
      if lines.contains(where: { $0.hasPrefix("__patch:") }) {
        throw PinewindError("existing __patch must use block-style YAML")
      }
      lines.append("__patch:")
      header = lines.count - 1
    }
    var end = header + 1
    while end < lines.count {
      let line = lines[end]
      if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.hasPrefix("#") {
        break
      }
      end += 1
    }
    let content = [start] + body.components(separatedBy: "\n").map { "  " + $0 } + ["# }"]
    lines.insert(contentsOf: content, at: end)
    let output = lines.joined(separator: newline) + newline
    let mapping = try reader.mapping(reader.document(output))
    guard mapping["__patch"]?.sequence != nil else {
      throw PinewindError("patch produced invalid __patch data")
    }
    return Data(output.utf8)
  }
}
