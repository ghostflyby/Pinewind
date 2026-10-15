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

#endif
