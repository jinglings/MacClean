//
//  DiskAlertScheduler.swift
//  MacClean
//
//  后台提醒：磁盘空间不足、定期清理。
//  判断逻辑全部放在 DiskAlertPolicy（纯函数，单元测试覆盖），调度器只负责取数、存状态、发通知。
//

import AppKit
import Combine
import Foundation
import UserNotifications
import os

// MARK: - 设置项

nonisolated enum LowDiskThreshold: String, CaseIterable, Identifiable, Sendable {
    case gb10
    case gb20
    case percent10

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gb10: return String(localized: "少于 10 GB")
        case .gb20: return String(localized: "少于 20 GB")
        case .percent10: return String(localized: "少于 10%")
        }
    }
}

nonisolated enum CleanupReminderInterval: String, CaseIterable, Identifiable, Sendable {
    case off
    case weekly
    case biweekly
    case monthly

    var id: String { rawValue }

    nonisolated var days: Int {
        switch self {
        case .off: return 0
        case .weekly: return 7
        case .biweekly: return 14
        case .monthly: return 30
        }
    }

    var title: String {
        switch self {
        case .off: return String(localized: "不提醒")
        case .weekly: return String(localized: "每周")
        case .biweekly: return String(localized: "每两周")
        case .monthly: return String(localized: "每月")
        }
    }
}

/// UserDefaults 键（设置页用 @AppStorage 绑定同名键）
nonisolated enum NotificationSettingsKey {
    static let lowDiskEnabled = "lowDiskAlertEnabled"
    static let lowDiskThreshold = "lowDiskThreshold"
    static let cleanupReminder = "cleanupReminderInterval"

    // 内部状态
    static let lowDiskArmed = "lowDiskAlertArmed"
    static let lowDiskLastAlertAt = "lowDiskLastAlertAt"
    static let reminderLastFiredAt = "cleanupReminderLastFiredAt"
    static let firstLaunchAt = "firstLaunchAt"
}

// MARK: - 判断逻辑（纯函数）

nonisolated struct LowDiskAlertState: Equatable, Sendable {
    /// 上次提醒后空间是否已恢复到阈值以上（恢复后才允许再次提醒）
    var armed = true
    var lastAlertAt: Date?
}

nonisolated enum DiskAlertPolicy {
    nonisolated static let alertCooldown: TimeInterval = 24 * 3600

    nonisolated static func isLow(available: Int64, total: Int64, threshold: LowDiskThreshold) -> Bool {
        let gb: Int64 = 1_000_000_000
        switch threshold {
        case .gb10: return available < 10 * gb
        case .gb20: return available < 20 * gb
        case .percent10:
            guard total > 0 else { return false }
            return Double(available) / Double(total) < 0.10
        }
    }

    /// 返回是否应发出低空间提醒，以及更新后的状态。
    /// 规则：低于阈值且已「上膛」且距上次提醒满 24 小时才提醒；提醒后需先恢复到阈值以上才会再次上膛。
    nonisolated static func evaluateLowDisk(
        available: Int64,
        total: Int64,
        threshold: LowDiskThreshold,
        state: LowDiskAlertState,
        now: Date
    ) -> (notify: Bool, state: LowDiskAlertState) {
        var next = state
        guard isLow(available: available, total: total, threshold: threshold) else {
            next.armed = true
            return (false, next)
        }
        guard state.armed else { return (false, next) }
        if let last = state.lastAlertAt, now.timeIntervalSince(last) < alertCooldown {
            return (false, next)
        }
        next.armed = false
        next.lastAlertAt = now
        return (true, next)
    }

    /// 定期清理提醒是否到期：距「上次清理 / 上次提醒 / 首次启动」中最近的一个满 N 天。
    nonisolated static func isCleanupReminderDue(
        interval: CleanupReminderInterval,
        lastCleanup: Date?,
        lastReminder: Date?,
        firstLaunch: Date,
        now: Date
    ) -> Bool {
        guard interval.days > 0 else { return false }
        let reference = [lastCleanup, lastReminder, firstLaunch].compactMap { $0 }.max() ?? firstLaunch
        return now.timeIntervalSince(reference) >= TimeInterval(interval.days) * 86_400
    }

    nonisolated static func daysBetween(_ from: Date, _ to: Date) -> Int {
        max(0, Int(to.timeIntervalSince(from) / 86_400))
    }

    nonisolated static func cleanupReminderBody(lastCleanup: Date?, now: Date) -> String {
        guard let lastCleanup else { return String(localized: "还没有清理过，看看能释放多少空间？") }
        let days = daysBetween(lastCleanup, now)
        return days == 0 ? String(localized: "看看现在能释放多少空间？") : String(localized: "上次清理是 \(days) 天前，看看能释放多少空间？")
    }
}

// MARK: - 调度器

@MainActor
final class DiskAlertScheduler: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = DiskAlertScheduler()

    /// 系统通知授权状态（设置页 / 引导页展示）
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "com.macclean", category: "DiskAlert")
    private var timer: Timer?
    private static let checkInterval: TimeInterval = 30 * 60
    nonisolated private static let actionKey = "action"

    private var center: UNUserNotificationCenter { .current() }

    private override init() {
        super.init()
    }

    func start() {
        guard timer == nil else { return }
        center.delegate = self
        defaults.register(defaults: [
            NotificationSettingsKey.lowDiskEnabled: true,
            NotificationSettingsKey.lowDiskThreshold: LowDiskThreshold.gb10.rawValue,
            NotificationSettingsKey.cleanupReminder: CleanupReminderInterval.off.rawValue,
            NotificationSettingsKey.lowDiskArmed: true,
        ])
        if defaults.object(forKey: NotificationSettingsKey.firstLaunchAt) == nil {
            defaults.set(Date(), forKey: NotificationSettingsKey.firstLaunchAt)
        }

        Task {
            await refreshAuthorizationStatus()
            // 引导完成后的首次启动：已开启提醒但还没问过授权，就在这里问
            if defaults.bool(forKey: OnboardingKeys.hasCompleted),
               defaults.bool(forKey: NotificationSettingsKey.lowDiskEnabled),
               authorizationStatus == .notDetermined {
                _ = await requestAuthorization()
            }
        }

        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { _ in
            Task { @MainActor in DiskAlertScheduler.shared.runChecks() }
        }
        timer.tolerance = 5 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // 启动稍后先检查一次，避开启动高峰
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.runChecks()
        }
    }

    // MARK: 授权

    func refreshAuthorizationStatus() async {
        authorizationStatus = await center.notificationSettings().authorizationStatus
    }

    /// 用户开启某个通知设置时调用；已决定过的状态不会再弹窗。
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            await refreshAuthorizationStatus()
            return granted
        } catch {
            logger.error("请求通知授权失败: \(error.localizedDescription, privacy: .public)")
            await refreshAuthorizationStatus()
            return false
        }
    }

    static func openSystemNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 检查

    func runChecks() {
        checkLowDisk()
        checkCleanupReminder()
    }

    private func checkLowDisk() {
        guard defaults.bool(forKey: NotificationSettingsKey.lowDiskEnabled) else { return }
        let threshold = LowDiskThreshold(rawValue: defaults.string(forKey: NotificationSettingsKey.lowDiskThreshold) ?? "") ?? .gb10
        Task {
            let stats = await Task.detached(priority: .utility) { SystemStats.disk() }.value
            guard let stats else { return }
            let state = LowDiskAlertState(
                armed: defaults.bool(forKey: NotificationSettingsKey.lowDiskArmed),
                lastAlertAt: defaults.object(forKey: NotificationSettingsKey.lowDiskLastAlertAt) as? Date
            )
            let result = DiskAlertPolicy.evaluateLowDisk(
                available: stats.available, total: stats.total, threshold: threshold, state: state, now: Date()
            )
            guard result.notify else {
                defaults.set(result.state.armed, forKey: NotificationSettingsKey.lowDiskArmed)
                return
            }
            // 只有真正发出了通知才消耗这次提醒
            guard await post(
                id: "low-disk",
                title: String(localized: "磁盘空间不足"),
                body: String(localized: "「\(stats.volumeName)」仅剩 \(ByteCountFormatter.string(fromByteCount: stats.available, countStyle: .file)) 可用，点按查看可释放的空间。"),
                action: AppTab.cacheCleanup
            ) else { return }
            defaults.set(result.state.armed, forKey: NotificationSettingsKey.lowDiskArmed)
            defaults.set(result.state.lastAlertAt, forKey: NotificationSettingsKey.lowDiskLastAlertAt)
        }
    }

    private func checkCleanupReminder() {
        let interval = CleanupReminderInterval(rawValue: defaults.string(forKey: NotificationSettingsKey.cleanupReminder) ?? "") ?? .off
        guard interval != .off else { return }
        let firstLaunch = defaults.object(forKey: NotificationSettingsKey.firstLaunchAt) as? Date ?? Date()
        let lastReminder = defaults.object(forKey: NotificationSettingsKey.reminderLastFiredAt) as? Date
        Task {
            let lastCleanup = await Task.detached(priority: .utility) {
                CleanupHistoryStore.shared.sessions().map(\.date).max()
            }.value
            let now = Date()
            guard DiskAlertPolicy.isCleanupReminderDue(
                interval: interval, lastCleanup: lastCleanup, lastReminder: lastReminder, firstLaunch: firstLaunch, now: now
            ) else { return }
            guard await post(
                id: "cleanup-reminder",
                title: String(localized: "该给 Mac 做个体检了"),
                body: DiskAlertPolicy.cleanupReminderBody(lastCleanup: lastCleanup, now: now),
                action: AppTab.smartCare
            ) else { return }
            defaults.set(now, forKey: NotificationSettingsKey.reminderLastFiredAt)
        }
    }

    private func post(id: String, title: String, body: String, action: AppTab) async -> Bool {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [Self.actionKey: action.rawValue]
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            return true
        } catch {
            logger.error("发送通知失败: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let raw = response.notification.request.content.userInfo[Self.actionKey] as? String
        await MainActor.run {
            guard let raw, let tab = AppTab(rawValue: raw) else {
                AppState.shared.openMainWindow()
                return
            }
            if tab == .smartCare {
                AppState.shared.startSmartCareScan()
            } else {
                AppState.shared.openMainWindow(tab: tab)
            }
        }
    }
}
