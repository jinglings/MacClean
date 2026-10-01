//
//  DiskAnalyzer.swift
//  MacClean
//
//  磁盘分析器
//

import Darwin
import Foundation

private extension String {
    nonisolated func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

actor DiskAnalyzer {
    static let shared = DiskAnalyzer()

    private init() {}

    // macOS exposes several synthetic mount points under /System/Volumes.
    // Space Lens scans the user-facing root and skips those internal volumes to
    // avoid duplicate Data-volume accounting.
    static let dataVolumeRoot = "/System/Volumes/Data"

    // MARK: - 空间透镜扫描（一次建全树）
    //
    // 与旧实现（对每层做一次全树 recursiveUsage 但只保留一层子目录，用户进入子目录时
    // 重新全树扫描）不同：buildSpaceLensTree 自底向上一次性构建整棵、已按层剪枝的树，
    // 内存有界，导航到已建好的节点不再触发任何磁盘重扫。

    /// 空间透镜进度累计器：多个并发的顶层目录扫描任务共享同一个实例，
    /// 用锁保护累计字节/条目数，达到阈值才回调，避免刷爆 MainActor。
    final class SpaceLensProgressState: @unchecked Sendable {
        private let lock = NSLock()
        private var accumulatedBytes: Int64 = 0
        private var accumulatedEntries = 0
        private var lastReportedBytes: Int64 = 0
        private var lastReportedEntries = 0
        private var unreadableDirCount = 0
        private let diskUsedSpace: Int64
        private let progressCallback: (@Sendable (SpaceLensScanProgress) -> Void)?

        private static let reportEntryThreshold = 8192
        private static let reportByteThreshold: Int64 = 1_073_741_824 // 1 GB

        init(diskUsedSpace: Int64, progress: (@Sendable (SpaceLensScanProgress) -> Void)?) {
            self.diskUsedSpace = diskUsedSpace
            self.progressCallback = progress
        }

        func markUnreadable() {
            lock.lock()
            unreadableDirCount += 1
            lock.unlock()
        }

        var unreadableCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return unreadableDirCount
        }

        func record(bytesDelta: Int64, entriesDelta: Int, currentPath: String) {
            guard bytesDelta != 0 || entriesDelta != 0 else { return }

            lock.lock()
            accumulatedBytes += bytesDelta
            accumulatedEntries += entriesDelta
            let shouldReport = (accumulatedEntries - lastReportedEntries) >= Self.reportEntryThreshold
                || (accumulatedBytes - lastReportedBytes) >= Self.reportByteThreshold
            if shouldReport {
                lastReportedEntries = accumulatedEntries
                lastReportedBytes = accumulatedBytes
            }
            let bytesSnapshot = accumulatedBytes
            let itemsSnapshot = accumulatedEntries
            lock.unlock()

            guard shouldReport else { return }
            let progressValue = min(Double(bytesSnapshot) / Double(max(diskUsedSpace, 1)), 0.98)
            progressCallback?(SpaceLensScanProgress(
                scannedPath: DiskAnalyzer.cleanProgressPath(currentPath),
                scannedItems: itemsSnapshot,
                progress: progressValue
            ))
        }
    }

    nonisolated static let spaceLensVisibleFolderLimit = 10

    // 按扩展名判断"包"目录，避免对每个目录都调用代价较高的 isPackageKey 查询。
    nonisolated private static let spaceLensBundleExtensions: Set<String> = [
        "app", "bundle", "framework", "appex", "xcarchive",
        "photoslibrary", "pvm", "vmwarevm",
    ]

    nonisolated static func scanSpaceLens(
        rootURL: URL = URL(fileURLWithPath: "/"),
        progress: (@Sendable (SpaceLensScanProgress) -> Void)? = nil
    ) async throws -> SpaceLensScanResult {
        let startTime = Date()
        let diskInfo = try getDiskInfo()
        let (root, unreadableCount) = try await scanSpaceLensRoot(
            at: rootURL.standardizedFileURL,
            diskUsedSpace: diskInfo.usedSpace,
            progress: progress
        )
        let duration = Date().timeIntervalSince(startTime)

        return SpaceLensScanResult(
            root: root,
            diskInfo: diskInfo,
            scanDuration: duration,
            unreadableCount: unreadableCount
        )
    }

    /// 兜底重扫单个子树（正常情况下全树已在 scanSpaceLens 中建好，很少被触发）。
    nonisolated static func scanSpaceLensDirectory(
        at url: URL,
        progress: (@Sendable (SpaceLensScanProgress) -> Void)? = nil
    ) async throws -> SpaceLensItem {
        let diskUsedSpace = (try? getDiskInfo().usedSpace) ?? 1
        let progressState = SpaceLensProgressState(diskUsedSpace: diskUsedSpace, progress: progress)
        return try buildSpaceLensTree(
            at: url.standardizedFileURL.path,
            visibleFolderLimit: spaceLensVisibleFolderLimit,
            progressState: progressState
        )
    }

    // MARK: - 顶层并发扫描

    // 顶层目录并发扫描：每个直属子目录一个 task，共享同一个 progressState。
    nonisolated private static func scanSpaceLensRoot(
        at url: URL,
        diskUsedSpace: Int64,
        progress: (@Sendable (SpaceLensScanProgress) -> Void)?
    ) async throws -> (item: SpaceLensItem, unreadableCount: Int) {
        try Task.checkCancellation()

        let path = url.path
        let progressState = SpaceLensProgressState(diskUsedSpace: diskUsedSpace, progress: progress)

        var rootInfo = stat()
        guard lstat(path, &rootInfo) == 0 else {
            throw NSError(domain: "DiskAnalyzer", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "无法访问 \(path)")])
        }
        let ownSize = allocatedSizeFrom(rootInfo)
        let name = displayNameStatic(atPath: path, isRoot: true)
        let lastModified = modificationDateFrom(rootInfo)

        guard let directory = opendir(path) else {
            throw NSError(domain: "DiskAnalyzer", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "无法读取 \(path)")])
        }

        var childDirectoryPaths: [String] = []
        var directFilesSize: Int64 = 0
        var directFilesCount = 0

        while let entry = readdir(directory) {
            let entryName = entryFileName(entry)
            if entryName == "." || entryName == ".." { continue }

            let childPath = joinPath(path, entryName)
            if shouldSkipPathDuringRecursiveScan(childPath) { continue }

            let (entryType, maybeStat) = resolveEntryType(childPath: childPath, dtype: entry.pointee.d_type)
            if entryType == UInt8(DT_UNKNOWN) { continue } // lstat 失败，跳过
            if entryType == UInt8(DT_LNK) { continue } // 符号链接跳过，不跟随

            if entryType == UInt8(DT_DIR) {
                childDirectoryPaths.append(childPath)
            } else {
                let info = maybeStat ?? statOrNil(childPath)
                guard let info else { continue }
                let size = allocatedSizeFrom(info)
                directFilesSize += size
                directFilesCount += 1
                progressState.record(bytesDelta: size, entriesDelta: 1, currentPath: childPath)
            }
        }
        closedir(directory)

        var folderChildren: [SpaceLensItem] = []
        try await withThrowingTaskGroup(of: SpaceLensItem.self) { group in
            for childPath in childDirectoryPaths {
                group.addTask {
                    try buildSpaceLensTree(
                        at: childPath,
                        visibleFolderLimit: spaceLensVisibleFolderLimit,
                        progressState: progressState
                    )
                }
            }
            for try await item in group {
                folderChildren.append(item)
            }
        }

        let totalItemCount = folderChildren.reduce(0) { $0 + 1 + $1.itemCount } + directFilesCount
        let visibleChildren = pruneChildren(
            folderChildren: folderChildren,
            directFilesSize: directFilesSize,
            directFilesCount: directFilesCount,
            parentPath: path,
            visibleFolderLimit: spaceLensVisibleFolderLimit
        )
        let childrenTotalSize = visibleChildren.reduce(0) { $0 + $1.size }

        let rootItem = SpaceLensItem(
            name: name,
            path: path,
            size: ownSize + childrenTotalSize,
            isDirectory: true,
            children: visibleChildren.sorted { $0.size > $1.size },
            itemCount: totalItemCount,
            isReadable: true,
            isVirtual: false,
            lastModified: lastModified
        )
        return (rootItem, progressState.unreadableCount)
    }

    // MARK: - 单个子树构建（自底向上，按层剪枝）

    nonisolated static func buildSpaceLensTree(
        at path: String,
        visibleFolderLimit: Int,
        progressState: SpaceLensProgressState
    ) throws -> SpaceLensItem {
        try Task.checkCancellation()

        let name = displayNameStatic(atPath: path)

        if shouldSkipPathDuringRecursiveScan(path) {
            return SpaceLensItem(name: name, path: path, size: 0, isDirectory: true, children: [],
                                  itemCount: 0, isReadable: false, isVirtual: false, lastModified: nil)
        }

        guard let selfInfo = statOrNil(path) else {
            progressState.markUnreadable()
            return SpaceLensItem(name: name, path: path, size: 0, isDirectory: true, children: [],
                                  itemCount: 0, isReadable: false, isVirtual: false, lastModified: nil)
        }

        let lastModified = modificationDateFrom(selfInfo)

        if (selfInfo.st_mode & S_IFMT) == S_IFLNK {
            // 符号链接不跟随、不计入大小，作为不可进入的文件型节点呈现。
            return SpaceLensItem(name: name, path: path, size: 0, isDirectory: false, children: [],
                                  itemCount: 0, isReadable: false, isVirtual: false, lastModified: lastModified)
        }

        let ownSize = allocatedSizeFrom(selfInfo)

        guard (selfInfo.st_mode & S_IFMT) == S_IFDIR else {
            progressState.record(bytesDelta: ownSize, entriesDelta: 1, currentPath: path)
            return SpaceLensItem(name: name, path: path, size: ownSize, isDirectory: false, children: [],
                                  itemCount: 0, isReadable: true, isVirtual: false, lastModified: lastModified)
        }

        // "包"目录（.app/.framework 等）整体作为一个不可进入的节点，大小仍全树统计。
        if isBundlePath(path) {
            let usage = try packageUsage(atPath: path, progressState: progressState)
            return SpaceLensItem(name: name, path: path, size: usage.size, isDirectory: false, children: [],
                                  itemCount: usage.itemCount, isReadable: false, isVirtual: false, lastModified: lastModified)
        }

        guard let directory = opendir(path) else {
            progressState.markUnreadable()
            return SpaceLensItem(name: name, path: path, size: ownSize, isDirectory: true, children: [],
                                  itemCount: 0, isReadable: false, isVirtual: false, lastModified: lastModified)
        }
        defer { closedir(directory) }

        var folderChildren: [SpaceLensItem] = []
        var directFilesSize: Int64 = 0
        var directFilesCount = 0
        var totalItemCount = 0
        var processedSinceCheck = 0

        while let entry = readdir(directory) {
            processedSinceCheck += 1
            if processedSinceCheck >= 4096 {
                try Task.checkCancellation()
                processedSinceCheck = 0
            }

            let entryName = entryFileName(entry)
            if entryName == "." || entryName == ".." { continue }

            let childPath = joinPath(path, entryName)
            if shouldSkipPathDuringRecursiveScan(childPath) { continue }

            let (entryType, maybeStat) = resolveEntryType(childPath: childPath, dtype: entry.pointee.d_type)
            if entryType == UInt8(DT_UNKNOWN) { continue }
            if entryType == UInt8(DT_LNK) { continue }

            if entryType == UInt8(DT_DIR) {
                if isBundlePath(childPath) {
                    let usage = try packageUsage(atPath: childPath, progressState: progressState)
                    folderChildren.append(SpaceLensItem(
                        name: displayNameStatic(atPath: childPath), path: childPath, size: usage.size,
                        isDirectory: false, children: [], itemCount: usage.itemCount,
                        isReadable: false, isVirtual: false,
                        lastModified: maybeStat.map(modificationDateFrom)
                    ))
                    totalItemCount += 1 + usage.itemCount
                } else {
                    let childItem = try buildSpaceLensTree(
                        at: childPath, visibleFolderLimit: visibleFolderLimit, progressState: progressState
                    )
                    folderChildren.append(childItem)
                    totalItemCount += 1 + childItem.itemCount
                }
            } else {
                let info = maybeStat ?? statOrNil(childPath)
                guard let info else { continue }
                let size = allocatedSizeFrom(info)
                directFilesSize += size
                directFilesCount += 1
                totalItemCount += 1
                progressState.record(bytesDelta: size, entriesDelta: 1, currentPath: childPath)
            }
        }

        let visibleChildren = pruneChildren(
            folderChildren: folderChildren,
            directFilesSize: directFilesSize,
            directFilesCount: directFilesCount,
            parentPath: path,
            visibleFolderLimit: visibleFolderLimit
        )
        let childrenTotalSize = visibleChildren.reduce(0) { $0 + $1.size }
        progressState.record(bytesDelta: ownSize, entriesDelta: 0, currentPath: path)

        return SpaceLensItem(
            name: name, path: path, size: ownSize + childrenTotalSize, isDirectory: true,
            children: visibleChildren.sorted { $0.size > $1.size },
            itemCount: totalItemCount, isReadable: true, isVirtual: false, lastModified: lastModified
        )
    }

    /// 仅统计大小/条目数的快速遍历，供"包"目录使用——不构建内部子树。
    nonisolated private static func packageUsage(
        atPath path: String,
        progressState: SpaceLensProgressState
    ) throws -> (size: Int64, itemCount: Int) {
        try Task.checkCancellation()
        if shouldSkipPathDuringRecursiveScan(path) { return (0, 0) }

        guard let info = statOrNil(path) else {
            progressState.markUnreadable()
            return (0, 0)
        }
        if (info.st_mode & S_IFMT) == S_IFLNK { return (0, 0) }

        let ownSize = allocatedSizeFrom(info)
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            progressState.record(bytesDelta: ownSize, entriesDelta: 1, currentPath: path)
            return (ownSize, 0)
        }

        guard let directory = opendir(path) else {
            progressState.markUnreadable()
            return (ownSize, 0)
        }
        defer { closedir(directory) }

        var total = ownSize
        var itemCount = 0
        var processedSinceCheck = 0

        while let entry = readdir(directory) {
            processedSinceCheck += 1
            if processedSinceCheck >= 4096 {
                try Task.checkCancellation()
                processedSinceCheck = 0
            }

            let entryName = entryFileName(entry)
            if entryName == "." || entryName == ".." { continue }
            let childPath = joinPath(path, entryName)
            if shouldSkipPathDuringRecursiveScan(childPath) { continue }

            let (entryType, maybeStat) = resolveEntryType(childPath: childPath, dtype: entry.pointee.d_type)
            if entryType == UInt8(DT_UNKNOWN) { continue }
            if entryType == UInt8(DT_LNK) { continue }

            itemCount += 1
            if entryType == UInt8(DT_DIR) {
                let childUsage = try packageUsage(atPath: childPath, progressState: progressState)
                total += childUsage.size
                itemCount += childUsage.itemCount
            } else {
                let info = maybeStat ?? statOrNil(childPath)
                guard let info else { continue }
                let size = allocatedSizeFrom(info)
                total += size
                progressState.record(bytesDelta: size, entriesDelta: 1, currentPath: childPath)
            }
        }
        return (total, itemCount)
    }

    // MARK: - 剪枝：每层只保留 size 最大的前 N 个子目录，其余聚合为"其他"

    nonisolated private static func pruneChildren(
        folderChildren: [SpaceLensItem],
        directFilesSize: Int64,
        directFilesCount: Int,
        parentPath: String,
        visibleFolderLimit: Int
    ) -> [SpaceLensItem] {
        let sortedFolders = folderChildren.sorted { $0.size > $1.size }
        var visibleChildren = Array(sortedFolders.prefix(visibleFolderLimit))
        let hiddenFolders = Array(sortedFolders.dropFirst(visibleFolderLimit))
        let otherSize = directFilesSize + hiddenFolders.reduce(0) { $0 + $1.size }
        let otherCount = directFilesCount + hiddenFolders.reduce(0) { $0 + 1 + $1.itemCount }

        if otherSize > 0 || otherCount > 0 {
            visibleChildren.append(SpaceLensItem(
                name: String(localized: "其他"),
                path: parentPath + "/.space-lens-other",
                size: otherSize,
                isDirectory: true,
                children: [],
                itemCount: otherCount,
                isReadable: false,
                isVirtual: true,
                lastModified: nil
            ))
        }

        return visibleChildren.sorted { $0.size > $1.size }
    }

    // MARK: - readdir/lstat 辅助

    nonisolated private static func entryFileName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                String(cString: $0)
            }
        }
    }

    nonisolated private static func joinPath(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }

    nonisolated private static func statOrNil(_ path: String) -> stat? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info
    }

    /// d_type == DT_UNKNOWN 时才 lstat；返回解析后的类型（DT_DIR/DT_REG/DT_LNK）与已取得的 stat（若有）。
    /// 返回 DT_UNKNOWN 表示 lstat 失败，调用方应跳过该条目。
    nonisolated private static func resolveEntryType(childPath: String, dtype: UInt8) -> (type: UInt8, stat: stat?) {
        if dtype == UInt8(DT_DIR) || dtype == UInt8(DT_REG) || dtype == UInt8(DT_LNK) {
            return (dtype, nil)
        }
        guard let info = statOrNil(childPath) else { return (UInt8(DT_UNKNOWN), nil) }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return (UInt8(DT_DIR), info)
        case S_IFLNK: return (UInt8(DT_LNK), info)
        default: return (UInt8(DT_REG), info)
        }
    }

    nonisolated private static func allocatedSizeFrom(_ info: stat) -> Int64 {
        let allocated = Int64(info.st_blocks) * 512
        return allocated > 0 ? allocated : Int64(info.st_size)
    }

    nonisolated private static func modificationDateFrom(_ info: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
             + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    nonisolated private static func isBundlePath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return !ext.isEmpty && spaceLensBundleExtensions.contains(ext)
    }

    nonisolated private static func displayNameStatic(atPath path: String, isRoot: Bool = false) -> String {
        if isRoot || path == "/" || path == dataVolumeRoot {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return (try? home.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
        }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    nonisolated private static func cleanProgressPath(_ path: String) -> String {
        path.hasPrefix(dataVolumeRoot)
            ? String(path.dropFirst(dataVolumeRoot.count)).ifEmpty("/")
            : path
    }

    // MARK: - 获取磁盘信息

    nonisolated private static func getDiskInfo() throws -> DiskInfo {
        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser

        let values = try homeURL.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])

        return DiskInfo(
            volumeName: values.volumeName ?? "Macintosh HD",
            totalSpace: Int64(values.volumeTotalCapacity ?? 0),
            freeSpace: Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        )
    }

    /// 伪文件系统、交换文件与 /System/Volumes 下的合成挂载点不参与统计（避免重复计算 Data 卷）。
    nonisolated private static func shouldSkipPathDuringRecursiveScan(_ path: String) -> Bool {
        if path == "/dev" || path == "/Volumes" || path == "/Network" || path == "/net" || path == "/proc" {
            return true
        }
        if path == "/private/var/vm" || path.hasPrefix("/private/var/vm/") {
            return true
        }
        if path == "/System/Volumes" || path.hasPrefix("/System/Volumes/") {
            return true
        }
        return false
    }
}
