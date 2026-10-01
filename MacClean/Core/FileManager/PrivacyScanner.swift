//
//  PrivacyScanner.swift
//  MacClean
//
//  隐私清理：发现各浏览器的历史、Cookie、下载记录、自动填充、会话恢复文件，以及系统「最近使用的项目」。
//  全部为无状态静态方法，可在后台线程调用；路径发现接受 home 参数，便于在临时目录里测试。
//
//  刻意不碰：保存的密码（Login Data、钥匙串）、书签（Bookmarks、Bookmarks.plist、Firefox places.sqlite）。
//

import Foundation

// MARK: - 浏览器

enum PrivacyBrowser: String, CaseIterable, Sendable, Identifiable {
    case safari, chrome, edge, brave, firefox
    /// 不属于任何浏览器的系统痕迹（最近使用的项目）
    case system

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave"
        case .firefox: return "Firefox"
        case .system: return String(localized: "系统")
        }
    }

    /// 用于检测是否正在运行、退出应用、读取应用图标。
    nonisolated var bundleIdentifier: String? {
        switch self {
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .edge: return "com.microsoft.edgemac"
        case .brave: return "com.brave.Browser"
        case .firefox: return "org.mozilla.firefox"
        case .system: return nil
        }
    }

    /// Chromium 系浏览器的用户数据目录（相对 home）。
    nonisolated var chromiumUserDataPath: String? {
        switch self {
        case .chrome: return "Library/Application Support/Google/Chrome"
        case .edge: return "Library/Application Support/Microsoft Edge"
        case .brave: return "Library/Application Support/BraveSoftware/Brave-Browser"
        default: return nil
        }
    }
}

// MARK: - 痕迹类型

enum PrivacyKind: String, CaseIterable, Sendable {
    case history
    case cookies
    case downloads
    case autofill
    case formHistory
    case sessions
    case recentItems

    nonisolated var title: String {
        switch self {
        case .history: return String(localized: "浏览历史")
        case .cookies: return "Cookie"
        case .downloads: return String(localized: "下载记录")
        case .autofill: return String(localized: "自动填充（含保存的地址/卡片）")
        case .formHistory: return String(localized: "表单输入记录")
        case .sessions: return String(localized: "会话 / 标签页恢复")
        case .recentItems: return String(localized: "最近使用的项目")
        }
    }

    nonisolated var detail: String {
        switch self {
        case .history: return String(localized: "访问过的网址与访问时间")
        case .cookies: return String(localized: "会退出所有网站登录")
        case .downloads: return String(localized: "下载列表中的记录（不会删除已下载的文件）")
        case .autofill: return String(localized: "表单自动填充数据，包括保存的地址和银行卡信息")
        case .formHistory: return String(localized: "搜索框和表单中输入过的内容")
        case .sessions: return String(localized: "上次打开的窗口和标签页，清除后无法恢复上次会话")
        case .recentItems: return String(localized: "「最近使用的文稿 / 应用 / 服务器」列表及各应用的最近文稿")
        }
    }

    /// 需要用醒目颜色提示的副作用。
    nonisolated var isRisky: Bool {
        self == .cookies || self == .autofill
    }

    nonisolated var icon: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .cookies: return "person.badge.key"
        case .downloads: return "arrow.down.circle"
        case .autofill: return "creditcard"
        case .formHistory: return "character.cursor.ibeam"
        case .sessions: return "square.on.square"
        case .recentItems: return "doc.badge.clock"
        }
    }
}

// MARK: - 发现结果

struct PrivacyEntry: Identifiable, Sendable, Equatable {
    let browser: PrivacyBrowser
    let kind: PrivacyKind
    /// Chromium / Firefox 的配置文件目录名（Default、Profile 1、xxxx.default-release），Safari/系统为 nil。
    let profileDirectory: String?
    /// 用户可读的配置文件名（Chromium Local State 里的名称），没有则同 profileDirectory。
    let profileName: String?
    /// 要移入废纸篓的文件/目录（数据库及其 -journal / -wal / -shm 伴随文件）。
    let paths: [String]
    let size: Int64

    nonisolated var id: String {
        [browser.rawValue, profileDirectory ?? "-", kind.rawValue].joined(separator: "|")
    }
}

struct PrivacyScanResult: Sendable {
    var entries: [PrivacyEntry] = []
    /// 已安装/有数据目录的浏览器（含无可清理项的），用于决定显示哪些分组。
    var browsersWithData: Set<PrivacyBrowser> = []
    /// ~/Library/Safari 存在但没有读取权限（未授予完全磁盘访问权限）。
    var safariNeedsFullDiskAccess = false
}

// MARK: - 扫描

enum PrivacyScanner {

    nonisolated static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> PrivacyScanResult {
        var result = PrivacyScanResult()

        let safari = safariEntries(home: home)
        if safari.hasData { result.browsersWithData.insert(.safari) }
        result.safariNeedsFullDiskAccess = safari.needsFullDiskAccess
        result.entries += safari.entries

        for browser in [PrivacyBrowser.chrome, .edge, .brave] {
            let entries = chromiumEntries(browser: browser, home: home)
            if entries.hasData { result.browsersWithData.insert(browser) }
            result.entries += entries.entries
        }

        let firefox = firefoxEntries(home: home)
        if firefox.hasData { result.browsersWithData.insert(.firefox) }
        result.entries += firefox.entries

        let recent = recentItemsEntries(home: home)
        if !recent.isEmpty { result.browsersWithData.insert(.system) }
        result.entries += recent

        return result
    }

    // MARK: Safari

    nonisolated static func safariEntries(home: URL) -> (entries: [PrivacyEntry], hasData: Bool, needsFullDiskAccess: Bool) {
        let fm = FileManager.default
        let safariDir = home.appendingPathComponent("Library/Safari")
        let containerLibrary = home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library")

        let dirExists = fm.fileExists(atPath: safariDir.path)
        var needsFDA = false
        if dirExists {
            do {
                _ = try fm.contentsOfDirectory(atPath: safariDir.path)
            } catch {
                needsFDA = isPermissionError(error)
            }
        }

        var entries: [PrivacyEntry] = []
        func add(_ kind: PrivacyKind, _ urls: [URL]) {
            let existing = urls.filter { fm.fileExists(atPath: $0.path) }
            guard !existing.isEmpty else { return }
            entries.append(PrivacyEntry(
                browser: .safari, kind: kind, profileDirectory: nil, profileName: nil,
                paths: existing.map(\.path), size: totalSize(of: existing)
            ))
        }

        if dirExists && !needsFDA {
            add(.history, sqliteFamily(safariDir.appendingPathComponent("History.db"), suffixes: ["-wal", "-shm", "-lock"]))
            add(.downloads, [safariDir.appendingPathComponent("Downloads.plist")])
            add(.sessions, [safariDir.appendingPathComponent("LastSession.plist")])
        }
        add(.cookies, [
            containerLibrary.appendingPathComponent("Cookies/Cookies.binarycookies"),
            home.appendingPathComponent("Library/Cookies/Cookies.binarycookies"),
        ])

        return (entries, dirExists || !entries.isEmpty, needsFDA)
    }

    // MARK: Chromium（Chrome / Edge / Brave）

    nonisolated static func chromiumEntries(browser: PrivacyBrowser, home: URL) -> (entries: [PrivacyEntry], hasData: Bool) {
        guard let relative = browser.chromiumUserDataPath else { return ([], false) }
        let root = home.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: root.path) else { return ([], false) }

        let names = chromiumProfileNames(root: root)
        var entries: [PrivacyEntry] = []
        for profile in chromiumProfiles(root: root) {
            let dir = profile.lastPathComponent
            let candidates: [(PrivacyKind, [URL])] = [
                (.history, sqliteFamily(profile.appendingPathComponent("History"), suffixes: ["-journal"])),
                (.cookies, sqliteFamily(profile.appendingPathComponent("Cookies"), suffixes: ["-journal"])
                    + sqliteFamily(profile.appendingPathComponent("Network/Cookies"), suffixes: ["-journal"])),
                (.autofill, sqliteFamily(profile.appendingPathComponent("Web Data"), suffixes: ["-journal"])),
                (.sessions, ["Sessions", "Current Session", "Current Tabs", "Last Session", "Last Tabs"]
                    .map { profile.appendingPathComponent($0) }),
            ]
            for (kind, urls) in candidates {
                let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
                guard !existing.isEmpty else { continue }
                entries.append(PrivacyEntry(
                    browser: browser, kind: kind, profileDirectory: dir, profileName: names[dir] ?? dir,
                    paths: existing.map(\.path), size: totalSize(of: existing)
                ))
            }
        }
        return (entries, true)
    }

    /// 「Default」与「Profile N」两类配置文件目录，按名称排序（Default 在前）。
    nonisolated static func chromiumProfiles(root: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .sorted { lhs, rhs in
                if lhs == "Default" { return rhs != "Default" }
                if rhs == "Default" { return false }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            .map { root.appendingPathComponent($0, isDirectory: true) }
            .filter { isDirectory($0) }
    }

    /// 从「Local State」读取配置文件显示名：profile.info_cache.<目录名>.name。
    nonisolated static func chromiumProfileNames(root: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [:] }
        var names: [String: String] = [:]
        for (dir, value) in cache {
            if let name = (value as? [String: Any])?["name"] as? String, !name.isEmpty {
                names[dir] = name
            }
        }
        return names
    }

    // MARK: Firefox

    /// Firefox 的浏览历史与书签同在 places.sqlite，不能单独删除历史，因此只提供 Cookie、表单记录与会话恢复。
    nonisolated static func firefoxEntries(home: URL) -> (entries: [PrivacyEntry], hasData: Bool) {
        let root = home.appendingPathComponent("Library/Application Support/Firefox/Profiles")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return ([], false) }

        var entries: [PrivacyEntry] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let profile = root.appendingPathComponent(name, isDirectory: true)
            guard isDirectory(profile) else { continue }
            let candidates: [(PrivacyKind, [URL])] = [
                (.cookies, sqliteFamily(profile.appendingPathComponent("cookies.sqlite"), suffixes: ["-wal", "-shm"])),
                (.formHistory, sqliteFamily(profile.appendingPathComponent("formhistory.sqlite"), suffixes: ["-wal", "-shm"])),
                (.sessions, ["sessionstore.jsonlz4", "sessionstore-backups"].map { profile.appendingPathComponent($0) }),
            ]
            for (kind, urls) in candidates {
                let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
                guard !existing.isEmpty else { continue }
                entries.append(PrivacyEntry(
                    browser: .firefox, kind: kind, profileDirectory: name, profileName: firefoxProfileLabel(name),
                    paths: existing.map(\.path), size: totalSize(of: existing)
                ))
            }
        }
        return (entries, true)
    }

    /// 「abcd1234.default-release」→「default-release」
    nonisolated static func firefoxProfileLabel(_ directory: String) -> String {
        guard let dot = directory.firstIndex(of: ".") else { return directory }
        let label = directory[directory.index(after: dot)...]
        return label.isEmpty ? directory : String(label)
    }

    // MARK: 系统：最近使用的项目

    /// 只取名称含「Recent」的列表文件（最近文稿/应用/服务器/主机）与各应用的最近文稿；
    /// 同目录下的 FavoriteItems、FavoriteVolumes 等是访达侧栏收藏，绝不能动。
    nonisolated static func recentItemsEntries(home: URL) -> [PrivacyEntry] {
        let root = home.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
        let fm = FileManager.default
        var urls: [URL] = []

        let topLevel = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for name in topLevel.sorted() where isRecentListFile(name) {
            urls.append(root.appendingPathComponent(name))
        }
        let perApp = root.appendingPathComponent("com.apple.LSSharedFileList.ApplicationRecentDocuments")
        for name in ((try? fm.contentsOfDirectory(atPath: perApp.path)) ?? []).sorted() where isSFLFile(name) {
            urls.append(perApp.appendingPathComponent(name))
        }

        guard !urls.isEmpty else { return [] }
        return [PrivacyEntry(
            browser: .system, kind: .recentItems, profileDirectory: nil, profileName: nil,
            paths: urls.map(\.path), size: totalSize(of: urls)
        )]
    }

    nonisolated static func isRecentListFile(_ name: String) -> Bool {
        name.hasPrefix("com.apple.LSSharedFileList.Recent") && isSFLFile(name)
    }

    /// .sfl / .sfl2 / .sfl3 / .sfl4 …
    nonisolated static func isSFLFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard ext.hasPrefix("sfl") else { return false }
        return ext.dropFirst(3).allSatisfy(\.isNumber)
    }

    // MARK: - 工具

    nonisolated private static func sqliteFamily(_ base: URL, suffixes: [String]) -> [URL] {
        [base] + suffixes.map { URL(fileURLWithPath: base.path + $0) }
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    nonisolated static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(EPERM) || underlying.code == Int(EACCES) {
            return true
        }
        return ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES))
    }

    /// 文件取自身大小；目录递归累加（不跟随符号链接）。
    nonisolated static func totalSize(of urls: [URL]) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for url in urls {
            if isDirectory(url) {
                guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { continue }
                for case let child as URL in enumerator {
                    let values = try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
                    guard values?.isRegularFile == true else { continue }
                    total += Int64(values?.totalFileAllocatedSize ?? 0)
                }
            } else if let attrs = try? fm.attributesOfItem(atPath: url.path), let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }

    /// 选中的条目 → 交给 CleanupManager 的清理项（每个文件/目录整体移入废纸篓）。
    nonisolated static func cleanableItems(for entries: [PrivacyEntry]) -> [CleanableItem] {
        entries.flatMap { entry in
            entry.paths.map { path in
                CleanableItem(
                    name: (path as NSString).lastPathComponent,
                    path: path,
                    size: totalSize(of: [URL(fileURLWithPath: path)]),
                    category: .privacyData,
                    isSelected: true,
                    description: "\(entry.browser.displayName) · \(entry.kind.title)",
                    removesContainer: true
                )
            }
        }
    }
}
