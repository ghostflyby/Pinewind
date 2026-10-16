// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(Windows)
  import Foundation
  import SystemPackage
  import WinSDK

  /// A stable junction points to a complete private generation. Updating its
  /// reparse data switches targets without renaming or removing the active root.
  enum WindowsDirectoryPublisher {
    /// Resolve parent aliases and expand the entry's short name without following
    /// the final managed junction into its replaceable generation.
    static func publicationPath(_ output: FilePath) throws -> FilePath {
      guard let component = output.lastComponent else {
        throw FileSystemFailure.isFilesystemRoot(output)
      }
      let parent = try resolvedPath(output.removingLastComponent())
      let entry = parent.appending(component)
      guard FileManager.default.fileExists(atPath: entry.string) else { return entry }
      var buffer = [WCHAR](repeating: 0, count: 32_768)
      let count = entry.withPlatformString {
        GetLongPathNameW($0, &buffer, DWORD(buffer.count))
      }
      guard count > 0, Int(count) < buffer.count else {
        throw FileSystemFailure.unresolvable(entry)
      }
      return FilePath(platformString: buffer)
    }

    static func storage(for output: FilePath) -> FilePath {
      output.removingLastComponent().appending(
        "." + (output.lastComponent?.string ?? "") + ".pinewind-generations")
    }

    static func validate(_ output: FilePath) throws {
      var isDirectory: ObjCBool = false
      if let target = try currentTarget(output) {
        let target = try resolvedPath(target)
        guard
          try canonicalPath(target.removingLastComponent())
            == canonicalPath(storage(for: output)),
          isGeneration(target.lastComponent?.string ?? "")
        else {
          throw FileSystemFailure.publicationFailed(
            detail: "composition output is not a Pinewind generation junction")
        }
      } else if FileManager.default.fileExists(atPath: output.string, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
          throw FileSystemFailure.publicationFailed(
            detail: "Windows composition output must be a directory")
        }
        guard try FileManager.default.contentsOfDirectory(atPath: output.string).isEmpty else {
          throw FileSystemFailure.publicationFailed(
            detail: "Windows composition output must be empty or managed by Pinewind")
        }
      }
    }

    static func publish(_ candidate: FilePath, at output: FilePath) throws {
      let fm = FileManager.default
      if try currentTarget(output) != nil || fm.fileExists(atPath: output.string) {
        try redirect(output, to: candidate)
      } else {
        let link = output.removingLastComponent().appending(
          ".pinewind-link-" + UUID().uuidString)
        try fm.createDirectory(at: link, withIntermediateDirectories: false)
        defer {
          if let path = try? windowsNativePath(link) {
            _ = path.withPlatformString { RemoveDirectoryW($0) }
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
      where isGeneration(old.lastComponent?.string ?? "") {
        guard let path = try? canonicalPath(old), path != activePath, path != candidatePath else {
          continue
        }
        try? fm.removeItem(at: old)
      }
    }

    private static func isGeneration(_ name: String) -> Bool {
      name.hasPrefix("generation-") && UUID(uuidString: String(name.dropFirst(11))) != nil
    }

    private static func withHandle<T>(
      _ url: FilePath, access: DWORD, following: Bool = false, _ body: (HANDLE) throws -> T
    ) throws -> T {
      let handle = try windowsNativePath(url).withPlatformString {
        CreateFileW(
          $0, access, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_BACKUP_SEMANTICS) | (following ? 0 : DWORD(FILE_FLAG_OPEN_REPARSE_POINT)),
          nil)
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw FileSystemFailure.publicationFailed(
          detail: "cannot open composition junction (Windows error \(GetLastError()))")
      }
      defer { _ = CloseHandle(handle) }
      return try body(handle)
    }

    /// Resolve the nearest existing ancestor through the filesystem, including
    /// short names, junctions and case aliases, then append absent components.
    static func canonicalPath(_ url: FilePath) throws -> FilePath {
      FilePath(try resolvedPath(url).string.lowercased())
    }

    static func resolvedPath(_ url: FilePath) throws -> FilePath {
      var ancestor = url
      var missing: [FilePath.Component] = []
      while !FileManager.default.fileExists(atPath: ancestor.string) {
        let parent = ancestor.removingLastComponent()
        guard parent != ancestor, let component = ancestor.lastComponent else {
          throw FileSystemFailure.publicationFailed(detail: "cannot resolve composition path")
        }
        missing.append(component)
        ancestor = parent
      }
      var resolved = try withHandle(ancestor, access: 0, following: true) { handle in
        var buffer = [WCHAR](repeating: 0, count: 32_768)
        let count = GetFinalPathNameByHandleW(handle, &buffer, DWORD(buffer.count), 0)
        guard count > 0, Int(count) < buffer.count else {
          throw FileSystemFailure.publicationFailed(
            detail: "cannot resolve composition path (Windows error \(GetLastError()))")
        }
        let path = FilePath(platformString: buffer)
        return try windowsNativePath(path)
      }
      for component in missing.reversed() { resolved.append(component) }
      let normalized = resolved.lexicallyNormalized()
      if normalized != resolved { return try resolvedPath(normalized) }
      return resolved
    }

    static func currentTarget(_ output: FilePath) throws -> FilePath? {
      let attributes = try windowsNativePath(output).withPlatformString {
        GetFileAttributesW($0)
      }
      if attributes == DWORD(INVALID_FILE_ATTRIBUTES) {
        let error = GetLastError()
        if error == DWORD(ERROR_FILE_NOT_FOUND) || error == DWORD(ERROR_PATH_NOT_FOUND) {
          return nil
        }
        throw FileSystemFailure.publicationFailed(
          detail: "cannot inspect composition output (Windows error \(error))")
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
          throw FileSystemFailure.publicationFailed(
            detail: "cannot read composition junction (Windows error \(GetLastError()))")
        }
        guard count >= 16,
          buffer.integer(at: 0, as: UInt32.self) == UInt32(IO_REPARSE_TAG_MOUNT_POINT)
        else {
          throw FileSystemFailure.publicationFailed(
            detail: "composition output is not a directory junction")
        }
        let offset = 16 + Int(buffer.integer(at: 8, as: UInt16.self))
        let length = Int(buffer.integer(at: 10, as: UInt16.self))
        guard offset + length <= Int(count), length.isMultiple(of: 2),
          var path = String(
            data: buffer.subdata(in: offset..<(offset + length)), encoding: .utf16LittleEndian),
          path.hasPrefix("\\??\\")
        else {
          throw FileSystemFailure.publicationFailed(detail: "invalid composition junction target")
        }
        path.removeFirst(4)
        if path.hasPrefix("UNC\\") { path = "\\\\" + path.dropFirst(4) }
        return FilePath(path)
      }
    }

    static func redirect(_ output: FilePath, to candidate: FilePath) throws {
      let printName = try windowsNativePath(candidate).string
      let substituteName =
        printName.hasPrefix("\\\\")
        ? "\\??\\UNC\\" + printName.dropFirst(2) : "\\??\\" + printName
      let substitute = Array(substituteName.utf16)
      let printable = Array(printName.utf16)
      let dataLength = 8 + (substitute.count + printable.count + 2) * 2
      guard dataLength + 8 <= 16_384 else {
        throw FileSystemFailure.publicationFailed(detail: "composition junction path is too long")
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
          throw FileSystemFailure.publicationFailed(
            detail: "cannot publish composition junction (Windows error \(GetLastError()))")
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
