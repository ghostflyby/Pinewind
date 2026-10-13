# 松风 / Pinewind:兼容 plum 清单的包管理与配置方案(设计定案)

- 状态:设计定案稿 v4;§12 为文件格式与状态职责草案,§13 为增量执行预设计(未改任何代码)
- 日期:2026-10-11(v2:收窄为 Swift 库设计——本机布局零 plum 沿袭、URL+元数据身份、短名映射分层、有序覆盖);2026-10-13(v3:conf 前端改用 SwiftBash、清单语法生态普查、选项双层求值实证、只读挂载实测落档)
- v4 修订(2026-10-13):conf 前端统一为 SwiftBash 沙盒求值;删除 SwiftBash 平台依赖条件化;commit 为源码复现锚点,归档哈希仅用于下载与缓存校验;补丁逐条目在文件安装后立即应用,后续整文件覆盖可覆盖此前补丁。
- 依赖基线:plum `b1be196`(`/Users/ghostflyby/repos/learn/plum`,仅作语法与语义参照,无代码关联);RimeKit v0.0.42(`rime-deploy`/`RimeDeployCore` 工具族先例);Pteromyini master 契约(`RimeServiceClient.swift:56-72`、`BlueGreenManager.swift:147-169`)
- 已确认决策:
  1. 本阶段为 **Swift 库设计**:定数据文件清单(格式/用途/是否同步)与目录角色及内部结构;**一切目录位置皆为库参数,库不内定路径**;实现另立一轮;
  2. **本机落盘零 plum 沿袭**:兼容仅限 plum 生态包在远端的文件格式与内容/元数据;本机目录与文件布局为自有设计;
  3. 原生清单与锁以 **URL + 元数据**为包身份;plum 包名规则(user 缺省/裸名展开)仅作 conf 导入期的翻译兼容;
  4. **短名映射双层**:同步层合入 `pinewind.yaml` 的 `names` 段,本地覆写单独存于 `pinewind.local.yaml`;字段级合并、本地胜,便于本地改向调试;
  5. 覆盖 = **声明次序后者胜**,无角色特殊优先级;用户文件树(`self`)是清单中一个可排序条目;每个包条目先安装文件、再立即应用自身补丁,后续条目可整文件覆盖此前的文件与补丁;
  6. 取包后端 v1 = **HTTP 归档**(codeload tarball + refs API 锁 commit,零 git 依赖);后端走接口抽象,libgit2 路线(Swift 绑定调研中)可后续替换;
  7. **conf 前端 = SwiftBash 沙盒求值**(v4,§4.5):使用 `BashInterpreter` + 只读挂载,清单求值采用解释器语义,不维护自定义 bash 求值子集;SwiftBash 产品依赖不作平台条件化,macOS / iOS 均支持 conf 导入。
  8. **独立下载资源固定版本**:recipe 的 `download_files` 不受仓库 commit 约束,可变 URL 的资源单独在包锁中记录内容校验值;该校验值标识资源内容版本,不用于源码归档复现(语义见 §12.5)。
  9. **锁为库管理的不透明文件**:文件名 `pinewind.lock`,不带 YAML 后缀,不承诺序列化格式、字段布局或内部结构;用户通过库操作生成、更新和检查锁。
  10. **用户配置 version 必填**:manifest 与本地覆写文件均须声明顶层整数 `version: 1`;缺失或不支持的版本报错,不按隐含 v1 解析。plum conf/recipe 继续使用生态格式,锁和私有状态不受此 YAML 规则约束。
  11. **项目命名**:松风 / Pinewind;库 `PinewindCore`,命令 `pinewind`,用户侧文件 `pinewind.yaml` / `pinewind.local.yaml` / `pinewind.lock`。

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

项目/产品名已定为 **松风 / Pinewind**;核心库 `PinewindCore`,CLI 命令 `pinewind`,与输入法产品 Pteromyini 分别命名。核心库落位 RimeKit 包内(实现期另立 target),CLI 与 App 均为库的调用方。

“松风”取意于王维《酬张少府》的“松风吹解带,山月照弹琴”(参见[原诗](https://www.gushici.net/shici/31/4886.html));英文名 Pinewind 与松林之风的意象对应。配置文件统一使用产品的小写前缀:共享声明 `pinewind.yaml`、可选本地覆写 `pinewind.local.yaml`、库管理的不透明锁 `pinewind.lock`。

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
│ + manifest/lock      │   │ packages/<身份>/<c>/ │   │                      │
│   可选本地覆写        │   │                      │   │ ← 部署唯一取材处      │
└───────── git 同步 ────┘   └──────────────────────┘   └──────────────────────┘
```

不变式:

- **I1(纯用户域)**:输入域只含 authored 内容与 §4.1 所列库元数据;库对输入域的唯一写回是 `pinewind.lock`(受控生成物),`pinewind.local.yaml` 由用户手写;取包与组合绝不写入输入域;
- **I2(缓存可抛弃)**:缓存域整目录可删;凭锁文件重取,组合结果不变;
- **I3(组合纯派生)**:组合域任意时刻可删;结果必须等价于从净态按声明次序组合。允许复用依赖仍有效的私有缓存与中间结果,缓存缺失时可全量重建;不得在已发布文件上重复叠加补丁来代替组合。Rx 同键替换见 §6.2,不修改输入域;
- **I4(任意子结构)**:用户域文件的相对路径 = 其组合产物中的路径;不设强制骨架;
- **I5(复现封闭)**:输入域 git commit + `pinewind.lock` 完全确定组合域文件内容;远程仓库源码以锁定的 commit 为复现锚点,不以归档字节哈希或目录树哈希标识源码版本;
- **I6(位置皆参数)**:三个域的根路径、镜像、后端全部由调用方注入(§7.3);库不内定任何本机路径。

## 3. 目录角色与内部结构(位置一律为库参数)

库只认三个**目录角色**,根路径全部由调用方注入(配置类型见 §7.3);库内不出现任何默认绝对路径,也不感知调用方形态(CLI、App、测试)。

### 3.1 输入域(用户配置域)

- 用户文件树:rime 目录任意子结构,无强制骨架(`self` 条目的取材范围);
- 库元数据文件:§4.1 总表所列(manifest 含同步 names、可选本地覆写、lock);
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

- 每次组合在未发布的 staging 中准备候选结果,可全量重建或复用仍有效的文件/中间结果;完成后原子发布为 composed(调用方只读)。活跃输出不可就地修改,具体代次切换机制在实现期确定;
- 组合域可整目录删除,由输入域 + 锁完全重建。

### 3.4 调用方示例(位置由调用方决定,库不感知)

- **通用 CLI**:输入域 = 用户 dotfiles 仓库;缓存域/组合域 = CLI 实参或其自选默认;目标 rime 目录经**受管路径账本**同步(§7.2),绝不碰 userdb、`build/`、`installation.yaml`、`user.yaml` 及一切未受管文件;
- **Pteromyini**:输入域 = master(`~/Library/Application Support/Pteromyini/config`,契约不变:唯一用户编辑域,引擎永不写入);缓存域/组合域 = App 容器内 App 自定;`importMasterSources` 导入源 master → composed 的改造点见 §7.1;无 manifest 时等价 `order: [self]`(fresh-install 行为与现状一致,bundle 万象 shared 兜底不变);「重新部署」= `fetch(如需)→ compose → deployAndSwitch`,fetch/compose 绝不进入按键服务路径(遵循 XPC-BlueGreen-Refactor-Plan 不变式 I4)。

## 4. 文件清单与格式

### 4.1 文件总表

| 文件(名为提案) | 角色 | 格式 | 用途 | 谁写 | 随用户仓库同步 |
|---|---|---|---|---|---|
| `pinewind.yaml` | 输入域 | YAML 映射(version 必填,names 可选,order 有序) | 短名同步层 + 部署声明:条目次序即覆盖次序 | 用户 | 同步 |
| `pinewind.local.yaml` | 输入域 | YAML 映射(version 必填,names 覆写) | 短名映射本地覆写层(字段级合并、本地胜;本地改向调试) | 用户 | **不同步**(约定 gitignore) |
| `pinewind.lock` | 输入域 | 库私有,不承诺内部格式 | 解析结果与资源版本约束 | 库生成 | 建议同步 |
| `*-packages.conf` / `recipe.yaml` / Rx 块 | 远端 | plum 格式 | 只读导入与 recipe 语义(§1、§4.5) | 生态 | — |

库不读输入域中除上表外的任何文件;其余内容即用户文件树(`self` 条目的取材范围)。

### 4.2 `pinewind.yaml`(原生清单)

顶层 `version` 必填,`names` 为可选同步短名映射(缺省 `{}`),`order` 为有序条目表。短名定义本身不安装包,只有 order 中引用才应用;**条目次序即覆盖次序**(§6),条目四型:

```yaml
version: 1
names:
  wanxiang:
    url: https://github.com/amzxyz/rime-wanxiang
    ref: main
  octagram:
    url: https://github.com/lotem/rime-octagram-data
order:
  - self                       # 用户文件树条目:位置可任意声明
  - wanxiang                   # 短名条目:经映射解析(§4.3)
  - name: octagram             # 短名条目 + 内联字段覆写
    recipe: customize
  - url: https://github.com/amzxyz/rime-wanxiang   # 直连条目(不经映射)
    ref: main
  - import: :preset            # plum conf 导入:在其位置就地按序展开
  - import: https://…/x-packages.conf
```

- 包条目可选字段:`ref`(分支/tag)或 `commit`(二者互斥)、`recipe`、`options`、`exclude`/`include`(glob);各条目具体字段见 §12.3;
- 无 manifest 时等价 `order: [self]`(库退化为纯拷贝);
- `import` 求值得到的 plum 描述符按 §1.1 规则翻译为 URL+元数据条目;conf 内的 `source` 按解释器语义处理,不对重复引用自动去重,求值资源限制见 §4.5 与 §10.2;
- 镜像/缓存位置等**环境性配置不在此文件**——那是调用方注入的库参数(§7.3);文件里只有部署声明。

### 4.3 manifest 的 `names` / `pinewind.local.yaml`(短名映射)

```yaml
# pinewind.local.yaml —— 本地覆写层(不同步)
version: 1
names:
  wanxiang:
    url: file:///Users/me/dev/rime-wanxiang   # 改指本地文件树调试
```

- 同步短名表就是 manifest 的 names 段,不另设文件。解析按 manifest.names → 本地 names → 条目内联字段的次序**字段级合并**,后层胜;只改 `url` 不必抄全量;
- 本地层可新增同步层没有的短名(纯本地包);
- plum 简写(`rime-essay` 裸名等)**不经映射机制**:仅在 conf 导入翻译期按 §1.1 缺省规则展开为 URL 条目。

### 4.4 `pinewind.lock`(锁)

锁是库生成、解释和维护的不透明文件,不承诺文本/二进制编码、字段名或结构。文件可以随用户仓库同步;库应提供检查解析结果的 API/CLI,不要求用户直接编辑锁。实现负责内部格式识别与迁移,不支持的锁给出明确诊断,不静默重新解析为新版本。

语义上记录有序包应用对应的源码 URL、锁定 commit、recipe/options/过滤规则,conf 的已解析展开结果,以及独立下载资源的版本约束。同一 URL 可出现多次,不以 URL 唯一记录代替有序声明;源码缓存可按 URL + commit 复用。

锁不承载本机路径、部署账本或增量执行缓存。resolve/update 才修改锁,fetch/compose/sync 不改锁;本地覆写在本次执行中应用,不生成本地锁。具体匹配与更新语义见 §12.4–§12.5;每目标部署状态见 §12.6。

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
  func resolveDefaultBranch(url: URL) async throws -> String
  func resolveCommit(url: URL, ref: String) async throws -> String
  func prepareSource(url: URL, commit: String, cacheRoot: URL) async throws -> PackageSourceSnapshot
  func downloadFile(url: URL) async throws -> Data
}
```

`PackageSourceSnapshot` 表示可读取的完整源码快照,具体类型在实现期定义,不要求以归档或 git 工作树作为组合层输入。v1 仅提供 `HTTPArchiveFetcher`,内部通过归档准备快照;libgit2 后端后续可用增量对象传输准备同一语义的快照,组合层无感。

### 5.3 已知约束(显式接受)

- 无子模块、无新 commit 的差量传输(归档天然全量;已有 URL 身份 + 锁定 commit 的完整缓存可复用,成功取回、解包后才标记完成;归档缓存字节按下载记录校验)。这不限制增量组合/同步,见 §13;
- 未认证 GitHub API 限流 60 次/时/IP:取包为低频操作,可接受;遇 403/429 给可读诊断;镜像经库配置(§7.3 `PkgConfig.mirrors`)缓解;
- v1 归档后端仅支持 **GitHub 形态 URL**(github.com 及同形镜像)与 **`file://` 本地路径**(短名映射本地改向的直连通道,免网络,不占缓存);其余 git 托管 URL 明确报错,留待 git/libgit2 后端;
- 仅 HTTPS。

## 6. 组合规则

### 6.1 步骤(净态组合为语义基准,候选结果原子发布)

1. 使用锁与已准备好的源码/资源建立组合计划,在组合域临时目录准备结果(§3.3)。下列顺序定义全量基准语义;增量执行可跳过或复用经依赖检查仍有效的操作(§13);
2. 按 manifest `order` **逐条目依声明次序**应用:
   - `self`:拷用户树(排除 §3.1 排除项;条目级 `exclude`/`include` 生效);
   - 包条目:消费 fetch 准备的源码与独立下载资源视图 → 定文件集(显式 `recipe` → 包内 `recipe.yaml` → 白名单,§1.4 规格逐字对齐外加 `.ocd2`,见偏离表)→ `install_files` glob 于缓存域包目录求值(`../<包>/…` 跨包寻址在缓存域内解析)→ 按相对路径落组合域 → **立即应用该条目的 `patch_files`**(§6.2),完成后才处理下一条目;
   - 同路径文件:**后声明条目覆盖先声明条目**,整文件覆盖同时覆盖该文件中此前已应用的补丁;`self` 与包条目完全同权,其在序中的位置由用户声明(缺省首项)。补丁遵循同一条目次序,不设独立的最终补丁阶段;
3. 全部条目完成后发布候选组合结果与本次文件集,不改锁。部署账本只在目标同步成功后提交(§12.6)。

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

CLI 示例:`pinewind resolve|fetch|compose|sync|update|list`(`--config <dir>` 指输入域,`--rime-dir <dir>` 通用形态目标——皆为 CLI 层实参,非库内定)。

## 8. 兼容与偏离对照表

| 面 | plum | 本方案 | 动机 |
|---|---|---|---|
| 包描述语法 / 缺省规则 | §1.1 | **同** | 生态兼容 |
| conf 清单语法 | bash,`source` 执行 | **SwiftBash 沙盒求值**(`BashInterpreter` + 只读挂载),不另设语法子集 | 解释器兼容清单语义,权限边界保障输入域只读(§9) |
| 原生清单 | 无(仅 conf) | `pinewind.yaml` 有序条目,plum conf 经 `import` 接入 | URL+元数据身份;次序即覆盖序 |
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
| 锁文件 | 无 | `pinewind.lock`(库管理,不承诺内部格式;记录有序解析结果) | 复现;本机部署状态另行管理 |

## 9. 安全决策

1. **清单沙盒求值**:使用 SwiftBash `BashInterpreter`,只读挂载输入域与清单资源;无宿主 fork/exec,网络保持拒绝,仅注册清单求值所需命令。`source`、数组与参数展开采用解释器语义,安全边界由能力限制与文件系统权限强制,不维护 bash 求值子集(§4.5)。
2. **补丁是数据不是代码**:plum 在 patch 阶段生成 bash 脚本并执行(选项 `eval`、命令行与未引号 heredoc 双层任意求值,实证见 §1.3);本方案补丁体与目标文件名键均为数据,选项替换仅对**已声明的 option 键**做字面白名单替换(生态用例 rime-emoji 已确认该形态足够)。
3. **归档解包加固**:tar 条目拒绝绝对路径、`..` 穿越与符号链接条目。
4. **传输与完整性**:远程传输仅 HTTPS;commit 是仓库源码的复现锚点。归档 sha256 仅用于下载与缓存对象校验,损坏对象丢弃后按同一 commit 重取,不自动前进 ref;同一 commit 的归档压缩字节变化不改变源码版本。远程清单 sha256 对锁校验,失败即终止不回落。

## 10. 实现路线与核对清单

### 10.1 里程碑

- **M1 解析 + 组合(离线可测)**:manifest(含同步 names) / 本地 names 覆写解析器(version 必填) + SwiftBash conf 沙盒求值前端 + 有序条目组合引擎(白名单/glob/补丁重建);fixture 取 `learn/plum` 各 conf 与 `RimeDeployPluginTests` 现有包形态用例(万象 import_tables/prism 命名/孤儿词典三类坑);
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
- 设置 UI 中包列表管理的形态(增删包 = 编辑 `pinewind.yaml` 的引导式界面?);
- 多机同步下锁文件的合并策略(以 commit 为锚的自动合并是否安全);
- `download_files` 是否需要条件请求(ETag/Last-Modified)省流量,v1 全量重下;
- 原生条目 `ref` 承载分支/tag;commit 直引(钉死历史版本)是否开放为显式字段;
- 本地覆写层是否需要输入域之外的全局层(用户主目录级)——v1 仅输入域内两层;
- `file://` 条目的 ref 语义(忽略,或校验本地工作树状态);

## 12. 文件格式细化草案(待确认)

本节细化用户编写的 YAML 配置与库生成状态的职责。锁不承诺内部格式;部署状态和缓存状态亦不作为用户配置协议。锁与状态只定义必要语义,不以序列化示例限制实现。

### 12.1 文件职责与同步边界

| 文件 | 所在角色 | 必要性 | 谁写 | 同步 |
|---|---|---|---|---|
| `pinewind.yaml` | 输入域 | 含 order 与可选 names;无文件等价仅 `self` | 用户 | 是 |
| `pinewind.local.yaml` | 输入域 | 本地改向时可选 | 用户 | 否 |
| `pinewind.lock` | 输入域 | 使用远程包/import 后生成 | 库 | 是 |
| 部署状态(私有存储) | 调用方注入的位置,每部署目标独立 | 使用目录同步时需要 | 库 | 否 |
| 下载与增量缓存元数据(私有存储) | 缓存域 | 产生缓存时维护 | 库 | 否 |

- 普通配置只需 manifest 与 lock;同步短名表是 manifest 的可选 names 段,本地覆写按需出现,不生成本地锁。没有远程包或 import 的纯 `self` 组合不要求先生成锁。
- 配置只声明所需内容;锁只记录解析结果;同步状态只记录某个本机目标的成功同步历史;下载记录只记录可抛弃的缓存对象。
- 目录根、镜像、认证和后端继续由调用方参数注入,不新增库级机器配置文件;CLI/App 如需保存自己的设置,格式由各调用方决定。
- `self` 排除 manifest、本地覆写、pinewind.lock 等库元数据;本地文件由调用方配置 gitignore。库不得因此修改用户的 `.gitignore`。

### 12.2 通用编码规则

- 本小节编码规则仅适用于用户编写的 manifest / 本地覆写文件,不适用于 plum conf/recipe、锁或私有状态。用户配置使用 UTF-8 YAML,顶层整数 version 必填,当前支持 `version: 1`;缺失、类型错误或不支持的版本均报错,不接受无版本简写。
- 数组有序;映射键的书写顺序不表示优先级。重复键、未知字段、错误类型和不支持的版本给带文件位置的诊断,不静默忽略。
- URL、ref、commit、recipe 和 option 值均按字符串处理;易被 YAML 推断为布尔值/数字的内容需加引号。序列化器保证字符串类型,不借助隐式类型转换传递语义。
- 路径使用 `/` 分隔的相对路径,不允许输出目标是绝对路径或含 `..`。recipe 的跨包源路径属于独立的兼容解析,不能原样成为输出目标路径。
- 未声明字段按下文缺省规则处理;没有部署时间、取包时间等非必要易变字段进入共享锁。
- 不生成目录树哈希,不以源码归档哈希定义包身份或复现版本。锁与 authored 声明的匹配采用规范化后的字段比较。

### 12.3 原生清单

```yaml
version: 1
names:
  emoji:
    url: https://github.com/rime/rime-emoji
    ref: master
order:
  - url: https://github.com/rime/rime-essay
    ref: master
  - name: emoji
    recipe: customize
    options:
      schema: luna_pinyin
  - import: ":preset"
  - self:
      exclude:
        - "scratch/**"
```

names 段可省略,缺省 `{}`;其映射定义本身不产生安装条目。order 中每个条目必须且只能具有一种主选择器:

| 选择器 | 形式 | 可选字段 |
|---|---|---|
| 用户树 | 标量 `self`,或 `self: {include: [...], exclude: [...]}` | include / exclude |
| 短名 | 标量短名,或 `name: <短名>` | ref / commit / recipe / options / include / exclude |
| 直连包 | `url: <URL>` | ref / commit / recipe / options / include / exclude |
| conf 导入 | `import: <内置名、输入域相对路径或 HTTPS URL>` | variables |

- `self` 为保留名。manifest 存在时按其 `order` 原样执行,不隐式插入 `self`;可声明零次或多次。仅无 manifest 时缺省为 `[self]`。
- `ref` 是分支/tag 请求,缺省为仓库默认分支;`commit` 是完整 commit 直引,与 `ref` 互斥。无歧义需要时使用 `refs/heads/...` / `refs/tags/...`。明确指定 commit 后,update 不前进该条目。
- `recipe` 缺省遵循既有选择顺序;`options` 为字符串映射,缺省 `{}`;不是 shell 命令或脚本片段。
- `include` 缺省选择完整候选文件集,`exclude` 缺省 `[]`;存在 include 时先取候选集交集,再排除 exclude 匹配项。匹配对象为规范化后的输出相对路径;对补丁目标应用同一过滤规则,不通过补丁绕过过滤。
- glob 格式需统一定义:以根相对路径匹配,`*`/`?` 不跨 `/`,`**` 可跨目录;候选来自白名单/recipe 或用户树,include 不扩大原始候选范围。匹配与展开顺序不得依赖宿主目录枚举顺序或 locale。
- import 在该位置展开,每个原生 import 以独立的解释器环境求值;内部重复 `source` 采用解释器语义。`variables` 为显式字符串映射,用于 conf 求值;库设置的虚拟 `root_dir` 不允许覆写,不隐式继承宿主进程环境。

### 12.4 短名表与本地覆写

```yaml
# pinewind.local.yaml
version: 1
names:
  emoji:
    url: file:///Users/me/dev/rime-emoji
```

- 合并次序:manifest.names → 本地覆写 names → 条目内联字段,后层胜。短名只用于找声明,不成为缓存或锁的源码身份;本地覆写同样必须有顶层整数 version。
- 沿用**字段级合并**:未出现字段继承;出现字段整体替换,例如 `options` 整个映射替换,不隐式逐键合并。
- 对可选字段,`null` 明确清除继承值:recipe 回到自动选择、ref/commit 清除请求、options 回到 `{}`、include/exclude 回到缺省。最终必须有非空 URL,ref 与 commit 不得同时有效。
- `file://` 表示实时本地文件树,不强制要求 git 仓库,不取包也不读取 HEAD;继承的 ref/commit 不参与本地树版本判断,不 hash 本地目录,编辑后可直接重新组合。
- 不生成本地锁。先验证共享声明与 pinewind.lock,再把本地覆写应用到执行计划;共享锁只根据 manifest(包括其 names 段)生成,不被本机调试改向改写。
- 本地覆写未改变远端来源与 ref/commit 请求时可继续使用已锁源码版本;改为其他远端时可直接在覆写中指定 commit,使用浮动 ref 则在开发模式解析为本次 commit。
- 开发覆写启用时不承诺仅凭共享输入 commit 与共享锁复现本机结果。本机解析结果可留在会话或可抛弃的私有缓存中,不新增输入域文件;增量失效语义见 §13。

### 12.5 解析锁的语义(不承诺内部格式)

pinewind.lock 只对外承诺解析结果与操作语义。下列信息由库内部表示,不是文件字段或序列化格式规定:

- 有序包应用及其规范化源码 URL、原始版本请求和最终 commit;同一 URL 可多次出现,不同 ref/recipe/options 不合并为同一条目。
- 短名展开后的有效元数据与过滤规则,以及每个 import 的选择器、显式变量和完整有序展开结果。compose 消费锁中的展开结果,不重新下载可变远程 conf 来检查变化。
- 独立下载资源的来源 URL、落盘相对路径和内容版本校验值。不记录缓存绝对路径、镜像 URL 或非必要取包时间。

共享声明与锁的匹配采用规范化后的字段比较,不计算声明或目录树哈希;显式 commit 必须匹配,自动解析的 commit 不是用户请求字段。import 的来源变化通过显式 resolve/update 重新求值;锁内的展开结果在此之前保持固定。

同一源码的同一 ref 在一次解析事务中只解析一次,避免请求之间分支移动。缺省 recipe 可由锁定 commit 的文件推导,不必把 recipe 内容重复塞进锁。纯 self 的声明变化也参与共享计划匹配;没有远程包/import 时不要求先生成锁。

新增远程条目未锁定或共享声明与锁不匹配时,compose 报告需要 resolve,不自动联网或改锁。resolve 保留仍匹配的条目所锁版本,为新增/改变的声明解析;update 重解析指定范围的 ref/import/独立资源。fetch 按锁取回,compose 从执行计划与已准备资源组合,sync 只部署结果。本地覆写遵循 §12.4。

**已确认:独立下载资源固定版本。** 仓库 commit 不约束 download_files 的独立资源。v1 对每个此类资源记录来源、包准备视图内的安全相对路径与实际落盘字节的 SHA-256 校验值,不对内容作换行或编码归一化;同一条目不允许多个下载占用同一路径。这是资源版本约束,不用于源码归档复现。

- 首次 resolve 下载并记录校验值;后续 resolve 保留仍匹配的资源记录,仅为新增或改变的资源声明建立新记录,不因同一 URL 返回新内容而刷新已有校验值。
- fetch 按锁下载或命中内容缓存,校验不符即失败,不接受新内容、不自动改锁。源 URL 已变化且旧内容不在缓存时,报告锁定资源无法取回。
- update 可更新指定范围的资源,即使仓库 commit 未变也可更新资源版本;完整解析与下载成功后才提交新锁。
- 资源在条目专属准备视图中覆盖源码,不修改共享 commit 源码缓存;compose 只消费准备好的资源。本地调试 recipe 若改变资源声明,在本次开发计划中重新解析与校验该资源,不写共享锁;普通本地文件编辑不重新下载或计算资源校验值。
- 独立资源 SHA-256 承担资源版本约束;归档 SHA-256 仅承担本机下载缓存校验,同一 commit 的归档重生成不会因此改变包锁。

### 12.6 每目标同步状态(私有存储)

此处只规定职责与恢复语义,不规定文件名、后缀或序列化布局。库需要保存:

- 状态绑定的本机目标,位置由调用方注入;不得拿另一目标/机器的状态作为本目标删除依据。Pteromyini blue / green 各自保存状态。
- 上次成功同步的受管文件路径集合;只拥有文件,不拥有整个目录。删文件后仅清理空目录,不递归删除未受管内容。
- 同步中的待恢复计划及其不可变源文件视图。它们不进入共享锁,也不是用户配置文件。

新组合提供本次文件集,删除集 = 上次成功文件集 − 本次文件集。compose 不修改部署状态,成功 sync 才提交新账本。新结果与既有未受管文件同路径时默认冲突,明确接管由调用方参数授权;运行产物始终受保护。

目标中的受管文件是部署副本,后续 sync 以声明和输入域为准;不要求记录历史文件哈希或自动合并目标编辑。

开始写目标前先预检冲突、准备事务专属的不可变文件视图并持久化计划;旧账本仍代表上次成功状态。中断后依同一计划继续,新创建文件仍有归属记录;同目标操作互斥,未恢复前不启动新同步。

全部文件操作成功后原子提交新账本,再清理事务视图。待恢复源视图缺失时报告需要修复状态,不继续删除目标文件。v1 默认向前恢复,不承诺自动回滚目标目录。

### 12.7 下载与执行缓存元数据(私有存储)

缓存内部记录下载对象的来源、字节校验值和完整状态;实现可采用索引、数据库或其他存储,不规定每个下载对应一个独立 receipt 文件。归档校验不遍历或 hash 解包目录树。

归档缓存损坏时按锁定 commit 重取;新归档字节校验值不同不改包锁。只有完成下载与必要解包的对象才可命中,ETag/Last-Modified 仅作为传输优化。

增量组合的计划、来源依赖、局部变更记录与可复用中间结果也属于可抛弃私有缓存,不进入 pinewind.lock;缓存缺失或版本不兼容时可全量组合。具体存储结构不在本阶段承诺。

### 12.8 本轮需确认的取舍

- include/exclude 是否同时过滤补丁目标(本草案推荐是)。
- 每目标部署状态与向前恢复语义是否按 §12.6 定案,内部存储格式由实现确定。
- I2/I5 对本地开发模式与来源不可取回时的适用范围需统一描述,不把缓存可重建等同于远端永久保留旧资源。


## 13. 增量取包与组合的预设计(建议契约)

本阶段应先保证全量与增量执行使用同一套语义,并为来源依赖与失效留出接口;不用现在定存储布局、目录树哈希或完整的增量算法。以下元数据全部属于私有状态,不改变 pinewind.lock 的公开承诺。

### 13.1 全量组合是正确性基准

给定相同锁、有效声明与本次读取的源文件快照,增量结果必须与全量组合一致,包括删除、覆盖、Rx 替换与有序补丁。复用只能跳过已证明仍有效的工作;不能把“读旧输出再补一下”作为组合语义。

本次执行中的计划、文件选择与补丁读取绑定同一份已准备快照,不在不同阶段混用变化前后的输入。缓存缺失、失效依据不充分或中间版本不兼容时退回全量组合,不影响语义。

### 13.2 分开规划与执行

resolve/update 产生解析结果;fetch 准备源码与独立资源;compose 先形成有序操作计划,再决定哪些操作重算、哪些结果复用。操作至少区分整文件写入与对目标文件的补丁。

计划知道每项操作的条目位置、源文件、目标路径、有效参数及前后依赖;可新增/移除的输出也在计划内。逻辑模型先定义,不必现在暴露 Swift 类型布局或持久化 schema。无变化时可返回既有已发布结果;有变化时准备候选结果,验证后发布。

### 13.3 为每个输出保留完整来源与有序操作链

仅记录最终获胜 URL 不够。需要知道一个目标文件的各次写入/补丁来自哪个条目,以及它们的次序;同一 URL 的多次出现必须分别参与排序。

例如 A 写入 x.yaml,B 随后覆盖 x.yaml:移除 B 后,结果应恢复 A 的内容;不能只把旧的 x.yaml 删除。对某条补丁的修改/撤销同样需要从适当基底重放剩余操作,不能假设可以从合并后的文件反向恢复。

文件内容可从**新计划中的最后一次整文件写入**开始,按序重放后续补丁。更早、已被覆盖的内容变化可不触发该路径重算;新增/删除/重排条目时必须重新确定获胜写入与后续补丁链。若没有整文件基底,按 §6.2 从空的补丁目标创建语义开始。

### 13.4 显式记录依赖与失效条件

| 变化 | 至少需要重查的工作 |
|---|---|
| URL / commit / 独立资源版本 | 对应源码准备视图,及使用它的选择/写入/补丁操作 |
| recipe / options / include / exclude | 该条目的文件选择、目标路径与补丁操作;同时考虑旧路径退出与新路径进入 |
| 条目新增、删除、重排 | 受影响路径的获胜来源与补丁顺序,以及依赖被变更条目的跨包引用 |
| 本地文件修改 | 读取该文件的操作及依赖它的目标 |
| 本地文件新增、删除、改名 | 对应目录/glob 的匹配集合,以及输出的新增/删除/来源回退 |
| 跨包所引用源码变化 | 所有读取该来源的其他条目,即使它们自身 commit 未变 |
| 组合器/recipe/glob/模板语义版本变化 | 使用旧语义生成的私有执行缓存 |

glob 不只依赖上次匹配到的文件,还依赖搜索范围与模式;否则新增匹配文件会漏入结果。跨包引用也不能仅依赖消费者自身 commit,必须绑定实际引用的源码快照/本地文件。

### 13.5 区分不可变来源与本地可变文件

- 远程源码复用依据为规范化 URL + commit;独立资源按已确认的版本校验值复用。后端/镜像变化不凭空改变源码身份,解包/准备语义变化则使相应私有缓存失效。
- 本地 file:// 与 self 不生成内容锁,不计算目录树哈希。变更通知和文件元数据可用于缩小检查范围,不能在漏事件或证据不足时当成内容未变的证明;必要时重新枚举相关目录、直接比较源文件字节或重算受影响项。
- 变更记录需覆盖新增、修改、删除与改名;目录路径集合的变化也要被观察。调用方传入的变化集合可以作为优化提示,不能使实际输入变化被静默忽略。
- 复用中间结果还需比较操作参数、补丁基底与执行语义版本;commit 相同不代表不同 recipe/options 或不同排序的组合结果相同。

### 13.6 发布与同步只提交完整结果

增量结果在未发布的候选代次中构造;可复用已发布的不可变文件,但任何补丁/写入前必须获得独立可写副本,不通过硬链接修改仍在使用的文件。

全部成功后原子发布候选结果及其文件集;失败时保留上一份完整结果与成功账本。sync 根据新旧文件集计算新增/修改/删除,没有变化的路径可跳过写入,事务恢复仍遵循 §12.6。并发 compose/update/sync 不能相互覆盖同一份正在构造的状态;具体锁与代次机制由实现期选择。

### 13.7 后端接缝与 v1 实现边界

取包后端的组合层契约是“按锁定源码准备可读取的完整快照”(§5.2 prepareSource),HTTP 归档或 git/libgit2 如何取得该快照属于后端实现,不要求所有后端都返回 tarball。来源间差异可以作为可选优化信息,不是必需输入。

需区分三类增量:

- **取包复用**:不重新下载已完整缓存的 URL + commit,独立资源缓存命中时不重取;v1 可做。
- **增量传输**:从旧 commit 只取变化对象,由 git/libgit2 等后端后续提供;HTTP codeload v1 不承诺新 commit 的差量下载。
- **增量组合与同步**:复用未受影响的输出/中间结果,重放受影响路径的操作链,只写变化的目标;可在全量组合模型之上逐步实现。

本阶段必要交付是操作计划、来源/依赖与失效边界、完整结果发布契约。实现可先支持取包缓存与无变化直接返回,再增加按路径重算;无需现在承诺任意操作下的最小重算集。

### 13.8 验证方向

实现期用同一输入的增量结果与全量结果做差异核对,覆盖删包后来源回退、顺序调整、补丁撤销/同 Rx 替换、glob 新增匹配、跨包源变更、本地编辑与缓存丢失。比较实际输出文件集与内容即可,不引入目录树哈希作为正确性契约。
