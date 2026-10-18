# 松风 / Pinewind: 错误处理与诊断

状态: 2026-10-18,开放错误协议与本地 lint。

## 1. 开放错误类型

`PinewindErrorProtocol: Error, Sendable, CustomStringConvertible` 是可选的公共能力,不要求所有外部错误加入封闭词表。人类可读输出复用 `description`;具体类型也可按需遵循 `LocalizedError`,不另设描述转换协议。

```swift
public typealias CodablePinewindError = PinewindErrorProtocol & Codable
```

Codable 是具体类型的能力,不要求基础协议可编码。编码直接保留原类型结构,不经过统一的诊断 DTO,不使用 Mirror,不通过错误文本猜测类型。

`Failure` 总枚举已删除。单域函数可以继续使用具体 typed throws;涉及不同原因的函数使用普通 throws,不为统一签名复制外部错误分类。

业务规则仍有自己的类型,例如 DeclarationFailure、InterpreterFailure、LockFailure、StateFailure、CacheFailure。文件路径约束、Git 引用和资源限额等 Pinewind 自己识别的事实仍保留。它们不必替外部库穷举所有可能错误。

## 2. 原始原因与操作上下文

错误值保存真正缺少的信息:

- `FileOperationFailure<E>` 保存 operation、paths、原始 cause;`FileOperationErrorProtocol` 提供不依赖 E 的只读检查入口。
- `ResourceTransferFailure<E>` 保存 URL 和原始传输错误。URLError 的 code/userInfo 等信息仍在原值中。
- `DocumentError<E>` 保存 DocumentContext 和具体 failure。`DocumentErrorProtocol` 提供 context 和 underlyingError,供 GUI、lint 和异构集合检查。

泛型包装器分别条件遵循 Encodable/Decodable,条件来自其原因类型;可比较性也只是具体类型的可选能力。不存在把任意错误强制变成 Codable 或 Hashable 的存在容器。

Errno、URLError、Yams.YamlError、SwiftBash.FileSystemError 按需遵循公共协议,不复制成另一组一一对应的枚举。Errno 保持原有 Codable。Yams 的原始错误、Context、Mark 获得原字段的 Encodable 实现;Context 没有公开构造入口,因此不声称支持 Decodable。不提供任意外部错误类型的自动恢复注册表。

URLError 的 CustomStringConvertible 和 Yams 类型的 Encodable 属于外部类型对外部协议的追溯符合。上游以后加入相同符合时可能发生冲突,升级依赖或工具链时需要检查并移除对应适配。Yams 解析错误的关联位置编码为 `mark`,包含 `line`、`column`。

文件操作不再压平为 SystemErrorCode;网络传输不再压平为 TransportFailureReason。显式识别的 HTTP 拒绝、HTTPS 约束和资源上限仍是 Pinewind 的业务事实。

## 3. 归因与位置

`PinewindError` 只表达三种归因,不穷尽底层类型:

```swift
enum PinewindError {
  case configuration(any DocumentErrorProtocol)
  case incident(any DocumentErrorProtocol)
  case runtime(any Error)
}
```

configuration 是对声明内容的裁决;incident 是处理声明途中观察到的事件;runtime 没有文档锚点。归因由拥有操作上下文的边界明确赋予,不由错误类型全局决定。例如 Git 引用不存在可以归因于所请求的声明;认证或传输失败只能是观察到的事件。

DocumentContext 保留本机 path、来源 URL、可选 placement 和推导链。位置来自原文节点或解析器位置,行列从 1 开始,列按 UTF-16 计算。URL 采用绝对身份,编码路径使用可表示的 Unicode 文本,解码不重新读取当前目录。不能无损表示的路径明确编码失败。

没有原文位置时不能伪造行列。配置编辑的表单字段与操作序号属于 ConfigurationDiagnostic,不是 YAML 位置。模板生成内容的错误重新归因到原始模板节点,原始原因仍保留。

由于归因容器持有开放存在值,`PinewindError` 不冒充 Codable 或普遍 Equatable。需要结构化输出时编码其中保留具体类型的文档包装器。

## 4. 边界规则

- 未识别的外部错误保留原值和身份,不自动变为 Defect。
- Defect 只由明确发现内部不变量或实现错误的代码构造,保留开发者 origin。
- 取消保持 CancellationError;URLSession 的取消在传输边界转换,不成为 lint 诊断。
- 已有主归因不被后续边界覆盖;推导链按外到内附加。
- 当前机械归一化保持原值、保持幂等。没有转换需求的类型无需实现归一化方法;以后如需引入转换,也只在有语义的边界进行。
- 不要求所有错误 Hashable。诊断仅在具体原因支持比较时去重;不以 description 充当错误身份。

## 5. 编辑和提交

`Workspace.validate(editing:)` 与 `ConfigurationSnapshot.validate()` 继续用于内存候选检查,返回 `[ConfigurationDiagnostic]`。字段检查与真正求值共用规则,每条诊断保留操作序号、包名、表单字段和归因错误,不生成假的 YAML 行列。

ConfigurationValidationError 表示整批候选在配置预检中被拒绝,携带 diagnostics。编辑器方法不抛配置错误,失败编辑保留诊断,独立编辑继续检查。配置错误或解析失败不提交。

PreparationFailure 保留已提交的 Resolution 和原始 `cause: any Error`,只表示提交后的准备失败。它不为了序列化而删除恢复所需的运行时信息,也不声称支持 Codable。调用者可通过 install 重试。取消后可查询 configuration/status 判断已提交状态。

声明、本地覆写和 lock 的持久化事务契约见 Package-Management-Design。错误协议调整不改变协作读者的恢复规则或外部修改保护。

## 6. lint

`Workspace.lint()` 使用本机已有信息,返回 `LintReport`。它不解析 Git 引用、不下载包、不执行 conf、不准备文件、不构建输出。

始终检查共享声明和本地覆写的 YAML 结构及内部语义。原始节点与值在同一收集过程保留;字段、选择器、名称、导入来源与求值共用现有规则。独立字段、条目、文档和 recipe 部分继续检查;前置问题使后续无法判断时跳过依赖检查。

只有带真实 YAML 位置的 configuration 裁决进入 diagnostics。内存编辑的字段问题、网络、认证、缓存损坏和协调故障不被强行附到 YAML 上。读取等操作性故障通过正常 throws 报告。

本机信息是可选证据:

- 缺少 lock、源码或缓存不是 lint 错误。
- 已有 lock 可以提供已知 commit 和 import 展开;陈旧、不兼容或损坏的二进制记录不能建立 YAML 裁决,不据此误报配置。
- 已有本地源码和受管源码快照中的 recipe 会被检查。源码尚未取得时跳过;源码已存在而显式指定的 recipe 缺失时,诊断指向原声明的 recipe 节点。未指定的默认 recipe 可以缺省。仅由 lock 展开、没有原始 YAML 选择器位置的显式 recipe 缺失通过正常 throws 报告,不伪造位置。
- 已有锁定 YAML 资源仅在字节符合校验和时检查语法。损坏缓存不被误判为作者的 YAML 错误。
- 不扫描与当前声明无关的缓存条目,不因缺少其他包而猜测依赖错误。

CLI:

```sh
pinewind lint
pinewind lint --format json
```

成功且没有诊断返回 0;存在诊断或操作/输出失败返回非零。取消沿用 130。

LintReport 只承诺 Encodable。JSON 外层有 version 和 diagnostics,每个错误保留自己的编码结构。文本复用 description。JSON 在内存中完整编码成功后才写 stdout;不可编码的错误明确导致输出失败,不静默遗漏,不降级成描述字符串。错误写 stderr。

lint 不提交新的配置或 lock,也不创建个人源码目录。它仍使用 Core 的文件协调,可能创建协作锁或恢复此前已持久化的事务;不是绕过恢复契约的原始磁盘读取器。
