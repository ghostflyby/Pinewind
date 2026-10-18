// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CPINEWIND_PLATFORM_H
#define CPINEWIND_PLATFORM_H

// Exposes strerror to Swift for native errno diagnostics in Composer.
#include <string.h>

// Returns zero on success or the native errno on failure.
int pinewind_exchange_directories(const char *candidate, const char *output);

// Nonblocking flock for an already-open descriptor. Returns zero or native errno.
int pinewind_try_lock_exclusive(int descriptor);

// Atomic file replacement and non-recursive removal. Returns zero or errno.
int pinewind_replace_file(const char *source, const char *destination);
int pinewind_remove_file(const char *path);
// Flush an open descriptor to storage. Returns zero or errno.
int pinewind_sync_file(int descriptor);

#endif
