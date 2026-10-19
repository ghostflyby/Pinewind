# 松风 / Pinewind

Pinewind 是 Rime 包管理与配置组合工具,提供 `pinewind` 命令和 `PinewindCore` Swift 库。安装准备依赖,构建按声明次序生成配置,输出到对应 Rime 实现的用户配置目录。

支持 macOS 15 / iOS 16 及以上版本、Linux 和 Windows。需要 Swift 6.2 或更高版本;Windows 使用 Swift 6.3.1 或更高版本。

## 命令行

CLI 使用 swift-argument-parser,通过普通 `import PinewindCore` 消费公开 API。CLI 支持 macOS、Linux 和 Windows;库同时支持 iOS。

```sh
swift run pinewind --help
swift run pinewind paths
swift run pinewind add emoji
swift run pinewind add owner/repository --branch main --name example
swift run pinewind add ./local-package --name local
swift run pinewind install
swift run pinewind install --locked
swift run pinewind update emoji
swift run pinewind update
swift run pinewind remove emoji
swift run pinewind build --frontend squirrel
```

`add` 接受 HTTPS Git URL、`owner/repository`、Rime 包名(`emoji` 展开为 `rime/rime-emoji`)或本地目录。默认插入第一个 `self` 之前,没有 `self` 则追加;`--before NAME` / `--after NAME` 指定唯一位置。可以指定 `--branch`、`--tag`、`--ref` 或 `--commit`,以及 `--recipe`、重复的 `--option KEY=VALUE`、`--include`、`--exclude`。

`add` 先解析,成功后保存声明和 lock,再准备文件。解析失败保留原声明和 lock;后续准备失败返回非零状态,保留已保存的声明和 lock,用 `install` 重试。`remove` 删除命名依赖的全部 order 引用及对应本地覆写,更新 lock,保留共享缓存。`install` 保留匹配的锁定版本;`--locked` 要求现有 lock 匹配,不改锁。只有 `update` 主动刷新浮动版本;指定名称只更新选中的远程命名依赖。

`build` 完全离线,读取匹配 lock、缓存及实时本地来源。它先完成渲染,然后逐个更新生成文件,保留 Rime 目录本身、用户词库和其他运行文件。已不再生成的旧文件仅在内容仍匹配发布记录时删除;外部修改过的旧文件保留并报告。多文件发布中断后可重新 `build` 完成恢复。此命令生成配置,不触发 Rime 引擎重新部署。

**首次构建不会静默覆盖已有个人配置。** 已存在但不受 Pinewind 管理的同名文件若与生成内容不同,`build` 会列出全部冲突并在写入任何生成文件之前失败。先将个人配置备份并整理到 `paths` 显示的个人来源目录;确认覆盖清单后才使用 `build --force`。与生成内容完全相同的文件可直接复用并纳入管理。`--force` 仅授权覆盖这些配置冲突,不允许写入词库或运行状态路径;实际覆盖与保留清单输出到 stderr。

发布意图先同步落盘再修改输出。损坏的 pending 记录会被保守丢弃并发出警告,无法证明所有权的文件仍按未受管文件保护。已提交的发布记录损坏时停止构建:恢复可信备份,或将错误信息指出的记录移到别处重置所有权,再重新构建并审核冲突;这不会自动删除既有输出。

Windows 的按文件发布要求输出末级是普通目录,拒绝 junction;可用 `--output` 指定实际目录。它与整目录发布共用入口锁,避免混用两种模式时写入即将淘汰的代次。

CLI 不以当前目录作为项目根。默认位置如下:

| 平台 | 配置目录 | 机器状态目录 | 缓存目录 |
| --- | --- | --- | --- |
| macOS | `~/Library/Application Support/Pinewind` | 配置目录下 `State` | `~/Library/Caches/Pinewind` |
| Windows | `%APPDATA%\Pinewind` | `%LOCALAPPDATA%\Pinewind\State` | `%LOCALAPPDATA%\Pinewind\Cache` |
| Linux | `$XDG_CONFIG_HOME/pinewind` | `$XDG_STATE_HOME/pinewind` | `$XDG_CACHE_HOME/pinewind` |

Linux 的 XDG 基目录默认分别为 `~/.config`、`~/.local/state`、`~/.cache`,相对环境变量值被忽略。配置目录保存 `pinewind.yaml`、`pinewind.lock` 和个人来源 `user/`;机器状态目录保存 `pinewind.local.yaml`,其 `managed/` 子目录保存受管状态及发布记录。

输出默认选择已存在的 Rime 用户目录。macOS 支持 Squirrel(`~/Library/Rime`)和 fcitx5;Windows 支持 Weasel(优先读取其注册表配置,否则 `%APPDATA%\Rime`);Linux 支持 fcitx5(`$XDG_DATA_HOME/fcitx5/rime`)、fcitx(`$XDG_CONFIG_HOME/fcitx/rime`)和 ibus(`$XDG_CONFIG_HOME/ibus/rime`)。发现多个目录时要求 `--frontend` 或 `--output`;没有现存目录时 macOS/Windows 使用默认前端,Linux 要求显式选择。

`paths` 只显示位置,不创建目录。各命令支持 `--config-directory`、`--state-directory`、`--cache-directory`、`--user-files`;`build` / `paths` 支持 `--frontend` 与 `--output`。`--maximum-resource-bytes` 调整每个下载资源的上限,默认 64 MiB。显式相对路径以命令启动位置为基准。

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

`stateRoot`、`cacheRoot`、Git 本地仓库、源码快照和组合目标必须是 `SystemPackage.FilePath`,不接受 `URL`。公开入口将相对位置转换为绝对路径。工作区可指定 `relativeTo: FilePath`;省略时在初始化入口捕获当前工作目录并固定该基准,后续执行不再读取当前目录。独立调用取包、下载、`SourceSnapshot` 或本地 `PackageRequest` 时,相对位置同样在公开入口转换。路径不展开 `~` 或环境变量。

首次使用远程条目或共享声明改变后,显式解析:

```swift
let resolution = try await workspace.resolve()
let prepared = try await workspace.fetch(resolution)
let plan = try await workspace.plan(prepared)
let result = try await workspace.compose(plan, to: outputPath)
```

`resolve` 保留仍匹配的版本,为变化声明补全解析;`resolve(refreshing:)` 重新选择浮动版本和资源。两者完整成功后才原子提交共享锁,检测到配置或旧锁改变时失败。

日常使用匹配锁和完整缓存离线组合:

```swift
let result = try await workspace.compose(to: outputPath)
```

需要补齐缓存时使用 `fetchAndCompose(to:)`;它仅下载锁定内容,不自动解析或刷新版本,不修改锁。也可用 `cachedInputs()`、`plan(_:)`、`compose(_:to:)` 分阶段执行。纯用户文件与本地包无需先生成锁。缺少清单时默认只包含用户文件,显式空 `order` 则产生空组合。

`CompositionResult.directory` 是 `FilePath`,表示当前发布目录,下一次发布可以替换其内容。`paths`、`changedPaths`、`removedPaths`、`reusedPaths` 是 `[RelativePath]`,它们是经过初始化校验和词法归一化的 `FilePath` 包装:只接受 `FilePath` 初始化,通过 `.filePath` 访问原生路径,通过 `.string` 读取统一 `/` 分隔的表示。例如 `try RelativePath(FilePath("assets/./old/../table.txt"))` 得到 `assets/table.txt`。这些路径从文件枚举到发布一直保留类型,不会在阶段间转回字符串重复校验。`plan.contributions(for:)` 检查贡献顺序和原始来源,不暴露临时快照。

默认 `publication: .directory` 原子替换完整目录。该模式在 Windows 上要求输出目录不存在、为空或为 Pinewind 管理的 junction。向现存 Rime 用户目录发布时使用 `publication: .managedFiles()`,只修改生成路径,并通过 `preservedPaths` 报告保留的外部修改文件。未受管同名文件冲突报告为 `StateFailure.unmanagedOutputFiles`;明确授权时使用 `.managedFiles(overwriteUnmanaged: true)`,结果中的 `overwrittenUnmanagedPaths` 列出实际覆盖的路径,`warnings` 报告损坏 pending 的恢复。此模式逐文件原子更新,将发布意图和所有权记录保存在状态目录;中断后下一次构建恢复,不承诺多文件整体原子性。所有平台均要求所在文件系统支持对应的原子发布与锁操作。

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

## 包管理、编辑与预览

日常包管理直接操作 Workspace,单次与批量共用一个非抛出编辑闭包:

```swift
let application = try await workspace.update { configuration in
  configuration.addPackage(source: "emoji")
  configuration.addPackage("local", source: "./my-package")
  configuration.renamePackage("local", to: "personal")
}
let prepared = application.inputs
let installed = try await workspace.install()
let refreshed = try await workspace.refresh(packagesNamed: ["emoji"])
let built = try await workspace.build(to: rimeDirectory)
```

编辑器方法只修改临时候选,失败的修改不覆盖已有值并保留诊断。`addPackage` 可直接接受来源简写,或接受允许不完整的 `PackageFields`;无需先构造可能抛错的 PackageRequest。表单中的原始 commit 文本可通过 `commit: String` 添加重载提交,无效 commit 与其他字段问题一起收集。名称推导、来源简写和相对路径解析由 Core 负责,本地来源以工作区固定基准定位。此用户输入入口展开 `~`,底层路径类型不展开。

`validate(editing:)` 返回 `[ConfigurationDiagnostic]`,不联网、不提交本次变更。每条诊断包含原有 `PinewindError`、可选操作序号(从 0 开始)、包名和字段。字段用于表单定位,不伪造 YAML 行号。独立字段错误一次收集,前置错误导致无法判断的派生问题跳过。`update` 在联网解析前执行同一校验,有错误时整体抛出 `ConfigurationValidationError`。

GUI 可以持有不可变候选,检查、预览并应用同一快照,无需 Session:

```swift
let candidate = try await workspace.configuration { configuration in
  configuration.addPackage("unfinished", fields: PackageFields())
}
let diagnostics = candidate.validate()
// 修正后的候选通过同一个编辑入口重新生成。
let valid = try await workspace.configuration { $0.addPackage(source: "emoji") }
let preview = try await workspace.resolve(preview: valid)
let inputs = try await workspace.fetch(preview)
let plan = try await workspace.plan(inputs)
let previewResult = try await workspace.compose(plan, to: previewOutputPath)
let applied = try await workspace.apply(valid)
```

候选不改变工作区的已保存状态。`apply` 检查整个配置与 lock 的基线,不自动重放编辑闭包;发生外部修改则整批拒绝。校验或解析失败不提交。本次批量的声明、本地覆写和 lock 由持久化重做日志协调提交,Core 读者先恢复未完成事务再读取;日志持久化后即进入提交阶段,不再响应取消。I/O 故障可能返回错误并留下待恢复日志,下一次访问完成同一事务。它不保证其他程序或云同步逐个读取这些文件时的跨文件原子可见性。

错误处理采用开放的 `PinewindErrorProtocol` (`Error`、`Sendable`、`CustomStringConvertible`),按需接入外部错误,保留具体原因。`CodablePinewindError` 只是协议与 Codable 的组合;泛型 `DocumentError<E>`、`FileOperationFailure<E>`、`ResourceTransferFailure<E>` 按原因的能力分别支持编码/解码。未知错误不自动转成 Defect,取消仍是 `CancellationError`。归因容器保留 configuration / incident / runtime 的区分,不再通过 Failure 总枚举穷举领域。

默认应用后准备依赖。提交后的准备失败抛出 `PreparationFailure`,提供已提交的 `resolution` 和原始 `cause: any Error`;声明与 lock 保留,可用 `install(locked: true)` 重试。取消始终保持 `CancellationError`,取消后可重新查询状态。只提交并解析、不准备文件时使用 `preparation: .deferred`,例如移除包。

`workspace.status()` 只读返回配置、可用的解析结果和输入准备状态,不自动解析或下载;损坏或缺失的 lock/cache 通过类型化状态原因展示。配置读取会恢复此前已提交的事务。构建使用 `build(to:)`,在 Core 内统一执行离线构建和 Rime 运行时文件保护;底层 `compose` 仍提供通用发布能力。

`PlatformDirectories` 提供平台配置、状态和缓存位置,`workspaceLocations()` 直接生成 CLI/GUI 共用的默认文件布局,各目录可独立覆盖。`discoverRimeDirectories()` 返回已存在的前端与目录候选,GUI 可展示选择器;`output(frontend:)` 共用 CLI 的自动选择规则。显式 WorkspaceLocations 仍支持任意平台位置。

正常发布前检查配置与 lock 基线,拒绝过期计划。预览不提交配置或 lock,但可下载和缓存输入。本地文件内容在规划时捕获,规划完成后的编辑只影响下一次规划。

公开面只保留调用参数、只读产物、编辑和预览能力、后端协议与错误载荷。Session、内部草稿、保存回执、具体 Git/HTTP 后端、Glob 和归因辅助方法不再公开;PinnedResource 的构造器与文档上重复的修改方法也收回内部。

## 检查配置

```sh
pinewind lint
pinewind lint --format json
```

lint 始终检查共享 YAML 与本地覆写的结构和内部一致性,尽量收集具有真实原文位置的配置问题。本地路径及其 recipe 的文件检查以最终生效配置为准;被覆写的共享本地值不读取。生效本地来源不存在或不是目录时,诊断指向 URL 节点。共享远端依赖作为 lock 输入,其已有源码和资源也会检查。缺少 lock、远端源码或缓存不报错,不联网补全,也不执行 conf 或构建。

Core 的 `workspace.lint()` 返回 LintReport,CLI/GUI 共用检查规则。文本复用错误的 description;JSON 输出 version 和原结构的 diagnostics。有诊断或执行失败时退出非零;不可编码的诊断导致明确的输出失败,不会丢项或留下半份 JSON。运行态故障通过正常错误通道报告,不伪造 YAML 位置。

lint 不提交新配置或 lock,不创建个人源码目录;正常文件协调仍可能创建协作锁或恢复先前已提交的事务。完整边界见 [错误处理设计](Docs/Error-System-Design.md)。

## 版本更新、开发模式与后端

解析结果提供包、import 和资源标识,可选择更新:

```swift
let updated = try await workspace.resolve(refreshing: .packages(Set(resolution.packages.map(\.id))))
let resources = Set(updated.packages.flatMap(\.resourceIDs))
let refreshed = try await workspace.resolve(refreshing: .resources(resources))
let named = try await workspace.refresh(packagesNamed: ["emoji"])
```

过期或不属于当前锁的标识会被拒绝。明确 commit 不随 update 前进。recipe 下载资源以 URL、相对路径和实际字节的 SHA-256 固定;缓存丢失后的下载若与固定校验值不同会失败,不会接受新内容或自动改锁。

`ImportID.index` 表示生成该标识时的声明位置。选择更新 import 时先校验标识属于当前锁,再按 request 匹配当前清单中的所有相同声明;前方插入、删除或移动其他条目不会改变选中目标。已删除或改变 request 的声明会报错,不会静默跳过。

`WorkspaceOptions.maximumResourceBytes` 默认 64 MiB,限制每个资源的传输和缓存恢复,覆盖 recipe 的 `download_files`。远程 conf 还受 `imports.maximumFileBytes` 限制,取两者较小值,默认 1 MiB。上限必须为正数,超限中断下载并清理候选文件,不提交新锁或组合结果。自定义 `ResourceDownloader` 也必须在传输中执行收到的上限;存储层会在缓存前再次检查大小。

默认 `.locked` 准备模式允许共享锁定版本和本地目录改向。覆写引入其他远程选择或尚未固定的资源时,显式使用 `fetch(mode: .development)` 或 `fetchAndCompose(to:mode: .development)`。开发结果只用于本次准备,不写共享锁或本地锁。

`WorkspaceServices` 可注入 `RepositoryProvider` 和 `ResourceDownloader`。默认实现使用内部 GitKit 和 HTTPS 后端。认证和 HTTP session 通过 `WorkspaceServices.live(credentials:session:)` 配置。默认 Git 后端不使用外部 git/ssh 命令;下载、资源固定与条目视图由工作区完成。

通过服务工厂注入的 session 在有界和无上限下载中都将认证质询转发给注入 session 的 delegate,回调接收注入的 session 和实际传输的 task;未实现对应回调时使用默认认证处理。Corelibs 的有界下载使用相同配置的专用 session 承载传输。

各操作可传入独立的 `progress` 回调。错误通过 `PinewindError.configuration`、`.incident`、`.runtime` 区分文档裁决、处理事件和无文档锚点的失败,再匹配其 `Failure` 领域事实。文件操作携带路径与系统错误码,网络传输携带原因分类,校验失败携带预期与实际哈希;取消保留 `CancellationError`。提交阶段不响应取消;后续准备阶段仍可取消,已提交状态保留。进度回调的界面线程切换由调用方负责。

完整语义与文件系统边界见 [设计契约](Docs/Package-Management-Design.md);验证方式见 [贡献指南](CONTRIBUTING.md)。

## 许可证

[Mozilla Public License 2.0](LICENSE)。
