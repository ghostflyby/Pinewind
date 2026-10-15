// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "CPinewindPlatform.h"
#include <errno.h>
#include <sys/file.h>

int pinewind_try_lock_exclusive(int descriptor) {
  int result;
  do { result = flock(descriptor, LOCK_EX | LOCK_NB); } while (result == -1 && errno == EINTR);
  return result == 0 ? 0 : errno;
}
