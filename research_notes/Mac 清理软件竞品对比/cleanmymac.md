# CleanMyMac (MacPaw): competitive inventory, as of October 2026

Research date: 2026-10-02. Latest version found: 5.7.1 (Oct 1, 2026). "CleanMyMac" (v5, released Oct 2024) replaced "CleanMyMac X" (v4). Anything about "CleanMyMac X" below is marked **[legacy X]**.

## Q1. Current modules and features (2024 redesign plus 2025–2026 updates)

### Takeaway
CleanMyMac 5.x has five core modules (Cleanup, Protection, Performance, Applications, My Clutter), plus Space Lens, Cloud Cleanup, a Smart Care one-click flow, a menu bar "Menu" app with a health score, and many 2025–2026 additions: Apple-Intelligence "Smart Insights", Dropbox/OneDrive cloud cleanup, My Activity, My Tools, Notification Center, Gmail "Email Cleanup" and Screen Cleaning Mode. Its malware engine (Moonlock) is the biggest capability MacClean does not have, and MacClean deliberately leaves it out.

### Cited Findings

**Release timeline (official changelog)**: [What's New](https://macpaw.com/cleanmymac/whats-new)
- 5.0.0 (Oct 16, 2024): redesign, with "Redesigned UI … improved navigation".
- 5.0.5 (Feb 10, 2025): Maintenance task "Free Up Purgeable Space" ("cached, temporary, and files that can be redownloaded").
- 5.1.0 (Jun 12, 2025): reimagined Space Lens, a storage map with "folders as bubbles arranged from largest to smallest".
- 5.2.1 (Jul 29, 2025): Cloud Cleanup for iCloud Drive, Google Drive and OneDrive, with Space Lens and Large Files for cloud storage.
- 5.2.6 (Oct 20, 2025): "Smart Insights", "Powered by Apple Intelligence … helpful info about system files".
- 5.3.0 (Dec 17, 2025): Dropbox integration and improved OneDrive.
- 5.4.0 (Feb 26, 2026): "My Activity" dashboard that tracks local and cloud cleanup progress.
- 5.5.0 (Apr 2, 2026): "My Tools", which lets users pin favorite features.
- 5.5.5 (Jul 9, 2026): the Applications module scans in the background, so users can start reviewing before the scan finishes.
- 5.6.0 (Aug 17, 2026): "Notification Center", a hub for updates behind a bell icon.
- 5.7.0 (Sep 25, 2026): "Email Cleanup". It connects a Gmail account and scans for newsletters, promotions, spam and drafts. It sorts mail into categories (Old Promotions, Forgotten Emails, Automated Emails) and can unsubscribe, trash or archive.
- 5.7.1 (Oct 1, 2026): "Screen Cleaning Mode", which "temporarily locks your keyboard and trackpad while you wipe the screen".

**Smart Care (one-click scan)**
- It runs five modules in order:
  - Cleanup: "system junk (like log files, cache files, broken login items…), mail attachments, and trash bins".
  - Protection: a malware scan.
  - Performance: recommends "periodic maintenance scripts and the Flush DNS Cache task".
  - Applications: app updates, excluding macOS and system updates.
  - My Clutter: scoped to duplicates in **Downloads only**.

  Users can deselect modules and review items before running. The KB states: "CleanMyMac doesn't delete any user files or app data unless you choose to." — [KB: Smart Care](https://macpaw.com/support/cleanmymac/knowledgebase/smart-care)
- Macworld describes it as a quick check-up that summarizes results in tiles across the five categories. — [Macworld](https://www.macworld.com/article/352922/cleanmymac-x-review-macos.html)

**Cleanup**
- It targets system junk without touching user files: caches, Trash bins, extra binaries and document versions. It "almost always lets us save a couple of GB" and shrinks System Data. — [TheSweetBits](https://thesweetbits.com/tools/cleanmymac-review/)
- Its sub-categories include system cache, system logs, iOS device backups, language files, Universal Binaries (stripping the unused architecture), broken login items and deleted users. The App Store edition drops these. — [KB: edition differences](https://macpaw.com/support/cleanmymac/knowledgebase/missing-features)
- **[legacy X]** "Photo Junk" was a separate module and was excluded from the App Store edition. — [KB X: missing features](https://macpaw.com/support/cleanmymac-x/knowledgebase/missing-features)

**Protection (Moonlock Engine)**
- Moonlock Engine "powers all the antimalware features … malware removal, real-time malware monitoring, and background scanning". It inspects mail attachments, archives, USB drives, browser extensions and launch items. MacPaw claims scans are 49% faster on Intel and 89% faster on M1 than its old algorithm. — [KB: Moonlock Engine](https://macpaw.com/support/cleanmymac/knowledgebase/moonlock-engine)
- The real-time monitor covers newly installed apps. Periodic deeper background scans cover the whole system and send notifications. The Protection monitor warns when real-time or background monitoring is off. — [KB: protection monitoring](https://macpaw.com/support/cleanmymac/knowledgebase/protection-monitoring)
- It offers Quick, Balanced and Deep scan modes. It monitors camera and microphone access, can revoke permissions, and scans DMGs and attachments. — [TheSweetBits](https://thesweetbits.com/tools/cleanmymac-review/)
- Protection also contains Privacy (browser data including Safari, and Wi-Fi network cleanup) and Application Permissions. — [KB: edition differences](https://macpaw.com/support/cleanmymac/knowledgebase/missing-features)
- MacPaw launched **Moonlock** as a separate security app in Oct 2025. It has real-time protection, smart insights and a built-in VPN. — [9to5Mac](https://9to5mac.com/2025/10/28/macpaw-releases-moonlock-a-standalone-macos-security-app-with-real-time-protection-smart-insights-built-in-vpn-more/); [KB: Moonlock vs CleanMyMac](https://macpaw.com/support/moonlock/knowledgebase/moonlock-and-cleanmymac)

**Performance**
- Maintenance tasks: Flush DNS, Free Up Purgeable Space, free up RAM, reindex Spotlight, Time Machine snapshot management, and periodic maintenance scripts. — [KB: edition differences](https://macpaw.com/support/cleanmymac/knowledgebase/missing-features); [Macworld](https://www.macworld.com/article/352922/cleanmymac-x-review-macos.html)
- It also manages login items and background items/processes. — [TheSweetBits](https://thesweetbits.com/tools/cleanmymac-review/)

**Applications**
- It uninstalls apps along with their leftovers, cleans orphaned leftovers and installation files, and updates non-App Store apps. — [TheSweetBits](https://thesweetbits.com/tools/cleanmymac-review/); [KB: Uninstaller](https://macpaw.com/support/cleanmymac/knowledgebase/uninstaller)
- The direct edition's Updater checks App Store and macOS updates. The App Store edition supports "only custom and Sparkle updates". — [KB: edition differences](https://macpaw.com/support/cleanmymac/knowledgebase/missing-features)

**My Clutter and Space Lens**
- My Clutter finds large, duplicate and similar files, including similar photos, even when names or sizes differ. — [TheSweetBits](https://thesweetbits.com/tools/cleanmymac-review/); [macpaw.com/cleanmymac](https://macpaw.com/cleanmymac)
- Space Lens is an interactive bubble map that drills down into folders. It also works on cloud storage. — [What's New](https://macpaw.com/cleanmymac/whats-new)

**Cloud Cleanup (Plus plan only)**
- It covers iCloud Drive, Google Drive, OneDrive and Dropbox. It shows how synced files affect local storage and removes cloud files. — [Forbes](https://www.forbes.com/sites/marksparrow/2025/07/29/the-latest-version-of-macpaws-cleanmymac-can-now-clean-up-cloud-storage-accounts/); [PR Newswire](https://www.prnewswire.com/news-releases/macpaw-introduces-cloud-cleanup-cleanmymacs-latest-feature-for-smarter-cloud-storage-302514024.html); [What's New](https://macpaw.com/cleanmymac/whats-new)

**Smart Insights (AI)**
- It uses Apple Intelligence on the device to explain what a file or item does, whether it is safe to remove, and what happens if you keep or delete it.
- It appears in Cleanup, Protection, Performance and Applications.
- It requires Apple Silicon and macOS Tahoe 26.
- It supports Simplified Chinese among other languages.

  — [MacPaw news](https://macpaw.com/news/introducing-smart-insights)

**Menu (menu bar app) and Mac health**
- The KB sections cover Protection, Storage, Memory (RAM), Battery, Processor (CPU), Network and Connected devices. — [KB index](https://macpaw.com/support/cleanmymac/knowledgebase)
- The Menu frees RAM and storage, and shows network speed, battery and connected devices. — [TheSweetBits](https://thesweetbits.com/tools/cleanmymac-review/)
- The health score has five levels: Excellent, Good, Fair, Requires Attention and Critical. It factors in malware, disk health, battery health, low disk space, pending updates, unused apps, Trash size, uptime, whether Full Disk Access is enabled, and whether scans are recent. It sends reminders based on conditions and shows recommendations in My Activity. — [KB: Mac health](https://macpaw.com/support/cleanmymac/knowledgebase/mac-health)

**Business edition**
- CleanMyMac Business launched in Jan 2025, and MacPaw announced its discontinuation in July 2026. — [Wikipedia](https://en.wikipedia.org/wiki/CleanMyMac)

### Inferences
- **Features MacClean lacks entirely:**
  - malware detection and removal with real-time monitoring (MacClean is deliberately not antivirus)
  - Cloud Cleanup (iCloud, Google Drive, OneDrive, Dropbox)
  - Gmail Email Cleanup
  - AI explanations of files (Smart Insights)
  - a composite health score and a My Activity progress dashboard
  - Notification Center and condition-based reminders
  - a RAM "free up" action
  - Universal Binary and language-file stripping
  - deleted-user cleanup
  - Wi-Fi network list cleanup
  - updates for App Store apps and macOS (MacClean checks Sparkle feeds only)
  - pinning favorite tools (My Tools)
  - Screen Cleaning Mode
  - scanning USB drives and archives
- **Features MacClean has that CleanMyMac apparently lacks or does not market:**
  - Dev Caches (Xcode, simulators, npm, pip, Gradle, Cargo, idle node_modules)
  - per-app real size including WeChat/QQ chat data and Docker disks
  - Recover Files from APFS snapshots and Time Machine (CleanMyMac only *deletes* TM snapshots)
  - read-only security posture checks (FileVault, firewall, SIP, Gatekeeper, XProtect freshness, remote access)
  - configuration profile review
  - a universal Trash-first approach with undo via Cleanup History
  - Rebuild Launch Services and restart Dock/Finder
  - Bluetooth battery levels in the menu bar
  - File Search with its own index

  I found no CleanMyMac documentation of an undo or cleanup history. The Smart Care KB does not mention undo.
- **Overlapping features where CleanMyMac goes deeper:**
  - Smart Care is broader (it includes malware and updates), but its duplicates check is narrower (Downloads only), while MacClean's Checkup covers exact duplicates across a wider scope.
  - Space Lens extends to cloud drives.
  - CleanMyMac's privacy cleanup includes Wi-Fi networks.

### Gaps
- I could not fetch the full Menu KB because the domain fetch was blocked. Whether the Menu has a network speed test, as MacClean does, is unconfirmed; TheSweetBits only says it "displays network speed".
- I found no official statement on whether removals go to the Trash or can be undone in v5.
- I could not confirm whether Privacy covers Chrome, Edge, Brave and Firefox in v5.

## Q2. Pricing, editions, trial and Setapp

### Takeaway
Since July 2025 CleanMyMac has had two tiers, Basic and Plus. Plus is required for Protection, Space Lens and Cloud Cleanup. For 1 Mac, Basic is about $47.50 per year and Plus about $71.40 per year; one-time licenses are about $119.95 (Basic) and $195.95 (Plus). After the 7-day trial, the direct edition can scan but not clean. MacClean's one-time price of ¥98 for 2 Macs undercuts it heavily.

### Cited Findings
- Macworld (updated Oct 10, 2025), 1 Mac: Basic costs $9.95 per month, $47.50 per year or $119.95 one-time. Plus costs $15.95 per month, $71.40 per year or $195.95 one-time. Multi-Mac plans exist. — [Macworld](https://www.macworld.com/article/352922/cleanmymac-x-review-macos.html)
- Basic lacks Protection (malware, privacy, app permissions), Space Lens and Cloud Cleanup; Plus adds them. — [PopSci](https://www.popsci.com/gear/cleanmymac-software-black-friday-deal/) (search snippet), consistent with [Macworld](https://www.macworld.com/article/352922/cleanmymac-x-review-macos.html)
- The official homepage says "from $3.33/month" and offers a free trial. — [macpaw.com/cleanmymac](https://macpaw.com/cleanmymac)
- Other reported prices are older or conflict:
  - TheSweetBits gives $39.95 per year and $119.95 one-time, with a 7-day trial and a 30-day money-back guarantee. — [TheSweetBits](https://thesweetbits.com/tools/cleanmymac-review/)
  - Aggregators list multi-Mac one-time prices of $191.95 for 2 Macs and $383.95 for 5 Macs, and yearly plans of about $5.95 per month for 2 Macs and $12.95 per month for 5 Macs. These are likely pre-Basic/Plus or Basic prices. — [hamsterstack](https://hamsterstack.com/pricing/cleanmymac/)
- One-time licenses cover updates "for your current major version" only, with discounted upgrades to later versions. Subscriptions include major upgrades. MacPaw Store buyers get 30% off other MacPaw apps. — [KB: purchase options](https://macpaw.com/support/cleanmymac/knowledgebase/purchase-options)
- The App Store edition offers Basic/Plus yearly at $39.99–$65.99, monthly at $9.99–$15.99 and a one-time purchase at $89.99, all with 7-day trials. — [App Store listing](https://apps.apple.com/us/app/cleanmymac/id1339170533?mt=12)
- The App Store edition lacks 22+ features:
  - system caches, system logs, iOS backups, language files, Universal Binaries, broken login items and deleted users
  - all maintenance tasks (DNS flush, purgeable space, RAM, Spotlight reindex, TM snapshots)
  - Safari privacy cleanup, Wi-Fi cleanup, Application Permissions and the menu bar Protection Monitor
  - App Store and macOS update checks

  — [KB: edition differences](https://macpaw.com/support/cleanmymac/knowledgebase/missing-features)
- The Setapp edition has full feature parity with the direct edition and comes with a Setapp subscription that bundles about 260 other apps. — [KB: edition differences](https://macpaw.com/support/cleanmymac/knowledgebase/missing-features); [KB: purchase options](https://macpaw.com/support/cleanmymac/knowledgebase/purchase-options)
- **Trial and free tier:**
  - The trial gives 7 days of full use. After it ends, users "only be able to scan your Mac", and cleanup, optimization and duplicate deletion are blocked.
  - **[legacy X]** The App Store trial capped cleanup at 500 MB.

  — [KB X: trial](https://macpaw.com/support/cleanmymac-x/knowledgebase/trial)

### Inferences
- The scan-free, pay-to-clean model is the same as MacClean's. CleanMyMac adds a second paywall tier (Plus) for security and visualization features.
- For 2 Macs over 3 years, CleanMyMac Plus yearly would cost well over $200. MacClean's one-time ¥98 (about $14) is an order of magnitude cheaper.

### Gaps
- MacPaw's store page returned 403, so I could not confirm official 2026 multi-Mac Plus prices or regional (CNY) pricing.
- The App Store page reported "5.6.0 (August 2024)", which conflicts with the changelog date of Aug 2026. This is likely a parsing error.

## Q3. Criticisms and praise

### Takeaway
Reviewers praise the polished UI, the breadth of tools and Space Lens. They criticize the price (now made worse by the Plus split), malware detection that falls short of real antivirus, overlap with built-in macOS tools, trial auto-renewal surprises and cloud-permission discomfort.

### Cited Findings
- Macworld gave it Editors' Choice (Oct 2025). Praise: the tile UI, the range of tools and flexible pricing. Criticism: higher cost than competitors, and Moonlock missed WaveBrowser and MacSecurity in testing ("not a substitute for dedicated antivirus"). Some users are uncomfortable granting cloud storage access. — [Macworld](https://www.macworld.com/article/352922/cleanmymac-x-review-macos.html)
- TheSweetBits cons: "no real-time antivirus scanning like traditional security software", minimal speed gains on newer Macs, overlap with built-in macOS tools, and the subscription model. Typical cleanups freed 3–8 GB. — [TheSweetBits](https://thesweetbits.com/tools/cleanmymac-review/)
- Reported complaints: some scans offer to remove data that should be kept, and some users missed the trial cancellation deadline and were charged for a year. — [SoftwareHow](https://www.softwarehow.com/cleanmymac-review/) (via search snippet); [Trustpilot](https://ie.trustpilot.com/review/cleanmymac.com)
- App Store review themes: the uninstaller reports success while apps remain, "Grant Access" breaks on macOS 15, and support demands personal data even with a valid App Store purchase. — [App Store listing](https://apps.apple.com/us/app/cleanmymac/id1339170533?mt=12)
- App Store privacy label: email, device identifiers, usage data and diagnostics are collected as "not linked to user", for marketing and analytics. — [App Store listing](https://apps.apple.com/us/app/cleanmymac/id1339170533?mt=12)
- MacPaw's marketing claims: 29M downloads, an average of 5.5 GB cleaned on the first scan, Trustpilot 4.7/5 (3,353 reviews), and Apple notarization. — [macpaw.com/cleanmymac](https://macpaw.com/cleanmymac)

### Inferences
- Several angles are open to MacClean: local-only with no analytics, a one-time price, Trash-first undo, and an honest "not antivirus" stance.
- CleanMyMac's cloud and Gmail features require OAuth access to accounts. That cuts against MacClean's local-only position, which can be a privacy selling point.

### Gaps
- The Reddit r/macapps and r/mac threads and the 少数派 (sspai) review did not surface in my searches, so I have no direct citations from them.
- I found no 2026 independent malware lab results for Moonlock.

## Q4. Automation features

### Takeaway
CleanMyMac's automation is monitoring-driven rather than user-scheduled. It runs real-time and background malware scans, sends health-based reminders, collects notifications in Notification Center, and puts status in the Menu. I found no documented scheduled auto-clean, Shortcuts, AppleScript or desktop widget support for v5.

### Cited Findings
- Background malware scans run periodically and notify the user when threats are found. — [KB: protection monitoring](https://macpaw.com/support/cleanmymac/knowledgebase/protection-monitoring)
- The app reminds users about maintenance based on current conditions and gives recommendations in the Menu and My Activity. — [KB: Mac health](https://macpaw.com/support/cleanmymac/knowledgebase/mac-health)
- Notification Center (5.6.0) and background scanning in Applications (5.5.5) are documented. — [What's New](https://macpaw.com/cleanmymac/whats-new)
- The Smart Care KB has no information on scheduling. — [KB: Smart Care](https://macpaw.com/support/cleanmymac/knowledgebase/smart-care)

### Inferences
- If MacClean added scheduled scans with notifications, or Shortcuts/App Intents, it could exceed CleanMyMac's documented automation.

### Gaps
- I could not verify whether v5 supports Shortcuts, AppleScript, WidgetKit widgets or scheduled cleanup, because no source mentions them.
