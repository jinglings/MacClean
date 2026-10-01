//
//  AppLeftovers.swift
//  MacClean
//
//  应用关联文件与残留检测。
//  - associatedFiles：某个应用（按 bundle id / 应用名）在 ~/Library 中留下的文件，卸载时一并移走。
//  - orphanedFiles：已卸载应用留下的孤立文件。误判会直接毁掉用户数据，所以规则刻意保守：
//    名称必须像 reverse-DNS bundle id，且任何已安装应用（含同开发商、同名、LaunchServices 登记的）都认领不了，
//    排除 Apple 与常见共享目录，最近 7 天内还在变动的也不算。
//  - trashedAppLeftovers：用户把 .app 拖进废纸篓后留下的文件（来源可确定，可信度更高）。
//  全部为 nonisolated，可在后台线程调用。
//

import Foundation
import AppKit

// MARK: - 已安装应用索引

nonisolated struct InstalledAppIndex: Sendable {
    /// 已安装应用 / 插件 / 偏好设置面板等 bundle 的 id（小写）。
    var bundleIDs: Set<String> = []
    /// bundle id 的前两段（如 com.google），同开发商的共享目录一律视为仍在使用。
    var vendors: Set<String> = []
    /// 归一化后的应用名（小写、去掉非字母数字）及出现次数。
    var nameCounts: [String: Int] = [:]
    /// 命令行工具名（归一化），只用于认领残留。
    var toolNames: Set<String> = []
    /// 已安装应用声明的 App Group（小写）。
    var groups: Set<String> = []
    var ownBundleID: String? = Bundle.main.bundleIdentifier
    /// 额外查询：LaunchServices 是否登记了该 bundle id 的应用（在任意位置）。测试中注入。
    var lookup: @Sendable (String) -> Bool = AppLeftovers.launchServicesHasApp

    mutating func insert(bundleID: String, name: String?) {
        let lower = bundleID.lowercased()
        guard !lower.isEmpty else { return }
        bundleIDs.insert(lower)
        let parts = lower.split(separator: ".")
        if parts.count >= 3 { vendors.insert(parts.prefix(2).joined(separator: ".")) }
        if let name {
            let normalized = AppLeftovers.normalize(name)
            if !normalized.isEmpty { nameCounts[normalized, default: 0] += 1 }
        }
    }

    /// 是否有其他（比 bundleID 更具体的）已安装应用拥有这个名字，例如 com.foo.App.Pro 之于 com.foo.App。
    func ownedByOther(_ candidate: String, than bundleID: String) -> Bool {
        let lower = candidate.lowercased()
        let mine = bundleID.lowercased()
        return bundleIDs.contains { other in
            other != mine && other.count > mine.count && (lower == other || lower.hasPrefix(other + "."))
        }
    }

    /// 这个疑似 bundle id 是否仍被某个已安装的东西认领。
    func isClaimed(_ candidate: String) -> Bool {
        let lower = candidate.lowercased()
        if bundleIDs.contains(lower) || groups.contains(lower) { return true }
        if bundleIDs.contains(where: { lower.hasPrefix($0 + ".") || $0.hasPrefix(lower + ".") }) { return true }

        let parts = lower.split(separator: ".").map(String.init)
        if parts.count >= 2, vendors.contains(parts.prefix(2).joined(separator: ".")) { return true }

        // 任意一段与已安装应用名/命令行工具名相同或互相包含（如 com.tinyspeck.slackmacgap ↔ Slack）
        let knownNames = Array(nameCounts.keys) + toolNames
        for part in parts.dropFirst() {
            let token = AppLeftovers.normalize(part)
            guard token.count >= 3, !AppLeftovers.genericTokens.contains(token) else { continue }
            for name in knownNames {
                if name == token { return true }
                if token.count >= 4, name.count >= 4, token.contains(name) || name.contains(token) { return true }
            }
        }

        // LaunchServices：应用可能装在扫描范围之外（下载目录、外置盘、开发工具里）
        for length in stride(from: parts.count, through: 3, by: -1) {
            let prefix = candidate.split(separator: ".").prefix(length).joined(separator: ".")
            if lookup(prefix) { return true }
        }
        return false
    }

    // MARK: 构建

    /// 应用目录（递归几层，覆盖 /Applications/Utilities、Setapp、JetBrains Toolbox 等子文件夹）。
    nonisolated static func appRoots(home: String) -> [(path: String, depth: Int)] {
        [
            ("/Applications", 3),
            (home + "/Applications", 3),
            ("/System/Applications", 2),
            ("/System/Library/CoreServices", 1),
            ("/Library/Application Support", 2),
        ]
    }

    /// 非 .app 的 bundle：偏好设置面板、输入法、音频插件、JDK 等，它们也会在 ~/Library 写偏好设置。
    nonisolated static func pluginRoots(home: String) -> [String] {
        let shared = [
            "/Library/PreferencePanes", "/Library/Input Methods", "/Library/QuickLook", "/Library/Screen Savers",
            "/Library/Internet Plug-Ins", "/Library/Spotlight", "/Library/Services", "/Library/Frameworks",
            "/Library/Java/JavaVirtualMachines", "/Library/Mail/Bundles", "/Library/Extensions",
            "/Library/Audio/Plug-Ins/Components", "/Library/Audio/Plug-Ins/HAL", "/Library/Audio/Plug-Ins/VST",
            "/Library/Audio/Plug-Ins/VST3", "/Library/Audio/Plug-Ins/MAS", "/Library/SystemExtensions",
        ]
        return shared + shared.filter { !$0.hasPrefix("/Library/SystemExtensions") && !$0.hasPrefix("/Library/Extensions") }
            .map { home + $0 }
    }

    nonisolated static func build(home: String, extraApps: [AppBundle] = []) -> InstalledAppIndex {
        var index = InstalledAppIndex()
        for app in extraApps { index.insert(bundleID: app.bundleID, name: app.name) }
        var seenPaths = Set(extraApps.map(\.path))

        func visit(_ directory: String, depth: Int) {
            guard depth > 0, let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
            for name in names where !name.hasPrefix(".") {
                let path = directory + "/" + name
                if let info = bundleInfo(at: path) {
                    if seenPaths.insert(path).inserted { index.insert(bundleID: info.bundleID, name: info.name) }
                    continue
                }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    visit(path, depth: depth - 1)
                }
            }
        }

        for root in appRoots(home: home) { visit(root.path, depth: root.depth) }
        for root in pluginRoots(home: home) { visit(root, depth: 2) }

        // 命令行工具（Homebrew、npm、cargo 等）也会在 ~/Library 写偏好设置/缓存，按名字认领
        for directory in commandLineRoots(home: home) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where !name.hasPrefix(".") {
                let normalized = AppLeftovers.normalize(name)
                if normalized.count >= 3 { index.toolNames.insert(normalized) }
            }
        }
        return index
    }

    nonisolated static func commandLineRoots(home: String) -> [String] {
        [
            "/usr/local/bin", "/opt/homebrew/bin", "/opt/homebrew/Caskroom", "/opt/homebrew/Cellar",
            "/usr/local/Caskroom", "/usr/local/Cellar", "/opt/local/bin",
            home + "/.local/bin", home + "/bin", home + "/.npm-global/bin", home + "/.cargo/bin", home + "/go/bin",
        ]
    }

    /// 读取 bundle（.app / .prefPane / .component / .jdk / .framework 等）的 id 与显示名。
    nonisolated private static func bundleInfo(at path: String) -> (bundleID: String, name: String)? {
        let candidates = [path + "/Contents/Info.plist", path + "/Resources/Info.plist", path + "/Info.plist"]
        for plistPath in candidates {
            guard let plist = NSDictionary(contentsOfFile: plistPath) as? [String: Any] else { continue }
            guard let bundleID = plist["CFBundleIdentifier"] as? String else { return nil }
            return (bundleID, AppStorageScanner.displayName(plist: plist, path: path))
        }
        return nil
    }
}

// MARK: - 关联文件与残留

enum AppLeftovers {

    /// 常见顶级域名：残留候选的第一段必须是其中之一，才算「像 bundle id」。
    nonisolated static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "app", "dev", "co", "me", "de", "cn", "jp", "uk", "fr", "ru", "us", "ca", "au",
        "nl", "se", "ch", "at", "it", "es", "pl", "in", "eu", "ai", "so", "sh", "is", "fm", "im", "ly", "to",
        "tv", "cc", "xyz", "pro", "info", "biz", "edu", "kr", "tw", "hk", "br", "dk", "no", "fi", "cz", "be",
    ]

    /// 名称片段里过于通用、不能拿来与应用名比对的词。
    nonisolated static let genericTokens: Set<String> = [
        "app", "apps", "mac", "macos", "osx", "desktop", "client", "helper", "agent", "launcher", "update", "updater",
        "service", "services", "daemon", "plugin", "plugins", "extension", "free", "pro", "lite", "beta", "mobile",
        "player", "editor", "viewer", "studio", "manager", "tool", "tools", "sync", "share", "widget", "main",
        "core", "framework", "group", "shared", "default", "cache", "data", "settings", "preferences", "plist",
    ]

    /// 不当作残留的前缀：Apple 自家与系统组件（含不以 com.apple 开头的）、开发工具链/运行时、
    /// 以及被嵌进各种应用里的第三方 SDK（崩溃上报、统计、图片缓存）——它们的数据不属于某一个应用。
    nonisolated static let protectedPrefixes: [String] = [
        "com.apple.", "group.com.apple.", "systemgroup.", "is.workflow.", "org.cups.",
        "com.github.electron", "org.python.", "org.nodejs.", "com.oracle.java", "net.java.", "org.openjdk.",
        "org.swift.", "com.android.", "org.gradle.", "org.apache.", "org.eclipse.", "org.graalvm.",
        "com.microsoft.autoupdate", "com.microsoft.appcenter", "com.google.keystone", "com.google.googleupdater",
        "org.mozilla.updater", "org.sparkle-project.", "com.crashlytics", "com.plausiblelabs.", "com.bugsnag.",
        "io.sentry", "com.firebase", "com.onevcat.", "com.segment.", "com.mixpanel", "com.amplitude",
        "com.squareup.", "com.tabnine",
    ]

    /// 以这些词结尾的条目通常由命令行工具与应用共用（如 ai.foo.shared），不当作残留。
    nonisolated static let sharedSuffixes: Set<String> = ["shared", "common"]

    /// 多个应用共用、按应用名匹配时绝不能当作某个应用独有的目录名（归一化后比较）。
    nonisolated static let sharedFolderNames: Set<String> = [
        "crashreporter", "addressbook", "clouddocs", "knowledge", "icloud", "google", "microsoft", "adobe", "apple",
        "mozilla", "oracle", "java", "jetbrains", "electron", "python", "node", "steam", "unity", "autodesk",
        "fonts", "plugins", "plugin", "data", "default", "cache", "caches", "logs", "temp", "tmp", "audio", "video",
        "app", "helper", "updater", "update", "shared", "common", "documents", "library", "mail", "safari", "chrome",
    ]

    /// 归一化名称：小写，只保留字母和数字。
    nonisolated static func normalize(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(Character.init))
    }

    /// 至少三段、首段是常见顶级域名、每段只含字母数字下划线连字符。
    nonisolated static func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, topLevelDomains.contains(parts[0].lowercased()) else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
        }
    }

    nonisolated static func isProtected(_ name: String, ownBundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        let lower = name.lowercased()
        if lower.contains("com.apple.") || lower.hasPrefix("apple") { return true }
        if protectedPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        if let last = lower.split(separator: ".").last, sharedSuffixes.contains(String(last)) { return true }
        if let own = ownBundleID?.lowercased(), !own.isEmpty, lower == own || lower.hasPrefix(own + ".") { return true }
        return false
    }

    /// LaunchServices 是否登记了该 id 的应用（忽略废纸篓里的和已经不存在的）。
    nonisolated static func launchServicesHasApp(_ bundleID: String) -> Bool {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL] else {
            return false
        }
        return urls.contains { !$0.path.contains("/.Trash/") && FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - 某个应用的关联文件

    nonisolated static func associatedFiles(
        bundleID: String,
        appName: String,
        appGroups: [String],
        home: String,
        index: InstalledAppIndex
    ) -> [RelatedFile] {
        guard !bundleID.isEmpty, !isProtected(bundleID, ownBundleID: index.ownBundleID) else { return [] }
        let library = home + "/Library"
        var files: [RelatedFile] = []
        var seen = Set<String>()

        func add(_ relative: String, _ type: RelatedFileType) {
            let path = library + "/" + relative
            guard !seen.contains(path), isRegularEntry(path) else { return }
            seen.insert(path)
            files.append(RelatedFile(
                name: (relative as NSString).lastPathComponent,
                path: path,
                size: CleanupManager.allocatedSize(atPath: path),
                type: type,
                owner: appName
            ))
        }

        let exact: [(String, RelatedFileType)] = [
            ("Preferences/\(bundleID).plist", .preferences),
            ("Caches/\(bundleID)", .cache),
            ("HTTPStorages/\(bundleID)", .webData),
            ("HTTPStorages/\(bundleID).binarycookies", .webData),
            ("WebKit/\(bundleID)", .webData),
            ("Cookies/\(bundleID).binarycookies", .webData),
            ("Containers/\(bundleID)", .containers),
            ("Application Scripts/\(bundleID)", .containers),
            ("Application Support/\(bundleID)", .applicationSupport),
            ("Logs/\(bundleID)", .logs),
            ("Saved Application State/\(bundleID).savedState", .savedState),
            ("LaunchAgents/\(bundleID).plist", .launchAgent),
        ]
        for (relative, type) in exact { add(relative, type) }

        // 以 bundle id 为前缀的扩展、助手与按主机保存的偏好设置
        let prefixed: [(String, RelatedFileType)] = [
            ("Containers", .containers), ("Application Scripts", .containers), ("LaunchAgents", .launchAgent),
            ("Preferences", .preferences), ("Preferences/ByHost", .preferences),
        ]
        for (directory, type) in prefixed {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: library + "/" + directory)) ?? []
            for name in names where name.hasPrefix(bundleID + ".") {
                let core = name.hasSuffix(".plist") ? String(name.dropLast(6)) : name
                guard directory == "Preferences/ByHost" || !index.ownedByOther(core, than: bundleID) else { continue }
                add(directory + "/" + name, type)
            }
        }

        for group in appGroups where !isProtected(group, ownBundleID: index.ownBundleID) {
            add("Group Containers/\(group)", .containers)
        }

        // 按应用名匹配（如 Application Support/Slack）：名字够独特、不是共享目录、没有第二个同名应用时才算
        let normalized = normalize(appName)
        if normalized.count >= 3, !sharedFolderNames.contains(normalized), index.nameCounts[normalized, default: 0] <= 1,
           !appName.contains("/") {
            for (directory, type) in [("Application Support", RelatedFileType.applicationSupport), ("Caches", .cache), ("Logs", .logs)] {
                add("\(directory)/\(appName)", type)
            }
        }

        return files
    }

    // MARK: - 孤立残留

    /// 扫描的 ~/Library 子目录，以及从条目名还原 bundle id 时要去掉的后缀。
    nonisolated static let orphanLocations: [(directory: String, type: RelatedFileType, suffix: String?)] = [
        ("Application Support", .applicationSupport, nil),
        ("Caches", .cache, nil),
        ("Preferences", .preferences, ".plist"),
        ("Containers", .containers, nil),
        ("Group Containers", .containers, nil),
        ("Application Scripts", .containers, nil),
        ("Saved Application State", .savedState, ".savedState"),
        ("HTTPStorages", .webData, nil),
        ("WebKit", .webData, nil),
        ("Cookies", .webData, ".binarycookies"),
        ("Logs", .logs, nil),
    ]

    /// 已卸载应用留下的文件。默认不勾选，由用户逐项确认。
    nonisolated static func orphanedFiles(
        home: String,
        index: InstalledAppIndex,
        now: Date = Date(),
        minimumAge: TimeInterval = 7 * 24 * 3600
    ) -> [RelatedFile] {
        let library = home + "/Library"
        var results: [RelatedFile] = []
        var claimCache: [String: Bool] = [:]

        func isOrphan(_ candidate: String) -> Bool {
            if let cached = claimCache[candidate] { return cached }
            let orphan = !isProtected(candidate, ownBundleID: index.ownBundleID) && !index.isClaimed(candidate)
            claimCache[candidate] = orphan
            return orphan
        }

        for location in orphanLocations {
            if Task.isCancelled { return results }
            let directory = library + "/" + location.directory
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for name in names where !name.hasPrefix(".") {
                var candidate = name
                if let suffix = location.suffix {
                    guard candidate.hasSuffix(suffix) else { continue }
                    candidate = String(candidate.dropLast(suffix.count))
                } else if location.directory == "HTTPStorages", candidate.hasSuffix(".binarycookies") {
                    candidate = String(candidate.dropLast(".binarycookies".count))
                }
                if location.directory == "Group Containers" {
                    guard !index.groups.contains(name.lowercased()) else { continue }
                    candidate = groupContainerBundleID(candidate)
                }
                guard looksLikeBundleID(candidate) else { continue }

                let path = directory + "/" + name
                guard isRegularEntry(path), isOrphan(candidate) else { continue }
                if let modified = modificationDate(path), now.timeIntervalSince(modified) < minimumAge { continue }

                results.append(RelatedFile(
                    name: name,
                    path: path,
                    size: CleanupManager.allocatedSize(atPath: path),
                    type: location.type,
                    owner: candidate,
                    isSelected: false
                ))
            }
        }

        results += brokenLaunchAgents(library: library, index: index)
        return results.sorted { ($0.owner.lowercased(), $0.path) < ($1.owner.lowercased(), $1.path) }
    }

    /// 组容器名形如 TEAMID.com.foo.bar 或 group.com.foo.bar，去掉前缀还原出 bundle id。
    nonisolated static func groupContainerBundleID(_ name: String) -> String {
        if name.lowercased().hasPrefix("group.") { return String(name.dropFirst("group.".count)) }
        let parts = name.split(separator: ".", maxSplits: 1)
        if parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isUppercase || $0.isNumber }) {
            return String(parts[1])
        }
        return name
    }

    /// 指向已不存在的可执行文件的启动代理（应用删了，开机还在尝试启动它）。
    nonisolated static func brokenLaunchAgents(library: String, index: InstalledAppIndex) -> [RelatedFile] {
        let directory = library + "/LaunchAgents"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.compactMap { name -> RelatedFile? in
            guard name.hasSuffix(".plist") else { return nil }
            let label = String(name.dropLast(6))
            let path = directory + "/" + name
            guard !isProtected(label, ownBundleID: index.ownBundleID), isRegularEntry(path),
                  let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else { return nil }
            let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
            guard let program, program.hasPrefix("/"), !program.hasPrefix("/Volumes/"),
                  !FileManager.default.fileExists(atPath: program) else { return nil }
            return RelatedFile(
                name: name, path: path, size: CleanupManager.allocatedSize(atPath: path),
                type: .launchAgent, owner: label, isSelected: false
            )
        }
    }

    // MARK: - 废纸篓中的应用

    /// 用户把 .app 拖进废纸篓（且没有在别处另装一份）后，它在 ~/Library 留下的文件。
    nonisolated static func trashedAppLeftovers(home: String, index: InstalledAppIndex) -> [RelatedFile] {
        let trash = home + "/.Trash"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: trash)) ?? []
        var results: [RelatedFile] = []
        for name in names where name.hasSuffix(".app") {
            if Task.isCancelled { break }
            let path = trash + "/" + name
            guard let bundle = AppBundle(path: path), !bundle.bundleID.isEmpty,
                  !index.bundleIDs.contains(bundle.bundleID.lowercased()),
                  !index.lookup(bundle.bundleID) else { continue }
            let groups = AppStorageScanner.appGroups(ofAppAt: path).filter { !index.groups.contains($0.lowercased()) }
            let files = associatedFiles(bundleID: bundle.bundleID, appName: bundle.name, appGroups: groups, home: home, index: index)
            results += files.map { file in
                var file = file
                file.fromTrashedApp = true
                file.isSelected = false
                return file
            }
        }
        return results
    }

    // MARK: - 辅助

    /// 存在且不是符号链接（符号链接可能指向别处，交给用户手动处理）。
    nonisolated static func isRegularEntry(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) != S_IFLNK
    }

    nonisolated static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
