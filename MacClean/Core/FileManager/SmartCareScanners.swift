//
//  SmartCareScanners.swift
//  MacClean
//
//  智能呵护：重复文件 / 大文件 / 损坏启动项 扫描器
//  全部为无状态静态方法，可在后台线程调用。
//

import Foundation
import CryptoKit

// MARK: - 重复文件扫描

enum DuplicateFinder {

    /// 在给定目录集合下查找重复文件。同一大小的文件会被逐个计算 SHA-256，
    /// 哈希相同即视为重复；每组按 `keeperOrder` 保留一个「原件」不生成条目（因此即使全选也删不光一整组），
    /// 其余副本作为可清理项返回。`directories` 的顺序即位置优先级，越靠前越像原件的存放位置。
    nonisolated static func findDuplicates(in directories: [URL], minSize: Int64 = 1_048_576) async throws -> [CleanableItem] {
        let fileManager = FileManager.default

        // 1. 收集候选文件，按大小分组
        var sizeGroups: [Int64: [URL]] = [:]

        for directory in directories {
            try Task.checkCancellation()
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey, .isSymbolicLinkKey, .fileSizeKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                try Task.checkCancellation()
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                guard values?.isSymbolicLink != true else { continue }
                guard values?.isPackage != true else { continue }
                let size = Int64(values?.fileSize ?? 0)
                guard size >= minSize else { continue }
                sizeGroups[size, default: []].append(url)
            }
        }

        // 2. 大小相同且组内 ≥2 个文件的，逐个计算哈希，按哈希分组
        var result: [CleanableItem] = []

        for (size, urls) in sizeGroups {
            guard urls.count >= 2 else { continue }
            try Task.checkCancellation()

            // 硬链接共享同一份磁盘数据，删掉其中一个不释放空间，按 inode 去重。
            var seenInodes: Set<String> = []
            let distinctURLs = urls.filter { url in
                var info = stat()
                guard lstat(url.path, &info) == 0 else { return false }
                return seenInodes.insert("\(info.st_dev):\(info.st_ino)").inserted
            }
            guard distinctURLs.count >= 2 else { continue }

            // 先用首尾各 64KB 的指纹粗筛，只有指纹相同的才做全量哈希，大文件场景能省掉绝大部分 IO。
            var prefixGroups: [String: [URL]] = [:]
            for url in distinctURLs {
                try Task.checkCancellation()
                guard let fingerprint = try? partialFingerprint(of: url, size: Int64(size)) else { continue }
                prefixGroups[fingerprint, default: []].append(url)
            }

            var hashGroups: [String: [URL]] = [:]
            for (_, candidates) in prefixGroups where candidates.count >= 2 {
                for url in candidates {
                    try Task.checkCancellation()
                    guard let hash = try? sha256(of: url) else { continue }
                    hashGroups[hash, default: []].append(url)
                }
            }

            for (_, duplicateURLs) in hashGroups {
                guard duplicateURLs.count >= 2 else { continue }

                // 第一个是保留的原件，不生成 item
                let sorted = duplicateURLs
                    .map { KeeperCandidate(url: $0, roots: directories) }
                    .sorted(by: keeperOrder)
                    .map(\.url)

                guard let keep = sorted.first else { continue }
                for url in sorted.dropFirst() {
                    let lastModified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
                    result.append(CleanableItem(
                        name: url.lastPathComponent,
                        path: url.path,
                        size: CleanupManager.allocatedSize(atPath: url.path),
                        category: .duplicates,
                        isSelected: true,
                        description: String(localized: "与 \(keep.lastPathComponent) 重复"),
                        lastModified: lastModified
                    ))
                }
            }
        }

        return result
    }

    /// 判断一组重复文件中哪个是「原件」所需的信息。
    nonisolated struct KeeperCandidate {
        let url: URL
        /// 所在扫描根目录的下标，越小越优先；不在任何根目录下的排最后。
        let locationRank: Int
        /// 文件名带「 (1)」「 copy」「副本」等系统生成的副本后缀。
        let looksLikeCopy: Bool
        /// 创建时间与修改时间中较早的一个，代表这份内容最早出现在磁盘上的时间。
        let earliestDate: Date

        init(url: URL, roots: [URL]) {
            self.url = url
            let path = url.standardizedFileURL.path
            locationRank = roots.firstIndex { root in
                let rootPath = root.standardizedFileURL.path
                return path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
            } ?? roots.count
            looksLikeCopy = DuplicateFinder.looksLikeCopy(url.deletingPathExtension().lastPathComponent)
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            earliestDate = [values?.creationDate, values?.contentModificationDate]
                .compactMap { $0 }
                .min() ?? Date.distantFuture
        }
    }

    /// 原件优先级：位置更规范 → 不带副本后缀 → 更早出现 → 路径更短。
    nonisolated static func keeperOrder(_ lhs: KeeperCandidate, _ rhs: KeeperCandidate) -> Bool {
        if lhs.locationRank != rhs.locationRank { return lhs.locationRank < rhs.locationRank }
        if lhs.looksLikeCopy != rhs.looksLikeCopy { return !lhs.looksLikeCopy }
        if lhs.earliestDate != rhs.earliestDate { return lhs.earliestDate < rhs.earliestDate }
        return lhs.url.path.count < rhs.url.path.count
    }

    /// 「报告 (1)」「报告 copy」「报告 copy 2」「报告 副本」这类系统/浏览器生成的副本名。
    nonisolated static func looksLikeCopy(_ baseName: String) -> Bool {
        let patterns = [
            #"\s\(\d+\)$"#,
            #"\scopy(\s\d+)?$"#,
            #"\s?副本(\s?\d+)?$"#,
        ]
        return patterns.contains { baseName.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// 首尾各 64KB 的 SHA-256 指纹，用于廉价预筛。
    nonisolated static func partialFingerprint(of url: URL, size: Int64, sampleSize: Int = 64 * 1024) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        hasher.update(data: try handle.read(upToCount: sampleSize) ?? Data())
        if size > Int64(sampleSize * 2) {
            try handle.seek(toOffset: UInt64(size - Int64(sampleSize)))
            hasher.update(data: try handle.read(upToCount: sampleSize) ?? Data())
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 流式计算文件的 SHA-256，按 1MB 分块读取，避免大文件占用过多内存。
    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1024 * 1024

        while true {
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

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
