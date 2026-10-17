# SPDX-FileCopyrightText: 2026 ghostflyby
# SPDX-License-Identifier: MPL-2.0

import fcntl
import sys

with open(sys.argv[1], "a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    print("ready", flush=True)
    sys.stdin.read(1)
