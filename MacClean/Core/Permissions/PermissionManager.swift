//
//  PermissionManager.swift
//  MacClean
//
//  权限管理器 - 处理 Security-Scoped Bookmarks
//

import Foundation
import AppKit

class PermissionManager {
    static let shared = PermissionManager()
    
    private let bookmarksKey = "SecurityScopedBookmarks"
    private var activeSecurityScopedURLs: [URL] = []
    
    private init() {
        // 恢复已保存的书签
        restoreBookmarks()
    }
    
    // MARK: - 请求目录访问权限
    
    func requestAccess(to path: String, reason: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path)
        panel.message = reason
        panel.prompt = NSLocalizedString("grant_access", comment: "")
        
        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        
        // 创建并保存安全范围书签
        saveBookmark(for: url)
        
        return url
    }
    
    // MARK: - 检查权限状态
    
    func checkAccess(to path: String) -> PermissionStatus {
        let url = URL(fileURLWithPath: path)
        
        // 检查是否有已保存的书签
        if let bookmarks = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data],
           let bookmarkData = bookmarks[path] {
            // 尝试解析书签
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if !isStale && resolvedURL.startAccessingSecurityScopedResource() {
                    activeSecurityScopedURLs.append(resolvedURL)
                    return .granted
                }
            }
        }
        
        // 检查是否可以直接访问
        if FileManager.default.isReadableFile(atPath: path) {
            return .granted
        }
        
        return .notDetermined
    }
    
    // MARK: - 保存书签
    
    private func saveBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            
            var bookmarks = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
            bookmarks[url.path] = bookmarkData
            UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
            
            print("书签已保存: \(url.path)")
        } catch {
            print("保存书签失败: \(error)")
        }
    }
    
    // MARK: - 恢复书签
    
    private func restoreBookmarks() {
        guard let bookmarks = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] else {
            return
        }
        
        for (path, bookmarkData) in bookmarks {
            var isStale = false
            
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                
                if isStale {
                    // 书签已过期，尝试刷新
                    print("书签已过期，需要重新授权: \(path)")
                    continue
                }
                
                if url.startAccessingSecurityScopedResource() {
                    activeSecurityScopedURLs.append(url)
                    print("恢复书签访问权限: \(path)")
                }
            } catch {
                print("恢复书签失败: \(path) - \(error)")
            }
        }
    }
    
    // MARK: - 停止访问
    
    func stopAccessing(url: URL) {
        url.stopAccessingSecurityScopedResource()
        activeSecurityScopedURLs.removeAll { $0 == url }
    }
    
    func stopAllAccess() {
        for url in activeSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURLs.removeAll()
    }
    
    // MARK: - 清除所有书签
    
    func clearAllBookmarks() {
        stopAllAccess()
        UserDefaults.standard.removeObject(forKey: bookmarksKey)
    }
    
    deinit {
        stopAllAccess()
    }
}

// MARK: - 权限请求视图

import SwiftUI

struct PermissionRequestView: View {
    let request: PermissionRequest
    let onGrant: () -> Void
    let onDeny: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            
            Text("permission_required")
                .font(.headline)
            
            Text(request.reason)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Text(request.path)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            
            HStack(spacing: 16) {
                Button("deny") {
                    onDeny()
                }
                .buttonStyle(.bordered)
                
                Button("grant_access") {
                    onGrant()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(width: 400)
    }
}
