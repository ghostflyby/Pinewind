# RimePkg:兼容 plum 清单的包管理与配置方案(设计定案)

- 状态:设计定案稿 v4(未改任何代码)
- 日期:2026-10-11(v2:收窄为 Swift 库设计——本机布局零 plum 沿袭、URL+元数据身份、短名映射分层、有序覆盖);2026-10-13(v3:conf 前端改用 SwiftBash、清单语法生态普查、选项双层求值实证、只读挂载实测落档)
- v4 修订(2026-10-13):conf 前端统一为 SwiftBash 沙盒求值;删除 SwiftBash 平台依赖条件化;commit 为源码复现锚点,归档哈希仅用于下载与缓存校验;补丁逐条目在文件安装后立即应用,后续整文件覆盖可覆盖此前补丁。
- 依赖基线:plum `b1be196`(`/Users/ghostflyby/repos/learn/plum`,仅作语法与语义参照,无代码关联);RimeKit v0.0.42(`rime-deploy`/`RimeDeployCore` 工具族先例);Pteromyini master 契约(`RimeServiceClient.swift:56-72`、`BlueGreenManager.swift:147-169`)
- 已确认决策:
  1. 本阶段为 **Swift 库设计**:定数据文件清单(格式/用途/是否同步)与目录角色及内部结构;**一切目录位置皆为库参数,库不内定路径**;实现另立一轮;
  2. **本机落盘零 plum 沿袭**:兼容仅限 plum 生态包在远端的文件格式与内容/元数据;本机目录与文件布局为自有设计;
  3. 原生清单与锁以 **URL + 元数据**为包身份;plum 包名规则(user 缺省/裸名展开)仅作 conf 导入期的翻译兼容;
  4. **短名映射双层**:同步层与本地覆写层分开存储,字段级合并、本地胜,便于本地改向调试;
  5. 覆盖 = **声明次序后者胜**,无角色特殊优先级;用户文件树(`self`)是清单中一个可排序条目;每个包条目先安装文件、再立即应用自身补丁,后续条目可整文件覆盖此前的文件与补丁;
  6. 取包后端 v1 = **HTTP 归档**(codeload tarball + refs API 锁 commit,零 git 依赖);后端走接口抽象,libgit2 路线(Swift 绑定调研中)可后续替换;
  7. **conf 前端 = SwiftBash 沙盒求值**(v4,§4.5):使用 `BashInterpreter` + 只读挂载,清单求值采用解释器语义,不维护自定义 bash 求值子集;SwiftBash 产品依赖不作平台条件化,macOS / iOS 均支持 conf 导入。

---

## 0. 背景与目标

plum 是 rime 生态的事实标准配置管理器,但其模型有一个结构性缺陷:**取包、组合、落盘全部直接发生在 rime 目录里**。后果:

- 用户改过的文件会被后到的包直接覆盖(`install-packages.sh:84-104`:`diff` 不同即 `cp`,无优先级概念);
- 远程内容与用户配置混居一目录,无法用 git 干净地同步「我自己的配置」;
- plum 的 Rx 标签「删旧块再追加」既处理重复应用,也发生在**就地编辑**可能已被用户改动的文件时。本方案从净态组合,不跨次修改旧输出;单次组合中仍按 Rx 键替换已有同键块,包括从用户文件复制来的块。

本方案的目标:**用户配置与远程下载包彻底分离,经声明次序组合后部署**,使得:

1. 用户配置仓库可以整体 git 同步,复现 = 输入域 commit + 锁文件,二者完全确定组合产物;
2. 兼容 plum 生态的**远端文件格式与内容/元数据**(`*-packages.conf`、包描述语法、`:preset` 等内置清单、recipe.yaml 三段、Rx 标签)——可导入、可翻译;**本机落盘布局完全是自有设计,零 plum 沿袭**;
3. 用户配置树保持 **rime 配置目录的任意子结构**——不强迫任何固定骨架,文件的仓库相对路径即其在组合产物中的路径;
4. 以 **Swift 库**形态交付:目录位置、镜像、后端全部是调用方注入的参数;CLI 与 App(Pteromyini)只是两类调用方。

命名提案(与 `rime-deploy`/`RimeDeployCore` 同族):核心库 `RimePkgCore`(CLI `rime-pkg` 与 App 皆为其调用方)。落位 RimeKit 包内(实现期另立 target)。

## 1. plum 规则基线(实测语义)

以下语义已对照 `learn/plum` 源码逐行核实,是本方案兼容面的 authoritative 基线。**兼容仅限本章所列远端格式的读取与翻译**;§1.5–§1.6 的本机行为(落盘覆盖、缓存布局、git 取包)仅作对照与决裂对象,不沿袭。

### 1.1 包描述语法(resolver.sh:5-56)

```
<github-user>/<repository-name>@<branch>:<recipe>:key=value,...
```

| 部分 | 缺省 | 解析 |
|---|---|---|
| user | `rime` | 最后一个 `/` 之前(`resolver.sh:10-17`) |
| package | — | 最后一个 `/` 之后,剥 `rime-` 前缀用于缓存目录名(`resolver.sh:19-24`) |
| branch | (repo 默认分支) | `@` 之后、第一个 `:` 之前(`resolver.sh:32-37`) |
| recipe | (空) | 第一个 `:` 之后、第二个 `:` 之前(`resolver.sh:40-46`) |
| options | (空) | 第二个 `:` 之后,按 `,`/`:` 切分(`resolver.sh:48-56`) |

裸名 `foo` 经缺省规则展开为 `rime/rime-foo`,plum 缓存目录 `package/rime/foo`。

### 1.2 清单 target 四类(resolver.sh:70-95)

1. **远程清单**:`<user>/<repo>[@<branch>]/<path>/…-packages.conf` 映射为 `https://github.com/<user>/<repo>/raw/<branch|master>/<path>`,或任意 `https://` URL(plum 用 `curl -fLO` 下载后 `source`)(`resolver.sh:58-68`);
2. **本地 `.conf`**:直接 `source`;
3. **`:name`**:展开为工具自带的 `name-packages.conf`(`:preset` 8 包、`:extra` 追加 14 包、`:all` = 两者并集);
4. **其余**:视为单个包描述符。

清单文件本体是 bash 语法(`package_list+=( … )` 数组,可多次追加),plum 以 `source` 加载。

### 1.3 recipe 语义(recipe.sh)

- **选择顺序**(`install-packages.sh:38-46`):显式 `:<recipe>` 用 `<recipe>.recipe.yaml` → 否则包内默认 `recipe.yaml` → 否则白名单整拷;
- **`recipe:` 段 Rx 校验**(`recipe.sh:34-45`):段内 `Rx:` 值须与 recipe 文件名主干一致(未显式指定 recipe 时跳过);
- **`download_files:`**(`recipe.sh:47-94`):每项为 URL,支持 `<filename>::<url>` 指定落盘名,取进包目录;
- **`install_files:`**(`recipe.sh:96-117`):每项是**包目录内求值的 shell glob**(`cd <package_dir> && ls <patterns>`),匹配文件按相对路径落盘;`../<其他包>/…` 形态可跨包取文件(plum 生态中 essay 等共享文件依赖此机制)。映射式(`target: source`)写法在 bash 解析下不可达,生态以纯列表为主(抽样核对见 §10.2);
- **`patch_files:`**(`recipe.sh:119-198`):每项为 `<目标文件>:` + 缩进补丁体;补丁体以 **Rx 标签块**追加到输出目录目标文件的 `__patch:` 段之后,块格式:

  ```yaml
  # Rx: <user>/<repo>:<recipe>:<opt1,opt2> {
  <补丁体>
  # }
  ```

  幂等 = 先按 Rx 标签删旧块再追加;落盘经 `.new` 临时文件 + `mv` 原子替换。recipe options 在 patch 阶段被 `eval` 为 shell 变量,消费点两处,均靠 bash 展开而非显式模板:**目标文件名键**(被转成 `patch_file <键> <<EOF` 命令行后展开,选项决定补哪个文件;rime-emoji `customize.recipe.yaml` 的键 `${schema:-luna_pinyin}.custom.yaml` 为实证用例)与**补丁体**(未加引号的 heredoc 展开)。两层均构成任意求值面:`eval` 对选项词逐字求值,heredoc/命令行对 recipe.yaml(远端内容)中的一切 `$` 展开——本方案以 §9 第 2 条的字面白名单替换取代之。

### 1.4 默认白名单(install-packages.sh:67-82)

无 recipe 的包,从包目录顶层拷贝:

- `*.yaml`,排除 `*.custom.yaml`、`*.recipe.yaml`、`recipe.yaml`;
- `*.txt`、`*.gram`;
- `opencc/*.{json,ocd,txt}`(仅一层)。

注意:**不含 `.ocd2`、不含 `lua/`、不递归子目录**(除 opencc 一层)——生态里靠自定义 recipe 补足(万象即走定制 plum 分支)。

### 1.5 落盘次序与覆盖(install-packages.sh:84-118)

包按清单顺序处理;`install_files` 对已存在且内容不同的目标**无条件 `cp` 覆盖**——后包覆盖先包,也覆盖用户已改文件。这是本方案以「声明次序覆盖」取代的行为(§6.1)。

### 1.6 其他

- 缓存布局:`${plum根}/package/<user>/<pkg>/`(在 plum 仓库内,不在 rime 目录)(`install-packages.sh:27`);
- 取包:git clone `--depth 1`(含子模块);更新 `fetch` + `--ff-only`,失败降级 `reset --hard`;
- `no_update=1` 跳过更新;来源限制:git 包仅 GitHub,清单与 download_files 任意 HTTPS(`git_mirror` 已于上游废弃)。

## 2. 三层域模型

```
┌─ 用户配置域 ─────────┐   ┌─ 包缓存域 ──────────┐   ┌─ 组合域 ────────────┐
│ 用户 authored 文件    │   │ 取回的远程包内容      │   │ 用户 ⊕ 包 ⊕ 补丁     │
│ (rime 目录任意子结构) │   │ (可抛弃,不入库)      │   │ (纯派生,随删随建)    │
│ + manifest/names/    │   │ packages/<身份>/<c>/ │   │                      │
│   lock 等库元数据     │   │                      │   │ ← 部署唯一取材处      │
└───────── git 同步 ────┘   └──────────────────────┘   └──────────────────────┘
```

不变式:

- **I1(纯用户域)**:输入域只含 authored 内容与 §4.1 所列库元数据;库对输入域的唯一写回是 `packages.lock.yaml`(受控生成物),`packages.names.local.yaml` 由用户手写;取包与组合绝不写入输入域;
- **I2(缓存可抛弃)**:缓存域整目录可删;凭锁文件重取,组合结果不变;
- **I3(组合纯派生)**:组合域任意时刻可删;每次从净态重建,相同输入与应用次序得到相同结果,不读取或修改上次组合产物;单次组合中的 Rx 同键替换见 §6.2,只修改组合域文件;
- **I4(任意子结构)**:用户域文件的相对路径 = 其组合产物中的路径;不设强制骨架;
- **I5(复现封闭)**:输入域 git commit + `packages.lock.yaml` 完全确定组合域文件内容;远程仓库源码以锁定的 commit 为复现锚点,不以归档字节哈希或目录树哈希标识源码版本;
- **I6(位置皆参数)**:三个域的根路径、镜像、后端全部由调用方注入(§7.3);库不内定任何本机路径。

## 3. 目录角色与内部结构(位置一律为库参数)

库只认三个**目录角色**,根路径全部由调用方注入(配置类型见 §7.3);库内不出现任何默认绝对路径,也不感知调用方形态(CLI、App、测试)。

### 3.1 输入域(用户配置域)

- 用户文件树:rime 目录任意子结构,无强制骨架(`self` 条目的取材范围);
- 库元数据文件:§4.1 总表所列(manifest、names 两层、lock);
- 组合期排除:`.git/`、`.DS_Store`、`*.local.*` 约定文件与库元数据文件本体。

### 3.2 缓存域

内部结构为自有设计(键 = 包身份,非 plum 布局):

```
packages/<identity>/<commit>/
```

- `identity`:URL 归一化目录形式——GitHub 形态取 `<owner>/<repo>`,其余 URL 取安全化 slug(或其 sha256 前 16 位);
- 以 commit 键控:分支前进不覆写既有取回,多版本天然共存,与锁对齐;
- 归档对象的 sha256 存在缓存域的下载记录中,用于下载对象与缓存字节校验,不进入源码复现锁;不计算解包目录树哈希;
- 归档解包剥 tar 顶层 `<repo>-<sha7>/` 前缀后落此;`file://` 条目不占缓存(直连本地路径)。

### 3.3 组合域

- 每次组合在 `staging/` 临时目录从净态重建,完成后**原子改名**换入 `composed/`(调用方只读 `composed/`);
- 组合域可整目录删除,由输入域 + 锁完全重建。

### 3.4 调用方示例(位置由调用方决定,库不感知)

- **通用 CLI**:输入域 = 用户 dotfiles 仓库;缓存域/组合域 = CLI 实参或其自选默认;目标 rime 目录经**受管路径账本**同步(§7.2),绝不碰 userdb、`build/`、`installation.yaml`、`user.yaml` 及一切未受管文件;
- **Pteromyini**:输入域 = master(`~/Library/Application Support/Pteromyini/config`,契约不变:唯一用户编辑域,引擎永不写入);缓存域/组合域 = App 容器内 App 自定;`importMasterSources` 导入源 master → composed 的改造点见 §7.1;无 manifest 时等价 `order: [self]`(fresh-install 行为与现状一致,bundle 万象 shared 兜底不变);「重新部署」= `fetch(如需)→ compose → deployAndSwitch`,fetch/compose 绝不进入按键服务路径(遵循 XPC-BlueGreen-Refactor-Plan 不变式 I4)。

## 4. 文件清单与格式

### 4.1 文件总表

| 文件(名为提案) | 角色 | 格式 | 用途 | 谁写 | 随用户仓库同步 |
|---|---|---|---|---|---|
| `packages.manifest.yaml` | 输入域 | YAML 有序表 | 部署声明:条目次序即覆盖次序 | 用户 | 同步 |
| `packages.names.yaml` | 输入域 | YAML 映射 | 短名 → URL+元数据(同步层) | 用户 | 同步 |
| `packages.names.local.yaml` | 输入域 | 同上 | 短名映射本地覆写层(字段级合并、本地胜;本地改向调试) | 用户 | **不同步**(约定 gitignore) |
| `packages.lock.yaml` | 输入域 | YAML | 解析锁 + 受管路径账本 | 库生成 | 建议同步 |
| `*-packages.conf` / `recipe.yaml` / Rx 块 | 远端 | plum 格式 | 只读导入与 recipe 语义(§1、§4.5) | 生态 | — |

库不读输入域中除上表外的任何文件;其余内容即用户文件树(`self` 条目的取材范围)。

### 4.2 `packages.manifest.yaml`(原生清单)

有序条目表,**次序即覆盖次序**(§6);条目四型:

```yaml
order:
  - self                       # 用户文件树条目:位置可任意声明(缺省首项)
  - wanxiang                   # 短名条目:经映射解析(§4.3)
  - name: octagram             # 短名条目 + 内联字段覆写
    recipe: customize
  - url: https://github.com/amzxyz/rime-wanxiang   # 直连条目(不经映射)
    ref: main
  - import: :preset            # plum conf 导入:在其位置就地按序展开
  - import: https://…/x-packages.conf
```

- 条目公共可选字段:`ref`(分支/tag)、`recipe`、`options`、`exclude`/`include`(glob);
- 无 manifest 时等价 `order: [self]`(库退化为纯拷贝);
- `import` 求值得到的 plum 描述符按 §1.1 规则翻译为 URL+元数据条目;conf 内的 `source` 按解释器语义处理,不对重复引用自动去重,求值资源限制见 §4.5 与 §10.2;
- 镜像/缓存位置等**环境性配置不在此文件**——那是调用方注入的库参数(§7.3);文件里只有部署声明。

### 4.3 `packages.names.yaml` / `packages.names.local.yaml`(短名映射)

```yaml
# packages.names.yaml —— 同步层
wanxiang:
  url: https://github.com/amzxyz/rime-wanxiang
  ref: main
octagram:
  url: https://github.com/lotem/rime-octagram-data

# packages.names.local.yaml —— 本地覆写层(不同步)
wanxiang:
  url: file:///Users/me/dev/rime-wanxiang   # 改指本地克隆调试
  ref: my-fix
```

- 解析:短名 → 先本地层、后同步层;**字段级合并**(本地层覆盖同名字段,未覆盖字段继承同步层),只改 `url` 不必抄全量;
- 本地层可新增同步层没有的短名(纯本地包);
- plum 简写(`rime-essay` 裸名等)**不经映射机制**:仅在 conf 导入翻译期按 §1.1 缺省规则展开为 URL 条目。

### 4.4 `packages.lock.yaml`(锁)

以 URL 为键(身份与短名解耦——映射改指不改变锁身份)。**组合永远从锁出发**;`update` 才前进 ref 并改写锁。

```yaml
version: 1
packages:
  - url: https://github.com/amzxyz/rime-wanxiang
    ref: main                         # 解析用引用(分支或 tag)
    commit: <40-hex>                  # 解析钉定的 commit
    recipe: wanxiang-base
    options: {key: value}
    fetched-at: "2026-10-11T00:00:00Z"
manifests:                            # import 过的远程 conf(含哈希)
  - url: https://github.com/u/r/raw/main/x-packages.conf
    sha256: <hex>
managed-paths:                        # 受管路径账本:组合域受管相对路径 → 来源 URL
  cn_dicts/base.dict.yaml: {url: https://github.com/amzxyz/rime-wanxiang}
  default.yaml: {url: https://github.com/amzxyz/rime-wanxiang}
```

账本双重用途:删包后的清理计算(通用形态同步的删除集)+ 组合来源溯源。

### 4.5 `*-packages.conf` 前端(plum 兼容;SwiftBash 沙盒求值,v4)

plum 以 `source` 加载清单意味着清单可执行任意代码。v2 曾决定手写「bash 数组字面量子集」静态解析,v3 起证伪并废弃:生态普查(19 份独立内容清单、34 个文件)显示严格子集会拒绝 **68.4%**——失败组 100% 使用初始赋值 `package_list=( … )`(社区单文件清单的主流写法),另有行尾注释 ×2、`source "${root_dir:-.}"/…` include ×2、双引号 `${var:-default}` ×1;而危险构造(`$( )`、反引号、裸 `$var`、单引号串、if/for/函数)在全部文件中**零出现**。结论:生态复杂度集中在无害语法,手写子集既不必要也不胜任。

conf 前端使用 **SwiftBash**(cocoanetics/swiftbash;MIT;SPM 远程依赖 `0.1.x`,家族 minor 同步锁)的 `BashInterpreter` 进行沙盒求值。此前的 `BashSyntax` AST 子集提取路线已被替代,不再作为默认或备选前端。

**求值与能力边界(只读挂载已实测)**

- 输入域以 `Mount(virtual:host:readOnly: true)` 挂载供解释器 `source`:include 与 `${var:-default}` 获得与 plum 一致的原生语义;
- 数组初始化、重置、追加、引号、变量展开与 `source` 均由解释器处理;求值完成后读取 `package_list` 数组,再按 §1.1 翻译描述符。不另设 AST 节点白名单或自定义参数展开子集;
- `:preset`/`:extra`/`:all` 的 vendored conf 与取回的远程 conf 走同一沙盒求值入口,清单内容只读供给;include 的来源定位与资源限制见实现期核对清单;
- 只读由 `MountedFileSystem.gateWrite` 结构性强制(实测:`cat`/`source` 通过,重定向/`touch`/`rm`/`chmod` 全部 `permission denied`,被挂载目录零残留);读写两侧均过 `canonicalGate`,挂载内符号链接逃逸被拒;
- 能力受限模型:无 fork/exec,命令集 = 已注册的 Swift 命令,网络默认拒绝(`Network access denied`),文件系统默认虚拟;
- 威胁模型为**能力受限执行 + 只读挂载强制 I1**:清单在 Swift 解释器内求值,不调用宿主 bash;访问权限由挂载表、命令注册与网络权限控制,不依赖语法子集限制。

**依赖与平台事实**

- 产品级消费:`BashInterpreter`(所需命令按需由 `BashCommandKit` 提供);SwiftPM 解析期取回家族(ShellKit/SwiftPorts/SwiftScript 及传递依赖;其中 GitKit 自带 vendored libgit2,可作 §5.2 后端的参照),解释器所需家族目标进入构建图;
- swift-tools 6.2;探测的 SwiftBash 平台基线为 macOS 13 / iOS 16,当前 RimeKit 为 macOS 15 / iOS 16。SwiftBash 产品依赖不加 `.when(platforms:)`,macOS / iOS 均提供原生清单与 conf 导入;
- 0.x 阶段 API 随 minor 变动,`upToNextMinor` 锁家族同步升级。

## 5. 取包后端(v1:HTTP 归档)

### 5.1 流程

1. **解析引用**:`GET {api}/repos/<u>/<r>` 取 `default_branch`(描述符未指定分支时),或 `GET {api}/repos/<u>/<r>/commits/<ref>` 取分支/tag 头 commit sha;
2. **取归档**:`GET {archive}/<u>/<r>/tar.gz/<sha>`(按锁定 commit 寻址)。commit 确定源码版本;归档压缩字节可能变化,其 sha256 仅存入下载缓存记录用于对象校验,不与历史锁中的归档哈希作复现约束,不计算目录树哈希;
3. **解包**:剥顶层 `<repo>-<sha7>/` 前缀,落缓存域 `packages/<identity>/<commit>/`(§3.2);
4. **recipe download_files**:普通 HTTPS GET(支持 `<filename>::<url>` 落盘名)。

### 5.2 后端接缝(为 libgit2 预留)

```swift
protocol PackageFetcher: Sendable {
  func resolveDefaultBranch(user: String, repo: String) async throws -> String
  func resolveCommit(user: String, repo: String, ref: String) async throws -> String
  func fetchArchive(user: String, repo: String, commit: String) async throws -> ArchivedPackage
  func downloadFile(url: URL) async throws -> Data
}
```

v1 仅提供 `HTTPArchiveFetcher`;libgit2 后端(子模块、增量)后续实现同协议替换,组合层无感。

### 5.3 已知约束(显式接受)

- 无子模块、无增量更新(归档天然全量;源码缓存按 URL 身份 + 锁定 commit 寻址,成功取回、解包后才标记完成;归档缓存字节按下载记录校验);
- 未认证 GitHub API 限流 60 次/时/IP:取包为低频操作,可接受;遇 403/429 给可读诊断;镜像经库配置(§7.3 `PkgConfig.mirrors`)缓解;
- v1 归档后端仅支持 **GitHub 形态 URL**(github.com 及同形镜像)与 **`file://` 本地路径**(短名映射本地改向的直连通道,免网络,不占缓存);其余 git 托管 URL 明确报错,留待 git/libgit2 后端;
- 仅 HTTPS。

## 6. 组合规则

### 6.1 步骤(每次从净态重建,临时目录 + 原子换入)

1. 在组合域临时目录重建(§3.3);
2. 按 manifest `order` **逐条目依声明次序**应用:
   - `self`:拷用户树(排除 §3.1 排除项;条目级 `exclude`/`include` 生效);
   - 包条目:`download_files` 取进缓存域包目录 → 定文件集(显式 `recipe` → 包内 `recipe.yaml` → 白名单,§1.4 规格逐字对齐外加 `.ocd2`,见偏离表)→ `install_files` glob 于缓存域包目录求值(`../<包>/…` 跨包寻址在缓存域内解析)→ 按相对路径落组合域 → **立即应用该条目的 `patch_files`**(§6.2),完成后才处理下一条目;
   - 同路径文件:**后声明条目覆盖先声明条目**,整文件覆盖同时覆盖该文件中此前已应用的补丁;`self` 与包条目完全同权,其在序中的位置由用户声明(缺省首项)。补丁遵循同一条目次序,不设独立的最终补丁阶段;
3. 全部条目完成后,写账本回 `packages.lock.yaml`,组合域原子换入。

### 6.2 补丁语义(逐条目应用,同 Rx 替换)

补丁属于声明它的包条目:**先安装该条目的文件,再立即应用其补丁,然后进入下一条目**。补丁在当前文件上追加或替换 Rx 块,后续条目仍可覆盖整个文件:

- 目标文件基底 = 该条目的文件安装完成后,组合域中当时的同名文件(可能来自当前包、`self` 或先前的包条目);
- 目标不存在时,创建所需父目录与带 `__patch:` 的目标文件;目标存在但没有 `__patch:` 段时,补建该段;
- 各包补丁段以 plum 同款 Rx 标签块格式追加到 `__patch:` 段内;Rx 键沿用 plum 形态 `<user>/<repo>:<recipe>:<opts>`(由包 URL 推导 owner/repo),与生态既有标记互认;
- **不同 Rx 键**:保留当前已有块,按条目应用次序追加新块;**同一目标内同一 Rx 键**:先移除当前文件中所有该键的旧块,再在段末追加本次块,使本次应用后的该键仅保留一份。旧块可能来自先前条目,也可能从用户文件树或包文件中复制而来;去重范围是当前目标文件,不作跨文件或全局去重;
- 后续条目若整文件覆盖目标,此前补丁随旧文件一并被覆盖,不在末尾重新补回;因此 `self` 放最后时,它提供的同名文件决定最终内容;
- 未被同键替换或整文件覆盖的 Rx 注释原样保留,用于溯源与生态标记互认(如本机 `~/Library/Rime/rime_ice.custom.yaml` 中 octagram 留下的标记);
- **绝不回写输入域**。

例如 `order: [A, self, B]`:A 安装文件并应用 A 的补丁 → `self` 拷入用户文件,覆盖同名文件及其中 A 的补丁 → B 安装文件并在当时的目标文件上应用 B 的补丁。若 B 只补丁、不安装该目标文件,其补丁作用于 `self` 提供的基底;若 B 安装同名文件,则先覆盖基底再应用补丁。

## 7. 调用方衔接(位置均由调用方注入)

### 7.1 Pteromyini(未来改造点,本轮不实施)

| 改动 | 位置 |
|---|---|
| `importMasterSources` 导入源 master → composed | `BlueGreenManager.swift:147-169` |
| 「重新部署」前置 fetch + compose(异步,禁入按键路径) | `PteromyiniApplication.swift` redeploy 动作 |
| 缓存域/组合域路径常量 | `RimeServiceClient.swift`(与 master 常量同处) |

不改动:master 契约、bundle 万象 shared 兜底、`prefillStagedBuild` 预铺、蓝绿翻转语义。

### 7.2 通用形态同步(`sync` 子命令)

staging(组合域)→ rime 目录的账本同步:

- 受管且内容变 → 更新;账本有而 staging 无 → 删除(该包已移除或文件退出文件集);
- 账本外路径一律不碰(userdb、`build/`、`installation.yaml`、`user.yaml`、用户手放文件);
- `.new` 原子替换机制**不进入本方案**:它服务的场景(就地改用户文件时的冲突暂停)被 staging + 账本同步结构性消除;
- `--dry-run` 打印变更集。

### 7.3 库 API 骨架与 CLI 示例(草案)

库的一切位置/后端/镜像经单一配置类型注入;CLI 只是库的一层调用方:

```swift
struct PkgConfig: Sendable {
  var inputRoot: URL          // 输入域(§3.1)
  var cacheRoot: URL          // 缓存域(§3.2)
  var composeRoot: URL        // 组合域(§3.3)
  var fetcher: any PackageFetcher
  var mirrors: [MirrorRule]   // GitHub 形态 URL 的 base 改写(可选)
}
// 主要入口(草案):resolve() / fetch() / compose() / sync(into:) / update()
```

CLI 示例:`rime-pkg resolve|fetch|compose|sync|update|list`(`--config <dir>` 指输入域,`--rime-dir <dir>` 通用形态目标——皆为 CLI 层实参,非库内定)。

## 8. 兼容与偏离对照表

| 面 | plum | 本方案 | 动机 |
|---|---|---|---|
| 包描述语法 / 缺省规则 | §1.1 | **同** | 生态兼容 |
| conf 清单语法 | bash,`source` 执行 | **SwiftBash 沙盒求值**(`BashInterpreter` + 只读挂载),不另设语法子集 | 解释器兼容清单语义,权限边界保障输入域只读(§9) |
| 原生清单 | 无(仅 conf) | `packages.manifest.yaml` 有序条目,plum conf 经 `import` 接入 | URL+元数据身份;次序即覆盖序 |
| `:preset` 等内置清单 | plum 仓库 conf | vendored 副本 | 免运行期 plum 依赖 |
| 远程清单 URL | 任意 HTTPS | **同** | 生态兼容 |
| recipe 三段 / Rx 格式 | §1.3,逐包安装后补丁 | **同格式与应用时序**;组合域内逐条目安装后补丁,同目标同 Rx 替换,后续整文件覆盖可覆盖已有补丁 | 净态重建保障跨次幂等,Rx 替换处理单次组合中的既有块 |
| 包身份 / 命名 | user/repo 简写 + 缺省展开 | **URL+元数据**为原生身份;plum 简写仅导入期翻译;短名映射双层(§4.3) | 本机零沿袭;可本地改向 |
| 缓存布局 | `package/<user>/<pkg>`(plum 仓库内) | `packages/<身份>/<commit>`(自有设计,位置为库参数) | 本机布局零沿袭 |
| 取包 | GitHub git clone | HTTP 归档(镜像可配) | 零 git 依赖,锁保复现 |
| 覆盖语义 | 后包无条件覆盖(用户文件遭殃) | **声明次序后者胜**,每包安装后立即补丁;`self` 为可排序条目,后续整文件可覆盖此前补丁 | 次序显式化;用户树同权可定位 |
| `.new` 原子替换 | 有 | 无(账本同步取代) | 场景被结构性消除 |
| 白名单 | 顶层 yaml/txt/gram + opencc 一层 | 同 + `.ocd2` | ocd2 是现代 OpenCC 产物,plum 白名单陈旧 |
| 子模块 / `git_mirror` / `--select` | 支持 / 已废弃 / 支持 | v1 均不支持 | 归档路线代价;交互属 CLI 之外 |
| 锁文件 | 无 | `packages.lock.yaml`(URL 键控 + 受管账本) | 复现 |

## 9. 安全决策

1. **清单沙盒求值**:使用 SwiftBash `BashInterpreter`,只读挂载输入域与清单资源;无宿主 fork/exec,网络保持拒绝,仅注册清单求值所需命令。`source`、数组与参数展开采用解释器语义,安全边界由能力限制与文件系统权限强制,不维护 bash 求值子集(§4.5)。
2. **补丁是数据不是代码**:plum 在 patch 阶段生成 bash 脚本并执行(选项 `eval`、命令行与未引号 heredoc 双层任意求值,实证见 §1.3);本方案补丁体与目标文件名键均为数据,选项替换仅对**已声明的 option 键**做字面白名单替换(生态用例 rime-emoji 已确认该形态足够)。
3. **归档解包加固**:tar 条目拒绝绝对路径、`..` 穿越与符号链接条目。
4. **传输与完整性**:远程传输仅 HTTPS;commit 是仓库源码的复现锚点。归档 sha256 仅用于下载与缓存对象校验,损坏对象丢弃后按同一 commit 重取,不自动前进 ref;同一 commit 的归档压缩字节变化不改变源码版本。远程清单 sha256 对锁校验,失败即终止不回落。

## 10. 实现路线与核对清单

### 10.1 里程碑

- **M1 解析 + 组合(离线可测)**:manifest / names 两层解析器 + SwiftBash conf 沙盒求值前端 + 有序条目组合引擎(白名单/glob/补丁重建);fixture 取 `learn/plum` 各 conf 与 `RimeDeployPluginTests` 现有包形态用例(万象 import_tables/prism 命名/孤儿词典三类坑);
- **M2 取包 + 锁**:`HTTPArchiveFetcher` + 锁读写 + `update`;
- **M3 Pteromyini 集成**:§7.1 改造点 + 菜单/设置入口。

### 10.2 实现期核对清单(本轮未逐字确认,不冒下定论)

- `install_files` 生态形态抽样:纯 glob 列表为主,映射式是否真实存在于在用 recipe;
- `opencc/*.*` 白名单是否需含 `.ocd2` 之外的现代产物(以生态包抽样定);
- 远程 conf 的编码/行尾假设(plum 依赖 bash 词法,CRLF 行为需测);
- 同一 commit 的归档重新生成或压缩格式变化时,下载缓存记录更新与损坏缓存恢复行为;归档哈希不作为源码复现约束;
- 镜像域名对 API/归档两条路径的兼容矩阵;
- recipe `Rx:` 校验对大小写/空白的容差;
- 补丁时序 fixture:后续整文件覆盖此前补丁、`self` 置尾、已有同 Rx 块替换、不同 Rx 顺序追加、目标缺失时创建与重复净态组合结果一致;
- 沙盒求值最小产品集:`BashInterpreter` 能否脱离 `BashCommandKit` 满足 `source` + 数组读取(`printf` 是否内建);
- conf 求值的只读清单视图、远程 include 相对来源定位、注入变量范围及时间/内存/include 深度限制;与解释器语义一致的重复 `source` 行为;
- SwiftBash 0.x 家族 minor 同步升级的跟进纪律(minor 变更须成组 bump 并过回归)。

## 11. 开放问题

- 组合报告(冲突告警、来源清单)是否落盘为文件,v1 先仅日志;
- 万象从构建期 submodule 迁为运行期包的路径与时机;
- 设置 UI 中包列表管理的形态(增删包 = 编辑 `packages.manifest.yaml` 的引导式界面?);
- 多机同步下锁文件的合并策略(以 commit 为锚的自动合并是否安全);
- `download_files` 是否需要条件请求(ETag/Last-Modified)省流量,v1 全量重下;
- 原生条目 `ref` 承载分支/tag;commit 直引(钉死历史版本)是否开放为显式字段;
- manifest 与 names 是否合并为单文件多段(减文件数 vs 同步粒度);
- 本地覆写层是否需要输入域之外的全局层(用户主目录级)——v1 仅输入域内两层;
- `file://` 条目的 ref 语义(忽略,或校验本地工作树状态);
