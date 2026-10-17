# 松风 / Pinewind:错误系统设计

状态:2026-10-17 错误边界迁移版。顶层结构与类型命名已实现;标注"到实现中验证"的条目留待后续裁决。本文是错误面的唯一权威,与《Package-Management-Design》(工作区与存储契约)并列。

## 1. 服务对象与总原则

错误系统为"配置解析 → 依赖获取验证 → 部署"这条管线服务。事实词表的域枚举的是**管线的题材**(文档、依赖、内容、部署目标的世界),不是管线的**执行装置**(锁、队列、协调机制)。

一个错误事件包含三个正交关注点,错误值同时回答:

- **事实**(什么发生了):单一事实词表,按域分组;
- **归因**(处理者去哪行动):文档锚点 / 无锚点;
- **因果**(为何):由事实类型的结构化字段承载,类型化、稀疏,禁止 `any Error` 万能口子。

消费者三类——文档修复者、环境修复者、库开发者——各取所需,载荷按此配置。

## 2. 顶层结构

```swift
enum PinewindError {
  case configuration(DocumentError)  // 裁决:文档有错,位置是事实主体
  case incident(DocumentError)       // 事件:处理途中发生,归因未判,位置是目击锚点
  case runtime(Failure)              // 无文档锚点的机器失败
}

struct DocumentError {
  let context: DocumentContext       // 文档身份与定位(§4)
  let failure: Failure               // 单一事实词表(§5)
}
```

- **configuration**:对声明内容的裁决。"order 第 2 项引用了未定义的名字"中,位置与违规是同一事实,拆开即不成立。包含 schema 级检查(字段有效性、结构、命名、约束)与经执行才得知的裁决(ref 不存在、声明的文件缺失)。归因准则:修复动作发生在文档 ⇒ configuration。
- **incident**:处理某声明的途中发生的失败,位置可指但不能(确定)归为文档错误——认证失败(对内容零蕴含)、下载 404(归因现场不可判定)。位置在此是**目击锚点**而非裁决对象。对归因不可判定的 kind,case 承载失败点的现场归因决定;该 case 由此不是 payload 可推导的冗余 tag。
- **runtime**:无文档锚点的机器失败(如部署目标目录不可写)。

两条属性纪律:

- 事实 kind 的**内容关联性是静态属性**:"ref 不存在"蕴含"声明的 revision 无法满足";"认证失败"对内容零蕴含。零蕴含者永不构成 configuration 裁决,也永不进入其他事实的因果位。处理者对机器事实的分类(瞬态/永久、凭据/名字/网络)据此只写一次。
- **位置附着是动态属性**:同一认证失败,解析某条 revision 途中发生则带锚点,部署阶段发生则裸奔为 runtime。附着与否由失败点上什么在途决定,事实类型不变。

## 3. 定位进错误,无平行验证通道

YAML/conf 定位信息是错误载荷的一部分,不设独立 validation 通道:

- 语义错误只在真实求值/准备逻辑执行到相应位置时才显形,前置静态校验要么漏报,要么复抄一遍求值逻辑;
- 定位随求值逐层累积(解析点取节点 mark,求值层路过自己的条目时当场附着),只有错误值能承载这种沿途累积;
- "收集不中断"与"立即中断"是同一错误值的两种消费姿态。

诊断不设平行类型:批量结果就是同一词表的数组。

## 4. 文档上下文(DocumentContext)

- **双身份**:本机 `FilePath`(服务此刻的修复者,编辑器直接打开)+ `URL`(本机 file URL 或远程身份,服务跨机器审计与同步——报告随 lock 同步到他机后本机路径失效,URL 身份仍在)。锚点纪律:**有本机文档可开才锚;凡锚定,双身份齐备**(锚定远端 conf 时本机路径为捕获快照路径)。
- **定位**:行/列/范围,IDE 惯例,直接指向文档内文本。**无字段路径**——字段路径复原为文本位置必须重过解析器,违背位置的存在意义。文档级失败(外部修改、格式不兼容)只锚身份、不带定位;定位存在时行列必填,范围尽力而为(容器节点的结束位置未必可靠,可空);行列均从 1 开始,列按 UTF-16 code unit 计数;Yams 的 Unicode scalar 列在解析边缘转换。消费 LSP 时行列分别减 1。语法错误直接提取 Yams mark,展开后 YAML 的错误归回原始模板节点,不暴露生成位置。
- **正向附着**:位置在解析时从节点 mark 取得,求值层路过自己的条目时当场附着;废除事后按字段名回查节点重建行号的机制。
- **推导链**:include/import 链是一次归因的**嵌套路径**,不是并列归因——context 含主定位 + 可选的推导帧序列(外→内,每帧为真实行列),跳到中间帧即可移除引入点。推导链与下条的单定位不变量不冲突。
- **单定位不变量**:一个错误至多一个主定位。并列的多处归因(约束涉及两个文档)拆成多个错误对象各自锚定,即使语义相关、即使丢失关联标识。
- incident 与 configuration 复用同一 context 类型:字段路径废除后,身份 + 定位对"在途声明"全部有效,无需变体。
- 事实与 context 的边界:context 答"何处"(文档身份与定位),fact 答"什么"(含违规值本身——`unknownName` 的名字是事实载荷,不是 context)。

## 5. 事实词表(Failure)

单一词表。enum,case = 领域,各领域 payload 类型自理(struct 或内嵌 kind enum 按需决定):

| 领域 | 收纳(例) |
|---|---|
| git | ref 不存在/歧义、认证失败、commit 不可用、传输失败、tree 条目非法(非 UTF-8/路径逃逸/符号链接) |
| file | 缺失、权限、类型不符、符号链接越界、原子交换不支持、Windows 发布/junction 机制错误 |
| network | 资源下载:HTTP 状态拒绝、传输失败、非 HTTPS、下载超限 |
| interpreter | conf 求值失败、超时、include 预算超限、不支持的结构 |
| declaration | 保留名、未知名、URL/commit/revision 形态、schema 结构违规、重复目标、约束冲突 |
| lock | lock 文档编解码:格式不兼容、记录损坏、声明已变需重解析 |
| state | 会话协调:文档被外部修改、输入陈旧、发布竞争 |
| cache | 资源缓存:内容缺失、校验和不符 |

纪律:

- 词表对归因无感知——不得为某个顶层 case 定制领域变体;同一事实跨 case 复用(认证失败在 incident 带锚点、在 runtime 裸奔)由单一词表天然保证。
- **深层直接抛事实**:单域函数抛领域类型,跨域纯函数抛 `Failure`;到归因边缘再构造 `PinewindError`。`runtime` 主要表达没有文档锚点的结果,避免依赖中间层先装箱再补归因。
- **归因显式选择**:`attributed(to:as:)` 区分 `.configuration` 裁决与 `.incident` 目击。领域事实的 `allowsConfiguration` 只表示裁决资格,不自动选择归因;认证、网络、协调、缓存和文件操作失败即便请求裁决也只附为 incident,defect 保持 runtime。已有主定位原样保留;外层通过 `addingDerivation(_:)` 单独加入引入帧,外层在前。
- 限额不立独立域,按主题归域:下载超限进 network(携带上限值字段),include 预算进 interpreter。
- 待实现验证的归属:进程锁装置损坏(锁工件非常规/打不开)归 file 还是独立协调域;lock 编解码独立还是并入 declaration;cache 独立还是并入 file。裁决依据:到实现中看调用层次是否需要转换关系。

## 6. 渲染

无 message 字段。每个类型的 `description` 由结构化字段推导(CustomStringConvertible),措辞是该类型自己的排版职责。承载 origin 的类型渲染 origin——它的读者本就是开发者。

## 7. 宏 origin(#fileID/#line)

判据(默认启发):**可行动消费者是库开发者的错误才承载 origin**——内部不变量/一致性失败(不该发生的分支被命中)、边界包装兜底(外来错误进入词表的关口)。按裁决放宽:每个具体错误类型自行决定是否承载;边界函数直接声明 `fileID: String = #fileID, line: UInt = #line`,再构造 `Origin(file:line:)`;转调辅助函数时显式转传这两个参数。不得使用嵌套的 `origin: Origin = Origin()` 默认表达式,否则位置会固定在辅助函数声明处。已归一化的错误保持首次 origin。

世界事实的站点可区分性义务由结构化字段承担(操作身份、对象身份)——同一 kind 多站点分不清时补字段,不撒 origin。

外来错误兜底装 `String(describing:)`:有损但自包含、可跨边界;不留 `any Error` 万能深挖口子,需要结构化时按需增设专属 kind。(倾向记录,随实现定。)

## 8. 层次与边界翻译

- 执行装置的内部机制细节(获取策略、重试记账、队列状态)不进词表——装置失败说的不是"题材世界怎么了"。
- **竞争不是错误**:非阻塞获取 + 轮询等待的装置,竞争以等待与取消语义收场,不产生错误值。
- 每个抽象层拥有自己的错误类型,内部子系统的错误类型不逃逸;在依赖边缘被**显式翻译**成上层词表的题材事实。翻译允许有损,低于上层分辨率的细节有意丢弃;翻不出的装置语义以取消/中断收场。
- 装置损坏若构成题材陈述(受管锁工件处于损坏状态)按题材检验归域,到实现中验证。

## 9. 批量与签名

- **查询型批量**(validate:找出文档全部问题):返回值 `-> [PinewindError]`。找出问题是询问的成功回答,不是控制流异常;致命失败(文档本身读不出)同样以错误值入数组,不区分第二通道。
- **管线型批量**(独立单元的执行):收集后抛聚合容器。聚合是独立类型(如 `failures: [PinewindError]`),不是词表 case——单复数是基数差异,塞入词表会迫使每个单数匹配顺手排除聚合。批量只出现在操作主动声明单元独立的签名上;失败相关的操作首错中断。
- typed throws:事实层的签名携带**层级最底层的具体类型**——单域链路用域类型(`throws(FileSystemFailure)`/`throws(DeclarationFailure)`…),跨域事实函数用 `throws(Failure)`,抛出点直接抛词表值;归因边界(解析/求值/文档方法/lock 解码)不标注顶层类型,以普通 `throws` 承载 PinewindError——类型系统不做 Failure⇄PinewindError 隐式转换,跨域归因边界强行标注只会制造全量 do/catch 噪声,归因语义由构造点保证。被取消(CancellationError)或外来错误(Foundation/Errno)污染的签名保持 untyped。公共操作边界(Workspace、配置会话、公开文档方法及默认后端)共用 `ErrorBoundary.normalize`:取消原样穿透,已有 `PinewindError` 原样返回,所有领域错误和 `Failure` 归位 runtime,未知错误入 defect。归一化保持幂等,取消以外的管线错误恒为 `PinewindError`。执行队列只转发,不提前归一化;取消检查不在提交完成后补做。

## 10. 迁移

2026-10-16 完成:旧 struct + Code 体系(14 个统一五字段 payload)已整体替换为本文结构;诊断平行类型(Diagnostic)与字段路径回查机制(relabeled)删除。归因范围 v1:解析与求值边界锚定文档身份+mark 行列;求值内部的条目级归因(锚到具体 order 条目)需要位置随求值管线下传,留待后续。传输层失败落 network.transportFailed(现为 url:reason:detail:),不走 defect 兜底。词表展开顺序建议:declaration → git/file/network → interpreter/state/lock/cache。

## 11. 归一化与迁移约定(2026-10-17)

三种转换各司其职:

1. **外部错误翻译**在依赖边缘完成,保留操作和对象身份。相同的不存在错误,可选配置读取可返回 nil,明确声明的缺失由声明边缘裁决,普通 I/O 失败进 file 域。
2. **机械装箱**只有一份 `Failure.recognizing` 类型表。`ErrorBoundary.normalize` 负责取消穿透、已有错误保持与未知错误兜底,不推断文档责任、不检查错误文本、不以 Task.isCancelled 覆盖已发生的其他错误。
3. **文档归因**由持有真实文档上下文的边缘显式选择。共享仓库声明解析可作裁决;有效配置的开发准备仅把共享文档作为目击锚点。没有可打开的声明文档时保留 runtime。

`FileIO.perform` 只翻译预期的原生文件错误,其他领域错误、取消和未知错误原样穿过。文件操作使用 `FileSystemFailure.operationFailed(FileOperationFailure)`,携带操作、路径序列、`SystemErrorCode` 和展示 detail。copy/move 路径按源、目标排序;协调失败列出全部请求路径。网络传输携带 `TransportFailureReason`,Git 操作携带 operation,资源校验失败携带 URL、预期与实际 SHA-256。编码内部锁数据失败属于 defect,解码输入损坏才属于 lock.malformed。

迁移公开消费代码:

- `promoted(context)` 改为 `attributed(to: context, as: .configuration/.incident)`;已有主定位不变,引入帧使用 `addingDerivation`。
- `GitFailure.operationFailed` 增加 operation;`NetworkFailure.transportFailed` 增加 reason;`CacheFailure.checksumMismatch` 改为具名 url/expected/actual 载荷。
- 文件错误消费需处理新增的 operationFailed;旧的路径约束事实和锁装置事实仍保留。
- 文档及归因方法改为普通 throws;内部删除 embed/wrap/relay。纯校验继续使用具体 typed throws。模板的选项失败为 `Failure.declaration`,正则/替换范围不变量失败为 `Failure.defect`,不再提供 invalidTemplateRange 声明错误。

条目级求值位置与解释器内 include 的逐帧定位仍遵循 §10 的边界:本次提供显式归因和推导链操作,不通过重新查字段或生成 YAML 伪造缺失的位置。
