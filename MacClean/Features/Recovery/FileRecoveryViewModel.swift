//
//  FileRecoveryViewModel.swift
//  MacClean
//
//  找回文件：来源发现 → 挂载所选本地快照（一次管理员授权）→ 查找 → 复制回原位置。
//  ViewModel 常驻（static let shared），切换侧栏不丢状态；快照挂载在应用退出时尝试卸载。
//

import AppKit
import Combine
import SwiftUI

// MARK: - 查找范围

enum RecoveryFolder: Hashable, Identifiable {
    case desktop, documents, downloads, pictures, movies, music, home
    case custom(String)

    static let quickPicks: [RecoveryFolder] = [.desktop, .documents, .downloads, .pictures, .movies, .music, .home]

    var id: String { relativePath.isEmpty ? "~" : relativePath }

    /// 相对主目录的路径；整个主目录为 ""。
    var relativePath: String {
        switch self {
        case .desktop: return "Desktop"
        case .documents: return "Documents"
        case .downloads: return "Downloads"
        case .pictures: return "Pictures"
        case .movies: return "Movies"
        case .music: return "Music"
        case .home: return ""
        case .custom(let path): return path
        }
    }

    var title: String {
        switch self {
        case .desktop: return String(localized: "桌面")
        case .documents: return String(localized: "文稿")
        case .downloads: return String(localized: "下载")
        case .pictures: return String(localized: "recovery.folder.pictures", defaultValue: "图片")
        case .movies: return String(localized: "影片")
        case .music: return String(localized: "音乐")
        case .home: return String(localized: "整个主目录")
        case .custom(let path): return (path as NSString).lastPathComponent
        }
    }

    var icon: String {
        switch self {
        case .desktop: return "menubar.dock.rectangle"
        case .documents: return "doc"
        case .downloads: return "arrow.down.circle"
        case .pictures: return "photo"
        case .movies: return "film"
        case .music: return "music.note"
        case .home: return "house"
        case .custom: return "folder"
        }
    }
}

enum RecoveryResultSort: String, CaseIterable, Identifiable {
    case modified, name, size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modified: return String(localized: "按修改时间")
        case .name: return String(localized: "按名称")
        case .size: return String(localized: "按大小")
        }
    }
}

// MARK: - 退出时卸载用的挂载点登记（任意线程可读）

nonisolated final class RecoveryMountRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var points: [String] = []

    var mountPoints: [String] {
        lock.lock(); defer { lock.unlock() }
        return points
    }

    func set(_ newValue: [String]) {
        lock.lock(); defer { lock.unlock() }
        points = newValue
    }
}

// MARK: - ViewModel

@MainActor
final class FileRecoveryViewModel: ObservableObject {
    static let shared = FileRecoveryViewModel()

    enum Phase: Equatable { case intro, discovering, ready }

    struct Notice: Equatable {
        let text: String
        let isError: Bool
    }

    // 来源
    @Published private(set) var phase: Phase = .intro
    @Published private(set) var discovery = RecoveryDiscovery()
    /// 不可访问的时间机器备份（备份磁盘未连接等）
    @Published private(set) var unreachableBackups: Set<String> = []
    @Published var selectedSourceIDs: Set<String> = []
    @Published private(set) var mountedSnapshots: [String: String] = [:] {
        didSet { mountRegistry.set(Array(mountedSnapshots.values)) }
    }
    @Published private(set) var isMounting = false
    @Published private(set) var isUnmounting = false
    @Published private(set) var notice: Notice?
    @Published private(set) var lastCheckedAt: Date?

    // 查找条件
    @Published var mode: RecoverySearchMode = .missing
    @Published var folder: RecoveryFolder = .home
    @Published var includeHidden = false
    @Published var searchTerm = ""
    @Published var sort: RecoveryResultSort = .modified

    // 结果
    @Published private(set) var isScanning = false
    @Published private(set) var checkedCount = 0
    @Published private(set) var results: [RecoveryItem] = []
    @Published private(set) var hasSearched = false
    @Published private(set) var truncated = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var searchedSources: [RecoverySource] = []
    /// 来源里找不到当前用户的主目录（例如别的用户的备份）
    @Published private(set) var sourcesWithoutHome: [RecoverySource] = []
    @Published private(set) var selection: Set<String> = []
    @Published private(set) var directorySizes: [String: Int64] = [:]
    @Published private(set) var restoredIDs: Set<String> = []

    // 恢复
    @Published private(set) var isRestoring = false
    @Published private(set) var restoreProgress = 0
    @Published var restoreReport: RecoveryRestoreReport?

    let home: URL
    nonisolated let mountRegistry = RecoveryMountRegistry()
    private var searchTask: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var terminationObserver: NSObjectProtocol?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, observesTermination: Bool = true) {
        self.home = home
        if observesTermination {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [registry = mountRegistry] _ in
                // 尽力而为：同步卸载（需要时会弹一次密码框）；失败也没关系，重启后挂载自动消失
                let points = registry.mountPoints
                guard !points.isEmpty else { return }
                _ = RecoveryRunner.runAdmin(RecoveryAdminScript.unmountCommands(mountPoints: points))
            }
            // 上次运行留下、尚未卸载的快照：直接恢复「已挂载」状态并列出来源
            let ref = WeakRef(self)
            Task.detached(priority: .utility) {
                let mounts = RecoveryRunner.currentMounts()
                guard !mounts.isEmpty else { return }
                await MainActor.run {
                    guard let model = ref.object, model.phase == .intro else { return }
                    model.mountedSnapshots = mounts
                    model.discover()
                }
            }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        let points = mountRegistry.mountPoints
        if !points.isEmpty {
            Task.detached(priority: .utility) {
                _ = RecoveryRunner.runAdmin(RecoveryAdminScript.unmountCommands(mountPoints: points))
            }
        }
    }

    // MARK: - 来源

    var snapshots: [RecoverySource] { discovery.sources.filter { $0.kind == .localSnapshot } }
    var backups: [RecoverySource] { discovery.sources.filter { $0.kind == .timeMachine } }
    var hasAnySource: Bool { !discovery.sources.isEmpty }

    func isMounted(_ source: RecoverySource) -> Bool {
        source.kind == .localSnapshot && mountedSnapshots[source.name] != nil
    }

    func isReady(_ source: RecoverySource) -> Bool {
        switch source.kind {
        case .localSnapshot: return isMounted(source)
        case .timeMachine: return !unreachableBackups.contains(source.name)
        }
    }

    var selectedSources: [RecoverySource] { discovery.sources.filter { selectedSourceIDs.contains($0.id) } }
    var readySelectedSources: [RecoverySource] { selectedSources.filter(isReady) }
    var selectedUnmountedSnapshots: [RecoverySource] {
        selectedSources.filter { $0.kind == .localSnapshot && !isMounted($0) }
    }

    func toggleSource(_ source: RecoverySource) {
        if selectedSourceIDs.contains(source.id) {
            selectedSourceIDs.remove(source.id)
        } else {
            selectedSourceIDs.insert(source.id)
        }
    }

    func discover() {
        guard phase != .discovering else { return }
        phase = .discovering
        notice = nil
        let ref = WeakRef(self)
        Task.detached(priority: .userInitiated) {
            let discovery = RecoveryRunner.discover()
            let unreachable = Set(discovery.sources.filter { $0.kind == .timeMachine && !RecoveryPaths.isRealDirectory($0.name) }.map(\.name))
            await MainActor.run { ref.object?.applyDiscovery(discovery, unreachableBackups: unreachable) }
        }
    }

    func applyDiscovery(_ discovery: RecoveryDiscovery, unreachableBackups: Set<String> = []) {
        let isFirst = lastCheckedAt == nil
        self.discovery = discovery
        self.unreachableBackups = unreachableBackups
        mountedSnapshots = discovery.mountedSnapshots
        let ids = Set(discovery.sources.map(\.id))
        selectedSourceIDs.formIntersection(ids)
        if isFirst || selectedSourceIDs.isEmpty {
            // 默认：全部本地快照（通常只有最近一天） + 最新一份可访问的时间机器备份
            selectedSourceIDs = Set(discovery.sources.filter { $0.kind == .localSnapshot }.map(\.id))
            if let newest = discovery.sources.first(where: { $0.kind == .timeMachine && !unreachableBackups.contains($0.name) }) {
                selectedSourceIDs.insert(newest.id)
            }
        }
        lastCheckedAt = Date()
        phase = .ready
    }

    // MARK: - 挂载 / 卸载

    func mountSelectedSnapshots() {
        let names = selectedUnmountedSnapshots.map(\.name)
        guard !names.isEmpty, !isMounting else { return }
        guard let device = discovery.dataDeviceNode else {
            notice = Notice(text: String(localized: "无法确定数据卷的设备，暂时不能挂载快照。"), isError: true)
            return
        }
        isMounting = true
        notice = nil
        let ref = WeakRef(self)
        Task.detached(priority: .userInitiated) {
            let commands = RecoveryAdminScript.mountCommands(snapshots: names, deviceNode: device)
            let outcome = RecoveryRunner.runAdmin(commands)
            let mounts = RecoveryRunner.currentMounts()
            await MainActor.run { ref.object?.finishMount(outcome, mounts: mounts, requested: names) }
        }
    }

    private func finishMount(_ outcome: RecoveryAdminOutcome, mounts: [String: String], requested: [String]) {
        isMounting = false
        mountedSnapshots = mounts
        switch outcome {
        case .cancelled:
            notice = Notice(text: String(localized: "已取消"), isError: false)
        case .failure(let message):
            notice = Notice(text: String(localized: "挂载失败：\(message)"), isError: true)
        case .finished(let errors):
            let failed = requested.filter { mounts[$0] == nil }
            if failed.isEmpty {
                notice = Notice(text: String(localized: "已挂载 \(requested.count) 个快照，可以开始查找了。"), isError: false)
            } else {
                let reason = errors.compactMap { $0 }.first ?? String(localized: "未知原因")
                notice = Notice(text: String(localized: "\(failed.count) 个快照挂载失败：\(reason)"), isError: true)
            }
        }
    }

    func unmountAll() {
        let points = Array(mountedSnapshots.values)
        guard !points.isEmpty, !isUnmounting else { return }
        cancelSearch()
        isUnmounting = true
        notice = nil
        let ref = WeakRef(self)
        Task.detached(priority: .userInitiated) {
            let outcome = RecoveryRunner.runAdmin(RecoveryAdminScript.unmountCommands(mountPoints: points))
            let mounts = RecoveryRunner.currentMounts()
            await MainActor.run { ref.object?.finishUnmount(outcome, mounts: mounts) }
        }
    }

    private func finishUnmount(_ outcome: RecoveryAdminOutcome, mounts: [String: String]) {
        isUnmounting = false
        mountedSnapshots = mounts
        switch outcome {
        case .cancelled:
            notice = Notice(text: String(localized: "已取消"), isError: false)
        case .failure(let message):
            notice = Notice(text: String(localized: "卸载失败：\(message)"), isError: true)
        case .finished:
            if mounts.isEmpty {
                notice = Notice(text: String(localized: "快照已卸载。"), isError: false)
                // 结果里的快照路径已失效
                let snapshotIDs = Set(snapshots.map(\.id))
                results.removeAll { snapshotIDs.contains($0.sourceID) }
                selection.formIntersection(results.map(\.id))
            } else {
                notice = Notice(text: String(localized: "还有 \(mounts.count) 个快照没能卸载，可能仍在使用中；重启后会自动卸载。"), isError: true)
            }
        }
    }

    // MARK: - 查找

    var canSearch: Bool {
        !readySelectedSources.isEmpty && !(mode == .name && searchTerm.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func startSearch() {
        guard canSearch else { return }
        cancelSearch()
        searchGeneration += 1
        let generation = searchGeneration
        let sources = readySelectedSources.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let mounts = mountedSnapshots
        let options = RecoveryScanner.Options(
            mode: mode,
            term: searchTerm,
            includeHidden: includeHidden,
            relativeFolder: folder.relativePath
        )
        let currentHome = home.standardizedFileURL.path
        let relativeHome = RecoveryPaths.relativeHome(home)

        isScanning = true
        checkedCount = 0
        results = []
        selection = []
        directorySizes = [:]
        restoredIDs = []
        truncated = false
        permissionDenied = false
        searchedSources = sources
        sourcesWithoutHome = []

        let ref = WeakRef(self)
        searchTask = Task.detached(priority: .userInitiated) {
            var perSource: [[RecoveryItem]] = []
            var truncated = false
            var denied = false
            var withoutHome: [RecoverySource] = []
            var checkedBefore = 0
            for source in sources {
                if Task.isCancelled { break }
                let root = source.kind == .localSnapshot ? (mounts[source.name] ?? "") : source.name
                guard !root.isEmpty,
                      let sourceHome = RecoveryPaths.homeInSource(root: root, kind: source.kind, relativeHome: relativeHome)
                else {
                    if access(root, R_OK) != 0, errno == EPERM || errno == EACCES { denied = true }
                    withoutHome.append(source)
                    continue
                }
                let base = checkedBefore
                let outcome = RecoveryScanner.scan(
                    sourceID: source.id,
                    sourceHome: sourceHome,
                    currentHome: currentHome,
                    options: options,
                    isCancelled: { Task.isCancelled },
                    progress: { count in
                        Task { @MainActor in
                            guard let model = ref.object, model.searchGeneration == generation else { return }
                            model.checkedCount = base + count
                        }
                    }
                )
                checkedBefore += outcome.checked
                perSource.append(outcome.items)
                truncated = truncated || outcome.truncated
                denied = denied || outcome.permissionDenied
            }
            let merged = RecoveryScanner.mergeDuplicates(perSource)
            let cancelled = Task.isCancelled
            let finalChecked = checkedBefore
            let withoutHomeFinal = withoutHome
            let truncatedFinal = truncated
            let deniedFinal = denied
            await MainActor.run {
                guard let model = ref.object, model.searchGeneration == generation, !cancelled else { return }
                model.finishSearch(merged, checked: finalChecked, truncated: truncatedFinal, permissionDenied: deniedFinal, withoutHome: withoutHomeFinal)
            }
        }
    }

    private func finishSearch(_ items: [RecoveryItem], checked: Int, truncated: Bool, permissionDenied: Bool, withoutHome: [RecoverySource]) {
        results = items
        checkedCount = checked
        self.truncated = truncated
        self.permissionDenied = permissionDenied
        sourcesWithoutHome = withoutHome
        isScanning = false
        hasSearched = true
        computeDirectorySizes()
    }

    func cancelSearch() {
        searchTask?.cancel()
        sizeTask?.cancel()
        searchGeneration += 1
        isScanning = false
    }

    /// 文件夹大小在后台逐个计算，算完一批刷新一次。
    private func computeDirectorySizes() {
        let directories = results.filter(\.isDirectory).map { ($0.id, $0.sourcePath) }
        guard !directories.isEmpty else { return }
        let generation = searchGeneration
        let ref = WeakRef(self)
        sizeTask = Task.detached(priority: .utility) {
            var batch: [String: Int64] = [:]
            for (index, (id, path)) in directories.enumerated() {
                if Task.isCancelled { return }
                batch[id] = RecoveryScanner.directorySize(path, isCancelled: { Task.isCancelled })
                if batch.count >= 20 || index == directories.count - 1 {
                    let sizes = batch
                    batch = [:]
                    await MainActor.run {
                        guard let model = ref.object, model.searchGeneration == generation else { return }
                        model.directorySizes.merge(sizes) { $1 }
                    }
                }
            }
        }
    }

    // MARK: - 结果与选择

    func source(for item: RecoveryItem) -> RecoverySource? {
        discovery.sources.first { $0.id == item.sourceID }
    }

    func size(of item: RecoveryItem) -> Int64? {
        item.size ?? directorySizes[item.id]
    }

    var sortedResults: [RecoveryItem] {
        switch sort {
        case .modified:
            return results.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        case .name:
            return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            return results.sorted { (size(of: $0) ?? -1) > (size(of: $1) ?? -1) }
        }
    }

    func isSelected(_ item: RecoveryItem) -> Bool { selection.contains(item.id) }

    func toggle(_ item: RecoveryItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    func selectAll(_ on: Bool) {
        if on {
            selection = Set(results.filter { !restoredIDs.contains($0.id) }.map(\.id))
        } else {
            selection = []
        }
    }

    var selectedItems: [RecoveryItem] { results.filter { selection.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + (size(of: $1) ?? 0) } }
    /// 还有文件夹的大小没算完
    var selectedSizeIsPartial: Bool { selectedItems.contains { size(of: $0) == nil } }

    /// 确认框里的目标位置说明：同一个文件夹时直接给出路径。
    var selectedDestinationSummary: String {
        let parents = Set(selectedItems.map { ($0.relativePath as NSString).deletingLastPathComponent })
        if parents.count == 1, let parent = parents.first {
            return parent.isEmpty ? "~" : "~/" + parent
        }
        return String(localized: "各自原来的位置（\(parents.count) 个文件夹）")
    }

    // MARK: - 恢复

    func restoreSelected() {
        let items = selectedItems
        guard !items.isEmpty, !isRestoring else { return }
        isRestoring = true
        restoreProgress = 0
        let home = self.home
        let ref = WeakRef(self)
        Task.detached(priority: .userInitiated) {
            let report = RecoveryRestorer.restore(items, home: home) { done in
                Task { @MainActor in ref.object?.restoreProgress = done }
            }
            await MainActor.run { ref.object?.finishRestore(report) }
        }
    }

    private func finishRestore(_ report: RecoveryRestoreReport) {
        isRestoring = false
        let restored = Set(report.restored.map(\.item.id))
        restoredIDs.formUnion(restored)
        selection.subtract(restored)
        restoreReport = report
    }
}
