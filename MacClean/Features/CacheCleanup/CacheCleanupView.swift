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
}

struct CleanGroupState: Identifiable {
    let descriptor: CleanGroupDescriptor
    var items: [CleanableItem] = []
    var isScanning = false
    var hasScanned = false

    var id: String { descriptor.id }
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
        return [projects] + caches
    }
}

// MARK: - 跨并发域的弱引用

/// 后台扫描的进度回调需要弱引用 ViewModel；以 let 常量捕获此盒子，避免「捕获可变 weak var」的并发告警。
final class WeakRef<Object: AnyObject>: @unchecked Sendable {
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
    /// 最近一次全部分组扫描完成的时间
    @Published private(set) var lastScannedAt: Date?

    private let home: URL
    /// 每次触发扫描递增，旧扫描的回调据此丢弃，避免重新扫描时新旧结果互相覆盖。
    private var scanGeneration: [String: Int] = [:]

    init(descriptors: [CleanGroupDescriptor], home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.groups = descriptors.map { CleanGroupState(descriptor: $0) }
        self.home = home
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
        if !isScanning { lastScannedAt = Date() }
    }

    // MARK: - 选择

    func setSelection(groupID: String, selected: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        for itemIndex in groups[index].items.indices {
            groups[index].items[itemIndex].isSelected = selected
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
        let affectedGroups = groups.filter { $0.selectedCount > 0 }.map(\.id)
        let selected = selectedItems
        guard !selected.isEmpty else { return }

        isCleaning = true
        cleanProgress = 0
        lastRestoreResult = nil

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
        for groupID in affectedGroups { scan(groupID: groupID) }
    }

    /// 撤销最近一次清理：把仍在废纸篓里的项目放回原处。
    func undoLastClean() async {
        guard let sessionID = lastCleanResult?.historySessionID else { return }
        lastRestoreResult = await CleanupManager.shared.restore(sessionID: sessionID)
        lastCleanResult = nil
        scanAll()
    }
}
