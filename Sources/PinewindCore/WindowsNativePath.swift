// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

#if os(Windows)
  func windowsNativePath(_ url: FilePath) throws -> String {
    guard var path = String(validating: url) else {
      throw PinewindError(.invalidPath, "unrepresentable Windows path")
    }
    if path.hasPrefix("\\\\?\\UNC\\") {
      path = "\\\\" + path.dropFirst(8)
    } else if path.hasPrefix("\\\\?\\") {
      path.removeFirst(4)
    }
    return path
  }

#endif
