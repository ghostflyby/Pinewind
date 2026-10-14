// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "CPinewindPlatform.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>

int pinewind_exchange_directories(const char *candidate, const char *output) {
#if defined(__APPLE__)
  int result = renameatx_np(AT_FDCWD, candidate, AT_FDCWD, output, RENAME_SWAP);
#elif defined(__linux__)
  int result = renameat2(AT_FDCWD, candidate, AT_FDCWD, output, RENAME_EXCHANGE);
#else
  return ENOTSUP;
#endif
#if defined(__APPLE__) || defined(__linux__)
  return result == 0 ? 0 : errno;
#endif
}
