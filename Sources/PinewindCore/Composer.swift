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
  /// Formerly managed files kept because they were modified outside Pinewind.
  public let preservedPaths: [RelativePath]
  public let overwrittenUnmanagedPaths: [RelativePath]
  public let warnings: [PublicationWarning]

  init(
    directory: FilePath, paths: [RelativePath], changedPaths: [RelativePath],
    removedPaths: [RelativePath], reusedPaths: [RelativePath], preservedPaths: [RelativePath] = [],
    overwrittenUnmanagedPaths: [RelativePath] = [], warnings: [PublicationWarning] = []
  ) {
    self.directory = directory
    self.paths = paths
    self.changedPaths = changedPaths
    self.removedPaths = removedPaths
    self.reusedPaths = reusedPaths
    self.preservedPaths = preservedPaths
    self.overwrittenUnmanagedPaths = overwrittenUnmanagedPaths
    self.warnings = warnings
  }
}

public enum PublicationWarning: Sendable, CustomStringConvertible {
  case discardedPendingRecord(FilePath)
  public var description: String {
    switch self {
    case .discardedPendingRecord(let path):
      return
        "Discarded corrupt pending publication record: \(path.string). Unproven files remain protected as unmanaged."
    }
  }
}

public enum PublicationMode: Sendable {
  /// Atomically replace a complete directory generation.
  case directory
  /// Update only generated files, preserving unrelated input-method data.
  /// Individual files are atomic; an interrupted multi-file update is recovered
  /// by a subsequent build using the persisted publication intent.
  /// Existing unmanaged files with different bytes require explicit approval.
  case managedFiles(overwriteUnmanaged: Bool = false)
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
    #if os(Windows)
      let outputRoot = try WindowsDirectoryPublisher.publicationPath(requestedOutput)
    #else
      let outputRoot = try SafePath.canonical(requestedOutput)
    #endif
    try SafePath.validateRoots(
      input: inputRoot, output: outputRoot, sources: plan.sourceRoots + [plan.snapshot.directory])
    #if os(Windows)
      let storage = WindowsDirectoryPublisher.storage(for: outputRoot)
      try SafePath.validateRoots(
        input: inputRoot, output: storage, sources: plan.sourceRoots + [plan.snapshot.directory])
      try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    #endif
    return try NativeLock.withLock(
      outputRoot.removingLastComponent().appending(
        "." + (outputRoot.lastComponent?.string ?? "") + ".pinewind-publication.lock")
    ) {
      try composeGeneration(plan, inputRoot: inputRoot, outputRoot: outputRoot)
    }
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
    let exists = fm.fileExists(atPath: outputRoot.string)
    let previous = exists ? try SafePath.files(in: outputRoot) : []
    let parent = outputRoot.removingLastComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    #if os(Windows)
      let storage = WindowsDirectoryPublisher.storage(for: outputRoot)
      let candidate = storage.appending(
        "generation-" + UUID().uuidString)
    #else
      let candidate = parent.appending(".pinewind-" + UUID().uuidString)
    #endif
    try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
    var retained = false
    defer { if !retained { try? fm.removeItem(at: candidate) } }
    let files = plan.files.sorted { $0.key < $1.key }
    let paths = files.map(\.key)
    var reused: [RelativePath] = []
    var changed: [RelativePath] = []
    for (path, operations) in files {
      try Cancellation.check()
      let destination = try SafePath.file(path, in: candidate)
      try fm.createDirectory(
        at: destination.removingLastComponent(), withIntermediateDirectories: true)
      try render(operations, to: destination)
      var matchesPrevious = false
      if exists {
        let old = try SafePath.file(path, in: outputRoot)
        matchesPrevious =
          try fm.fileExists(atPath: old.string)
          && SnapshotFiles.sameContents(old, destination)
      }
      if matchesPrevious {
        reused.append(path)
      } else {
        changed.append(path)
      }
    }
    let current = Set(paths)
    let removed = previous.filter { !current.contains($0) }
    if exists && changed.isEmpty && removed.isEmpty {
      try plan.binding?.validate()
      try Cancellation.check()
      return CompositionResult(
        directory: outputRoot, paths: paths,
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
          throw PinewindError.runtime(.file(.exchangeFailed(errno: status)))
        }
      } else {
        try fm.moveItem(at: candidate, to: outputRoot)
      }
    #endif
    return CompositionResult(
      directory: outputRoot, paths: paths,
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
