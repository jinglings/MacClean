//
//  SmartCareScanners.swift
//  MacClean
//
//  智能呵护：重复文件 / 大文件 / 损坏启动项 扫描器
//  全部为无状态静态方法，可在后台线程调用。
//

import Foundation

// 重复文件扫描见 DuplicateFinder.swift（与「重复与相似」页面共用）。

// MARK: - 大文件扫描

enum LargeFileFinder {

    /// 一键体检用：取超过 minSize 的前 limit 个大文件。遍历规则与「大型与陈旧文件」页面共用 LargeOldFileScanner。
    nonisolated static func findLargeFiles(
        under root: URL,
        minSize: Int64 = 500 * 1024 * 1024,
        limit: Int = 50,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [CleanableItem] {
        let records = try await LargeOldFileScanner.scan(under: root, minSize: minSize, resolveLastOpened: false, progress: progress)
        return records.prefix(limit).map { record in
            CleanableItem(
                name: record.name,
                path: record.path,
                size: record.size,
                category: .largeFiles,
                isSelected: false,
                description: (record.path as NSString).deletingLastPathComponent,
                lastModified: record.modified
            )
        }
    }
}

// MARK: - 损坏启动项扫描

enum BrokenLoginItemFinder {

    /// 扫描 ~/Library/LaunchAgents/*.plist，找出指向不存在可执行文件的损坏项。
    /// plist 解析失败的项保守跳过，不判定为损坏。
    nonisolated static func findBrokenLoginItems(home: URL) -> [CleanableItem] {
        let fileManager = FileManager.default
        let launchAgentsURL = home.appendingPathComponent("Library/LaunchAgents")

        guard let plistURLs = try? fileManager.contentsOfDirectory(
            at: launchAgentsURL,
            includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "plist" }) else {
            return []
        }

        var result: [CleanableItem] = []

        for plistURL in plistURLs {
            guard let data = try? Data(contentsOf: plistURL) else { continue }
            guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                continue
            }

            var programPath: String?
            if let program = plist["Program"] as? String {
                programPath = program
            } else if let args = plist["ProgramArguments"] as? [String], let first = args.first {
                programPath = first
            }

            guard let rawPath = programPath, !rawPath.isEmpty else { continue }

            let expandedPath = (rawPath as NSString).expandingTildeInPath
            guard !fileManager.fileExists(atPath: expandedPath) else { continue }

            let lastModified = (try? plistURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            result.append(CleanableItem(
                name: plistURL.lastPathComponent,
                path: plistURL.path,
                size: CleanupManager.allocatedSize(atPath: plistURL.path),
                category: .brokenLoginItems,
                isSelected: true,
                description: String(localized: "指向不存在的程序: \(rawPath)"),
                lastModified: lastModified
            ))
        }

        return result
    }
}
