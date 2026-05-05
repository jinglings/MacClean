//
//  AppState.swift
//  MacClean
//
//  全局应用状态管理
//

import SwiftUI
import Combine

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()
    
    // MARK: - UI 状态
    @Published var currentTab: AppTab = .diskAnalysis
    @Published var showOnboarding: Bool = false
    @Published var showAboutWindow: Bool = false
    @Published var showLicenseActivation: Bool = false
    @Published var showSettingsWindow: Bool = false
    
    // MARK: - 扫描状态
    @Published var isScanning: Bool = false
    @Published var scanProgress: Double = 0.0
    @Published var scanStatus: String = ""
    
    // MARK: - 清理状态
    @Published var isCleaning: Bool = false
    @Published var cleanProgress: Double = 0.0
    @Published var cleanStatus: String = ""
    
    // MARK: - 磁盘信息
    @Published var diskInfo: DiskInfo?
    @Published var cleanableItems: [CleanableItem] = []
    @Published var totalCleanableSize: Int64 = 0
    
    // MARK: - 许可证状态
    @Published var isLicensed: Bool = false
    @Published var licenseType: LicenseType = .trial
    @Published var trialDaysRemaining: Int = 7
    
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        setupBindings()
    }
    
    private func setupBindings() {
        // 监听清理项目变化，更新总大小
        $cleanableItems
            .map { items in
                items.filter { $0.isSelected }.reduce(0) { $0 + $1.size }
            }
            .assign(to: &$totalCleanableSize)
    }
    
    // MARK: - Actions
    
    func startDiskScan() {
        guard !isScanning else { 
            print("已经在扫描中，忽略请求")
            return 
        }
        
        print("开始磁盘扫描...")
        isScanning = true
        scanProgress = 0.0
        scanStatus = NSLocalizedString("scanning_disk", comment: "")
        
        // 使用 detached task 在后台线程执行，避免阻塞主线程
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // 更新进度（需要在主线程）
                await MainActor.run {
                    self?.scanProgress = 0.3
                    self?.scanStatus = "正在分析磁盘..."
                }
                
                let result = try await DiskAnalyzer.shared.analyzeDisk()
                
                await MainActor.run {
                    self?.scanProgress = 1.0
                    self?.diskInfo = result.diskInfo
                    self?.cleanableItems = result.cleanableItems
                    self?.scanStatus = NSLocalizedString("scan_complete", comment: "")
                    self?.isScanning = false
                    print("扫描完成! 发现 \(result.cleanableItems.count) 个可清理项目")
                }
            } catch {
                await MainActor.run {
                    self?.scanStatus = NSLocalizedString("scan_failed", comment: "")
                    self?.isScanning = false
                    print("扫描失败: \(error)")
                }
            }
        }
    }
    
    func startQuickClean() {
        guard !isCleaning else { return }
        
        let selectedItems = cleanableItems.filter { $0.isSelected }
        guard !selectedItems.isEmpty else { return }
        
        isCleaning = true
        cleanProgress = 0.0
        cleanStatus = NSLocalizedString("cleaning", comment: "")
        
        Task {
            do {
                let result = try await CleanupManager.shared.clean(items: selectedItems) { progress in
                    Task { @MainActor in
                        self.cleanProgress = progress
                    }
                }
                self.cleanProgress = 1.0
                self.cleanStatus = String(
                    format: NSLocalizedString("clean_complete_format", comment: ""),
                    ByteCountFormatter.string(fromByteCount: result.freedSpace, countStyle: .file)
                )
                
                // 从列表中移除已清理的项目
                self.cleanableItems.removeAll { item in
                    selectedItems.contains { $0.id == item.id }
                }
                
            } catch {
                self.cleanStatus = NSLocalizedString("clean_failed", comment: "")
                print("清理失败: \(error)")
            }
            self.isCleaning = false
        }
    }
    
    func selectAllItems(_ selected: Bool) {
        for index in cleanableItems.indices {
            cleanableItems[index].isSelected = selected
        }
    }
}

// MARK: - 应用标签页
enum AppTab: String, CaseIterable, Identifiable {
    case diskAnalysis = "disk_analysis"
    case cacheCleanup = "cache_cleanup"
    case developerTools = "developer_tools"
    case appUninstaller = "app_uninstaller"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .diskAnalysis: return "chart.pie.fill"
        case .cacheCleanup: return "trash.fill"
        case .developerTools: return "hammer.fill"
        case .appUninstaller: return "app.badge.checkmark"
        }
    }
    
    var localizedName: String {
        NSLocalizedString(rawValue, comment: "")
    }
}

// MARK: - 许可证类型
enum LicenseType: String {
    case trial = "trial"
    case annual = "annual"
    case lifetime = "lifetime"
    
    var localizedName: String {
        NSLocalizedString("license_\(rawValue)", comment: "")
    }
}
