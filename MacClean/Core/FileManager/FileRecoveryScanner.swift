//
//  FileRecoveryScanner.swift
//  MacClean
//
//  找回文件：在来源（快照挂载点 / 时间机器备份）里查找「当前已不存在」或「名称匹配」的项目，
//  以及把选中的项目复制回原位置（绝不覆盖）。全部 nonisolated，由 Task.detached 在后台调用。
//

import Foundation
import os

nonisolated private let recoveryLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MacClean", category: "FileRecovery")

// MARK: - 结果条目

nonisolated struct RecoveryItem: Identifiable, Hashable, Sendable {
    let sourceID: String
    /// 来源里的完整路径（预览 / 在访达中显示 / 复制的源头）。
    let sourcePath: String
    /// 相对主目录的路径，例如 "Desktop/报告.pdf"。
    let relativePath: String
    let isDirectory: Bool
    let isPackage: Bool
    /// 文件为实际占用大小；文件夹为 nil，之后在后台计算。
    let size: Int64?
    let modified: Date?
    /// 原位置当前仍有同名项目（恢复时会另存为「（恢复）」副本）。
    let existsNow: Bool
    /// 其他来源里内容相同（同修改时间、同大小）的副本数，已合并为这一行。
    var duplicateCount = 0

    var id: String { sourceID + "|" + relativePath }
    var name: String { (relativePath as NSString).lastPathComponent }

    func originalURL(home: URL) -> URL {
        home.appendingPathComponent(relativePath)
    }

    /// 合并相同副本时用的键。
    var versionKey: String {
        let time = modified.map { String(Int64($0.timeIntervalSince1970)) } ?? "-"
        return relativePath + "|" + time + "|" + (isDirectory ? "d" : String(size ?? -1))
    }
}

nonisolated struct RecoveryScanOutcome: Sendable {
    var items: [RecoveryItem] = []
    /// 达到单个来源的上限，结果不完整。
    var truncated = false
    /// 读取来源时遇到「没有权限」（通常是缺少完全磁盘访问权限）。
    var permissionDenied = false
    var checked = 0
}

nonisolated enum RecoverySearchMode: String, Sendable {
    /// 来源里有、当前主目录同一位置没有的项目
    case missing
    /// 按名称匹配（不论当前是否存在）
    case name
}

// MARK: - 遍历

nonisolated enum RecoveryScanner {

    static let resultLimit = 5_000

    /// 始终跳过：废纸篓、访达元数据。
    private static let alwaysSkipped: Set<String> = [".Trash", ".DS_Store", ".localized", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems"]

    struct Options: Sendable {
        var mode: RecoverySearchMode = .missing
        var term = ""
        var includeHidden = false
        var limit = RecoveryScanner.resultLimit
        /// 起始文件夹相对主目录的路径（"" 表示整个主目录）。
        var relativeFolder = ""
    }

    /// 在一个来源里查找。
    /// - sourceHome: 来源里与主目录对应的目录；currentHome: 当前主目录。
    /// - isCancelled 返回 true 时尽快结束；progress 回调已检查的条目数（节流）。
    static func scan(
        sourceID: String,
        sourceHome: String,
        currentHome: String,
        options: Options,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) -> RecoveryScanOutcome {
        var outcome = RecoveryScanOutcome()
        let folder = options.relativeFolder
        let sourceStart = folder.isEmpty ? sourceHome : sourceHome + "/" + folder
        let currentStart = folder.isEmpty ? currentHome : currentHome + "/" + folder
        guard RecoveryPaths.isRealDirectory(sourceStart) else {
            // 起始文件夹在来源里不存在（或是符号链接）：在该来源里没有可找回的东西
            if access(sourceStart, F_OK) != 0, errno == EPERM || errno == EACCES { outcome.permissionDenied = true }
            return outcome
        }

        let foldedTerm = fold(options.term.trimmingCharacters(in: .whitespacesAndNewlines))
        var lastReported = 0

        // 显式栈（深度优先），避免深层目录递归爆栈
        var stack: [String] = [folder]
        while let relativeDir = stack.popLast() {
            if isCancelled() || outcome.items.count >= options.limit { break }
            let sourceDir = relativeDir.isEmpty ? sourceHome : sourceHome + "/" + relativeDir
            let currentDir = relativeDir.isEmpty ? currentHome : currentHome + "/" + relativeDir

            guard let entries = readDirectory(sourceDir) else {
                if errno == EPERM || errno == EACCES { outcome.permissionDenied = true }
                continue
            }

            // 缺失模式下，当前目录与来源目录修改时间相同 → 两边条目名单一致，文件无需逐个比对，只需下探子目录
            let sameListing = options.mode == .missing && sameModificationTime(sourceDir, currentDir)
            let currentExists = options.mode == .missing ? RecoveryPaths.isRealDirectory(currentDir) : true

            var subdirectories: [String] = []
            entryLoop: for entry in entries {
                outcome.checked += 1
                if outcome.checked - lastReported >= 500 {
                    lastReported = outcome.checked
                    progress(outcome.checked)
                    if isCancelled() { break entryLoop }
                }

                let name = entry.name
                if alwaysSkipped.contains(name) { continue }
                if !options.includeHidden && name.hasPrefix(".") { continue }
                let relative = relativeDir.isEmpty ? name : relativeDir + "/" + name
                // 主目录顶层的 Library 体量巨大、多为应用数据，默认不进
                if relative == "Library" { continue }

                let isDirectory = entry.type == DT_DIR
                let isPackage = isDirectory && name.contains(".") && isPackageDirectory(sourceDir + "/" + name)

                switch options.mode {
                case .missing:
                    if sameListing {
                        if isDirectory && !isPackage { subdirectories.append(relative) }
                        continue
                    }
                    let currentPath = currentDir + "/" + name
                    var currentInfo = stat()
                    let exists = currentExists && lstat(currentPath, &currentInfo) == 0
                    if !exists {
                        // 整个文件夹都不在了：只列文件夹本身
                        if let item = makeItem(sourceID: sourceID, sourcePath: sourceDir + "/" + name, relativePath: relative, isDirectory: isDirectory, isPackage: isPackage, existsNow: false) {
                            outcome.items.append(item)
                            if outcome.items.count >= options.limit { outcome.truncated = true; break entryLoop }
                        }
                    } else if isDirectory && !isPackage && (currentInfo.st_mode & S_IFMT) == S_IFDIR {
                        subdirectories.append(relative)
                    }

                case .name:
                    if matches(name: name, foldedTerm: foldedTerm) {
                        var currentInfo = stat()
                        let exists = lstat(currentHome + "/" + relative, &currentInfo) == 0
                        if let item = makeItem(sourceID: sourceID, sourcePath: sourceDir + "/" + name, relativePath: relative, isDirectory: isDirectory, isPackage: isPackage, existsNow: exists) {
                            outcome.items.append(item)
                            if outcome.items.count >= options.limit { outcome.truncated = true; break entryLoop }
                        }
                    }
                    if isDirectory && !isPackage { subdirectories.append(relative) }
                }
            }
            // 倒序压栈，保持大致按字母顺序遍历
            stack.append(contentsOf: subdirectories.reversed())
        }
        if outcome.items.count >= options.limit { outcome.truncated = true }
        progress(outcome.checked)
        return outcome
    }

    // MARK: 名称匹配

    /// 大小写、变音符号不敏感；支持 * ? 通配（整名匹配，与「文件搜索」一致）。
    static func matches(name: String, foldedTerm: String) -> Bool {
        guard !foldedTerm.isEmpty else { return true }
        return NameMatcher.matches(fold(name), term: foldedTerm)
    }

    static func fold(_ string: String) -> String {
        string.allSatisfy(\.isASCII)
            ? string.lowercased()
            : string.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: 文件夹大小

    /// 文件夹实际占用大小（不跟随符号链接）。
    static func directorySize(_ path: String, isCancelled: @escaping @Sendable () -> Bool = { false }) -> Int64 {
        var total: Int64 = 0
        var stack = [path]
        var counter = 0
        while let dir = stack.popLast() {
            guard let entries = readDirectory(dir) else { continue }
            for entry in entries {
                counter += 1
                if counter % 2_000 == 0, isCancelled() { return total }
                let child = dir + "/" + entry.name
                var info = stat()
                guard lstat(child, &info) == 0 else { continue }
                if (info.st_mode & S_IFMT) == S_IFDIR {
                    stack.append(child)
                } else {
                    total += Int64(info.st_blocks) * 512
                }
            }
        }
        return total
    }

    // MARK: 底层

    struct DirectoryEntry {
        let name: String
        let type: Int32
    }

    /// readdir 读取一层目录（带 d_type，免去逐个 stat）。失败时返回 nil，errno 保留。
    static func readDirectory(_ path: String) -> [DirectoryEntry]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        var entries: [DirectoryEntry] = []
        while let pointer = readdir(dir) {
            let name = withUnsafeMutablePointer(to: &pointer.pointee.d_name) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var type = Int32(pointer.pointee.d_type)
            if type == DT_UNKNOWN {
                var info = stat()
                if lstat(path + "/" + name, &info) == 0 {
                    type = (info.st_mode & S_IFMT) == S_IFDIR ? DT_DIR : ((info.st_mode & S_IFMT) == S_IFLNK ? DT_LNK : DT_REG)
                }
            }
            entries.append(DirectoryEntry(name: name, type: type))
        }
        return entries
    }

    private static func sameModificationTime(_ a: String, _ b: String) -> Bool {
        var infoA = stat(), infoB = stat()
        guard lstat(a, &infoA) == 0, lstat(b, &infoB) == 0 else { return false }
        return infoA.st_mtimespec.tv_sec == infoB.st_mtimespec.tv_sec
            && infoA.st_mtimespec.tv_nsec == infoB.st_mtimespec.tv_nsec
    }

    private static func isPackageDirectory(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
    }

    private static func makeItem(sourceID: String, sourcePath: String, relativePath: String, isDirectory: Bool, isPackage: Bool, existsNow: Bool) -> RecoveryItem? {
        var info = stat()
        guard lstat(sourcePath, &info) == 0 else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        return RecoveryItem(
            sourceID: sourceID,
            sourcePath: sourcePath,
            relativePath: relativePath,
            isDirectory: isDirectory,
            isPackage: isPackage,
            size: isDirectory ? nil : Int64(info.st_blocks) * 512,
            modified: modified,
            existsNow: existsNow
        )
    }

    /// 多个来源按从新到旧依次给出结果，合并内容相同的副本（保留最新来源那一行）。
    static func mergeDuplicates(_ itemsBySource: [[RecoveryItem]]) -> [RecoveryItem] {
        var merged: [RecoveryItem] = []
        var indexByKey: [String: Int] = [:]
        for items in itemsBySource {
            for item in items {
                if let index = indexByKey[item.versionKey] {
                    merged[index].duplicateCount += 1
                } else {
                    indexByKey[item.versionKey] = merged.count
                    merged.append(item)
                }
            }
        }
        return merged
    }
}

// MARK: - 恢复（复制回原位置）

nonisolated struct RecoveryRestoreReport: Sendable {
    struct Restored: Sendable, Hashable {
        let item: RecoveryItem
        let destination: String
    }
    struct Failure: Sendable, Hashable {
        let item: RecoveryItem
        let reason: String
    }

    var restored: [Restored] = []
    var failed: [Failure] = []
}

nonisolated enum RecoveryRestorer {

    /// 恢复副本的文件名：attempt 1 →「名（恢复）.扩展名」，2 起 →「名（恢复 2）.扩展名」。
    /// 点开头且无其他点的文件（.zshrc）、无扩展名的文件，后缀加在末尾；splitExtension 为 false 时（普通文件夹）也加在末尾。
    static func restoredName(for name: String, attempt: Int, splitExtension: Bool = true) -> String {
        let suffix = attempt <= 1 ? String(localized: "（恢复）") : String(localized: "（恢复 \(attempt)）")
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        guard splitExtension, !ext.isEmpty, !base.isEmpty, base != "." else { return name + suffix }
        return base + suffix + "." + ext
    }

    /// 第一个不存在的目标路径：原路径空着就用原路径，否则依次尝试「（恢复）」「（恢复 2）」…
    static func availableDestination(for original: URL, splitExtension: Bool = true, exists: (String) -> Bool = { path in
        var info = stat()
        return lstat(path, &info) == 0
    }) -> URL? {
        if !exists(original.path) { return original }
        let parent = original.deletingLastPathComponent()
        for attempt in 1...999 {
            let candidate = parent.appendingPathComponent(restoredName(for: original.lastPathComponent, attempt: attempt, splitExtension: splitExtension))
            if !exists(candidate.path) { return candidate }
        }
        return nil
    }

    /// 同一来源里，已选中其上级文件夹的项目不再单独复制（上级会一并恢复）。
    static func removingNested(_ items: [RecoveryItem]) -> [RecoveryItem] {
        let directories = Set(items.filter(\.isDirectory).map { $0.sourceID + "|" + $0.relativePath })
        return items.filter { item in
            var parent = (item.relativePath as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if directories.contains(item.sourceID + "|" + parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }
    }

    /// 把条目复制回 home 下的原位置。copyItem 走 copyfile，保留修改日期等元数据；再显式写一次修改日期兜底。
    static func restore(_ items: [RecoveryItem], home: URL, progress: @escaping @Sendable (Int) -> Void = { _ in }) -> RecoveryRestoreReport {
        let fileManager = FileManager.default
        var report = RecoveryRestoreReport()
        for (index, item) in removingNested(items).enumerated() {
            defer { progress(index + 1) }
            let source = URL(fileURLWithPath: item.sourcePath)
            let original = item.originalURL(home: home)
            // 防御：相对路径不得跳出主目录
            guard original.standardizedFileURL.path.hasPrefix(home.standardizedFileURL.path + "/") else {
                report.failed.append(.init(item: item, reason: String(localized: "目标位置不在主目录内")))
                continue
            }
            do {
                try fileManager.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                let splitExtension = !item.isDirectory || item.isPackage
                var copied: URL?
                // 检查与复制之间目标可能被占用：copyItem 不会覆盖，失败就换下一个名字再试
                for _ in 0..<5 {
                    guard let destination = availableDestination(for: original, splitExtension: splitExtension) else { break }
                    do {
                        try fileManager.copyItem(at: source, to: destination)
                        copied = destination
                        break
                    } catch CocoaError.fileWriteFileExists {
                        continue
                    }
                }
                guard let destination = copied else {
                    report.failed.append(.init(item: item, reason: String(localized: "同名文件过多，无法找到可用的文件名")))
                    continue
                }
                if let modified = item.modified {
                    try? fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
                }
                recoveryLog.info("Restored \(item.relativePath, privacy: .private) to \(destination.path, privacy: .private)")
                report.restored.append(.init(item: item, destination: destination.path))
            } catch {
                recoveryLog.error("Restore failed for \(item.relativePath, privacy: .private): \(error.localizedDescription, privacy: .public)")
                report.failed.append(.init(item: item, reason: error.localizedDescription))
            }
        }
        return report
    }
}

// MARK: - 执行命令（后台调用）

nonisolated struct RecoveryDiscovery: Sendable {
    var sources: [RecoverySource] = []
    var needsFullDiskAccess = false
    var timeMachineConfigured = false
    var dataDeviceNode: String?
    /// 已挂载（包括上次运行留下的）的快照：名 → 挂载点
    var mountedSnapshots: [String: String] = [:]
}

nonisolated enum RecoveryAdminOutcome: Sendable {
    /// 各项命令结果：id 顺序与输入一致，nil 表示成功，否则为错误信息。
    case finished([String?])
    case cancelled
    case failure(String)
}

nonisolated enum RecoveryRunner {

    static func discover() -> RecoveryDiscovery {
        var discovery = RecoveryDiscovery()

        // 1. 本地快照：数据卷优先，兼容只认「/」的旧系统
        var names = RecoveryParsing.parseLocalSnapshots(MaintenanceRunner.runProcess("/usr/bin/tmutil", ["listlocalsnapshots", "/System/Volumes/Data"]).stdout)
        if names.isEmpty {
            names = RecoveryParsing.parseLocalSnapshots(MaintenanceRunner.runProcess("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).stdout)
        }
        let snapshots = names.map { RecoverySource(kind: .localSnapshot, name: $0, date: RecoveryParsing.parseDate(in: $0)) }

        // 2. 时间机器备份
        let destinations = MaintenanceRunner.runProcess("/usr/bin/tmutil", ["destinationinfo"])
        discovery.timeMachineConfigured = RecoveryParsing.hasTimeMachineDestination(destinations.stdout + destinations.stderr)
        let backupsOutput = MaintenanceRunner.runProcess("/usr/bin/tmutil", ["listbackups"])
        let listing = RecoveryParsing.parseBackupList(stdout: backupsOutput.stdout, stderr: backupsOutput.stderr)
        // 没配置备份磁盘时，「Operation not permitted」与权限无关
        discovery.needsFullDiskAccess = listing.needsFullDiskAccess && discovery.timeMachineConfigured
        let backups = listing.paths.map {
            RecoverySource(kind: .timeMachine, name: $0, date: RecoveryParsing.parseDate(in: ($0 as NSString).lastPathComponent))
        }

        discovery.sources = (snapshots + backups).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        discovery.mountedSnapshots = currentMounts()

        // 3. 数据卷设备节点（挂载快照用，无需管理员）
        let info = MaintenanceRunner.runProcess("/usr/sbin/diskutil", ["info", "-plist", "/System/Volumes/Data"])
        discovery.dataDeviceNode = RecoveryParsing.parseDeviceNode(plist: Data(info.stdout.utf8))
        return discovery
    }

    static func currentMounts() -> [String: String] {
        RecoveryParsing.parseRecoveryMounts(MaintenanceRunner.runProcess("/sbin/mount", []).stdout)
    }

    /// 一次管理员授权执行一组命令。
    static func runAdmin(_ commands: [(id: String, command: String)]) -> RecoveryAdminOutcome {
        guard !commands.isEmpty else { return .finished([]) }
        let result = MaintenanceRunner.runProcess("/usr/bin/osascript", ["-e", RecoveryAdminScript.appleScript(for: commands)])
        if result.status != 0 {
            if MaintenanceCommands.isUserCancelled(result.stderr) { return .cancelled }
            recoveryLog.error("Admin script failed: \(result.stderr, privacy: .public)")
            return .failure(MaintenanceRunner.cleanedMessage(result.stderr, fallback: String(localized: "授权失败")))
        }
        let parsed = MaintenanceCommands.parseBatchOutput(result.stdout)
        return .finished(commands.map { command in
            guard let entry = parsed[command.id] else { return String(localized: "没有返回结果") }
            return entry.status == 0 ? nil : MaintenanceRunner.cleanedMessage(entry.output, fallback: String(localized: "退出码 \(entry.status)"))
        })
    }
}
