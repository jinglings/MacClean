//
//  CleanupManager.swift
//  MacClean
//
//  清理管理器
//

import Foundation

actor CleanupManager {
    static let shared = CleanupManager()
    
    private init() {}
    
    typealias ProgressCallback = @Sendable (Double) -> Void
    
    // MARK: - 清理操作
    
    func clean(items: [CleanableItem], progress: ProgressCallback? = nil) async throws -> CleanResult {
        let startTime = Date()
        var freedSpace: Int64 = 0
        var cleanedItems = 0
        var errors: [CleanError] = []
        
        let totalItems = items.count
        
        for (index, item) in items.enumerated() {
            do {
                let freedSize = try await cleanItem(item)
                freedSpace += freedSize
                cleanedItems += 1
            } catch {
                errors.append(CleanError(
                    path: item.path,
                    error: error,
                    message: error.localizedDescription
                ))
            }
            
            // 报告进度
            let currentProgress = Double(index + 1) / Double(totalItems)
            progress?(currentProgress)
        }
        
        let duration = Date().timeIntervalSince(startTime)
        
        return CleanResult(
            freedSpace: freedSpace,
            cleanedItems: cleanedItems,
            duration: duration,
            errors: errors
        )
    }
    
    // MARK: - 清理单个项目
    
    private func cleanItem(_ item: CleanableItem) async throws -> Int64 {
        let fileManager = FileManager.default
        let path = item.path
        
        // 检查路径是否存在
        guard fileManager.fileExists(atPath: path) else {
            throw CleanupError.pathNotFound(path)
        }
        
        // 获取原始大小
        let originalSize = item.size
        
        // 根据类别执行不同的清理策略
        switch item.category {
        case .userCache, .browserCache, .developerTools:
            // 删除目录内容，保留目录本身
            try await cleanDirectoryContents(at: path)
            
        case .systemLogs:
            // 只删除旧日志文件
            try await cleanOldFiles(at: path, olderThanDays: 7)
            
        case .largeFiles, .oldFiles, .duplicates:
            // 删除整个文件
            try fileManager.removeItem(atPath: path)
        }
        
        return originalSize
    }
    
    // MARK: - 清理目录内容
    
    private func cleanDirectoryContents(at path: String) async throws {
        let fileManager = FileManager.default
        
        guard let contents = try? fileManager.contentsOfDirectory(atPath: path) else {
            throw CleanupError.cannotReadDirectory(path)
        }
        
        for item in contents {
            let itemPath = path + "/" + item
            do {
                try fileManager.removeItem(atPath: itemPath)
            } catch {
                // 记录错误但继续清理其他文件
                print("清理失败: \(itemPath) - \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - 清理旧文件
    
    private func cleanOldFiles(at path: String, olderThanDays days: Int) async throws {
        let fileManager = FileManager.default
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        
        guard let enumerator = fileManager.enumerator(atPath: path) else {
            throw CleanupError.cannotReadDirectory(path)
        }
        
        while let file = enumerator.nextObject() as? String {
            let filePath = path + "/" + file
            
            if let attributes = try? fileManager.attributesOfItem(atPath: filePath),
               let modificationDate = attributes[.modificationDate] as? Date,
               modificationDate < cutoffDate {
                try? fileManager.removeItem(atPath: filePath)
            }
        }
    }
    
    // MARK: - 预估清理大小
    
    func estimateCleanupSize(for items: [CleanableItem]) -> Int64 {
        items.filter { $0.isSelected }.reduce(0) { $0 + $1.size }
    }
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
            return "Path not found: \(path)"
        case .cannotReadDirectory(let path):
            return "Cannot read directory: \(path)"
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        case .unknown(let error):
            return error.localizedDescription
        }
    }
}
