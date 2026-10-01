//
//  AppManager.swift
//  MacClean
//
//  应用管家：盘点已安装应用（真实占用、上次使用时间、关联文件）、未使用应用、残留文件与安装包。
//  全部为 nonisolated 静态方法，由 ViewModel 在 Task.detached 中调用（工程默认 MainActor 隔离）。
//  删除一律交给 CleanupManager（移入废纸篓 + PathGuard 校验 + 清理记录可撤销）。
//

import Foundation
import os

// MARK: - 应用信息模型

nonisolated struct AppInfo: Identifiable, Hashable, Sendable {
    let name: String
    let bundleIdentifier: String
    let path: String
    /// CFBundleShortVersionString
    let version: String
    /// CFBundleVersion
    let buildVersion: String?
    /// 应用包实际占用（st_blocks，完整递归）。
    let size: Int64
    /// Spotlight 记录的上次打开时间（kMDItemLastUsedDate）；nil 表示系统没有记录。
    let lastUsedDate: Date?
    let isFromAppStore: Bool
    /// Info.plist 里的 Sparkle 更新源（SUFeedURL）。
    let feedURL: String?
    /// ~/Library 中按 bundle id / 应用名找到的关联文件，卸载时一并移入废纸篓。
    var relatedFiles: [RelatedFile] = []

    var id: String { path }

    var relatedSize: Int64 { relatedFiles.filter(\.isSelected).reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { size + relatedSize }
    var isAppleApp: Bool { bundleIdentifier.hasPrefix("com.apple.") }
}

// MARK: - 关联文件模型

nonisolated struct RelatedFile: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let size: Int64
    let type: RelatedFileType
    /// 归属说明：卸载时为应用名；残留文件为推断出的 bundle id 或废纸篓里的应用名。
    var owner: String = ""
    /// 来自废纸篓中的应用（可信度高于按名称推断的孤立残留）。
    var fromTrashedApp: Bool = false
    var isSelected: Bool = true

    var id: String { path }
}

nonisolated enum RelatedFileType: String, Sendable {
    case preferences = "偏好设置"
    case cache = "缓存文件"
    case applicationSupport = "应用支持"
    case logs = "日志文件"
    case containers = "容器数据"
    case savedState = "保存的状态"
    case webData = "网页数据"
    case launchAgent = "启动代理"
    case other = "其他"

    var icon: String {
        switch self {
        case .preferences: return "gearshape.fill"
        case .cache: return "folder.badge.gearshape"
        case .applicationSupport: return "folder.fill"
        case .logs: return "doc.text.fill"
        case .containers: return "shippingbox.fill"
        case .savedState: return "clock.arrow.circlepath"
        case .webData: return "globe"
        case .launchAgent: return "bolt.horizontal.fill"
        case .other: return "doc.fill"
        }
    }
}

// MARK: - 安装包模型

nonisolated struct InstallerFile: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let size: Int64
    let modified: Date?

    var id: String { path }
}

// MARK: - 扫描结果模型

nonisolated struct AppScanResult: Sendable {
    var apps: [AppInfo]
    var leftoverFiles: [RelatedFile]
    var installers: [InstallerFile]
    let scannedAt: Date

    static let unusedThresholdDays = 30

    /// 可以判断是否「长期未使用」的应用：排除系统自带与 MacClean 自己。
    private var judgeableApps: [AppInfo] {
        let own = Bundle.main.bundleIdentifier
        return apps.filter { !$0.isAppleApp && $0.bundleIdentifier != own }
    }

    /// 有使用记录且超过 30 天没打开的应用。
    var unusedApps: [AppInfo] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.unusedThresholdDays, to: scannedAt) ?? scannedAt
        return judgeableApps
            .filter { ($0.lastUsedDate ?? .distantFuture) < cutoff }
            .sorted { ($0.lastUsedDate ?? .distantPast) < ($1.lastUsedDate ?? .distantPast) }
    }

    /// Spotlight 没有使用记录的应用（可能从未打开，也可能索引缺失），单独列出、不计入「未使用」。
    var unknownUsageApps: [AppInfo] {
        judgeableApps.filter { $0.lastUsedDate == nil }.sorted { $0.totalSize > $1.totalSize }
    }

    var appStoreAppsCount: Int { apps.filter(\.isFromAppStore).count }
    var totalAppsCount: Int { apps.count }
    var unusedAppsSize: Int64 { unusedApps.reduce(0) { $0 + $1.totalSize } }
    var leftoverSize: Int64 { leftoverFiles.reduce(0) { $0 + $1.size } }
    var installerSize: Int64 { installers.reduce(0) { $0 + $1.size } }

    /// 清理后去掉已经不存在的条目（不必整页重扫）。
    mutating func pruneMissing() {
        let fm = FileManager.default
        apps.removeAll { !fm.fileExists(atPath: $0.path) }
        for index in apps.indices {
            apps[index].relatedFiles.removeAll { !fm.fileExists(atPath: $0.path) }
        }
        leftoverFiles.removeAll { !fm.fileExists(atPath: $0.path) }
        installers.removeAll { !fm.fileExists(atPath: $0.path) }
    }
}

// MARK: - 应用管理器

enum AppManager {
    nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MacClean", category: "AppManager")

    /// 进度回调：0...1 的进度与当前正在处理的条目。
    typealias Progress = @Sendable (Double, String) -> Void

    nonisolated static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip"]

    /// 执行完整扫描。任务被取消时返回 nil。
    nonisolated static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        progress: Progress
    ) -> AppScanResult? {
        let homePath = home.standardizedFileURL.path
        progress(0, String(localized: "正在列出已安装的应用…"))

        // 1. 可卸载的应用：/Applications 与 ~/Applications 的直接子项（与 PathGuard 的允许范围一致）
        let bundles = ["/Applications", homePath + "/Applications"].flatMap { directory -> [AppBundle] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            return names.filter { $0.hasSuffix(".app") }.compactMap { AppBundle(path: directory + "/" + $0) }
        }
        let index = InstalledAppIndex.build(home: homePath, extraApps: bundles)
        if Task.isCancelled { return nil }

        // 组容器只有被唯一一个应用声明时才算作它的关联文件（同一开发商的多个应用可能共用）
        let groupsByApp = Dictionary(bundles.map { ($0.path, AppStorageScanner.appGroups(ofAppAt: $0.path)) }, uniquingKeysWith: { a, _ in a })
        var groupClaims: [String: Int] = [:]
        for groups in groupsByApp.values {
            for group in Set(groups) { groupClaims[group, default: 0] += 1 }
        }

        // 2. 每个应用：真实大小、上次使用时间、关联文件（占进度的大头）
        var apps: [AppInfo] = []
        for (offset, bundle) in bundles.enumerated() {
            if Task.isCancelled { return nil }
            progress(0.05 + 0.7 * Double(offset) / Double(max(bundles.count, 1)), bundle.name)

            let groups = (groupsByApp[bundle.path] ?? []).filter { groupClaims[$0] == 1 }
            let related = bundle.bundleID.isEmpty ? [] : AppLeftovers.associatedFiles(
                bundleID: bundle.bundleID, appName: bundle.name, appGroups: groups, home: homePath, index: index
            )
            apps.append(AppInfo(
                name: bundle.name,
                bundleIdentifier: bundle.bundleID,
                path: bundle.path,
                version: bundle.shortVersion ?? String(localized: "未知"),
                buildVersion: bundle.buildVersion,
                size: CleanupManager.allocatedSize(atPath: bundle.path),
                lastUsedDate: lastUsedDate(path: bundle.path),
                isFromAppStore: FileManager.default.fileExists(atPath: bundle.path + "/Contents/_MASReceipt/receipt"),
                feedURL: bundle.feedURL,
                relatedFiles: related
            ))
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // 3. 已卸载应用的残留
        if Task.isCancelled { return nil }
        progress(0.78, String(localized: "正在查找已卸载应用的残留文件…"))
        var leftovers = AppLeftovers.trashedAppLeftovers(home: homePath, index: index)
        if Task.isCancelled { return nil }
        let claimed = Set(leftovers.map(\.path))
        leftovers += AppLeftovers.orphanedFiles(home: homePath, index: index).filter { !claimed.contains($0.path) }

        // 4. 安装包
        if Task.isCancelled { return nil }
        progress(0.95, String(localized: "正在检查下载文件夹中的安装包…"))
        let installers = scanInstallers(in: homePath + "/Downloads")

        progress(1, "")
        log.info("App scan: \(apps.count) apps, \(leftovers.count) leftovers, \(installers.count) installers")
        return AppScanResult(apps: apps, leftoverFiles: leftovers, installers: installers, scannedAt: Date())
    }

    // MARK: - 安装包

    nonisolated static func scanInstallers(in directory: String) -> [InstallerFile] {
        let url = URL(fileURLWithPath: directory)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isSymbolicLinkKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        return contents.compactMap { item -> InstallerFile? in
            guard installerExtensions.contains(item.pathExtension.lowercased()) else { return nil }
            let values = try? item.resourceValues(forKeys: Set(keys))
            guard values?.isSymbolicLink != true else { return nil }
            return InstallerFile(
                name: item.lastPathComponent,
                path: item.path,
                size: CleanupManager.allocatedSize(atPath: item.path),
                modified: values?.contentModificationDate
            )
        }
        .sorted { $0.size > $1.size }
    }

    // MARK: - 上次使用时间

    /// Finder「上次打开日期」对应的 Spotlight 属性；没有记录时返回 nil，不拿修改日期冒充。
    nonisolated static func lastUsedDate(path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              let value = MDItemCopyAttribute(item, kMDItemLastUsedDate) else { return nil }
        return value as? Date
    }
}

// MARK: - 应用包 Info.plist

nonisolated struct AppBundle: Sendable, Hashable {
    let path: String
    let bundleID: String
    let name: String
    let shortVersion: String?
    let buildVersion: String?
    let feedURL: String?

    init?(path: String) {
        guard let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any] else { return nil }
        self.path = path
        self.bundleID = plist["CFBundleIdentifier"] as? String ?? ""
        self.name = AppStorageScanner.displayName(plist: plist, path: path)
        self.shortVersion = plist["CFBundleShortVersionString"] as? String
        self.buildVersion = plist["CFBundleVersion"] as? String
        self.feedURL = (plist["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
