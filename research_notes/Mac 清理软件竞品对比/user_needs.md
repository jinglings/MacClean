# What Mac users want from, and complain about, cleaner and maintenance apps (2024–2026, EN + ZH)

Method note: Reddit (old.reddit and reddit search) could not be fetched from this environment, and site-restricted web searches returned no Reddit threads. 小红书 and 知乎 pages returned 403 or were not indexed. So the evidence below leans on Hacker News, V2EX, Apple Community, Apple Developer Forums, TidBITS Talk, App Store review pages, GitHub and press coverage. Engagement counts are given where they were visible. Most individual threads were small (2–30 replies), so treat single quotes as anecdotes unless several sources agree.

## 1. Top storage pain points in 2024–2026, and which ones current cleaners handle poorly

### Takeaway
"System Data / 其他 is huge and I can't tell why" is the most common complaint, and it keeps coming back. Users on 256 GB Macs report 150–330 GB of opaque System Data. In China, WeChat (微信) and WeCom (企业微信) storage is the top single-app complaint, and WeChat's own "clear cache" button is widely believed to do nothing. Among developers, Xcode, simulators, Docker.raw and, since 2025, local AI models (Ollama, LM Studio, Hugging Face) are the big hidden consumers. These categories are new enough that a crop of small indie "dev/AI cache cleaner" apps appeared in 2025–26. That suggests incumbents like CleanMyMac and Tencent Lemon don't handle them well.

### Cited Findings
**System Data / "Other"**
- Apple Community, Feb 26 2025: "System data has made my computer unusable... I'm looking at 233 GB of system data I can't delete." This was a 256 GB iMac on macOS 15.3.1. The only answer pointed to iPhone backups, and the thread was closed (1 "me too"). — [Apple Community 255987206](https://discussions.apple.com/thread/255987206)
- Apple Developer Forums, Oct 2024 (M2 Air, 256 GB): "in just a few months, my Mac has accumulated 170GB of data under 'Other Users and Shared,' 'macOS,' and 'System.' 170GB out of 245GB is absurd". 401 views, sent elsewhere as off-topic. — [Apple Dev Forums 766370](https://developer.apple.com/forums/thread/766370)
- Other threads are titled "macOS Sequoia system data is 200 GB" and "Why is Sequoia taking 154gb of system data?" — [Apple Dev Forums 758416](https://developer.apple.com/forums/thread/758416); [MacRumors](https://forums.macrumors.com/threads/why-is-sequoia-taking-154gb-of-system-data-need-to-clear-it.2453366/) (403, could not read the body)
- Specific causes reported on Sequoia: a Spotlight bug that writes huge index files to `~/Library/Metadata/CoreSpotlight` (one user found 324 GB), and a bloated `com.apple.mediaanalysisd` cache that was fixed by deleting it and updating to 15.2. — summarized in search results for [Apple Community 255806791](https://discussions.apple.com/thread/255806791) and [256249051](https://discussions.apple.com/thread/256249051). I did not read these threads directly, so treat the details as secondhand.
- Hacker News founder, 2025: "System Data in my Mac was taking up 300GB". He spent months working out which caches and logs to clear, and built a cleaner because "CleanMyMac is a subscription - I refuse to pay subscription fees for Mac apps that run locally." (3 points, 2 comments) — [HN 46574450](https://news.ycombinator.com/item?id=46574450)
- Older but the same pattern: a web developer had "350GB consumed by 'Other'". Answers were to delete `~/Library/Caches` ("Right now, it's 56GB") and use GrandPerspective. — [Ask HN 31974984](https://news.ycombinator.com/item?id=31974984) (2022)
- Chinese equivalent: "mac 的存储空间里面的'其他'类别占了 60G，有什么清理方法吗" — [V2EX 876152](https://v2ex.com/t/876152)

**WeChat / QQ / WeCom (China)**
- V2EX, Dec 4 2024, "Mac 端的微信、企微这也太占空间了啊，腾讯也太没社会责任感了". One user reported WeChat using 172 GB. Replies: "垄断了不用考虑用户体验的"; "微信自己说记录在云端不保存（乐），所以都存在客户硬盘里了". Tencent Lemon was recommended, with sarcasm that it is "自产自销". — [V2EX 1094857](https://v2ex.com/t/1094857)
- V2EX, Feb 17 2025 (14 replies): WeChat's cache button shows "0B" but 13.8 GB stays on disk. The consensus was that the button is decorative. Workarounds: delete `~/Library/Containers/com.tencent.xinWeChat/.../2.0b4.0.9` by hand, back up then reinstall WeChat and re-import chats, Tencent Lemon, or a symlink to an external drive. — [V2EX 1111926](https://www.v2ex.com/t/1111926)
- Older threads show the problem is long-running: "Mac 上微信占有空间 32GB" with only 5 GB free on 512 GB, and "刚刚清理了 62G". — [V2EX 791330](https://v2ex.com/t/791330); [V2EX 621978](https://www.v2ex.com/t/621978)
- An open-source "Clean My WeChat" tool reached 3.0 in 2026 with 5,000+ GitHub stars and 300k+ downloads (developer's claim). The developer says it beats WeChat's built-in cleanup because it is "使用更方便，还可以定期自动清理". Users replied with crashes on macOS 15.6 and failed WeChat detection on newer macOS. — [V2EX 1217802](https://www.v2ex.com/t/1217802)

**Developer tooling**
- Many 2025–26 guides, nearly all written by small cleaner vendors, cite Xcode DerivedData at 10–50 GB, simulators and DeviceSupport at 20–80 GB, and Docker.raw at 20–60 GB+. They also note that "Docker.raw never shrinks by itself". These are vendor sizes, not user surveys. — [dev.to](https://dev.to/nixeton/your-dev-tools-are-why-your-mac-is-full-heres-how-to-reclaim-50-100gb-3n8b); [ClearDisk Docker guide](https://bysiber.github.io/cleardisk/blog/docker-disk-space-cleanup-mac.html); [CleanMyDev "12 GB Xcode vs 180 GB System Data"](https://cleanmydev.com/blog/xcode-vs-system-data-storage/)
- A HN Show HN author says caches can take "30–40% of disk space on systems with Docker, browsers, and dev tools". — [HN 46568518](https://news.ycombinator.com/item?id=46568518)
- Mole (tw93), an open-source CLI cleaner, has about 68.9k GitHub stars. It targets npm/pnpm caches and build artifacts (node_modules, target, .build, dist) and has `--dry-run`, a whitelist and an operations log. Its README does not highlight AI model caches. — [GitHub tw93/Mole](https://github.com/tw93/mole)

**Local AI models**
- Ollama stores models in `~/.ollama/models` at 4–45 GB each. Hugging Face caches in `~/.cache/huggingface/hub`, "often the single largest hidden folder on an ML machine". These figures come from vendor and guide sites. — [Mole blog](https://mole.fit/blog/how-to-remove-ai-tool-leftovers-mac); [deepcleanmac](https://deepcleanmac.com/blog/clean-up-local-ai-models-on-mac); [Ollama issue #4122](https://github.com/ollama/ollama/issues/4122) (a user asking how to delete models to free space)
- A Jan 2026 HN post, "Clutterfall", targets "browser and dev and AI caches" plus chat apps. Its pitch is "minimal and transparent — not a 'tune-up' app", with no background processes and no analytics. The only comment asked how it differs from OnyX (1 point, 2 comments). — [HN 46711394](https://news.ycombinator.com/item?id=46711394)

**Other categories**
- Users and helpers often cite iOS backups (`MobileSync/Backup`) and Time Machine local snapshots (`tmutil deletelocalsnapshots`) as hidden System Data. — [Apple Community 255987206](https://discussions.apple.com/thread/255987206); [Apple Dev Forums 766370](https://developer.apple.com/forums/thread/766370)
- Tencent Lemon App Store reviews ask it to detect orphaned device backups and downloaded phone apps. — [App Store CN Lemon](https://apps.apple.com/cn/app/%E8%85%BE%E8%AE%AF%E6%9F%A0%E6%AA%AC%E6%B8%85%E7%90%86/id1449962996)

### Inferences
- Rough rank by how often it came up: (1) opaque System Data, which includes snapshots, Spotlight/mediaanalysisd bugs and iOS backups; (2) WeChat/WeCom in China; (3) Xcode, simulators and Docker for developers; (4) AI model caches, which are fast-growing but mostly visible through vendor content so far. I found little user discussion of Photos, iCloud Drive local copies, Adobe or Steam in this pass. That reflects the sources I could reach, not proof those problems are minor.
- What users are missing is an explanation, not more cleaning. Every System Data thread is someone asking *why*, and the helpers answer with folder paths. An app that breaks System Data down into named, explained buckets ("Spotlight index 41 GB — a known macOS 15 bug; safe to rebuild") speaks directly to this.
- WeChat is a strong differentiator for a Chinese-localized app. Users distrust WeChat's own button, Tencent Lemon's motives (自产自销), and fragile open-source scripts. They want reliable, version-robust cleanup that preserves chat history and runs on a schedule.
- The flood of tiny 2025–26 dev/AI cleaners (ClearDisk, CleanMyDev, DeepClean, Clutterfall, FreeUpMyMac, mac-cleanup-go) suggests incumbents don't cover these categories well. It also means the niche is crowded and the bar is low.

### Gaps
- No Reddit vote counts: Reddit could not be fetched.
- No user-sourced numbers for Photos libraries, iCloud "Optimize Storage" local copies, Adobe caches or Steam.
- No 小红书 data.

## 2. What users distrust, and whether they think cleaners are needed at all

### Takeaway
Distrust comes from two sides. Experts and Apple Community helpers say cleaners do more harm than good. Users who do buy one complain about subscriptions, opaque "smart" cleaning and things that didn't actually get removed. On top of that, CleanMyMac's brand is a malware lure: fake CleanMyMac sites and cracks were used to spread infostealers in 2024–2026, which ties the category to danger. What convinces skeptics is a specific, visible problem (hundreds of GB of System Data, a 172 GB WeChat folder) together with a review-first tool that shows exactly what it will delete.

### Cited Findings
- Howard Oakley (Eclectic Light) has long held that cleaners do no good, saying he has "never seen any of those tools do any good" and has seen the damage they cause. In Jan 2025 he argued apps should ship install manifests so third-party cleaners aren't needed: "if it doesn't know what files it installs, it shouldn't be offered to the public." A reader reported "approximately 3GB of leftover junk" and didn't know which files were safe to remove. — [Eclectic Light 2016](https://eclecticlight.co/2016/05/28/why-you-shouldnt-use-cleaning-or-housekeeping-apps/); [Eclectic Light 2025-01-26](https://eclecticlight.co/2025/01/26/last-week-on-my-mac-can-we-make-cleaning-up-our-macs-simpler/)
- HN commenter: "It would be really great if operating systems and applications didn't have to be constantly cleaned up in the first place. Way too much software uses the user's filesystem as their personal dumping ground for crap." — quoted in search summary of [HN Show HN threads](https://news.ycombinator.com/item?id=42250429) (exact thread not verified)
- The review-first rationale from the mac-cleanup-go developer: existing tools "either automatically remove files or obscure how items are categorized, making them difficult to trust." — [HN 46568518](https://news.ycombinator.com/item?id=46568518)
- Chinese skepticism: in a V2EX thread on CleanMyMac's ¥248/year price (2020, 27 replies), users said "想开了，也就不用这个软件了" and "看开了真的没必要". — [V2EX 706203](https://www.v2ex.com/t/706203)
- A Tencent Lemon reviewer says: "虽然不知道到底清理了什么但是看着减少删除一些东西还是算开心". Another asks for "可视的清除界面". These users can't see what the app deleted. — [App Store CN Lemon](https://apps.apple.com/cn/app/%E8%85%BE%E8%AE%AF%E6%9F%A0%E6%AA%AC%E6%B8%85%E7%90%86/id1449962996)
- CleanMyMac App Store complaints (US): "A Joke and a waste..." (Jan 2024) says uninstalls were reported done but the apps remained. "Doesn't appear to function with macOS 15" (Oct 2024, 2★) says "Grant Access" does nothing. "Poor Customer Service" says they wanted card details before helping. Rave 5★ reviews exist alongside these. — [App Store US CleanMyMac](https://apps.apple.com/us/app/cleanmymac/id1339170533?see-all=reviews)
- AlternativeTo's user summary of CleanMyMac: "way too many features which you'll probably won't need… cleans too much things that you probably won't gain any benefit from, and runs in background whether you want it or not". Users also report it causing system issues and being hard to remove. — [AlternativeTo CleanMyMac](https://www.alternativeto.net/software/cleanmymac/about/)
- Malware association: fake "CleanMyMacCrack.dmg" carried a stealer (Moonlock, Jun 2024). Cthulhu Stealer posed as CleanMyMac (Aug 2024). A fake CleanMyMac site pushed SHub Stealer through ClickFix (2026). — [Moonlock](https://moonlock.com/macos-stealer-cleanmymac-crack); [Cybernews](https://cybernews.com/security/fake-cleanmymac-website-delivers-macos-malware/); [Hackread](https://hackread.com/fake-cleanmymac-site-clickfix-shub-stealer-macos/)
- TidBITS Talk on Mole (Jan 2026): mixed. "i downloaded it… after one run froze… I can't endorse this one" (rda). Another user reported it working fine on three Macs. A UX gripe: "They should show it is busy even if it's a terminal app." — [TidBITS Talk](https://talk.tidbits.com/t/mole-a-terminal-tool-to-clean-and-optimize-mac-environment/32710)

### Inferences
- The "you don't need a cleaner" advice targets one-click "optimize/speed up" junk cleaning. It doesn't argue against diagnosing space or uninstalling apps fully. Positioning MacClean as "find and explain what's using space; you decide; undoable" rather than "speed up your Mac" sidesteps most expert criticism.
- Trash-first undo and a visible, itemized preview answer two of the most specific complaints: not knowing what was deleted, and deleting needed files.
- Because of the malware association, a clean, official download channel, notarization and a clear "no background agents unless you enable them" stance count as trust signals.

### Gaps
- No quantified data on how many people believe cleaners are unnecessary. This is drawn from expert opinion and a few threads.
- No direct evidence on App Store versus direct-download preference.
- Telemetry complaints about specific cleaners were not found. Clutterfall's "no analytics" pitch suggests privacy is a selling point but isn't evidence of demand.

## 3. What makes users recommend an app

### Takeaway
The apps the community recommends are free or open source and do one thing transparently: Pearcleaner (~11.7k stars), Mole (~69k stars), AppCleaner, GrandPerspective, OmniDiskSweeper and OnyX. In China, Tencent Lemon is the default recommendation because it's free. Recommendations hinge on transparency (preview, dry run), being free or one-time, being native and lightweight, and doing a specific job well. Trials matter: "if they have used it, they are more likely to recommend it."

### Cited Findings
- Pearcleaner: free, source-available, Swift/SwiftUI, Finder extension, Homebrew management, a "Sentinel" monitor using about 2 MB RAM, Steam game support, 11.7k+ stars. The developer notes updates have slowed because of a day job. — [GitHub Pearcleaner mirror](https://github.com/szgambol/Pearcleaner); [repo writeup](https://arifsolmaz.github.io/repo/2026/02/22/pearcleaner/)
- Mole: about 68.9k stars, GPL-3.0, "combines CleanMyMac, AppCleaner, DaisyDisk, and iStat Menus style workflows". Dry run, whitelist, `mo history` log. A paid native app sits on top. — [GitHub tw93/Mole](https://github.com/tw93/mole); [mole.fit](https://mole.fit/)
- AlternativeTo lists the top CleanMyMac alternatives as CCleaner, Canta, AppCleaner, Mole and Pearcleaner. — [AlternativeTo](https://alternativeto.net/software/cleanmymac/news)
- On HN, users advise visualization first, cleanup second: GrandPerspective ("this really old, free, open source one") and deleting `~/Library/Caches`. — [Ask HN 31974984](https://news.ycombinator.com/item?id=31974984)
- On V2EX, recommended alternatives to CleanMyMac are Tencent Lemon (free), AppCleaner, TinkerTool System ("superior… at lower cost") and Setapp (bundle value). — [V2EX 706203](https://www.v2ex.com/t/706203)
- HN advice to a new cleaner developer: offer a trial. "Those who appreciate it will buy it. Those who don't want to buy your software, will anyway never pay for it." — thisislife2, [HN 46574450](https://news.ycombinator.com/item?id=46574450)
- Reaction to CleanMyMac's 2024 redesign: some users complained that tools now take extra clicks. — [How-To Geek review](https://www.howtogeek.com/cleanmymac-2024-review/); [MacRumors](https://www.macrumors.com/2024/10/16/macpaw-releases-redesigned-cleanmymac/)

### Inferences
- A paid entrant competes with free and open-source tools on the narrow jobs: uninstall (Pearcleaner), disk map (GrandPerspective), dev caches (Mole). MacClean has to justify its price through integration, explanation, undo, and categories the free tools miss (WeChat, AI models, snapshots, recovery), plus a polished native and Chinese UX.
- Mole's star count (much higher than Pearcleaner's), and the fact that it's made by a Chinese developer (tw93), point to large demand among developers and Chinese-speaking users for transparent cleanup.

### Gaps
- No direct evidence found that Chinese localization drives recommendations, apart from Tencent Lemon's dominance in Chinese threads.
- No user evidence on whether "undo" is a stated buying criterion. It is inferred from complaints about fear of deleting things.

## 4. Pricing sentiment

### Takeaway
Subscription fatigue is strong and explicit. CleanMyMac's $39.95/yr (about ¥210–298/yr in China) and $119.95 lifetime (about ¥569) are widely seen as too expensive, and Chinese users historically called ¥248/yr not worth it. In China, buyers anchor on free Tencent Lemon and discounted reseller keys (about ¥147–223 perpetual during sales). Reasonable inference: a one-time ¥68–¥128 / $19–$39 price with a usable free tier would be welcome. That range is inferred, not measured.

### Cited Findings
- CleanMyMac 2024 pricing: $39.95/yr subscription or $119.95 one-time. Previous one-time owners get up to 50% off to upgrade. Coverage notes users' "biggest gripe is yet another app moving to a subscription model… 40 dollars a year by default is a lot". — [MacRumors 2024-10-16](https://www.macrumors.com/2024/10/16/macpaw-releases-redesigned-cleanmymac/); [9to5Mac](https://9to5mac.com/2024/10/16/macpaw-releases-major-update-to-cleanmymac-with-fresh-design-and-new-features/)
- Chinese pricing reported: ¥210/yr or ¥569 perpetual. A 2026 review cites ¥298/yr. Resellers offered about ¥147 (Double 11) and ¥156 (Double 12), with perpetual listings at ¥223. These come from search-result aggregation of reseller and review pages, some of them reseller-affiliated. — [腾讯新闻 CMM5](https://news.qq.com/rain/a/20241016A0A61H00); [什么值得买](https://post.smzdm.com/p/a90gqqle/); [mycleanmymac reseller](https://www.mycleanmymac.com/buy.html)
- V2EX: "这个软件很好用 但是这个价格就让我觉得很不好用" (lslqtz) on ¥248/yr. — [V2EX 706203](https://www.v2ex.com/t/706203)
- HN founder: "I refuse to pay subscription fees for Mac apps that run locally." — [HN 46574450](https://news.ycombinator.com/item?id=46574450)
- DaisyDisk anchors the one-time price for disk visualization at about $9.99–$11.99. — [search summary / comparison pages](https://www.theodorehq.com/shiny/blog/daisydisk-vs-cleanmymac)
- Tencent Lemon is free with no ads and is often cited as the free baseline in China. — [V2EX 1094857](https://v2ex.com/t/1094857); [少数派/CSDN roundup](https://blog.csdn.net/weixin_43871154/article/details/146306045)

### Inferences
- "Local-only app" plus "subscription" is a mismatch that users name explicitly, so a one-time license is a real selling point worth putting front and center.
- China pricing has to beat "free Lemon" and "¥150 discounted CMM perpetual" on perceived value. A Mac-specific WeChat cleanup that actually works may be the single feature that justifies paying.

### Gaps
- No survey data on willingness to pay. The price ranges above are inferred.
- Family or multi-Mac license expectations were not found in user discussions. DaisyDisk's "up to 5 Macs" is the only data point.

## 5. Emerging needs no cleaner serves well yet

### Takeaway
Users or new indie entrants clearly point to five needs: (a) a plain-language breakdown of "System Data", including macOS bugs like CoreSpotlight bloat; (b) local AI model and agent caches; (c) Docker.raw and VM images that never shrink on their own; (d) reliable, scheduled WeChat/WeCom cleanup that keeps chat history; (e) automation, meaning scheduled or periodic cleanup. I found no user evidence for demand around Shortcuts integration or family license management.

### Cited Findings
- There is no good explainer for System Data: the threads end with folder paths or are closed without resolution. — [Apple Community 255987206](https://discussions.apple.com/thread/255987206); [Apple Dev Forums 766370](https://developer.apple.com/forums/thread/766370)
- AI caches: new apps explicitly target them (Clutterfall, Mole's AI leftovers guide, DeepClean). Users ask how to delete Ollama models. — [HN 46711394](https://news.ycombinator.com/item?id=46711394); [Mole blog](https://mole.fit/blog/how-to-remove-ai-tool-leftovers-mac); [Ollama #4122](https://github.com/ollama/ollama/issues/4122)
- Docker.raw needs a special reclaim step (`docker/desktop-reclaim-space`) after pruning. — [ClearDisk Docker guide](https://bysiber.github.io/cleardisk/blog/docker-disk-space-cleanup-mac.html)
- Scheduled WeChat cleanup is the main stated benefit of the open-source Clean My WeChat ("还可以定期自动清理"). Users also suggest symlinking WeChat data to external drives. — [V2EX 1217802](https://www.v2ex.com/t/1217802); [V2EX 1111926](https://www.v2ex.com/t/1111926)
- An app-install manifest / complete-uninstall need was raised by Oakley and readers. — [Eclectic Light 2025](https://eclecticlight.co/2025/01/26/last-week-on-my-mac-can-we-make-cleaning-up-our-macs-simpler/)
- A Tencent Lemon user asked for a simpler memory-cleanup path from the status bar. That review is from 2019, so it's old. — [App Store CN Lemon](https://apps.apple.com/cn/app/%E8%85%BE%E8%AE%AF%E6%9F%A0%E6%AA%AC%E6%B8%85%E7%90%86/id1449962996)

### Inferences
- The biggest opening for MacClean is an explanatory Storage Map plus a System Data breakdown in plain Chinese and English, with known-bug detection (CoreSpotlight, mediaanalysisd, local snapshots, iOS backups), backed by trash-first undo.
- Per-chat WeChat cleanup (by chat or contact, by date, keeping text and dropping media) would outdo the bulk "clear all" of WeChat and Lemon. Chinese users are clearly frustrated, though I found no thread asking for per-chat cleanup by name.
- AI model and agent caches are a fast-moving category that competitors are only now adding. Covering Ollama, LM Studio, Hugging Face and the various agent and IDE caches early is cheap to do and makes a good marketing hook.

### Gaps
- Shortcuts or automation integration, multi-Mac or family licensing, and LLM-agent tool caches (Claude Code, Cursor and similar): I found no user-sourced demand evidence in this pass.
- Recovery of deleted files from snapshots and Time Machine: no user discussion collected here (a sibling note covers recovery).
