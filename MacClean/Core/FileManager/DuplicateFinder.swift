//
//  DuplicateFinder.swift
//  MacClean
//
//  完全相同的文件：按内容（SHA-256）找出字节级重复。「一键体检 → 重复文件」与「重复与相似」页面共用这一份实现。
//
//  流程：第一遍遍历只统计「每个大小出现几次」→ 第二遍只收集大小撞车的路径 → 首尾 64KB 指纹粗筛 → 流式全量 SHA-256。
//  两遍遍历换内存：主目录几十万个文件时，常驻的只有大小直方图和少量候选路径，内存基本持平。
//
//  遍历规则：不跟随符号链接；跳过隐藏项、包内部、依赖目录、主目录下的 Library 与废纸篓；
//  iCloud 云盘（~/Library/Mobile Documents）只有在用户显式添加时才进入，且只读已下载到本机的文件，
//  任何「无数据占位」(dataless) 文件都不读，避免触发下载。
//
//  全部为 nonisolated 静态方法（工程默认 MainActor 隔离），请在 Task.detached 中调用。
//

import Foundation
import CryptoKit

// MARK: - 模型

/// 一组重复中的一份文件。
nonisolated struct DuplicateFile: Identifiable, Hashable, Sendable {
    let path: String
    /// 文件的逻辑大小（字节），组内每份相同
    let size: Int64
    let modified: Date
    let created: Date

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var parentPath: String { (path as NSString).deletingLastPathComponent }
}

/// 内容完全相同的一组文件。`files` 按保留优先级排序，第一个是建议保留的那份。
nonisolated struct DuplicateGroup: Identifiable, Hashable, Sendable {
    let id: String
    let size: Int64
    let files: [DuplicateFile]

    var suggestedKeeper: DuplicateFile { files[0] }
    /// 每组只留一份时可释放的空间：大小 × (份数 − 1)
    var reclaimableSize: Int64 { size * Int64(max(files.count - 1, 0)) }
}

/// 结果页的类型筛选。空集合表示全部类型。
nonisolated enum DuplicateTypeFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case images, videos, audio, documents, archives

    var id: String { rawValue }

    func matches(_ kind: FileKind) -> Bool {
        switch (self, kind) {
        case (.images, .image), (.videos, .video), (.audio, .audio), (.documents, .document),
             (.archives, .archive), (.archives, .diskImage):
            return true
        default:
            return false
        }
    }

    static func matches(path: String, types: Set<DuplicateTypeFilter>) -> Bool {
        guard !types.isEmpty else { return true }
        let kind = FileKind.classify(extension: (path as NSString).pathExtension)
        return types.contains { $0.matches(kind) }
    }
}

nonisolated struct DuplicateScanOptions: Sendable {
    /// 小于此大小的文件不参与比对；0 字节文件始终跳过（删了也不释放空间）
    var minSize: Int64 = 1
    var types: Set<DuplicateTypeFilter> = []
    /// 用来确定 Library / 废纸篓 / iCloud 云盘这些默认跳过的位置
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    /// 保留优先级：越靠前越像原件的存放位置；不在其中的排在最后
    var preferredLocations: [URL] = []
}

nonisolated struct DuplicateScanProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        /// 第一遍：清点文件大小
        case counting
        /// 第二遍：收集大小相同的候选文件
        case gathering
        /// 比对内容
        case comparing
    }

    var phase: Phase = .counting
    var filesChecked = 0
    var bytesHashed: Int64 = 0
    var candidatesDone = 0
    var candidatesTotal = 0
    var currentFolder = ""
}

nonisolated struct DuplicateScanResult: Sendable {
    /// 按可释放空间降序
    var groups: [DuplicateGroup]
    var filesChecked: Int
    var bytesHashed: Int64
    /// 没有读取权限而被跳过的文件夹（最多记录 maxDeniedFolders 个）
    var deniedFolders: [String]
}

// MARK: - 查找

enum DuplicateFinder {

    nonisolated static let maxDeniedFolders = 50
    /// 粗筛指纹的采样大小：首、尾各取这么多字节
    nonisolated static let sampleSize = 64 * 1024
    /// stat.st_flags 中的 SF_DATALESS：iCloud 等文件提供程序的「未下载」占位文件，读取会触发下载
    nonisolated static let datalessFlag: UInt32 = 0x4000_0000

    /// 一键体检用：在给定目录下查找重复文件，每组保留一份（按 `directories` 顺序作为位置优先级），
    /// 其余副本作为可清理项返回。原件不生成条目，因此即使全选也删不光一整组。
    nonisolated static func findDuplicates(in directories: [URL], minSize: Int64 = 1_048_576) async throws -> [CleanableItem] {
        let options = DuplicateScanOptions(minSize: minSize, preferredLocations: directories)
        let result = try scan(roots: directories, options: options)
        return result.groups.flatMap { group in
            let keeper = group.suggestedKeeper
            return group.files.dropFirst().map { file in
                CleanableItem(
                    name: file.name,
                    path: file.path,
                    size: CleanupManager.allocatedSize(atPath: file.path),
                    category: .duplicates,
                    isSelected: true,
                    description: String(localized: "与 \(keeper.name) 重复"),
                    lastModified: file.modified
                )
            }
        }
    }

    /// 在 roots 下查找内容完全相同的文件组。同步执行、可取消（检查当前 Task 的取消状态）。
    /// progress 节流回调（约每 0.1 秒一次），可在任意线程触发。
    nonisolated static func scan(
        roots: [URL],
        options: DuplicateScanOptions,
        progress: (@Sendable (DuplicateScanProgress) -> Void)? = nil
    ) throws -> DuplicateScanResult {
        let rootPaths = normalizedRoots(roots)
        let reporter = ProgressReporter(callback: progress)
        let minSize = max(options.minSize, 1)
        let homePath = canonicalPath(options.home.path) ?? options.home.standardizedFileURL.path
        var denied: [String] = []

        // 1. 第一遍：只统计每个大小出现的次数（到 2 封顶）
        var sizeCounts: [Int64: UInt8] = [:]
        try walk(rootPaths, homePath: homePath, reporter: reporter, denied: &denied) { path, info in
            reporter.state.filesChecked += 1
            guard accepts(path: path, info: info, minSize: minSize, types: options.types) else { return }
            let size = Int64(info.st_size)
            let count = sizeCounts[size] ?? 0
            if count < 2 { sizeCounts[size] = count + 1 }
        }
        sizeCounts = sizeCounts.filter { $0.value >= 2 }

        // 2. 第二遍：只留下大小撞车的文件
        reporter.state.phase = .gathering
        reporter.report(force: true)
        var candidates: [Int64: [Candidate]] = [:]
        if !sizeCounts.isEmpty {
            var ignoredDenied: [String] = []
            try walk(rootPaths, homePath: homePath, reporter: reporter, denied: &ignoredDenied) { path, info in
                let size = Int64(info.st_size)
                guard sizeCounts[size] != nil,
                      accepts(path: path, info: info, minSize: minSize, types: options.types) else { return }
                candidates[size, default: []].append(Candidate(path: path, info: info))
            }
        }
        sizeCounts = [:]

        // 3. 比对内容：大文件优先，粗筛指纹相同的才做全量哈希
        reporter.state.phase = .comparing
        reporter.state.candidatesTotal = candidates.values.reduce(0) { $0 + $1.count }
        reporter.report(force: true)

        let preferred = options.preferredLocations.map { canonicalPath($0.path) ?? $0.standardizedFileURL.path }
        var groups: [DuplicateGroup] = []

        for size in candidates.keys.sorted(by: >) {
            guard let files = candidates.removeValue(forKey: size) else { continue }
            try Task.checkCancellation()

            // 硬链接共享同一份磁盘数据，删掉其中一个不释放空间，按 inode 去重。
            var seenInodes: Set<String> = []
            let distinct = files.filter { seenInodes.insert("\($0.device):\($0.inode)").inserted }
            guard distinct.count >= 2 else {
                reporter.state.candidatesDone += files.count
                continue
            }

            var fingerprintGroups: [String: [Candidate]] = [:]
            for file in distinct {
                try Task.checkCancellation()
                reporter.state.currentFolder = (file.path as NSString).deletingLastPathComponent
                guard let fingerprint = try? partialFingerprint(ofPath: file.path, size: size) else { continue }
                reporter.state.bytesHashed += min(size, Int64(sampleSize * 2))
                fingerprintGroups[fingerprint, default: []].append(file)
                reporter.report()
            }

            var hashGroups: [String: [Candidate]] = [:]
            for (fingerprint, sameFingerprint) in fingerprintGroups where sameFingerprint.count >= 2 {
                // 不超过两倍采样大小的文件，指纹已覆盖全部内容，本身就是全量哈希
                if size <= Int64(sampleSize * 2) {
                    hashGroups[fingerprint] = sameFingerprint
                    continue
                }
                for file in sameFingerprint {
                    try Task.checkCancellation()
                    reporter.state.currentFolder = (file.path as NSString).deletingLastPathComponent
                    guard let hash = try? sha256(ofPath: file.path, reporter: reporter) else { continue }
                    hashGroups[hash, default: []].append(file)
                }
            }
            reporter.state.candidatesDone += files.count
            reporter.report()

            for (hash, same) in hashGroups where same.count >= 2 {
                let ordered = same
                    .map { KeeperCandidate(file: $0.record(size: size), preferredLocations: preferred) }
                    .sorted(by: keeperOrder)
                    .map(\.file)
                groups.append(DuplicateGroup(id: "\(size)-\(hash)", size: size, files: ordered))
            }
        }

        reporter.report(force: true)
        groups.sort {
            $0.reclaimableSize != $1.reclaimableSize ? $0.reclaimableSize > $1.reclaimableSize : $0.id < $1.id
        }
        return DuplicateScanResult(
            groups: groups,
            filesChecked: reporter.state.filesChecked,
            bytesHashed: reporter.state.bytesHashed,
            deniedFolders: denied
        )
    }

    // MARK: - 保留规则

    /// 判断一组重复文件中哪个是「原件」所需的信息。
    nonisolated struct KeeperCandidate {
        let file: DuplicateFile
        /// 所在优先位置的下标，越小越优先；不在任何优先位置下的排最后。
        let locationRank: Int
        /// 文件名带「 (1)」「 copy」「副本」等系统生成的副本后缀。
        let looksLikeCopy: Bool
        /// 创建时间与修改时间中较早的一个，代表这份内容最早出现在磁盘上的时间。
        let earliestDate: Date

        init(file: DuplicateFile, preferredLocations: [String]) {
            self.file = file
            let path = file.path
            locationRank = preferredLocations.firstIndex { root in
                path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            } ?? preferredLocations.count
            looksLikeCopy = DuplicateFinder.looksLikeCopy(((file.name as NSString).deletingPathExtension))
            earliestDate = min(file.created, file.modified)
        }
    }

    /// 原件优先级：位置更规范 → 不带副本后缀 → 更早出现 → 路径更短。
    nonisolated static func keeperOrder(_ lhs: KeeperCandidate, _ rhs: KeeperCandidate) -> Bool {
        if lhs.locationRank != rhs.locationRank { return lhs.locationRank < rhs.locationRank }
        if lhs.looksLikeCopy != rhs.looksLikeCopy { return !lhs.looksLikeCopy }
        if lhs.earliestDate != rhs.earliestDate { return lhs.earliestDate < rhs.earliestDate }
        if lhs.file.path.count != rhs.file.path.count { return lhs.file.path.count < rhs.file.path.count }
        return lhs.file.path < rhs.file.path
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

    // MARK: - 哈希

    /// 首尾各 64KB 的 SHA-256 指纹，用于廉价预筛。不超过 128KB 的文件等于读了全部内容。
    nonisolated static func partialFingerprint(ofPath path: String, size: Int64, sampleSize: Int = sampleSize) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }

        var hasher = SHA256()
        hasher.update(data: try handle.read(upToCount: sampleSize) ?? Data())
        if size > Int64(sampleSize) {
            try handle.seek(toOffset: UInt64(max(size - Int64(sampleSize), Int64(sampleSize))))
            hasher.update(data: try handle.read(upToCount: sampleSize) ?? Data())
        }
        return hex(hasher.finalize())
    }

    /// 流式计算文件的 SHA-256，按 1MB 分块读取，不把整个文件读进内存；每块之间检查取消。
    nonisolated private static func sha256(ofPath path: String, reporter: ProgressReporter) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        while true {
            try Task.checkCancellation()
            let done: Bool = try autoreleasepool {
                let data = try handle.read(upToCount: chunkSize) ?? Data()
                if data.isEmpty { return true }
                hasher.update(data: data)
                reporter.state.bytesHashed += Int64(data.count)
                return false
            }
            if done { break }
            reporter.report()
        }
        return hex(hasher.finalize())
    }

    nonisolated private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 遍历

    nonisolated private struct Candidate {
        let path: String
        let device: Int32
        let inode: UInt64
        let modified: Date
        let created: Date

        init(path: String, info: stat) {
            self.path = path
            device = info.st_dev
            inode = info.st_ino
            modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            created = Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec))
        }

        func record(size: Int64) -> DuplicateFile {
            DuplicateFile(path: path, size: size, modified: modified, created: created)
        }
    }

    /// 是否参与比对：大小、类型、未下载的云端文件。
    nonisolated private static func accepts(path: String, info: stat, minSize: Int64, types: Set<DuplicateTypeFilter>) -> Bool {
        guard Int64(info.st_size) >= minSize else { return false }
        guard info.st_flags & datalessFlag == 0 else { return false }
        guard DuplicateTypeFilter.matches(path: path, types: types) else { return false }
        if path.contains("/Library/Mobile Documents/") {
            // iCloud 云盘：只读已完整下载到本机的版本
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus != .current { return false }
        }
        return true
    }

    /// 规范化扫描根目录：解析符号链接得到真实路径、去掉不存在的、去掉被其他根目录包含的（避免同一文件被数两次）。
    nonisolated static func normalizedRoots(_ roots: [URL]) -> [String] {
        let paths = roots.compactMap { canonicalPath($0.path) }
        var result: [String] = []
        for path in Set(paths).sorted() {
            let covered = result.contains { parent in parent == "/" || path == parent || path.hasPrefix(parent + "/") }
            if !covered { result.append(path) }
        }
        return result
    }

    nonisolated private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 单线程 readdir 深度优先遍历，对每个普通文件调用 visit。不跟随符号链接。
    nonisolated private static func walk(
        _ roots: [String],
        homePath: String,
        reporter: ProgressReporter,
        denied: inout [String],
        visit: (String, stat) throws -> Void
    ) throws {
        for root in roots {
            // 默认跳过的位置；根目录本身在它们里面（用户显式添加）时不跳过
            let skipped = Set([homePath + "/Library", homePath + "/.Trash", homePath + "/Library/Mobile Documents"].filter { excluded in
                !(root == excluded || root.hasPrefix(excluded + "/"))
            })

            var stack = [root]
            while let dirPath = stack.popLast() {
                try Task.checkCancellation()
                reporter.state.currentFolder = dirPath
                reporter.report()

                guard let dir = opendir(dirPath) else {
                    if (errno == EACCES || errno == EPERM), denied.count < maxDeniedFolders { denied.append(dirPath) }
                    continue
                }
                defer { closedir(dir) }

                while let entry = readdir(dir) {
                    let name = withUnsafePointer(to: entry.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                            String(cString: $0)
                        }
                    }
                    if name.hasPrefix(".") { continue }
                    let childPath = dirPath == "/" ? "/\(name)" : "\(dirPath)/\(name)"

                    var entryType = entry.pointee.d_type
                    var info = stat()
                    if entryType == UInt8(DT_UNKNOWN) {
                        guard lstat(childPath, &info) == 0 else { continue }
                        switch info.st_mode & S_IFMT {
                        case S_IFDIR: entryType = UInt8(DT_DIR)
                        case S_IFREG: entryType = UInt8(DT_REG)
                        default: continue
                        }
                    }

                    if entryType == UInt8(DT_DIR) {
                        if skipped.contains(childPath) { continue }
                        if LargeOldFileScanner.skippedDirectoryNames.contains(name) { continue }
                        if isPackage(name: name, path: childPath) { continue }
                        stack.append(childPath)
                    } else if entryType == UInt8(DT_REG) {
                        guard lstat(childPath, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
                        try visit(childPath, info)
                    }
                    // 符号链接及其他类型一律跳过
                }
            }
        }
    }

    /// 包（App、照片图库、Pages 文稿等）在访达中显示为单个文件，内部文件不应单独删除。
    nonisolated private static func isPackage(name: String, path: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if LargeOldFileScanner.bundleExtensions.contains(ext) { return true }
        return (try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    /// 进度状态 + 节流回调。只在扫描线程上读写。
    nonisolated private final class ProgressReporter {
        var state = DuplicateScanProgress()
        private let callback: (@Sendable (DuplicateScanProgress) -> Void)?
        private var lastReport = Date.distantPast

        init(callback: (@Sendable (DuplicateScanProgress) -> Void)?) {
            self.callback = callback
        }

        func report(force: Bool = false) {
            guard let callback else { return }
            let now = Date()
            guard force || now.timeIntervalSince(lastReport) >= 0.1 else { return }
            lastReport = now
            callback(state)
        }
    }
}
