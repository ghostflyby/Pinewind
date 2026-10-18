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

  public init(_ path: FilePath) throws(FileSystemFailure) {
    guard path.root == nil,
      path.components.allSatisfy({ !$0.string.contains(":") && !$0.string.contains("\\") })
    else {
      throw FileSystemFailure.notPortable(path)
    }
    let normalized = path.lexicallyNormalized()
    guard !normalized.isEmpty, String(validating: normalized) != nil,
      normalized.components.allSatisfy({ $0.kind == .regular })
    else { throw FileSystemFailure.unsafeRelative(path) }
    filePath = normalized
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

  func resolved(relativeTo base: FilePath?) throws(FileSystemFailure) -> Self {
    switch self {
    case .path(let path): return .path(try NativePath.absolute(path, relativeTo: base))
    case .fileURL(let url):
      guard try NativePath.from(url).isAbsolute else {
        throw FileSystemFailure.notAbsoluteFileURL(url)
      }
      return self
    }
  }
  var url: URL {
    get throws(FileSystemFailure) {
      switch self {
      case .fileURL(let url): return url
      case .path(let path): return try path.foundationURL
      }
    }
  }
  var filePath: FilePath {
    get throws(FileSystemFailure) {
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
        throw FileSystemFailure.overlappingPaths(input, managed)
      }
      for file in [
        self.configuration.manifest, self.configuration.lock, self.configuration.localOverrides,
      ].compactMap({ $0 }) {
        guard try !SafePath.overlaps(managed, file.filePath) else {
          throw FileSystemFailure.overlappingPaths(managed, try file.filePath)
        }
      }
    }
    guard try !SafePath.overlaps(self.stateRoot, self.cacheRoot) else {
      throw FileSystemFailure.overlappingPaths(self.stateRoot, self.cacheRoot)
    }
    let documents = try [
      self.configuration.manifest, self.configuration.lock, self.configuration.localOverrides,
    ].compactMap({ $0 }).map { try SafePath.canonical($0.filePath) }
    var seen: Set<FilePath> = []
    for document in documents {
      guard seen.insert(document).inserted else {
        throw FileSystemFailure.duplicatePath(document)
      }
    }
  }
}

enum NativePath {
  /// Resolve once at a public entry point, before asynchronous work begins.
  static func absolute(_ path: FilePath, relativeTo base: FilePath? = nil) throws(FileSystemFailure)
    -> FilePath
  {
    if path.isAbsolute { return path }
    guard path.root == nil else {
      throw FileSystemFailure.ambiguousForm(path)
    }
    let resolved: FilePath
    switch base {
    case .some(let supplied): resolved = try absolute(supplied)
    case nil: resolved = FilePath(FileManager.default.currentDirectoryPath)
    }
    return resolved.appending(path.components)
  }
  static func from(_ url: URL) throws(FileSystemFailure) -> FilePath {
    guard url.isFileURL, !url.absoluteString.contains("%00"), !url.path.contains("\0"),
      let representation = url.withUnsafeFileSystemRepresentation({ pointer in
        pointer.flatMap { String(validatingCString: $0) }
      })
    else { throw FileSystemFailure.unrepresentableFileURL(url) }
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
        throw FileSystemFailure.nonLocalFileURL(url)
      }
      let path = FilePath(representation)
    #endif
    return path
  }
}

// Foundation is an adapter at the native I/O edge; managed interfaces stay FilePath-only.
extension FilePath {
  var foundationURL: URL {
    get throws(FileSystemFailure) {
      guard let value = String(validating: self) else {
        throw FileSystemFailure.unresolvable(self)
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
    try FileIO.perform(.createDirectory, paths: [path]) {
      try createDirectory(
        at: path.foundationURL, withIntermediateDirectories: intermediates, attributes: attributes)
    }
  }
  func copyItem(at source: FilePath, to destination: FilePath) throws {
    try Cancellation.check()
    try FileIO.perform(.copy, paths: [source, destination]) {
      try copyItem(at: source.foundationURL, to: destination.foundationURL)
    }
    try Cancellation.check()
  }
  func moveItem(at source: FilePath, to destination: FilePath) throws {
    try FileIO.perform(.move, paths: [source, destination]) {
      try moveItem(at: source.foundationURL, to: destination.foundationURL)
    }
  }
  func removeItem(at path: FilePath) throws {
    try FileIO.perform(.remove, paths: [path]) { try removeItem(at: path.foundationURL) }
  }
  func contentsOfDirectory(at path: FilePath, includingPropertiesForKeys keys: [URLResourceKey]?)
    throws -> [FilePath]
  {
    try FileIO.perform(.enumerate, paths: [path]) {
      try contentsOfDirectory(at: path.foundationURL, includingPropertiesForKeys: keys).map {
        try NativePath.from($0)
      }
    }
  }
}
extension Data {
  init(contentsOf path: FilePath) throws {
    self = try FileIO.perform(.read, paths: [path]) { try Data(contentsOf: path.foundationURL) }
  }
  func write(to path: FilePath, options: WritingOptions = []) throws {
    try FileIO.perform(.write, paths: [path]) {
      try write(to: path.foundationURL, options: options)
    }
  }
}
extension String {
  init(contentsOf path: FilePath, encoding: Encoding) throws {
    self = try FileIO.perform(.read, paths: [path]) {
      try String(contentsOf: path.foundationURL, encoding: encoding)
    }
  }
}
