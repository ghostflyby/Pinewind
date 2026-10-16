// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CGitKit
import Foundation
import SystemPackage

/// Internal seam for deterministic tests. Production callers enter through the
/// fetcher's HTTPS validation; local transport is used only by fixture adapters.
protocol GitTransport: Sendable {
  func advertise(url: URL) throws -> [GitReference]
  func containsCommit(_ commit: String, repository: FilePath) throws -> Bool
  func fetch(url: URL, repository: FilePath, commit: String) throws
  func export(commit: String, repository: FilePath, destination: FilePath) throws
}

struct GitKitTransport: GitTransport {
  let credentials: GitCredentialProvider?

  func advertise(url: URL) throws -> [GitReference] {
    GitLibrary.ensureInitialized()
    let remote = try makeRemote(url: url)
    defer { git_remote_free(remote) }
    return try withCallbacks(url: url) { callbacks in
      try check(git_remote_connect(remote, GIT_DIRECTION_FETCH, &callbacks, nil, nil))
      defer { git_remote_disconnect(remote) }
      var heads: UnsafeMutablePointer<UnsafePointer<git_remote_head>?>?
      var count = 0
      try check(git_remote_ls(&heads, &count, remote))
      return (0..<count).compactMap { index in
        guard let head = heads?[index]?.pointee, let name = head.name else { return nil }
        var oid = head.oid
        return GitReference(
          name: String(cString: name), commit: format(&oid),
          symbolicTarget: head.symref_target.map { String(cString: $0) })
      }
    }
  }

  func containsCommit(_ commit: String, repository: FilePath) throws -> Bool {
    guard FileManager.default.fileExists(atPath: repository.string) else { return false }
    return try withRepository(repository) { repo in
      var oid = try parse(commit)
      var object: OpaquePointer?
      let status = git_commit_lookup(&object, repo, &oid)
      defer { git_commit_free(object) }
      if status == GIT_ENOTFOUND.rawValue { return false }
      try check(status)
      return true
    }
  }

  func fetch(url: URL, repository: FilePath, commit: String) throws {
    if !FileManager.default.fileExists(atPath: repository.string) {
      GitLibrary.ensureInitialized()
      var repo: OpaquePointer?
      try check(git_repository_init(&repo, repository.string, 1))
      git_repository_free(repo)
    }
    try withRepository(repository) { repo in
      let remote = try makeRemote(url: url, repository: repo)
      defer { git_remote_free(remote) }
      try fetch(
        remote, url: url,
        refspecs: [
          "+refs/heads/*:refs/remotes/origin/*", "+refs/tags/*:refs/tags/*",
        ])
      var oid = try parse(commit)
      var object: OpaquePointer?
      let status = git_commit_lookup(&object, repo, &oid)
      defer { git_commit_free(object) }
      if status == GIT_ENOTFOUND.rawValue {
        // Servers may permit requesting a reachable but unadvertised commit.
        // Do not substitute a moving branch tip when the locked ID is unavailable.
        try fetch(remote, url: url, refspecs: ["+\(commit):refs/pinewind/commits/\(commit)"])
        var fetched: OpaquePointer?
        try check(git_commit_lookup(&fetched, repo, &oid))
        git_commit_free(fetched)
      } else {
        try check(status)
      }
    }
  }

  func export(commit: String, repository: FilePath, destination: FilePath) throws {
    try withRepository(repository) { repo in
      var oid = try parse(commit)
      var object: OpaquePointer?
      try check(git_commit_lookup(&object, repo, &oid))
      defer { git_commit_free(object) }
      var tree: OpaquePointer?
      try check(git_commit_tree(&tree, object))
      defer { git_tree_free(tree) }
      try validate(tree: tree, repository: repo, prefix: "")
      var options = git_checkout_options()
      try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
      options.checkout_strategy =
        UInt32(GIT_CHECKOUT_FORCE.rawValue)
        | UInt32(GIT_CHECKOUT_DONT_UPDATE_INDEX.rawValue)
        | UInt32(GIT_CHECKOUT_DONT_WRITE_INDEX.rawValue)
      // A commit snapshot contains blob bytes, without platform EOL/smudge filters.
      options.disable_filters = 1
      options.notify_flags = UInt32(GIT_CHECKOUT_NOTIFY_ALL.rawValue)
      options.notify_cb = { _, _, _, _, _, _ in Cancellation.isCancelled ? GIT_EUSER.rawValue : 0 }
      try destination.string.withCString { path in
        options.target_directory = path
        try check(git_checkout_tree(repo, tree, &options))
      }
      // Pin successful views even when the selected commit was already cached
      // as an ancestor of a different, previously fetched version.
      var pin: OpaquePointer?
      try check(
        git_reference_create(&pin, repo, "refs/pinewind/commits/" + commit, &oid, 1, "Pinewind pin")
      )
      git_reference_free(pin)
    }
  }

  private func fetch(_ remote: OpaquePointer?, url: URL, refspecs: [String]) throws {
    var strings = refspecs.map { strdup($0) }
    defer { for string in strings { free(string) } }
    try strings.withUnsafeMutableBufferPointer { buffer in
      var array = git_strarray(strings: buffer.baseAddress, count: buffer.count)
      var options = git_fetch_options()
      try check(git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION)))
      options.download_tags = GIT_REMOTE_DOWNLOAD_TAGS_NONE
      try withCallbacks(url: url) { callbacks in
        options.callbacks = callbacks
        defer { git_remote_disconnect(remote) }
        try check(git_remote_fetch(remote, &array, &options, nil))
      }
    }
  }

  private func makeRemote(url: URL, repository: OpaquePointer? = nil) throws -> OpaquePointer {
    guard url.scheme?.lowercased() == "https" || url.isFileURL else {
      throw PinewindError("unsupported Git transport")
    }
    var options = git_remote_create_options()
    try check(git_remote_create_options_init(&options, UInt32(GIT_REMOTE_CREATE_OPTIONS_VERSION)))
    options.repository = repository
    options.flags =
      UInt32(GIT_REMOTE_CREATE_SKIP_INSTEADOF.rawValue)
      | UInt32(GIT_REMOTE_CREATE_SKIP_DEFAULT_FETCHSPEC.rawValue)
    var remote: OpaquePointer?
    try check(git_remote_create_with_opts(&remote, url.absoluteString, &options))
    guard let remote else { throw PinewindError("Git remote could not be created") }
    return remote
  }

  private func validate(tree: OpaquePointer?, repository: OpaquePointer?, prefix: String) throws {
    for index in 0..<git_tree_entrycount(tree) {
      try Cancellation.check()
      guard let entry = git_tree_entry_byindex(tree, index), let name = git_tree_entry_name(entry)
      else {
        throw PinewindError("Git tree contains an invalid entry")
      }
      guard let component = String(validatingCString: name) else {
        throw PinewindError(.invalidPath, "Git tree entry name must be UTF-8")
      }
      let path = prefix + component
      // Tree entries are individual names, not expressions to normalize before checkout.
      let relative = try RelativePath(FilePath(component))
      guard relative.filePath.components.count == 1,
        relative.string.utf8.elementsEqual(component.utf8)
      else {
        throw PinewindError(.invalidPath, "Git tree entry must be a single filename", source: path)
      }
      guard component != ".git" else {
        throw PinewindError("Git tree contains reserved metadata", source: path)
      }
      guard git_tree_entry_filemode(entry) != GIT_FILEMODE_LINK else {
        throw PinewindError("symbolic links are not supported in package sources", source: path)
      }
      if git_tree_entry_type(entry) == GIT_OBJECT_TREE {
        var subtree: OpaquePointer?
        try check(git_tree_lookup(&subtree, repository, git_tree_entry_id(entry)))
        defer { git_tree_free(subtree) }
        try validate(tree: subtree, repository: repository, prefix: path + "/")
      }
      // Gitlinks are not recursively fetched; checkout creates at most empty directories.
    }
  }

  private func withRepository<T>(_ directory: FilePath, _ body: (OpaquePointer) throws -> T) throws
    -> T
  {
    GitLibrary.ensureInitialized()
    try Cancellation.check()
    var repository: OpaquePointer?
    try check(git_repository_open(&repository, directory.string))
    guard let repository else {
      throw PinewindError("Git repository could not be opened", source: directory.string)
    }
    defer { git_repository_free(repository) }
    return try body(repository)
  }

  private func withCallbacks<T>(url: URL, _ body: (inout git_remote_callbacks) throws -> T) throws
    -> T
  {
    let context = TransferContext(credentials: credentials, local: url.isFileURL)
    // libgit2 callbacks are synchronous; the context lives through body and its disconnect.
    return try withExtendedLifetime(context) {
      var callbacks = git_remote_callbacks()
      try check(git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION)))
      callbacks.payload = Unmanaged.passUnretained(context).toOpaque()
      callbacks.transfer_progress = { _, _ in Cancellation.isCancelled ? GIT_EUSER.rawValue : 0 }
      callbacks.sideband_progress = { _, _, _ in Cancellation.isCancelled ? GIT_EUSER.rawValue : 0 }
      callbacks.transport = { out, owner, payload in
        guard let payload else { return GIT_EUSER.rawValue }
        let context = Unmanaged<TransferContext>.fromOpaque(payload).takeUnretainedValue()
        if context.local { return git_transport_local(out, owner, nil) }
        // Force the in-process HTTP transport, even if ambient git configuration
        // or another library registered an SSH/exec transport or URL rewrite.
        var definition = git_smart_subtransport_definition(
          callback: git_smart_subtransport_http, rpc: 1, param: nil)
        return withUnsafeMutablePointer(to: &definition) { git_transport_smart(out, owner, $0) }
      }
      callbacks.credentials = { out, rawURL, username, allowed, payload in
        guard !Cancellation.isCancelled, let rawURL, let payload,
          let url = URL(string: String(cString: rawURL)), url.scheme?.lowercased() == "https"
        else {
          return GIT_EUSER.rawValue
        }
        let context = Unmanaged<TransferContext>.fromOpaque(payload).takeUnretainedValue()
        guard let supplied = context.credentials?(url) else { return GIT_EUSER.rawValue }
        if allowed & UInt32(GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue) != 0 {
          return git_credential_userpass_plaintext_new(out, supplied.username, supplied.password)
        }
        if allowed & UInt32(GIT_CREDENTIAL_USERNAME.rawValue) != 0 {
          return git_credential_username_new(out, supplied.username)
        }
        return GIT_EUSER.rawValue
      }
      return try body(&callbacks)
    }
  }

  private func parse(_ commit: String) throws -> git_oid {
    var oid = git_oid()
    try check(git_oid_fromstr(&oid, commit))
    return oid
  }

  private func format(_ oid: inout git_oid) -> String {
    var buffer = [CChar](repeating: 0, count: 41)
    return buffer.withUnsafeMutableBufferPointer { bytes in
      _ = git_oid_tostr(bytes.baseAddress, bytes.count, &oid)
      return String(cString: bytes.baseAddress!)
    }
  }

  private func check(_ status: Int32) throws {
    try Cancellation.check()
    guard status >= 0 else {
      let message =
        git_error_last().flatMap { $0.pointee.message }.map { String(cString: $0) }
        ?? "unknown error"
      throw PinewindError(
        status == GIT_EAUTH.rawValue ? .authenticationFailed : .io,
        "Git operation failed (\(status)): \(message)")
    }
  }
}

private final class TransferContext: Sendable {
  let credentials: GitCredentialProvider?
  let local: Bool
  init(credentials: GitCredentialProvider?, local: Bool) {
    self.credentials = credentials
    self.local = local
  }
}

private enum GitLibrary {
  // Retain one process-wide initialization reference while this backend is in use.
  private static let initialized: Bool = git_libgit2_init() >= 0

  static func ensureInitialized() {
    precondition(initialized, "libgit2 initialization failed")
  }
}
