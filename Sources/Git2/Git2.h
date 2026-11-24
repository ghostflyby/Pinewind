// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef PINWIND_GIT2_H
#define PINWIND_GIT2_H

/*
 * Curated entry point into the installed libgit2 headers, located through
 * the pkg-config file selected in Package.swift (vcpkg roots first, plain
 * system pkg-config as fallback). A custom umbrella header instead of
 * SwiftPM's auto-generated umbrella-directory module map applies the two
 * Windows (MSVC / clang-cl) compatibility shims libgit2's public headers
 * assume but the toolchain doesn't provide — a cSetting -D doesn't reach
 * the Swift importer's module build, so it must live in a header. Shim
 * shape follows GitKit's gitkit_libgit2.h.
 */
#if defined(_WIN32)
#  include <stddef.h>
typedef ptrdiff_t ssize_t;  // used by git2/sys/stream.h callback types
#  define _MSC_STDINT_H_    // skip libgit2's bundled <stdint.h> polyfill
#endif

#include <git2.h>

// Backend ("sys") API the transport relies on to force the in-process
// local and smart HTTP transports. git2.h does not include the sys tree.
#include <git2/sys/transport.h>

#endif
