// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import struct Glob.Pattern

/// Path globs are deterministic and independent of the host shell and locale.
public enum Glob {
  static func compile(_ pattern: String) throws(DeclarationFailure) -> Pattern {
    guard !pattern.isEmpty, !pattern.hasPrefix("/"), !pattern.contains("\\"),
      !pattern.contains("\0"), !pattern.split(separator: "/").contains("..")
    else {
      throw DeclarationFailure.invalidPattern(
        pattern: pattern, detail: "pattern must be a portable relative path")
    }
    do {
      return try Pattern(pattern, options: options)
    } catch {
      throw DeclarationFailure.invalidPattern(
        pattern: pattern, detail: String(describing: error.underlyingError))
    }
  }

  public static func matches(_ pattern: String, path: RelativePath) throws(DeclarationFailure)
    -> Bool
  {
    try compile(pattern).match(path.string)
  }

  // Keep Pinewind's path contract explicit rather than adopting library defaults
  // for dotfiles, extglob, brace expansion, or trailing directory separators.
  private static let options: Pattern.Options = {
    var options = Pattern.Options.default
    options.requiresExplicitLeadingPeriods = false
    options.supportsPatternLists = false
    options.supportsBraceExpansion = false
    options.supportsEscapedCharacters = false
    options.rangeNegationCharacter = .both
    options.bracketExpressionsCannotMatchPathSeparators = true
    options.matchesTrailingPathSeparator = false
    return options
  }()
}
