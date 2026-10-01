//
//  PrivacyViewModel.swift
//  MacClean
//
//  隐私清理页的状态：扫描结果、勾选、浏览器运行状态、清理与撤销。
//

import AppKit
import Combine

@MainActor
final class PrivacyViewModel: ObservableObject {
    static let shared = PrivacyViewModel()

    @Published private(set) var result = PrivacyScanResult()
    @Published private(set) var hasScanned = false
    @Published private(set) var isScanning = false
    @Published private(set) var lastScannedAt: Date?
    /// 默认什么都不选：隐私数据的删除都有副作用（退出登录、丢失会话），由用户自己勾选。
    @Published var selectedIDs: Set<String> = []
    @Published private(set) var runningBrowsers: Set<PrivacyBrowser> = []

    @Published private(set) var isCleaning = false
    @Published private(set) var cleanProgress: Double = 0
    @Published private(set) var lastCleanResult: CleanResult?
    @Published private(set) var lastRestoreResult: RestoreResult?

    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunningBrowsers() }
            })
        }
        refreshRunningBrowsers()
    }

    // MARK: - 派生数据

    /// 有数据的浏览器分组，按固定顺序。
    var browsers: [PrivacyBrowser] {
        PrivacyBrowser.allCases.filter { result.browsersWithData.contains($0) }
    }

    func entries(for browser: PrivacyBrowser) -> [PrivacyEntry] {
        result.entries.filter { $0.browser == browser }
    }

    var selectedEntries: [PrivacyEntry] {
        result.entries.filter { selectedIDs.contains($0.id) && !runningBrowsers.contains($0.browser) }
    }

    var selectedSize: Int64 { selectedEntries.reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { result.entries.reduce(0) { $0 + $1.size } }

    func isSelected(_ entry: PrivacyEntry) -> Bool { selectedIDs.contains(entry.id) }

    func setSelected(_ entry: PrivacyEntry, _ selected: Bool) {
        if selected { selectedIDs.insert(entry.id) } else { selectedIDs.remove(entry.id) }
    }

    func setSelection(browser: PrivacyBrowser, selected: Bool) {
        for entry in entries(for: browser) {
            setSelected(entry, selected)
        }
    }

    // MARK: - 扫描

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        lastRestoreResult = nil
        refreshRunningBrowsers()
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                PrivacyScanner.scan()
            }.value
            self.result = result
            // 只保留仍然存在的勾选
            let ids = Set(result.entries.map(\.id))
            selectedIDs.formIntersection(ids)
            hasScanned = true
            isScanning = false
            lastScannedAt = Date()
        }
    }

    // MARK: - 浏览器运行状态

    func refreshRunningBrowsers() {
        var running: Set<PrivacyBrowser> = []
        for browser in PrivacyBrowser.allCases {
            guard let id = browser.bundleIdentifier else { continue }
            if !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
                running.insert(browser)
            }
        }
        runningBrowsers = running
    }

    func quit(_ browser: PrivacyBrowser) {
        guard let id = browser.bundleIdentifier else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
            app.terminate()
        }
        // 退出通知会刷新状态；应用弹出「确定退出？」时也能在稍后补刷一次
        Task {
            try? await Task.sleep(for: .seconds(2))
            refreshRunningBrowsers()
        }
    }

    // MARK: - 清理

    func cleanSelected() async {
        // 清理前再确认一次运行状态，刚打开的浏览器不能删它的数据库
        refreshRunningBrowsers()
        let entries = selectedEntries
        guard !entries.isEmpty else { return }

        isCleaning = true
        cleanProgress = 0
        lastRestoreResult = nil

        let items = await Task.detached(priority: .userInitiated) {
            PrivacyScanner.cleanableItems(for: entries)
        }.value
        let result = try? await CleanupManager.shared.clean(items: items) { [weak self] progress in
            Task { @MainActor in self?.cleanProgress = progress }
        }
        lastCleanResult = result
        selectedIDs.subtract(entries.map(\.id))
        isCleaning = false
        await rescanQuietly()
    }

    func undoLastClean() async {
        guard let sessionID = lastCleanResult?.historySessionID else { return }
        lastRestoreResult = await CleanupManager.shared.restore(sessionID: sessionID)
        lastCleanResult = nil
        await rescanQuietly()
    }

    private func rescanQuietly() async {
        let result = await Task.detached(priority: .userInitiated) {
            PrivacyScanner.scan()
        }.value
        self.result = result
        selectedIDs.formIntersection(Set(result.entries.map(\.id)))
        lastScannedAt = Date()
    }
}
