# 发布清单

## 当前官网版本（2026-10-24）

- MacClean **1.5（构建 6）**，Apple 芯片与 Intel 通用，最低 macOS 14。
- 已使用 Apple Development 证书签名；尚未完成 Developer ID 公证，安装时可能出现系统验证提示。Sparkle 公钥仍为占位值，应用内自动更新未启用。
- 自愿使用统计默认关闭。已从实际 DMG 启动应用，验证首次打开、每日活跃、首次完成扫描上报及已登录后台显示，重复扫描不会重复计数。
- 385 项应用测试通过（含参数化测试共 427 次执行）；官网完整下载的 DMG 与本地发布包逐字节一致。
- DMG SHA-256：`fe82260c9557d7fd9b768567ab539eec8aeebe7441196961cf09075407d8fb70`。
- 当前下载入口：<https://thulem.com/download/latest>。安装包和验收截图保留在本地，源代码仓库不包含证书私钥、运行数据和推广账号资料。

MacClean 走官网直销：Developer ID 签名 + 公证，不上 Mac App Store（沙盒会让系统垃圾、启动项、维护任务、卸载残留等核心功能失效）。

## 1. 发布前必须填写的占位值

| 位置 | 内容 |
|---|---|
| `MacClean/Core/Licensing/LicenseConfig.swift` | `purchaseURL` 购买页（目前为 nil，按钮置灰）；`lemonSqueezyStoreID` / `lemonSqueezyProductID`（为 0 时不校验产品归属，其他产品的 key 也能激活）；`pricingHeadline` / `pricingDetail` 定价文案 |
| `MacClean/Features/About/AboutView.swift` → `AppLinks` | 官网、隐私政策、支持页地址（目前为 nil，不显示） |
| `MacClean-Info.plist` | `SUPublicEDKey`（Sparkle 公钥，见第 3 步）、`SUFeedURL`（appcast 地址） |
| `project.pbxproj` | `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 每次发布递增 |

## 2. 收款与授权

- 国际：LemonSqueezy（自带 License Key、支持支付宝/微信支付、代缴税）。在商品里开启 “Generate license keys”，设置激活数上限（建议 2–3 台）。
- 国内：面包多 / 爱发电等可通过 webhook 发放 key；接入时实现 `LicenseBackend` 协议即可（见 `LicenseBackend.swift`），界面与试用逻辑不用改。
- 试用 7 天；试用结束后扫描、浏览永远免费，清理/卸载/启动项/维护等操作需要授权（`ProGate.allowAction()`）。
- 准备：隐私政策（说明扫描只在本机进行、不上传文件信息）、用户协议、退款政策（行业惯例 30 天）、支持邮箱。

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

