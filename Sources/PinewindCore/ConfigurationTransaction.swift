// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

#if os(Windows)
  import WinSDK
#else
  import CPinewindPlatform
#endif

/// Durable redo journal. Access is serialized with all configuration documents.
/// Once the journal commits, recovery finishes the entire transaction. External
/// readers and cloud synchronization do not participate in this protocol.
struct ConfigurationTransaction: Codable {
  let version: Int
  let documents: [String]
  let before: [Data?]
  let after: [Data?]

  static func recover(at journal: URL, documents: [URL], identities: [String]) throws {
    guard let bytes = try ConfigurationStore.read(journal) else { return }
    let transaction: Self
    do { transaction = try PropertyListDecoder().decode(Self.self, from: bytes) } catch {
      throw StateFailure.invalidConfigurationTransaction(try NativePath.from(journal))
    }
    guard transaction.version == 1, transaction.documents == identities,
      transaction.before.count == documents.count, transaction.after.count == documents.count
    else { throw StateFailure.invalidConfigurationTransaction(try NativePath.from(journal)) }
    let current = try documents.map(ConfigurationStore.read)
    guard
      current.indices.allSatisfy({
        current[$0] == transaction.before[$0] || current[$0] == transaction.after[$0]
      })
    else { throw StateFailure.externallyModified }
    let order = documents.indices.filter { $0 != 1 } + documents.indices.filter { $0 == 1 }
    for index in order where current[index] != transaction.after[index] {
      try DurableFile.write(transaction.after[index], to: NativePath.from(documents[index]))
    }
    try DurableFile.write(nil, to: NativePath.from(journal))
  }

  func commit(at journal: URL, documents urls: [URL]) throws {
    try DurableFile.write(PropertyListEncoder().encode(self), to: NativePath.from(journal))
    let order = urls.indices.filter { $0 != 1 } + urls.indices.filter { $0 == 1 }
    for index in order where before[index] != after[index] {
      try DurableFile.write(after[index], to: NativePath.from(urls[index]))
    }
    try DurableFile.write(nil, to: NativePath.from(journal))
  }
}

/// Atomic replacement with file and directory durability at each commit point.
enum DurableFile {
  static func write(_ bytes: Data?, to path: FilePath) throws {
    let parent = path.removingLastComponent()
    try FileIO.perform(.write, paths: [path]) {
      if let bytes {
        var missing: [FilePath] = []
        var ancestor = parent
        while !FileManager.default.fileExists(atPath: ancestor.string), !ancestor.isEmpty {
          missing.append(ancestor)
          let next = ancestor.removingLastComponent()
          if next == ancestor { break }
          ancestor = next
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        for created in missing.reversed() { try syncDirectory(created.removingLastComponent()) }
        let temporary = parent.appending(".pinewind-transaction-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try bytes.write(to: temporary)
        let descriptor = try FileDescriptor.open(temporary, .readWrite)
        do {
          defer { try? descriptor.close() }
          try descriptor.synchronize()
        }
        #if os(Windows)
          let success = temporary.withPlatformString { source in
            path.withPlatformString { target in
              MoveFileExW(source, target, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            }
          }
          guard success else {
            throw NSError(domain: "NSWin32ErrorDomain", code: Int(GetLastError()))
          }
        #else
          let status = temporary.withPlatformString { source in
            path.withPlatformString { target in pinewind_replace_file(source, target) }
          }
          guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
        #endif
      } else if FileManager.default.fileExists(atPath: path.string) {
        #if os(Windows)
          guard path.withPlatformString({ DeleteFileW($0) }) else {
            throw NSError(domain: "NSWin32ErrorDomain", code: Int(GetLastError()))
          }
        #else
          let status = path.withPlatformString { pinewind_remove_file($0) }
          guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
        #endif
      } else {
        return
      }
      try syncDirectory(parent)
    }
  }

  private static func syncDirectory(_ path: FilePath) throws {
    #if !os(Windows)
      let descriptor = try FileDescriptor.open(
        path, .readOnly, options: [.directory, .closeOnExec])
      defer { try? descriptor.close() }
      try descriptor.synchronize()
    #endif
  }
}
