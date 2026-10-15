# 松风 / Pinewind:工作区与存储契约

状态:2026-10-15 新 API。提供 `PinewindCore`,面向 App、配置编辑器和未来 CLI。尚未发布,不保留旧 API、旧清单结构或旧内部锁编码兼容层。用户清单仍声明整数 `version: 1`。

## 1. 域与位置

库区分用户文件树、外部配置文档、持久本机状态、可抛弃缓存和派生组合结果。一切根路径由调用方提供,库不选择用户目录或隐式当前工作目录。

`WorkspaceLocations` 包含:

| 属性 | 类型 | 职责 |
|---|---|---|
| userFilesRoot | FileLocation | `self` 条目取材 |
| configuration.manifest | FileLocation | 共享声明 |
| configuration.localOverrides | FileLocation? | 可选本地覆写;nil 禁用 |
| configuration.lock | FileLocation | 可同步的解析结果 |
| stateRoot | FilePath | 本机操作协调状态 |
| cacheRoot | FilePath | 源码、资源、准备视图和快照 |
| relativeTo | FilePath? | 显式的绝对相对路径基准 |

文件可以各处于不同目录或卷,文件名也可不同。配置元数据按实际位置从用户树排除,不按固定文件名排除其他用户文件。`.git`、`.DS_Store` 和 `*.local.*` 的既有用户树约定继续有效。

用户树不得与 state/cache 重叠,state/cache 不得互相包含,配置文档不得位于 state/cache 内。输出不得覆盖输入、使用的包来源、快照或配置文档。路径别名应按文件系统解析检查,不能用纯字符串前缀或 FilePath 相等代替文件身份。

## 2. 路径边界

使用 `SystemPackage.FilePath`,直接依赖 Swift System `1.8.x`,最低 `1.8.1`。

以下位置在公开和内部执行边界均为 FilePath:Git 裸仓库和导出目录、整个缓存、状态和互斥锁、快照和捕获文件、下载目标、组合候选和输出、原子替换与目录交换。`SourceSnapshot.directory` 与 `CompositionResult.directory` 也为 FilePath,不提供 URL 重载。

远程 Git 仓库地址和 HTTPS 资源保持 URL。`FileLocation.path(FilePath)` / `.fileURL(URL)` 仅表达外部文档、用户树或只读本地包。原始 file URL 为文件协调保留;协调访问范围内将实际 URL 转成 FilePath 后执行内部 I/O。桥接必须可验证,不通过有损字符串重建。

相对路径只能相对于 `relativeTo`,没有基准时报错。工作区建立后固定基准,后续执行不读取当前目录。Windows 的盘符相对和当前盘根相对形式拒绝。`~` 和环境变量不作 shell 展开。受管路径进入执行边界时均为绝对路径。

`RelativePath` 是平台无关的资源和输出路径:统一 `/`,拒绝根、空组件、`.`、`..`、反斜杠、冒号和 NUL。其字符串用于锁和检查结果,执行时再拼入宿主 FilePath。glob 与 recipe 原始表达式继续是 String,不能未经求值验证就作为目标路径。

词法归一化不是符号链接解析。普通来源文件树不接受符号链接,安全路径检查防止越出来源根。Windows 使用实际目录句柄解析 junction/短名/大小写别名,输出受管 junction 按发布规则单独处理。

## 3. 声明与求值

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

## 4. 配置会话

`workspace.configuration()` 加载独立 `ConfigurationSession`,不会使工作区默认操作使用内存草稿。

- edit 接受同步闭包,抛错时整份 ConfigurationDraft 回滚。
- snapshot 是独立不可变值,分别携带两层修订和 isDirty。
- save(.shared)/save(.local) 分别校验、保存,返回实际持久化修订。I/O 等待期间可以编辑,新编辑不会被误标为已经保存。
- 本地草稿为 nil 时保存会删除覆写,此恢复操作不要求共享草稿可部署。禁用本地覆写位置时保存该层报错。
- reload 拒绝丢弃未保存编辑;discardChangesAndReload 明确放弃。重载等待期间又发生编辑时拒绝覆盖。
- 重命名维护共享引用和本地覆写,删除仍被引用的定义时报错。

Apple 文件访问经 NSFileCoordinator,使用回调实际 URL。其他平台通过 stateRoot 内稳定的本机配置锁协调;同一配置集合的调用者共用 stateRoot。锁文件不删除,不应同步。App 在进入库前准备云文件和权限;识别到未下载的云端占位文档时报告内容未准备,不回退为默认清单。

两个配置文件和共享解析锁分别原子写入,不构成跨文件或跨设备同步事务。每次写入检查加载基线,拒绝覆盖外部修改。

## 5. 阶段与副作用

| 入口 | 行为 |
|---|---|
| resolve | 保留匹配版本,补全变化声明,成功后提交共享锁 |
| update(selection) | 更新指定范围,成功后提交共享锁 |
| resolve/update(preview:) | 使用显式配置快照,不提交文档或锁 |
| fetch | 按确定版本取回源码和资源,不改锁 |
| cachedInputs | 只接受完整缓存和本地树,不联网 |
| plan | 固定本次目录成员、文件和 recipe 快照 |
| compose(plan,to:) | 离线执行计划并原子发布 |
| compose(to:) | cachedInputs → plan → compose |
| fetchAndCompose | fetch → plan → compose,不自动解析或更新版本 |

Resolution、PreparedInputs、CompositionPlan 由库创建,外部不能任意构造或通用解码。阶段产物绑定工作区和配置快照,拒绝跨工作区使用。

源码请求按规范化仓库身份和 revision 在一次事务中复用,同一请求不能对应冲突 commit。不同 recipe/options 的应用位置独立保留。非 GitHub 请求地址保留 .git 后缀,缓存身份可消除后缀;GitHub 地址统一规范化并由后端补 .git 获取。

resolve/update 在全部解析、下载和校验完成后,再次协调检查共享配置、本地配置及旧锁的基线,然后原子提交新锁。中途失败或取消不改变旧锁。UpdateSelection 支持包、import 和资源标识;不属于当前解析的标识报错。

锁只承诺语义和库读写入口,不承诺内部编码。私有 DTO 解码后完整验证来源、版本、路径、校验、重复项、展开关系与冲突。锁不记录缓存路径、本机覆写或本地树内容;本地声明仅保留不含绝对路径的拓扑和元数据。旧编码报告不兼容,显式 resolve 可重建。

## 6. 资源、导入与开发覆写

`RepositoryProvider.resolve` 一次返回确定 SourceIdentity,默认后端将默认分支识别与 commit 选择放在同次 refs 广播。prepareSource 接收 FilePath 缓存根,返回完整不可变源码快照。HTTPS Git 使用进程内 GitKit/libgit2,不使用外部 git/ssh 或 GitHub REST API。没有自动子模块和 LFS 内容获取,commit 不可用时失败,不替换成分支最新版本。

`ResourceDownloader.download` 写入 FilePath 候选文件。资源缓存按实际字节的 SHA-256 固定,不归一化换行或编码,不 hash 源码目录树。resolve 保留仍匹配的资源版本,update 可单独更新资源。fetch 校验不符即失败,不自动接受新内容或改锁。

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

已保存配置的计划发布前重新检查配置和锁基线,拒绝过期输入;显式预览按固定快照执行。结果目录表示当前发布位置,不是永久代次快照。

## 8. 并发、取消与诊断

缓存按来源和资源身份协调,输出按实际目标位置协调,覆盖多个实例和进程。不能依赖调用方持有同一个 actor。互斥锁文件不删除,等待可取消。阻塞系统操作使用专门执行队列,不占用主线程或合作式 executor。

取消检查覆盖等待、下载、文件枚举、哈希和渲染,提交前执行最后检查。提交已经完成则返回成功,不在成功提交后再报告取消。失败或取消保留旧锁和完整已发布输出,候选和临时视图清理。

PinewindError 提供稳定 Code、说明、来源、行、字段和条目上下文,实现 LocalizedError。CancellationError 单独保留。每次操作可独立接收进度回调,界面线程切换由调用方处理。

## 9. 验证边界

测试包含公开消费方 target、API 正负编译契约、独立文档位置、草稿与保存基线、离线后端计数、资源版本和校验、conf include、开发覆写、取消与原子发布、真实进程间锁、跨平台路径和既有补丁/大文件回归。默认测试不联网,真实 GitHub 测试通过 PINEWIND_NETWORK_TESTS 显式启用。

本轮不包含 sync/事务恢复、Rime 引擎部署或 CLI。它们由后续工作消费当前组合结果。
