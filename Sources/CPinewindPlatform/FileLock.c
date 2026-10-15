// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "CPinewindPlatform.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

int pinewind_lock_file(const char *path, int *descriptor) {
  int fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd == -1) return errno;
  struct stat info;
  if (fstat(fd, &info) == -1) {
    int status = errno;
    close(fd);
    return status;
  }
  if (!S_ISREG(info.st_mode)) {
    close(fd);
    return EINVAL;
  }
  int result;
  do { result = flock(fd, LOCK_EX); } while (result == -1 && errno == EINTR);
  if (result == -1) {
    int status = errno;
    close(fd);
    return status;
  }
  *descriptor = fd;
  return 0;
}

void pinewind_unlock_file(int descriptor) {
  // Closing also releases the lock after a process exits; never unlink the lock file.
  close(descriptor);
}
