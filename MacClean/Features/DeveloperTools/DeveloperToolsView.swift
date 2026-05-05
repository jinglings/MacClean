//
//  DeveloperToolsView.swift
//  MacClean
//
//  Wraps CosmicDeveloperToolsView and provides ViewModel/Models
//

import SwiftUI
import Combine

struct DeveloperToolsView: View {
    var body: some View {
        CosmicDeveloperToolsView()
    }
}

// MARK: - Models

struct DevToolItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    var isSelected: Bool = true
}

// MARK: - ViewModel

@MainActor
class DeveloperToolsViewModel: ObservableObject {
    @Published var xcodeItems: [DevToolItem] = []
    @Published var homebrewItems: [DevToolItem] = []
    @Published var npmItems: [DevToolItem] = []
    @Published var cocoapodsItems: [DevToolItem] = []
    
    @Published var isScanning: Bool = false
    @Published var isCleaning: Bool = false
    
    var totalSelectedSize: Int64 {
        let all = xcodeItems + homebrewItems + npmItems + cocoapodsItems
        return all.filter { $0.isSelected }.reduce(0) { $0 + $1.size }
    }
    
    func scanAll() {
        guard !isScanning else { return }
        isScanning = true
        
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.doScanXcode() }
                group.addTask { await self.doScanHomebrew() }
                group.addTask { await self.doScanNpm() }
                group.addTask { await self.doScanCocoapods() }
            }
            self.isScanning = false
        }
    }
    
    func cleanAll() {
        cleanXcode()
        cleanHomebrew()
        cleanNpm()
        cleanCocoapods()
    }
    
    // MARK: - Individual Actions
    
    func scanXcode() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            await doScanXcode()
            self.isScanning = false
        }
    }
    
    func cleanXcode() { cleanItems(at: \.xcodeItems) }
    
    func scanHomebrew() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            await doScanHomebrew()
            self.isScanning = false
        }
    }
    
    func cleanHomebrew() { cleanItems(at: \.homebrewItems) }
    
    func scanNpm() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            await doScanNpm()
            self.isScanning = false
        }
    }
    
    func cleanNpm() { cleanItems(at: \.npmItems) }
    
    func scanCocoapods() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            await doScanCocoapods()
            self.isScanning = false
        }
    }
    
    func cleanCocoapods() { cleanItems(at: \.cocoapodsItems) }
    
    // MARK: - Internal Logic
    
    private func doScanXcode() async {
        await scanDirectoryStub(path: "Library/Developer/Xcode/DerivedData", target: \.xcodeItems)
    }
    
    private func doScanHomebrew() async {
        await scanDirectoryStub(path: "Library/Caches/Homebrew", target: \.homebrewItems)
    }
    
    private func doScanNpm() async {
        await scanDirectoryStub(path: ".npm", target: \.npmItems)
    }
    
    private func doScanCocoapods() async {
        await scanDirectoryStub(path: "Library/Caches/CocoaPods", target: \.cocoapodsItems)
    }
    
    private func scanDirectoryStub(path: String, target: ReferenceWritableKeyPath<DeveloperToolsViewModel, [DevToolItem]>) async {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(path)
        var items: [DevToolItem] = []
        
        // 简单模拟或真实扫描
        if let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            for contentUrl in contents {
                let size = (try? contentUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)) ?? 0
                items.append(DevToolItem(
                    name: contentUrl.lastPathComponent,
                    path: contentUrl.path,
                    size: size
                ))
            }
        }
        
        // Update on MainActor
        await MainActor.run {
            self[keyPath: target] = items
        }
    }
    
    private func cleanItems(at target: ReferenceWritableKeyPath<DeveloperToolsViewModel, [DevToolItem]>) {
        guard !isCleaning else { return }
        isCleaning = true
        
        let items = self[keyPath: target]
        let selected = items.filter { $0.isSelected }
        
        Task.detached {
            let fileManager = FileManager.default
            for item in selected {
                try? fileManager.removeItem(atPath: item.path)
            }
            
            await MainActor.run {
                self[keyPath: target].removeAll { item in selected.contains(where: { $0.id == item.id }) }
                self.isCleaning = false
            }
        }
    }
}
