# MacClean

原生 macOS 磁盘分析、清理与系统维护工具。支持 Apple 芯片和 Intel，需 macOS 14 或更新版本。

## 使用与许可

从 1.6 起，个人和企业内部使用均免费；全部功能开放，无试用期限、设备数限制或激活要求。内部修改与部署也免费。

对外销售原版、修改版，或将代码集成到收费产品中，需要另行取得付费商业授权。免费分享需保留许可和第三方声明，修改版需注明改动。具体条款见 [LICENSE](LICENSE)。这是源码可用的社区许可，不是 OSI 开源许可证。代码仓库目前保持私有，尚未公开源码。

官网：<https://thulem.com/> · 下载：<https://thulem.com/download.html> · 商业授权与支持：<https://thulem.com/support.html>

## 开发

使用 Xcode 打开 `MacClean.xcodeproj`，选择 MacClean scheme 构建。命令行构建需将 `DEVELOPER_DIR` 指向完整 Xcode。发布步骤与当前签名限制见 [RELEASE.md](RELEASE.md)。网站及后台位于 `web/`。

扫描与清理在本机执行；匿名使用统计默认关闭，可在设置中选择开启。路径保护、危险操作确认和系统权限检查不受免费策略影响。
