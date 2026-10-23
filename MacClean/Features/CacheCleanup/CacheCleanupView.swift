//
//  CacheCleanupView.swift
//  MacClean
//
//  「释放空间」与「开发缓存」共用的分组清理 ViewModel。
//  每个分组各自在后台并发扫描、增量回填；清理统一走 CleanupManager（PathGuard 校验 + 移入废纸篓 + 清理记录）。
//

import SwiftUI
import Combine

// MARK: - 分组定义

struct CleanGroupDescriptor: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    /// 卡片上用语义红强调的风险提示（如「永久删除」）。
    let riskNote: String?
    /// 后台线程执行的同步扫描函数（必须只调用 nonisolated 代码）。
    let scan: @Sendable (URL) -> [CleanableItem]
    /// 展开分组后列表顶部的提示。
    var hint: String? = nil
    /// 条目行显示上次修改时间。
    var showsLastModified = false
    /// 某个应用运行时锁定本组的部分条目，需先退出。
    var runningApp: RunningAppGuard? = nil
    /// 清理前在后台把选中条目展开为真正要移走的路径（如 Ollama 模型 → 清单 + 不再被引用的数据块）。
    var prepareForCleaning: (@Sendable ([CleanableItem]) -> [CleanableItem])? = nil
}

/// 应用运行时不能安全删除它正在使用的文件：锁定 lockedPaths 下的条目，并提供「退出」按钮。
struct RunningAppGuard: Sendable {
    let appName: String
    let lockedPaths: [String]
    let isRunning: @Sendable () -> Bool
    let quit: @Sendable () -> Void

    func locks(_ path: String) -> Bool {
        lockedPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

struct CleanGroupState: Identifiable {
    let descriptor: CleanGroupDescriptor
    var items: [CleanableItem] = []
    var isScanning = false
    var hasScanned = false
    /// descriptor.runningApp 对应的应用正在运行
    var isAppRunning = false

    var id: String { descriptor.id }
    func isLocked(_ item: CleanableItem) -> Bool {
        isAppRunning && descriptor.runningApp?.locks(item.path) == true
    }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { items.filter(\.isSelected).reduce(0) { $0 + $1.size } }
    var selectedCount: Int { items.filter(\.isSelected).count }
}

extension CleanGroupDescriptor {
    /// 「释放空间」页面的分组。
    static var reclaimGroups: [CleanGroupDescriptor] {
        JunkGroupID.allCases.map { group in
            CleanGroupDescriptor(
                id: group.rawValue,
                title: group.title,
                subtitle: group.subtitle,
                icon: group.icon,
                riskNote: group.riskNote,
                scan: { home in JunkScanner.scan(group, home: home) }
            )
        }
    }

    /// 「开发缓存」页面的分组：各生态缓存 + 长期未动项目的依赖目录。
    static var devGroups: [CleanGroupDescriptor] {
        let caches = DevEcosystem.allCases.map { ecosystem in
            CleanGroupDescriptor(
                id: ecosystem.rawValue,
                title: ecosystem.title,
                subtitle: ecosystem.subtitle,
                icon: ecosystem.icon,
                riskNote: nil,
                scan: { home in DevCacheCatalog.scan(ecosystem, home: home) }
            )
        }
        let projects = CleanGroupDescriptor(
            id: "projectArtifacts",
            title: String(localized: "闲置项目的依赖与构建产物"),
            subtitle: String(localized: "超过 30 天未修改的项目里的 node_modules、Pods、target、.build、.venv 等；超过 90 天的默认勾选。"),
            icon: "folder.badge.gearshape",
            riskNote: nil,
            scan: { home in ProjectArtifactFinder.find(home: home) }
        )
        let locations = AIModelLocations.resolve(home: FileManager.default.homeDirectoryForCurrentUser, environment: AIModelLocations.currentEnvironment)
        let aiModels = CleanGroupDescriptor(
            id: "aiModels",
            title: String(localized: "本地 AI 模型"),
            subtitle: String(localized: "Ollama、Hugging Face、LM Studio 等下载到本机的模型"),
            icon: "brain",
            riskNote: String(localized: "删除后需要重新下载"),
            scan: { home in AIModelCatalog.scan(home: home) },
            hint: String(localized: "长期没用的大模型最值得清理；删除后用到时会自动重新下载"),
            showsLastModified: true,
            runningApp: RunningAppGuard(
                appName: "Ollama",
                lockedPaths: locations.ollamaModels,
                isRunning: { OllamaProcess.isRunning() },
                quit: { OllamaProcess.quit() }
            ),
            prepareForCleaning: { AIModelCatalog.prepareForCleaning($0) }
        )
        return [projects, aiModels] + caches
    }
}

// MARK: - 跨并发域的弱引用

/// 后台扫描的进度回调需要弱引用 ViewModel；以 let 常量捕获此盒子，避免「捕获可变 weak var」的并发告警。
nonisolated final class WeakRef<Object: AnyObject>: @unchecked Sendable {
    weak var object: Object?
    init(_ object: Object) { self.object = object }
}

// MARK: - ViewModel

@MainActor
final class CleanGroupsViewModel: ObservableObject {
    @Published var groups: [CleanGroupState]
    @Published var isCleaning = false
    @Published var cleanProgress: Double = 0
    @Published var lastCleanResult: CleanResult?
    @Published var lastRestoreResult: RestoreResult?
    /// 展开的分组；放在 ViewModel 里，切换侧栏后回来仍保持展开状态
    @Published var expandedGroupIDs: Set<String> = []
    /// 最近一次全部分组扫描完成的时间
    @Published private(set) var lastScannedAt: Date?

    private let home: URL
    private var cancellables: Set<AnyCancellable> = []
    /// 每次触发扫描递增，旧扫描的回调据此丢弃，避免重新扫描时新旧结果互相覆盖。
    private var scanGeneration: [String: Int] = [:]

    init(descriptors: [CleanGroupDescriptor], home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.groups = descriptors.map { CleanGroupState(descriptor: $0) }
        self.home = home
        if descriptors.contains(where: { $0.runningApp != nil }) {
            let center = NSWorkspace.shared.notificationCenter
            Publishers.Merge(
                center.publisher(for: NSWorkspace.didLaunchApplicationNotification),
                center.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshRunningApps() }
            .store(in: &cancellables)
        }
    }

    var isScanning: Bool { groups.contains(where: \.isScanning) }
    var hasScanned: Bool { groups.contains(where: \.hasScanned) }
    var allItems: [CleanableItem] { groups.flatMap(\.items) }
    var selectedItems: [CleanableItem] { allItems.filter(\.isSelected) }
    var totalSize: Int64 { groups.reduce(0) { $0 + $1.totalSize } }
    var selectedSize: Int64 { groups.reduce(0) { $0 + $1.selectedSize } }

    /// 已选项目中会被永久删除（不可恢复）的部分。
    var permanentSelectedSize: Int64 {
        selectedItems.filter { !$0.category.isRecoverable }.reduce(0) { $0 + $1.size }
    }

    // MARK: - 扫描

    func scanAll() {
        refreshRunningApps()
        for group in groups { scan(groupID: group.id) }
    }

    func scan(groupID: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let generation = (scanGeneration[groupID] ?? 0) + 1
        scanGeneration[groupID] = generation
        groups[index].isScanning = true

        let scan = groups[index].descriptor.scan
        let home = self.home
        Task.detached(priority: .userInitiated) { [weak self] in
            let items = IgnoreList.filter(scan(home))
            await self?.applyScan(items, groupID: groupID, generation: generation)
        }
    }

    private func applyScan(_ items: [CleanableItem], groupID: String, generation: Int) {
        guard scanGeneration[groupID] == generation,
              let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].items = items
        groups[index].isScanning = false
        groups[index].hasScanned = true
        if !isScanning {
            lastScannedAt = Date()
            UsageAnalytics.shared.recordScanCompleted()
        }
        refreshRunningApps()
    }

    // MARK: - 运行中的应用

    /// 刷新各分组关联应用的运行状态；运行中时取消勾选被锁定的条目。
    func refreshRunningApps() {
        for index in groups.indices {
            guard let runningApp = groups[index].descriptor.runningApp else { continue }
            let running = runningApp.isRunning()
            if groups[index].isAppRunning != running { groups[index].isAppRunning = running }
            guard running else { continue }
            for itemIndex in groups[index].items.indices where groups[index].items[itemIndex].isSelected
                && runningApp.locks(groups[index].items[itemIndex].path) {
                groups[index].items[itemIndex].isSelected = false
            }
        }
    }

    func quitRunningApp(groupID: String) {
        guard let runningApp = groups.first(where: { $0.id == groupID })?.descriptor.runningApp else { return }
        runningApp.quit()
        // 后台服务进程不发应用退出通知；应用弹出确认框时也能在稍后补刷一次
        Task {
            try? await Task.sleep(for: .seconds(2))
            refreshRunningApps()
        }
    }

    // MARK: - 选择

    func setSelection(groupID: String, selected: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let group = groups[index]
        for itemIndex in group.items.indices {
            groups[index].items[itemIndex].isSelected = selected && !group.isLocked(group.items[itemIndex])
        }
    }

    /// 加入「始终忽略」并立即从列表移除。
    func ignore(_ item: CleanableItem) {
        IgnoreList.add(item.path)
        for index in groups.indices {
            groups[index].items.removeAll { IgnoreList.isIgnored($0.path, in: [item.path]) }
        }
    }

    // MARK: - 清理

    func cleanSelected() async {
        guard !isCleaning else { return }
        // 清理前再确认一次运行状态，刚打开的应用不能删它正在用的文件
        refreshRunningApps()
        let affectedGroups = groups.filter { $0.selectedCount > 0 }
        guard !affectedGroups.isEmpty else { return }

        isCleaning = true
        cleanProgress = 0
        lastRestoreResult = nil

        var selected: [CleanableItem] = []
        for group in affectedGroups {
            let items = group.items.filter(\.isSelected)
            if let prepare = group.descriptor.prepareForCleaning {
                selected += await Task.detached(priority: .userInitiated) { prepare(items) }.value
            } else {
                selected += items
            }
        }

        do {
            // CleanupManager 内部会先做 PathGuard 校验，再按分类策略处理并写入清理记录。
            lastCleanResult = try await CleanupManager.shared.clean(items: selected) { progress in
                Task { @MainActor [weak self] in self?.cleanProgress = progress }
            }
        } catch {
            lastCleanResult = CleanResult(
                freedSpace: 0, cleanedItems: 0, duration: 0,
                errors: [CleanError(path: "", error: error, message: error.localizedDescription)]
            )
        }

        isCleaning = false
        // 缓存类只清空内容、目录还在，需要重新扫描拿到准确的剩余大小。
        for group in affectedGroups { scan(groupID: group.id) }
    }

    /// 撤销最近一次清理：把仍在废纸篓里的项目放回原处。
    func undoLastClean() async {
        guard let sessionID = lastCleanResult?.historySessionID else { return }
        lastRestoreResult = await CleanupManager.shared.restore(sessionID: sessionID)
        lastCleanResult = nil
        scanAll()
    }
}
