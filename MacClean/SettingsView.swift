//
//  SettingsView.swift
//  MacClean
//
//  设置窗口：通用 / 通知 / 许可证 / 关于
//

import SwiftUI
import ServiceManagement
import UserNotifications

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }

            NotificationSettingsView()
                .tabItem { Label("通知", systemImage: "bell.badge") }

            LicenseSettingsView()
                .tabItem { Label("许可证", systemImage: "key") }

            AboutView()
                .frame(width: 520, height: 360)
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .tint(AppTheme.accent)
    }
}

// MARK: - 外观

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .light: return String(localized: "浅色")
        case .dark: return String(localized: "深色")
        }
    }

    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    /// 用 NSApp.appearance 统一作用于主窗口、菜单栏面板与设置窗口
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - 语言

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    private static let appleLanguagesKey = "AppleLanguages"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    /// 只看本应用域里的覆盖值（UserDefaults.standard 会回落到全局语言列表）
    static var stored: AppLanguage {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: bundleID)?[appleLanguagesKey] as? [String],
              let first = languages.first else { return .system }
        return AppLanguage(rawValue: first) ?? .system
    }

    func store() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: Self.appleLanguagesKey)
        } else {
            UserDefaults.standard.set([rawValue], forKey: Self.appleLanguagesKey)
        }
    }

    /// 写入后，下次启动实际会用的本地化
    static var effectiveAfterRelaunch: String? {
        Bundle.preferredLocalizations(
            from: Bundle.main.localizations,
            forPreferences: UserDefaults.standard.stringArray(forKey: appleLanguagesKey)
        ).first
    }

    static var needsRelaunch: Bool {
        effectiveAfterRelaunch != Bundle.main.preferredLocalizations.first
    }

    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: - 通用

struct GeneralSettingsView: View {
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @AppStorage(SensorSettingsKey.showTemperatureInMenuBar) private var showsTemperatureInMenuBar = false
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @ObservedObject private var updater = AppUpdater.shared
    @ObservedObject private var usage = UsageAnalytics.shared

    @State private var launchAtLogin = false
    @State private var loginItemStatus: SMAppService.Status = .notRegistered
    @State private var loginItemError: String?
    @State private var language = AppLanguage.stored
    @State private var needsRelaunch = AppLanguage.needsRelaunch

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时打开 MacClean", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if loginItemStatus == .requiresApproval {
                    hintRow(String(localized: "需要在「系统设置 → 通用 → 登录项」中允许 MacClean。"), color: AppTheme.warning) {
                        Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginItemError {
                    hintRow(loginItemError, color: AppTheme.danger) { EmptyView() }
                }

                Toggle(isOn: $showInMenuBar) {
                    Text("在菜单栏显示")
                    Text("快速查看磁盘、内存与网络状态")
                }
                Toggle(isOn: $showsTemperatureInMenuBar) {
                    Text("在菜单栏图标旁显示 CPU 温度")
                    Text("每分钟读取一次传感器，只读")
                }
                .disabled(!showInMenuBar)
            }

            Section("外观与语言") {
                Picker("外观", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, _ in AppAppearance.current.apply() }

                Picker("语言", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: language) { _, newValue in
                    newValue.store()
                    needsRelaunch = AppLanguage.needsRelaunch
                }

                if needsRelaunch {
                    hintRow(String(localized: "重启 MacClean 后生效"), color: AppTheme.accent) {
                        Button("立即重启") { AppLanguage.relaunch() }
                    }
                }
            }

            Section("隐私") {
                Toggle("分享使用统计", isOn: Binding(get: { usage.isEnabled }, set: { usage.setEnabled($0) }))
                Text("默认关闭。开启后发送随机安装标识、应用与系统版本，以及首次打开、每日活跃和首次完成扫描的事件时间。不包含文件信息、扫描结果或许可证；关闭会停止上报并清空未发送事件。")
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
                Link("查看隐私政策", destination: UsageAnalytics.privacyURL)
            }

            Section("更新") {
                Toggle("自动检查更新", isOn: $updater.automaticallyChecksForUpdates)
                    .disabled(!updater.isConfigured)
                if !updater.isConfigured {
                    hintRow(String(localized: "自动更新将在正式版中启用"), color: AppTheme.textMuted) { EmptyView() }
                }
                HStack {
                    Text("当前版本 \(AppVersionInfo.version)（\(AppVersionInfo.build)）")
                        .foregroundColor(AppTheme.textSecondary)
                    Spacer()
                    Button("立即检查更新") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 460)
        .onAppear(perform: refreshLoginItemStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginItemStatus()
        }
    }

    private func hintRow<Trailing: View>(_ text: String, color: Color, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            trailing()
        }
    }

    private func refreshLoginItemStatus() {
        loginItemStatus = SMAppService.mainApp.status
        launchAtLogin = loginItemStatus == .enabled || loginItemStatus == .requiresApproval
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = enabled
                ? String(localized: "无法添加登录项：\(error.localizedDescription)")
                : String(localized: "无法移除登录项：\(error.localizedDescription)")
        }
        refreshLoginItemStatus()
    }
}

// MARK: - 通知

struct NotificationSettingsView: View {
    @AppStorage(NotificationSettingsKey.lowDiskEnabled) private var lowDiskEnabled = true
    @AppStorage(NotificationSettingsKey.lowDiskThreshold) private var lowDiskThreshold = LowDiskThreshold.gb10.rawValue
    @AppStorage(NotificationSettingsKey.cleanupReminder) private var cleanupReminder = CleanupReminderInterval.off.rawValue
    @ObservedObject private var scheduler = DiskAlertScheduler.shared

    var body: some View {
        Form {
            if scheduler.authorizationStatus == .denied {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.slash.fill")
                            .foregroundColor(AppTheme.warning)
                        Text("系统已关闭 MacClean 的通知，以下提醒不会显示。")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.textSecondary)
                        Spacer()
                        Button("打开通知设置") { DiskAlertScheduler.openSystemNotificationSettings() }
                    }
                }
            }

            Section {
                Toggle(isOn: $lowDiskEnabled) {
                    Text("磁盘空间不足提醒")
                    Text("每 30 分钟检查一次启动盘，24 小时内最多提醒一次")
                }
                .onChange(of: lowDiskEnabled) { _, enabled in
                    if enabled { requestAuthorization() }
                }

                Picker("可用空间", selection: $lowDiskThreshold) {
                    ForEach(LowDiskThreshold.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .disabled(!lowDiskEnabled)
            } header: {
                Text("磁盘空间")
            }

            Section {
                Picker(selection: $cleanupReminder) {
                    ForEach(CleanupReminderInterval.allCases) { Text($0.title).tag($0.rawValue) }
                } label: {
                    Text("定期清理提醒")
                    Text("距上次清理满所选时间后提醒你做一次体检")
                }
                .onChange(of: cleanupReminder) { _, value in
                    if value != CleanupReminderInterval.off.rawValue { requestAuthorization() }
                }
            } header: {
                Text("定期清理")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 360)
        .task { await scheduler.refreshAuthorizationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await scheduler.refreshAuthorizationStatus() }
        }
    }

    private func requestAuthorization() {
        Task { await scheduler.requestAuthorization() }
    }
}

// MARK: - 许可证

struct LicenseSettingsView: View {
    var body: some View {
        ScrollView {
            LicenseStatusView()
                .padding(24)
        }
        .frame(width: 520, height: 420)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState.shared)
}
