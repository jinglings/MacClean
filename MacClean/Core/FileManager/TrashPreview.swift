//
//  TrashPreview.swift
//  MacClean
//
//  清空废纸篓前的内容预览：只读废纸篓顶层，告诉用户「将永久删除哪些东西」。
//

import Foundation

nonisolated struct TrashPreview: Equatable, Sendable {
    /// 废纸篓顶层项目数
    let count: Int
    /// 最近放入废纸篓的几项名称（新到旧）
    let recentNames: [String]

    /// 读取废纸篓顶层。没有完全磁盘访问权限时可能读不到，返回 nil。
    static func load(trashURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"), limit: Int = 3) -> TrashPreview? {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: trashURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }
        func date(_ url: URL) -> Date {
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast
        }
        let recent = items
            .map { ($0, date($0)) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0.lastPathComponent }
        return TrashPreview(count: items.count, recentNames: Array(recent))
    }

    /// 「共 N 项，最近放入的有：a、b、c」
    var summary: String {
        guard count > 0 else { return String(localized: "废纸篓是空的。") }
        let names = recentNames.map { String(localized: "「\($0)」") }.joined(separator: String(localized: "、"))
        return count > recentNames.count
            ? String(localized: "共 \(count) 项，最近放入的有：\(names) 等。")
            : String(localized: "共 \(count) 项：\(names)。")
    }

    /// 清空前的统一提醒
    static var irreversibleNote: String {
        String(localized: "清空后 MacClean 无法撤销。如果事后发现删错了，可以在「找回文件」里尝试从本地快照或时间机器备份中找回。")
    }
}
