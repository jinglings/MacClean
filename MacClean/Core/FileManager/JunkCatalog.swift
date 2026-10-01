//
//  JunkCatalog.swift
//  MacClean
//
//  「释放空间」各分组的扫描规则。
//  全部为无状态 nonisolated 静态方法，可在后台线程调用（工程默认 MainActor 隔离）。
//

import Foundation

enum JunkGroupID: String, CaseIterable, Identifiable, Sendable {
    case appCaches
    case browserCaches
    case logs
    case installers
    case mailAttachments
    case iosDevices
    case trash

    nonisolated var id: String { rawValue }

    var title: String {
        switch self {
        case .appCaches: return String(localized: "应用缓存")
        case .browserCaches: return String(localized: "浏览器缓存")
        case .logs: return String(localized: "日志与诊断报告")
        case .installers: return String(localized: "下载的安装包")
        case .mailAttachments: return String(localized: "邮件附件")
        case .iosDevices: return String(localized: "iPhone / iPad 备份与固件")
        case .trash: return String(localized: "废纸篓")
        }
    }

    var subtitle: String {
        switch self {
        case .appCaches: return String(localized: "应用运行时生成的缓存与窗口状态，删除后会按需重建。")
        case .browserCaches: return String(localized: "Safari、Chrome、Edge、Firefox 等的网页缓存，不影响书签、密码与历史记录。")
        case .logs: return String(localized: "超过 7 天的应用日志与崩溃报告。")
        case .installers: return String(localized: "下载与桌面中的 .dmg / .pkg / .xip / .iso，超过 30 天的默认勾选。")
        case .mailAttachments: return String(localized: "邮件 App 打开附件时保存的本地副本，原件仍在邮件服务器上。")
        case .iosDevices: return String(localized: "旧的设备备份（默认不勾选）与已下载的固件更新包。")
        case .trash: return String(localized: "清空后永久删除、不可恢复，默认不勾选。")
        }
    }

    var icon: String {
        switch self {
        case .appCaches: return "square.stack.3d.up"
        case .browserCaches: return "globe"
        case .logs: return "doc.text"
        case .installers: return "shippingbox"
        case .mailAttachments: return "paperclip"
        case .iosDevices: return "iphone"
        case .trash: return "trash"
        }
    }

    /// 需要在卡片上额外强调的风险提示。
    var riskNote: String? {
        switch self {
        case .trash: return String(localized: "永久删除")
        default: return nil
        }
    }
}

enum JunkScanner {

    nonisolated static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso"]

    /// 浏览器缓存目录（相对 ~/Library/Caches）。
    nonisolated static let browserCacheDirectories: [(name: String, path: String)] = [
        ("Safari", "com.apple.Safari"),
        ("Google Chrome", "Google/Chrome"),
        ("Microsoft Edge", "Microsoft Edge"),
        ("Brave", "BraveSoftware"),
        ("Firefox", "Firefox"),
        ("Arc", "company.thebrowser.Browser"),
        ("Opera", "com.operasoftware.Opera"),
        ("Vivaldi", "com.vivaldi.Vivaldi"),
        ("Chromium", "Chromium"),
    ]

    nonisolated static var browserCacheTopLevelNames: Set<String> {
        Set(browserCacheDirectories.compactMap { $0.path.split(separator: "/").first.map(String.init) })
    }

    nonisolated static func scan(_ group: JunkGroupID, home: URL, now: Date = Date()) -> [CleanableItem] {
        let items: [CleanableItem]
        switch group {
        case .appCaches: items = scanAppCaches(home: home)
        case .browserCaches: items = scanBrowserCaches(home: home)
        case .logs: items = scanLogs(home: home, now: now)
        case .installers: items = scanInstallers(home: home, now: now)
        case .mailAttachments: items = scanMailAttachments(home: home)
        case .iosDevices: items = scanIOSBackups(home: home) + scanIOSUpdates(home: home)
        case .trash: items = scanTrash(home: home)
        }
        return items.sorted { $0.size > $1.size }
    }

    // MARK: - 应用缓存

    nonisolated static func scanAppCaches(home: URL, minSize: Int64 = 1024 * 1024) -> [CleanableItem] {
        let fileManager = FileManager.default
        let cachesRoot = home.appendingPathComponent("Library/Caches")
        // 浏览器与开发工具各有独立分组，这里排除避免重复计入。
        let excluded = browserCacheTopLevelNames.union(DevCacheCatalog.libraryCacheNames)

        var items: [CleanableItem] = []
        if let children = try? fileManager.contentsOfDirectory(at: cachesRoot, includingPropertiesForKeys: nil) {
            for child in children {
                let name = child.lastPathComponent
                guard !excluded.contains(name) else { continue }
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                let size = CleanupManager.allocatedSize(atPath: child.path)
                guard size > minSize else { continue }
                items.append(CleanableItem(
                    name: name,
                    path: child.path,
                    size: size,
                    category: .userCache,
                    isSelected: true,
                    description: nil,
                    lastModified: DevCacheCatalog.modificationDate(of: child)
                ))
            }
        }

        let savedState = home.appendingPathComponent("Library/Saved Application State")
        let savedStateSize = CleanupManager.allocatedSize(atPath: savedState.path)
        if savedStateSize > minSize {
            items.append(CleanableItem(
                name: String(localized: "应用窗口状态"),
                path: savedState.path,
                size: savedStateSize,
                category: .userCache,
                isSelected: true,
                description: String(localized: "应用重新打开时恢复窗口用的快照"),
                lastModified: nil
            ))
        }
        return items
    }

    // MARK: - 浏览器缓存

    nonisolated static func scanBrowserCaches(home: URL, minSize: Int64 = 1024 * 1024) -> [CleanableItem] {
        let cachesRoot = home.appendingPathComponent("Library/Caches")
        return browserCacheDirectories.compactMap { browser in
            let url = cachesRoot.appendingPathComponent(browser.path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let size = CleanupManager.allocatedSize(atPath: url.path)
            guard size > minSize else { return nil }
            return CleanableItem(
                name: browser.name,
                path: url.path,
                size: size,
                category: .browserCache,
                isSelected: true,
                description: String(localized: "网页缓存，浏览器运行时清理效果最好在其退出后进行"),
                lastModified: nil
            )
        }
    }

    // MARK: - 日志

    /// 只统计超过 retentionDays 天的日志文件大小，与 CleanupManager 的实际清理范围保持一致。
    nonisolated static func scanLogs(home: URL, now: Date = Date(), retentionDays: Int = 7, minSize: Int64 = 256 * 1024) -> [CleanableItem] {
        let fileManager = FileManager.default
        let logsRoot = home.appendingPathComponent("Library/Logs")
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)

        guard let children = try? fileManager.contentsOfDirectory(at: logsRoot, includingPropertiesForKeys: nil) else { return [] }

        return children.compactMap { child in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let size = oldFilesSize(at: child.path, before: cutoff)
            guard size > minSize else { return nil }
            let isCrashReports = child.lastPathComponent == "DiagnosticReports"
            return CleanableItem(
                name: isCrashReports ? String(localized: "崩溃与诊断报告") : child.lastPathComponent,
                path: child.path,
                size: size,
                category: .systemLogs,
                isSelected: true,
                description: String(localized: "超过 \(retentionDays) 天的日志"),
                lastModified: nil
            )
        }
    }

    nonisolated static func oldFilesSize(at path: String, before cutoff: Date) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while let relative = enumerator.nextObject() as? String {
            var info = stat()
            let filePath = path + "/" + relative
            guard lstat(filePath, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            guard modified < cutoff else { continue }
            let allocated = Int64(info.st_blocks) * 512
            total += allocated > 0 ? allocated : Int64(info.st_size)
        }
        return total
    }

    // MARK: - 安装包

    nonisolated static func scanInstallers(home: URL, now: Date = Date(), selectAfterDays: Int = 30) -> [CleanableItem] {
        let fileManager = FileManager.default
        let selectCutoff = now.addingTimeInterval(-Double(selectAfterDays) * 86_400)
        var items: [CleanableItem] = []

        for folder in ["Downloads", "Desktop"] {
            let root = home.appendingPathComponent(folder)
            // 两层：根目录 + 一级子目录（很多人按日期/项目归档下载）
            var directories = [root]
            if let children = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                directories += children.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                        && !installerExtensions.contains($0.pathExtension.lowercased())
                        && $0.pathExtension.lowercased() != "app"
                }
            }

            for directory in directories {
                guard let files = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for file in files where installerExtensions.contains(file.pathExtension.lowercased()) {
                    let size = CleanupManager.allocatedSize(atPath: file.path)
                    guard size > 0 else { continue }
                    let modified = DevCacheCatalog.modificationDate(of: file)
                    let days = modified.map { Int(now.timeIntervalSince($0) / 86_400) }
                    items.append(CleanableItem(
                        name: file.lastPathComponent,
                        path: file.path,
                        size: size,
                        category: .installers,
                        isSelected: (modified ?? now) < selectCutoff,
                        description: days.map { String(localized: "\(folder) · \($0) 天前") } ?? folder,
                        lastModified: modified
                    ))
                }
            }
        }
        return items
    }

    // MARK: - 邮件附件

    nonisolated static func scanMailAttachments(home: URL) -> [CleanableItem] {
        let url = home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let size = CleanupManager.allocatedSize(atPath: url.path)
        guard size > 1024 * 1024 else { return [] }
        return [CleanableItem(
            name: String(localized: "邮件下载的附件"),
            path: url.path,
            size: size,
            category: .mailAttachments,
            isSelected: true,
            description: String(localized: "再次打开邮件时可重新下载"),
            lastModified: nil
        )]
    }

    // MARK: - iOS 备份与固件

    nonisolated static func scanIOSBackups(home: URL) -> [CleanableItem] {
        let fileManager = FileManager.default
        let root = home.appendingPathComponent("Library/Application Support/MobileSync/Backup")
        guard let backups = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }

        return backups.compactMap { backup in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: backup.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let size = CleanupManager.allocatedSize(atPath: backup.path)
            guard size > 0 else { return nil }

            var deviceName = String(localized: "设备备份")
            var backupDate: Date?
            if let data = try? Data(contentsOf: backup.appendingPathComponent("Info.plist")),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                deviceName = (plist["Device Name"] as? String) ?? (plist["Display Name"] as? String) ?? deviceName
                backupDate = plist["Last Backup Date"] as? Date
            }
            let dateText = backupDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none) }

            var item = CleanableItem(
                name: deviceName,
                path: backup.path,
                size: size,
                category: .iosBackups,
                isSelected: false,
                description: dateText.map { String(localized: "备份于 \($0)") } ?? String(localized: "本地设备备份"),
                lastModified: backupDate ?? DevCacheCatalog.modificationDate(of: backup)
            )
            item.removesContainer = true
            return item
        }
    }

    nonisolated static func scanIOSUpdates(home: URL) -> [CleanableItem] {
        let fileManager = FileManager.default
        var items: [CleanableItem] = []
        for folder in ["iPhone Software Updates", "iPad Software Updates", "iPod Software Updates"] {
            let root = home.appendingPathComponent("Library/iTunes/\(folder)")
            guard let files = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension.lowercased() == "ipsw" {
                var item = CleanableItem(
                    name: file.lastPathComponent,
                    path: file.path,
                    size: CleanupManager.allocatedSize(atPath: file.path),
                    category: .iosUpdates,
                    isSelected: true,
                    description: String(localized: "固件更新包，更新设备时会重新下载"),
                    lastModified: DevCacheCatalog.modificationDate(of: file)
                )
                item.removesContainer = true
                items.append(item)
            }
        }
        return items
    }

    // MARK: - 废纸篓

    nonisolated static func scanTrash(home: URL) -> [CleanableItem] {
        let url = home.appendingPathComponent(".Trash")
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        let visible = children.filter { $0 != ".DS_Store" }
        guard !visible.isEmpty else { return [] }
        let size = CleanupManager.allocatedSize(atPath: url.path)
        guard size > 0 else { return [] }
        return [CleanableItem(
            name: String(localized: "废纸篓中的 \(visible.count) 个项目"),
            path: url.path,
            size: size,
            category: .trash,
            isSelected: false,
            description: String(localized: "清空后无法恢复"),
            lastModified: nil
        )]
    }
}
