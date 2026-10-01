//
//  CleanupManager.swift
//  MacClean
//
//  清理管理器
//

import Foundation

actor CleanupManager {
    static let shared = CleanupManager()

    private let history: CleanupHistoryStore

    init(history: CleanupHistoryStore = .shared) {
        self.history = history
    }

    typealias ProgressCallback = @Sendable (Double) -> Void

    /// 本次 clean 调用中移入废纸篓的条目，结束时写入清理记录。
    private var trashedEntries: [CleanupHistoryEntry] = []

    // MARK: - 清理操作

    func clean(items: [CleanableItem], progress: ProgressCallback? = nil) async throws -> CleanResult {
        let startTime = Date()
        var freedSpace: Int64 = 0
        var permanentlyFreed: Int64 = 0
        var cleanedItems = 0
        var errors: [CleanError] = []
        trashedEntries = []

        let totalItems = items.count

        for (index, item) in items.enumerated() {
            defer { progress?(Double(index + 1) / Double(totalItems)) }

            // 删除前先做路径安全校验，命中黑名单/超出允许范围/层级过浅/符号链接逃逸的项直接跳过
            do {
                try PathGuard.validate(path: item.path, category: item.category, removesContainer: item.removesContainer)
            } catch {
                errors.append(CleanError(path: item.path, error: error, message: error.localizedDescription))
                continue
            }

            do {
                let (freedSize, itemErrors) = try cleanItem(item)
                if item.category.isRecoverable {
                    freedSpace += freedSize
                } else {
                    permanentlyFreed += freedSize
                }
                errors.append(contentsOf: itemErrors)
                // 目录内容清理时只要不是全部子项都失败，就算成功清理了这一项
                if itemErrors.isEmpty || freedSize > 0 {
                    cleanedItems += 1
                }
            } catch {
                errors.append(CleanError(path: item.path, error: error, message: error.localizedDescription))
            }
        }

        let sessionID = history.record(entries: trashedEntries)
        trashedEntries = []
        NotificationCenter.default.post(name: .macCleanDiskUsageChanged, object: nil)

        return CleanResult(
            freedSpace: freedSpace,
            cleanedItems: cleanedItems,
            duration: Date().timeIntervalSince(startTime),
            errors: errors,
            historySessionID: sessionID,
            permanentlyFreed: permanentlyFreed
        )
    }

    /// 恢复某次清理（把仍在废纸篓里的项目放回原处）。
    func restore(sessionID: UUID) -> RestoreResult {
        let result = history.restore(sessionID: sessionID)
        NotificationCenter.default.post(name: .macCleanDiskUsageChanged, object: nil)
        return result
    }

    // MARK: - 清理单个项目

    private func cleanItem(_ item: CleanableItem) throws -> (freed: Int64, errors: [CleanError]) {
        let path = item.path

        guard FileManager.default.fileExists(atPath: path) else {
            throw CleanupError.pathNotFound(path)
        }

        if item.removesContainer {
            return (try trashItem(atPath: path), [])
        }

        switch item.category {
        case .userCache, .browserCache, .developerTools, .mailAttachments, .appData:
            // 删除目录内容，保留目录本身；每个子项单独移入废纸篓
            return try cleanDirectoryContents(at: path)

        case .systemLogs:
            // 只删除旧日志文件，移入废纸篓
            return (try cleanOldFiles(at: path, olderThanDays: 7), [])

        case .trash:
            // 唯一的永久删除路径：清空废纸篓
            return try emptyDirectoryPermanently(at: path)

        case .largeFiles, .oldFiles, .duplicates, .brokenLoginItems,
             .installers, .iosBackups, .iosUpdates, .projectArtifacts, .similarPhotos,
             .applications, .appLeftovers, .privacyData, .spaceLens:
            // 整个文件/目录移入废纸篓
            return (try trashItem(atPath: path), [])
        }
    }

    // MARK: - 清理目录内容

    private func cleanDirectoryContents(at path: String) throws -> (freed: Int64, errors: [CleanError]) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            throw CleanupError.cannotReadDirectory(path)
        }

        var freed: Int64 = 0
        var errors: [CleanError] = []

        for item in contents {
            let itemPath = path + "/" + item
            do {
                freed += try trashItem(atPath: itemPath)
            } catch {
                // 记录错误但继续清理其他文件
                errors.append(CleanError(path: itemPath, error: error, message: error.localizedDescription))
            }
        }

        return (freed, errors)
    }

    // MARK: - 永久清空（仅废纸篓）

    private func emptyDirectoryPermanently(at path: String) throws -> (freed: Int64, errors: [CleanError]) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            throw CleanupError.cannotReadDirectory(path)
        }

        var freed: Int64 = 0
        var errors: [CleanError] = []
        for item in contents where item != ".DS_Store" {
            let itemPath = path + "/" + item
            let size = Self.allocatedSize(atPath: itemPath)
            do {
                try FileManager.default.removeItem(atPath: itemPath)
                freed += size
            } catch {
                errors.append(CleanError(path: itemPath, error: error, message: error.localizedDescription))
            }
        }
        return (freed, errors)
    }

    // MARK: - 清理旧文件

    private func cleanOldFiles(at path: String, olderThanDays days: Int) throws -> Int64 {
        let fileManager = FileManager.default
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!

        guard let enumerator = fileManager.enumerator(atPath: path) else {
            throw CleanupError.cannotReadDirectory(path)
        }

        var freed: Int64 = 0

        while let file = enumerator.nextObject() as? String {
            let filePath = path + "/" + file

            // 只对文件做 trash，目录本身跳过，避免父目录先被移走导致子文件 trash 失败
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: filePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }

            if let attributes = try? fileManager.attributesOfItem(atPath: filePath),
               let modificationDate = attributes[.modificationDate] as? Date,
               modificationDate < cutoffDate {
                freed += (try? trashItem(atPath: filePath)) ?? 0
            }
        }

        return freed
    }

    // MARK: - 移入废纸篓

    /// 计算路径实际占用大小后，将其移入废纸篓（而非直接删除），保证清理操作可恢复；
    /// 同时记下废纸篓中的新位置，供「清理记录」一键恢复。
    private func trashItem(atPath path: String) throws -> Int64 {
        let size = Self.allocatedSize(atPath: path)
        let url = URL(fileURLWithPath: path)
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        if let trashed = resultingURL as URL? {
            trashedEntries.append(CleanupHistoryEntry(originalPath: path, trashedPath: trashed.path, size: size))
        }
        return size
    }

    // MARK: - 计算实际占用大小

    /// 与 DiskAnalyzer 中的实现保持一致：使用 lstat 的 st_blocks * 512 作为实际磁盘占用，
    /// 比 totalFileAllocatedSizeKey 更准确；目录需要递归求和。
    nonisolated static func allocatedSize(atPath path: String) -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }

        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        let isSymlink = (info.st_mode & S_IFMT) == S_IFLNK

        let ownSize: Int64 = {
            let allocated = Int64(info.st_blocks) * 512
            return allocated > 0 ? allocated : Int64(info.st_size)
        }()

        guard isDirectory, !isSymlink else { return ownSize }

        // fts 直接复用遍历时拿到的 stat，比 FileManager.enumerator + 逐个 lstat 快数倍，
        // node_modules 这类百万级小文件目录差异尤其明显。
        guard let pathCopy = strdup(path) else { return ownSize }
        defer { free(pathCopy) }
        var paths: [UnsafeMutablePointer<CChar>?] = [pathCopy, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return ownSize }
        defer { fts_close(fts) }

        var total: Int64 = 0
        while let entry = fts_read(fts) {
            switch Int32(entry.pointee.fts_info) {
            case FTS_DP, FTS_DNR, FTS_ERR, FTS_NS, FTS_NSOK:
                // 目录后序访问（前序已计入）或无法读取/无 stat 信息的条目
                continue
            default:
                guard let st = entry.pointee.fts_statp else { continue }
                let allocated = Int64(st.pointee.st_blocks) * 512
                total += allocated > 0 ? allocated : Int64(st.pointee.st_size)
            }
        }

        return total
    }

    // MARK: - 预估清理大小

    func estimateCleanupSize(for items: [CleanableItem]) -> Int64 {
        items.filter { $0.isSelected }.reduce(0) { $0 + $1.size }
    }
}

extension Notification.Name {
    /// 清理或恢复后磁盘占用发生变化，侧边栏等处据此刷新磁盘概览。
    static let macCleanDiskUsageChanged = Notification.Name("MacCleanDiskUsageChanged")
}

// MARK: - 清理错误类型

enum CleanupError: LocalizedError {
    case pathNotFound(String)
    case cannotReadDirectory(String)
    case permissionDenied(String)
    case unknown(Error)
    
    var errorDescription: String? {
        switch self {
        case .pathNotFound(let path):
            return String(localized: "路径不存在：\(path)")
        case .cannotReadDirectory(let path):
            return String(localized: "无法读取文件夹：\(path)")
        case .permissionDenied(let path):
            return String(localized: "没有权限：\(path)")
        case .unknown(let error):
            return error.localizedDescription
        }
    }
}
