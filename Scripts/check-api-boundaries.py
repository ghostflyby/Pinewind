#!/usr/bin/env python3
"""Type-check external consumers against the built module, including rejected URL inputs."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
bin_path = Path(subprocess.check_output(
    ["swift", "build", "--show-bin-path"], cwd=root, text=True).strip())
args = ["swiftc", "-typecheck", "-I", str(bin_path), "-I", str(bin_path / "Modules")]
for directory in [
    "swift-system/Sources/CSystem/include", "Yams/Sources/CYaml/include",
    "swift-subprocess/Sources/_SubprocessCShims/include", "GitKit/Sources/CGitKit/include",
]:
    args += ["-I", str(root / ".build/checkouts" / directory)]
for name in ["CPinewindPlatform", "Clibgit2", "Clibgit2Patches", "FNMDefinitions"]:
    candidates = [
        root / ".build/out/Intermediates.noindex/GeneratedModuleMaps" / (name + ".modulemap"),
        bin_path / (name + ".build") / "module.modulemap",
    ]
    for candidate in candidates:
        if candidate.exists():
            args += ["-Xcc", "-fmodule-map-file=" + str(candidate)]
            break

prefix = """import Foundation
import PinewindCore
import SystemPackage
func boundary(_ workspace: Workspace, _ provider: any RepositoryProvider,
 _ identity: SourceIdentity, _ downloader: any ResourceDownloader,
 _ endpoint: URL, _ path: FilePath, _ files: ConfigurationFiles) async throws {
"""
cases = {
    "accepted native boundaries": (True, """
      _ = try await workspace.compose(to: path)
      _ = try await provider.prepareSource(identity, cacheRoot: path)
      try await downloader.download(endpoint, to: path)
      _ = try WorkspaceLocations(userFilesRoot: .fileURL(endpoint), configuration: files,
        stateRoot: path, cacheRoot: path)
    """),
    "URL publication target": (False, "_ = try await workspace.compose(to: endpoint)"),
    "URL repository cache": (False, "_ = try await provider.prepareSource(identity, cacheRoot: endpoint)"),
    "URL download destination": (False, "try await downloader.download(endpoint, to: endpoint)"),
    "URL managed state": (False, """
      _ = try WorkspaceLocations(userFilesRoot: .fileURL(endpoint), configuration: files,
        stateRoot: endpoint, cacheRoot: path)
    """),
    "URL managed cache": (False, """
      _ = try WorkspaceLocations(userFilesRoot: .fileURL(endpoint), configuration: files,
        stateRoot: path, cacheRoot: endpoint)
    """),
    "URL source snapshot": (False, "_ = try SourceSnapshot(identity: identity, directory: endpoint)"),
    "arbitrary resolution": (False, "_ = Resolution()"),
    "arbitrary prepared inputs": (False, "_ = PreparedInputs()"),
    "arbitrary plan": (False, "_ = CompositionPlan()"),
    "domain decoding": (False, "_ = try JSONDecoder().decode(PackageRequest.self, from: Data())"),
}
for label, (expected_success, body) in cases.items():
    result = subprocess.run(args + ["-"], input=prefix + body + "\n}",
                            cwd=root, text=True, capture_output=True)
    if (result.returncode == 0) != expected_success:
        sys.exit(label + " failed its compile contract:\n" + result.stderr)
    # A dependency lookup failure must never count as a successful negative test.
    if not expected_success and ("missing required module" in result.stderr or
                                 "no such module" in result.stderr):
        sys.exit(result.stderr)
    print("PASS:", label)
