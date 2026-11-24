# 贡献指南

所有源码、测试、文档、依赖和工作流变更都通过独立分支与 Pull Request 提交,不直接推送 main。PR 说明修改目的及相关验证结果。

## 本地依赖(libgit2)

Git 后端经 `Git2` 系统库模块使用 libgit2,通过 pkg-config 解析,**供给由构建者选择**,包本身不感知任何包管理器:

- `LIBGIT2_PKG_CONFIG`:要链接的 `libgit2.pc` 绝对路径(任意来源:下述 vcpkg 流程、Homebrew cellar、自建树)。
- 未设时回退系统 pkg-config 的裸名 `libgit2`(Homebrew、apt `libgit2-dev`)。

**一次一个目的地**:包对 libgit2 只有一个 system-library target,macOS 与 iOS 模拟器各链接一份不同平台的库,靠构建会话的变量值区分。manifest 每次构建都会带着新鲜环境重新求值(编译产物按内容缓存、求值执行不缓存),所以切换目的地 = 换一次变量再构建。**不要**在一次构建会话里对两个目的地用同一变量值,也不要把变量指向另一平台的库——SwiftPM 在此无法检测错配,错误会在链接或运行期才出现。

推荐的 vcpkg 准备方式(manifest 模式,`vcpkg.json` 钉 `builtin-baseline` 随仓库走;此版 vcpkg 工具已不生成 lock 文件,版本钉定即 baseline;manifest install 会把安装树修剪成「host + 本次目标 triplet」,故**每个 triplet 一棵专属树**(`--x-install-root`),即官方 CMake 集成同款机制):

```sh
# macOS 桌面
vcpkg install --triplet arm64-osx-15 --overlay-triplets vcpkg-triplets --x-install-root vcpkg-trees/arm64-osx-15
export LIBGIT2_PKG_CONFIG=$PWD/vcpkg-trees/arm64-osx-15/arm64-osx-15/lib/pkgconfig/libgit2.pc

# iOS 模拟器
vcpkg install --triplet arm64-ios-simulator-16 --overlay-triplets vcpkg-triplets --x-install-root vcpkg-trees/arm64-ios-simulator-16
export LIBGIT2_PKG_CONFIG=$PWD/vcpkg-trees/arm64-ios-simulator-16/arm64-ios-simulator-16/lib/pkgconfig/libgit2.pc
```

设变量的同时建议 `export PKG_CONFIG_PATH=$(dirname "$LIBGIT2_PKG_CONFIG")`:vcpkg 产出的 pc 带 `Requires:`(libpcre/openssl 等),把搜索路径指进树内可让传递依赖就地解析,不依赖具体 pkg-config 实现是否把显式 pc 所在目录纳入搜索(CI 已这样做)。

`vcpkg-triplets/` 提供部署目标钉在包平台下限(macOS 15 / iOS 16)的专属 triplet(名字后缀即下限):stock triplet 不设 `CMAKE_OSX_DEPLOYMENT_TARGET`,会按宿主 SDK 基线产出、与包链接时告警;专属名字同时拥有独立 ABI 命名空间,不与同根下既往安装状态冲突。升级依赖 = 更新 `vcpkg.json` 的 baseline(本地 vcpkg 先 `git pull` 拿新 commit)后重新 install。引用 `PinewindCore` 的消费方同理:export 变量即完全接管供给(动/静态由所选 pc 的 `Libs` 指向决定),不设则走系统回退。

## 本地检查

```sh
xcrun swift-format lint --strict --recursive Sources Tests
swift test --no-parallel
git diff --check
```

公开 API 消费测试位于 PinewindAPITests,不使用 @testable。CLI 仅通过普通 import 消费 PinewindCore,不使用 package、SPI 或 @testable 访问库。PinewindCLITests 通过子进程验证命令与持久化行为,可用 @testable PinewindCLI 检查平台路径。各测试 target 通过 Bundle.module 读取 Fixtures;完整 YAML、recipe、conf 和多文件场景放入资源,短非法输入、动态 Git 提交与大文件在测试中生成。测试助手只负责夹具装配和 I/O 桥接,解析与校验直接调用库实现。

默认测试不联网。需要验证真实 GitHub HTTPS 取包时,显式启用联网用例:

```sh
PINEWIND_NETWORK_TESTS=1 swift test --filter GitKitRepositoryProviderTests
```

Corelibs Foundation 不支持为自定义 URLProtocol 创建下载文件,因此无上限下载任务的目标文件错误测试仅在 Apple Foundation 上运行;有上限的流式下载、HTTP 状态、传输错误、取消和注入下载后端的资源测试在各平台运行。

纯文档修改检查内容、链接和差异;修改示例时核对其可用性。行为变更运行相关测试,必要时补充回归用例。修改配置或组合语义前,核对 [设计契约](Docs/Package-Management-Design.md)。
