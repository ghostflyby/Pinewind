// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SystemPackage

#if !os(Windows)
  import CPinewindPlatform
#endif

public struct CompositionResult: Sendable {
  public let directory: FilePath
  public let paths: [RelativePath]
  public let changedPaths: [RelativePath]
  public let removedPaths: [RelativePath]
  public let reusedPaths: [RelativePath]
  init(
    directory: FilePath, paths: [String], changedPaths: [String], removedPaths: [String],
    reusedPaths: [String]
  ) throws {
    self.directory = directory
    self.paths = try paths.map(RelativePath.init)
    self.changedPaths = try changedPaths.map(RelativePath.init)
    self.removedPaths = try removedPaths.map(RelativePath.init)
    self.reusedPaths = try reusedPaths.map(RelativePath.init)
  }

}

/// Renders a candidate generation and atomically publishes it as the active
/// output. Previous bytes are only reused after comparing the fully rendered
/// candidate, so deletions, local edits and lost change notifications stay correct.
struct Composer {
  /// On Windows, outputRoot must be absent, empty, or a junction managed by Pinewind.
  func compose(_ plan: CompositionPlan, inputRoot: FilePath, outputRoot requestedOutput: FilePath)
    throws
    -> CompositionResult
  {
    // Captured paths do not retain their owner. Keep it alive through all reads,
    // including optimized builds that may end a property's lifetime at last use.
    defer { withExtendedLifetime(plan.snapshot) {} }
    try Cancellation.check()
    try NativePath.requireAbsolute(inputRoot)
    try NativePath.requireAbsolute(requestedOutput)
    #if os(Windows)
      let outputRoot = try WindowsDirectoryPublisher.publicationPath(requestedOutput)
    #else
      let outputRoot = FilePath(try SafePath.canonical(requestedOutput))
    #endif
    try SafePath.validateRoots(
      input: inputRoot, output: outputRoot, sources: plan.sourceRoots + [plan.snapshot.directory])
    #if os(Windows)
      try SafePath.validateOutputRoot(outputRoot)
      let storage = WindowsDirectoryPublisher.storage(for: outputRoot)
      try SafePath.validateRoots(
        input: inputRoot, output: storage, sources: plan.sourceRoots + [plan.snapshot.directory])
      try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
      return try NativeLock.withLock(
        outputRoot.removingLastComponent().appending(
          "." + outputRoot.lastPathComponent + ".pinewind-publication.lock")
      ) {
        try composeGeneration(plan, inputRoot: inputRoot, outputRoot: outputRoot)
      }
    #else
      return try NativeLock.withLock(
        outputRoot.removingLastComponent().appending(
          "." + outputRoot.lastPathComponent + ".pinewind-publication.lock")
      ) {
        try composeGeneration(plan, inputRoot: inputRoot, outputRoot: outputRoot)
      }
    #endif
  }

  private func composeGeneration(_ plan: CompositionPlan, inputRoot: FilePath, outputRoot: FilePath)
    throws
    -> CompositionResult
  {
    try SafePath.validateRoots(
      input: inputRoot, output: outputRoot, sources: plan.sourceRoots + [plan.snapshot.directory])
    #if os(Windows)
      try WindowsDirectoryPublisher.validate(outputRoot)
    #endif
    let fm = FileManager.default
    let exists = fm.fileExists(atPath: outputRoot.path)
    let previous = exists ? try SafePath.files(in: outputRoot) : []
    let parent = outputRoot.deletingLastPathComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    #if os(Windows)
      let storage = WindowsDirectoryPublisher.storage(for: outputRoot)
      let candidate = storage.appendingPathComponent(
        "generation-" + UUID().uuidString, isDirectory: true)
    #else
      let candidate = parent.appendingPathComponent(".pinewind-" + UUID().uuidString)
    #endif
    try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
    var retained = false
    defer { if !retained { try? fm.removeItem(at: candidate) } }
    var reused: [String] = []
    var changed: [String] = []
    for path in plan.stringPaths {
      try Cancellation.check()
      guard let operations = plan.files[path] else { continue }
      let destination = try SafePath.file(path, in: candidate)
      try fm.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try render(operations, to: destination)
      var matchesPrevious = false
      if exists {
        let old = try SafePath.file(path, in: outputRoot)
        matchesPrevious =
          try fm.fileExists(atPath: old.path)
          && SnapshotFiles.sameContents(old, destination)
      }
      if matchesPrevious {
        reused.append(path)
      } else {
        changed.append(path)
      }
    }
    let current = Set(plan.stringPaths)
    let removed = previous.filter { !current.contains($0) }
    if exists && changed.isEmpty && removed.isEmpty {
      try plan.binding?.validate()
      try Cancellation.check()
      return try CompositionResult(
        directory: outputRoot, paths: plan.stringPaths,
        changedPaths: [], removedPaths: [], reusedPaths: reused)
    }
    try plan.binding?.validate()
    try Cancellation.check()
    #if os(Windows)
      try WindowsDirectoryPublisher.publish(candidate, at: outputRoot)
      retained = true
    #else
      if exists {
        let status = candidate.withPlatformString { source in
          outputRoot.withPlatformString { destination in
            pinewind_exchange_directories(source, destination)
          }
        }
        guard status == 0 else {
          throw PinewindError(
            .unsupportedFilesystem,
            "cannot atomically exchange composition directories: \(String(cString: strerror(status))) (errno \(status))"
          )
        }
      } else {
        try fm.moveItem(at: candidate, to: outputRoot)
      }
    #endif
    return try CompositionResult(
      directory: outputRoot, paths: plan.stringPaths,
      changedPaths: changed, removedPaths: removed, reusedPaths: reused)
  }

  private func render(_ operations: [CompositionOperation], to destination: FilePath) throws {
    // Execute the full reference chain in M1. Future cached replays may elide
    // overwritten contributions only after preserving validation semantics.
    var bytes: Data?
    var base: FilePath?
    for operation in operations {
      try Cancellation.check()
      switch operation.action {
      case .write(let file):
        base = file
        bytes = nil
      case .patch(let rx, let body):
        let input = try bytes ?? base.map { try Data(contentsOf: $0) }
        bytes = try PatchRenderer.apply(input, rx: rx, body: body)
        base = nil
      }
    }
    if let bytes {
      try bytes.write(to: destination)
    } else if let base {
      // copyItem may clone on APFS; never hard-link mutable candidate files.
      try FileManager.default.copyItem(at: base, to: destination)
    }
  }
}
