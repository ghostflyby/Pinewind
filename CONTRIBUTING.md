# 贡献指南

所有源码、测试、文档、依赖和工作流变更都通过独立分支与 Pull Request 提交,不直接推送 main。PR 说明修改目的及相关验证结果。

## 本地检查

```sh
xcrun swift-format lint --strict --recursive Sources Tests
swift test --no-parallel
python3 Scripts/check-api-boundaries.py
git diff --check
```

公开 API 消费测试位于 PinewindAPITests,不使用 @testable;核心组合回归通过测试夹具适配器保留 URL 资源夹具。编译契约脚本需要先构建,验证受管 FilePath 边界及不可任意构造/解码的阶段类型。

默认测试不联网。需要验证真实 GitHub HTTPS 取包时,显式启用联网用例:

```sh
PINEWIND_NETWORK_TESTS=1 swift test --filter GitKitFetcherTests
```

Corelibs Foundation 不支持为自定义 URLProtocol 创建下载文件,因此成功下载与 HTTP 状态的模拟测试仅在 Apple Foundation 上运行;传输错误、取消和注入下载后端的资源测试在各平台运行。

纯文档修改检查内容、链接和差异;修改示例时核对其可用性。行为变更运行相关测试,必要时补充回归用例。修改配置或组合语义前,核对 [设计契约](Docs/Package-Management-Design.md)。
