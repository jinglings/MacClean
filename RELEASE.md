# 发布清单

## 当前发布状态（2026-10-24）

- MacClean **1.6（构建 7）**：Apple 芯片与 Intel 通用，最低 macOS 14。
- 个人及企业内部全部功能免费；移除试用、设备名额和激活机制。旧版许可记录保留但不再影响新版。
- 采用 [MacClean Community License 1.0](LICENSE)。对外销售、修改后销售或集成到收费产品需另行取得付费商业授权；源码仓库现已公开，官网提供源码入口。不得宣传为 OSI 开源许可。
- 安装包使用 Apple Development 证书签名，尚未完成 Developer ID 签名和 Apple 公证。自动更新因 Sparkle 签名密钥未配置而保持禁用。
- 357 项原生测试通过，含参数化执行共 399 次。52 项网站后台测试通过。18 个中英文页面及 45 个静态目标检查通过。
- DMG 已通过签名、通用架构及镜像完整性校验，实际挂载打开确认为 1.6（7）。设置中无许可页，使用统计默认关闭；系统维护的 DNS 刷新已实际运行成功。
- DMG SHA-256：`c955d290a2e99616b0de52a97a08359c6593bd6228d687c37abdec701c1a1938`，15,145,063 字节。
- 下载地址：<https://thulem.com/download/latest>。发布后需完整下载核对校验和。
- 网站不再显示个人付费套餐；新订单入口返回 410，历史订单、售后与旧版许可服务保留。
- 发布备份：`/var/backups/macclean-web/release-1.6-20261024`（包含一致性数据库快照及发布审计）；网站备份：`/var/backups/macclean-web/usage-20261024T002455Z-2591961`。

## 1. 发版前配置

| 位置 | 用途 |
|---|---|
| `MacClean/Features/About/AboutView.swift` | 官网、隐私、支持与许可链接 |
| `LICENSE` / `MacClean/Resources/CommunityLicense.txt` / `web/site/license.txt` | 三份许可文本需保持一致，DMG 中同时附带原文 |
| `MacClean-Info.plist` | 正式启用自动更新前配置 `SUPublicEDKey` 和 `SUFeedURL` |
| `project.pbxproj` | 同步修改 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` |

## 2. 付费服务兼容

原有订单、退款、许可证及激活数据继续保留，用于历史售后与旧版客户端兼容。新版不再调用许可服务。生产 `salesEnabled` 固定默认关闭，商业分发授权通过单独书面协议处理，不得恢复旧个人套餐作为新版使用门槛。

## 3. 自动更新（Sparkle 2）

1. Sparkle 2.10.0 已内置在 `Vendor/Sparkle/`（框架 + 工具）。运行 `Vendor/Sparkle/bin/generate_keys` 生成 EdDSA 密钥（私钥存在钥匙串，妥善备份），把输出的公钥填进 `MacClean-Info.plist` 的 `SUPublicEDKey`。
2. 每次发布：导出公证后的 `.dmg`/`.zip`，用 `Vendor/Sparkle/bin/generate_appcast <目录>` 生成 `appcast.xml` 并上传到 `SUFeedURL`。
3. 公钥仍是 `REPLACE_…` 占位值时，应用内更新自动停用（设置页显示“自动更新将在正式版中启用”）。

## 4. 签名与公证

```sh
# Archive（Release，Developer ID Application 证书，Hardened Runtime 已开启）
xcodebuild -scheme MacClean -configuration Release -archivePath build/MacClean.xcarchive archive
xcodebuild -exportArchive -archivePath build/MacClean.xcarchive -exportPath build/export -exportOptionsPlist ExportOptions.plist  # method = developer-id
# 公证 + 装订
xcrun notarytool submit build/MacClean.dmg --keychain-profile <profile> --wait
xcrun stapler staple build/MacClean.dmg
```

## 5. 发布前自测

- `xcodebuild … test -only-testing:MacCleanTests -testLanguage en` 与 `-testLanguage zh-Hans` 均通过。
- 界面截图走查：`TEST_RUNNER_MACCLEAN_SNAPSHOT_DIR=<目录> xcodebuild … test -only-testing:MacCleanTests/UISnapshotTests`（可加 `TEST_RUNNER_MACCLEAN_SNAPSHOT_SCAN=1` 看真实扫描结果）。
- 在一台没装过 MacClean 的 Mac（最低 macOS 14）上走一遍：首次引导 → 完全磁盘访问授权 → 一键体检 → 清理 → 撤销 → 试用到期后的购买页 → 激活 → 停用。
- 文案：不写“让 Mac 更快”之类无法证实的承诺，所有数字必须是真实扫描结果（参考 MacKeeper 集体诉讼）。

## 6. 发布官网改动

1. `node web/site/dev/bump-asset-version.mjs <版本号>`：给所有 JS/CSS 引用加上 `?v=<版本号>`。thulem.com 在 Cloudflare 后面，静态资源会被边缘缓存；不改 URL 的话，访客可能拿到新 HTML 配旧 JS（比如英文版文案缺失）。
2. 同步 `web/site/`（排除 `dev/`）到服务器 `/var/www/thulem.com/`，并 `chown -R caddy:caddy`。
3. 抽查：`curl -sS https://thulem.com/ | grep -o 'home.js?v=[0-9.]*'` 应为新版本号。

