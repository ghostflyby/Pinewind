# 松风 / Pinewind

`PinewindCore` 是独立 Swift Package Pinewind 提供的 Rime 包管理与配置组合库,当前支持 macOS 15 / iOS 16,不依赖 RimeKit 或 librime。用户声明写在 `pinewind.yaml` 中,顶层 `version: 1` 必填,`names` 定义短名,`order` 决定文件覆盖与补丁应用次序。可选 `pinewind.local.yaml` 将短名改向本机文件树;本地编辑不生成 local lock 或目录树哈希。`pinewind.lock` 由库管理,内部格式不承诺。

## 使用

当前尚未发布版本标签,在消费方的 `Package.swift` 中按 main 分支引用:

```swift
.package(url: "https://github.com/ghostflyby/Pinewind.git", branch: "main")
```

本地开发也可引用同级目录:

```swift
.package(path: "../Pinewind")
```

消费 library product:

```swift
.product(name: "PinewindCore", package: "Pinewind")
```

应用分别消费 Pinewind 与 RimeKit:Pinewind 生成组合目录,应用将目录交给引擎部署。两个库不互相依赖。

当前实现支持内置包清单、本地 plum conf 沙盒求值、本地包、HTTPS Git 取包、recipe/glob/补丁组合、锁读写及原子发布。未变化的组合直接复用已有输出。自动 resolve/update 编排、资源准备视图、目标 sync 与 CLI/App 接入尚未完成。

```swift
import PinewindCore

let manifest = try Manifest.load(inputRoot: inputRoot)
let expanded = try await PlumImporter().expand(manifest, inputRoot: inputRoot)
let plan = try CompositionPlanner().plan(expanded, inputRoot: inputRoot)
let result = try await Composer().compose(
  plan, inputRoot: inputRoot, outputRoot: composeRoot)
```

上例适用于本地包;远端包通过 planner 的 `packages` 参数传入 `PreparedPackage`。计划持有磁盘快照引用,普通文件逐个拷贝并按块比较,不驻留全量词典字节。可通过 `CompositionPlanner(snapshotRoot:)` 指定快照临时根,计划释放后清理。详细契约与当前实现边界见 [包管理设计](Docs/Package-Management-Design.md)。

HTTPS Git 取包无需外部 git/ssh 命令,支持缓存复用,导出的源码只包含锁定 commit 的原始文件字节:

```swift
let fetcher = GitKitPackageFetcher()
let request = try PackageRequest(url: URL(string: "https://github.com/rime/rime-prelude")!)
let branch = try await fetcher.resolveDefaultBranch(url: request.url)
let commit = try await fetcher.resolveCommit(url: request.url, ref: branch)
let source = try await fetcher.prepareSource(url: request.url, commit: commit, cacheRoot: cacheRoot)
let prepared = try PreparedPackage(request: request, directory: source.directory, commit: commit)
```

有锁时直接使用已锁定的 commit,无需重新解析浮动 ref。凭证可经 `GitKitPackageFetcher(credentials:)` 的同步回调注入;默认支持公共 HTTPS 仓库。recipe 的独立资源通过 `downloadFile(url:)` 下载,仍须按锁中 SHA-256 校验并在条目准备视图中覆盖,不能直接写入共享源码快照。

## 平台支持

支持 macOS 15 / iOS 16 及以上版本。Linux / Windows 尚未支持。

开发、测试与仓库维护约定见 [贡献指南](CONTRIBUTING.md)。

## 许可证

[Mozilla Public License 2.0](LICENSE)。
