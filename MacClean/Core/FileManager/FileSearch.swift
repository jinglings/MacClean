//
//  FileSearch.swift
//  MacClean
//
//  快速文件搜索：
//  - 主通道：Spotlight 索引（NSMetadataQuery），毫秒级返回，支持按名称/内容、类型、大小、修改时间筛选。
//  - 备用通道：Spotlight 索引关闭（或未覆盖该位置）时，MacClean 自建内存文件名索引：
//    首次多线程遍历磁盘建立（十几秒），之后每次输入都在内存中毫秒级匹配，也能找到隐藏文件。
//

import Foundation
import Combine

// MARK: - 查询条件

enum SearchScope: Hashable, Sendable {
    case home
    case computer
    case folders([URL])

    var title: String {
        switch self {
        case .home: return String(localized: "主目录")
        case .computer: return String(localized: "整台 Mac")
        case .folders(let urls): return urls.count == 1 ? urls[0].lastPathComponent : String(localized: "\(urls.count) 个文件夹")
        }
    }
}

enum SearchKindFilter: String, CaseIterable, Identifiable, Sendable {
    case folder, document, image, video, audio, archive, diskImage

    nonisolated var id: String { rawValue }

    var title: String {
        switch self {
        case .folder: return String(localized: "文件夹")
        case .document: return String(localized: "文档")
        case .image: return String(localized: "图片")
        case .video: return String(localized: "视频")
        case .audio: return String(localized: "音频")
        case .archive: return String(localized: "压缩包")
        case .diskImage: return String(localized: "安装包/映像")
        }
    }

    var icon: String {
        switch self {
        case .folder: return "folder"
        case .document: return "doc.richtext"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .archive: return "doc.zipper"
        case .diskImage: return "externaldrive"
        }
    }

    /// Spotlight 内容类型树（kMDItemContentTypeTree）中的 UTI。
    nonisolated var contentTypes: [String] {
        switch self {
        case .folder: return ["public.folder"]
        case .document: return [
            "com.adobe.pdf", "public.composite-content", "public.presentation", "public.spreadsheet",
            "public.rtf", "public.plain-text", "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
        ]
        case .image: return ["public.image"]
        case .video: return ["public.movie"]
        case .audio: return ["public.audio"]
        case .archive: return ["public.archive"]
        case .diskImage: return ["com.apple.disk-image", "com.apple.installer-package-archive", "public.iso-image"]
        }
    }

    /// 备用通道（无 Spotlight）按扩展名判断。
    nonisolated func matches(extension ext: String, isDirectory: Bool) -> Bool {
        if self == .folder { return isDirectory }
        guard !isDirectory else { return false }
        switch self {
        case .document: return FileKind.classify(extension: ext) == .document || ["txt", "md", "rtf"].contains(ext.lowercased())
        case .image: return FileKind.classify(extension: ext) == .image
        case .video: return FileKind.classify(extension: ext) == .video
        case .audio: return FileKind.classify(extension: ext) == .audio
        case .archive: return FileKind.classify(extension: ext) == .archive
        case .diskImage: return FileKind.classify(extension: ext) == .diskImage
        case .folder: return false
        }
    }
}

enum SearchSizeFilter: Int64, CaseIterable, Identifiable, Sendable {
    case any = 0
    case mb1 = 1_048_576
    case mb100 = 104_857_600
    case gb1 = 1_073_741_824

    nonisolated var id: Int64 { rawValue }
    var title: String {
        switch self {
        case .any: return String(localized: "任意大小")
        case .mb1: return "≥ 1 MB"
        case .mb100: return "≥ 100 MB"
        case .gb1: return "≥ 1 GB"
        }
    }
}

enum SearchDateFilter: Int, CaseIterable, Identifiable, Sendable {
    case any = 0
    case today = 1
    case week = 7
    case month = 30
    case year = 365

    nonisolated var id: Int { rawValue }
    var title: String {
        switch self {
        case .any: return String(localized: "任意时间")
        case .today: return String(localized: "今天")
        case .week: return String(localized: "最近 7 天")
        case .month: return String(localized: "最近 30 天")
        case .year: return String(localized: "最近 1 年")
        }
    }

    nonisolated func cutoff(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .any: return nil
        case .today: return calendar.startOfDay(for: now)
        default: return now.addingTimeInterval(-Double(rawValue) * 86_400)
        }
    }
}

enum SearchSort: String, CaseIterable, Identifiable, Sendable {
    case modified, name, size

    nonisolated var id: String { rawValue }
    var title: String {
        switch self {
        case .modified: return String(localized: "最近修改")
        case .name: return String(localized: "名称")
        case .size: return String(localized: "大小")
        }
    }
}

struct FileSearchQuery: Equatable, Sendable {
    var term = ""
    var scope: SearchScope = .home
    var kinds: Set<SearchKindFilter> = []
    var size: SearchSizeFilter = .any
    var date: SearchDateFilter = .any
    var matchContents = false
    var sort: SearchSort = .modified

    nonisolated var trimmedTerm: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 没有关键词也没有任何筛选时不发起搜索（否则会列出整个索引）。
    nonisolated var isEmpty: Bool { trimmedTerm.isEmpty && kinds.isEmpty && size == .any && date == .any }
}

struct FileSearchResult: Identifiable, Hashable, Sendable {
    let path: String
    let size: Int64
    let modified: Date?
    let isDirectory: Bool

    nonisolated var id: String { path }
    nonisolated var name: String { (path as NSString).lastPathComponent }
}

// MARK: - 谓词构建（纯函数，可测试）

enum SpotlightPredicate {

    nonisolated static func build(for query: FileSearchQuery, now: Date = Date()) -> NSPredicate? {
        guard !query.isEmpty else { return nil }
        var parts: [NSPredicate] = []

        let term = query.trimmedTerm
        if !term.isEmpty {
            let name: NSPredicate = (term.contains("*") || term.contains("?"))
                ? NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, term)
                : NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, term)
            if query.matchContents {
                let content = NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemTextContent", term)
                parts.append(NSCompoundPredicate(orPredicateWithSubpredicates: [name, content]))
            } else {
                parts.append(name)
            }
        }

        if !query.kinds.isEmpty {
            let types = query.kinds.sorted { $0.rawValue < $1.rawValue }.flatMap(\.contentTypes)
            parts.append(NSCompoundPredicate(orPredicateWithSubpredicates: types.map {
                NSPredicate(format: "%K == %@", NSMetadataItemContentTypeTreeKey, $0)
            }))
        }

        if query.size != .any {
            parts.append(NSPredicate(format: "%K >= %lld", NSMetadataItemFSSizeKey, query.size.rawValue))
        }

        if let cutoff = query.date.cutoff(now: now) {
            parts.append(NSPredicate(format: "%K >= %@", NSMetadataItemFSContentChangeDateKey, cutoff as NSDate))
        }

        return parts.count == 1 ? parts[0] : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    nonisolated static func sortDescriptors(for sort: SearchSort) -> [NSSortDescriptor] {
        switch sort {
        case .modified: return [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        case .name: return [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]
        case .size: return [NSSortDescriptor(key: NSMetadataItemFSSizeKey, ascending: false)]
        }
    }
}

// MARK: - Spotlight 通道

@MainActor
final class SpotlightSearch: ObservableObject {
    @Published private(set) var results: [FileSearchResult] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var isSearching = false
    @Published private(set) var hasSearched = false

    let limit: Int
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    init(limit: Int = 1_000) {
        self.limit = limit
    }

    func run(_ request: FileSearchQuery) {
        stop()
        guard let predicate = SpotlightPredicate.build(for: request) else {
            results = []
            totalCount = 0
            hasSearched = false
            return
        }

        let query = NSMetadataQuery()
        query.predicate = predicate
        query.sortDescriptors = SpotlightPredicate.sortDescriptors(for: request.sort)
        query.notificationBatchingInterval = 0.2
        switch request.scope {
        case .home: query.searchScopes = [NSMetadataQueryUserHomeScope]
        case .computer: query.searchScopes = [NSMetadataQueryLocalComputerScope]
        case .folders(let urls): query.searchScopes = urls
        }

        let center = NotificationCenter.default
        let names: [Notification.Name] = [.NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate]
        for name in names {
            observers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.collect(finished: note.name != .NSMetadataQueryGatheringProgress)
                }
            })
        }

        self.query = query
        isSearching = true
        hasSearched = true
        results = []
        totalCount = 0
        query.start()
    }

    func stop() {
        query?.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        query = nil
        isSearching = false
    }

    private func collect(finished: Bool) {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        totalCount = query.resultCount
        let count = min(query.resultCount, limit)
        var items: [FileSearchResult] = []
        items.reserveCapacity(count)
        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let contentType = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
            items.append(FileSearchResult(
                path: path,
                size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0,
                modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                isDirectory: contentType == "public.folder"
            ))
        }
        results = items
        if finished { isSearching = false }
    }

    /// 移到废纸篓后立即从列表去掉（Spotlight 的更新通知会稍晚到达）。
    func remove(paths: Set<String>) {
        results.removeAll { paths.contains($0.path) }
    }
}

// MARK: - Spotlight 状态

enum SpotlightStatus {
    /// `mdutil -s` 报告该路径所在卷是否开启了 Spotlight 索引。
    /// 必须查询卷的挂载点：对普通子目录 mdutil 会返回 "unknown indexing state"。
    nonisolated static func isIndexingEnabled(for path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        process.arguments = ["-s", volumePath(for: path)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return true }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseEnabled(String(decoding: data, as: UTF8.self))
    }

    /// 路径所在卷的挂载点。启动盘上的用户数据（/Users、/Applications 等）实际位于数据卷
    /// /System/Volumes/Data；只读的系统卷「/」本来就不建索引，不能拿它来判断。
    nonisolated static func volumePath(for path: String) -> String {
        let volume = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeURLKey]).volume)?.path ?? "/"
        return volume == "/" ? "/System/Volumes/Data" : volume
    }

    nonisolated static func parseEnabled(_ output: String) -> Bool {
        let lower = output.lowercased()
        if lower.contains("indexing disabled") || lower.contains("indexing and searching disabled") { return false }
        return lower.contains("indexing enabled")
    }
}

// MARK: - 名称匹配（字节级，可测试）

enum NameMatcher {

    @inline(__always)
    nonisolated static func fold(_ byte: UInt8) -> UInt8 {
        (byte >= 65 && byte <= 90) ? byte | 0x20 : byte
    }

    /// 关键词转为小写 UTF-8。ASCII 字母不区分大小写；中文等无大小写之分的字符按原样匹配。
    nonisolated static func pattern(for term: String) -> [UInt8] {
        Array(term.lowercased().utf8)
    }

    nonisolated static func isWildcard(_ term: String) -> Bool {
        term.contains("*") || term.contains("?")
    }

    /// 子串匹配（ASCII 大小写不敏感）。
    @inline(__always)
    nonisolated static func contains(_ name: UnsafeBufferPointer<UInt8>, _ needle: UnsafeBufferPointer<UInt8>) -> Bool {
        let n = name.count, m = needle.count
        guard m > 0 else { return true }
        guard m <= n, let h = name.baseAddress, let p = needle.baseAddress else { return false }
        let first = p[0]
        var i = 0
        while i <= n - m {
            if fold(h[i]) == first {
                var j = 1
                while j < m && fold(h[i + j]) == p[j] { j += 1 }
                if j == m { return true }
            }
            i += 1
        }
        return false
    }

    /// 通配匹配：* 匹配任意长度（含 0），? 匹配单个字节；整名匹配（与 Finder/fnmatch 一致）。
    @inline(__always)
    nonisolated static func glob(_ name: UnsafeBufferPointer<UInt8>, _ pattern: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let h = name.baseAddress else { return pattern.allSatisfy { $0 == UInt8(ascii: "*") } }
        guard let p = pattern.baseAddress else { return name.isEmpty }
        let star = UInt8(ascii: "*"), question = UInt8(ascii: "?")
        let nameCount = name.count, patternCount = pattern.count
        var n = 0, k = 0
        var starK = -1, starN = 0
        while n < nameCount {
            if k < patternCount && (p[k] == question || p[k] == fold(h[n])) {
                n += 1; k += 1
            } else if k < patternCount && p[k] == star {
                starK = k; starN = n; k += 1
            } else if starK >= 0 {
                k = starK + 1; starN += 1; n = starN
            } else {
                return false
            }
        }
        while k < patternCount && p[k] == star { k += 1 }
        return k == patternCount
    }

    /// 通配模式中最长的字面片段（不含 * ?），用于 memmem 预筛。
    nonisolated static func longestLiteral(in pattern: [UInt8]) -> [UInt8] {
        let star = UInt8(ascii: "*"), question = UInt8(ascii: "?")
        var best: ArraySlice<UInt8> = []
        var current = pattern.startIndex
        var segmentStart = pattern.startIndex
        while current <= pattern.endIndex {
            if current == pattern.endIndex || pattern[current] == star || pattern[current] == question {
                let segment = pattern[segmentStart..<current]
                if segment.count > best.count { best = segment }
                segmentStart = current + 1
            }
            current += 1
        }
        return Array(best)
    }

    /// 便于测试与零散调用的 String 版本。
    nonisolated static func matches(_ name: String, term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let bytes = Array(name.utf8)
        let pattern = pattern(for: trimmed)
        return bytes.withUnsafeBufferPointer { name in
            pattern.withUnsafeBufferPointer { isWildcard(trimmed) ? glob(name, $0) : contains(name, $0) }
        }
    }
}

// MARK: - 分块存储

/// 只追加的分块数组：按固定大小分块一次性分配、永不搬迁。
/// 普通 Array 增长时反复「分配两倍 + 拷贝 + 释放旧块」，被释放的大块会被 malloc 缓存并继续计入进程内存，
/// 百万级条目时可多出数百 MB；分块后常驻内存基本等于数据本身。仅用于平凡类型（整数/布尔）。
nonisolated final class ChunkedBuffer<Element>: @unchecked Sendable {
    private let shift: Int
    private let mask: Int
    private var chunks: [UnsafeMutablePointer<Element>] = []
    private(set) var count = 0

    init(chunkShift: Int = 16) {
        shift = chunkShift
        mask = (1 << chunkShift) - 1
    }

    deinit { chunks.forEach { $0.deallocate() } }

    @inline(__always)
    func append(_ value: Element) {
        if count & mask == 0 { chunks.append(.allocate(capacity: mask + 1)) }
        (chunks[count >> shift] + (count & mask)).initialize(to: value)
        count += 1
    }

    @inline(__always)
    subscript(index: Int) -> Element { chunks[index >> shift][index & mask] }

    var allocatedBytes: Int { chunks.count * (mask + 1) * MemoryLayout<Element>.stride }
}

/// 名称字节的分块存储：每块 1 MB，一个名字不会跨块，因此每块都能直接整块 memmem。
/// ASCII 大写折叠为小写存放，另用每字节 1 位记录原本是否大写，显示时还原。
nonisolated final class NameBlob: @unchecked Sendable {
    static let chunkShift = 20
    static let chunkSize = 1 << chunkShift
    private(set) var chunks: [UnsafeMutablePointer<UInt8>] = []
    private(set) var used: [Int] = []
    private var upperBits: [UnsafeMutablePointer<UInt8>] = []

    deinit {
        chunks.forEach { $0.deallocate() }
        upperBits.forEach { $0.deallocate() }
    }

    /// 追加一个名字，返回其全局偏移（块号 << 20 | 块内偏移）。
    func append(_ name: UnsafeBufferPointer<UInt8>) -> UInt32 {
        let length = name.count
        if chunks.isEmpty || used[used.count - 1] + length > NameBlob.chunkSize {
            chunks.append(.allocate(capacity: NameBlob.chunkSize))
            let bits = UnsafeMutablePointer<UInt8>.allocate(capacity: NameBlob.chunkSize / 8)
            bits.initialize(repeating: 0, count: NameBlob.chunkSize / 8)
            upperBits.append(bits)
            used.append(0)
        }
        let chunk = chunks.count - 1
        let start = used[chunk]
        let destination = chunks[chunk] + start
        let bits = upperBits[chunk]
        for k in 0..<length {
            let byte = name[k]
            if byte >= 65 && byte <= 90 {
                destination[k] = byte | 0x20
                let position = start + k
                bits[position >> 3] |= UInt8(1 << (position & 7))
            } else {
                destination[k] = byte
            }
        }
        used[chunk] = start + length
        return UInt32(chunk << NameBlob.chunkShift | start)
    }

    @inline(__always)
    func pointer(at offset: UInt32) -> UnsafeMutablePointer<UInt8> {
        chunks[Int(offset) >> NameBlob.chunkShift] + (Int(offset) & (NameBlob.chunkSize - 1))
    }

    func originalName(at offset: UInt32, length: Int) -> String {
        let chunk = Int(offset) >> NameBlob.chunkShift
        let start = Int(offset) & (NameBlob.chunkSize - 1)
        let source = chunks[chunk] + start
        let bits = upperBits[chunk]
        var bytes = [UInt8](repeating: 0, count: length)
        for k in 0..<length {
            let position = start + k
            bytes[k] = (bits[position >> 3] >> UInt8(position & 7)) & 1 == 1 ? source[k] - 0x20 : source[k]
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    var allocatedBytes: Int { chunks.count * (NameBlob.chunkSize + NameBlob.chunkSize / 8) }
}

// MARK: - 自建文件名索引

/// 内存中的文件名索引：名称以 UTF-8 字节分块连续存放，路径通过父节点链还原。
/// 建立后只读，可多线程并发查询。
nonisolated final class FileNameIndex: @unchecked Sendable {
    let roots: [String]
    let builtAt = Date()
    private let names: NameBlob
    /// 条目 → 名称在 NameBlob 中的全局偏移（单调递增）
    private let starts: ChunkedBuffer<UInt32>
    private let lengths: ChunkedBuffer<UInt16>
    private let parents: ChunkedBuffer<UInt32>
    private let isDirectory: ChunkedBuffer<Bool>

    static let rootParent = UInt32.max
    static let skippedNames: Set<String> = [".git", "node_modules", ".Trash", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100"]
    static let packageExtensions: Set<String> = ["app", "photoslibrary", "musiclibrary", "framework", "bundle", "xcarchive", "xcassets"]

    var count: Int { starts.count }

    /// 索引数据占用的字节数（诊断用）。
    var dataBytes: Int {
        names.allocatedBytes + starts.allocatedBytes + lengths.allocatedBytes + parents.allocatedBytes + isDirectory.allocatedBytes
    }

    fileprivate init(roots: [String], names: NameBlob, starts: ChunkedBuffer<UInt32>, lengths: ChunkedBuffer<UInt16>,
                     parents: ChunkedBuffer<UInt32>, isDirectory: ChunkedBuffer<Bool>) {
        self.roots = roots
        self.names = names
        self.starts = starts
        self.lengths = lengths
        self.parents = parents
        self.isDirectory = isDirectory
    }

    // MARK: 建立

    /// - excludedPaths: 只收录该目录本身、不进入其内部（如 ~/Library）。
    static func build(
        roots: [String],
        excludedPaths: Set<String> = [],
        progress: (@Sendable (Int) -> Void)? = nil
    ) async -> FileNameIndex? {
        let builder = Builder(roots: roots, excludedPaths: excludedPaths, progress: progress)
        let index = await withTaskCancellationHandler {
            builder.run()
        } onCancel: {
            builder.cancel()
        }
        return Task.isCancelled ? nil : index
    }

    private final class Builder: @unchecked Sendable {
        private let condition = NSCondition()
        private var pending: [(path: String, id: UInt32)] = []
        private var busy = 0
        private var cancelled = false
        private let names = NameBlob()
        private let starts = ChunkedBuffer<UInt32>()
        private let lengths = ChunkedBuffer<UInt16>()
        private let parents = ChunkedBuffer<UInt32>()
        private let isDirectory = ChunkedBuffer<Bool>()
        private let roots: [String]
        private let excludedPaths: Set<String>
        private let progress: (@Sendable (Int) -> Void)?

        init(roots: [String], excludedPaths: Set<String>, progress: (@Sendable (Int) -> Void)?) {
            self.roots = roots
            self.excludedPaths = excludedPaths
            self.progress = progress
            for root in roots {
                let id = UInt32(starts.count)
                Array(root.utf8).withUnsafeBufferPointer { appendEntry($0, parent: FileNameIndex.rootParent, isDirectory: true) }
                pending.append((root, id))
            }
        }

        /// 调用方需持锁。
        private func appendEntry(_ name: UnsafeBufferPointer<UInt8>, parent: UInt32, isDirectory directory: Bool) {
            let trimmed = UnsafeBufferPointer(rebasing: name.prefix(Int(UInt16.max)))
            starts.append(names.append(trimmed))
            lengths.append(UInt16(trimmed.count))
            parents.append(parent)
            isDirectory.append(directory)
        }

        func cancel() {
            condition.lock(); cancelled = true; condition.broadcast(); condition.unlock()
        }

        func run() -> FileNameIndex? {
            DispatchQueue.concurrentPerform(iterations: max(2, ProcessInfo.processInfo.activeProcessorCount)) { _ in work() }
            condition.lock(); defer { condition.unlock() }
            guard !cancelled else { return nil }
            progress?(starts.count)
            return FileNameIndex(roots: roots, names: names, starts: starts, lengths: lengths, parents: parents, isDirectory: isDirectory)
        }

        private func next() -> (path: String, id: UInt32)? {
            condition.lock(); defer { condition.unlock() }
            while true {
                if cancelled { return nil }
                if let item = pending.popLast() { busy += 1; return item }
                if busy == 0 { condition.broadcast(); return nil }
                condition.wait()
            }
        }

        private func work() {
            // 每个目录的子项名称先写入本地连续缓冲区，避免为每个名字单独分配数组
            var localBlob: [UInt8] = []
            var localEntries: [(start: Int, length: Int, isDir: Bool, descend: Bool)] = []
            localBlob.reserveCapacity(16 << 10)

            while let (dirPath, dirID) = next() {
                autoreleasepool {
                    localBlob.removeAll(keepingCapacity: true)
                    localEntries.removeAll(keepingCapacity: true)

                    if let dir = opendir(dirPath) {
                        while let entry = readdir(dir) {
                            let length = Int(entry.pointee.d_namlen)
                            let type = entry.pointee.d_type
                            let isDir = type == UInt8(DT_DIR)
                            guard isDir || type == UInt8(DT_REG) || type == UInt8(DT_LNK) else { continue }

                            let start = localBlob.count
                            withUnsafeBytes(of: entry.pointee.d_name) { raw in
                                localBlob.append(contentsOf: raw.prefix(length))
                            }
                            if length <= 2, localBlob[start] == 46, length == 1 || localBlob[start + 1] == 46 {
                                localBlob.removeLast(length) // "." ".."
                                continue
                            }

                            var descend = false
                            if isDir {
                                descend = localBlob.withUnsafeBufferPointer { buffer in
                                    FileNameIndex.shouldDescend(
                                        UnsafeBufferPointer(rebasing: buffer[start..<start + length]),
                                        parentPath: dirPath,
                                        excludedPaths: excludedPaths
                                    )
                                }
                            }
                            localEntries.append((start, length, isDir, descend))
                        }
                        closedir(dir)
                    }

                    condition.lock()
                    localBlob.withUnsafeBufferPointer { buffer in
                        for child in localEntries {
                            let id = UInt32(starts.count)
                            let name = UnsafeBufferPointer(rebasing: buffer[child.start..<child.start + child.length])
                            appendEntry(name, parent: dirID, isDirectory: child.isDir)
                            if child.descend {
                                pending.append((dirPath + "/" + String(decoding: name, as: UTF8.self), id))
                            }
                        }
                    }
                    busy -= 1
                    let total = starts.count
                    let shouldReport = total / 50_000 != (total - localEntries.count) / 50_000
                    condition.broadcast()
                    condition.unlock()
                    if shouldReport { progress?(total) }
                }
            }
        }
    }

    /// 目录是否需要深入：跳过依赖/版本库等目录、App 等包、以及排除路径。
    /// 直接在名称字节上判断扩展名，避免遍历几十万个目录时产生大量临时字符串。
    static func shouldDescend(_ name: UnsafeBufferPointer<UInt8>, parentPath: String, excludedPaths: Set<String>) -> Bool {
        var dot = -1
        for k in stride(from: name.count - 1, through: 1, by: -1) where name[k] == 46 { dot = k; break }
        if dot > 0 {
            let ext = String(decoding: UnsafeBufferPointer(rebasing: name[(dot + 1)...]), as: UTF8.self).lowercased()
            if packageExtensions.contains(ext) { return false }
        }
        if name.count <= 24, name.first == 46 || name.first == 110 { // "." 或 "n"(node_modules)
            if skippedNames.contains(String(decoding: name, as: UTF8.self)) { return false }
        }
        if !excludedPaths.isEmpty {
            let path = parentPath + "/" + String(decoding: name, as: UTF8.self)
            if excludedPaths.contains(path) { return false }
        }
        return true
    }

    // MARK: 查询

    func name(at index: Int) -> String {
        names.originalName(at: starts[index], length: Int(lengths[index]))
    }

    func path(at index: Int) -> String {
        var components: [String] = []
        var current = index
        while true {
            components.append(name(at: current))
            let parent = parents[current]
            if parent == FileNameIndex.rootParent { break }
            current = Int(parent)
        }
        return components.reversed().joined(separator: "/")
    }

    /// 全局偏移所属的条目（starts 单调递增，二分查找最后一个 ≤ offset 的条目）。
    @inline(__always)
    private func entry(containing offset: Int) -> Int {
        var lo = 0, hi = count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if Int(starts[mid]) <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// 名称匹配的条目下标（按建立顺序），最多 maxMatches 个。根条目本身不参与匹配。
    /// 普通关键词：对每个名称块整块 memmem，再二分定位到条目；
    /// 通配：用最长字面片段 memmem 预筛后逐个验证；纯通配/空关键词逐条验证。
    func matchingIndices(term: String, maxMatches: Int = 50_000) -> [Int] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = NameMatcher.pattern(for: trimmed)
        let wildcard = NameMatcher.isWildcard(trimmed)
        let literal: [UInt8] = wildcard ? NameMatcher.longestLiteral(in: pattern) : pattern
        let total = count
        guard total > 0 else { return [] }

        func verify(_ i: Int, _ patternPtr: UnsafeBufferPointer<UInt8>) -> Bool {
            guard parents[i] != FileNameIndex.rootParent else { return false }
            guard wildcard else { return true }
            let name = UnsafeBufferPointer(start: names.pointer(at: starts[i]), count: Int(lengths[i]))
            return NameMatcher.glob(name, patternPtr)
        }

        let lock = NSLock()
        var perPart: [[Int]]

        if literal.isEmpty {
            // 空关键词或纯通配（如 "*"）：按条目区间并行逐条验证
            let parts = max(1, min(32, ProcessInfo.processInfo.activeProcessorCount * 2))
            let size = (total + parts - 1) / parts
            perPart = [[Int]](repeating: [], count: parts)
            pattern.withUnsafeBufferPointer { patternPtr in
                DispatchQueue.concurrentPerform(iterations: parts) { part in
                    var found: [Int] = []
                    var i = part * size
                    let upper = min(total, i + size)
                    while i < upper, found.count < maxMatches {
                        if verify(i, patternPtr) { found.append(i) }
                        i += 1
                    }
                    lock.lock(); perPart[part] = found; lock.unlock()
                }
            }
        } else {
            // 按名称块并行 memmem
            let chunkCount = names.chunks.count
            perPart = [[Int]](repeating: [], count: chunkCount)
            pattern.withUnsafeBufferPointer { patternPtr in
            literal.withUnsafeBufferPointer { literalPtr in
                let m = literalPtr.count
                DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                    let base = names.chunks[chunk]
                    let used = names.used[chunk]
                    let chunkOrigin = chunk << NameBlob.chunkShift
                    var found: [Int] = []
                    var offset = 0
                    while offset + m <= used, found.count < maxMatches {
                        guard let hit = memmem(base + offset, used - offset, literalPtr.baseAddress!, m) else { break }
                        let position = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                        let i = entry(containing: chunkOrigin + position)
                        let entryEnd = (Int(starts[i]) - chunkOrigin) + Int(lengths[i])
                        if position + m <= entryEnd {
                            if verify(i, patternPtr) { found.append(i) }
                            offset = entryEnd // 同一条目只计一次
                        } else {
                            offset = position + 1
                        }
                    }
                    lock.lock(); perPart[chunk] = found; lock.unlock()
                }
            }
            }
        }
        return Array(perPart.joined().prefix(maxMatches))
    }

    /// 完整查询：名称匹配后再按类型/大小/时间过滤（只对名称命中的条目做 lstat），排序并截断。
    nonisolated func search(_ query: FileSearchQuery, limit: Int = 1_000, now: Date = Date()) -> (results: [FileSearchResult], totalMatches: Int) {
        // 名称命中数最多统计 5 万；只对前 1 万个做 lstat（路径还原 + 大小/时间），过宽的关键词请加筛选缩小
        let matched = matchingIndices(term: query.trimmedTerm, maxMatches: query.trimmedTerm.isEmpty ? Int.max : 50_000)
        let candidates = Array(matched.prefix(query.trimmedTerm.isEmpty ? matched.count : 10_000))
        let cutoff = query.date.cutoff(now: now)

        var results = [FileSearchResult?](repeating: nil, count: candidates.count)
        results.withUnsafeMutableBufferPointer { output in
            let base = output.baseAddress!
            DispatchQueue.concurrentPerform(iterations: max(1, min(candidates.count, 64))) { chunk in
                let per = (candidates.count + 63) / 64
                let lower = chunk * max(per, 1), upper = min(candidates.count, lower + max(per, 1))
                guard lower < upper else { return }
                for position in lower..<upper {
                    let index = candidates[position]
                    let directory = isDirectory[index]
                    if !query.kinds.isEmpty {
                        let ext = (name(at: index) as NSString).pathExtension
                        guard query.kinds.contains(where: { $0.matches(extension: ext, isDirectory: directory) }) else { continue }
                    }
                    let path = self.path(at: index)
                    var info = stat()
                    guard lstat(path, &info) == 0 else { continue } // 建立索引后已被删除
                    let size = directory ? 0 : Int64(info.st_size)
                    if query.size != .any, size < query.size.rawValue { continue }
                    let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                    if let cutoff, modified < cutoff { continue }
                    base[position] = FileSearchResult(path: path, size: size, modified: modified, isDirectory: directory)
                }
            }
        }

        let hits = results.compactMap { $0 }
        let sorted: [FileSearchResult]
        switch query.sort {
        case .modified: sorted = hits.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        case .name: sorted = hits.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size: sorted = hits.sorted { $0.size > $1.size }
        }
        // 未做 lstat 的命中（超过 1 万个）不知道是否满足筛选，按名称命中数估算总数
        let total = matched.count > candidates.count && query.kinds.isEmpty && query.size == .any && query.date == .any
            ? matched.count : hits.count
        return (Array(sorted.prefix(limit)), total)
    }
}

// MARK: - 索引缓存

/// 按「根目录 + 是否排除 ~/Library」缓存已建立的索引，同一会话内重复搜索无需重建。
actor FileIndexStore {
    static let shared = FileIndexStore()

    struct Key: Hashable, Sendable {
        let roots: [String]
        let excluded: Set<String>
    }

    private var cache: [Key: FileNameIndex] = [:]
    private var building: [Key: Task<FileNameIndex?, Never>] = [:]

    nonisolated static func key(for scope: SearchScope, includeLibrary: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Key {
        let roots: [String]
        switch scope {
        case .home: roots = [home.path]
        case .computer: roots = [home.path, "/Applications", "/Users/Shared"]
        case .folders(let urls): roots = urls.map(\.path).sorted()
        }
        let excluded: Set<String> = includeLibrary ? [] : [home.path + "/Library"]
        return Key(roots: roots, excluded: excluded)
    }

    func cached(_ key: Key) -> FileNameIndex? { cache[key] }

    func index(for key: Key, rebuild: Bool = false, progress: (@Sendable (Int) -> Void)? = nil) async -> FileNameIndex? {
        if !rebuild, let existing = cache[key] { return existing }
        if let task = building[key] { return await task.value }
        let task = Task.detached(priority: .userInitiated) {
            await FileNameIndex.build(roots: key.roots, excludedPaths: key.excluded, progress: progress)
        }
        building[key] = task
        let index = await task.value
        building[key] = nil
        if let index { cache[key] = index }
        return index
    }

    func clear() { cache = [:] }
}
