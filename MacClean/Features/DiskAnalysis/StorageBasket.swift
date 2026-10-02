//
//  StorageBasket.swift
//  MacClean
//
//  存储地图 →「暂存篮」：浏览目录地图时把要清理的项目先收进来，跨层级累计可释放空间，最后一次性清理。
//  纯数据模型，不碰界面也不删文件，便于单元测试。
//

import Foundation

struct StorageBasket: Equatable {
    struct Entry: Identifiable, Equatable {
        let id: SpaceLensItem.ID
        let name: String
        let path: String
        /// 扫描时的实际占用（已分配块大小）。
        let size: Int64
        let isDirectory: Bool
        /// 加入时被它吸收掉的、原本已在篮中的子项数。
        var absorbedCount = 0
        /// 上次清理未能移走时的原因；为 nil 表示尚未清理过。
        var failureReason: String?
    }

    enum AddResult: Equatable {
        /// 已加入；absorbed 为被吸收的子项数。
        case added(absorbed: Int)
        /// 同一项目已在篮中。
        case duplicate
        /// 上层文件夹已在篮中，加入它不会多释放空间。
        case coveredBy(name: String)
        /// PathGuard 或其他规则拒绝。
        case rejected(reason: String)
    }

    private(set) var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    /// 可释放空间 = 顶层条目的占用之和；去重保证条目之间互不包含，不会重复计算。
    var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }

    var failedEntries: [Entry] { entries.filter { $0.failureReason != nil } }

    // MARK: - 查询

    func contains(id: SpaceLensItem.ID) -> Bool {
        entries.contains { $0.id == id }
    }

    /// 覆盖该路径的条目（路径本身或其上层文件夹已在篮中）。
    func entry(covering path: String) -> Entry? {
        let target = Self.normalized(path)
        return entries.first { Self.isPath(target, inside: Self.normalized($0.path)) || Self.normalized($0.path) == target }
    }

    /// 该文件夹下已在篮中的子项数（不含它本身）。
    func descendantCount(of path: String) -> Int {
        let ancestor = Self.normalized(path)
        return entries.filter { Self.isPath(Self.normalized($0.path), inside: ancestor) }.count
    }

    // MARK: - 修改

    @discardableResult
    mutating func add(
        _ item: SpaceLensItem,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AddResult {
        if item.isVirtual {
            return .rejected(reason: String(localized: "「其他」是零散文件的汇总，请进入文件夹后逐项加入"))
        }
        if contains(id: item.id) || entries.contains(where: { Self.normalized($0.path) == Self.normalized(item.path) }) {
            return .duplicate
        }
        if let ancestor = entry(covering: item.path) {
            return .coveredBy(name: ancestor.name)
        }
        do {
            try PathGuard.validateForSpaceLens(path: item.path, homeDirectory: homeDirectory)
        } catch {
            return .rejected(reason: Self.protectionReason(for: error, path: item.path, homeDirectory: homeDirectory))
        }

        let target = Self.normalized(item.path)
        let absorbed = entries.filter { Self.isPath(Self.normalized($0.path), inside: target) }
        entries.removeAll { Self.isPath(Self.normalized($0.path), inside: target) }
        entries.append(Entry(
            id: item.id,
            name: item.name,
            path: item.path,
            size: item.size,
            isDirectory: item.isDirectory,
            absorbedCount: absorbed.reduce(0) { $0 + 1 + $1.absorbedCount }
        ))
        return .added(absorbed: absorbed.count)
    }

    mutating func remove(id: SpaceLensItem.ID) {
        entries.removeAll { $0.id == id }
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    /// 清理结束后整理篮子：已离开原位置的条目移出；仍在原处的保留并记下原因，方便用户处理后重试。
    /// - Returns: 已移出篮子的条目。
    @discardableResult
    mutating func applyCleanOutcome(
        attempted: [Entry],
        stillExists: (String) -> Bool,
        failureMessages: [String: String]
    ) -> [Entry] {
        var removed: [Entry] = []
        for entry in attempted {
            guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { continue }
            if stillExists(entry.path) {
                entries[index].failureReason = failureMessages[entry.path] ?? String(localized: "未能移到废纸篓")
            } else {
                removed.append(entries.remove(at: index))
            }
        }
        return removed
    }

    // MARK: - 清理前提醒

    /// 位于文稿、桌面、图片、影片、音乐中的条目：通常是个人资料，确认框里额外提醒。
    func personalEntries(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Entry] {
        let home = homeDirectory.standardizedFileURL.path
        let folders = ["Documents", "Desktop", "Pictures", "Movies", "Music"].map { home + "/" + $0 }
        return entries.filter { entry in
            let path = Self.normalized(entry.path)
            return folders.contains { Self.isPath(path, inside: $0) }
        }
    }

    static let largeEntryThreshold: Int64 = 10_000_000_000

    var largeEntries: [Entry] { entries.filter { $0.size > Self.largeEntryThreshold } }

    // MARK: - 路径工具

    /// path 是否严格位于 ancestor 之下（相同路径返回 false）。
    static func isPath(_ path: String, inside ancestor: String) -> Bool {
        if ancestor == "/" { return path != "/" && path.hasPrefix("/") }
        return path.hasPrefix(ancestor + "/")
    }

    /// 去掉数据卷前缀与末尾斜杠，保证同一位置的两种写法能比较。
    static func normalized(_ path: String) -> String {
        var cleaned = SpaceLensItem.cleanPath(path)
        while cleaned.count > 1 && cleaned.hasSuffix("/") { cleaned.removeLast() }
        return cleaned
    }

    /// 列表里显示的路径：主目录下的写成 ~/…。
    static func displayPath(_ path: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let cleaned = normalized(path)
        let home = homeDirectory.standardizedFileURL.path
        if cleaned == home { return "~" }
        if isPath(cleaned, inside: home) { return "~" + cleaned.dropFirst(home.count) }
        return cleaned
    }

    /// 把 PathGuard 的拒绝原因翻成用户能看懂的一句话。
    static func protectionReason(for error: Error, path: String, homeDirectory: URL) -> String {
        guard let guardError = error as? PathGuardError else {
            return String(localized: "受保护：\(error.localizedDescription)")
        }
        let home = homeDirectory.standardizedFileURL.path
        let target = normalized(path)
        if target == home || target == home + "/Library" {
            return String(localized: "受保护：主目录与资源库")
        }
        switch guardError {
        case .symlinkEscape:
            return String(localized: "受保护：链接指向受保护的位置")
        case .pathTooShallow:
            return String(localized: "受保护：磁盘顶层目录")
        case .outsideAllowedRoots:
            return String(localized: "受保护：不在可清理范围内")
        case .protectedPath:
            let personal = ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music"].map { home + "/" + $0 }
            if personal.contains(target) {
                return String(localized: "受保护：主目录顶层文件夹")
            }
            let iCloud = home + "/Library/Mobile Documents"
            if target == iCloud || isPath(target, inside: iCloud) {
                return String(localized: "受保护：iCloud 云盘")
            }
            return String(localized: "受保护：系统文件夹")
        }
    }
}

// MARK: - 拖放载荷

/// 行与气泡拖到暂存篮时只携带节点 ID 的字符串；带前缀以免把普通文本拖入误识别。
enum StorageBasketDropPayload {
    static let prefix = "macclean-storage-item:"

    static func encode(_ id: SpaceLensItem.ID) -> String {
        prefix + id.uuidString
    }

    static func decode(_ payload: String) -> SpaceLensItem.ID? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(trimmed.dropFirst(prefix.count)))
    }
}
