//
//  AppStorageScanner.swift
//  MacClean
//
//  应用占用：统计每个应用「本体 + 用户数据 + 缓存」实际占用的磁盘空间，
//  并按规则给出可清理的部分（微信/QQ 等有专门规则，其余应用走通用缓存/日志规则）。
//  全部为 nonisolated 静态方法，可在后台线程调用（工程默认 MainActor 隔离）。
//

import Foundation
import Security

// MARK: - 模型

enum AppStorageKind: String, Sendable {
    case bundle, data, cache

    var title: String {
        switch self {
        case .bundle: return String(localized: "应用本体")
        case .data: return String(localized: "用户数据")
        case .cache: return String(localized: "缓存与日志")
        }
    }
}

struct AppStorageLocation: Identifiable, Hashable, Sendable {
    let path: String
    let label: String
    let kind: AppStorageKind
    let size: Int64
    /// 与其他已安装应用共用的组容器（如同一开发商的多个应用）。
    let isShared: Bool
    /// 目录存在但无权读取（未授予完全磁盘访问权限时，其他应用的容器可能读不到）。
    let isUnreadable: Bool
    nonisolated var id: String { path }
}

struct AppCleanupCandidate: Identifiable, Hashable, Sendable {
    enum Risk: Sendable, Hashable {
        /// 删除后应用会自动重建（缓存、日志、旧版本更新包）。
        case safe
        /// 用户自己的数据（聊天图片/视频/文件），删除后从本机消失，默认不勾选。
        case userData
    }

    let path: String
    let title: String
    let note: String
    let size: Int64
    let risk: Risk
    /// true 整个目录移入废纸篓；false 只清空目录内容（保留目录结构，应用无需重建）。
    let removesContainer: Bool
    var isSelected: Bool
    nonisolated var id: String { path }
}

struct AppStorageInfo: Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    let bundlePath: String
    let locations: [AppStorageLocation]
    var candidates: [AppCleanupCandidate]

    nonisolated var id: String { bundleID }
    nonisolated func size(of kind: AppStorageKind) -> Int64 {
        locations.filter { $0.kind == kind && !$0.isShared }.reduce(0) { $0 + $1.size }
    }
    /// 总占用（共享组容器不计入，避免同一份数据在多个应用下重复计算）。
    nonisolated var totalSize: Int64 { locations.filter { !$0.isShared }.reduce(0) { $0 + $1.size } }
    nonisolated var cleanableSize: Int64 { candidates.reduce(0) { $0 + $1.size } }
    nonisolated var hasUnreadableData: Bool { locations.contains { $0.isUnreadable } }
}

// MARK: - 专门规则

struct AppCleanupRule: Sendable {
    enum Base: Sendable {
        /// ~/Library/Containers/<bundleID>/Data
        case container
        /// 用户主目录
        case home
    }
    enum Layout: Sendable {
        case contents
        case whole
        /// 匹配到多个目录时保留最近修改的一个（如当前正在使用的版本），其余整项删除。
        case keepNewest
    }

    let bundleID: String
    let base: Base
    /// 相对路径，每段可含通配符（fnmatch 语法），如 "Documents/xwechat_files/*/msg/file"。
    let pattern: String
    let title: String
    let note: String
    let risk: AppCleanupCandidate.Risk
    let layout: Layout
}

enum AppStorageScanner {

    nonisolated static let wechat = "com.tencent.xinWeChat"
    nonisolated static let qq = "com.tencent.qq"

    /// 经实测目录结构（微信 4.x / 3.x、QQ NT 版）整理的专门规则。
    nonisolated static let rules: [AppCleanupRule] = [
        // 微信 4.x
        .init(bundleID: wechat, base: .container, pattern: "Documents/xwechat_files/*/cache", title: String(localized: "聊天缓存"), note: String(localized: "按月份存放的临时缓存，会自动重建"), risk: .safe, layout: .contents),
        .init(bundleID: wechat, base: .container, pattern: "Documents/app_data/log", title: String(localized: "运行日志"), note: String(localized: "微信自身的诊断日志"), risk: .safe, layout: .contents),
        .init(bundleID: wechat, base: .container, pattern: ".wxapplet/cache", title: String(localized: "小程序缓存"), note: String(localized: "小程序运行缓存，再次打开时重新下载"), risk: .safe, layout: .contents),
        .init(bundleID: wechat, base: .container, pattern: "Documents/xwechat_files/*/msg/file", title: String(localized: "聊天中收到的文件"), note: String(localized: "删除后在微信里点开需重新下载，过期文件将无法恢复"), risk: .userData, layout: .contents),
        .init(bundleID: wechat, base: .container, pattern: "Documents/xwechat_files/*/msg/attach", title: String(localized: "聊天图片与附件"), note: String(localized: "聊天中的图片原图与附件；删除后未过期的可重新下载"), risk: .userData, layout: .contents),
        .init(bundleID: wechat, base: .container, pattern: "Documents/xwechat_files/*/msg/video", title: String(localized: "聊天视频"), note: String(localized: "删除后未过期的可重新下载"), risk: .userData, layout: .contents),
        .init(bundleID: wechat, base: .container, pattern: "Documents/xwechat_files/*/business/migrate", title: String(localized: "旧版迁移数据"), note: String(localized: "升级到微信 4.x 时迁移过来的旧版数据，确认新版聊天记录完整后再删除"), risk: .userData, layout: .contents),
        // 微信 3.x
        .init(bundleID: wechat, base: .container, pattern: "Library/Application Support/com.tencent.xinWeChat/*/*/Message/MessageTemp", title: String(localized: "旧版聊天图片、视频与文件"), note: String(localized: "微信 3.x 的聊天媒体文件"), risk: .userData, layout: .contents),

        // QQ（NT 版）
        .init(bundleID: qq, base: .container, pattern: "Library/Application Support/QQ/versions/*", title: String(localized: "旧版本 QQ"), note: String(localized: "QQ 自动更新留下的历史版本，只保留正在使用的最新版本"), risk: .safe, layout: .keepNewest),
        .init(bundleID: qq, base: .container, pattern: "Library/Application Support/QQ/packages", title: String(localized: "更新安装包"), note: String(localized: "已下载的更新包，安装完成后不再需要"), risk: .safe, layout: .contents),
        .init(bundleID: qq, base: .container, pattern: "Library/Application Support/QQ/nt_qq_*/nt_data/Log", title: String(localized: "运行日志"), note: String(localized: "QQ 自身的诊断日志"), risk: .safe, layout: .contents),
        .init(bundleID: qq, base: .container, pattern: "Library/Application Support/QQ/nt_qq_*/nt_data/Pic", title: String(localized: "聊天图片"), note: String(localized: "删除后未过期的可重新下载"), risk: .userData, layout: .contents),
        .init(bundleID: qq, base: .container, pattern: "Library/Application Support/QQ/nt_qq_*/nt_data/Video", title: String(localized: "聊天视频"), note: String(localized: "删除后未过期的可重新下载"), risk: .userData, layout: .contents),
        .init(bundleID: qq, base: .container, pattern: "Library/Application Support/QQ/nt_qq_*/nt_data/File", title: String(localized: "聊天中收到的文件"), note: String(localized: "删除后在 QQ 里点开需重新下载"), risk: .userData, layout: .contents),
        .init(bundleID: qq, base: .container, pattern: "Library/Application Support/QQ/nt_qq_*/nt_data/Emoji", title: String(localized: "表情缓存"), note: String(localized: "包含收藏的自定义表情，删除后可能需要重新同步"), risk: .userData, layout: .contents),
    ]

    // MARK: - 入口

    /// progress(已完成应用数, 总数)
    nonisolated static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil,
        minTotalSize: Int64 = 10 * 1024 * 1024,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> [AppStorageInfo] {
        let directories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/Applications/Setapp"),
            URL(fileURLWithPath: "/Applications/Utilities"),
        ]
        let apps = installedApps(in: directories)
        progress?(0, apps.count)

        // 统计每个组容器被多少个已安装应用声明，被多个应用共用的标为共享。
        var groupClaims: [String: Int] = [:]
        for app in apps { for group in Set(app.groups) { groupClaims[group, default: 0] += 1 } }

        var results = [AppStorageInfo?](repeating: nil, count: apps.count)
        let lock = NSLock()
        var done = 0
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            let info = analyze(apps[index], home: home, groupClaims: groupClaims)
            lock.lock()
            results[index] = info
            done += 1
            let current = done
            lock.unlock()
            progress?(current, apps.count)
        }

        return results
            .compactMap { $0 }
            .filter { $0.totalSize >= minTotalSize }
            .sorted { $0.totalSize > $1.totalSize }
    }

    // MARK: - 已安装应用

    struct InstalledApp: Sendable {
        let bundleID: String
        let name: String
        let path: String
        let groups: [String]
        var version: String? = nil
    }

    nonisolated static func installedApps(in directories: [URL]) -> [InstalledApp] {
        var seen: Set<String> = []
        var apps: [InstalledApp] = []
        for directory in directories {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where name.hasSuffix(".app") {
                let path = directory.path + "/" + name
                guard let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any],
                      let bundleID = plist["CFBundleIdentifier"] as? String,
                      seen.insert(bundleID).inserted else { continue }
                let displayName = displayName(plist: plist, path: path)
                apps.append(InstalledApp(
                    bundleID: bundleID, name: displayName, path: path,
                    groups: appGroups(ofAppAt: path),
                    version: plist["CFBundleShortVersionString"] as? String
                ))
            }
        }
        return apps
    }

    /// 显示名称：CFBundleDisplayName → CFBundleName → 文件名，跳过空字符串（有的应用把显示名设成空串）。
    nonisolated static func displayName(plist: [String: Any], path: String) -> String {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = (plist[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// 从代码签名的 entitlements 读取 application-groups（组容器名），比按名称猜测准确。
    nonisolated static func appGroups(ofAppAt path: String) -> [String] {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    // MARK: - 单个应用

    nonisolated static func analyze(_ app: InstalledApp, home: URL, groupClaims: [String: Int]) -> AppStorageInfo {
        let fileManager = FileManager.default
        let library = home.appendingPathComponent("Library").path
        var locations: [AppStorageLocation] = []
        var seenPaths: Set<String> = []

        func add(_ path: String, label: String, kind: AppStorageKind, shared: Bool = false) {
            guard seenPaths.insert(path).inserted else { return }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return }
            let unreadable = isDirectory.boolValue && !fileManager.isReadableFile(atPath: path)
            let size = unreadable ? 0 : CleanupManager.allocatedSize(atPath: path)
            guard size > 0 || unreadable else { return }
            locations.append(AppStorageLocation(path: path, label: label, kind: kind, size: size, isShared: shared, isUnreadable: unreadable))
        }

        add(app.path, label: String(localized: "应用本体"), kind: .bundle)

        // 沙盒容器：主容器 + 以 bundleID. 开头的扩展容器（如微信的小程序、分享扩展）
        let containers = library + "/Containers"
        if let names = try? fileManager.contentsOfDirectory(atPath: containers) {
            for name in names where name == app.bundleID || name.hasPrefix(app.bundleID + ".") {
                add(containers + "/" + name, label: name == app.bundleID ? String(localized: "沙盒容器") : String(localized: "扩展容器 \(String(name.dropFirst(app.bundleID.count + 1)))"), kind: .data)
            }
        }

        // 组容器：签名声明的 + 名称以 .<bundleID> 结尾的
        let groupRoot = library + "/Group Containers"
        var groups = Set(app.groups)
        if let names = try? fileManager.contentsOfDirectory(atPath: groupRoot) {
            for name in names where name.hasSuffix("." + app.bundleID) || name == app.bundleID { groups.insert(name) }
        }
        for group in groups.sorted() {
            add(groupRoot + "/" + group, label: String(localized: "组容器"), kind: .data, shared: (groupClaims[group] ?? 0) > 1)
        }

        for name in folderNames(for: app) {
            add(library + "/Application Support/" + name, label: String(localized: "应用支持文件"), kind: .data)
            add(library + "/Caches/" + name, label: String(localized: "缓存"), kind: .cache)
            add(library + "/Logs/" + name, label: String(localized: "日志"), kind: .cache)
        }
        add(library + "/HTTPStorages/" + app.bundleID, label: String(localized: "网络缓存"), kind: .cache)
        add(library + "/WebKit/" + app.bundleID, label: String(localized: "网页数据"), kind: .cache)
        add(library + "/Saved Application State/" + app.bundleID + ".savedState", label: String(localized: "窗口状态"), kind: .cache)

        let candidates = cleanupCandidates(for: app, home: home, library: library)
        return AppStorageInfo(bundleID: app.bundleID, name: app.name, bundlePath: app.path, locations: locations, candidates: candidates)
    }

    // MARK: - 可清理项

    nonisolated static func cleanupCandidates(for app: InstalledApp, home: URL, library: String) -> [AppCleanupCandidate] {
        let containerData = library + "/Containers/" + app.bundleID + "/Data"
        var result: [AppCleanupCandidate] = []
        var seen: Set<String> = []

        func append(_ path: String, title: String, note: String, risk: AppCleanupCandidate.Risk, removesContainer: Bool, minSize: Int64 = 1024 * 1024) {
            guard seen.insert(path).inserted else { return }
            let size = CleanupManager.allocatedSize(atPath: path)
            guard size > minSize else { return }
            result.append(AppCleanupCandidate(
                path: path, title: title, note: note, size: size, risk: risk,
                removesContainer: removesContainer, isSelected: risk == .safe
            ))
        }

        for rule in rules where rule.bundleID == app.bundleID {
            let base = rule.base == .container ? containerData : home.path
            let matches = expand(pattern: rule.pattern, under: base)
            switch rule.layout {
            case .contents:
                for path in matches { append(path, title: rule.title, note: rule.note, risk: rule.risk, removesContainer: false) }
            case .whole:
                for path in matches { append(path, title: rule.title, note: rule.note, risk: rule.risk, removesContainer: true) }
            case .keepNewest:
                let keep = versionsToKeep(matches, installedVersion: app.version)
                for path in matches where !keep.contains(path) {
                    let version = (path as NSString).lastPathComponent
                    append(path, title: "\(rule.title) \(version)", note: rule.note, risk: rule.risk, removesContainer: true)
                }
            }
        }

        // 通用规则：Electron / Chromium 内核应用（VS Code、Cursor、Slack、Claude 等）在 Application Support 里的缓存
        for folder in folderNames(for: app) {
            let support = library + "/Application Support/" + folder
            for (name, title) in electronCacheFolders {
                append(support + "/" + name, title: title, note: String(localized: "Chromium 内核缓存，会按需重建"), risk: .safe, removesContainer: false)
            }
        }

        // 通用规则：沙盒内与 ~/Library 下以 bundleID 命名的缓存、日志
        append(containerData + "/Library/Caches", title: String(localized: "应用缓存"), note: String(localized: "会按需重建"), risk: .safe, removesContainer: false)
        append(containerData + "/Library/Logs", title: String(localized: "应用日志"), note: String(localized: "诊断日志"), risk: .safe, removesContainer: false)
        append(library + "/Caches/" + app.bundleID, title: String(localized: "应用缓存"), note: String(localized: "会按需重建"), risk: .safe, removesContainer: false)
        for name in folderNames(for: app) where name == app.name {
            append(library + "/Logs/" + name, title: String(localized: "应用日志"), note: String(localized: "诊断日志"), risk: .safe, removesContainer: false)
        }

        return result.sorted {
            if $0.risk != $1.risk { return $0.risk == .safe }
            return $0.size > $1.size
        }
    }

    /// 用来拼接 ~/Library 子目录的名称。空字符串或含「/」「..」的名称会让路径退化成
    /// ~/Library/Application Support 这类根目录，把所有应用的数据算到一个应用头上，必须排除。
    nonisolated static func folderNames(for app: InstalledApp) -> [String] {
        Set([app.bundleID, app.name])
            .filter { name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && !name.contains("/") && name != "." && name != ".."
            }
            .sorted()
    }

    /// Chromium/Electron 应用数据目录里可安全清空的缓存子目录。
    nonisolated static let electronCacheFolders: [(String, String)] = [
        ("Cache", String(localized: "网页缓存")),
        ("Code Cache", String(localized: "脚本编译缓存")),
        ("GPUCache", String(localized: "GPU 缓存")),
        ("DawnCache", String(localized: "图形缓存")),
        ("DawnGraphiteCache", String(localized: "图形缓存")),
        ("DawnWebGPUCache", String(localized: "图形缓存")),
        ("Service Worker/CacheStorage", String(localized: "离线网页缓存")),
        ("CachedData", String(localized: "旧版本编译缓存")),
        ("CachedExtensionVSIXs", String(localized: "扩展安装包缓存")),
        ("logs", String(localized: "运行日志")),
    ]

    /// 逐段展开通配符路径，只返回存在的目录。
    nonisolated static func expand(pattern: String, under base: String) -> [String] {
        var current = [base]
        for component in pattern.split(separator: "/").map(String.init) {
            var next: [String] = []
            for directory in current {
                if component.contains("*") || component.contains("?") {
                    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
                    for name in names where fnmatch(component, name, 0) == 0 {
                        next.append(directory + "/" + name)
                    }
                } else {
                    next.append(directory + "/" + component)
                }
            }
            current = next.filter { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
        }
        return current.sorted()
    }

    /// 保留版本号最大的目录，以及与已安装 .app 版本号一致的目录（两者可能是同一个）。
    nonisolated static func versionsToKeep(_ paths: [String], installedVersion: String?) -> Set<String> {
        var keep: Set<String> = []
        if let highest = paths.max(by: {
            ($0 as NSString).lastPathComponent.compare(($1 as NSString).lastPathComponent, options: .numeric) == .orderedAscending
        }) {
            keep.insert(highest)
        }
        if let installedVersion, !installedVersion.isEmpty {
            for path in paths where (path as NSString).lastPathComponent.hasPrefix(installedVersion) {
                keep.insert(path)
            }
        }
        return keep
    }
}

// MARK: - Docker

struct DockerUsageRow: Sendable, Equatable {
    let type: String
    let totalCount: Int
    let active: Int
    let size: String
    let reclaimable: String

    var title: String {
        switch type {
        case "Images": return String(localized: "镜像")
        case "Containers": return String(localized: "容器")
        case "Local Volumes": return String(localized: "数据卷")
        case "Build Cache": return String(localized: "构建缓存")
        default: return type
        }
    }
}

enum DockerStatus: Sendable, Equatable {
    case notInstalled
    case notRunning
    case running([DockerUsageRow])
}

enum DockerPruneLevel: Sendable, CaseIterable {
    case buildCache
    case unused
    case allUnusedImages

    var title: String {
        switch self {
        case .buildCache: return String(localized: "清理构建缓存")
        case .unused: return String(localized: "清理停止的容器与悬空镜像")
        case .allUnusedImages: return String(localized: "删除所有未被容器使用的镜像")
        }
    }

    var detail: String {
        switch self {
        case .buildCache: return String(localized: "docker builder prune，下次构建会变慢")
        case .unused: return String(localized: "docker system prune，不会删除数据卷")
        case .allUnusedImages: return String(localized: "docker image prune -a，需要时要重新拉取")
        }
    }

    var arguments: [String] {
        switch self {
        case .buildCache: return ["builder", "prune", "-f"]
        case .unused: return ["system", "prune", "-f"]
        case .allUnusedImages: return ["image", "prune", "-a", "-f"]
        }
    }
}

enum DockerTool {

    nonisolated static func cliPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let candidates = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            home.path + "/.docker/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            home.path + "/.orbstack/bin/docker",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static func status() -> DockerStatus {
        guard let cli = cliPath() else { return .notInstalled }
        guard let output = run(cli, ["system", "df", "--format", "{{json .}}"], timeout: 20), output.status == 0 else {
            return .notRunning
        }
        return .running(parseSystemDF(output.stdout))
    }

    nonisolated static func prune(_ level: DockerPruneLevel) -> (ok: Bool, message: String) {
        guard let cli = cliPath() else { return (false, String(localized: "未找到 docker 命令")) }
        guard let output = run(cli, level.arguments, timeout: 600) else { return (false, String(localized: "执行超时")) }
        let text = String(decoding: output.stdout, as: UTF8.self)
        let reclaimed = text.components(separatedBy: "\n").last { $0.contains("reclaimed") } ?? ""
        return (output.status == 0, reclaimed.isEmpty ? (output.status == 0 ? String(localized: "已完成") : String(localized: "执行失败")) : reclaimed)
    }

    /// 解析 `docker system df --format '{{json .}}'`（每行一个 JSON 对象）。
    nonisolated static func parseSystemDF(_ data: Data) -> [DockerUsageRow] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line -> DockerUsageRow? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let type = object["Type"] as? String else { return nil }
                func int(_ key: String) -> Int {
                    if let text = object[key] as? String { return Int(text) ?? 0 }
                    return (object[key] as? NSNumber)?.intValue ?? 0
                }
                return DockerUsageRow(
                    type: type,
                    totalCount: int("TotalCount"),
                    active: int("Active"),
                    size: object["Size"] as? String ?? "—",
                    reclaimable: object["Reclaimable"] as? String ?? "—"
                )
            }
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, stdout: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }

        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
