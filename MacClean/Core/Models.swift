//
//  Models.swift
//  MacClean
//
//  数据模型定义
//

import SwiftUI

// MARK: - 磁盘信息
struct DiskInfo {
    let volumeName: String
    let totalSpace: Int64
    let freeSpace: Int64
    
    var usedSpace: Int64 {
        totalSpace - freeSpace
    }
    
    var usedPercentage: Double {
        guard totalSpace > 0 else { return 0 }
        return Double(usedSpace) / Double(totalSpace)
    }
}

// MARK: - 可清理项目
struct CleanableItem: Identifiable {
    let id = UUID()
    var name: String
    var path: String
    var size: Int64
    var category: CleanableCategory
    var isSelected: Bool
    var description: String?
    var lastModified: Date?
}

// MARK: - 可清理分类
enum CleanableCategory: String, CaseIterable {
    case userCache = "user_cache"
    case browserCache = "browser_cache"
    case developerTools = "developer_tools"
    case systemLogs = "system_logs"
    case largeFiles = "large_files"
    case oldFiles = "old_files"
    case duplicates = "duplicates"
    
    var localizedName: String {
        NSLocalizedString(rawValue, comment: "")
    }
    
    var icon: String {
        switch self {
        case .userCache: return "folder.badge.person.crop"
        case .browserCache: return "globe"
        case .developerTools: return "hammer.fill"
        case .systemLogs: return "doc.text.fill"
        case .largeFiles: return "doc.fill"
        case .oldFiles: return "clock.fill"
        case .duplicates: return "doc.on.doc.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .userCache: return .blue
        case .browserCache: return .purple
        case .developerTools: return .orange
        case .systemLogs: return .gray
        case .largeFiles: return .red
        case .oldFiles: return .yellow
        case .duplicates: return .green
        }
    }
}

// MARK: - 扫描结果
struct ScanResult {
    let diskInfo: DiskInfo
    let cleanableItems: [CleanableItem]
    let scanDuration: TimeInterval
}

// MARK: - 空间透镜
struct SpaceLensItem: Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var path: String
    var size: Int64
    var isDirectory: Bool
    var children: [SpaceLensItem]
    var itemCount: Int
    var isReadable: Bool
    var isVirtual: Bool
    var lastModified: Date?
    
    var sortedChildren: [SpaceLensItem] {
        children.sorted {
            if $0.size == $1.size { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return $0.size > $1.size
        }
    }

    /// Strip the macOS data-volume prefix so paths display as familiar /Users/… paths.
    static func cleanPath(_ path: String) -> String {
        let prefix = "/System/Volumes/Data"
        guard path.hasPrefix(prefix) else { return path }
        let stripped = path.dropFirst(prefix.count)
        return stripped.isEmpty ? "/" : String(stripped)
    }
}

struct SpaceLensScanProgress: Sendable {
    let scannedPath: String
    let scannedItems: Int
    let progress: Double
}

struct SpaceLensScanResult {
    let root: SpaceLensItem
    let diskInfo: DiskInfo
    let scanDuration: TimeInterval
}

// MARK: - 清理结果
struct CleanResult {
    let freedSpace: Int64
    let cleanedItems: Int
    let duration: TimeInterval
    let errors: [CleanError]
}

// MARK: - 清理错误
struct CleanError: Identifiable {
    let id = UUID()
    let path: String
    let error: Error
    let message: String
}

// MARK: - 权限状态
enum PermissionStatus {
    case notDetermined
    case granted
    case denied
    
    var isGranted: Bool {
        self == .granted
    }
}

// MARK: - 权限请求
struct PermissionRequest: Identifiable {
    let id = UUID()
    let path: String
    let reason: String
    var status: PermissionStatus = .notDetermined
}
