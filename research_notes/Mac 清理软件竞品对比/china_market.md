# 中国市场 Mac 清理/管家类软件盘点（截至 2026-10）

Research date: 2026-10-02. Scope: Tencent Lemon (full + App Store Lite), the new 腾讯电脑管家 Mac, BuhoCleaner (Dr.Buho), 360, and indie/open-source tools recommended on V2EX/知乎, plus Chinese user sentiment. MacClean is the comparison baseline (not researched).

## 1. 腾讯柠檬清理 Tencent Lemon: features, WeChat/QQ depth, maintenance, Lite limits

### Takeaway
Lemon is still the default free Chinese Mac cleaner. It has deep cleanup tailored to 100+ apps (WeChat, QQ and 企业微信 included), large/duplicate/similar-photo finders, browser privacy, an uninstaller, login items, a space analyser, "文件搬家" and a strong menu bar monitor (CPU temperature, fan speed, network speed, camera/mic alerts). The closed-source full build is still updated (5.3.x in 2026). The open-source GitHub repo now lags well behind, and Tencent's team has moved its effort to a rewritten **腾讯电脑管家 Mac 版** (June 2026). Open GitHub issues in 2026 report a silent permanent-delete fallback, a Finder hang caused by Lemon's Trash watcher, and open questions about telemetry.

### Cited Findings
**Feature list (official)**
- README feature highlights: 深度扫描清理 with schemes customised per app (Xcode, Sketch, etc.); 大文件清理 (files over 50 MB, custom folders); 重复文件 (content comparison, custom folders); 相似照片; 浏览器隐私清理 (Safari/Chrome and others); 应用卸载 ("不怕卸载有残留"); 开机启动项管理; a customisable status bar showing 内存占用, 磁盘空间, CPU 温度, 风扇转速 and 网速 — [GitHub README](https://github.com/Tencent/lemon-cleaner)
- README technical modules also include LemonSpaceAnalyse (磁盘空间分析), LemonFileMove (文件搬家), LemonHardware (硬件信息), LemonNetSpeed (网络测速) and a privileged LemonDaemon — [GitHub README](https://github.com/Tencent/lemon-cleaner)
- Official site lists: system/app junk, large files, duplicates, similar photos, browser privacy, app uninstall, network detection, menu bar CPU temperature and fan speed, and **camera/microphone usage alerts**. Deep scan specifically targets "微信、QQ、企业微信等通讯工具". The site also states support for "macOS X 10.11及以上" — [lemon.qq.com](https://lemon.qq.com/)
- Third-party write-ups say the WeChat/QQ schemes sort files into cache, logs, data, etc. and "especially support scanning and cleaning WeChat and QQ chat images and videos" — [CSDN summary via search](https://blog.csdn.net/gitblog_00718/article/details/156820806) (secondary source; not verified against the app)
- License: GPL v2 (LemonDaemon) and GPL v3 (rest) — [GitHub README](https://github.com/Tencent/lemon-cleaner)

**Versions and maintenance**
- GitHub: about 6.3k stars and 797 forks; not archived. Last GitHub release **v5.1.20 on 2025-10-22**. Last commit 2026-05-08 ("fix: 修复了若干问题"). Before that, 2025-12-04 "修复MacOS 26上的一些bug" — [GitHub API / releases](https://github.com/Tencent/lemon-cleaner/releases)
- The full (closed) build is reported at **5.3.6, updated 2026-08-31**. A privacy guide dated 2026-08-28 says the main cleaning feature collects "device identification, filenames, paths, file sizes, creation times, and installed software lists" — [TechMoon](https://techmoon.xyz/tencent-lemon-cleaner/) (secondary source)
- Issue #151 (2026-08-10) asks "最新的5.3.5版本什么时候可以开源". A commenter replies "看起来他们已经放弃了这个项目". **The open-source code lags the shipping build** — [Issue #151](https://github.com/Tencent/lemon-cleaner/issues/151)
- **AI assistant**: TechMoon reports the full build has an AI assistant powered by Tencent 元宝 that syncs chat history when logged in and may touch clipboard content — [TechMoon](https://techmoon.xyz/tencent-lemon-cleaner/). A V2EX user (June 2026) warns of "AI删除数据风险" and says "AI上次把桌面数据全部删除了". It is unclear whether this was Lemon's AI or a general AI agent — [V2EX t/1222690](https://www.v2ex.com/t/1222690)
- macOS 26 support: Lite 4.2.12 (2025-12-04) "fixed macOS 26 UI display issues". Issue #128 reports UI misplacement after the Tahoe update. Issue #138 reports a clean-button display bug on macOS 26.2. Issue #135 says an **M5** MacBook Pro cannot read CPU temperature or fan speed. Issue #132 reports high CPU use by LemonMonitor in 5.1.20 — [Lite App Store](https://apps.apple.com/cn/app/%E8%85%BE%E8%AE%AF%E6%9F%A0%E6%AA%AC%E6%B8%85%E7%90%86-lite/id1449962996), [GitHub issues](https://github.com/Tencent/lemon-cleaner/issues)

**Safety, privacy and quality issues raised in 2026**
- #149 (open): duplicate- and large-file cleanup **fall back to permanent deletion (`removeItemAtPath`) when Finder automation authorisation fails**, even though the UI says files go to the Trash — [Issue #149](https://github.com/Tencent/lemon-cleaner/issues/149)
- #150 (open): static analysis found no path that uploads file contents. However, the app loads an embedded page from `sdi.3g.qq.com` with a guid, sends partial serial numbers over plain HTTP to an Apple endpoint, and contains an unused multipart uploader. The reporter asks for a list of the domains it contacts — [Issue #150](https://github.com/Tencent/lemon-cleaner/issues/150)
- #148 (closed): missing client authorisation on the privileged LemonDaemon XPC service — [Issue #148](https://github.com/Tencent/lemon-cleaner/issues/148)
- #145 (open): Lemon's `com.tencent.Lemon.trash.plist` LaunchAgent (WatchPaths on ~/.Trash) can freeze the Finder desktop until Finder and Dock are killed. The reporter says this reproduces 100% of the time — [Issue #145](https://github.com/Tencent/lemon-cleaner/issues/145)
- #147: LemonMonitor creates an mmkv cache folder in ~/Documents. #134: questions about a `~/Library/.sharkgi` file. #133: the login-item manager keeps disabling ToDesk's launch item after reboot — [GitHub issues](https://github.com/Tencent/lemon-cleaner/issues)
- #139: users ask why folders outside the user folder cannot be scanned — [Issue #139](https://github.com/Tencent/lemon-cleaner/issues/139)

**App Store "Lite" version**
- 腾讯柠檬清理(Lite): free, 30.5 MB, macOS 10.11+. Latest version 4.2.13 ("July 7", fixes a similar-photo scan freeze). 4.2.11 (2025-10-22) "enhanced duplicate logic; new WeChat compatibility". Features: junk with 100+ app schemes, large files over 50 MB, duplicates, similar photos, disk space analysis, 文件搬家, and a status bar showing network/CPU/GPU/disk. Too few ratings to show a score. Privacy label: device ID, product interaction and usage data are linked to the user — [Mac App Store CN](https://apps.apple.com/cn/app/%E8%85%BE%E8%AE%AF%E6%9F%A0%E6%AA%AC%E6%B8%85%E7%90%86-lite/id1449962996)
- The official site says "因App Store审核限制，完整版内部分功能无法上架（例如应用卸载等）" — [lemon.qq.com](https://lemon.qq.com/). TechMoon adds that Lite lacks the dedicated browser privacy tool and app removal — [TechMoon](https://techmoon.xyz/tencent-lemon-cleaner/)

### Inferences
- Lemon's moat in China is its free price, its Tencent brand and its first-party WeChat/QQ cleanup schemes. MacClean's App Storage view (per-app size including WeChat/QQ chat data) matches this, but Lemon also deletes chat images and videos by category inside WeChat/QQ. That is a likely feature gap unless MacClean offers per-chat-media cleanup.
- Lemon's menu bar monitor shows CPU temperature and fan speed, which MacClean's menu bar panel does not list. MacClean has battery health, Bluetooth device batteries and a speed test. Lemon also has camera/mic alerts.
- MacClean's "everything to Trash, undoable" design and its local-only design are direct answers to the open #149 permanent-delete fallback and the #150 telemetry questions. These are concrete marketing angles, citable from Tencent's own issue tracker.

### Gaps
- No official changelog text for 5.2 or 5.3. Release notes on lemon.qq.com did not render, so the full 5.3.x feature set (AI assistant details, any new modules) is unconfirmed from a first-party source.
- Whether Lemon has "内存释放" or "文件粉碎" was not confirmed from an official source. Neither appears in the README or on the site.
- The App Store Lite 4.2.13 year is not shown on the page (presumably 2026).

## 2. 腾讯电脑管家 Mac 版 (new 2026 Tencent product; successor direction to Lemon)

### Takeaway
In June 2026 the Lemon team announced a from-scratch, native, free "腾讯电脑管家 Mac 版". It is a toolbox: cleanup, uninstall, login items, a TAV antivirus engine, remote file access from a phone, scrolling screenshots, an AI-era camera/mic privacy guard, memory management, and disk-write and traffic monitoring. Lemon is kept as the "open-source, pure cleaner".

### Cited Findings
- Announced in Lemon issue #146 (2026-06-06) by a Lemon team member: rebuilt "从 0 到 1", native, installer under 50 MB, code "重构、重写（with AI）", and it targets AI-era privacy and security. Asked how it differs, the team said "Lemon我们继续保持开源与纯粹的清理工具定位。管家Mac是工具箱". One commenter wrote "这不是跟lemon一模一样？" — [Issue #146](https://github.com/Tencent/lemon-cleaner/issues/146)
- Product page: TAV antivirus engine; large files, duplicates and similar photos; deep uninstall; remote access from a phone; smart and scrolling screenshots; camera/mic access alerts; memory monitoring and killing background processes; disk-write and network traffic monitoring. Version 18.2.2.0-1014, ARM64 and Intel builds. No price shown (appears free) — [guanjia.qq.com/main-mac.html](https://guanjia.qq.com/main-mac.html)

### Inferences
- Tencent now has two free Mac products. The new one adds **antivirus**, which MacClean explicitly does not do. In Chinese buyers' minds a "管家" is expected to include 杀毒. MacClean should position its Security Center clearly as read-only checks, not antivirus.

### Gaps
- No release date, WeChat-specific cleanup or user reviews were found for the new 管家 Mac.

## 3. BuhoCleaner (Dr.Buho)

### Takeaway
BuhoCleaner comes from a Chengdu-based company (the footer address is on 天府大道, Hi-Tech Zone). It is a paid, direct-sale, CleanMyMac-style cleaner with Simplified and Traditional Chinese UI. It offers both yearly and lifetime licences, discounts heavily (55–70% off "autumn sale"), and is sold outside the App Store because uninstalling apps isn't allowed there. In Chinese channels it shows up mostly through affiliate reviews and piracy sites.

### Cited Findings
- Features: Flash Clean, large files, duplicates (photos, files, folders), Disk Space Analyzer, App Uninstall plus "Deep Uninstall" for 100+ apps, leftover removal, startup items (login items and launch agents), Mac Monitor (RAM, CPU, disk, temperature, fan, network), Xcode cache cleaner, **Secure File Shredder**, Spotlight reindex, flush DNS, Free Up RAM. Languages include 简体/繁體中文. Supports M1–M5. Claims 1,000,000+ downloads and 4.8/5 on Trustpilot (168 reviews) — [drbuho.com/buhocleaner](https://www.drbuho.com/buhocleaner)
- Pricing on the store page (Autumn Sale 2026). Yearly plan "Billed yearly, cancelled anytime": shown $17.99 vs $39.99. Lifetime plan "Pay once": $25.99 vs $67.99. Business plan for 10 Macs lifetime: $119.99 vs $319.99. Each plan has a 1 Mac / 3 Macs toggle. Prices include tax, with a 30-day money-back guarantee. (I read each pair as sale price vs list price; the 1-Mac vs 3-Mac mapping is ambiguous in the scraped text.) — [drbuho.com/buhocleaner/buy](https://www.drbuho.com/buhocleaner/buy)
- Earlier or alternative quoted pricing: Single $39.99 lifetime, Family (3 Macs) $69.99, Business (10) $124.99 — [StackSocial / deals sites via search](https://www.stacksocial.com/sales/buhocleaner-for-mac-business-plan-lifetime-subscription)
- Free version: the FAQ says only "download the trial version… to use all the functions… you need to purchase". An affiliate GitHub review says the only limit is that once junk exceeds **3 GB** you must delete it manually in Finder, and quotes "买断低至 ¥98" — [Dr.Buho FAQ](https://www.drbuho.com/buhocleaner/faq), [peru911/buhocleaner (affiliate, low reliability)](https://github.com/peru911/buhocleaner)
- The FAQ says it isn't on the App Store because uninstall isn't permitted there. It requires a Privileged Helper Tool — [Dr.Buho FAQ](https://www.drbuho.com/buhocleaner/faq)
- Version 1.16.2 is listed as of 2026-07-03 on a Chinese Mac download site. Cracked builds circulate on Chinese sites (macwk, macsky, macat, macked) — [MacWk](https://macwk.cn/app/3751.html), [MacSKY](https://www.macsky.net/68359.html)
- The site footer links "macOS Golden Gate Tips" and says it is "optimized" for macOS Golden Gate, so it claims support for the next macOS — [drbuho.com](https://www.drbuho.com/buhocleaner)

### Inferences
- BuhoCleaner is MacClean's closest pricing and positioning analogue: a Chinese team, direct sale, CN/EN, with a lifetime option. Its sale lifetime price ($25.99 ≈ ¥185) is close to MacClean's ¥98 / ¥168. Its list price is higher, but it runs near-permanent promotions.
- MacClean lacks (as listed): a secure file shredder, "Free Up RAM", and a RAM/CPU temperature/fan monitor (MacClean's menu bar covers memory and CPU but not temperature or fan).
- BuhoCleaner lacks (as listed): duplicate-photo similarity, a privacy/browser cleaner, a security audit (TCC, profiles, extensions), snapshot/Time Machine recovery, WeChat/QQ chat-data sizing, and Trash-first undo.

### Gaps
- No reliable Chinese-community reception data (V2EX, 少数派 or 知乎 threads specifically about BuhoCleaner) was found. It does not appear in the June 2026 V2EX recommendations thread.

## 4. Other Chinese-market competitors (360, 猎豹, 火绒, indie)

### Takeaway
360's Mac cleaner is free and still on the App Store, but its last update was in Dec 2024, so it is effectively dormant. No current 猎豹/Clean Master or 火绒 Mac cleaners were found. On V2EX the 2026 mindshare has moved to open-source or indie tools: Pearcleaner, **Mole** (a CLI that is free plus a paid GUI) and OmniDiskSweeper, along with Nektony's App Cleaner & Uninstaller and DaisyDisk.

### Cited Findings
- 360安全卫士极速版 (Beijing Qihoo), Mac App Store, free: hardware info, disk cleanup, one-click uninstall, large files, smart scan (1.0.1081), duplicate files (1.0.1050) and duplicate folders (1.0.1060). English UI added in 1.0.1080. **Last version 1.0.1082 on 2024-12-22**. Too few ratings — [Mac App Store](https://apps.apple.com/us/app/360%E5%AE%89%E5%85%A8%E5%8D%AB%E5%A3%AB%E6%9E%81%E9%80%9F%E7%89%88/id6449414501?mt=12)
- Pearcleaner (open-source, alienator88): about 14.8k GitHub stars, last release 5.4.3 (2025-11-26), last push 2026-06-22. Recommended on V2EX as "开源、功能强大". One user who tried cleanmymac, mole, lemoncleaner and pearcleaner settled on Pearcleaner — [GitHub API](https://github.com/alienator88/Pearcleaner), [V2EX t/1222690](https://www.v2ex.com/t/1222690)
- In the V2EX thread "macOS 上有什么比较好用的清理软件" (2026-06-25), recommendations were Mole ("够用了"; the GUI price rose from $9 to $19), Pearcleaner, OmniDiskSweeper ("简单，免费，好用"), App Cleaner & Uninstaller (paid), DaisyDisk, and 柠檬清理 — [V2EX t/1222690](https://www.v2ex.com/t/1222690)
- An indie developer on V2EX (2026-04) built a "系统数据" analyser. The biggest culprits in the screenshot were "爱思助手备份、微信、飞书、企业微信、Chrome". Replies pushed back on WeChat-公众号 distribution ("凡公众号引流不看", "为什么不放 Github") and recommended Mole and OmniDiskSweeper — [V2EX t/1205096](https://v2ex.com/t/1205096)
- Lemon issue #152 (2026-08-25) is an ad for "Eos", described as "免费、无广告、无订阅的 Mac 磁盘清理工具". This shows new free indie entrants pitching against Lemon — [Issue #152](https://github.com/Tencent/lemon-cleaner/issues/152)
- Another App Store app, "App Cleaner - App Uninstaller" (id6748003724), is free, macOS 13+ and 3.7 MB. Nektony's App Cleaner & Uninstaller v8 added VoiceOver support and update detection — [App Store](https://apps.apple.com/bh/app/app-cleaner-app-uninstaller/id6748003724?mt=12), [search summary](https://www.malavida.com/en/soft/app-cleaner/mac/)

### Inferences
- The Chinese big-vendor field has narrowed to Tencent (Lemon plus 管家 Mac). 360 is dormant. The paid market sits between CleanMyMac (seen as expensive and subscription-based), BuhoCleaner and indie tools. Price-sensitive developers lean toward open source (Pearcleaner, Mole).

### Gaps
- No evidence that 猎豹/Clean Master for Mac or 火绒 Mac exist in 2026. Searches returned nothing relevant (treat as "not found", not "confirmed absent").
- No specific "Mac 清理大师" or "App Cleaner 8" Chinese indie product could be identified.
- Pearcleaner's Simplified Chinese localisation status was not verified.

## 5. What Chinese users want or complain about

### Takeaway
The recurring themes are WeChat, 企业微信 and 飞书 eating tens of GB; an opaque "系统数据" figure; distrust of domestic "管家" apps over privacy; dislike of subscriptions and price hikes; fear of accidental deletion (now including AI agents deleting files); and scepticism that cleaning makes a Mac faster.

### Cited Findings
- WeChat bloat: 知乎 articles say WeChat auto-caches chat images, videos and files even when they were not saved. They direct users to `~/Library/Containers/com.tencent.xinWeChat/.../` and say the Cache and predownload folders are safe to delete — [知乎 2026](https://zhuanlan.zhihu.com/p/2066148461691548684), [知乎 M1 WeChat cleanup](https://zhuanlan.zhihu.com/p/17815665199)
- System Data: 知乎 2026 posts ("系统数据暴涨上百G", "释放50G+") describe it as unclassified caches, logs, **Time Machine local snapshots** and third-party leftovers — [知乎](https://zhuanlan.zhihu.com/p/2068279907994678775), [知乎](https://zhuanlan.zhihu.com/p/2004495413282113487)
- Electron apps and iOS backups (爱思助手), WeChat, Feishu, 企业微信 and Chrome are the biggest consumers — [V2EX t/1205096](https://v2ex.com/t/1205096)
- Privacy distrust: "国产的管家类更是不敢用". Lemon praised: "柠檬清理腾讯自家的软件效果是很好的，比如微信、企业微信". Complaints: "卸载后有残留服务", and "清理了之后…很多东西变卡了". There is also scepticism that cleaners are needed at all — [V2EX t/627143 (2019)](https://global.v2ex.com/t/627143)
- 2026: "清理后系统也不会变快"; prefer "手动清理自己知道的文件"; worries about AI-driven deletion; complaints about subscription and price (CleanMyMac too expensive, Mole's price hike) — [V2EX t/1222690](https://www.v2ex.com/t/1222690)
- Indie pitch language that works: "免费、无广告、无订阅" — [Lemon Issue #152](https://github.com/Tencent/lemon-cleaner/issues/152)

### Inferences
- MacClean's strongest China-market messages are: local-only (no account, no telemetry), recoverable via Trash and undo, one-time purchase (no subscription), and a clear breakdown of 系统数据 including TM snapshots. Each counters a cited complaint.
- MacClean should state publicly that it does not claim to "speed up" the Mac, given the scepticism. It should also add a WeChat/企业微信/飞书-specific cleanup path (cache/predownload, old chat media by date), since that is the #1 concrete pain point.

### Gaps
- 小红书 and Bilibili content was not reachable or searched effectively. No quotes from those platforms.
- 少数派 articles on Mac cleaners in 2026 were not found in searches.

## 6. Feature gap matrix vs MacClean (synthesis)

### Takeaway
MacClean is broader than any Chinese competitor on safety (Trash-first and undo), security audit, recovery, dev caches and privacy. It is weaker on WeChat/QQ chat-media cleanup granularity, menu bar hardware sensors (temperature, fan), free price (vs Lemon and 管家 Mac), antivirus perception (vs 管家 Mac), a file shredder and RAM-freeing (vs BuhoCleaner), and 文件搬家 (vs Lemon).

### Cited Findings
- Lemon has: per-app deep clean including WeChat/QQ/企业微信; 文件搬家; CPU temperature, fan and network speed in the menu bar; camera/mic alerts; free — [README](https://github.com/Tencent/lemon-cleaner), [lemon.qq.com](https://lemon.qq.com/)
- 管家 Mac has: antivirus (TAV), remote phone access, screenshots, memory killing, traffic and disk-write monitoring, AI privacy guard; free — [guanjia.qq.com](https://guanjia.qq.com/main-mac.html)
- BuhoCleaner has: Secure File Shredder, Free Up RAM, temperature and fan monitor, deep uninstall for 100+ apps; yearly or lifetime pricing — [drbuho.com](https://www.drbuho.com/buhocleaner), [store](https://www.drbuho.com/buhocleaner/buy)
- 360极速版 has: duplicate folders, hardware info; dormant since 2024-12 — [App Store](https://apps.apple.com/us/app/360%E5%AE%89%E5%85%A8%E5%8D%AB%E5%A3%AB%E6%9E%81%E9%80%9F%E7%89%88/id6449414501?mt=12)

### Inferences
- **MacClean lacks**: (1) WeChat/QQ chat image and video cleanup by type and date, rather than just showing the size; (2) CPU temperature and fan speed in the menu bar; (3) camera/mic in-use alerts; (4) a secure shredder; (5) "free up RAM" (often considered a placebo, but it is expected in China); (6) 文件搬家 to external or cloud storage; (7) duplicate *folders* (360).
- **MacClean is clearly stronger**: Trash-first and undo for everything (vs Lemon's documented permanent-delete fallback); a security audit of TCC, profiles, launch items and extensions (none of the cleaners have this); APFS snapshot and Time Machine recovery; dev caches; iOS backups and firmware; Sparkle update checks; orphaned-leftover scans; a local-only privacy stance. MacClean's price (¥98 / 2 Macs) is below BuhoCleaner's list price.
- **MacClean is weaker**: Lemon and 管家 Mac are free with Tencent's brand trust for WeChat. Tencent has first-party knowledge of WeChat's file layout.

### Gaps
- Hands-on verification of any of these apps' actual behaviour was out of scope.
