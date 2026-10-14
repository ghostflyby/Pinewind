// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(Windows)
  import Foundation
  import WinSDK

  /// A stable junction points to a complete private generation. Updating its
  /// reparse data switches targets without renaming or removing the active root.
  enum WindowsDirectoryPublisher {
    static func storage(for output: URL) -> URL {
      output.deletingLastPathComponent().appendingPathComponent(
        "." + output.lastPathComponent + ".pinewind-generations", isDirectory: true)
    }

    static func validate(_ output: URL) throws {
      if let target = try currentTarget(output) {
        let target = try resolvedURL(target)
        guard
          try canonicalPath(target.deletingLastPathComponent())
            == canonicalPath(storage(for: output)),
          isGeneration(target.lastPathComponent)
        else { throw PinewindError("composition output is not a Pinewind generation junction") }
      } else if FileManager.default.fileExists(atPath: output.path) {
        guard try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty else {
          throw PinewindError("Windows composition output must be empty or managed by Pinewind")
        }
      }
    }

    static func publish(_ candidate: URL, at output: URL) throws {
      let fm = FileManager.default
      if try currentTarget(output) != nil || fm.fileExists(atPath: output.path) {
        try redirect(output, to: candidate)
      } else {
        let link = output.deletingLastPathComponent().appendingPathComponent(
          ".pinewind-link-" + UUID().uuidString)
        try fm.createDirectory(at: link, withIntermediateDirectories: false)
        defer {
          if let path = try? nativePath(link) {
            _ = path.withCString(encodedAs: UTF16.self) { RemoveDirectoryW($0) }
          }
        }
        try redirect(link, to: candidate)
        try fm.moveItem(at: link, to: output)
      }
      // Publication and candidate construction share the output lock. A held
      // reader may prevent deletion; retry owned leftovers on a later publication.
      guard let active = try? currentTarget(output),
        let activePath = try? canonicalPath(active),
        let candidatePath = try? canonicalPath(candidate)
      else { return }
      for old
        in (try? fm.contentsOfDirectory(
          at: storage(for: output), includingPropertiesForKeys: nil)) ?? []
      where isGeneration(old.lastPathComponent) {
        guard let path = try? canonicalPath(old), path != activePath, path != candidatePath else {
          continue
        }
        try? fm.removeItem(at: old)
      }
    }

    /// Hold from reading the previous generation through candidate construction,
    /// publication and cleanup, including across independent instances/processes.
    static func withPublicationLock<T>(in storage: URL, _ body: () throws -> T) throws -> T {
      let file = storage.appendingPathComponent("publication.lock")
      let handle = try nativePath(file).withCString(encodedAs: UTF16.self) {
        CreateFileW(
          $0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
          nil,
          DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw PinewindError("cannot open composition lock (Windows error \(GetLastError()))")
      }
      defer { _ = CloseHandle(handle) }
      var overlapped = OVERLAPPED()
      guard LockFileEx(handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK), 0, 1, 0, &overlapped) else {
        throw PinewindError("cannot lock composition output (Windows error \(GetLastError()))")
      }
      defer { _ = UnlockFileEx(handle, 0, 1, 0, &overlapped) }
      return try body()
    }

    private static func isGeneration(_ name: String) -> Bool {
      name.hasPrefix("generation-") && UUID(uuidString: String(name.dropFirst(11))) != nil
    }

    private static func nativePath(_ url: URL) throws -> String {
      guard url.isFileURL, !url.path.contains("\0"),
        let representation = url.withUnsafeFileSystemRepresentation({ pointer in
          pointer.map { String(cString: $0) }
        })
      else { throw PinewindError("composition path has no filesystem representation") }
      var path = representation.replacingOccurrences(of: "/", with: "\\")
      if path.hasPrefix("\\"), path.dropFirst().dropFirst().hasPrefix(":") { path.removeFirst() }
      if path.hasPrefix("\\\\?\\UNC\\") {
        path = "\\\\" + path.dropFirst(8)
      } else if path.hasPrefix("\\\\?\\") {
        path.removeFirst(4)
      }
      return path
    }

    private static func withHandle<T>(
      _ url: URL, access: DWORD, following: Bool = false, _ body: (HANDLE) throws -> T
    ) throws -> T {
      let handle = try nativePath(url).withCString(encodedAs: UTF16.self) {
        CreateFileW(
          $0, access, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_BACKUP_SEMANTICS) | (following ? 0 : DWORD(FILE_FLAG_OPEN_REPARSE_POINT)),
          nil)
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw PinewindError("cannot open composition junction (Windows error \(GetLastError()))")
      }
      defer { _ = CloseHandle(handle) }
      return try body(handle)
    }

    /// Resolve the nearest existing ancestor through the filesystem, including
    /// short names, junctions and case aliases, then append absent components.
    static func canonicalPath(_ url: URL) throws -> String {
      try resolvedURL(url).standardizedFileURL.path.lowercased()
    }

    static func resolvedURL(_ url: URL) throws -> URL {
      var ancestor = url.standardizedFileURL
      var missing: [String] = []
      while !FileManager.default.fileExists(atPath: ancestor.path) {
        let parent = ancestor.deletingLastPathComponent()
        guard parent.path != ancestor.path else {
          throw PinewindError("cannot resolve composition path")
        }
        missing.append(ancestor.lastPathComponent)
        ancestor = parent
      }
      var resolved = try withHandle(ancestor, access: 0, following: true) { handle in
        var buffer = [WCHAR](repeating: 0, count: 32_768)
        let count = GetFinalPathNameByHandleW(handle, &buffer, DWORD(buffer.count), 0)
        guard count > 0, Int(count) < buffer.count else {
          throw PinewindError("cannot resolve composition path (Windows error \(GetLastError()))")
        }
        var path = String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
        if path.hasPrefix("\\\\?\\UNC\\") {
          path = "\\\\" + path.dropFirst(8)
        } else if path.hasPrefix("\\\\?\\") {
          path.removeFirst(4)
        }
        return URL(fileURLWithPath: path)
      }
      for component in missing.reversed() { resolved.appendPathComponent(component) }
      return resolved
    }

    static func currentTarget(_ output: URL) throws -> URL? {
      let attributes = try nativePath(output).withCString(encodedAs: UTF16.self) {
        GetFileAttributesW($0)
      }
      if attributes == DWORD(INVALID_FILE_ATTRIBUTES) {
        let error = GetLastError()
        if error == DWORD(ERROR_FILE_NOT_FOUND) || error == DWORD(ERROR_PATH_NOT_FOUND) {
          return nil
        }
        throw PinewindError("cannot inspect composition output (Windows error \(error))")
      }
      if attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 { return nil }
      return try withHandle(output, access: 0) { handle in
        var buffer = Data(count: 16_384)
        var count: DWORD = 0
        let ok = buffer.withUnsafeMutableBytes {
          DeviceIoControl(
            handle, DWORD(FSCTL_GET_REPARSE_POINT), nil, 0, $0.baseAddress,
            DWORD($0.count), &count, nil)
        }
        guard ok else {
          throw PinewindError("cannot read composition junction (Windows error \(GetLastError()))")
        }
        guard count >= 16,
          buffer.integer(at: 0, as: UInt32.self) == UInt32(IO_REPARSE_TAG_MOUNT_POINT)
        else { throw PinewindError("composition output is not a directory junction") }
        let offset = 16 + Int(buffer.integer(at: 8, as: UInt16.self))
        let length = Int(buffer.integer(at: 10, as: UInt16.self))
        guard offset + length <= Int(count), length.isMultiple(of: 2),
          var path = String(
            data: buffer.subdata(in: offset..<(offset + length)), encoding: .utf16LittleEndian),
          path.hasPrefix("\\??\\")
        else { throw PinewindError("invalid composition junction target") }
        path.removeFirst(4)
        if path.hasPrefix("UNC\\") { path = "\\\\" + path.dropFirst(4) }
        return URL(fileURLWithPath: path, isDirectory: true)
      }
    }

    static func redirect(_ output: URL, to candidate: URL) throws {
      let printName = try nativePath(candidate)
      let substituteName =
        printName.hasPrefix("\\\\")
        ? "\\??\\UNC\\" + printName.dropFirst(2) : "\\??\\" + printName
      let substitute = Array(substituteName.utf16)
      let printable = Array(printName.utf16)
      let dataLength = 8 + (substitute.count + printable.count + 2) * 2
      guard dataLength + 8 <= 16_384 else {
        throw PinewindError("composition junction path is too long")
      }
      var data = Data()
      data.appendInteger(UInt32(IO_REPARSE_TAG_MOUNT_POINT))
      data.appendInteger(UInt16(dataLength))
      data.appendInteger(UInt16(0))
      data.appendInteger(UInt16(0))
      data.appendInteger(UInt16(substitute.count * 2))
      data.appendInteger(UInt16((substitute.count + 1) * 2))
      data.appendInteger(UInt16(printable.count * 2))
      for word in substitute + [0] + printable + [0] { data.appendInteger(word) }
      try withHandle(output, access: DWORD(GENERIC_WRITE)) { handle in
        var count: DWORD = 0
        let ok = data.withUnsafeMutableBytes {
          DeviceIoControl(
            handle, DWORD(FSCTL_SET_REPARSE_POINT), $0.baseAddress, DWORD($0.count), nil, 0, &count,
            nil)
        }
        guard ok else {
          throw PinewindError(
            "cannot publish composition junction (Windows error \(GetLastError()))")
        }
      }
    }
  }

  extension Data {
    fileprivate mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
      var word = value.littleEndian
      Swift.withUnsafeBytes(of: &word) { append(contentsOf: $0) }
    }

    fileprivate func integer<T: FixedWidthInteger>(at offset: Int, as: T.Type) -> T {
      withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
  }
#endif
