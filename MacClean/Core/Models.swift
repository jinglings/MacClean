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

    nonisolated var usedSpace: Int64 {
        totalSpace - freeSpace
    }

    nonisolated var usedPercentage: Double {
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
    /// 为 true 时清理会把整个路径移入废纸篓；否则按分类的默认策略处理（缓存类只清空目录内容）。
    var removesContainer: Bool = false
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
    case brokenLoginItems = "broken_login_items"
    /// 废纸篓内容：唯一一个「永久删除、不可恢复」的分类。
    case trash = "trash"
    /// 下载目录中的安装包（.dmg / .pkg / .xip / .iso 等）。
    case installers = "installers"
    /// 邮件 App 下载到本地的附件副本。
    case mailAttachments = "mail_attachments"
    /// iPhone / iPad 本地备份。
    case iosBackups = "ios_backups"
    /// iPhone / iPad 固件更新包（.ipsw）。
    case iosUpdates = "ios_updates"
    /// 长期未动的项目中可重建的依赖/构建目录（node_modules、Pods、target 等）。
    case projectArtifacts = "project_artifacts"
    /// 相似照片组中用户选择移除的照片。
    case similarPhotos = "similar_photos"
    /// 应用的数据目录（聊天缓存、旧版本、应用缓存等），来自「应用占用」页面。
    case appData = "app_data"
    /// 卸载的应用本体（/Applications 或 ~/Applications 下的 .app，整体移入废纸篓）。
    case applications = "applications"
    /// 应用卸载后残留在 ~/Library 下的偏好、支持文件、缓存等。
    case appLeftovers = "app_leftovers"
    /// 浏览器历史、Cookie、最近使用记录等隐私数据。
    case privacyData = "privacy_data"
    /// 「存储地图」中用户手动选择删除的任意文件/文件夹。
    case spaceLens = "space_lens"

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
        case .brokenLoginItems: return "exclamationmark.triangle.fill"
        case .trash: return "trash.fill"
        case .installers: return "shippingbox.fill"
        case .mailAttachments: return "paperclip"
        case .iosBackups: return "iphone"
        case .iosUpdates: return "arrow.down.circle.fill"
        case .projectArtifacts: return "folder.fill.badge.gearshape"
        case .similarPhotos: return "photo.on.rectangle.angled"
        case .appData: return "shippingbox.fill"
        case .applications: return "app.fill"
        case .appLeftovers: return "folder.fill.badge.minus"
        case .privacyData: return "hand.raised.fill"
        case .spaceLens: return "chart.pie.fill"
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
        case .brokenLoginItems: return .red
        case .trash: return .red
        case .installers: return .orange
        case .mailAttachments: return .blue
        case .iosBackups: return .purple
        case .iosUpdates: return .purple
        case .projectArtifacts: return .orange
        case .similarPhotos: return .blue
        case .appData: return .orange
        case .applications: return .blue
        case .appLeftovers: return .orange
        case .privacyData: return .teal
        case .spaceLens: return .blue
        }
    }

    /// 清理后是否仍可从废纸篓恢复。只有清空废纸篓本身是不可逆的。
    nonisolated var isRecoverable: Bool {
        self != .trash
    }
}

// MARK: - 扫描结果
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
    /// 因缺少权限（TCC 未授权等）而无法读取、未纳入统计的目录数。
    let unreadableCount: Int
}

// MARK: - 清理结果
struct CleanResult {
    let freedSpace: Int64
    let cleanedItems: Int
    let duration: TimeInterval
    let errors: [CleanError]
    /// 本次清理在「清理记录」中的会话 ID；为 nil 表示没有可恢复的项目（例如只清空了废纸篓）。
    var historySessionID: UUID? = nil
    /// 永久删除（清空废纸篓）释放的空间，这部分立即生效且不可恢复。
    var permanentlyFreed: Int64 = 0
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
