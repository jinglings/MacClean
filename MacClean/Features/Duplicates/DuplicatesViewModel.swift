//
//  DuplicatesViewModel.swift
//  MacClean
//
//  「重复与相似」页面：当前模式 + 「完全相同的文件」模式的扫描、选择与清理。
//  每组自动保留一份（DuplicateFinder 的保留规则），其余副本默认勾选；保留的那份永远不会被勾选，
//  因此任何一组都不可能被整组删除。删除走废纸篓，可在「清理记录」中撤销。
//

import SwiftUI
import Combine

enum DuplicatesMode: String, CaseIterable, Identifiable {
    case exact, similar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exact: return String(localized: "完全相同的文件")
        case .similar: return String(localized: "相似照片")
        }
    }
}

/// 最小文件大小档位。
enum DuplicateSizeFloor: Int64, CaseIterable, Identifiable {
    case any = 1
    case kb100 = 102_400
    case mb1 = 1_048_576
    case mb10 = 10_485_760
    case mb100 = 104_857_600

    var id: Int64 { rawValue }

    var title: String {
        switch self {
        case .any: return String(localized: "任意")
        case .kb100: return "100 KB"
        case .mb1: return "1 MB"
        case .mb10: return "10 MB"
        case .mb100: return "100 MB"
        }
    }
}

extension DuplicateTypeFilter {
    var title: String {
        switch self {
        case .images: return String(localized: "图片")
        case .videos: return String(localized: "视频")
        case .audio: return String(localized: "音频")
        case .documents: return String(localized: "文档")
        case .archives: return String(localized: "压缩包与安装包")
        }
    }

    var icon: String {
        switch self {
        case .images: return "photo"
        case .videos: return "film"
        case .audio: return "waveform"
        case .documents: return "doc.richtext"
        case .archives: return "doc.zipper"
        }
    }
}

@MainActor
final class DuplicatesViewModel: ObservableObject {
    nonisolated static let modeDefaultsKey = "duplicatesPageMode"

    /// 页面当前模式；记住上次的选择
    @Published var mode: DuplicatesMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeDefaultsKey) }
    }

    // MARK: 扫描条件

    @Published private(set) var folders: [URL]
    @Published var minSize: DuplicateSizeFloor = .mb1
    @Published var types: Set<DuplicateTypeFilter> = []

    // MARK: 结果

    @Published private(set) var groups: [DuplicateGroup] = []
    /// 用户改过保留项的组：组 id → 保留文件路径。未出现的组保留建议项。
    @Published private(set) var keepers: [String: String] = [:]
    @Published private(set) var selected: Set<String> = []
    @Published private(set) var deniedFolders: [String] = []
    @Published private(set) var filesChecked = 0

    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var wasCancelled = false
    @Published private(set) var lastScannedAt: Date?
    @Published private(set) var progress = DuplicateScanProgress()
    /// 生成当前结果时的扫描条件，用来提示「条件已更改」
    @Published private(set) var scannedSettings: ScanSettings?

    @Published private(set) var isCleaning = false
    @Published private(set) var cleanProgress: Double = 0
    @Published private(set) var lastCleanResult: CleanResult?
    @Published private(set) var lastRestoreResult: RestoreResult?

    struct ScanSettings: Equatable {
        let folders: [URL]
        let minSize: DuplicateSizeFloor
        let types: Set<DuplicateTypeFilter>
    }

    let home: URL
    /// 主目录的真实路径（扫描结果中的路径都已解析符号链接）
    private let homePath: String
    private let defaults: UserDefaults
    private var scanTask: Task<Void, Never>?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, folders: [URL]? = nil, defaults: UserDefaults = .standard) {
        self.home = home
        homePath = realpath(home.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? home.path
        self.defaults = defaults
        self.folders = folders ?? [home]
        mode = defaults.string(forKey: Self.modeDefaultsKey).flatMap(DuplicatesMode.init(rawValue:)) ?? .exact
    }

    // MARK: - 汇总

    var currentSettings: ScanSettings { ScanSettings(folders: folders, minSize: minSize, types: types) }
    var settingsChangedSinceScan: Bool { hasScanned && scannedSettings != nil && scannedSettings != currentSettings }

    var copyCount: Int { groups.reduce(0) { $0 + $1.files.count - 1 } }
    var reclaimableSize: Int64 { groups.reduce(0) { $0 + $1.reclaimableSize } }
    var selectedCount: Int { selected.count }
    var selectedSize: Int64 {
        groups.reduce(0) { total, group in
            total + Int64(group.files.filter { selected.contains($0.path) }.count) * group.size
        }
    }
    /// 所有文件都被勾选的组数。模型保证它恒为 0，保留在这里供测试与清理前校验。
    var fullySelectedGroupCount: Int {
        groups.filter { group in group.files.allSatisfy { selected.contains($0.path) } }.count
    }

    // MARK: - 范围

    func addFolder(_ url: URL) {
        let url = url.standardizedFileURL
        guard !folders.contains(url) else { return }
        folders.append(url)
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }
    }

    func toggleType(_ type: DuplicateTypeFilter) {
        if types.contains(type) {
            types.remove(type)
        } else {
            types.insert(type)
        }
    }

    // MARK: - 扫描

    func scan() {
        guard !folders.isEmpty else { return }
        scanTask?.cancel()
        isScanning = true
        wasCancelled = false
        progress = DuplicateScanProgress()
        lastRestoreResult = nil

        let settings = currentSettings
        let options = DuplicateScanOptions(
            minSize: settings.minSize.rawValue,
            types: settings.types,
            home: home,
            preferredLocations: ["Documents", "Desktop", "Downloads"].map { home.appendingPathComponent($0) }
        )
        let ref = WeakRef(self)

        scanTask = Task.detached(priority: .userInitiated) {
            let result = try? DuplicateFinder.scan(roots: settings.folders, options: options) { progress in
                Task { @MainActor in
                    guard let model = ref.object, model.isScanning else { return }
                    model.progress = progress
                }
            }
            let filtered = result.map(Self.removingIgnored)
            let cancelled = Task.isCancelled
            await ref.object?.finishScan(filtered, settings: settings, cancelled: cancelled)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        wasCancelled = true
    }

    /// 被「始终忽略」的文件不参与；去掉后不足两份的组不再算重复。
    nonisolated private static func removingIgnored(_ result: DuplicateScanResult) -> DuplicateScanResult {
        let ignored = IgnoreList.paths()
        guard !ignored.isEmpty else { return result }
        var filtered = result
        filtered.groups = result.groups.compactMap { group in
            let files = group.files.filter { !IgnoreList.isIgnored($0.path, in: ignored) }
            return files.count >= 2 ? DuplicateGroup(id: group.id, size: group.size, files: files) : nil
        }
        return filtered
    }

    private func finishScan(_ result: DuplicateScanResult?, settings: ScanSettings, cancelled: Bool) {
        guard !cancelled, isScanning else { return }
        isScanning = false
        guard let result else { return }
        apply(result, settings: settings)
        UsageAnalytics.shared.recordScanCompleted()
    }

    /// 载入扫描结果：每组保留建议项，其余副本全部预选。
    func apply(_ result: DuplicateScanResult, settings: ScanSettings? = nil) {
        groups = result.groups
        keepers = [:]
        selected = Set(result.groups.flatMap { $0.files.dropFirst().map(\.path) })
        deniedFolders = result.deniedFolders
        filesChecked = result.filesChecked
        scannedSettings = settings ?? currentSettings
        hasScanned = true
        wasCancelled = false
        lastScannedAt = Date()
    }

    // MARK: - 选择

    func keeperPath(of group: DuplicateGroup) -> String {
        keepers[group.id] ?? group.suggestedKeeper.path
    }

    func isKeeper(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool {
        keeperPath(of: group) == file.path
    }

    func isSelected(_ file: DuplicateFile) -> Bool { selected.contains(file.path) }

    /// 勾选/取消一个副本。保留的那份不能被勾选——这是「不会整组删除」的保证。
    func toggle(_ file: DuplicateFile, in group: DuplicateGroup) {
        guard !isKeeper(file, in: group) else { return }
        if selected.contains(file.path) {
            selected.remove(file.path)
        } else {
            selected.insert(file.path)
        }
    }

    /// 「保留这个」：改为保留这一份，原来保留的那份变成待删除的副本。
    func keep(_ file: DuplicateFile, in group: DuplicateGroup) {
        let previous = keeperPath(of: group)
        guard previous != file.path, group.files.contains(file) else { return }
        keepers[group.id] = file.path
        selected.remove(file.path)
        selected.insert(previous)
    }

    /// 每组保留当前的保留项，选中其余全部副本。
    func selectAllCopies() {
        selected = Set(groups.flatMap { group in
            let keeper = keeperPath(of: group)
            return group.files.map(\.path).filter { $0 != keeper }
        })
    }

    func clearSelection() { selected = [] }

    func ignore(_ file: DuplicateFile) {
        IgnoreList.add(file.path)
        selected.remove(file.path)
        groups = groups.compactMap { group in
            let files = group.files.filter { $0.path != file.path }
            return files.count >= 2 ? DuplicateGroup(id: group.id, size: group.size, files: files) : nil
        }
        pruneKeepers()
    }

    /// 保留项不在组里了（被忽略或已删除）时回到建议项，并确保它没有被勾选。
    private func pruneKeepers() {
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        keepers = keepers.filter { id, path in byID[id]?.files.contains { $0.path == path } == true }
        for group in groups { selected.remove(keeperPath(of: group)) }
        let all = Set(groups.flatMap { $0.files.map(\.path) })
        selected.formIntersection(all)
    }

    // MARK: - 清理

    /// 本次要移入废纸篓的文件。保留项永不在内；保留项已不在磁盘上的组整组跳过，避免把最后一份也删掉。
    func cleanupTargets(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [CleanableItem] {
        groups.flatMap { group -> [CleanableItem] in
            let keeper = keeperPath(of: group)
            guard fileExists(keeper) else { return [] }
            return group.files.filter { $0.path != keeper && selected.contains($0.path) }.map { file in
                var item = CleanableItem(
                    name: file.name,
                    path: file.path,
                    size: file.size,
                    category: .duplicates,
                    isSelected: true,
                    description: nil,
                    lastModified: file.modified
                )
                item.removesContainer = true
                return item
            }
        }
    }

    func cleanSelected() async {
        guard !isCleaning else { return }
        let items = cleanupTargets()
        guard !items.isEmpty else { return }

        isCleaning = true
        cleanProgress = 0
        lastRestoreResult = nil

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

        // 移除已不在原位置的副本；剩余不足两份的组不再是重复。
        let fileManager = FileManager.default
        groups = groups.compactMap { group in
            let remaining = group.files.filter { fileManager.fileExists(atPath: $0.path) }
            return remaining.count >= 2 ? DuplicateGroup(id: group.id, size: group.size, files: remaining) : nil
        }
        pruneKeepers()
        isCleaning = false
    }

    func undoLastClean() async {
        guard let sessionID = lastCleanResult?.historySessionID else { return }
        lastRestoreResult = await CleanupManager.shared.restore(sessionID: sessionID)
        lastCleanResult = nil
        scan()
    }

    // MARK: - 显示

    /// 相对主目录的路径（~/…）
    func displayPath(_ path: String) -> String {
        if path == homePath { return "~" }
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }

    func folderTitle(_ url: URL) -> String {
        url.standardizedFileURL.path == home.standardizedFileURL.path ? String(localized: "主目录") : url.lastPathComponent
    }
}
