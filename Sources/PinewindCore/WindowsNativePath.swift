// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

#if os(Windows)
  func windowsNativePath(_ url: URL) throws -> String {
    guard url.isFileURL, !url.absoluteString.contains("%00"), !url.path.contains("\0"),
      let representation = url.withUnsafeFileSystemRepresentation({ pointer in
        pointer.map { String(cString: $0) }
      })
    else { throw PinewindError("file URL has no filesystem representation") }
    var path = representation.replacingOccurrences(of: "/", with: "\\")
    if path.hasPrefix("\\"), path.dropFirst().dropFirst().hasPrefix(":") { path.removeFirst() }
    if path.hasPrefix("\\\\?\\UNC\\") {
      path = "\\\\" + path.dropFirst(8)
    } else if path.hasPrefix("\\\\?\\") {
      path.removeFirst(4)
    }
    return path
  }

#endif
