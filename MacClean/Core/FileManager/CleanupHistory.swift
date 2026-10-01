//
//  CleanupHistory.swift
//  MacClean
//
//  清理记录与一键恢复：每次移入废纸篓都记下「原路径 → 废纸篓路径」，
//  只要用户还没清空废纸篓，就能把整次清理原样放回去。
//  另含「始终忽略」名单。
//

import Foundation
import os

struct CleanupHistoryEntry: Codable, Hashable, Sendable {
    let originalPath: String
    let trashedPath: String
    let size: Int64
}

struct CleanupSession: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let date: Date
    var entries: [CleanupHistoryEntry]
    /// 用户是否已执行过恢复。
    var restoredAt: Date?

    nonisolated var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }

    /// 仍在废纸篓里、原位置又没有被占用的条目才可以恢复。
    nonisolated var restorableEntries: [CleanupHistoryEntry] {
        let fileManager = FileManager.default
        return entries.filter {
            fileManager.fileExists(atPath: $0.trashedPath) && !fileManager.fileExists(atPath: $0.originalPath)
        }
    }
}

struct RestoreResult: Sendable {
    let restoredCount: Int
    let restoredSize: Int64
    let failedPaths: [String]
}

/// 清理记录存储。所有方法都是同步文件 IO，量很小，调用方可在任意线程使用；内部用锁串行化。
final class CleanupHistoryStore: @unchecked Sendable {
    nonisolated static let shared = CleanupHistoryStore()

    nonisolated static let maxSessions = 30

    private let fileURL: URL
    private let lock = NSLock()

    nonisolated init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.fileURL = support.appendingPathComponent("MacClean/cleanup-history.json")
        }
    }

    nonisolated func sessions() -> [CleanupSession] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    nonisolated func session(id: UUID) -> CleanupSession? {
        sessions().first { $0.id == id }
    }

    /// 记录一次清理，返回会话 ID；entries 为空时不记录。
    @discardableResult
    nonisolated func record(entries: [CleanupHistoryEntry], date: Date = Date()) -> UUID? {
        guard !entries.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        var all = load()
        let session = CleanupSession(id: UUID(), date: date, entries: entries, restoredAt: nil)
        all.insert(session, at: 0)
        if all.count > Self.maxSessions { all = Array(all.prefix(Self.maxSessions)) }
        save(all)
        return session.id
    }

    /// 把某次清理中仍在废纸篓里的项目移回原位置。
    nonisolated func restore(sessionID: UUID) -> RestoreResult {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        guard let index = all.firstIndex(where: { $0.id == sessionID }) else {
            return RestoreResult(restoredCount: 0, restoredSize: 0, failedPaths: [])
        }

        let fileManager = FileManager.default
        var restored = 0
        var restoredSize: Int64 = 0
        var failed: [String] = []

        for entry in all[index].restorableEntries {
            let original = URL(fileURLWithPath: entry.originalPath)
            do {
                try fileManager.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: URL(fileURLWithPath: entry.trashedPath), to: original)
                restored += 1
                restoredSize += entry.size
            } catch {
                failed.append(entry.originalPath)
            }
        }

        all[index].restoredAt = Date()
        save(all)
        return RestoreResult(restoredCount: restored, restoredSize: restoredSize, failedPaths: failed)
    }

    nonisolated func clear() {
        lock.lock(); defer { lock.unlock() }
        save([])
    }

    // MARK: - 持久化

    nonisolated private func load() -> [CleanupSession] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([CleanupSession].self, from: data)) ?? []
    }

    nonisolated private func save(_ sessions: [CleanupSession]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger(subsystem: "com.macclean", category: "CleanupHistory")
                .error("保存清理记录失败: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - 始终忽略

/// 用户标记为「始终忽略」的路径。被忽略的路径及其子路径不会出现在任何扫描结果里。
enum IgnoreList {
    nonisolated private static let key = "MacClean.ignoredPaths"

    nonisolated static func paths(defaults: UserDefaults = .standard) -> [String] {
        (defaults.stringArray(forKey: key) ?? []).sorted()
    }

    nonisolated static func add(_ path: String, defaults: UserDefaults = .standard) {
        var current = Set(defaults.stringArray(forKey: key) ?? [])
        current.insert(path)
        defaults.set(Array(current), forKey: key)
    }

    nonisolated static func remove(_ path: String, defaults: UserDefaults = .standard) {
        let current = (defaults.stringArray(forKey: key) ?? []).filter { $0 != path }
        defaults.set(current, forKey: key)
    }

    nonisolated static func isIgnored(_ path: String, in ignored: [String]) -> Bool {
        ignored.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    nonisolated static func filter(_ items: [CleanableItem], defaults: UserDefaults = .standard) -> [CleanableItem] {
        let ignored = paths(defaults: defaults)
        guard !ignored.isEmpty else { return items }
        return items.filter { !isIgnored($0.path, in: ignored) }
    }
}
