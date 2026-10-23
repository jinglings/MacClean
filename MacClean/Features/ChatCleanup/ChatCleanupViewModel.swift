//
//  ChatCleanupViewModel.swift
//  MacClean
//
//  聊天清理的状态：当前应用 / 账号、扫描结果、三级勾选（会话 → 类型 → 月份）、会话备注名、清理与撤销。
//  默认只勾选应用会自动重建的缓存与缩略图；收到的文件永远不会被预先勾选。
//

import AppKit
import Combine
import Foundation

// MARK: - 会话备注名

/// 用户给会话起的名字，只保存在本机（UserDefaults），键为「应用 | 账号 | 会话哈希」。
nonisolated struct ChatLabelStore {
    private let defaults: UserDefaults
    private let key = "ChatCleanup.conversationLabels"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(app: ChatApp, accountID: String, hash: String) -> String {
        "\(app.rawValue)|\(accountID)|\(hash)"
    }

    func all() -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    func set(_ label: String?, for labelKey: String) {
        var labels = all()
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        labels[labelKey] = trimmed.isEmpty ? nil : trimmed
        defaults.set(labels, forKey: key)
    }
}

// MARK: - ViewModel

@MainActor
final class ChatCleanupViewModel: ObservableObject {
    static let shared = ChatCleanupViewModel()

    @Published var app: ChatApp {
        didSet { if app != oldValue { resetSelection() } }
    }
    @Published private(set) var availableApps: Set<ChatApp> = []
    @Published private(set) var results: [ChatApp: ChatScanResult] = [:]
    @Published private(set) var lastScannedAt: [ChatApp: Date] = [:]
    @Published private var selectedAccountIDs: [ChatApp: String] = [:]

    @Published private(set) var isScanning = false
    @Published private(set) var scanningApp: ChatApp?
    @Published private(set) var scannedFiles = 0

    @Published private(set) var selectedBuckets: Set<String> = []
    @Published private(set) var selectedLargeFiles: Set<String> = []
    @Published var expanded: Set<String> = []
    /// 下次显示结果时滚动到的位置（ChatCleanupView.groupsAnchor 或分组 id），用后清空。
    @Published var scrollTarget: String?
    @Published private(set) var labels: [String: String] = [:]
    @Published private(set) var runningBundleIDs: Set<String> = []

    @Published private(set) var isCleaning = false
    @Published private(set) var cleanProgress: Double = 0
    @Published private(set) var lastCleanResult: CleanResult?
    @Published private(set) var lastRestoreResult: RestoreResult?

    let home: URL
    private let labelStore: ChatLabelStore
    /// 快捷筛选的「现在」，测试中固定。
    var now: () -> Date = Date.init
    /// 正在运行的应用 bundle ID，测试中替换。
    var runningApps: () -> Set<String> = {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
    private var scanTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        labelStore: ChatLabelStore = ChatLabelStore(),
        observeWorkspace: Bool = true
    ) {
        self.home = home
        self.labelStore = labelStore
        let available = ChatMediaScanner.availability(home: home)
        availableApps = available
        app = ChatApp.allCases.first { available.contains($0) } ?? .wechat
        labels = labelStore.all()
        guard observeWorkspace else { return }
        refreshRunning()
        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: center.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .sink { [weak self] _ in self?.refreshRunning() }
            .store(in: &cancellables)
    }

    // MARK: 当前结果

    var result: ChatScanResult? { results[app] }
    var hasScanned: Bool { results[app] != nil }
    var accounts: [ChatAccount] { result?.accounts ?? [] }

    var account: ChatAccount? {
        let accounts = self.accounts
        if let id = selectedAccountIDs[app], let match = accounts.first(where: { $0.id == id }) { return match }
        return accounts.first
    }

    func selectAccount(_ account: ChatAccount) {
        guard account.id != self.account?.id else { return }
        selectedAccountIDs[app] = account.id
        resetSelection()
    }

    func refreshAvailability() {
        availableApps = ChatMediaScanner.availability(home: home)
    }

    // MARK: 运行状态

    var isAppRunning: Bool { app.isRunning(among: runningBundleIDs) }

    func refreshRunning() {
        runningBundleIDs = runningApps()
    }

    func quitApp() {
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID) {
            running.terminate()
        }
    }

    // MARK: 扫描

    func scan() {
        scanTask?.cancel()
        let app = self.app
        let home = self.home
        isScanning = true
        scanningApp = app
        scannedFiles = 0
        lastRestoreResult = nil
        let ref = WeakRef(self)
        scanTask = Task.detached(priority: .userInitiated) {
            let result = try? ChatMediaScanner.scan(app: app, home: home) { count in
                Task { @MainActor in
                    guard ref.object?.scanningApp == app else { return }
                    ref.object?.scannedFiles = count
                }
            }
            let cancelled = Task.isCancelled
            await ref.object?.finishScan(app: app, result: result, cancelled: cancelled)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        scanningApp = nil
    }

    private func finishScan(app: ChatApp, result: ChatScanResult?, cancelled: Bool) {
        guard !cancelled, scanningApp == app else { return }
        isScanning = false
        scanningApp = nil
        guard let result else { return }
        apply(result)
        UsageAnalytics.shared.recordScanCompleted()
    }

    /// 写入扫描结果并恢复默认勾选（测试也直接调用）。
    func apply(_ result: ChatScanResult) {
        results[result.app] = result
        lastScannedAt[result.app] = Date()
        if let id = selectedAccountIDs[result.app], !result.accounts.contains(where: { $0.id == id }) {
            selectedAccountIDs[result.app] = nil
        }
        if result.app == app { resetSelection() }
    }

    // MARK: 勾选

    /// 默认只勾选应用会自动重建的缓存与缩略图。
    static func defaultSelection(for account: ChatAccount?) -> Set<String> {
        Set(account?.buckets.filter { $0.type.isRegenerable }.map(\.id) ?? [])
    }

    func resetSelection() {
        selectedBuckets = Self.defaultSelection(for: account)
        selectedLargeFiles = []
    }

    /// true 全选、false 未选、nil 部分选中。
    func state(of buckets: [ChatBucket]) -> Bool? {
        let selected = buckets.filter { selectedBuckets.contains($0.id) }.count
        if selected == 0 { return false }
        return selected == buckets.count ? true : nil
    }

    func toggle(_ buckets: [ChatBucket]) {
        let ids = buckets.map(\.id)
        if state(of: buckets) == true {
            selectedBuckets.subtract(ids)
        } else {
            selectedBuckets.formUnion(ids)
        }
    }

    func isSelected(_ file: ChatLargeFile) -> Bool {
        selectedLargeFiles.contains(file.path) || selectedBuckets.contains(file.bucketID)
    }

    func toggle(_ file: ChatLargeFile) {
        if selectedBuckets.contains(file.bucketID) {
            // 整个桶已选中时，取消单个文件 = 取消整个桶，其余大文件保持选中
            selectedBuckets.remove(file.bucketID)
            let siblings = account?.largeFiles.filter { $0.bucketID == file.bucketID && $0.path != file.path } ?? []
            selectedLargeFiles.formUnion(siblings.map(\.path))
            selectedLargeFiles.remove(file.path)
        } else if selectedLargeFiles.contains(file.path) {
            selectedLargeFiles.remove(file.path)
        } else {
            selectedLargeFiles.insert(file.path)
        }
    }

    // MARK: 快捷筛选

    func isActive(_ filter: ChatQuickFilter) -> Bool {
        guard let account else { return false }
        let buckets = filter.matchingBuckets(in: account, now: now())
        let files = filter.matchingLargeFiles(in: account)
        guard !buckets.isEmpty || !files.isEmpty else { return false }
        return buckets.allSatisfy { selectedBuckets.contains($0.id) } && files.allSatisfy(isSelected)
    }

    func matchSize(_ filter: ChatQuickFilter) -> Int64 {
        guard let account else { return 0 }
        return filter.matchingBuckets(in: account, now: now()).reduce(0) { $0 + $1.size }
            + filter.matchingLargeFiles(in: account).reduce(0) { $0 + $1.size }
    }

    func apply(_ filter: ChatQuickFilter) {
        guard let account else { return }
        let buckets = filter.matchingBuckets(in: account, now: now())
        let files = filter.matchingLargeFiles(in: account)
        if isActive(filter) {
            // 大文件也可能因所在的整个桶被选中而算作选中，一并取消
            selectedBuckets.subtract(buckets.map(\.id) + files.map(\.bucketID))
            selectedLargeFiles.subtract(files.map(\.path))
        } else {
            selectedBuckets.formUnion(buckets.map(\.id))
            selectedLargeFiles.formUnion(files.filter { !selectedBuckets.contains($0.bucketID) }.map(\.path))
        }
    }

    // MARK: 已选汇总

    private var looseSelectedLargeFiles: [ChatLargeFile] {
        account?.largeFiles.filter { selectedLargeFiles.contains($0.path) && !selectedBuckets.contains($0.bucketID) } ?? []
    }

    var selectedSizeByType: [ChatMediaType: Int64] {
        var sizes: [ChatMediaType: Int64] = [:]
        for bucket in account?.buckets ?? [] where selectedBuckets.contains(bucket.id) {
            sizes[bucket.type, default: 0] += bucket.size
        }
        for file in looseSelectedLargeFiles { sizes[file.type, default: 0] += file.size }
        return sizes
    }

    var selectedSize: Int64 { selectedSizeByType.values.reduce(0, +) }
    var selectedCount: Int {
        (account?.buckets.filter { selectedBuckets.contains($0.id) }.count ?? 0) + looseSelectedLargeFiles.count
    }

    var selectedTargets: [ChatCleanTarget] {
        let buckets = account?.buckets.filter { selectedBuckets.contains($0.id) } ?? []
        return buckets.flatMap(\.targets) + looseSelectedLargeFiles.map { .item($0.path) }
    }

    // MARK: 会话名称

    func label(for group: ChatGroup, in account: ChatAccount) -> String {
        switch group.kind {
        case .conversation(let hash):
            if let custom = labels[ChatLabelStore.key(app: app, accountID: account.id, hash: hash)] { return custom }
            let conversations = account.groups.filter { $0.conversationHash != nil }
            let index = (conversations.firstIndex { $0.id == group.id } ?? 0) + 1
            return String(localized: "会话 \(index)")
        case .month(let month):
            return month.start().formatted(.dateTime.year().month(.wide))
        case .shared:
            return account.isLegacy ? String(localized: "所有会话共用") : String(localized: "视频、文件与缓存")
        }
    }

    func hasCustomLabel(_ group: ChatGroup, in account: ChatAccount) -> Bool {
        guard let hash = group.conversationHash else { return false }
        return labels[ChatLabelStore.key(app: app, accountID: account.id, hash: hash)] != nil
    }

    func rename(_ group: ChatGroup, in account: ChatAccount, to label: String?) {
        guard let hash = group.conversationHash else { return }
        labelStore.set(label, for: ChatLabelStore.key(app: app, accountID: account.id, hash: hash))
        labels = labelStore.all()
    }

    // MARK: 清理

    enum CleanOutcome: Equatable { case cleaned, blockedByRunningApp, nothingSelected }

    @discardableResult
    func cleanSelected() async -> CleanOutcome {
        guard !isCleaning else { return .nothingSelected }
        // 确认框弹出期间用户可能又打开了聊天应用：动手前再查一次
        refreshRunning()
        guard !isAppRunning else { return .blockedByRunningApp }
        let targets = selectedTargets
        guard !targets.isEmpty else { return .nothingSelected }

        isCleaning = true
        cleanProgress = 0
        lastRestoreResult = nil
        let items = await Task.detached(priority: .userInitiated) {
            ChatMediaScanner.cleanableItems(for: targets)
        }.value

        do {
            lastCleanResult = try await CleanupManager.shared.clean(items: items) { progress in
                Task { @MainActor [weak self] in self?.cleanProgress = progress }
            }
        } catch {
            lastCleanResult = CleanResult(
                freedSpace: 0, cleanedItems: 0, duration: 0,
                errors: [CleanError(path: "", error: error, message: error.localizedDescription)]
            )
        }
        isCleaning = false
        scan()
        return .cleaned
    }

    func undoLastClean() async {
        guard let sessionID = lastCleanResult?.historySessionID else { return }
        lastRestoreResult = await CleanupManager.shared.restore(sessionID: sessionID)
        lastCleanResult = nil
        scan()
    }
}
