# 松风 / Pinewind

Pinewind 是 Rime 包管理与配置组合的 Swift 库,提供 `PinewindCore` product。它将用户文件与远程包分开保存,按声明次序生成组合目录,供调用方交给输入法引擎部署。

支持 macOS 15 / iOS 16 及以上版本,需要 Swift 6.2 或更高版本。Linux / Windows 尚未支持。

## 接入

在消费方的 `Package.swift` 中添加依赖:

```swift
.package(url: "https://github.com/ghostflyby/Pinewind.git", branch: "main")
```

在消费 target 中添加 product:

```swift
.product(name: "PinewindCore", package: "Pinewind")
```

## 配置与组合

| 文件 | 用途 |
|---|---|
| `pinewind.yaml` | 用户编写的清单:必填 `version: 1`,`names` 定义短名,`order` 决定应用次序 |
| `pinewind.local.yaml` | 可选的本地短名覆写,用于改向本地文件树;不随用户配置仓库同步 |
| `pinewind.lock` | 通过库 API 读写的解析结果,内部格式不承诺 |

下例组合用户文件与本地包。`inputRoot` 和 `composeRoot` 是调用方提供的文件 URL:

```swift
import Foundation
import PinewindCore

let manifest = try Manifest.load(inputRoot: inputRoot)
let expanded = try await PlumImporter().expand(manifest, inputRoot: inputRoot)
let plan = try CompositionPlanner().plan(expanded, inputRoot: inputRoot)
let result = try await Composer().compose(
  plan, inputRoot: inputRoot, outputRoot: composeRoot)
```

没有清单时只组合用户文件。清单中的 `self` 与包条目按同一顺序执行:后面的文件覆盖前面的同名文件,每个包安装文件后立即应用自己的补丁。本地文件编辑在下一次规划时生效,不生成本地锁。

## HTTPS Git 取包

远程包需要先准备源码,再通过 planner 的 `packages` 参数传入。取包无需外部 git/ssh 命令;已有锁定 commit 时直接准备该版本,无需重新解析引用。`cacheRoot` 是调用方提供的缓存目录:

```swift
let fetcher = GitKitPackageFetcher()
let request = try PackageRequest(url: URL(string: "https://github.com/rime/rime-prelude")!)
let branch = try await fetcher.resolveDefaultBranch(url: request.url)
let commit = try await fetcher.resolveCommit(url: request.url, ref: branch)
let source = try await fetcher.prepareSource(url: request.url, commit: commit, cacheRoot: cacheRoot)
let prepared = try PreparedPackage(request: request, directory: source.directory, commit: commit)
```

认证可通过 `GitKitPackageFetcher(credentials:)` 注入。recipe 的独立下载资源需要调用方下载、按锁中 SHA-256 校验,并放入条目专属准备视图,随后将对应 `PinnedResource` 传给 `PreparedPackage`;共享源码快照由库管理,不得修改。

当前库提供配置解析、本地 conf 导入、取包、锁读写与组合 API。自动 resolve/update 编排、远程 conf 获取、资源视图自动准备、目标同步和 CLI 尚未提供。

配置规则与组合语义见 [设计契约](Docs/Package-Management-Design.md);参与开发见 [贡献指南](CONTRIBUTING.md)。

## 许可证

[Mozilla Public License 2.0](LICENSE)。
