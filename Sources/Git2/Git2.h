// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef PINWIND_GIT2_H
#define PINWIND_GIT2_H

/*
 * Curated entry point into the installed libgit2 headers, located through
 * the pkg-config file selected in Package.swift. A custom umbrella header
 * instead of SwiftPM's auto-generated umbrella-directory module map lets
 * Windows (MSVC / clang-cl) compatibility shims be applied in front of
 * git2.h — a cSetting -D doesn't reach the Swift importer's module build,
 * so it must live in a header. The shims are defensive only: they date
 * back to GitKit's vendored libgit2 tree, and against the 1.9.7 install
 * tree no reachable header needs them; the Windows target itself is not
 * exercised locally, so they stay.
 */
#if defined(_WIN32)
#  include <stddef.h>
typedef ptrdiff_t ssize_t;  // polyfill if a header expects SSIZE_MAX types
#  define _MSC_STDINT_H_    // skip any bundled <stdint.h> polyfill
#endif

#include <git2.h>

// Backend ("sys") API the transport relies on to force the in-process
// local and smart HTTP transports. git2.h does not include the sys tree.
#include <git2/sys/transport.h>

#endif
