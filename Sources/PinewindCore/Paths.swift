// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

/// A portable output path, independent of the host filesystem's path grammar.
public struct RelativePath: Hashable, Sendable, Comparable, CustomStringConvertible {
  public let string: String
  public init(_ string: String) throws {
    let parts = string.split(separator: "/", omittingEmptySubsequences: false)
    guard !string.isEmpty, !string.contains("\\"), !string.contains("\0"),
      !string.contains(":"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw PinewindError(.invalidPath, "unsafe relative path '\(string)'") }
    self.string = string
  }
  public var description: String { string }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.string < rhs.string }
}

/// External documents retain their original file URL for coordination and authorization.
public enum FileLocation: Hashable, Sendable {
  case path(FilePath)
  case fileURL(URL)

  func resolved(relativeTo base: FilePath?) throws -> Self {
    switch self {
    case .path(let path): return .path(try NativePath.absolute(path, relativeTo: base))
    case .fileURL(let url):
      _ = try NativePath.from(url)
      return self
    }
  }
  var url: URL {
    get throws {
      switch self {
      case .fileURL(let url):
        _ = try NativePath.from(url)
        return url
      case .path(let path): return try path.foundationURL
      }
    }
  }
  var filePath: FilePath { get throws { try NativePath.from(url) } }
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
  public let relativeTo: FilePath?

  public init(
    userFilesRoot: FileLocation, configuration: ConfigurationFiles,
    stateRoot: FilePath, cacheRoot: FilePath, relativeTo: FilePath? = nil
  ) throws {
    if let relativeTo { try NativePath.requireAbsolute(relativeTo) }
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
  static func requireAbsolute(_ path: FilePath) throws {
    guard path.isAbsolute, String(validating: path) != nil, !path.isEmpty else {
      throw PinewindError(
        .invalidPath, "an absolute, Unicode-representable filesystem path is required",
        source: path.string)
    }
  }
  static func absolute(_ path: FilePath, relativeTo base: FilePath?) throws -> FilePath {
    if path.isAbsolute {
      try requireAbsolute(path)
      return path
    }
    guard !path.isEmpty, path.root == nil, let base else {
      throw PinewindError(
        .invalidPath, "relative paths require an explicit absolute base", source: path.string)
    }
    try requireAbsolute(base)
    let result = base.appending(path.components)
    try requireAbsolute(result)
    return result
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
    try requireAbsolute(path)
    return path
  }
}

// Foundation is an adapter at the native I/O edge; managed interfaces stay FilePath-only.
extension FilePath {
  var foundationURL: URL {
    get throws {
      try NativePath.requireAbsolute(self)
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
