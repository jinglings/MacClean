# 用"解释 + 可撤销"打赢 Mac 清理市场

调研日期：2026-10-02 · 对比基线：MacClean 1.2

**一句话结论：MacClean 1.2 在安全模型（先进废纸篓、可撤销）、只读安全审计、快照/Time Machine 找回、开发缓存这几块，已经比几乎所有竞品更完整；真正的差距只有三处，而且都是用户呼声最高的：一是微信/QQ/企业微信聊天媒体的精细清理，二是对"系统数据"的分项解释，三是本地 AI 模型缓存。** 次一级的缺口是菜单栏硬件传感器（温度、风扇、GPU）和存储地图的易用性细节（暂存篮、空格预览、可清除空间/快照分项）。CleanMyMac 5.x 正在往云盘、Gmail、Apple Intelligence 解释和杀毒方向扩张（[What's New](https://macpaw.com/cleanmymac/whats-new)）。腾讯拿免费的柠檬清理加上新出的"腾讯电脑管家 Mac 版"（带 TAV 杀毒）守住国内基本盘（[Issue #146](https://github.com/Tencent/lemon-cleaner/issues/146)、[guanjia.qq.com](https://guanjia.qq.com/main-mac.html)）。开源的 Pearcleaner 自 2025 年底起暂停开发（[GitHub](https://github.com/alienator88/Pearcleaner)）。这几件事叠在一起，给"本地、透明、可撤销、一次买断"留出了明确位置。建议 1.3 集中做微信清理、系统数据拆解、AI 模型缓存和存储地图的体验补强。杀毒、内存"加速"、VPN、健康分、裸盘恢复都不要做：这些功能要么价值存疑，要么直接踩进 MacKeeper 式"恐吓软件"的雷区（[Wikipedia: MacKeeper](https://en.wikipedia.org/wiki/MacKeeper)）。

---

## 1. 一页结论：MacClean 广度够了，缺的是用户真正在问的三个问题

**我们的位置。** 在功能广度上，MacClean 已经和 CleanMyMac 5 同级：一键体检、存储地图、释放空间、重复与相似、应用管家、隐私、维护、菜单栏都有。CleanMyMac 只有一个大模块我们刻意没做，就是 Moonlock 杀毒（[KB: Moonlock Engine](https://macpaw.com/support/cleanmymac/knowledgebase/moonlock-engine)）。另外 CleanMyMac 有几个依赖账号授权的新功能（云盘清理、Gmail 清理），我们没有。价格上，我们一次性 ¥98 / 2 台，CleanMyMac Plus 一年就要约 $71.40（[Macworld](https://www.macworld.com/article/352922/cleanmymac-x-review-macos.html)）。在国内，我们要对抗的是"免费的柠檬清理"和"打折后约 ¥150 的 CMM 永久版"这两个价格锚点（[什么值得买](https://post.smzdm.com/p/a90gqqle/)）。

**最重要的 5 个缺口**（按用户价值排序）：

| # | 缺口 | 谁有 | 关键证据 |
|---|---|---|---|
| 1 | 微信/QQ/企业微信聊天图片、视频按类型/日期清理（我们现在只显示占用） | 柠檬清理 | V2EX 有用户微信占 172 GB（[V2EX 1094857](https://v2ex.com/t/1094857)）；微信自带"清理缓存"显示 0B，磁盘上实际还有 13.8 GB（[V2EX 1111926](https://www.v2ex.com/t/1111926)） |
| 2 | "系统数据"分项解释 + 已知 macOS bug 检测 | 无人完整做到（DaisyDisk、Nektony 只有可清除空间/快照） | 256 GB 机器出现 233 GB 系统数据（[Apple Community](https://discussions.apple.com/thread/255987206)）；CoreSpotlight bug 单个案例 324 GB（二手） |
| 3 | 本地 AI 模型缓存（Ollama / Hugging Face / LM Studio） | Mole、Clutterfall、DeepClean 等新独立工具 | 单个 Ollama 模型 4–45 GB（[Mole blog](https://mole.fit/blog/how-to-remove-ai-tool-leftovers-mac)）；[Ollama #4122](https://github.com/ollama/ollama/issues/4122) |
| 4 | 菜单栏温度/风扇/GPU/磁盘 I/O、阈值提醒与历史曲线 | 柠檬、BuhoCleaner、Sensei、iStat Menus、Stats | Stats 免费即具备（[exelban/stats](https://github.com/exelban/stats)），已成标配 |
| 5 | 存储地图的"暂存篮"、空格 Quick Look、可清除空间/APFS 快照分项、云盘/网络卷 | DaisyDisk、Nektony Disk Space Analyzer | DaisyDisk 的 collector 是用户最常称赞的点（[MacPaw review](https://macpaw.com/reviews/daisydisk-review)） |

**我们已经更好的 5 处：**

| # | 优势 | 对手的对应短板 |
|---|---|---|
| 1 | 所有删除先进废纸篓，并可在"清理记录"里撤销 | 柠檬 #149：Finder 授权失败时静默改用永久删除（[Issue #149](https://github.com/Tencent/lemon-cleaner/issues/149)）；CleanMyMac 文档里查不到撤销/历史功能（[KB: Smart Care](https://macpaw.com/support/cleanmymac/knowledgebase/smart-care)） |
| 2 | 只读安全审计（TCC、描述文件、可疑启动项、未签名应用、浏览器扩展） | 国内清理软件都没有；Nektony 只做到权限和公证检查（[nektony.com](https://nektony.com/mac-app-cleaner)） |
| 3 | 从 APFS 快照和 Time Machine 找回文件 | CleanMyMac 只能*删除* TM 快照；Disk Drill 的裸盘恢复在内置 SSD 上接近 0%（[Rossmann](https://rossmanngroup.com/problems/can-you-recover-data-after-trim)） |
| 4 | 开发缓存 + Docker + iOS 备份/固件 | CleanMyMac 没有在宣传开发缓存；BuhoCleaner 只覆盖 Xcode |
| 5 | 本地运行、无遥测、一次买断 | 柠檬 #150 的遥测疑问（[Issue #150](https://github.com/Tencent/lemon-cleaner/issues/150)）；CleanMyMac 的 App Store 隐私标签写明收集使用数据（[App Store](https://apps.apple.com/us/app/cleanmymac/id1339170533?mt=12)）；订阅制普遍招致反感 |

---

## 2. 竞品概览：一个巨头在扩张，腾讯换了产品线，开源头部停更

| 产品 | 定位 | 核心功能 | 价格模式与价格 | 平台/版本说明 | 维护状态 |
|---|---|---|---|---|---|
| **CleanMyMac 5**（MacPaw） | 全能清理 + 安全套件 | Smart Care、Cleanup、Protection（Moonlock 杀毒）、Performance、Applications、My Clutter、Space Lens、Cloud Cleanup、Smart Insights（AI）、Gmail 清理、菜单栏健康分（[What's New](https://macpaw.com/cleanmymac/whats-new)） | 订阅为主，另有买断。Basic $47.50/年，Plus $71.40/年（1 台）；买断 $119.95 / $195.95（[Macworld](https://www.macworld.com/article/352922/cleanmymac-x-review-macos.html)）。国内约 ¥210–298/年、¥569 永久（[腾讯新闻](https://news.qq.com/rain/a/20241016A0A61H00)）。试用 7 天，到期后只能扫描 | App Store 版缺 22 项以上功能（系统缓存、维护任务等）；Setapp 版与官网版功能一致（[KB](https://macpaw.com/support/cleanmymac/knowledgebase/missing-features)）。买断只覆盖当前大版本 | 很活跃：5.7.1（2026-10-01）。Business 版 2026-07 宣布停售（[Wikipedia](https://en.wikipedia.org/wiki/CleanMyMac)） |
| **腾讯柠檬清理** | 免费国民清理工具 | 100+ 应用定制深度清理（含微信/QQ/企业微信）、大文件、重复、相似照片、浏览器隐私、卸载、启动项、空间分析、文件搬家；菜单栏显示 CPU 温度、风扇、网速，摄像头/麦克风提醒（[README](https://github.com/Tencent/lemon-cleaner)、[lemon.qq.com](https://lemon.qq.com/)） | 免费 | 完整版（闭源 5.3.6，2026-08-31，[TechMoon](https://techmoon.xyz/tencent-lemon-cleaner/) 二手）；App Store Lite 4.2.13，不能卸载应用（[App Store](https://apps.apple.com/cn/app/%E8%85%BE%E8%AE%AF%E6%9F%A0%E6%AA%AC%E6%B8%85%E7%90%86-lite/id1449962996)） | 闭源版仍在更新；开源仓库落后（v5.1.20，2025-10），社区认为"已经放弃"（[#151](https://github.com/Tencent/lemon-cleaner/issues/151)） |
| **腾讯电脑管家 Mac 版** | 免费"工具箱" | TAV 杀毒、清理、深度卸载、手机远程访问、长截图、摄像头/麦克风守护、内存管理、流量与磁盘写入监控（[guanjia.qq.com](https://guanjia.qq.com/main-mac.html)） | 免费（页面未标价） | 18.2.2.0，ARM64 / Intel | 2026-06 发布，从零重写（[#146](https://github.com/Tencent/lemon-cleaner/issues/146)） |
| **BuhoCleaner**（成都 Dr.Buho） | 平价版 CleanMyMac，直销 | 快速清理、大文件、重复（照片/文件/文件夹）、空间分析、卸载 + 100+ 应用深度卸载、启动项、温度/风扇监控、Xcode 清理、**文件粉碎**、释放内存（[drbuho.com](https://www.drbuho.com/buhocleaner)） | 年付或买断，常年促销：买断标价 $67.99，促销 $25.99；年付 $39.99，促销 $17.99（1 台/3 台对应关系不明）（[store](https://www.drbuho.com/buhocleaner/buy)） | 简繁中文；需要特权助手；不上 App Store | 1.16.2（2026-07，[MacWk](https://macwk.cn/app/3751.html)），国内破解版流传 |
| **DaisyDisk** | 磁盘可视化 | 环形图、collector 暂存删除、管理员扫描隐藏空间、可清除空间、APFS 快照、云盘/网络盘、Quick Look（[daisydiskapp.com](https://daisydiskapp.com/)） | 一次性 $9.99，最多 5 台 | macOS 10.13+ | 4.34.2（2026-07） |
| **GrandPerspective** | 开源树状图 | 多种着色方案、过滤器、保存/重载扫描（[SourceForge](https://grandperspectiv.sourceforge.net/)） | 免费（GPL），App Store 版 $2.99 | macOS 14+ | 3.8.1（2026-09） |
| **Nektony 系列** | 订阅制套件 | App Cleaner & Uninstaller（扩展管理、默认应用、应用重置、网络活动、权限审计、批量更新）；Duplicate File Finder（文件夹比较/合并、重复文件夹、相似音乐）；Disk Space Analyzer；Memory Cleaner（[nektony.com](https://nektony.com/mac-app-cleaner)） | ACU $7.95/月起，MacCleaner Pro 套装 $14.95/月起；DSA $4.95/月起；Memory Cleaner 免费 | macOS 11–27 | 活跃：ACU v10.02（2026-09） |
| **Pearcleaner** | 开源卸载器 | Sentinel 废纸篓监听、孤立文件、Homebrew GUI、Lipo 瘦身、语言包裁剪、更新器、Finder 扩展、CLI；5.4.x 起删除走 UndoManager 进废纸篓（[GitHub](https://github.com/alienator88/Pearcleaner)） | 免费（Apache 2.0 + Commons Clause，不可商用） | README 写支持 macOS 13–15 | **自 2025 年底"无限期暂停"**，最后版本 v5.4.3 |
| **AppCleaner**（FreeMacSoft） | 极简免费卸载器 | 拖拽卸载、SmartDelete 废纸篓监听（[OWC](https://eshop.macsales.com/blog/96534-appcleaner-is-a-must-have-utility-that-makes-uninstalling-mac-apps-a-breeze/)） | 免费，接受捐赠 | 3.7 需 macOS 15+ | 官网未标发布日期（[freemacsoft.net](https://freemacsoft.net/appcleaner/)） |
| **OnyX** | 免费维护工具 | 校验启动卷、重建 LaunchServices/XPC/CoreDuet/Mail 索引、字体与各类缓存清理、隐藏设置"Parameters"（[titanium-software.fr](https://www.titanium-software.fr/en/onyx.html)） | 免费，接受捐赠 | 每个 macOS 大版本单独一个构建；5.1.0 仅支持 Apple 芯片 | 活跃（2026-09） |
| **Sensei**（Cindori） | 清理 + 硬件健康 | S.M.A.R.T.、温度风扇、GPU、电池、磁盘测速、TRIM、可定制菜单栏组件（[cindori.com](https://cindori.com/sensei)） | $29/年或 $59 买断（3 台，仅限一个大版本；第三方报价） | — | 版本号未查到 |
| **iStat Menus 7 / Stats** | 菜单栏监控 | CPU 每核、GPU/FPS、内存、磁盘、按应用统计网络、传感器、风扇曲线、各项阈值通知（[MacRumors](https://www.macrumors.com/2024/07/31/istat-menus-7-0-brings-new-features/)）；Stats 免费 MIT 开源，风扇控制已停止维护（[GitHub](https://github.com/exelban/stats)） | iStat $11.99 买断（App Store）；Stats 免费 | Stats 需 macOS 12+ | 均活跃 |
| **Disk Drill 6** | 数据恢复 + 保护 | 裸盘恢复、Recovery Vault / Guaranteed Recovery、S.M.A.R.T.、逐字节备份、清理、重复、粉碎（[pandorarecovery](https://scoreboard.pandorarecovery.com/disk-drill-mac-review/)） | 约 $89/年或 $149 买断（第三方报价）；Mac 免费版只能预览（[Macgasm](https://news.macgasm.net/reviews/disk-drill-mac-review/)） | — | 官方定价页无法访问 |
| **Gemini 2**（MacPaw） | 重复文件专家 | 精确重复 + 相似文件、Photos/Music 库、会学习的 Smart Select、Duplicate Monitor（[macpaw.com/gemini](https://macpaw.com/gemini)） | $19.95/年，$44.95 买断（1 台，第三方报价）；也在 Setapp | 10 种语言 | 2026-09 有构建 |
| **MacKeeper**（Clario） | "恐吓式"安全 + 清理套件 | 杀毒（AV-TEST 2025 认证）、广告软件清理、VPN、StopAd、身份盗用监控、内存清理、更新追踪（[mackeeper.com](https://mackeeper.com/)） | 订阅：约 $5.95–10.95/月（[allaboutcookies](https://allaboutcookies.org/mackeeper-review)） | — | 活跃；历史上有 $2M 集体诉讼和解、1300 万条用户记录泄露（[Wikipedia](https://en.wikipedia.org/wiki/MacKeeper)） |
| **Intego** | Mac 专业杀毒 | VirusBarrier + NetBarrier 双向防火墙；Premium 版加 Washing Machine 清理、家长控制、备份（[Tom's Guide](https://www.tomsguide.com/reviews/intego-premium-bundle-x9)） | 首年 $39.99（标价 $84.99），多档促销（[Intego](https://antivirus.intego.com/misx9-promotion)） | — | 官网页面无法访问 |
| **Mole**（tw93） | 开源 CLI + 付费 GUI | 开发缓存、构建产物、dry-run、白名单、操作日志（[GitHub](https://github.com/tw93/mole)） | CLI 免费；GUI 从 $9 涨到 $19（[V2EX](https://www.v2ex.com/t/1222690)） | — | 约 6.9 万 star，活跃 |
| **360 安全卫士极速版** | 免费 | 清理、大文件、重复文件和**重复文件夹**、硬件信息（[App Store](https://apps.apple.com/us/app/360%E5%AE%89%E5%85%A8%E5%8D%AB%E5%A3%AB%E6%9E%81%E9%80%9F%E7%89%88/id6449414501?mt=12)） | 免费 | — | **最后更新 2024-12，处于停滞状态** |

这张表反映出三个趋势。**一是 CleanMyMac 在向外扩张。** 2025–2026 年它新增的功能几乎都要求联网授权（云盘、Gmail）或 Apple Intelligence（Smart Insights），同时用 Plus 档把杀毒和 Space Lens 放到付费墙后面。**二是腾讯分拆了产品线。** 团队原话是"Lemon 我们继续保持开源与纯粹的清理工具定位。管家 Mac 是工具箱"（[#146](https://github.com/Tencent/lemon-cleaner/issues/146)），但开源仓库已经明显落后于发行版。**三是开源和独立工具占据了口碑。** 2026-06 的 V2EX 推荐帖里，被推荐的是 Mole、Pearcleaner、OmniDiskSweeper、App Cleaner & Uninstaller、DaisyDisk 和柠檬清理（[V2EX 1222690](https://www.v2ex.com/t/1222690)）。

---

## 3. 竞品有而我们没有的功能：值得做的集中在"中国特色"和"解释"两类

下表按"做 > 观望 > 不做"排序，同一档内按用户价值排序。用户价值依据 user_needs 和 china_market 两份笔记中的证据。难度和风险是我们自己的估计，"恐吓软件风险"指功能本身容易被做成或被看成制造焦虑、诱导付费。

| 排名 | 功能 | 谁有 | 用户价值（证据） | 难度 / 风险 | 建议 |
|---|---|---|---|---|---|
| 1 | **微信/QQ/企业微信/飞书聊天媒体清理**（按会话、类型、日期，保留文字只删媒体） | 柠檬清理（按缓存/日志/数据分类，二手资料称支持聊天图片和视频，[CSDN](https://blog.csdn.net/gitblog_00718/article/details/156820806)）；开源 Clean My WeChat（定期自动清理） | **高**：172 GB 案例（[V2EX 1094857](https://v2ex.com/t/1094857)）；用户普遍认为微信"清理缓存"按钮形同虚设（[V2EX 1111926](https://www.v2ex.com/t/1111926)）；用户对柠檬"自产自销"有调侃；Clean My WeChat 在新系统上出现崩溃、识别失败（[V2EX 1217802](https://www.v2ex.com/t/1217802)） | 中高。微信目录结构随版本变化，需要做版本兼容；误删聊天记录是最大风险，必须只动媒体和缓存，并且全部进废纸篓 | **做（1.3 头号）**：这可能是国内用户愿意付费的单一理由（调研笔记的推论，非实测） |
| 2 | **"系统数据"分项拆解 + 已知 bug 检测**（CoreSpotlight 膨胀、mediaanalysisd、本地快照、iOS 备份、交换文件只展示不动） | 无人完整做到；DaisyDisk 和 Nektony DSA 能显示可清除空间和快照 | **高**：系统数据 233 GB / 170 GB / 300 GB 的帖子反复出现（[Apple Community](https://discussions.apple.com/thread/255987206)、[Apple Dev Forums](https://developer.apple.com/forums/thread/766370)、[HN](https://news.ycombinator.com/item?id=46574450)）；知乎"系统数据暴涨上百G"（[知乎](https://zhuanlan.zhihu.com/p/2068279907994678775)）；V2EX 有独立开发者专门做了系统数据分析器（[V2EX 1205096](https://v2ex.com/t/1205096)） | 中。大部分扫描能力已有，主要工作是归类和撰写说明；风险低（只读 + 引导） | **做（1.3）** |
| 3 | **本地 AI 模型缓存**（Ollama、Hugging Face、LM Studio，以及后续的 IDE/Agent 缓存） | Mole（博客）、Clutterfall、DeepClean 等新工具 | **中高**：单个模型 4–45 GB；增长快，但目前主要靠厂商内容在推（[deepcleanmac](https://deepcleanmac.com/blog/clean-up-local-ai-models-on-mac)、[HN 46711394](https://news.ycombinator.com/item?id=46711394)） | 低。并入开发缓存即可；模型是用户主动下载的，应按"大而久未用"展示，不要默认勾选 | **做（1.3）**，成本低，适合拿来做宣传 |
| 4 | **存储地图体验补强**：暂存篮（显示累计可释放空间）、空格 Quick Look、"隐藏/可清除/APFS 快照"分项行、树状图视图 | DaisyDisk、Nektony DSA、GrandPerspective | 中高：collector 和隐藏空间是 DaisyDisk 被称赞的核心（[Dr.Buho review](https://www.drbuho.com/review/daisydisk-review)） | 低到中；无风险 | **做（1.3 做暂存篮和 QL，中期做树状图）** |
| 5 | **菜单栏硬件传感器**：CPU/GPU 温度、风扇转速（只读）、GPU 占用、磁盘读写、阈值提醒、1 小时/24 小时迷你曲线 | 柠檬、BuhoCleaner、Sensei、iStat、Stats、柠檬 Lite（含 GPU） | 中：已是标配（[Stats](https://github.com/exelban/stats)、[MacRumors](https://www.macrumors.com/2024/07/31/istat-menus-7-0-brings-new-features/)）；但没有用户调研说明大家实际看哪些指标 | 中。SMC 读取依赖非公开接口，新芯片会失效（柠檬 #135：M5 读不到温度和风扇）；监控本身也耗电（[Stats #3536](https://github.com/exelban/stats/issues/3536)）。**不做风扇控制** | **做（中期）**，保持只读、精简，不和 iStat 拼功能数量 |
| 6 | **OnyX 式维护补充**：校验启动卷、字体缓存、Quick Look 缩略图缓存重置；"隐藏设置"面板（截图格式/位置、Dock 延迟、显示隐藏文件等） | OnyX（[Wikipedia](https://en.wikipedia.org/wiki/OnyX)） | 中：Parameters 面板是很多人用 OnyX 的理由（[addictivetips](https://www.addictivetips.com/mac-os/inspect-mac-system-components-clean-system-files-and-apply-fixes-onyx/)） | 低；恐吓风险低 | **做（1.3 做维护项，中期做隐藏设置）** |
| 7 | **重复文件智能选择规则**（保留最新 / 保留某目录 / 记住用户选择） | Gemini 2 Smart Select；Nektony Auto Select（[macpaw.com/gemini](https://macpaw.com/gemini)） | 中 | 低 | **做（1.3）** |
| 8 | **废纸篓监听（SmartDelete / Sentinel）**：应用被拖进废纸篓时立即提示清理残留 | AppCleaner、Pearcleaner | 中：这是卸载器的参考体验；我们目前在扫描时才能发现"已拖进废纸篓的应用" | 中。**柠檬 #145 的教训：用 WatchPaths 监听 ~/.Trash 可能 100% 复现卡死 Finder**（[#145](https://github.com/Tencent/lemon-cleaner/issues/145)），必须默认关闭、轻量实现并做压力测试 | **做（中期，默认关闭）** |
| 9 | **扩展/插件管理**（偏好设置面板、Quick Look/Spotlight 插件、Internet 插件；浏览器扩展可删除） | Nektony ACU、AppCleaner、Pearcleaner | 中 | 中。我们的安全中心已能只读列出浏览器扩展，可以复用 | **做（中期）** |
| 10 | **重复文件夹 / 文件夹比较** | Nektony DFF（比较和合并）、360 极速版、BuhoCleaner | 中低 | 中 | **做（中期）只做检测；"合并"观望** |
| 11 | **相似/模糊照片与截图清理；感知 Photos 图库**（通过 PhotoKit 删除，而不是直接删图库包里的文件） | Avast Cleanup、Gemini、PowerPhotos、Nektony DFF | 中 | 中高。直接删 .photoslibrary 包内的文件会损坏图库，必须走 PhotoKit | **做（中期）** |
| 12 | **应用重置**（清掉偏好设置和缓存，保留应用本身） | Nektony ACU（[FAQ](https://nektony.com/help/app-cleaner/faq)） | 中低 | 低；进废纸篓后可撤销 | **做（中期）** |
| 13 | **定时扫描 + 通知 / 安全类别的自动清理（需用户主动开启）** | Nektony Memory Cleaner 定时、Norton 自动清理、Clean My WeChat 定期清理；CleanMyMac 是"按状态提醒" | 中：user_needs 把"定期清理"列为新兴需求，但证据只有 Clean My WeChat 一例 | 低到中。要避免变成"后台常驻吓人"，CleanMyMac 正因"在后台运行"挨批（[AlternativeTo](https://www.alternativeto.net/software/cleanmymac/about/)） | **做（中期）**，从微信定期清理切入 |
| 14 | **静态 + 本地 AI 解释**（"这是什么，删了会怎样"） | CleanMyMac Smart Insights（需 Apple 芯片 + macOS 26，支持简体中文，[MacPaw](https://macpaw.com/news/introducing-smart-insights)）；柠檬 AI 助手（联网到元宝，[TechMoon](https://techmoon.xyz/tencent-lemon-cleaner/)） | 中：用户要的是解释，而不是多清一点（user_needs 推论） | 静态说明成本低；本地模型解释中等。**AI 执行删除有风险**：V2EX 有用户称"AI 上次把桌面数据全部删除了"（未确认是哪款工具，[V2EX 1222690](https://www.v2ex.com/t/1222690)） | **做静态说明（1.3 随系统数据一起做）；本地 AI 观望（长期）；AI 自动删除不做** |
| 15 | **macOS / App Store 应用更新检查；一键安装更新** | CleanMyMac 官网版、Nektony ACU（[KB](https://macpaw.com/support/cleanmymac/knowledgebase/missing-features)） | 中低 | 只检查：低；一键安装：中高（不同安装器差异大） | **观望**：可补"只读检查"，不做自动安装 |
| 16 | **只读的应用网络活动 / 出站连接视图** | Nektony ACU 网络活动、Intego NetBarrier、iStat 按应用统计带宽 | 中低。活动监视器已有部分能力（笔记未取到 Apple 文档） | 只读：中；真正的防火墙需要 Network Extension，工程量大 | **观望（长期，只读）** |
| 17 | **硬盘健康徽章（S.M.A.R.T.）** | Sensei、Disk Drill | 中低。内置 NVMe 通过公开接口基本只能拿到"Verified"，外置盘更有用（推论） | 低到中 | **观望**：先只给外置盘做简单徽章 |
| 18 | **摄像头/麦克风使用提醒** | 柠檬、管家 Mac、CleanMyMac Protection | 中低 | 中；容易演变成"AI 时代隐私守护"这类制造焦虑的说法 | **观望** |
| 19 | **云盘清理 / 云盘与网络卷扫描** | CleanMyMac Plus（OAuth）、DaisyDisk、Nektony | 中 | 走 OAuth 与我们"纯本地"的定位冲突；Macworld 也指出用户对授权云盘有顾虑（[Macworld](https://www.macworld.com/article/352922/cleanmymac-x-review-macos.html)） | **观望**：最多扫描本地同步目录和网络卷，不接 OAuth |
| 20 | **文件搬家**（把大目录迁到外置盘/云盘并建链接） | 柠檬（LemonFileMove） | 中：V2EX 有人用软链接把微信数据挪到外置盘（[V2EX 1111926](https://www.v2ex.com/t/1111926)） | 中高。外置盘拔掉后应用可能出错，回滚复杂 | **观望** |
| 21 | **Lipo 二进制瘦身 / 语言包裁剪** | CleanMyMac 官网版、Pearcleaner、Nektony MacCleaner Pro | 低：Apple 芯片普及后收益有限（推论） | 中高。会修改应用包，可能影响签名和更新（我们的推论，笔记中无实测） | **不做（至少观望）** |
| 22 | **Homebrew 管理 / Finder 右键扩展 / CLI / 快捷指令** | Pearcleaner、Mole | 低到中：笔记中**没有找到**用户对快捷指令/自动化集成的需求证据 | 中 | **观望**；Finder 右键卸载可以放到中期 |
| 23 | **健康评分** | CleanMyMac（五档，把"是否启用完全磁盘访问""是否最近扫描过"也算进去，[KB](https://macpaw.com/support/cleanmymac/knowledgebase/mac-health)） | 低到中 | **恐吓软件风险高**：分数会诱导用户"为提分而清理" | **不做数字评分**；可以做中性的"状态清单" |
| 24 | **杀毒 / 恶意软件清除 / 实时防护** | CleanMyMac、MacKeeper、Intego、管家 Mac | 中：国内用户默认"管家"就该带杀毒（推论） | 极高。需要病毒库和误报处理；Moonlock 在 Macworld 测试中仍有漏检（[Macworld](https://www.macworld.com/article/352922/cleanmymac-x-review-macos.html)） | **不做**，并明确宣传"安全中心不是杀毒软件" |
| 25 | **内存"释放"作为加速卖点** | BuhoCleaner、MacKeeper、Nektony Memory Cleaner、CleanMyMac | 低：在现代 macOS 上基本是安慰剂；国内仍有人期待 | 恐吓/误导风险高 | **不做**；保留菜单栏里的 purge 作为专家工具即可 |
| 26 | **文件粉碎** | BuhoCleaner、Disk Drill | 低。TRIM + FileVault 下普通删除的数据已难以恢复（[CleverFiles](https://www.cleverfiles.com/help/variables-that-impact-file-recovery-chances/)），粉碎的增量价值低（推论） | 低，但会和"一切可撤销"相矛盾 | **不做** |
| 27 | **裸盘恢复 / Recovery Vault** | Disk Drill | 低：内置 SSD 上恢复率接近 0%（[pandorarecovery](https://ratings.pandorarecovery.com/best-ssd-recovery-software/)，有行业利益关联） | 高，而且会招来退款 | **不做**；改做"清理暂存期"，见路线图 |
| 28 | **Gmail 清理、VPN、广告拦截、身份盗用监控、远程控制、截图、清洁屏幕模式** | CleanMyMac、MacKeeper、管家 Mac | 低（偏离主业） | 需要联网/账号，或属于恐吓式捆绑 | **不做** |

---

## 4. 双方都有的功能逐项对比：赢在安全和覆盖面，输在细节

| 我们的模块 | 最强竞品 | 判定 | 具体差距 | 改进建议 |
|---|---|---|---|---|
| **一键体检** | CleanMyMac Smart Care | **持平略优** | Smart Care 多了恶意软件扫描和更新检查，但重复文件只查"下载"文件夹（[KB](https://macpaw.com/support/cleanmymac/knowledgebase/smart-care)）；我们覆盖下载、桌面、文稿三个目录，还会检查失效登录项 | 体检结果加入"系统数据异常"（如 CoreSpotlight 膨胀）和"微信可清理媒体"两张卡片；继续不打分 |
| **存储地图** | DaisyDisk / Space Lens / Nektony DSA | **较差** | 缺暂存篮和累计可释放空间、空格 Quick Look、隐藏/可清除/快照分项、云盘和网络卷、树状图、保存与比较扫描（[daisydiskapp](https://daisydiskapp.com/)、[GrandPerspective](https://grandperspectiv.sourceforge.net/)）；需要确认硬链接和克隆是否被重复计入 | 1.3 做暂存篮、QL 和"系统数据"分项；中期做树状图和扫描快照对比 |
| **释放空间** | CleanMyMac Cleanup / 柠檬深度清理 | **持平** | 柠檬有 100+ 应用的定制清理方案；CleanMyMac 有语言文件、通用二进制、已删除用户的残留；我们有 iOS 备份和固件、邮件附件、超过 7 天的日志 | 扩充按应用的清理规则库（飞书、企业微信、钉钉、Chrome 等 Electron 应用，[V2EX 1205096](https://v2ex.com/t/1205096)）；不做二进制瘦身 |
| **大型与陈旧文件** | Nektony DSA、柠檬、BuhoCleaner | **持平** | 竞品在功能上没有明显领先 | 和存储地图共用暂存篮 |
| **重复与相似** | Gemini 2、Nektony DFF | **较差** | 缺智能选择规则、重复文件夹、文件夹比较、Photos/Music 图库感知、模糊照片和截图识别、后台重复监控（[macpaw.com/gemini](https://macpaw.com/gemini)、[nektony.com](https://nektony.com/duplicate-finder-free)）；我们的优势是始终保留一份、可切换保留哪份、可撤销 | 1.3 做规则选择；中期做重复文件夹、PhotoKit 删除和模糊照片 |
| **开发缓存** | Mole（CLI）、Pearcleaner 开发环境清理、BuhoCleaner Xcode | **明显更好**，但缺 AI 模型 | Mole 有 dry-run、白名单和操作日志（[GitHub](https://github.com/tw93/mole)）；我们有可视化、可撤销，还会清理闲置项目里的 node_modules/target；**缺 Ollama/HF/LM Studio** | 1.3 加 AI 模型缓存；Docker 增加 Docker.raw 不会自动收缩的提示和 reclaim 步骤（[ClearDisk](https://bysiber.github.io/cleardisk/blog/docker-disk-space-cleanup-mac.html)） |
| **隐私清理** | CleanMyMac Protection > Privacy | **持平或更好** | CleanMyMac 多了 Wi-Fi 网络列表清理（[KB](https://macpaw.com/support/cleanmymac/knowledgebase/missing-features)）；它的 v5 是否覆盖 Chrome/Edge/Brave/Firefox 未查证；我们覆盖五个浏览器，并且不碰密码和书签 | 可选：增加"遗忘旧 Wi-Fi 网络"（低优先级） |
| **安全中心** | CleanMyMac Protection（杀毒）、Nektony 权限审计和公证检查 | **只读审计上明显更好；杀毒上不对标** | 竞品有实时防护、恶意软件清除、摄像头/麦克风权限撤销；国内用户可能把"管家"等同于杀毒 | 文案上明确"体检型、只读、不是杀毒软件"；可以为 TCC 权限加"一键跳转到系统设置撤销" |
| **启动项** | Nektony ACU、CleanMyMac Performance | **持平** | Nektony 能管理系统守护进程；我们对 BTM 登录项只读；柠檬 #133 出现过反复禁用 ToDesk 的 bug（[issues](https://github.com/Tencent/lemon-cleaner/issues)），说明这块容易出错 | 维持保守策略，为每一项补充来源说明 |
| **系统维护** | OnyX | **较差（在覆盖面上）** | 缺校验启动卷、字体缓存、QL 缓存、XPC/CoreDuet/Mail 索引重建、隐藏设置面板、"一键执行所选任务"（[titanium](https://www.titanium-software.fr/en/onyx.html)）。另外，**我们的"删除 TM 本地快照"会毁掉"找回文件"依赖的数据源** | 1.3 补校验卷、字体缓存、QL 缓存；删除快照前提示"会影响找回文件"，并且不要把它当成主打功能（macOS 会自行清理快照，[Apple](https://support.apple.com/guide/mac-help/optimize-storage-space-sysp4ee93ca4/mac)） |
| **应用占用** | 柠檬（微信/QQ 深度方案） | **展示更好，清理更差** | 我们能算出包括聊天数据在内的真实占用，还有 Docker；但不能按会话、按日期清理 | 1.3 的头号功能，见第 3 节第 1 行 |
| **应用管家** | Nektony ACU、Pearcleaner、AppCleaner | **持平略差** | 竞品有废纸篓监听、扩展管理、默认应用、应用重置、批量更新、Homebrew、Finder 扩展、按应用统计网络（[nektony.com](https://nektony.com/mac-app-cleaner)、[GitHub](https://github.com/alienator88/Pearcleaner)）；我们有孤立残留、可撤销卸载、Sparkle 检查、按最后使用时间找闲置应用 | 中期补废纸篓监听、扩展管理、应用重置；可选补 macOS/App Store 只读更新检查 |
| **文件搜索** | Pearcleaner 文件搜索、Nektony Funter（未调研） | **大概率更好**（证据有限） | 竞品资料太少，无法细比 | 维持现状 |
| **找回文件** | Disk Drill | **在内置 SSD 场景下更诚实、更好** | Disk Drill 可以扫外置盘和非 TRIM 介质，我们不行（[CleverFiles](https://www.cleverfiles.com/help/variables-that-impact-file-recovery-chances/)） | 增加"安全网"面板：显示 TM 和本地快照是否开启、覆盖的时间窗口 |
| **菜单栏** | iStat Menus / Stats / 柠檬 | **较差（传感器），部分更好（测速、蓝牙电量、一键清理）** | 缺温度、风扇、GPU、磁盘 I/O、按进程统计网络、历史曲线、阈值提醒 | 中期补齐只读传感器和提醒 |
| **低空间通知与定期提醒** | CleanMyMac 状态提醒 + 通知中心 | **持平** | CleanMyMac 按状态推荐（[KB](https://macpaw.com/support/cleanmymac/knowledgebase/mac-health)） | 提醒里写清具体原因（例如"Xcode 模拟器增加了 20 GB"），不要只说"该清理了" |
| **安全模型（全局）** | Pearcleaner（UndoManager）、Nektony DFF（从废纸篓恢复） | **最完整** | 竞品只在个别模块提供撤销；我们全局都有 | 把"清理记录 / 撤销"放到首页和官网首屏 |

整体来看，**我们输的都是细节和深度，没有一处输在模块缺失。** 只有存储地图、重复文件、菜单栏、系统维护四个模块被专业单品明显压过，而这些单品各自只做一件事。好处是不需要新开大模块，只要把现有模块打磨到"专业单品 80% 的水准"即可。

---

## 5. 独特优势与市场机会：竞品的弱点正好是我们的卖点

**可撤销是对柠檬的直接回应。** 柠檬 #149 记录了这样一个问题：重复文件和大文件清理在 Finder 自动化授权失败时，会退回到 `removeItemAtPath` 直接永久删除，而界面上仍显示"移到废纸篓"（[Issue #149](https://github.com/Tencent/lemon-cleaner/issues/149)）。#145 记录了柠檬的废纸篓 LaunchAgent 会卡死 Finder 桌面（[Issue #145](https://github.com/Tencent/lemon-cleaner/issues/145)）。#148 是特权 XPC 服务缺少客户端校验（[Issue #148](https://github.com/Tencent/lemon-cleaner/issues/148)）。这些都来自腾讯自己的 issue 区，公开可查。用户评论"虽然不知道到底清理了什么"和希望有"可视的清除界面"（[App Store CN](https://apps.apple.com/cn/app/%E8%85%BE%E8%AE%AF%E6%9F%A0%E6%AA%AC%E6%B8%85%E7%90%86/id1449962996)），说明"看得见、能撤销"正是用户缺的东西。需要说明的是，**撤销能力并非我们独有**：Pearcleaner 5.4.x 已把删除操作放进 UndoManager（[releases](https://github.com/alienator88/Pearcleaner/releases)），Nektony DFF 也有删除历史。我们的独特之处在于**全模块一致**，而且有统一的清理记录。

**本地运行、无遥测，对应国内用户对"管家"的不信任。** V2EX 上有"国产的管家类更是不敢用"（[V2EX 627143](https://global.v2ex.com/t/627143)）这样的说法。柠檬 #150 指出它会加载 `sdi.3g.qq.com` 页面并带 guid，代码里还有一个未使用的上传器（[Issue #150](https://github.com/Tencent/lemon-cleaner/issues/150)）。第三方隐私指南称其主清理功能会收集文件名、路径和已安装软件列表（[TechMoon](https://techmoon.xyz/tencent-lemon-cleaner/)，二手资料）。CleanMyMac 的 App Store 隐私标签写明为营销和分析收集使用数据（[App Store](https://apps.apple.com/us/app/cleanmymac/id1339170533?mt=12)），新功能还要求 Gmail 和云盘 OAuth。我们可以公开列出所有对外联网的域名（只有许可证激活、Sparkle 更新源、证书吊销检查三类），这正好回应了 #150 提问者"请列出连接的域名"的诉求。

**一次买断，对应订阅疲劳。** 用户对 CleanMyMac 改订阅的头号抱怨是"$40 一年太多"（[9to5Mac](https://9to5mac.com/2024/10/16/macpaw-releases-major-update-to-cleanmymac-with-fresh-design-and-new-features/)、[MacRumors](https://www.macrumors.com/2024/10/16/macpaw-releases-redesigned-cleanmymac/)）。HN 上有独立开发者说"I refuse to pay subscription fees for Mac apps that run locally"（[HN 46574450](https://news.ycombinator.com/item?id=46574450)）。V2EX 对 ¥248/年的评价是"这个价格就让我觉得很不好用"（[V2EX 706203](https://www.v2ex.com/t/706203)）。Nektony 全线订阅（$4.95–14.95/月），CleanMyMac 的 Plus 档把杀毒和 Space Lens 放进更高价位，这都给"一次买断、所有功能"留出了空间。

**"不承诺加速"，正面回应专家质疑。** Howard Oakley 长期认为清理软件"弊大于利"（[Eclectic Light](https://eclecticlight.co/2016/05/28/why-you-shouldnt-use-cleaning-or-housekeeping-apps/)）。V2EX 2026 年也有人说"清理后系统也不会变快"（[V2EX 1222690](https://www.v2ex.com/t/1222690)）。这些批评针对的是一键"优化/加速"，并不否定"弄清空间去哪了"和"彻底卸载"。把产品定位成"找到并解释占空间的东西，由你决定，可撤销"，可以绕开大部分批评。另外，CleanMyMac 的品牌已被反复用作恶意软件诱饵（破解版 dmg 夹带窃密木马、仿冒官网投放 SHub Stealer，[Moonlock](https://moonlock.com/macos-stealer-cleanmymac-crack)、[Hackread](https://hackread.com/fake-cleanmymac-site-clickfix-shub-stealer-macos/)）；BuhoCleaner 也在国内破解站流传（[MacSKY](https://www.macsky.net/68359.html)）。因此"官方渠道下载、已公证、不装后台进程（除非你开启）"本身就是信任信号。

**空出来的位置。** Pearcleaner 约有 1.5 万 star（GitHub API 显示 14.8k，另一份镜像写的是 11.7k，两处数据不一致），但开发者因换工作、手边没有 Mac，已"无限期暂停"维护，README 只写到支持 macOS 15（[GitHub](https://github.com/alienator88/Pearcleaner)）。360 极速版从 2024-12 起没有更新。柠檬开源版被社区认为"已经放弃"（[#151](https://github.com/Tencent/lemon-cleaner/issues/151)）。在 macOS 26/27 上，想要"原生、可信、持续维护"的用户正在找替代品。与此同时，Mole 约 6.9 万 star（作者是中国开发者 tw93），说明中文开发者群体对透明清理工具需求很大（[GitHub](https://github.com/tw93/mole)），而我们的开发缓存模块正好命中这部分人。

**新品类的窗口期。** AI 模型缓存、Docker.raw 不收缩、系统数据里的 macOS bug，这几类问题催生了一批 2025–26 年的小工具（ClearDisk、CleanMyDev、DeepClean、Clutterfall 等，[HN 46711394](https://news.ycombinator.com/item?id=46711394)、[HN 46568518](https://news.ycombinator.com/item?id=46568518)），说明老牌产品覆盖得不好。不过门槛也低、竞争者多，单靠这些功能形成不了护城河，必须和"解释 + 可撤销 + 中文"打包在一起。

---

## 6. 建议路线图：1.3 解决"微信、系统数据、AI 缓存"三件事

工作量按"人周"粗估（1 名熟悉代码库的工程师），只用于排序，不作排期承诺。

### 近期：1.3（目标是直接回应用户呼声最高的三个痛点）

| 项目 | 理由 | 工作量 |
|---|---|---|
| **微信/QQ/企业微信媒体清理**：按会话或联系人、类型（图片/视频/文件）、日期（如 6 个月前）筛选；只删媒体和缓存，不动聊天数据库；全部进废纸篓；适配多个微信版本的目录 | 国内第一大痛点；柠檬"自产自销"不被信任，开源脚本在新系统上崩溃；可能是用户愿意付费的单一理由 | 3–5 人周（目录逆向和版本兼容占大头）；飞书、钉钉可放在 1.3.x 迭代 |
| **"系统数据"拆解页**：把系统数据分为本地快照、iOS 备份、CoreSpotlight 索引、mediaanalysisd、日志和崩溃报告、应用支持残留、安装器、开发缓存、AI 模型、交换/VM（只展示）等桶，每个桶附中英文说明和"安全程度"；检测已知 bug 并引导到"重建 Spotlight" | 最常见、反复出现的问题，而且没有对手做好；我们的扫描能力大部分已具备 | 2–3 人周 |
| **AI 模型缓存**并入开发缓存：Ollama、Hugging Face、LM Studio；按大小和最后使用时间展示，默认不勾选 | 增长快、成本低，适合做宣传 | 0.5–1 人周 |
| **存储地图**：暂存篮（显示累计可释放空间，最后统一移到废纸篓）、空格 Quick Look | DaisyDisk 最受称赞的交互，补上就能抹平主要体验差距 | 1–1.5 人周 |
| **重复文件选择规则**：保留最新/最旧、保留某目录下的、记住上次的选择 | 低成本补上 Gemini 的核心便利 | 1 人周 |
| **维护项补充**：校验启动卷、清字体缓存、清 QL 缩略图缓存；删除 TM 快照时提示"会影响找回文件" | 成本低、风险低；同时修正我们自己的一个逻辑冲突 | 0.5–1 人周 |
| **Docker.raw reclaim 提示** | prune 之后磁盘空间不会自动缩小，用户会以为没清掉 | 0.5 人周 |
| **"不是杀毒软件 / 不承诺加速 / 联网域名清单"文案**：放到应用内和官网 | 应对管家 Mac 带杀毒造成的预期落差，以及专家对清理软件的质疑 | 0.5 人周 |

### 中期：1.4–1.6（把落后的模块拉到专业单品的八成水准）

| 项目 | 理由 | 工作量 |
|---|---|---|
| 菜单栏只读传感器：温度、风扇转速、GPU、磁盘 I/O、阈值提醒、迷你曲线（可整体关闭） | 已成标配；柠檬、Buho、Stats 都有；注意新芯片兼容（柠檬 #135）和耗电 | 3–4 人周 |
| 废纸篓监听（默认关闭） | AppCleaner/Pearcleaner 的标志功能；吸取柠檬 #145 的教训做轻量实现 | 1.5–2 人周 |
| 扩展/插件管理（复用安全中心里的浏览器扩展数据） | Nektony、AppCleaner、Pearcleaner 都有 | 2 人周 |
| 应用重置 | Nektony 独有，实现简单，可撤销 | 1 人周 |
| 重复文件夹检测；Photos 图库感知删除（PhotoKit）；模糊照片和截图识别 | 补齐 Gemini、Nektony、Avast 的差距 | 4–6 人周 |
| 定时扫描 + 通知；微信等"安全类别"的自动清理需用户主动开启 | 对应 Clean My WeChat 的"定期自动清理"诉求；默认只通知不删除 | 2 人周 |
| 存储地图树状图视图、保存扫描并对比（"这周多了什么"） | GrandPerspective、Nektony 的深度功能；"对比"正好服务于"解释"定位 | 2–3 人周 |
| 隐藏设置面板（OnyX Parameters 风格） | 很多人用 OnyX 就是为了这个；无恐吓风险 | 1.5 人周 |
| "安全网"面板：TM/本地快照开启状态与覆盖时间窗口；可选的"清理暂存期 N 天"（我们自己删除的东西延迟进入可永久删除状态） | 用诚实的方式替代 Disk Drill 式的 Recovery Vault | 1.5–2 人周 |
| macOS / App Store 只读更新检查 | 补齐 CleanMyMac 官网版的能力，不做自动安装 | 1 人周 |

### 长期（视数据再决定）

| 项目 | 理由 | 工作量 |
|---|---|---|
| 本地 AI 解释（Apple Intelligence / 端侧模型），只用于说明，不负责删除 | 跟进 CleanMyMac Smart Insights；坚持"AI 不替用户删东西"（回应 V2EX 上 AI 误删的担忧） | 3–4 人周 |
| 只读的应用出站连接视图 | 对标 Intego/Nektony，放在安全中心旁边；不做防火墙 | 4+ 人周 |
| 外置盘 S.M.A.R.T. 健康徽章 | 外置盘价值较高；内置盘数据有限 | 1–2 人周 |
| 本地同步目录（iCloud/Dropbox 等）占用分析和网络卷扫描，不接 OAuth | 保持纯本地；部分覆盖 CleanMyMac 云盘清理的价值 | 2–3 人周 |
| Finder 右键卸载、CLI / 快捷指令 | 目前没有需求证据；如果开发者用户占比高再做 | 2–3 人周 |

### 明确不做

| 不做 | 原因 |
|---|---|
| 杀毒引擎、实时防护、"发现 N 个威胁" | 病毒库和误报成本极高；连 Moonlock 都有漏检（[Macworld](https://www.macworld.com/article/352922/cleanmymac-x-review-macos.html)）；会打乱"只读审计"的定位 |
| 内存"释放/加速"、健康分数 | 在现代 macOS 上价值存疑，最容易被看成恐吓软件；MacKeeper 曾因"虚构问题诱导购买"被集体诉讼，最终以 $2M 和解（[Wikipedia](https://en.wikipedia.org/wiki/MacKeeper)、[Top Class Actions](https://topclassactions.com/lawsuit-settlements/closed-settlements/mackeeper-class-action-settlement/)） |
| VPN、广告拦截、身份盗用监控、Gmail 清理、云盘 OAuth | 偏离主业，需要账号和联网，破坏"纯本地"卖点 |
| 裸盘数据恢复 | 内置 SSD 在 TRIM 和 FileVault 下恢复率接近 0，会带来退款和口碑损失（[CleverFiles](https://www.cleverfiles.com/help/variables-that-impact-file-recovery-chances/)） |
| 文件粉碎 | 在 SSD + FileVault 下增量价值低（推论），而且与"一切可撤销"相矛盾 |
| 风扇控制 | 有风险，连 Stats 都已停止维护这部分（[GitHub](https://github.com/exelban/stats)） |
| 自动清空废纸篓、"空间不足时自动清缓存" | macOS 已内置这两项（[Apple](https://support.apple.com/guide/mac-help/optimize-storage-space-sysp4ee93ca4/mac)） |
| Lipo 瘦身、语言包裁剪 | 收益低，而且要修改应用包（风险判断属推论） |
| 手机远程访问、长截图、清洁屏幕模式 | 属于"工具箱"式膨胀，和清理定位无关 |

---

## 7. 定价与定位建议：保持买断，把"一次付费覆盖多久"写清楚

**价格锚点。** 一次性买断的锚点有：DaisyDisk $9.99 / 5 台（[daisydiskapp](https://daisydiskapp.com/)），iStat Menus $11.99，Gemini $44.95 / 1 台，Sensei $59 / 3 台（仅限一个大版本），BuhoCleaner 促销价 $25.99（标价 $67.99），CleanMyMac $119.95 / 1 台（Basic，仅限一个大版本，[KB](https://macpaw.com/support/cleanmymac/knowledgebase/purchase-options)）。国内锚点是免费的柠檬和管家，以及 CMM 永久版的 ¥569 标价 / 约 ¥147–223 促销价（[什么值得买](https://post.smzdm.com/p/a90gqqle/)）。值得注意的是，BuhoCleaner 的推广文案里出现过"买断低至 ¥98"（[affiliate repo](https://github.com/peru911/buhocleaner)，可靠性低），恰好和我们的入门价相同。

**建议。** 第一，**¥98 / 2 台、¥168 / 5 台的价格档不需要下调。** 它已经低于 BuhoCleaner 标价，远低于 CleanMyMac。user_needs 推断的接受区间是 ¥68–128，这个区间是推断，不是调研结果。一体化软件的价格本来就该高于 DaisyDisk 这类单品，我们和 DaisyDisk 的价差可以用"一个应用顶五个"来解释。第二，**在官网明确写出升级政策。** CleanMyMac 和 Sensei 的买断都只覆盖当前大版本，如果我们承诺"1.x 全部免费更新"，或者"买断包含 N 年大版本升级"，这就是一个看得见的优势。第三，**"扫描永远免费"要保留，并加强试用转化。** HN 上的建议是"Those who appreciate it will buy it"（[HN 46574450](https://news.ycombinator.com/item?id=46574450)）。可以考虑给免费版一个小额度的实际清理（BuhoCleaner 据称免费版超过 3 GB 才需要手动删，但此说法来自推广页，不可靠），让用户先体验一次"清理后撤销"，体会差异。第四，**宣传主线**建议用三句话："本地运行，不上传、不登录"，"每一次删除都能撤销"，"一次买断，没有订阅"。另外再配一句针对国内的"微信、企业微信真正能清掉的空间"，并直接回应柠檬 #149 所反映的担忧，但不点名攻击竞品。第五，**不要追求"管家"定位。** 国内用户默认"管家"就该带杀毒，而管家 Mac 是免费的，正面竞争没有胜算。我们应该把自己定位成"空间解释 + 安全清理"的专业工具。

---

## 8. 证据局限

**无法访问的来源。** Reddit、小红书、知乎（部分）、B 站、少数派都没能抓取到。所以用户声音主要来自 V2EX、HN、Apple Community 和 App Store 评论，单个帖子回复数大多只有 2–30 条，只能算轶事。以下官方页面返回 403 或 404：MacPaw 商店（无法确认 2026 年多机 Plus 价格和人民币价格）、Bjango（iStat 的 S.M.A.R.T. 和电池细节）、CleverFiles 定价页、Intego 产品页、Sensei 定价页、Nektony Smart Delete 帮助页。柠檬 5.2/5.3 的官方更新日志无法渲染。

**未经核实或相互矛盾的说法。** CleanMyMac 的价格各来源不一致：Macworld 的 Basic/Plus 价格与 TheSweetBits 的 $39.95/年、聚合站的多机价格对不上，App Store 页面显示的"5.6.0 (August 2024)"也疑似解析错误。BuhoCleaner 促销价和 1 台/3 台的对应关系不明；"免费版 3 GB 限制"和"¥98 买断"来自推广仓库。Pearcleaner 的 star 数（14.8k 对 11.7k）和 5.4.x 的发布年份（2024-11 对 2025-11）有冲突，本文采用 2025-11，因为它与"2025 年底暂停"的说法一致。Disk Drill Mac 免费版"500 MB 可恢复额度"应该是 Windows 版的政策，$89 被一处标为"月付"疑似错误。MacKeeper"2026 年未出现在 AV-TEST 名单上"来自二手评测。柠檬 AI 助手的细节、5.3.6 版本号、数据收集说明都来自 TechMoon 这一第三方来源。V2EX 上"AI 删除桌面数据"的帖子无法确认指的是哪款工具。柠檬按聊天图片/视频清理的能力来自 CSDN 二手摘要，没有实机验证。CoreSpotlight 324 GB 和 mediaanalysisd 两个案例来自搜索摘要，原帖没有直接读到。开发缓存和 AI 模型的体积数字大多来自清理软件厂商的博客。Sensei、Gemini 的价格来自第三方评测。

**没有覆盖的内容。** 本次没有对任何竞品做实机测试，功能判断都基于官网、文档和评测。OmniDiskSweeper、Funter、Photos Duplicate Cleaner 没有调研。CleanMyMac v5 是否支持快捷指令、AppleScript、小组件或定时清理，是否有撤销功能，都没有找到文档，表中按"未证实有"处理。快捷指令/自动化、多机家庭授权、IDE/Agent 缓存这几项，没有找到用户需求证据，因此在路线图中排得较低。所有价格接受区间和优先级排序都是基于以上证据的推断，不是用户调研结果，建议 1.3 上线后用激活数据和用户反馈校准。

---

## 结论

这次调研说明，MacClean 和竞品的竞争点不在功能数量。CleanMyMac 在往账号、云端、AI 和杀毒方向扩张，腾讯在往免费"工具箱"方向扩张，开源工具在停更或只解决单一问题。用户反复提出却没人解决好的，是三个具体问题："系统数据为什么这么大"、"微信怎么才能真正清掉"、"删错了怎么办"。前两个是**解释**问题，第三个是**信任**问题。我们已经有业内最完整的可撤销体系和只读安全审计，下一步要把这些能力用到用户最痛的具体场景上，把它们从"后台机制"变成用户看得见的卖点。

还有一点值得注意：我们最容易犯的错误是照着竞品的功能清单去补，尤其是健康分、内存加速、杀毒这类能让演示数字更好看的功能。证据显示，这些恰恰是专家批评、集体诉讼和用户不信任的来源。克制本身就是差异化，这一点应该当作长期定位坚持下去，而不是看成当下的功能短板。
