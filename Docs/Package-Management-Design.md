# 松风 / Pinewind:工作区与存储契约

状态:2026-10-18 包管理 API。提供 `PinewindCore` 与消费其公开 API 的 `pinewind` CLI。尚未发布,不保留旧 API、旧清单结构或旧内部锁编码兼容层。用户清单仍声明整数 `version: 1`。错误面的设计见《Error-System-Design》,为错误类型、定位与归因的唯一权威。

## 1. 域与位置

库区分用户文件树、外部配置文档、持久本机状态、可抛弃缓存和派生组合结果。一切根路径由调用方提供,显式 Workspace 不选择用户目录,PlatformDirectories 提供可选的平台发现便利入口;公开入口省略相对基准时捕获当前目录并固定。

`WorkspaceLocations` 包含:

| 属性 | 类型 | 职责 |
|---|---|---|
| userFilesRoot | FileLocation | `self` 条目取材 |
| configuration.manifest | FileLocation | 共享声明 |
| configuration.localOverrides | FileLocation? | 可选本地覆写;nil 禁用 |
| configuration.lock | FileLocation | 可同步的解析结果 |
| stateRoot | FilePath | 本机操作协调状态 |
| cacheRoot | FilePath | 源码、资源、准备视图和快照 |
| relativeTo | FilePath | 已固定的绝对路径基准,初始化时可省略 |

文件可以各处于不同目录或卷,文件名也可不同。配置元数据按实际位置从用户树排除,不按固定文件名排除其他用户文件。`.git`、`.DS_Store` 和 `*.local.*` 的既有用户树约定继续有效。

用户树不得与 state/cache 重叠,state/cache 不得互相包含,配置文档不得位于 state/cache 内。输出不得覆盖输入、使用的包来源、快照、配置文档、state/cache 或其子目录。路径别名应按文件系统解析检查,不能用纯字符串前缀或 FilePath 相等代替文件身份。

## 2. 路径边界

使用 `SystemPackage.FilePath`,直接依赖 Swift System `1.8.x`,最低 `1.8.1`。

以下位置在公开和内部执行边界均为 FilePath:Git 裸仓库和导出目录、整个缓存、状态和互斥锁、快照和捕获文件、下载目标、组合候选和输出、原子替换与目录交换。`SourceSnapshot.directory` 与 `CompositionResult.directory` 也为 FilePath,不提供 URL 重载。

远程 Git 仓库地址和 HTTPS 资源保持 URL。`FileLocation.path(FilePath)` / `.fileURL(URL)` 仅表达外部文档、用户树或只读本地包。原始 file URL 为文件协调保留,须指向绝对位置;`file:relative` 这类不完整 URL 在公开入口拒绝。协调访问范围内将实际 URL 转成 FilePath 后执行内部 I/O。桥接必须可验证,不通过有损字符串重建。

绝对路径转换只发生在公开执行入口及公开请求/阶段值的初始化入口。工作区通过 `relativeTo` 指定基准;省略时在初始化入口捕获当前工作目录。基准自身也可相对当前目录解析。工作区建立后保存固定的绝对基准和位置,后续执行不读取当前目录。独立取包、下载、SourceSnapshot 和本地 PackageRequest 同样在进入异步工作前或初始化时完成相对位置转换;后两者可显式指定基准。内部函数使用这些结果,不再重复检查绝对性。Windows 的盘符相对和当前盘根相对形式拒绝。`~` 和环境变量不作 shell 展开。

`RelativePath` 是 `FilePath` 的只读轻量包装。初始化委托 FilePath 归一化分隔符并消解 `.`、可消解的 `..`;拒绝根路径、空结果、剩余的父目录组件以及无法便携编码的组件。`filePath` 暴露原生路径;`string` 从组件生成统一 `/` 表示,用于锁和检查结果。唯一初始化入口接收 FilePath,按宿主语法解析原生分隔符;不提供 String 重载。YAML、锁及 conf 选择器在各自的文本边界先拒绝 NUL 和反斜杠,再构造原生路径,防止 FilePath 的字符串构造提前丢弃或改写无效输入。冒号和组件内的反斜杠仍被拒绝,避免跨平台解释歧义。recipe 下载和补丁目标在求值后转换一次,后续阶段直接使用包装值,并按规范化身份检查重复目标。文件枚举直接从原生组件构造 RelativePath,规划、发布和变更列表持续保留该类型,不在中间阶段退回字符串再校验。Git 后端额外校验原始树条目是未经改写的单个 UTF-8 文件名。显式 recipe 名称及其文件路径在 PackageRequest 构造时一起归一化,后续加载和 Rx 比较使用同一结果。glob 与 recipe 原始表达式继续是 String。词法归一化不替代符号链接、junction 和目录重叠检查。

FileFilter.accepts 和 Glob.matches 的候选路径只接收 RelativePath,glob 表达式仍为 String。conf 捕获接口同样接收 RelativePath,SwiftBash 的 POSIX 文本路径只在其 FileSystem 适配器中转换。canonical/overlap 检查以文件系统解析后的 FilePath 及组件前缀工作,不在内部传递路径字符串。Windows 原生路径也直接通过 withPlatformString 交给 WinSDK,只有 junction 编码及大小写折叠保留必要的文本转换。

词法归一化不是符号链接解析。普通来源文件树不接受符号链接,安全路径检查防止越出来源根。Windows 使用实际目录句柄解析 junction/短名/大小写别名,输出受管 junction 按发布规则单独处理。

## 3. 声明与求值

YAML 字段只解码一次;可变 PackageFields 自己提供部分字段校验,解析、编辑求值和文档编码共用这些约束。编码直接检查草稿结构后生成节点,不再通过生成 YAML 并重新解析来验证。缺少来源的命名定义仍可作为草稿编码;完整来源要求由请求构造和执行求值检查。Git commit 从解析到准备结果持续使用 CommitID,底层值的校验不依赖 SourceIdentity。

共享清单由 `names` 和 `order` 组成。names 本身不安装包。order 保留所有出现位置和重复项,不会按 URL 去重。

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
  - import: ./lists/packages.conf
  - self
```

`revision` 省略或 `default` 表示默认分支;映射必须恰含 branch/tag/ref/commit 之一。commit 为完整 40 位十六进制 ID;ref 支持完整 refs 名称或不明确的分支/tag 名称,歧义时报错。明确 commit 不随更新前进。原独立 ref/commit 字段不再接受。

条目选择器仍为 self、name、url、import。无清单默认 `[self]`,存在清单时不隐式增加 self,空 order 合法。self 可重复出现。

本地覆写是独立 `version: 1` 的 names 映射。合并为共享 names → 本地 names → 条目字段。`FieldOverride` 的 inherit/reset/value 分别对应省略/null/整体替换,options 不深度合并。最终包必须有来源;本地 file URL 不接受显式版本,改向本地时清除该层未显式指定的继承 revision。

`ManifestDocument`、`LocalOverridesDocument` 保留不完整草稿,求值直接合并类型化字段。解析保留语法错误位置;编辑后的求值诊断提供字段和条目,不伪造生成 YAML 的行号。保存保持语义,不保留注释与布局。

## 4. 配置编辑与批量应用

Workspace 是唯一的公开编辑入口。configuration(editing:) 返回绑定工作区与文件基线的不可变候选,不会替换默认保存状态。update { configuration in ... } 通过同一个 ConfigurationEditor 执行单次或批量修改,校验、解析、提交后默认准备依赖;apply(snapshot) 应用已经预览过的同一候选。编辑闭包同步、非抛出,不能 await;不会为重试而重放。

ConfigurationEditor 的添加、删除、重命名、改向和移动方法均不抛配置错误。每次操作在临时值上执行,失败保留原值并记录诊断,因此重复添加不会通过字典覆盖丢失证据。允许通过 PackageFields 提交不完整字段;来源简写和相对位置在 Core 中解析。添加默认位于首个 self 前;删除维护全部命名引用和本地覆写;重命名维护两层对应名称。相对改向始终使用工作区基准。

validate(editing:) 与 candidate.validate() 返回 ConfigurationDiagnostic 集合,默认同时检查共享与有效配置,与实际应用一致。诊断包含原始错误及可选操作序号、包名、字段;后者只定位内存编辑,不进入文档文本定位。独立字段错误汇总,无法判断的派生错误跳过。预览不提交;存在错误时 update/apply 在联网前整体抛 ConfigurationValidationError。文件读取失败和取消仍抛出,不伪装为配置诊断。

无公开 Session、独立草稿构造、逐层保存回执或重载协议。GUI 保存表单状态或候选快照;需要最新状态时重新读取 Workspace。旧的文档协调会话仅为内部实现,不是外部契约。

Apple 文件访问经 NSFileCoordinator,使用其返回的实际 URL。其他平台通过 stateRoot 内稳定的本机配置锁协调;同一配置集合共用 stateRoot。每次协调同时访问机器本地事务日志。App 负责云文件下载和权限。日志缺失时不会产生配置内容写入;若存在此前持久化的提交,读取前先恢复。

应用前预检所有文档与 lock 基线。提交使用包含 before/after 字节和文档身份的持久化重做日志:先同步日志,再逐文件原子替换并同步,最后删除并同步日志。日志持久化即提交点,此后不响应取消。崩溃后 Core 读者在相同协调范围内先完成恢复,只看到完整结果;当前字节不属于 before/after 的任何一者则拒绝恢复,不覆盖外部修改。损坏或不属于本配置集合的日志硬失败并提供恢复提示。

该事务协议保证协作 Core 调用者的整批可见性与恢复,不承诺其他程序直接读取或跨设备同步时的跨文件原子性。持久化期间 I/O 错误可能留下待恢复提交;重新访问可完成。解析失败不写配置;提交后的准备失败保留声明与 lock,以 PreparationFailure 携带已提交 Resolution 和原始错误。取消保持 CancellationError,可通过 configuration/status 查询已提交状态。

## 5. 阶段与副作用

| 入口 | 行为 |
|---|---|
| resolve | 保留匹配版本,补全变化声明,成功后提交共享锁 |
| update / apply | 编辑校验与解析成功后事务提交配置和 lock,默认准备依赖 |
| validate | 收集配置诊断,不联网、不提交本次编辑 |
| status | 查询配置、解析结果及输入准备状态,不联网 |
| install | resolve 后准备,locked 模式只接受保存锁 |
| refresh | 刷新版本与资源后准备,不构建 |
| build | 离线规划,保护 Rime 运行数据,按文件发布 |
| resolve(refreshing:) | 更新指定范围,成功后提交共享锁 |
| resolve(refreshingPackagesNamed:) | 从当前声明选择活跃远程命名依赖,刷新对应仓库,不要求预先 resolve |
| resolve(preview:) / resolve(refreshing:preview:) | 使用显式配置快照,不提交文档或锁 |
| fetch | 按确定版本取回源码和资源,不改锁 |
| cachedInputs | 只接受完整缓存和本地树,不联网 |
| plan | 固定本次目录成员、文件和 recipe 快照 |
| compose(plan,to:publication:) | 离线执行计划,选择整目录或受管文件发布 |
| compose(to:) | cachedInputs → plan → compose |
| fetchAndCompose | fetch → plan → compose,不自动解析或更新版本 |

Resolution、PreparedInputs、CompositionPlan 由库创建,外部不能任意构造或通用解码。阶段产物绑定工作区和配置快照,拒绝跨工作区使用。

源码请求按规范化仓库身份和 revision 在一次事务中复用,同一请求不能对应冲突 commit。不同 recipe/options 的应用位置独立保留。非 GitHub 请求地址保留 .git 后缀,缓存身份可消除后缀;GitHub 地址统一规范化并由后端补 .git 获取。

resolve/refresh 在全部解析、下载和校验完成后,再次协调检查共享配置、本地配置及旧锁的基线,然后原子提交新锁。中途失败或取消不改变旧锁。RefreshSelection 支持包、import 和资源标识;不属于当前解析的标识报错。

update/apply 的事务与失败边界见 §4。preparation: .deferred 仅提交和解析,适合移除依赖;默认 required 准备输入。返回 ConfigurationApplication,包含 Resolution 和可选 PreparedInputs。

ImportID.index 是生成标识时的位置,用于校验旧锁中的标识。执行选择更新按 request 匹配当前清单,同一 request 的所有出现位置一起刷新;声明移动不影响匹配,声明已删除或 request 改变则拒绝选择。过期 expansion 标识仍被拒绝。

锁只承诺语义和库读写入口,不承诺内部编码。私有 DTO 解码后完整验证来源、版本、路径、校验、重复项、展开关系与冲突。锁不记录缓存路径、本机覆写或本地树内容;本地声明仅保留不含绝对路径的拓扑和元数据。旧编码报告不兼容,显式 resolve 可重建。

## 6. 资源、导入与开发覆写

`RepositoryProvider.resolve` 一次返回确定 SourceIdentity,默认后端将默认分支识别与 commit 选择放在同次 refs 广播。prepareSource 接收 FilePath 缓存根,返回完整不可变源码快照。HTTPS Git 使用进程内 GitKit/libgit2,不使用外部 git/ssh 或 GitHub REST API。没有自动子模块和 LFS 内容获取,commit 不可用时失败,不替换成分支最新版本。

`ResourceDownloader.download` 写入 FilePath 候选文件;调用方携带的单文件字节上限在传输中生效,超限即中断并清理候选,存储层在内容进入缓存前复核同一上限。资源缓存按实际字节的 SHA-256 固定,不归一化换行或编码,不 hash 源码目录树。resolve 保留仍匹配的资源版本,update 可单独更新资源。fetch 校验不符即失败,不自动接受新内容或改锁。

WorkspaceOptions.maximumResourceBytes 默认 64 MiB,是 recipe 下载、开发模式下载及缓存恢复共用的宿主上限。conf 初次导入和缓存恢复同时受 imports.maximumFileBytes 限制(默认 1 MiB),取更小值。已缓存内容也检查相同上限,降低策略后不能绕过限制。recipe 不能放宽宿主上限。默认 HTTPS 下载器在各平台逐块检查后写入,超限立即取消任务,取消与本地文件错误保持原有错误领域。

库识别 recipe、解析下载需求并构建条目资源视图。下载覆盖该条目视图中的源码,不会修改共享源码缓存。本地树在规划时重新读取,有下载资源时先建立本次视图再捕获文件。准备后本地 recipe 改变导致资源不匹配时拒绝规划,需要重新准备。

默认 locked 模式允许共享锁定版本和本地目录改向。变更远程选择或新增未固定资源要求显式 development 准备。开发结果只留在本次阶段产物或可丢弃缓存,不写共享锁或新增本地锁。开发模式不承诺仅凭共享声明和锁复现本机结果。

conf 使用 SwiftBash 解释器,每个 import 独立环境,不继承宿主变量,root_dir 保留。支持数组初始化/重置/追加、变量展开、控制流和重复 source;不注册外部命令目录或网络命令。preset/extra/all 使用内建有序列表。

本地 conf 相对于声明清单目录定位,include 受根 conf 所在资源目录限制。读取的本地 conf 在协调范围内捕获一次后供解释器读取,不复制整个清单父目录。远程资源通过只读虚拟挂载按需准备,相对 include 映射到根 conf 所在 HTTPS 目录,越界和远程目录枚举报错。重复 source 保留执行语义,下载内容在事务中固定。锁记录远程 import 资源校验与展开结果,普通组合不重新求值。

默认限制为每 import 5 秒、64 次 source、每文件 1 MiB、累计 4 MiB,可通过 WorkspaceOptions.imports 修改。限制、超时和取消传播到解释器和下载准备。

## 7. 组合与发布

按声明次序处理每个条目。用户树按任意相对结构复制;包优先选择显式 recipe、默认 recipe.yaml,最后使用白名单。每个包先安装文件,随即应用自身补丁,后面的整文件写入可以覆盖之前的文件及补丁。

默认白名单:顶层 yaml(排除 custom/recipe)、txt、gram,以及 opencc 一层 json/ocd/ocd2/txt。include 仅缩小候选范围,exclude 随后排除;同一过滤器也应用于补丁目标。

glob 以根相对路径求值,*、? 和字符类不跨 `/`,** 可跨目录,中间 **/ 可匹配零层。区分大小写,可以匹配点文件,不支持 extglob、brace expansion 和反斜杠转义。结果排序不依赖目录枚举或 locale。recipe 的 ../包名/模式仅通过已准备来源的兼容身份寻址,缺失或多版本歧义时报错。

补丁模板仅进行字面选项替换,不执行 shell 代码。缺失且无缺省的选项报错,显式空值和 `:-default` 按既有规则处理。相同 Rx 标签在单次组合中替换旧块;目标不存在时创建。__patch 目前要求块式序列,补丁重序列化不保留上游排版。

计划保留完整有序贡献链,捕获到独立磁盘快照,不通过硬链接引用可变源文件,不驻留全量字节。规划后编辑影响下次规划;规划本身不是整个工作树的原子快照。阶段所有者负责快照生命周期,公开贡献检查只显示原始来源。

每次从净态候选执行全量语义。普通文件拷贝和比较按文件/块处理,补丁可能占用单个目标文件的字节与 YAML 内存。结果相同时不重新发布,报告变化、退出和复用路径。本轮不实现持久化依赖缓存或最小重算。

发布锁位于不会随输出交换而移动的稳定位置,候选位于输出文件系统。Darwin/Linux 使用原子目录交换;Windows 使用受管 junction 和独立代次。Windows 输出必须不存在、为空或已经受管。文件系统不支持所需操作时失败,绝不先删除旧输出再复制。

以上为默认 directory 模式。managedFiles() 用于含有运行状态的 Rime 用户目录:先渲染完整候选,只检查、更新计划涉及的文件与历史受管文件,不枚举或交换整个输出目录。单个文件通过同目录临时文件与原子替换提交。旧受管路径只有当前哈希匹配历史记录时才删除,否则保留并报告 preservedPaths。未受管同名文件若内容不同,在修改任何输出前一次性报告全部冲突;只有 managedFiles(overwriteUnmanaged: true) / CLI build --force 才可覆盖,并通过 overwrittenUnmanagedPaths 报告。与生成内容相同的文件可复用并纳入管理。

所有权与未完成的发布意图按规范化输出位置保存在 stateRoot/publications。意图先写入临时文件并同步,再原子替换;POSIX 同步父目录,Windows 使用 FlushFileBuffers 与写穿透替换。输出更新及已提交记录使用同样的同步顺序。意图持久化完成前不修改输出。中途失败或取消后,下一次构建利用旧/新哈希恢复。损坏 pending 只丢弃无法证明的所有权,通过 PublicationWarning 报告;无所有权证据的输出仍受冲突保护。读取 pending 的 I/O 错误不被当作可忽略的损坏。已提交 record 损坏则硬失败,错误提供恢复备份或移走记录以重置所有权的指引。此模式不承诺多文件整体原子性,也不修改不相关的词库及运行状态。Core 的 build 入口拒绝把已知 Rime 运行数据路径作为生成目标,即使指定 --force 也不能绕过。

Windows 两种模式按保留末级入口的 publicationPath 获取同一发布锁,managedFiles 在锁内拒绝末级 junction,不允许通过代次入口修改被 directory 模式替换的文件。用户配置在 junction 后方时应直接选择其实际普通目录。CI 校验 GetLongPathNameW 不展开末级受管 junction 的入口断言。

已保存配置的计划发布前重新检查配置和锁基线,拒绝过期输入;显式预览按固定快照执行。结果目录表示当前发布位置,不是永久代次快照。

## 8. 并发、取消与诊断

缓存按来源和资源身份协调,输出按实际目标位置协调,覆盖多个实例和进程。不能依赖调用方持有同一个 actor。互斥锁文件不删除,等待可取消。阻塞系统操作使用专门执行队列,不占用主线程或合作式 executor。

受管文件的打开、读、定位、元数据检查和关闭优先使用 Swift System 的 `FileDescriptor`。锁文件只打开一次,在同一描述符上非阻塞尝试排他锁,关闭时释放;等待和取消逻辑跨平台共用。POSIX 仅为现有描述符补充 `flock`;Windows 保留禁止删除共享的打开策略,将原生句柄转交描述符管理,并通过 `LockFileEx` 锁定约定的首字节。两者提供协作式进程互斥,不承诺完全相同的内核锁语义。内部内容读取使用原始字节,不进行文本转换。

取消检查覆盖等待、下载、文件枚举、哈希和渲染,提交前执行最后检查。提交已经完成则返回成功,不在成功提交后再报告取消。普通 resolve/refresh 与 directory 发布失败或取消保留旧锁和完整已发布输出;update/apply 的跨文件提交与 managedFiles 的恢复边界如前所述。候选和临时视图清理。

PinewindError 按 configuration/incident/runtime 区分归因,原因由具体错误或协议存在值保留,说明由 description 推导。文档上下文含路径、URL、可选行列及推导链,不含字段路径;归一化与载荷约定以《Error-System-Design》为准。CancellationError 单独保留。每次操作可独立接收进度回调,界面线程切换由调用方处理。

## 9. 验证边界

测试包含公开消费方 target、独立文档位置、草稿与保存基线、离线后端计数、资源版本和校验、conf include、开发覆写、取消与原子发布、真实进程间锁、跨平台路径和既有补丁/大文件回归。默认测试不联网,真实 GitHub 测试通过 PINEWIND_NETWORK_TESTS 显式启用。

CLI 默认使用平台配置、状态和缓存目录,输出到所选 Rime 实现的用户配置目录,不引入当前目录项目根。add/install/update 准备依赖,remove 更新声明及 lock,build 离线发布,paths 只读显示位置。CLI 不包含跨设备 sync 或 Rime 引擎部署。

## 10. 公开边界

CLI 和 GUI 共用 Workspace 的 update/validate/configuration/apply/install/refresh/status/build。分阶段 resolve/fetch/cachedInputs/plan/compose 保持公开,供预览与高级操作使用。ConfigurationEditor 无公开构造器;ConfigurationSnapshot 为只读候选。ConfigurationSession、ConfigurationDraft、ConfigurationLayer、SaveReceipt、具体 Git/HTTP 后端、Glob 与归因辅助方法内部化。PinnedResource 只读公开,构造器内部化;ManifestDocument 上重复的变更方法内部化。自定义 RepositoryProvider / ResourceDownloader 协议及其必要类型继续公开;默认后端配置通过 WorkspaceServices.live(credentials:session:) 提供。
