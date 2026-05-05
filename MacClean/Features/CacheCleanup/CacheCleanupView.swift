//
//  CacheCleanupView.swift
//  MacClean
//
//  Wraps CosmicCacheView and provides ViewModel/Models
//

import SwiftUI
import Combine

struct CacheCleanupView: View {
    var body: some View {
        CosmicCacheView()
    }
}

// MARK: - Models

struct CacheItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    let category: CacheCategory
    var isSelected: Bool = true
    var appIcon: NSImage? {
        NSWorkspace.shared.icon(forFile: path)
    }
    
    enum CacheCategory {
        case systemJunk
        case binaryJunk
        case xcodeJunk
    }
}

// MARK: - ViewModel

@MainActor
class CacheCleanupViewModel: ObservableObject {
    @Published var userCaches: [CacheItem] = []
    @Published var browserCaches: [CacheItem] = []
    @Published var appCaches: [CacheItem] = []
    
    @Published var isScanning: Bool = false
    @Published var isCleaning: Bool = false
    
    var allItems: [CacheItem] {
        userCaches + browserCaches + appCaches
    }
    
    var selectedSize: Int64 {
        return allItems.filter { $0.isSelected }.reduce(0) { $0 + $1.size }
    }
    
    var totalScannedSize: Int64 {
        allItems.reduce(0) { $0 + $1.size }
    }
    
    func scanCaches() {
        guard !isScanning else { return }
        isScanning = true
        userCaches = []
        browserCaches = []
        appCaches = []
        
        Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let home = fileManager.homeDirectoryForCurrentUser
            
            let systemJunk = Self.scanGroups(
                home: home,
                groups: [
                    ScanGroup(name: "User Caches", relativePath: "Library/Caches"),
                    ScanGroup(name: "System Logs", relativePath: "Library/Logs"),
                    ScanGroup(name: "Diagnostic Reports", relativePath: "Library/Logs/DiagnosticReports"),
                    ScanGroup(name: "Saved Application State", relativePath: "Library/Saved Application State"),
                    ScanGroup(name: "Temporary Files", relativePath: NSTemporaryDirectory()),
                    ScanGroup(name: "Trash", relativePath: ".Trash")
                ],
                category: .systemJunk
            )
            
            let binaryJunk = Self.scanGroups(
                home: home,
                groups: [
                    ScanGroup(name: "Simulator Caches", relativePath: "Library/Developer/CoreSimulator/Caches"),
                    ScanGroup(name: "Device Symbols", relativePath: "Library/Developer/Xcode/iOS DeviceSupport"),
                    ScanGroup(name: "SwiftPM Repositories", relativePath: "Library/org.swift.swiftpm"),
                    ScanGroup(name: "Application Updates", relativePath: "Library/Application Support/com.apple.sharedfilelist")
                ],
                category: .binaryJunk
            )
            
            let xcodeJunk = Self.scanGroups(
                home: home,
                groups: [
                    ScanGroup(name: "DerivedData", relativePath: "Library/Developer/Xcode/DerivedData"),
                    ScanGroup(name: "Archives", relativePath: "Library/Developer/Xcode/Archives"),
                    ScanGroup(name: "Xcode Caches", relativePath: "Library/Caches/com.apple.dt.Xcode")
                ],
                category: .xcodeJunk
            )
            
            await MainActor.run {
                self.userCaches = systemJunk
                self.browserCaches = binaryJunk
                self.appCaches = xcodeJunk
                self.isScanning = false
            }
        }
    }
    
    func cleanSelected() {
        clean(items: allItems.filter { $0.isSelected })
    }
    
    func cleanCategory(_ category: CacheItem.CacheCategory) {
        clean(items: allItems.filter { $0.category == category && $0.isSelected })
    }
    
    private func clean(items selected: [CacheItem]) {
        guard !isCleaning else { return }
        guard !selected.isEmpty else { return }
        isCleaning = true
        
        Task.detached {
            let fileManager = FileManager.default
            
            for item in selected {
                try? fileManager.removeItem(atPath: item.path)
            }
            
            // 重新扫描或更新列表
            await MainActor.run {
                self.userCaches.removeAll { item in selected.contains(where: { $0.id == item.id }) }
                self.browserCaches.removeAll { item in selected.contains(where: { $0.id == item.id }) }
                self.appCaches.removeAll { item in selected.contains(where: { $0.id == item.id }) }
                self.isCleaning = false
            }
        }
    }
    
    private struct ScanGroup {
        let name: String
        let relativePath: String
    }
    
    nonisolated private static func scanGroups(home: URL, groups: [ScanGroup], category: CacheItem.CacheCategory) -> [CacheItem] {
        groups.compactMap { group in
            let url = group.relativePath.hasPrefix("/")
                ? URL(fileURLWithPath: group.relativePath)
                : home.appendingPathComponent(group.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let size = directorySize(at: url)
            guard size > 1024 * 1024 else { return nil }
            return CacheItem(name: group.name, path: url.path, size: size, category: category)
        }
        .sorted { $0.size > $1.size }
    }
    
    nonisolated private static func directorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        
        if !isDirectory.boolValue {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)) ?? 0
        }
        
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}
