# 松风 / Pinewind

Pinewind 是 Rime 包管理与配置组合的 Swift 库,提供 `PinewindCore` product。用户文件、共享声明、本地覆写、解析锁与受管缓存分别定位,按声明次序生成组合目录,供调用方交给输入法引擎部署。

支持 macOS 15 / iOS 16 及以上版本、Linux 和 Windows。需要 Swift 6.2 或更高版本;Windows 使用 Swift 6.3.1 或更高版本。

## 接入

在消费方 `Package.swift` 中添加依赖和 product:

```swift
.package(url: "https://github.com/ghostflyby/Pinewind.git", branch: "main")
.product(name: "PinewindCore", package: "Pinewind")
```

直接使用 `FilePath` 的消费 target 还应声明 Swift System 的 `SystemPackage` product;Pinewind 使用 Swift System `1.8.x`,最低 `1.8.1`。

## 工作区

以下位置均由调用方提供。文件 URL 可以来自文件选择器或 iCloud;App 负责下载、书签和授权,并在整个异步操作期间保持访问有效。

```swift
import Foundation
import PinewindCore
import SystemPackage

let locations = try WorkspaceLocations(
  userFilesRoot: .fileURL(userFilesURL),
  configuration: ConfigurationFiles(
    manifest: .fileURL(manifestURL),
    localOverrides: .fileURL(localOverridesURL),
    lock: .fileURL(lockURL)),
  stateRoot: statePath,
  cacheRoot: cachePath)
let workspace = try await Workspace.open(locations: locations)
```

`manifest`、`localOverrides`、`lock` 和用户文件树可以位于不同目录或卷,文件名也由调用方决定。`localOverrides: nil` 禁用本地覆写。用户文件树不得与状态或缓存重叠,状态与缓存也不得互相包含。配置文件不得放入受管状态或缓存。

`stateRoot`、`cacheRoot`、Git 本地仓库、源码快照和组合目标必须是 `SystemPackage.FilePath`,不接受 `URL`。相对位置需要显式 `relativeTo: FilePath`,工作区固定该基准,不读取进程当前目录。路径不展开 `~` 或环境变量。

首次使用远程条目或共享声明改变后,显式解析:

```swift
let resolution = try await workspace.resolve()
let prepared = try await workspace.fetch(resolution)
let plan = try await workspace.plan(prepared)
let result = try await workspace.compose(plan, to: outputPath)
```

`resolve` 保留仍匹配的版本,为变化声明补全解析;`update()` 重新选择浮动版本和资源。两者完整成功后才原子提交共享锁,检测到配置或旧锁改变时失败。

日常使用匹配锁和完整缓存离线组合:

```swift
let result = try await workspace.compose(to: outputPath)
```

需要补齐缓存时使用 `fetchAndCompose(to:)`;它仅下载锁定内容,不自动 resolve/update 或修改锁。也可用 `cachedInputs()`、`plan(_:)`、`compose(_:to:)` 分阶段执行。纯用户文件与本地包无需先生成锁。缺少清单时默认只包含用户文件,显式空 `order` 则产生空组合。

`CompositionResult.directory` 是 `FilePath`,表示当前发布目录,下一次发布可以替换其内容。`paths`、`changedPaths`、`removedPaths`、`reusedPaths` 是 `[RelativePath]`,使用 `.string` 读取统一 `/` 分隔的表示。`plan.contributions(for:)` 检查贡献顺序和原始来源,不暴露临时快照。

Windows 的输出目录必须不存在、为空或为 Pinewind 管理的 junction。所有平台均要求所在文件系统支持对应的原子发布与锁操作;不支持时明确失败,保留旧输出。

## 清单与本地覆写

```yaml
version: 1
names:
  emoji:
    url: https://github.com/rime/rime-emoji
    revision: {branch: master}
order:
  - name: emoji
    recipe: customize
    options: {schema: luna_pinyin}
  - self
```

`revision` 使用 `default`、`{branch: ...}`、`{tag: ...}`、`{ref: ...}` 或 `{commit: <完整40位ID>}`。省略时使用默认分支。项目尚未发布,新版结构仍为 `version: 1`,原独立 `ref/commit` 字段不再接受。

本地覆写仍是带 `version: 1` 的 `names` 映射。合并次序为共享 names → 本地 names → 条目内联字段。省略继承、null 清除、字段值整体替换;options 不逐键深度合并。`file://` 改向实时本地树时清除继承版本,不读取本地 Git HEAD,不计算目录内容锁。

后面的文件覆盖前面的同名文件;每个包安装文件后立即应用自己的补丁。`self` 没有特殊优先级。相对 conf import 以清单所在目录为基准,不是用户文件树。远程 conf 的相对 include 限制在根 conf 所在 HTTPS 资源目录内;普通组合使用固定的展开结果,不会重新求值清单。

## 配置编辑与预览

```swift
let session = try await workspace.configuration()
let request = try PackageRequest(
  source: .git(RepositoryRequest(
    url: URL(string: "https://github.com/rime/rime-emoji")!,
    revision: .branch("master"))))
try await session.edit { draft in
  try draft.addPackage("emoji", request: request)
}
let snapshot = await session.snapshot()
let diagnostics = snapshot.validate(scope: .effective)
let receipt = try await session.save(.shared)
```

`edit` 是同步闭包,抛错则整份草稿回滚。`snapshot` 返回独立值,包含共享和本地层各自的修订及 `isDirty`。`save(.shared)` / `save(.local)` 分别保存并返回实际持久化修订,保存等待期间的后续编辑仍保持未保存状态。将本地草稿设为 nil 后保存本地层会删除覆写文件。

`reload()` 拒绝丢弃未保存编辑;明确放弃使用 `discardChangesAndReload()`。保存保持 YAML 语义,不保留注释、引号和排版。两个文件分别保存,不构成跨文件同步事务。

工作区默认忽略未保存草稿。显式预览:

```swift
let snapshot = await session.snapshot()
let resolution = try await workspace.resolve(preview: snapshot)
let prepared = try await workspace.fetch(resolution)
let plan = try await workspace.plan(prepared)
let result = try await workspace.compose(plan, to: previewOutputPath)
```

预览不写共享配置或共享锁。正常发布前检查已保存配置及锁的基线,拒绝过期计划。本地树的文件内容在每次规划时捕获,规划完成后的编辑只影响下一次规划。

## 版本更新、开发模式与后端

解析结果提供包、import 和资源标识,可选择更新:

```swift
let updated = try await workspace.update(.packages(Set(resolution.packages.map(\.id))))
let resources = Set(updated.packages.flatMap(\.resourceIDs))
let refreshed = try await workspace.update(.resources(resources))
```

过期或不属于当前锁的标识会被拒绝。明确 commit 不随 update 前进。recipe 下载资源以 URL、相对路径和实际字节的 SHA-256 固定;缓存丢失后的下载若与固定校验值不同会失败,不会接受新内容或自动改锁。

默认 `.locked` 准备模式允许共享锁定版本和本地目录改向。覆写引入其他远程选择或尚未固定的资源时,显式使用 `fetch(mode: .development)` 或 `fetchAndCompose(to:mode: .development)`。开发结果只用于本次准备,不写共享锁或本地锁。

`WorkspaceServices` 可注入 `RepositoryProvider` 和 `ResourceDownloader`。默认实现为 `GitKitRepositoryProvider`、`HTTPSResourceDownloader`。认证通过 `GitKitRepositoryProvider(credentials:)` 注入。默认 Git 后端不使用外部 git/ssh 命令;下载、资源固定与条目视图由工作区完成。

各操作可传入独立的 `progress` 回调。错误通过 `PinewindError.code` 区分需要解析、缺失缓存、开发准备、冲突、过期输入、校验和不兼容格式;取消保留 `CancellationError`。提交前检查取消,提交后返回成功。进度回调的界面线程切换由调用方负责。

完整语义与文件系统边界见 [设计契约](Docs/Package-Management-Design.md);验证方式见 [贡献指南](CONTRIBUTING.md)。

## 许可证

[Mozilla Public License 2.0](LICENSE)。
