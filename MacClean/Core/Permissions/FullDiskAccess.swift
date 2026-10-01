//
//  FullDiskAccess.swift
//  MacClean
//
//  完全磁盘访问权限：检测是否已授权 + 跳转系统设置。
//  macOS 没有直接查询的 API，只能试读受 TCC 保护的位置。
//

import AppKit
import Foundation

enum FullDiskAccess {
    /// 是否已授予完全磁盘访问权限（同步文件 IO，耗时极短，任意线程可调用）。
    nonisolated static var isGranted: Bool {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path

        // 系统级 TCC 数据库：只有获得完全磁盘访问的进程能打开
        if let handle = FileHandle(forReadingAtPath: "/Library/Application Support/com.apple.TCC/TCC.db") {
            try? handle.close()
            return true
        }
        // 兜底：Safari / Mail 数据目录同样受保护；目录不存在时不作为依据
        for path in ["\(home)/Library/Safari", "\(home)/Library/Mail"] where fileManager.fileExists(atPath: path) {
            if (try? fileManager.contentsOfDirectory(atPath: path)) != nil { return true }
        }
        return false
    }

    /// 打开「隐私与安全性 → 完全磁盘访问权限」。
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
