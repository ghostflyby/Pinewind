// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

/// A normalized relative resource or output path backed by the host's FilePath.
public struct RelativePath: Hashable, Sendable, Comparable, CustomStringConvertible {
  public let filePath: FilePath

  public init(_ path: FilePath) throws {
    guard path.root == nil,
      path.components.allSatisfy({ !$0.string.contains(":") && !$0.string.contains("\\") })
    else {
      throw PinewindError(
        .invalidPath, "resource paths require portable relative components", source: path.string)
    }
    let normalized = path.lexicallyNormalized()
    guard !normalized.isEmpty, String(validating: normalized) != nil,
      normalized.components.allSatisfy({ $0.kind == .regular })
    else { throw PinewindError(.invalidPath, "unsafe relative path", source: path.string) }
    filePath = normalized
  }

  public init(_ string: String) throws {
    guard !string.contains("\0"), !string.contains("\\") else {
      throw PinewindError(
        .invalidPath, "portable resource paths must not contain NUL or backslashes")
    }
    try self.init(FilePath(string))
  }

  /// Platform-independent spelling used in documents and inspection results.
  public var string: String { filePath.components.map(\.string).joined(separator: "/") }
  public var description: String { string }
  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.string.utf8.lexicographicallyPrecedes(rhs.string.utf8)
  }
}

/// External documents retain their original file URL for coordination and authorization.
public enum FileLocation: Hashable, Sendable {
  case path(FilePath)
  case fileURL(URL)

  func resolved(relativeTo base: FilePath?) throws -> Self {
    switch self {
    case .path(let path): return .path(try NativePath.absolute(path, relativeTo: base))
    case .fileURL(let url):
      guard try NativePath.from(url).isAbsolute else {
        throw PinewindError(
          .invalidPath, "external document URLs must identify an absolute location")
      }
      return self
    }
  }
  var url: URL {
    get throws {
      switch self {
      case .fileURL(let url): return url
      case .path(let path): return try path.foundationURL
      }
    }
  }
  var filePath: FilePath {
    get throws {
      switch self {
      case .path(let path): return path
      case .fileURL(let url): return try NativePath.from(url)
      }
    }
  }
}

public struct ConfigurationFiles: Hashable, Sendable {
  public let manifest: FileLocation
  public let localOverrides: FileLocation?
  public let lock: FileLocation
  public init(manifest: FileLocation, localOverrides: FileLocation? = nil, lock: FileLocation) {
    self.manifest = manifest
    self.localOverrides = localOverrides
    self.lock = lock
  }
}

public struct WorkspaceLocations: Hashable, Sendable {
  public let userFilesRoot: FileLocation
  public let configuration: ConfigurationFiles
  public let stateRoot: FilePath
  public let cacheRoot: FilePath
  public let relativeTo: FilePath

  public init(
    userFilesRoot: FileLocation, configuration: ConfigurationFiles,
    stateRoot: FilePath, cacheRoot: FilePath, relativeTo: FilePath? = nil
  ) throws {
    let relativeTo = try NativePath.absolute(
      relativeTo ?? FilePath(FileManager.default.currentDirectoryPath))
    self.relativeTo = relativeTo
    self.userFilesRoot = try userFilesRoot.resolved(relativeTo: relativeTo)
    self.configuration = try ConfigurationFiles(
      manifest: configuration.manifest.resolved(relativeTo: relativeTo),
      localOverrides: configuration.localOverrides?.resolved(relativeTo: relativeTo),
      lock: configuration.lock.resolved(relativeTo: relativeTo))
    self.stateRoot = try NativePath.absolute(stateRoot, relativeTo: relativeTo)
    self.cacheRoot = try NativePath.absolute(cacheRoot, relativeTo: relativeTo)
    let input = try self.userFilesRoot.filePath
    for managed in [self.stateRoot, self.cacheRoot] {
      guard try !SafePath.overlaps(input, managed) else {
        throw PinewindError(.invalidPath, "managed storage must not overlap user files")
      }
      for file in [
        self.configuration.manifest, self.configuration.lock, self.configuration.localOverrides,
      ].compactMap({ $0 }) {
        guard try !SafePath.overlaps(managed, file.filePath) else {
          throw PinewindError(
            .invalidPath, "managed storage must not contain configuration documents")
        }
      }
    }
    guard try !SafePath.overlaps(self.stateRoot, self.cacheRoot) else {
      throw PinewindError(.invalidPath, "persistent state and disposable cache must not overlap")
    }
    let documents = try [
      self.configuration.manifest, self.configuration.lock, self.configuration.localOverrides,
    ].compactMap({ $0 }).map { try SafePath.canonical($0.filePath) }
    guard Set(documents).count == documents.count else {
      throw PinewindError(.invalidPath, "configuration documents must have distinct locations")
    }
  }
}

enum NativePath {
  /// Resolve once at a public entry point, before asynchronous work begins.
  static func absolute(_ path: FilePath, relativeTo base: FilePath? = nil) throws -> FilePath {
    if path.isAbsolute { return path }
    guard path.root == nil else {
      throw PinewindError(
        .invalidPath, "drive-relative and root-relative paths require a fully qualified location",
        source: path.string)
    }
    let base =
      try base.map { try absolute($0) }
      ?? FilePath(FileManager.default.currentDirectoryPath)
    return base.appending(path.components)
  }
  static func from(_ url: URL) throws -> FilePath {
    guard url.isFileURL, !url.absoluteString.contains("%00"), !url.path.contains("\0"),
      let representation = url.withUnsafeFileSystemRepresentation({ pointer in
        pointer.flatMap { String(validatingCString: $0) }
      })
    else { throw PinewindError(.invalidPath, "expected a representable file URL") }
    #if os(Windows)
      var value = representation.replacingOccurrences(of: "/", with: "\\")
      if value.hasPrefix("\\"), value.dropFirst(2).hasPrefix(":") { value.removeFirst() }
      // Corelibs' filesystem representation omits the file URL's authority.
      // Preserve it when constructing a native UNC path.
      if let host = url.host, !host.isEmpty, !value.hasPrefix("\\\\"),
        host != "localhost" || !FilePath(value).isAbsolute
      {
        value = "\\\\" + host + "\\" + value.drop(while: { $0 == "\\" })
      }
      let path = FilePath(value)
    #else
      guard url.host == nil || url.host == "" || url.host == "localhost" else {
        throw PinewindError(.invalidPath, "file URL must address the local filesystem")
      }
      let path = FilePath(representation)
    #endif
    return path
  }
}

// Foundation is an adapter at the native I/O edge; managed interfaces stay FilePath-only.
extension FilePath {
  var foundationURL: URL {
    get throws {
      guard let value = String(validating: self) else {
        throw PinewindError(.invalidPath, "unrepresentable path")
      }
      return URL(filePath: value, directoryHint: .notDirectory)
    }
  }
}
extension FileManager {
  func createDirectory(
    at path: FilePath, withIntermediateDirectories intermediates: Bool,
    attributes: [FileAttributeKey: Any]? = nil
  ) throws {
    try createDirectory(
      at: path.foundationURL, withIntermediateDirectories: intermediates, attributes: attributes)
  }
  func copyItem(at source: FilePath, to destination: FilePath) throws {
    try Cancellation.check()
    try copyItem(at: source.foundationURL, to: destination.foundationURL)
    try Cancellation.check()
  }
  func moveItem(at source: FilePath, to destination: FilePath) throws {
    try moveItem(at: source.foundationURL, to: destination.foundationURL)
  }
  func removeItem(at path: FilePath) throws { try removeItem(at: path.foundationURL) }
  func contentsOfDirectory(at path: FilePath, includingPropertiesForKeys keys: [URLResourceKey]?)
    throws -> [FilePath]
  {
    try contentsOfDirectory(at: path.foundationURL, includingPropertiesForKeys: keys).map {
      try NativePath.from($0)
    }
  }
}
extension Data {
  init(contentsOf path: FilePath) throws { try self.init(contentsOf: path.foundationURL) }
  func write(to path: FilePath, options: WritingOptions = []) throws {
    try write(to: path.foundationURL, options: options)
  }
}
extension String {
  init(contentsOf path: FilePath, encoding: Encoding) throws {
    try self.init(contentsOf: path.foundationURL, encoding: encoding)
  }
}
