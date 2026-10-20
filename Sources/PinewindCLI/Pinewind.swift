// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import PinewindCommands

@main
enum EntryPoint {
  static func main() async {
    let status = await PinewindCommandRunner().run(
      arguments: Array(CommandLine.arguments.dropFirst()))
    exit(status)
  }
}
