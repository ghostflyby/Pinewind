# 开发与维护

## 变更流程

所有内容变更,包括源码、测试、文档、依赖和工作流,都通过独立分支和 Pull Request 提交,不直接推送 main。PR 说明修改目的及相关验证结果。纯文档修改检查内容、链接和差异即可;涉及行为或示例变更时,执行对应验证。

## 本地验证

```sh
xcrun swift-format lint --strict --recursive Sources Tests
swift test --no-parallel
git diff --check
```

Git 后端测试通过 libgit2 创建本地仓库,默认不联网、不调用 git CLI。显式运行真实 GitHub HTTPS 取包回归:

```sh
PINEWIND_NETWORK_TESTS=1 swift test --filter GitKitFetcherTests
```

多文件场景位于 `Tests/PinewindCoreTests/Fixtures/<场景>/`,用 `input/`、`a/`、`b/` 表达用户输入与包来源。测试目标通过 `.copy("Fixtures")` 保留目录结构,从自己的 `Bundle.module` 读取后复制到独立临时目录;本地编辑、删除和组合都作用于该副本。简单错误用例和大文件生成保留在测试源码中。夹具自行编写,不复制上游数据。

## CI 与发布

[CI 工作流](.github/workflows/ci.yml) 在 main 推送、PR 和手动触发时运行:

- Sources/Tests 的严格格式检查;
- macOS 全包测试;
- generic iOS Simulator 的库与测试目标构建;
- iOS 模拟器运行测试,使用 `Pinewind` scheme,自动选择可用 iPhone 模拟器,上传 xcresult、测试日志和崩溃诊断。

[发布工作流](.github/workflows/release.yml) 在 `v*.*.*` 标签推送时触发,检查标签 commit 是 origin/main 的祖先,构建并运行测试后生成 GitHub Release。发布标签应指向已经通过 PR 合并到 main 的提交。

[Dependabot 配置](.github/dependabot.yml) 每周检查 SwiftPM 与 GitHub Actions 更新,SwiftPM 的 minor/patch 更新分组提交。

架构、实现边界与迁移记录见 [包管理设计](Docs/Package-Management-Design.md)。
