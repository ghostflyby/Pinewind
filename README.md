# 松风 / Pinewind

Pinewind 是 Rime 包管理与配置组合的 Swift 库,提供 `PinewindCore` product。它将用户文件与远程包分开保存,按声明次序生成组合目录,供调用方交给输入法引擎部署。

支持 macOS 15 / iOS 16 及以上版本、Linux 和 Windows。需要 Swift 6.2 或更高版本;Windows 使用 Swift 6.3.1 或更高版本。

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

| 文件 | 目录 | 用途 |
|---|---|---|
| `pinewind.yaml` | `inputRoot` | 用户编写的清单:必填 `version: 1`,`names` 定义短名,`order` 决定应用次序 |
| `pinewind.local.yaml` | `localStateRoot` | 可选的本地短名覆写,用于改向本地文件树 |
| `pinewind.lock` | `inputRoot` | 通过库 API 读写的解析结果,内部格式不承诺 |

`inputRoot` 可以同步,`localStateRoot` 应位于同步目录之外。两个目录不得重叠,路径均由调用方提供;原先位于输入目录的本地覆写需要调用方移到本机状态目录,库不自动迁移或回读旧位置。

下例组合用户文件与本地包。`composeRoot` 同样由调用方提供:

```swift
import Foundation
import PinewindCore

let configuration = try await Configuration.load(
  inputRoot: inputRoot, localStateRoot: localStateRoot)
let manifest = try await configuration.evaluateEffective()
let expanded = try await PlumImporter().expand(manifest, inputRoot: inputRoot)
let plan = try CompositionPlanner().plan(expanded, inputRoot: inputRoot)
let result = try await Composer().compose(
  plan, inputRoot: inputRoot, outputRoot: composeRoot)
```

Windows 的 `composeRoot` 必须不存在、为空或已由 Pinewind 管理,所在文件系统需支持目录 junction。

没有清单时只组合用户文件。清单中的 `self` 与包条目按同一顺序执行:后面的文件覆盖前面的同名文件,每个包安装文件后立即应用自己的补丁。本地文件编辑在下一次规划时生效,不生成本地锁。

`Configuration` 是配置编辑入口,分别保留共享清单与可选本地覆写;求值后的 `Manifest` 供部署流程使用。修改后显式保存:

```swift
let configuration = try await Configuration.load(
  inputRoot: inputRoot, localStateRoot: localStateRoot)
await configuration.edit { manifest, _ in
  manifest.names["emoji"] = PackageFields(
    url: .value(URL(string: "https://github.com/rime/rime-emoji")!),
    ref: .value("master"))
  manifest.order.append(.named("emoji"))
}
try await configuration.saveShared()
```

`Configuration` 是 actor,同一实例串行执行编辑、求值和保存。`edit` 接收同步闭包,抛错时两份草稿一起回滚;`snapshot()` 返回独立的文档值供界面读取。

字段的 `.inherit`、`.clear`、`.value(...)` 分别表示省略、YAML null 和整体替换。`renamePackage` 同时更新短名引用与本地覆写,仍被引用的定义不能删除。`saveLocalOverrides()` 只保存本地文件,在 `edit` 中将本地覆写设为 nil 后调用会删除该文件。保存不更新锁或触发部署;共享锁使用 `evaluateShared()` 的结果,本机部署使用 `evaluateEffective()`。

配置文件访问由库内协调:Apple 平台使用 `NSFileCoordinator`,Linux、Windows 使用本机状态目录内的 `configuration.lock`。同一输入目录的本机调用者应共用同一 `localStateRoot`;协调锁文件保留在磁盘上,不应删除或同步。读取缺省配置不创建 YAML 文件,但可能创建本机协调状态。

保存配置内容前会校验配置;删除本地覆写不要求共享草稿能够部署。保存或删除都会在协调范围内检查文件自加载后是否被外部修改,检测到冲突时需重新加载。单文件写入使用原子替换,两个配置文件分别保存;协调不表示跨设备同步已经完成。YAML 保存保持语义,不保留注释、引号样式或空行。

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
