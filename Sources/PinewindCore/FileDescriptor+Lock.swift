// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SystemPackage

#if os(Windows)
  import WinSDK
  import ucrt
#else
  import CPinewindPlatform
#endif

extension FileDescriptor {
  /// Opens a stable, regular lock file. Closing the descriptor releases its lock;
  /// the file itself is retained so every contender locks the same file identity.
  static func openLockFile(_ path: FilePath) throws -> Self {
    try NativePath.requireAbsolute(path)
    #if os(Windows)
      // System's open() always enables FILE_SHARE_DELETE. Lock files must not be
      // replaced while any contender holds a descriptor, including while waiting.
      let handle = path.withPlatformString {
        CreateFileW(
          $0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
          nil, DWORD(OPEN_ALWAYS), DWORD(FILE_FLAG_OPEN_REPARSE_POINT), nil)
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw PinewindError(
          .io, "cannot open operation lock (Windows error \(GetLastError()))", source: path.string)
      }
      var adopted = false
      defer { if !adopted { _ = CloseHandle(handle) } }
      var info = BY_HANDLE_FILE_INFORMATION()
      guard GetFileInformationByHandle(handle, &info) else {
        throw PinewindError(
          .io, "cannot inspect operation lock (Windows error \(GetLastError()))",
          source: path.string)
      }
      guard
        info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) == 0
      else {
        throw PinewindError(
          .invalidPath, "operation lock must be a regular file", source: path.string)
      }
      let descriptor = ucrt._open_osfhandle(
        Int(bitPattern: handle), _O_RDWR | _O_NOINHERIT)
      guard descriptor != -1 else {
        throw PinewindError(.io, "cannot adopt operation lock handle", source: path.string)
      }
      adopted = true
      return Self(rawValue: descriptor)
    #else
      let descriptor = try open(
        path, .readWrite, options: [.create, .closeOnExec, .noFollow, .nonBlocking],
        permissions: .ownerReadWrite)
      do {
        guard try descriptor.stat().type == .regular else {
          throw PinewindError(
            .invalidPath, "operation lock must be a regular file", source: path.string)
        }
        return descriptor
      } catch {
        try? descriptor.close()
        throw error
      }
    #endif
  }

  /// Nonblocking, process-wide exclusion for cooperating Pinewind callers.
  /// Returns false only for contention; unsupported locking and other failures throw.
  /// POSIX locks cover the file; Windows locks the reserved first byte. Both are
  /// released by close(), including when the owning process exits. Call only on
  /// an unlocked descriptor; recursive acquisition and lock conversion are unsupported.
  func tryLockExclusively() throws -> Bool {
    #if os(Windows)
      let native = ucrt._get_osfhandle(rawValue)
      guard native != -1, let handle = UnsafeMutableRawPointer(bitPattern: native) else {
        throw Errno.badFileDescriptor
      }
      var overlapped = OVERLAPPED()
      if LockFileEx(
        handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY), 0, 1, 0, &overlapped)
      {
        return true
      }
      let error = GetLastError()
      if error == DWORD(ERROR_LOCK_VIOLATION) { return false }
      throw PinewindError(.io, "cannot acquire operation lock (Windows error \(error))")
    #else
      // System's sharedLock/exclusiveLock options apply only during open(), and
      // are unavailable on Linux. This fills the existing-descriptor operation.
      let status = pinewind_try_lock_exclusive(rawValue)
      if status == 0 { return true }
      let error = Errno(rawValue: status)
      if error == .wouldBlock || error == .resourceTemporarilyUnavailable { return false }
      throw error
    #endif
  }
}
