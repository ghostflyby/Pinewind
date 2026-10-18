// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

#if os(Windows)
  import WinSDK
#endif

public enum RimeFrontend: String, CaseIterable, Hashable, Sendable {
  case squirrel, weasel, fcitx5, fcitx, ibus
}

public struct PlatformDirectories: Sendable {
  public let configuration: FilePath
  public let state: FilePath
  public let cache: FilePath
  private let home: FilePath
  private let environment: [String: String]

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: FilePath = FilePath(NSHomeDirectory())
  ) {
    self.home = home
    self.environment = environment
    func base(_ key: String, fallback: FilePath) -> FilePath {
      guard let text = environment[key], !text.isEmpty, FilePath(text).isAbsolute else {
        return fallback
      }
      return FilePath(text)
    }
    #if os(Windows)
      configuration = base("APPDATA", fallback: home.appending("AppData/Roaming")).appending(
        "Pinewind")
      state = base("LOCALAPPDATA", fallback: home.appending("AppData/Local")).appending(
        "Pinewind/State")
      cache = base("LOCALAPPDATA", fallback: home.appending("AppData/Local")).appending(
        "Pinewind/Cache")
    #elseif os(macOS) || os(iOS)
      configuration = home.appending("Library/Application Support/Pinewind")
      state = configuration.appending("State")
      cache = home.appending("Library/Caches/Pinewind")
    #else
      configuration = base("XDG_CONFIG_HOME", fallback: home.appending(".config")).appending(
        "pinewind")
      state = base("XDG_STATE_HOME", fallback: home.appending(".local/state")).appending("pinewind")
      cache = base("XDG_CACHE_HOME", fallback: home.appending(".cache")).appending("pinewind")
    #endif
  }

  /// The shared on-disk layout used by both frontends. Explicit document/file
  /// URLs remain available through WorkspaceLocations for cloud or custom layouts.
  public func workspaceLocations(
    configurationDirectory: FilePath? = nil, stateDirectory: FilePath? = nil,
    cacheDirectory: FilePath? = nil, userFilesRoot: FileLocation? = nil,
    relativeTo: FilePath? = nil
  ) throws -> WorkspaceLocations {
    let configuration = configurationDirectory ?? self.configuration
    let state = stateDirectory ?? self.state
    return try WorkspaceLocations(
      userFilesRoot: userFilesRoot ?? .path(configuration.appending("user")),
      configuration: ConfigurationFiles(
        manifest: .path(configuration.appending("pinewind.yaml")),
        localOverrides: .path(state.appending("pinewind.local.yaml")),
        lock: .path(configuration.appending("pinewind.lock"))),
      stateRoot: state.appending("managed"), cacheRoot: cacheDirectory ?? cache,
      relativeTo: relativeTo)
  }

  public func rimeDirectory(_ frontend: RimeFrontend) -> FilePath {
    func base(_ key: String, fallback: String) -> FilePath {
      if let text = environment[key], !text.isEmpty, FilePath(text).isAbsolute {
        return FilePath(text)
      }
      return home.appending(fallback)
    }
    switch frontend {
    case .squirrel: return home.appending("Library/Rime")
    case .weasel:
      #if os(Windows)
        if let configured = Self.weaselUserDirectory() { return configured }
      #endif
      return base("APPDATA", fallback: "AppData/Roaming").appending("Rime")
    case .fcitx5: return base("XDG_DATA_HOME", fallback: ".local/share").appending("fcitx5/rime")
    case .fcitx: return base("XDG_CONFIG_HOME", fallback: ".config").appending("fcitx/rime")
    case .ibus: return base("XDG_CONFIG_HOME", fallback: ".config").appending("ibus/rime")
    }
  }

  private var supportedFrontends: [RimeFrontend] {
    #if os(Windows)
      return [.weasel]
    #elseif os(macOS)
      return [.squirrel, .fcitx5]
    #else
      return [.fcitx5, .fcitx, .ibus]
    #endif
  }

  /// Existing common locations, available for a GUI destination chooser.
  public func discoverRimeDirectories() -> [RimeDestination] {
    supportedFrontends.compactMap { frontend in
      let directory = rimeDirectory(frontend)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: directory.string, isDirectory: &isDirectory),
        isDirectory.boolValue
      else { return nil }
      return RimeDestination(frontend: frontend, directory: directory)
    }
  }

  public func output(frontend: RimeFrontend?) throws -> FilePath {
    let candidates = supportedFrontends
    if let frontend {
      guard candidates.contains(frontend) else {
        throw PinewindError.runtime(.state(.unsupportedFrontend(frontend.rawValue)))
      }
      return rimeDirectory(frontend)
    }
    let existing = discoverRimeDirectories()
    if existing.count == 1 { return existing[0].directory }
    if existing.count > 1 {
      throw PinewindError.runtime(.state(.ambiguousOutputDirectories(existing.map(\.directory))))
    }
    #if os(macOS)
      return rimeDirectory(.squirrel)
    #elseif os(Windows)
      return rimeDirectory(.weasel)
    #else
      throw PinewindError.runtime(.state(.frontendRequired))
    #endif
  }

  #if os(Windows)
    private static func weaselUserDirectory() -> FilePath? {
      let key = Array("Software\\Rime\\Weasel".utf16) + [0]
      let value = Array("RimeUserDir".utf16) + [0]
      var size: DWORD = 0
      let flags = DWORD(RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ)
      guard RegGetValueW(HKEY_CURRENT_USER, key, value, flags, nil, nil, &size) == ERROR_SUCCESS,
        size >= 2
      else { return nil }
      var buffer = [WCHAR](repeating: 0, count: Int(size) / MemoryLayout<WCHAR>.size)
      let status = buffer.withUnsafeMutableBytes {
        RegGetValueW(HKEY_CURRENT_USER, key, value, flags, nil, $0.baseAddress, &size)
      }
      guard status == ERROR_SUCCESS else { return nil }
      let text = String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
      let path = FilePath(text)
      return path.isAbsolute ? path : nil
    }
  #endif
}

public struct RimeDestination: Hashable, Sendable {
  public let frontend: RimeFrontend
  public let directory: FilePath
}
