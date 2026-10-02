# Mac maintenance, monitoring, security-suite and data-recovery competitors (as of Oct 2026)

Scope: MacKeeper, Intego, Norton/Avast cleanup (brief), OnyX, iStat Menus, Stats, Disk Drill, Apple built-in storage management. MacClean (our app) is the reference frame and was not researched. Research date 2026-10-02. Some vendor pages (bjango.com, cleverfiles.com pricing, intego.com) could not be fetched directly, so figures for those come from reviews and the search snippets noted below.

## MacKeeper: features, pricing, reputation history, current status

### Takeaway
MacKeeper (Clario Tech FZCO since 2019) is now a subscription "security + cleaner" suite: AV-TEST-certified antivirus, adware cleaner, VPN, StopAd ad blocker, ID Theft Guard, memory cleaner, update tracker, duplicates and uninstaller. It costs about $6–11 a month. Its brand still carries baggage from the 2010–2016 era: aggressive affiliate ads, a $2M class-action settlement in 2015, a 13M-record data exposure, and lawsuits against critics.

### Cited Findings
- The official site lists four groups. Cleaning: Mac Cleaner, Uninstaller, Duplicate Finder. Performance: Optimizer, Memory Cleaner. Security: Antivirus, Adware Cleaner. Privacy: VPN, Ad-Blocker. — [mackeeper.com](https://mackeeper.com/)
- The free tier gives limited access to the RAM cleaner. Full access starts at $10.95/month and includes real-time protection, 24/7 chat support and the VPN. The footer reads "© 2026 Clario Tech FZCO". — [mackeeper.com](https://mackeeper.com/)
- 2026 pricing examples from reviews: about $5.95/mo for 1 Mac billed annually, $7.45/mo for 3 Macs billed annually, $10.95 month-to-month. The money-back guarantee is 30 days on annual plans and 14 days on monthly. — [cleanmymac.com review](https://cleanmymac.com/blog/mackeeper-review), [allaboutcookies.org](https://allaboutcookies.org/mackeeper-review)
- Other listed features: ID Theft Guard (monitors email addresses for breach exposure), Update Tracker, Private Connect VPN, and the StopAd ad/tracker blocker. Reviewers note it has no firewall and no browser phishing protection. — [privacysavvy.com](https://privacysavvy.com/reviews/antivirus/mackeeper/), [safetydetectives.com](https://www.safetydetectives.com/best-antivirus/mackeeper/)
- AV-TEST certification: MacKeeper 6.8 on macOS Sequoia 15.3.2 (March 2025) scored 6/6 each for protection, performance and usability. A review notes that no later major-version result appears on AV-TEST's March 2026 Mac page or in AV-Comparatives' May 2026 report. — [mackeeper.com blog](https://mackeeper.com/blog/mackeeper-gets-av-certification/), [antivirus-review.com](https://antivirus-review.com/blog/is-mackeeper-safe) (secondary source; treat the "not listed in 2026" claim as unverified)
- MacKeeper's marketing claims "99.7% detection" from AV-TEST, and its site presents "notarized by Apple" as a safety signal. Notarization is an automated malware check, not an endorsement. — [mackeeper.com](https://mackeeper.com/)
- History: ZeoBIT launched MacKeeper in October 2010. Kromtech, which was closely tied to ZeoBIT, acquired it in April 2013, and Clario Tech has owned it since 2019. — [Wikipedia: MacKeeper](https://en.wikipedia.org/wiki/MacKeeper)
- Advertising: pop-under ads and fake review accounts. By 2015 the company bought about 60M ad impressions a month through affiliates paid 50% commissions. — [Wikipedia](https://en.wikipedia.org/wiki/MacKeeper)
- Class action: an Illinois suit (January 2014) alleged the diagnostics did not work, and a Pennsylvania suit (May 2014) alleged the app fabricated problems to drive purchases. ZeoBIT settled on 10 August 2015 for $2M with no admission of fault. US buyers who purchased before about 8–9 July 2015 could claim a one-time $39.95 refund until 30 November 2015, and about 513,330 people were eligible. — [Wikipedia](https://en.wikipedia.org/wiki/MacKeeper), [Cult of Mac](https://www.cultofmac.com/news/the-makers-of-mackeeper-owe-you-a-refund), [Top Class Actions](https://topclassactions.com/lawsuit-settlements/closed-settlements/mackeeper-class-action-settlement/)
- Data exposure: in December 2015 Chris Vickery found the details of more than 13M customers publicly accessible. — [Wikipedia](https://en.wikipedia.org/wiki/MacKeeper), [BankInfoSecurity](https://www.bankinfosecurity.com/mackeeper-13m-customers-details-exposed-a-8749)
- Kromtech sued the makers of CleanMyMac (dismissed) and a video critic (dismissed), and sent a cease-and-desist letter to a 14-year-old reviewer in 2016. — [Wikipedia](https://en.wikipedia.org/wiki/MacKeeper)
- Some sites now describe it as "safe" and "excellent". Many of these are affiliate review sites, and cleanmymac.com is a direct competitor, so their verdicts are not independent. — [allaboutcookies.org](https://allaboutcookies.org/mackeeper-review), [cleanmymac.com](https://cleanmymac.com/blog/mackeeper-review)

### Inferences
- MacKeeper's feature list is close to "everything a scared user might buy": AV, VPN, ad blocker, breach monitoring and a memory cleaner. A "memory cleaner" fixes no real problem on modern macOS, and copying it would invite the same scareware criticism.
- MacClean's read-only Security Center plus non-AV positioning is a defensible contrast: no fear-based scan results and no "N threats found" upsell.

### Gaps
- No FTC action against MacKeeper was found. The legal record is the private class action, not FTC enforcement.
- Exact current 2026 checkout prices could not be verified from the vendor's checkout page.
- No independent StopAd or VPN audit was found.

## OnyX: maintenance and automation tasks (and what MacClean's Maintenance lacks)

### Takeaway
OnyX is free and donation-supported, and ships a separate build for each macOS version. Version 5.1.0 for macOS 27 (September 2026, Apple silicon only) is current. It adds several things MacClean lacks: verifying the startup volume structure; rebuilding the dyld shared cache, XPC cache, CoreDuet database and Mail index; clearing font, system, user and internet caches; force-emptying the Trash; and a large "Parameters" panel of hidden defaults for Finder, Dock, Safari and other apps.

### Cited Findings
- OnyX 5.1.0 for macOS 27 was released on 15 September 2026, requires Apple silicon, and is 7.9 MB. It is free, with optional donations ("Since 2003…"). There is a specific build per major OS version. — [titanium-software.fr](https://www.titanium-software.fr/en/onyx.html)
- Official description: "verify the structure of the system files; perform cleaning and computer maintenance tasks; uninstall applications" and configure hidden settings, delete caches, and rebuild databases. — [titanium-software.fr](https://www.titanium-software.fr/en/onyx.html)
- Maintenance features: verify the startup volume's file system, rebuild Launch Services, the CoreDuet database and the XPC cache, empty system, user, internet and font caches, force-empty the Trash, and rebuild the Spotlight and Mail indexes. "Repair disk permissions" also appears, but it is legacy and not meaningful since SIP. — [Wikipedia: OnyX](https://en.wikipedia.org/wiki/OnyX)
- Rebuild options cover LaunchServices, the dyld shared cache, mailboxes and the XPC cache. Cleaning targets include maintenance scripts, the font cache, junk, the Trash and recent items. — [macmyths.com](https://macmyths.com/onyx-for-mac-cleaner-review/), [mediapeanut.com](https://mediapeanut.com/how-to-use-onyx-for-mac-onyx-review-guide/)
- The Parameters section tweaks hidden preferences for Finder, Dock, QuickTime and other apps. — [addictivetips](https://www.addictivetips.com/mac-os/inspect-mac-system-components-clean-system-files-and-apply-fixes-onyx/), [Wikipedia](https://en.wikipedia.org/wiki/OnyX)

### Inferences
- MacClean's Maintenance gaps against OnyX:
  1. Verify the startup disk (`diskutil verifyVolume /`).
  2. Clear the font cache (`atsutil databases -remove`).
  3. Rebuild the dyld cache. Modern macOS ships it in the sealed system volume, so this is mostly obsolete and low value.
  4. Rebuild the XPC and CoreDuet caches.
  5. Rebuild the Mail index.
  6. Clear the QuickLook thumbnail cache (`qlmanage -r cache`).
  7. A hidden-settings "Parameters" panel (screenshot format and location, Dock auto-hide delay, show hidden files, and similar).
  8. An "Automation" mode that runs a selected task set in one click.
- Items 1, 2, 6 and 7 are cheap to build and have real value. The Parameters panel is a popular reason people use OnyX and carries little scareware risk.

### Gaps
- I could not fetch OnyX's per-version feature list for 5.x, so the exact current task list and which tasks were removed on sealed-volume macOS are unverified.

## iStat Menus and Stats: metrics, sensors, alerts, history, pricing; table stakes in 2026

### Takeaway
iStat Menus 7 (Bjango, $11.99 one-time on the Mac App Store; weather $0.99/mo or $4.99/yr) is the paid benchmark. It covers CPU, GPU (including FPS), memory, disks, network (per-app bandwidth and connection details), sensors, fan curves, battery and power, time zones and weather, with history graphs and rule-based notifications for nearly every metric. Stats (exelban, MIT, free) covers CPU, GPU, RAM, disk, network, battery, sensors (temperature, voltage, power), Bluetooth and clock, with top-process lists. Its fan control is in unmaintained legacy mode.

### Cited Findings
- iStat Menus 7.0 (July 2024) brought a redesign, new menu bar modes (stacked label/value), and new items for the Wi-Fi network name and GPU frames per second. — [MacRumors](https://www.macrumors.com/2024/07/31/istat-menus-7-0-brings-new-features/)
- CPU: per-core usage, history graphs, load averages, uptime and frequency. Network: history, current bandwidth, per-top-app bandwidth breakdown, connection details, IP addresses and a connectivity indicator. Fans: precise control with custom speed curves. — [MacRumors](https://www.macrumors.com/2024/07/31/istat-menus-7-0-brings-new-features/)
- Notifications can be set for CPU, GPU, memory, disks, network, sensors, battery, power and weather. — [MacRumors](https://www.macrumors.com/2024/07/31/istat-menus-7-0-brings-new-features/)
- Weather offers current conditions, hourly and weekly forecasts, wind, rain chance, humidity and UV. Pricing: $11.99 on the Mac App Store, weather at $0.99/mo or $4.99/yr, and a 14-day trial from Bjango. — [MacRumors](https://www.macrumors.com/2024/07/31/istat-menus-7-0-brings-new-features/), [App Store](https://apps.apple.com/us/app/istat-menus-7/id6499559693?mt=12)
- Stats modules: CPU, GPU, memory, disk, network, battery, fans (legacy), sensors (temperature, voltage, power), Bluetooth devices and a multi-timezone clock. It needs macOS 12 or later, does not support betas, and is MIT licensed. — [github.com/exelban/stats](https://github.com/exelban/stats)
- "Fan control operates in legacy mode and does not receive any updates or fixes." — [github.com/exelban/stats](https://github.com/exelban/stats)
- Stats shows top processes for CPU, RAM and network. The Sensors and Bluetooth modules are its heaviest, and disabling them can cut Stats' CPU use by up to 50%. — [mac-stats.com / search summary](https://mac-stats.com/), [github.com/exelban/stats](https://github.com/exelban/stats)
- An open Stats issue reports the network module polling airportd three times a second for the TX rate in the background, which shows that monitoring itself has an energy cost. — [Stats issue #3536](https://github.com/exelban/stats/issues/3536)

### Inferences
- Table stakes for a 2026 menu-bar monitor, offered by both free Stats and paid iStat:
  1. CPU per-core usage with history.
  2. GPU usage.
  3. Memory pressure with top processes.
  4. Disk free space and read/write activity.
  5. Network up/down with top processes.
  6. Temperatures and fan RPM from SMC sensors.
  7. Battery percentage, cycles, health and power draw.
  8. Bluetooth device batteries.
- MacClean already has 3, 4 (free space only), 5 (rates, no per-process), 7 and 8, plus a speed test that neither competitor offers.
- MacClean's missing table stakes: GPU usage, per-sensor temperatures and fan RPM (it only shows thermal state), disk I/O activity, per-process network use, history graphs, and user-configurable threshold alerts.
- Differentiators that are not table stakes: fan control (risky, and even Stats abandoned it), weather (off-mission), and time zones.
- Because Stats is free, a cleaner should not try to out-feature iStat. Keep the panel focused and add GPU, temperatures/fans and simple alerts.

### Gaps
- I could not fetch bjango.com directly, so iStat's SMART display and battery-history details are unverified. Stats' notification support (per-module thresholds) was not confirmed from primary docs.

## Disk Drill: APFS/SSD recovery reality, protection features, SMART, free tier, pricing; is a "Recovery Vault" worthwhile for us?

### Takeaway
Disk Drill 6 combines recovery, "Data Protection" (Recovery Vault and Guaranteed Recovery), S.M.A.R.T. monitoring, byte-to-byte backups, Clean Up and a duplicate finder. On Mac the free tier is scan and preview only; the 500 MB free recovery applies to Windows. Pro costs about $89 a year or $149 lifetime. On internal Apple SSDs with TRIM and FileVault, independent testers report close to zero recovery of deleted file contents, so raw carving is mainly useful for external, non-TRIM media.

### Cited Findings
- Pricing: about $89/year or a $149 lifetime license. — [pandorarecovery.com review](https://scoreboard.pandorarecovery.com/disk-drill-mac-review/). One review labels $89 as "1 Month", which conflicts and is probably an error. — [Macgasm](https://news.macgasm.net/reviews/disk-drill-mac-review/)
- Free tier: "The Mac free version only permits file previewing—no actual recovery." — [Macgasm](https://news.macgasm.net/reviews/disk-drill-mac-review/). Other summaries cite a 500 MB free limit; that conflicts with the Mac claim and most likely refers to Windows. — [Wondershare review](https://recoverit.wondershare.com/mac-data-recovery/disk-drill-mac-review.html)
- Pro covers one user on up to three Mac or Windows devices. — [pandorarecovery.com](https://scoreboard.pandorarecovery.com/disk-drill-mac-review/)
- Recovery Vault "remembers the metadata of deleted files to improve recovery chances", while Guaranteed Recovery "saves complete copies of files in specified locations". — [pandorarecovery.com](https://scoreboard.pandorarecovery.com/disk-drill-mac-review/). Guaranteed Recovery "temporarily retains copies of deleted files" and is marketed as most valuable on TRIM SSDs. — [Macgasm](https://news.macgasm.net/reviews/disk-drill-mac-review/)
- Other tools: S.M.A.R.T. monitoring for HDDs and SSDs, byte-to-byte backup, Clean Up (visual space breakdown), duplicate finder and data shredder. — [pandorarecovery.com](https://scoreboard.pandorarecovery.com/disk-drill-mac-review/), [Macgasm](https://news.macgasm.net/reviews/disk-drill-mac-review/)
- CleverFiles' own technical guide: "With TRIM enabled (default on modern systems), deleted blocks are flagged for purge… the original content may be physically erased", and "TRIM + garbage collection can permanently purge deleted blocks quickly." Under full-disk encryption without unlock, "raw content is indistinguishable noise". APFS snapshots and copy-on-write metadata "change the calculus". — [cleverfiles.com help](https://www.cleverfiles.com/help/variables-that-impact-file-recovery-chances/)
- Independent ratings tests: 0% recovery on an internal Mac SSD because of immediate TRIM, against high success on an external SSD without TRIM. An "82% success on APFS" figure applies to favorable conditions. Metadata can survive while the data reads back as zeros. — [pandorarecovery SSD ratings](https://ratings.pandorarecovery.com/best-ssd-recovery-software/), [Rossmann Group](https://rossmanngroup.com/problems/can-you-recover-data-after-trim). The pandorarecovery site is affiliated with the recovery-software industry, so treat its numbers with caution.
- Review limitations: you cannot preset a scan to specific folders or types, and there is no independent RAID reconstruction. — [Macgasm](https://news.macgasm.net/reviews/disk-drill-mac-review/)

### Inferences
- MacClean's snapshot and Time Machine-only Recover Files is the honest approach for internal Apple silicon SSDs. Raw carving would mostly return zero-filled files and invite refund requests.
- A "protect future deletions" feature in the style of Guaranteed Recovery is feasible: watch user folders with FSEvents and copy files into a vault before deletion, or intercept emptying the Trash. Its value is modest, because it duplicates what Trash, Time Machine and APFS local snapshots already do. It also costs disk space (which conflicts with a cleaner's goal), needs Full Disk Access, and can miss deletions done by `rm` or by apps.
- A cheaper, more honest variant: a "safety net" setting that (a) ensures Time Machine and local snapshots are enabled, (b) shows the snapshot coverage window, and (c) holds MacClean's own cleanup deletions in a recoverable staging area for N days. That is our own undo, not system-wide interception.
- SMART: Apple's internal NVMe exposes only limited SMART data through public APIs (`diskutil info` shows only "SMART Status: Verified"). A simple drive-health badge is feasible and useful, especially for external drives.

### Gaps
- I could not reach CleverFiles' official pricing page (404), so current Disk Drill prices and the edition matrix were not verified first-hand. No independent (non-vendor-affiliated) lab test of Recovery Vault was found.
- I could not verify whether wear/endurance data for internal Apple silicon SSDs is readable without a kernel extension or private APIs.

## Intego: features and pricing

### Takeaway
Intego's Mac Internet Security X9 pairs VirusBarrier (antivirus) with NetBarrier (two-way firewall). The Mac Premium Bundle X9 adds Washing Machine (cleanup and duplicates), ContentBarrier (parental controls) and Personal Backup, and a VPN is sold as an add-on bundle. Intego is Mac-specialist, with good review scores, but uses steep first-year discounts.

### Cited Findings
- The Premium Bundle X9 includes VirusBarrier, NetBarrier, Washing Machine, ContentBarrier and Personal Backup. — [Intego promo page](https://antivirus.intego.com/misx9-promotion), [Tom's Guide](https://www.tomsguide.com/reviews/intego-premium-bundle-x9)
- Pricing sightings: $39.99 first year against a $84.99 list price; also $69.99/yr and $129.99/2 yrs for 1 Mac; Premium Bundle + VPN $89.99/yr or $149.99/2 yrs. Prices vary by promotion. — [Intego promo](https://antivirus.intego.com/misx9-promotion), [Tekpon](https://tekpon.com/software/intego/pricing/)
- Macworld rated Internet Security X9 "excellent protection for Mac". — [Macworld](https://www.macworld.com/article/668086/intego-mac-internet-security-x9-review-3.html). Macworld also reviews a separate free "VirusBarrier Scanner" (on-demand). — [Macworld](https://www.macworld.com/article/2225550/intego-virusbarrier-scanner-review.html)

### Inferences
- Intego's outbound-firewall angle (NetBarrier) is a genuine gap that macOS's built-in inbound-only firewall leaves open. A read-only "which apps are making network connections" view could be a non-scareware feature for us. A full firewall needs a Network Extension and is a big project.

### Gaps
- I could not fetch intego.com product pages (404), and found no current 2026 AV-TEST score for Intego in this pass.

## Norton / Avast cleanup add-ons (brief)

### Takeaway
Both big AV vendors sell Mac cleanup as a separate subscription. Norton Utilities Ultimate costs $59.99/yr for up to 10 devices and includes junk cleanup, an uninstaller, auto-clean, browser data cleanup and data recovery. Avast Cleanup Premium for Mac costs $44.99 the first year ($79.99 thereafter) and has junk and duplicate cleanup, similar and bad photo detection, an uninstaller and startup item management, with no AV.

### Cited Findings
- Norton Utilities Ultimate: $59.99/yr, up to 10 devices, 30-day trial; junk cleanup, uninstaller, auto cleaning, browser data cleanup, data recovery. — [norton.com](https://us.norton.com/products/norton-utilities-ultimate), [Norton Community announcement](https://community.norton.com/t/introducing-norton-utilities-ultimate-for-mac/511934)
- Avast Cleanup Premium (Mac): $44.99 first year, normally $79.99/yr, 30-day trial with no card; junk, duplicates, browser data, similar/bad photos, uninstaller, startup items; no antivirus. — [Macworld review](https://www.macworld.com/article/2655777/avast-cleanup-premium-for-mac-review.html), [avast.com](https://www.avast.com/en-us/cleanup-mac)

### Inferences
- Similar and bad photo detection (blurry, screenshots) is a cleanup feature MacClean could add next to Duplicates.

### Gaps
- No independent test of Norton's Mac "data recovery" claim was found.

## Apple built-in: what Storage settings, Optimize Storage, Empty Trash Automatically and Activity Monitor already do; what "System Data" is

### Takeaway
macOS already offers Store in iCloud, Optimize Storage (removes watched Apple TV media and keeps only recent mail attachments), and Empty Trash Automatically after 30 days. It also clears "caches and logs that are safe to delete" on its own when space is needed. "System Data" is Apple's catch-all for files that don't fit another category: caches, logs, local snapshots, iOS backups, app support data, VM/swap and on-device AI models. Local snapshots counted there are purgeable and macOS deletes them under pressure.

### Cited Findings
- Store in iCloud: Desktop/Documents to iCloud Drive, iCloud Photos, Messages in iCloud, "keeping only recently opened files on your Mac when space is needed." — [Apple: Optimize storage space](https://support.apple.com/guide/mac-help/optimize-storage-space-sysp4ee93ca4/mac)
- Optimize Storage: "automatically removing Apple TV movies and TV shows that you already watched, and by keeping only recent email attachments." — [Apple](https://support.apple.com/guide/mac-help/optimize-storage-space-sysp4ee93ca4/mac)
- Empty Trash Automatically: "erase items that have been in the Trash for more than 30 days." — [Apple](https://support.apple.com/guide/mac-help/optimize-storage-space-sysp4ee93ca4/mac)
- Automatic cleanup: "when space is needed on your Mac, macOS also clears caches and logs that are safe to delete, including temporary database files, interrupted downloads, staged macOS and app updates, Safari website data, and more." — [Apple](https://support.apple.com/guide/mac-help/optimize-storage-space-sysp4ee93ca4/mac)
- System Data definition: "a general category that measures the storage space used by all Apple and third-party files that don't belong to any more specific category." Trash space is not freed until the Trash is emptied. — [Apple support 102624](https://support.apple.com/en-us/102624)
- Typical contents (non-Apple guides): caches, logs and crash reports, Time Machine local snapshots, iOS/iPadOS backups, app support leftovers, disk images and installers, fonts and plugins, aerial screensaver/wallpaper assets, and Apple Intelligence models. Local snapshots are deleted automatically when space is needed or as they age. — [Macworld](https://www.macworld.com/article/676493/how-to-delete-system-storage-on-mac.html), [search-summarized guides incl. clamperpod/mintstorage](https://mintstorage.app/guides/time-machine-local-snapshots-mac/)

### Inferences
- Avoid building:
  1. Automatic Trash emptying (already built in).
  2. Generic "clear caches when low on disk" (macOS already does this under pressure).
  3. "Delete local snapshots to free space" as a headline feature. macOS purges them on its own, and deleting them destroys MacClean's own Recover Files source.
- What third-party tools can safely add on top of System Data:
  1. Visibility: break System Data down into named buckets, which Apple does not.
  2. Stale iOS device backups.
  3. Old installers and DMGs.
  4. Leftovers from uninstalled apps.
  5. Large log and crash-report sets.
  6. Developer caches (Xcode DerivedData, simulators).
  Swap, VM files and sealed-system content should never be touched.
- MacClean's "delete TM local snapshots" action should warn that it removes the restore points Recover Files depends on.

### Gaps
- Activity Monitor coverage (CPU, Memory pressure, Energy, Disk and Network tabs with per-process data, plus the GPU History window) was not fetched from Apple docs in this pass. Treat it as known but unsourced here. It matters because per-process network and disk data already exist in Activity Monitor.
- Apple's Storage pane in macOS 26/27 may have changed (for example, per-category info buttons). I could not confirm this from the guide page fetched.

## Which capabilities MacClean lacks entirely, and value vs. scareware risk

### Takeaway
Worth adding (high value, low scareware risk): GPU usage, temperature/fan readouts, disk I/O, threshold alerts and short history in the menu bar; OnyX-style extras (verify startup disk, font and QuickLook cache reset, hidden-settings "Parameters"); a SMART/drive health badge; a System Data breakdown; and similar/blurry photo cleanup. Avoid: memory "cleaning", antivirus scans with threat counts, bundled VPN/ad blocker/ID-theft upsells, raw-disk carving on TRIM SSDs, and fan control.

### Cited Findings
- Memory cleaner, VPN, ad blocker and ID-theft monitoring are MacKeeper's paid bundle, and the brand's history (fabricated-problem lawsuit, $2M settlement) shows how easily that model reads as scareware. — [Wikipedia](https://en.wikipedia.org/wiki/MacKeeper), [mackeeper.com](https://mackeeper.com/)
- Internal SSD recovery via carving is close to 0% after TRIM, per a vendor-adjacent tester and repair-shop sources. — [pandorarecovery](https://ratings.pandorarecovery.com/best-ssd-recovery-software/), [Rossmann Group](https://rossmanngroup.com/problems/can-you-recover-data-after-trim)
- Fan control has been abandoned even by the leading open-source monitor. — [github.com/exelban/stats](https://github.com/exelban/stats)
- macOS already auto-clears safe caches, logs and staged updates under space pressure. — [Apple](https://support.apple.com/guide/mac-help/optimize-storage-space-sysp4ee93ca4/mac)

### Inferences
- Priority list (my judgement):
  1. Monitoring parity: GPU %, SMC temperatures and fan RPM (read-only), disk read/write, configurable alerts, 1-hour/24-hour sparklines.
  2. A System Data explainer and breakdown.
  3. OnyX extras: verify disk, font, QuickLook and XPC cache resets, and a defaults "Parameters" pane.
  4. A drive health badge.
  5. A cleanup undo/staging vault.
  6. Read-only outbound-connection insight, to sit beside the Security Center.
- Explicitly not building: AV engine, VPN, ad blocker, ID-theft, RAM "free up" as a performance claim (keep `purge` as an expert tool only), and raw recovery.

### Gaps
- No user-survey data was found on which monitor metrics users actually look at. The prioritization above is inference, not measured demand.
