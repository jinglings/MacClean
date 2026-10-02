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

    // MARK: - 可清除空间（存储地图摘要用）

    /// 可清除空间 = 「重要用途可用」−「真正空闲」，与系统数据页同一口径。
    nonisolated static func purgeableBytes(available: Int64, availableForImportantUsage: Int64) -> Int64 {
        SystemDataRules.purgeable(available: available, availableForImportantUsage: availableForImportantUsage)
    }

    /// 读取卷的可清除空间；读不到返回 nil。会访问文件系统，别在主线程调用。
    nonisolated static func purgeableSpace(
        onVolumeOf url: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]),
              let available = values.volumeAvailableCapacity,
              let important = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return purgeableBytes(available: Int64(available), availableForImportantUsage: important)
    }

    // MARK: - 只计大小的遍历（系统数据用）
    //
    // 用 getattrlistbulk 批量读取目录条目（比空间透镜的 readdir + lstat 快），不建树：只返回总占用和直属子项占用。
    // 与 buildSpaceLensTree 的区别：
    // - 只算实际分配的块（st_blocks），不回退到 st_size——已移出到 iCloud 的文件不占本地空间；
    // - 硬链接按 (dev, inode) 只计一次；APFS 克隆的共享块按克隆族只计一次（私有块照常计入）；
    // - excluding 中的路径整棵跳过（已归入别的类别）；不跨越挂载点（模拟器运行时等磁盘映像）。

    /// 跨多个并发遍历共享的去重表。
    nonisolated final class UsageDeduper: @unchecked Sendable {
        private struct InodeKey: Hashable {
            let dev: Int32
            let ino: UInt64
        }

        private let lock = NSLock()
        private var inodes: Set<InodeKey> = []
        private var cloneFamilies: Set<UInt64> = []

        init() {}

        /// 第一次见到这个硬链接 inode 时返回 true。
        func claimInode(dev: Int32, ino: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return inodes.insert(InodeKey(dev: dev, ino: ino)).inserted
        }

        /// 第一次见到这个克隆族时返回 true。
        func claimCloneFamily(_ id: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return cloneFamilies.insert(id).inserted
        }
    }

    nonisolated enum UsageAccess: Sendable, Equatable {
        case measured
        /// 路径不存在（或是指向别处的符号链接）
        case missing
        /// 隐私保护拒绝（EPERM）：通常需要「完全磁盘访问权限」
        case deniedByPrivacy
        /// Unix 权限拒绝（EACCES）：属于 root，需要管理员权限
        case deniedByOwner
    }

    nonisolated struct UsageChild: Sendable, Equatable {
        let name: String
        let path: String
        let size: Int64
    }

    nonisolated struct UsageMeasurement: Sendable {
        var access: UsageAccess
        var size: Int64 = 0
        var children: [UsageChild] = []
        /// 遍历途中无法读取的子目录数（总数可能偏小）
        var unreadableDirectories = 0
    }

    /// 测量一个路径（目录或单个文件）的实际占用。直属子目录并发遍历。
    /// onBytes 以批为单位回调新增字节，用于进度显示。
    nonisolated static func measureUsage(
        atPath path: String,
        excluding: Set<String> = [],
        deduper: UsageDeduper,
        onBytes: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> UsageMeasurement {
        try Task.checkCancellation()
        var rootInfo = stat()
        guard lstat(path, &rootInfo) == 0 else {
            return UsageMeasurement(access: errno == ENOENT || errno == ENOTDIR ? .missing : accessFromErrno(errno))
        }
        switch rootInfo.st_mode & S_IFMT {
        case S_IFLNK:
            return UsageMeasurement(access: .missing)
        case S_IFDIR:
            break
        default:
            let size = dedupedSize(rootInfo, path: path, deduper: deduper)
            onBytes?(size)
            return UsageMeasurement(access: .measured, size: size)
        }

        var openError: Int32 = 0
        guard let listing = listDirectory(atPath: path, device: rootInfo.st_dev, excluding: excluding, deduper: deduper, collectFiles: true, error: &openError) else {
            return UsageMeasurement(access: accessFromErrno(openError))
        }
        var children = listing.files
        var total = listing.fileBytes
        onBytes?(total)

        let rootDevice = rootInfo.st_dev
        var unreadable = 0
        try await withThrowingTaskGroup(of: (UsageChild, Int).self) { group in
            for childPath in listing.subdirectories {
                group.addTask {
                    let (size, childUnreadable) = try await usageOfTreeConcurrently(
                        atPath: childPath, device: rootDevice, excluding: excluding, deduper: deduper,
                        depth: concurrentDepth, onBytes: onBytes
                    )
                    return (UsageChild(name: (childPath as NSString).lastPathComponent, path: childPath, size: size), childUnreadable)
                }
            }
            for try await (child, childUnreadable) in group {
                total += child.size
                unreadable += childUnreadable
                children.append(child)
            }
        }

        return UsageMeasurement(
            access: .measured,
            size: total,
            children: children.sorted { $0.size > $1.size },
            unreadableDirectories: unreadable
        )
    }

    /// 根目录以下再并发展开几层：主目录里常有一个装着上百万文件的项目文件夹，只在第一层并发会被它拖住。
    nonisolated private static let concurrentDepth = 2

    nonisolated private static func usageOfTreeConcurrently(
        atPath path: String,
        device: Int32,
        excluding: Set<String>,
        deduper: UsageDeduper,
        depth: Int,
        onBytes: (@Sendable (Int64) -> Void)?
    ) async throws -> (size: Int64, unreadable: Int) {
        try Task.checkCancellation()
        var openError: Int32 = 0
        guard let listing = listDirectory(atPath: path, device: device, excluding: excluding, deduper: deduper, collectFiles: false, error: &openError) else {
            return (0, 1)
        }
        onBytes?(listing.fileBytes)
        var total = listing.fileBytes
        var unreadable = 0

        if depth > 0 && listing.subdirectories.count > 1 {
            try await withThrowingTaskGroup(of: (Int64, Int).self) { group in
                for subdirectory in listing.subdirectories {
                    group.addTask {
                        try await usageOfTreeConcurrently(
                            atPath: subdirectory, device: device, excluding: excluding, deduper: deduper,
                            depth: depth - 1, onBytes: onBytes
                        )
                    }
                }
                for try await (size, childUnreadable) in group {
                    total += size
                    unreadable += childUnreadable
                }
            }
        } else {
            var progress = WalkProgress(onBytes: onBytes)
            for subdirectory in listing.subdirectories {
                total += try usageOfTree(atPath: subdirectory, device: device, excluding: excluding, deduper: deduper, progress: &progress)
            }
            progress.flush()
            unreadable += progress.unreadable
        }
        return (total, unreadable)
    }

    /// 同步遍历时的进度与取消检查（按条目数节流）。
    nonisolated private struct WalkProgress {
        let onBytes: (@Sendable (Int64) -> Void)?
        var pendingBytes: Int64 = 0
        var entriesSinceCheck = 0
        var unreadable = 0

        mutating func record(entries: Int, bytes: Int64) throws {
            pendingBytes += bytes
            entriesSinceCheck += entries
            if entriesSinceCheck >= 4096 {
                entriesSinceCheck = 0
                try Task.checkCancellation()
                flush()
            }
        }

        mutating func flush() {
            if pendingBytes > 0 {
                onBytes?(pendingBytes)
                pendingBytes = 0
            }
        }
    }

    nonisolated private static func usageOfTree(
        atPath path: String,
        device: Int32,
        excluding: Set<String>,
        deduper: UsageDeduper,
        progress: inout WalkProgress
    ) throws -> Int64 {
        var openError: Int32 = 0
        guard let listing = listDirectory(atPath: path, device: device, excluding: excluding, deduper: deduper, collectFiles: false, error: &openError) else {
            progress.unreadable += 1
            return 0
        }
        try progress.record(entries: listing.entries, bytes: listing.fileBytes)
        var total = listing.fileBytes
        for subdirectory in listing.subdirectories {
            total += try usageOfTree(atPath: subdirectory, device: device, excluding: excluding, deduper: deduper, progress: &progress)
        }
        return total
    }

    /// 一个目录的直接内容：文件占用合计（已去重）、文件明细（可选）与子目录。
    nonisolated private struct DirectoryListing {
        var fileBytes: Int64 = 0
        var files: [UsageChild] = []
        var subdirectories: [String] = []
        var entries = 0
    }

    /// 用 getattrlistbulk 一次读回一批条目的名称、类型、inode、链接数与分配大小，
    /// 比 readdir + 每个文件一次 lstat 少得多的系统调用（主目录里常有上千万个文件）。
    /// 无法打开时返回 nil 并给出 errno；目录属于另一个卷（挂载点）时返回空内容。
    nonisolated private static func listDirectory(
        atPath path: String,
        device: Int32,
        excluding: Set<String>,
        deduper: UsageDeduper,
        collectFiles: Bool,
        error: inout Int32
    ) -> DirectoryListing? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            error = errno
            return nil
        }
        defer { close(fd) }

        var listing = DirectoryListing()
        var info = stat()
        guard fstat(fd, &info) == 0 else { return listing }
        // 挂载点（模拟器运行时、磁盘映像）属于另一个卷，不计入
        guard info.st_dev == device else { return listing }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FILEID)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)

        let bufferSize = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count <= 0 { break }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { continue }
                let nameReference = field.loadUnaligned(as: attrreference_t.self)
                let name = String(cString: (field + Int(nameReference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                field += MemoryLayout<attrreference_t>.size

                var type: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    type = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var fileID: UInt64 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
                    fileID = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }

                listing.entries += 1
                let childPath = joinPath(path, name)
                if !excluding.isEmpty && excluding.contains(childPath) { continue }

                if type == UInt32(VDIR.rawValue) {
                    listing.subdirectories.append(childPath)
                } else if type == UInt32(VREG.rawValue) {
                    var linkCount: UInt32 = 1
                    if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
                        linkCount = field.loadUnaligned(as: UInt32.self)
                        field += 4
                    }
                    var allocated: Int64 = 0
                    if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                        allocated = field.loadUnaligned(as: Int64.self)
                        field += 8
                    }
                    let size = dedupedSize(allocated: allocated, linkCount: linkCount, device: info.st_dev, inode: fileID, path: childPath, deduper: deduper)
                    listing.fileBytes += size
                    if collectFiles {
                        listing.files.append(UsageChild(name: name, path: childPath, size: size))
                    }
                }
                // 符号链接不跟随；设备文件、套接字等不占数据块
            }
        }
        return listing
    }

    nonisolated private static func accessFromErrno(_ code: Int32) -> UsageAccess {
        code == EACCES ? .deniedByOwner : .deniedByPrivacy
    }

    /// 实际分配的块；已移出到云端（dataless）的文件为 0。
    nonisolated private static func onDiskSize(_ info: stat) -> Int64 {
        Int64(info.st_blocks) * 512
    }

    /// 克隆检测只对 ≥ 1 MB 的文件做（多一次 getattrlist），小文件的共享块可以忽略不计。
    nonisolated private static let cloneCheckThreshold: Int64 = 1 << 20

    nonisolated private static func dedupedSize(_ info: stat, path: String, deduper: UsageDeduper) -> Int64 {
        dedupedSize(allocated: onDiskSize(info), linkCount: UInt32(info.st_nlink), device: info.st_dev, inode: info.st_ino, path: path, deduper: deduper)
    }

    nonisolated private static func dedupedSize(
        allocated: Int64, linkCount: UInt32, device: Int32, inode: UInt64, path: String, deduper: UsageDeduper
    ) -> Int64 {
        if linkCount > 1, !deduper.claimInode(dev: device, ino: inode) {
            return 0
        }
        guard allocated >= cloneCheckThreshold, let clone = cloneInfo(atPath: path) else { return allocated }
        let privateSize = min(max(clone.privateSize, 0), allocated)
        let shared = allocated - privateSize
        return privateSize + (deduper.claimCloneFamily(clone.cloneID) ? shared : 0)
    }

    /// APFS 克隆信息：可能与其他文件共享块时返回克隆族 ID 与私有块大小，否则 nil。
    nonisolated static func cloneInfo(atPath path: String) -> (cloneID: UInt64, privateSize: Int64)? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS)
        var buffer = [UInt8](repeating: 0, count: 96)
        let result = getattrlist(path, &request, &buffer, buffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        guard result == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> (UInt64, Int64)? in
            let returned = raw.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            let wanted = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS)
            guard returned.forkattr & wanted == wanted else { return nil }
            var offset = 4 + MemoryLayout<attribute_set_t>.size
            let privateSize = raw.loadUnaligned(fromByteOffset: offset, as: Int64.self)
            offset += 8
            let cloneID = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            offset += 8
            let flags = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            guard flags & UInt64(EF_MAY_SHARE_BLOCKS) != 0 else { return nil }
            return (cloneID, privateSize)
        }
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
