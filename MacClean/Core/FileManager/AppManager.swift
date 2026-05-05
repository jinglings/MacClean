//
//  AppManager.swift
//  MacClean
//
//  应用程序管理器 - 扫描、分析和卸载应用
//

import Foundation
import AppKit

// MARK: - 应用信息模型
struct AppInfo: Identifiable, Equatable, Hashable {
    let id = UUID()
    let name: String
    let bundleIdentifier: String
    let path: String
    let version: String
    let size: Int64
    let icon: NSImage?
    let lastUsedDate: Date?
    let isFromAppStore: Bool
    var isSelected: Bool = false
    var relatedFiles: [RelatedFile] = []
    
    var totalSize: Int64 {
        size + relatedFiles.reduce(0) { $0 + $1.size }
    }
    
    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - 关联文件模型
struct RelatedFile: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    let type: RelatedFileType
    var isSelected: Bool = true
    
    static func == (lhs: RelatedFile, rhs: RelatedFile) -> Bool {
        lhs.id == rhs.id
    }
}

enum RelatedFileType: String {
    case preferences = "偏好设置"
    case cache = "缓存文件"
    case applicationSupport = "应用支持"
    case logs = "日志文件"
    case containers = "容器数据"
    case savedState = "保存的状态"
    case other = "其他"
    
    var icon: String {
        switch self {
        case .preferences: return "gearshape.fill"
        case .cache: return "folder.badge.gearshape"
        case .applicationSupport: return "folder.fill"
        case .logs: return "doc.text.fill"
        case .containers: return "shippingbox.fill"
        case .savedState: return "clock.arrow.circlepath"
        case .other: return "doc.fill"
        }
    }
}

// MARK: - 扫描结果模型
struct AppScanResult {
    let apps: [AppInfo]
    let unusedApps: [AppInfo]
    let leftoverFiles: [RelatedFile]
    let installers: [InstallerFile]
    let updatableApps: [UpdatableApp]
    let totalAppsCount: Int
    let unusedAppsSize: Int64
    let leftoverSize: Int64
    let installerSize: Int64
}

// MARK: - 安装包模型
struct InstallerFile: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    var isSelected: Bool = true
    
    static func == (lhs: InstallerFile, rhs: InstallerFile) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 可更新应用模型
struct UpdatableApp: Identifiable {
    let id = UUID()
    let name: String
    let currentVersion: String
    let latestVersion: String
    let icon: NSImage?
}

// MARK: - 应用管理器
actor AppManager {
    static let shared = AppManager()
    
    private let fileManager = FileManager.default
    private let workspace = NSWorkspace.shared
    
    private init() {}
    
    // MARK: - 扫描所有应用
    func scanApplications() async throws -> AppScanResult {
        print("=== 开始扫描应用程序 ===")
        
        var allApps: [AppInfo] = []
        var unusedApps: [AppInfo] = []
        var leftoverFiles: [RelatedFile] = []
        var installers: [InstallerFile] = []
        let updatableApps: [UpdatableApp] = []
        
        // 扫描 /Applications
        let systemAppsPath = "/Applications"
        let systemApps = await scanAppsInDirectory(systemAppsPath)
        allApps.append(contentsOf: systemApps)
        
        // 扫描用户应用目录
        let userAppsPath = NSHomeDirectory() + "/Applications"
        if fileManager.fileExists(atPath: userAppsPath) {
            let userApps = await scanAppsInDirectory(userAppsPath)
            allApps.append(contentsOf: userApps)
        }
        
        print("共发现 \(allApps.count) 个应用程序")
        
        // 查找未使用的应用（30天内未使用）
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        unusedApps = allApps.filter { app in
            if let lastUsed = app.lastUsedDate {
                return lastUsed < thirtyDaysAgo
            }
            return false
        }
        print("发现 \(unusedApps.count) 个未使用的应用")
        
        // 扫描残留文件
        leftoverFiles = await scanLeftoverFiles()
        print("发现 \(leftoverFiles.count) 个残留文件")
        
        // 扫描安装包
        installers = await scanInstallers()
        print("发现 \(installers.count) 个安装包")
        
        let unusedAppsSize = unusedApps.reduce(0) { $0 + $1.totalSize }
        let leftoverSize = leftoverFiles.reduce(0) { $0 + $1.size }
        let installerSize = installers.reduce(0) { $0 + $1.size }
        
        print("=== 扫描完成 ===")
        
        return AppScanResult(
            apps: allApps,
            unusedApps: unusedApps,
            leftoverFiles: leftoverFiles,
            installers: installers,
            updatableApps: updatableApps,
            totalAppsCount: allApps.count,
            unusedAppsSize: unusedAppsSize,
            leftoverSize: leftoverSize,
            installerSize: installerSize
        )
    }
    
    // MARK: - 扫描目录中的应用
    private func scanAppsInDirectory(_ path: String) async -> [AppInfo] {
        var apps: [AppInfo] = []
        
        guard let contents = try? fileManager.contentsOfDirectory(atPath: path) else {
            return apps
        }
        
        for item in contents {
            if item.hasSuffix(".app") {
                let appPath = path + "/" + item
                if let appInfo = await getAppInfo(at: appPath) {
                    apps.append(appInfo)
                }
            }
        }
        
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    // MARK: - 获取应用信息
    private func getAppInfo(at path: String) async -> AppInfo? {
        let url = URL(fileURLWithPath: path)
        
        guard let bundle = Bundle(url: url) else { return nil }
        
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        
        let bundleIdentifier = bundle.bundleIdentifier ?? ""
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        
        // 获取应用大小
        let size = calculateDirectorySize(at: path)
        
        // 获取图标
        let icon = await MainActor.run {
            workspace.icon(forFile: path)
        }
        
        // 获取最后使用时间
        let lastUsedDate = getLastUsedDate(for: path)
        
        // 判断是否来自 App Store
        let isFromAppStore = checkIfFromAppStore(bundleIdentifier: bundleIdentifier, path: path)
        
        // 获取关联文件
        var relatedFiles: [RelatedFile] = []
        if !bundleIdentifier.isEmpty {
            relatedFiles = await findRelatedFiles(for: bundleIdentifier, appName: name)
        }
        
        return AppInfo(
            name: name,
            bundleIdentifier: bundleIdentifier,
            path: path,
            version: version,
            size: size,
            icon: icon,
            lastUsedDate: lastUsedDate,
            isFromAppStore: isFromAppStore,
            isSelected: false,
            relatedFiles: relatedFiles
        )
    }
    
    // MARK: - 查找应用关联文件
    private func findRelatedFiles(for bundleIdentifier: String, appName: String) async -> [RelatedFile] {
        var files: [RelatedFile] = []
        let homeDir = NSHomeDirectory()
        
        // 偏好设置
        let prefsPath = homeDir + "/Library/Preferences/\(bundleIdentifier).plist"
        if fileManager.fileExists(atPath: prefsPath) {
            let size = getFileSize(at: prefsPath)
            files.append(RelatedFile(name: "\(appName) 偏好设置", path: prefsPath, size: size, type: .preferences))
        }
        
        // 缓存
        let cachePath = homeDir + "/Library/Caches/\(bundleIdentifier)"
        if fileManager.fileExists(atPath: cachePath) {
            let size = calculateDirectorySize(at: cachePath)
            if size > 0 {
                files.append(RelatedFile(name: "\(appName) 缓存", path: cachePath, size: size, type: .cache))
            }
        }
        
        // 应用支持
        let supportPath = homeDir + "/Library/Application Support/\(appName)"
        if fileManager.fileExists(atPath: supportPath) {
            let size = calculateDirectorySize(at: supportPath)
            if size > 0 {
                files.append(RelatedFile(name: "\(appName) 应用支持", path: supportPath, size: size, type: .applicationSupport))
            }
        }
        
        // 容器（沙盒应用）
        let containersPath = homeDir + "/Library/Containers/\(bundleIdentifier)"
        if fileManager.fileExists(atPath: containersPath) {
            let size = calculateDirectorySize(at: containersPath)
            if size > 0 {
                files.append(RelatedFile(name: "\(appName) 容器数据", path: containersPath, size: size, type: .containers))
            }
        }
        
        // Group Containers
        let groupContainersPath = homeDir + "/Library/Group Containers"
        if fileManager.fileExists(atPath: groupContainersPath) {
            if let contents = try? fileManager.contentsOfDirectory(atPath: groupContainersPath) {
                for item in contents {
                    if item.contains(bundleIdentifier) {
                        let itemPath = groupContainersPath + "/" + item
                        let size = calculateDirectorySize(at: itemPath)
                        if size > 0 {
                            files.append(RelatedFile(name: "\(appName) 组容器", path: itemPath, size: size, type: .containers))
                        }
                    }
                }
            }
        }
        
        // 日志
        let logsPath = homeDir + "/Library/Logs/\(appName)"
        if fileManager.fileExists(atPath: logsPath) {
            let size = calculateDirectorySize(at: logsPath)
            if size > 0 {
                files.append(RelatedFile(name: "\(appName) 日志", path: logsPath, size: size, type: .logs))
            }
        }
        
        // 保存的状态
        let savedStatePath = homeDir + "/Library/Saved Application State/\(bundleIdentifier).savedState"
        if fileManager.fileExists(atPath: savedStatePath) {
            let size = calculateDirectorySize(at: savedStatePath)
            if size > 0 {
                files.append(RelatedFile(name: "\(appName) 保存状态", path: savedStatePath, size: size, type: .savedState))
            }
        }
        
        return files
    }
    
    // MARK: - 扫描残留文件
    private func scanLeftoverFiles() async -> [RelatedFile] {
        var leftovers: [RelatedFile] = []
        let homeDir = NSHomeDirectory()
        
        // 获取已安装应用的 bundle identifier 列表
        var installedBundleIds = Set<String>()
        if let apps = try? fileManager.contentsOfDirectory(atPath: "/Applications") {
            for app in apps where app.hasSuffix(".app") {
                if let bundle = Bundle(url: URL(fileURLWithPath: "/Applications/\(app)")),
                   let bundleId = bundle.bundleIdentifier {
                    installedBundleIds.insert(bundleId)
                }
            }
        }
        
        // 扫描 ~/Library/Application Support
        let supportPath = homeDir + "/Library/Application Support"
        if let contents = try? fileManager.contentsOfDirectory(atPath: supportPath) {
            for item in contents {
                let itemPath = supportPath + "/" + item
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: itemPath, isDirectory: &isDir), isDir.boolValue {
                    // 检查是否为残留文件（不属于任何已安装的应用）
                    let size = calculateDirectorySize(at: itemPath)
                    if size > 1_000_000 { // 大于 1MB
                        // TODO: 更精确的残留检测
                        // 这里简化处理，实际应该匹配应用名称
                    }
                }
            }
        }
        
        return leftovers
    }
    
    // MARK: - 扫描安装包
    private func scanInstallers() async -> [InstallerFile] {
        var installers: [InstallerFile] = []
        let homeDir = NSHomeDirectory()
        
        // 扫描下载文件夹
        let downloadsPath = homeDir + "/Downloads"
        if let contents = try? fileManager.contentsOfDirectory(atPath: downloadsPath) {
            for item in contents {
                let itemPath = downloadsPath + "/" + item
                let lowercased = item.lowercased()
                
                if lowercased.hasSuffix(".dmg") || lowercased.hasSuffix(".pkg") || lowercased.hasSuffix(".zip") {
                    let size = getFileSize(at: itemPath)
                    if size > 1_000_000 { // 大于 1MB
                        installers.append(InstallerFile(
                            name: item,
                            path: itemPath,
                            size: size
                        ))
                    }
                }
            }
        }
        
        return installers.sorted { $0.size > $1.size }
    }
    
    // MARK: - 卸载应用
    func uninstallApp(_ app: AppInfo) async throws {
        print("开始卸载应用: \(app.name)")
        
        // 删除应用本体
        try fileManager.trashItem(at: URL(fileURLWithPath: app.path), resultingItemURL: nil)
        print("已删除应用: \(app.path)")
        
        // 删除选中的关联文件
        for file in app.relatedFiles where file.isSelected {
            do {
                try fileManager.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil)
                print("已删除关联文件: \(file.path)")
            } catch {
                print("删除关联文件失败: \(file.path), 错误: \(error)")
            }
        }
        
        print("应用卸载完成: \(app.name)")
    }
    
    // MARK: - 删除文件
    func deleteFiles(_ files: [RelatedFile]) async throws {
        for file in files where file.isSelected {
            try fileManager.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil)
            print("已删除: \(file.path)")
        }
    }
    
    // MARK: - 删除安装包
    func deleteInstallers(_ installers: [InstallerFile]) async throws {
        for installer in installers where installer.isSelected {
            try fileManager.trashItem(at: URL(fileURLWithPath: installer.path), resultingItemURL: nil)
            print("已删除安装包: \(installer.path)")
        }
    }
    
    // MARK: - 辅助方法
    
    private func calculateDirectorySize(at path: String) -> Int64 {
        var totalSize: Int64 = 0
        
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        
        var count = 0
        while let fileURL = enumerator.nextObject() as? URL {
            count += 1
            if count > 1000 { break } // 限制遍历数量
            
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true,
               let size = values.fileSize {
                totalSize += Int64(size)
            }
        }
        
        return totalSize
    }
    
    private func getFileSize(at path: String) -> Int64 {
        do {
            let attrs = try fileManager.attributesOfItem(atPath: path)
            return attrs[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
    
    private func getLastUsedDate(for path: String) -> Date? {
        do {
            let attrs = try fileManager.attributesOfItem(atPath: path)
            return attrs[.modificationDate] as? Date
        } catch {
            return nil
        }
    }
    
    private func checkIfFromAppStore(bundleIdentifier: String, path: String) -> Bool {
        // 检查是否有 App Store 收据
        let receiptPath = path + "/Contents/_MASReceipt/receipt"
        return fileManager.fileExists(atPath: receiptPath)
    }
}
