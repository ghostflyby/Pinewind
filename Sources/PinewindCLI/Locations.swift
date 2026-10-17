// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ArgumentParser
import Foundation
import PinewindCore
import SystemPackage

#if os(Windows)
  import WinSDK
#endif

enum RimeFrontend: String, CaseIterable, ExpressibleByArgument {
  case squirrel, weasel, fcitx5, fcitx, ibus
}

struct PlatformDirectories {
  let configuration: FilePath
  let state: FilePath
  let cache: FilePath
  let home: FilePath
  let environment: [String: String]

  init(
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

  func rimeDirectory(_ frontend: RimeFrontend) -> FilePath {
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

  func output(frontend: RimeFrontend?) throws -> FilePath {
    let candidates: [RimeFrontend]
    #if os(Windows)
      candidates = [.weasel]
    #elseif os(macOS)
      candidates = [.squirrel, .fcitx5]
    #else
      candidates = [.fcitx5, .fcitx, .ibus]
    #endif
    if let frontend {
      guard candidates.contains(frontend) else {
        throw ValidationError(
          "Frontend '\(frontend.rawValue)' is not supported on this platform. Use --output for a custom location."
        )
      }
      return rimeDirectory(frontend)
    }
    let existing = candidates.filter {
      var directory: ObjCBool = false
      return FileManager.default.fileExists(
        atPath: rimeDirectory($0).string, isDirectory: &directory)
        && directory.boolValue
    }
    if existing.count == 1, let frontend = existing.first { return rimeDirectory(frontend) }
    if existing.count > 1 {
      throw ValidationError(
        "Multiple Rime directories found (\(existing.map(\.rawValue).joined(separator: ", "))). Choose --frontend or --output."
      )
    }
    #if os(macOS)
      return rimeDirectory(.squirrel)
    #elseif os(Windows)
      return rimeDirectory(.weasel)
    #else
      throw ValidationError("Cannot identify a Rime frontend. Choose --frontend or --output.")
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

struct LocationOptions: ParsableArguments {
  @Option(
    help:
      "Directory containing Pinewind's declarations and lock (platform configuration directory by default)."
  )
  var configDirectory: String?
  @Option(help: "Pinewind's machine-local state directory.") var stateDirectory: String?
  @Option(help: "Pinewind's package and resource cache directory.") var cacheDirectory: String?
  @Option(
    help:
      "Personal configuration sources, inserted by self (Pinewind configuration directory/user by default)."
  )
  var userFiles: String?
  @Option(help: "Maximum bytes per downloaded resource (default: 67108864).")
  var maximumResourceBytes: Int?

  func validate() throws {
    if let maximumResourceBytes, maximumResourceBytes <= 0 {
      throw ValidationError("--maximum-resource-bytes must be positive.")
    }
  }

  func locations() throws -> WorkspaceLocations {
    let defaults = PlatformDirectories()
    let config = FilePath(configDirectory ?? defaults.configuration.string)
    let state = FilePath(stateDirectory ?? defaults.state.string)
    return try WorkspaceLocations(
      userFilesRoot: .path(FilePath(userFiles ?? config.appending("user").string)),
      configuration: ConfigurationFiles(
        manifest: .path(config.appending("pinewind.yaml")),
        localOverrides: .path(state.appending("pinewind.local.yaml")),
        lock: .path(config.appending("pinewind.lock"))),
      stateRoot: state.appending("managed"),
      cacheRoot: FilePath(cacheDirectory ?? defaults.cache.string))
  }

  func open() async throws -> Workspace {
    let locations = try locations()
    if case .path(let user) = locations.userFilesRoot {
      try FileManager.default.createDirectory(
        at: URL(filePath: user.string, directoryHint: .isDirectory),
        withIntermediateDirectories: true)
    }
    var options = WorkspaceOptions()
    if let maximumResourceBytes { options.maximumResourceBytes = maximumResourceBytes }
    return try await Workspace.open(locations: locations, options: options)
  }
}

struct OutputOptions: ParsableArguments {
  @Option(help: "Rime frontend whose user configuration directory receives the build.")
  var frontend: RimeFrontend?
  @Option(name: .shortAndLong, help: "Override the Rime configuration output directory.")
  var output: String?
  func directory() throws -> FilePath {
    if let output {
      let path = FilePath(output)
      if path.isAbsolute { return path }
      guard path.root == nil else {
        throw ValidationError("Output must be an absolute path or an unambiguous relative path.")
      }
      return FilePath(FileManager.default.currentDirectoryPath).appending(path.components)
        .lexicallyNormalized()
    }
    return try PlatformDirectories().output(frontend: frontend)
  }
}
