//
//  LargeOldFileScanner.swift
//  MacClean
//
//  大型与陈旧文件：一次遍历收集所有超过下限的文件及其大小、修改时间、最后打开时间、类型，
//  之后的尺寸/闲置时长/类型筛选全部在内存中完成，切换筛选无需重扫。
//  全部为 nonisolated 静态方法，可在后台线程调用（工程默认 MainActor 隔离）。
//

import Foundation
import CoreServices

// MARK: - 文件类型

enum FileKind: String, CaseIterable, Identifiable, Sendable {
    case video, diskImage, archive, image, audio, document, other

    nonisolated var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return String(localized: "视频")
        case .diskImage: return String(localized: "磁盘映像与安装包")
        case .archive: return String(localized: "压缩包")
        case .image: return String(localized: "图片")
        case .audio: return String(localized: "音频")
        case .document: return String(localized: "文档")
        case .other: return String(localized: "其他")
        }
    }

    var icon: String {
        switch self {
        case .video: return "film"
        case .diskImage: return "externaldrive"
        case .archive: return "doc.zipper"
        case .image: return "photo"
        case .audio: return "waveform"
        case .document: return "doc.richtext"
        case .other: return "doc"
        }
    }

    nonisolated static func classify(extension ext: String) -> FileKind {
        switch ext.lowercased() {
        case "mp4", "mov", "m4v", "mkv", "avi", "wmv", "flv", "webm", "mpg", "mpeg", "ts", "mts", "m2ts", "prores":
            return .video
        case "dmg", "iso", "img", "pkg", "mpkg", "xip", "ipsw", "vmdk", "qcow2", "vdi", "vhd", "vhdx", "sparseimage", "sparsebundle":
            return .diskImage
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz4", "cab", "jar", "apk", "aab", "ipa":
            return .archive
        case "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "raw", "cr2", "cr3", "nef", "arw", "dng", "raf", "psd", "psb", "gif", "webp", "exr":
            return .image
        case "mp3", "m4a", "aac", "wav", "flac", "aif", "aiff", "ogg", "caf", "alac":
            return .audio
        case "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "key", "pages", "numbers", "epub", "csv", "sketch", "fig", "ai", "indd":
            return .document
        default:
            return .other
        }
    }
}

// MARK: - 记录

struct LargeFileRecord: Identifiable, Hashable, Sendable {
    let path: String
    let size: Int64
    let modified: Date
    /// Spotlight 记录的「上次打开时间」；没有记录时为 nil。
    let lastOpened: Date?
    let kind: FileKind

    nonisolated var id: String { path }
    nonisolated var name: String { (path as NSString).lastPathComponent }

    /// 最近一次「被用到」的时间：打开与修改取较新者。
    nonisolated var lastUsed: Date {
        guard let lastOpened else { return modified }
        return max(lastOpened, modified)
    }
}

// MARK: - 扫描

enum LargeOldFileScanner {

    /// 依赖目录几乎不含单个大文件，却极大拖慢遍历，直接跳过。
    nonisolated static let skippedDirectoryNames: Set<String> = ["node_modules", "Pods", "venv", "site-packages", "__pycache__"]

    /// 视为「包」的目录扩展名，不深入内部（App、虚拟机、照片库等，内部文件不应单独删除）。
    nonisolated static let bundleExtensions: Set<String> = [
        "app", "bundle", "framework", "appex", "xcarchive",
        "pvm", "pvs", "vmwarevm", "photoslibrary", "musiclibrary", "tvlibrary", "docset",
        "fcpbundle", "logicx", "imovielibrary", "sparsebundle",
    ]

    /// 在 root 下找出所有 ≥ minSize 的普通文件，跳过 ~/Library、隐藏项、依赖目录与包。
    /// 多线程并行遍历（共享目录队列，每核一个工作线程），readdir + d_type 避免逐条 stat；
    /// progress 按条目数节流回调；任务取消时尽快停止。
    nonisolated static func scan(
        under root: URL,
        minSize: Int64 = 50 * 1024 * 1024,
        resolveLastOpened: Bool = true,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [LargeFileRecord] {
        let rootPath = root.standardizedFileURL.path
        let walk = ParallelWalk(rootPath: rootPath, progress: progress)

        let found: [(path: String, info: stat)] = await withTaskCancellationHandler {
            walk.run(minSize: minSize, libraryPath: rootPath + "/Library")
        } onCancel: {
            walk.cancel()
        }
        try Task.checkCancellation()

        let records = found.map { entry in
            let allocated = Int64(entry.info.st_blocks) * 512
            let name = (entry.path as NSString).lastPathComponent
            return LargeFileRecord(
                path: entry.path,
                size: allocated > 0 ? allocated : Int64(entry.info.st_size),
                modified: Date(timeIntervalSince1970: TimeInterval(entry.info.st_mtimespec.tv_sec)),
                lastOpened: resolveLastOpened ? lastOpenedDate(path: entry.path) : nil,
                kind: FileKind.classify(extension: (name as NSString).pathExtension)
            )
        }
        return records.sorted { $0.size > $1.size }
    }

    /// 共享目录队列的并行遍历器。所有可变状态由 condition 保护。
    private final class ParallelWalk: @unchecked Sendable {
        private let condition = NSCondition()
        private var pending: [String]
        private var busyWorkers = 0
        private var cancelled = false
        private var scannedCount = 0
        private var results: [(path: String, info: stat)] = []
        private let progress: (@Sendable (Int) -> Void)?

        nonisolated init(rootPath: String, progress: (@Sendable (Int) -> Void)?) {
            self.pending = [rootPath]
            self.progress = progress
        }

        nonisolated func cancel() {
            condition.lock()
            cancelled = true
            condition.broadcast()
            condition.unlock()
        }

        nonisolated func run(minSize: Int64, libraryPath: String) -> [(path: String, info: stat)] {
            let workers = max(2, ProcessInfo.processInfo.activeProcessorCount)
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                worker(minSize: minSize, libraryPath: libraryPath)
            }
            condition.lock()
            defer { condition.unlock() }
            progress?(scannedCount)
            return cancelled ? [] : results
        }

        /// 取下一个目录；队列空且没有其他线程在工作时返回 nil（遍历结束）。
        nonisolated private func next() -> String? {
            condition.lock()
            defer { condition.unlock() }
            while true {
                if cancelled { return nil }
                if let dir = pending.popLast() {
                    busyWorkers += 1
                    return dir
                }
                if busyWorkers == 0 {
                    condition.broadcast()
                    return nil
                }
                condition.wait()
            }
        }

        nonisolated private func finish(subdirectories: [String], files: [(path: String, info: stat)], scanned: Int) {
            condition.lock()
            pending.append(contentsOf: subdirectories)
            results.append(contentsOf: files)
            busyWorkers -= 1
            let before = scannedCount
            scannedCount += scanned
            let report = scannedCount / 10_000 != before / 10_000 ? scannedCount : nil
            condition.broadcast()
            condition.unlock()
            if let report { progress?(report) }
        }

        nonisolated private func worker(minSize: Int64, libraryPath: String) {
            while let dirPath = next() {
                var subdirectories: [String] = []
                var files: [(path: String, info: stat)] = []
                var scanned = 0

                if let dir = opendir(dirPath) {
                    while let entry = readdir(dir) {
                        let name = withUnsafePointer(to: entry.pointee.d_name) {
                            $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                                String(cString: $0)
                            }
                        }
                        if name == "." || name == ".." || name.hasPrefix(".") { continue }
                        scanned += 1
                        let childPath = dirPath == "/" ? "/\(name)" : "\(dirPath)/\(name)"

                        var entryType = entry.pointee.d_type
                        if entryType == UInt8(DT_UNKNOWN) {
                            var info = stat()
                            guard lstat(childPath, &info) == 0 else { continue }
                            switch info.st_mode & S_IFMT {
                            case S_IFDIR: entryType = UInt8(DT_DIR)
                            case S_IFREG: entryType = UInt8(DT_REG)
                            default: continue
                            }
                        }

                        if entryType == UInt8(DT_DIR) {
                            if childPath == libraryPath { continue }
                            if LargeOldFileScanner.skippedDirectoryNames.contains(name) { continue }
                            let ext = (name as NSString).pathExtension.lowercased()
                            if !ext.isEmpty, LargeOldFileScanner.bundleExtensions.contains(ext) { continue }
                            subdirectories.append(childPath)
                        } else if entryType == UInt8(DT_REG) {
                            var info = stat()
                            guard lstat(childPath, &info) == 0, Int64(info.st_size) >= minSize else { continue }
                            files.append((childPath, info))
                        }
                        // 符号链接及其他类型一律跳过
                    }
                    closedir(dir)
                }

                finish(subdirectories: subdirectories, files: files, scanned: scanned)
            }
        }
    }

    /// Finder「上次打开日期」对应的 Spotlight 属性。只对通过尺寸下限的少量文件调用。
    nonisolated static func lastOpenedDate(path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              let value = MDItemCopyAttribute(item, kMDItemLastUsedDate) else { return nil }
        return value as? Date
    }
}

// MARK: - 筛选

struct LargeFileFilter: Equatable, Sendable {
    enum SizeFloor: Int64, CaseIterable, Identifiable, Sendable {
        case mb50 = 52_428_800
        case mb100 = 104_857_600
        case mb500 = 524_288_000
        case gb1 = 1_073_741_824
        case gb5 = 5_368_709_120

        nonisolated var id: Int64 { rawValue }
        var title: String {
            switch self {
            case .mb50: return "≥ 50 MB"
            case .mb100: return "≥ 100 MB"
            case .mb500: return "≥ 500 MB"
            case .gb1: return "≥ 1 GB"
            case .gb5: return "≥ 5 GB"
            }
        }
    }

    enum IdleAge: Int, CaseIterable, Identifiable, Sendable {
        case any = 0
        case months3 = 90
        case months6 = 180
        case year1 = 365
        case years2 = 730

        nonisolated var id: Int { rawValue }
        var title: String {
            switch self {
            case .any: return String(localized: "不限")
            case .months3: return String(localized: "3 个月未用")
            case .months6: return String(localized: "半年未用")
            case .year1: return String(localized: "1 年未用")
            case .years2: return String(localized: "2 年未用")
            }
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable, Sendable {
        case size, idle, name
        nonisolated var id: String { rawValue }
        var title: String {
            switch self {
            case .size: return String(localized: "按大小")
            case .idle: return String(localized: "按闲置时长")
            case .name: return String(localized: "按名称")
            }
        }
    }

    var sizeFloor: SizeFloor = .mb100
    var idleAge: IdleAge = .any
    /// 为空表示不限类型。
    var kinds: Set<FileKind> = []
    var sort: SortOrder = .size

    nonisolated func matches(_ record: LargeFileRecord, now: Date = Date()) -> Bool {
        guard record.size >= sizeFloor.rawValue else { return false }
        if !kinds.isEmpty, !kinds.contains(record.kind) { return false }
        if idleAge != .any {
            let cutoff = now.addingTimeInterval(-Double(idleAge.rawValue) * 86_400)
            guard record.lastUsed < cutoff else { return false }
        }
        return true
    }

    nonisolated func apply(to records: [LargeFileRecord], now: Date = Date()) -> [LargeFileRecord] {
        let filtered = records.filter { matches($0, now: now) }
        switch sort {
        case .size: return filtered.sorted { $0.size > $1.size }
        case .idle: return filtered.sorted { $0.lastUsed < $1.lastUsed }
        case .name: return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}
