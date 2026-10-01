//
//  AppState.swift
//  MacClean
//
//  全局应用状态管理
//

import SwiftUI
import Combine
import os

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()
    
    // MARK: - UI 状态
    @Published var currentTab: AppTab = .diskAnalysis
    @Published var showOnboarding: Bool = false
    @Published var showLicenseActivation: Bool = false
    /// 置为 true 即打开系统「设置」窗口（由 AppShellActions 响应后复位，不再以 sheet 呈现）
    @Published var showSettingsWindow: Bool = false
    /// 由菜单栏快速搜索带过来的关键词，「文件搜索」页面读取后清空。
    @Published var pendingSearchTerm: String?
    
    // MARK: - 磁盘信息
    @Published var diskInfo: DiskInfo?
    
    // MARK: - 许可证状态
    @Published var isLicensed: Bool = false
    @Published var licenseType: LicenseType = .trial
    @Published var trialDaysRemaining: Int = 7
    
    /// 由任一 SwiftUI 场景注入，供菜单命令 / 通知回调等非视图上下文重新打开主窗口
    var openWindowAction: OpenWindowAction?

    private init() {}
    
    // MARK: - 窗口

    /// 切换到指定页面并把主窗口带到前台；主窗口已关闭时重新打开。
    func openMainWindow(tab: AppTab? = nil) {
        if let tab { currentTab = tab }
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(id: "main")
        }
    }

    /// 打开「一键体检」并开始扫描（菜单 ⌘⇧K、引导页、定期提醒通知共用）。
    func startSmartCareScan() {
        openMainWindow(tab: .smartCare)
        PageModelStore.shared.smartCare.scanAll()
    }

    /// 读取启动盘容量（Finder 口径的可用空间，含可自动清除的部分），毫秒级，可频繁调用。
    func refreshDiskInfo() {
        Task.detached(priority: .utility) {
            guard let stats = SystemStats.disk() else { return }
            let info = DiskInfo(volumeName: stats.volumeName, totalSpace: stats.total, freeSpace: stats.available)
            await MainActor.run { AppState.shared.diskInfo = info }
        }
    }
}

// MARK: - 应用标签页
enum AppTab: String, CaseIterable, Identifiable {
    case smartCare = "smart_care"
    case diskAnalysis = "disk_analysis"
    case cacheCleanup = "cache_cleanup"
    case largeOldFiles = "large_old_files"
    case similarPhotos = "similar_photos_tab"
    case appStorage = "app_storage"
    case fileSearch = "file_search"
    case developerTools = "developer_tools"
    case privacy = "privacy_cleanup"
    case loginItems = "login_items"
    case maintenance = "maintenance"
    case recovery = "file_recovery"
    case appUninstaller = "app_uninstaller"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .smartCare: return "checkmark.seal"
        case .diskAnalysis: return "chart.pie"
        case .cacheCleanup: return "trash"
        case .largeOldFiles: return "doc.badge.clock"
        case .similarPhotos: return "photo.on.rectangle.angled"
        case .appStorage: return "shippingbox"
        case .fileSearch: return "magnifyingglass"
        case .developerTools: return "hammer"
        case .privacy: return "hand.raised"
        case .loginItems: return "power"
        case .maintenance: return "wrench.and.screwdriver"
        case .recovery: return "clock.arrow.circlepath"
        case .appUninstaller: return "square.grid.2x2"
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
