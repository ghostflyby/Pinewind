// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Darwin
import Foundation

public struct CompositionResult: Sendable {
  public let directory: URL
  public let paths: [String]
  public let changedPaths: [String]
  public let removedPaths: [String]
  public let reusedPaths: [String]
}

/// Renders a candidate generation and atomically exchanges it with the active
/// output. Previous bytes are only reused after comparing the fully rendered
/// candidate, so deletions, local edits and lost change notifications stay correct.
public actor Composer {
  public init() {}

  public func compose(_ plan: CompositionPlan, inputRoot: URL, outputRoot: URL) throws
    -> CompositionResult
  {
    // Snapshot URLs do not retain their owner. Keep it alive through all reads,
    // including optimized builds that may end a property's lifetime at last use.
    defer { withExtendedLifetime(plan.snapshot) {} }
    guard inputRoot.isFileURL, outputRoot.isFileURL else {
      throw PinewindError("composition roots must be file URLs")
    }
    try SafePath.validateRoots(
      input: inputRoot, output: outputRoot, sources: plan.sourceRoots + [plan.snapshot.directory])
    let fm = FileManager.default
    let exists = fm.fileExists(atPath: outputRoot.path)
    let previous = exists ? try SafePath.files(in: outputRoot) : []
    let parent = outputRoot.deletingLastPathComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    let candidate = parent.appendingPathComponent(".pinewind-" + UUID().uuidString)
    try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: candidate) }
    var reused: [String] = []
    var changed: [String] = []
    for path in plan.paths {
      guard let operations = plan.files[path] else { continue }
      let destination = try SafePath.file(path, in: candidate)
      try fm.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try render(operations, to: destination)
      let old = try SafePath.file(path, in: outputRoot)
      if exists, fm.fileExists(atPath: old.path), try SnapshotFiles.sameContents(old, destination) {
        reused.append(path)
      } else {
        changed.append(path)
      }
    }
    let current = Set(plan.paths)
    let removed = previous.filter { !current.contains($0) }
    if exists && changed.isEmpty && removed.isEmpty {
      return CompositionResult(
        directory: outputRoot, paths: plan.paths,
        changedPaths: [], removedPaths: [], reusedPaths: reused)
    }
    if exists {
      // Darwin directory exchange keeps an existing, nonempty output visible.
      guard
        renameatx_np(AT_FDCWD, candidate.path, AT_FDCWD, outputRoot.path, UInt32(RENAME_SWAP)) == 0
      else {
        throw PinewindError(
          "cannot atomically exchange composition directories: \(String(cString: strerror(errno)))")
      }
    } else {
      try fm.moveItem(at: candidate, to: outputRoot)
    }
    return CompositionResult(
      directory: outputRoot, paths: plan.paths,
      changedPaths: changed, removedPaths: removed, reusedPaths: reused)
  }

  private func render(_ operations: [CompositionOperation], to destination: URL) throws {
    // Execute the full reference chain in M1. Future cached replays may elide
    // overwritten contributions only after preserving validation semantics.
    var bytes: Data?
    var base: URL?
    for operation in operations {
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
