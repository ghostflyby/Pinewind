// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Package identifiers for the supported plum list aliases, in installation order.
/// These lists need neither bundled shell files nor interpreter evaluation.
enum BuiltinPackageLists {
  private static let preset = [
    "bopomofo", "cangjie", "essay", "luna-pinyin", "prelude", "quick", "stroke", "terra-pinyin",
  ]
  private static let extra = [
    "array", "cantonese", "combo-pinyin", "double-pinyin", "emoji", "ipa", "jyutping",
    "middle-chinese", "pinyin-simp", "scj", "soutzoe", "stenotype", "wubi", "wugniu",
  ]

  static func descriptors(for source: String) throws -> [String] {
    switch source {
    case ":preset": return preset
    case ":extra": return extra
    case ":all": return preset + extra
    default: throw InterpreterFailure.unknownBuiltIn(source)
    }
  }
}
