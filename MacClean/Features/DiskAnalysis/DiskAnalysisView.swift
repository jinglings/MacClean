//
//  DiskAnalysisView.swift
//  MacClean
//
//  空间透镜：扫描整盘目录占用并可视化管理大目录。
//

import AppKit
import Combine
import SwiftUI

struct DiskAnalysisView: View {
    @AppStorage(StorageMapMode.storageKey) private var mode: StorageMapMode = .folderMap

    var body: some View {
        switch mode {
        case .folderMap:
            FolderMapView()
        case .systemData:
            SystemDataView(viewModel: SystemDataViewModel.shared)
        }
    }
}

/// 存储地图 →「目录地图」：整盘目录占用的气泡图与逐层钻取。
private struct FolderMapView: View {
    @ObservedObject private var viewModel = PageModelStore.shared.spaceLens
    
    var body: some View {
        ZStack {
            AppBackdrop()
            
            switch viewModel.phase {
            case .intro:
                SpaceLensIntroView(viewModel: viewModel)
                    .transition(.opacity)
            case .scanning:
                SpaceLensScanningView(viewModel: viewModel)
                    .transition(.opacity)
            case .results:
                SpaceLensResultsView(viewModel: viewModel)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: viewModel.phase)
        .alert("清理暂存篮？", isPresented: $viewModel.showBasketConfirm) {
            Button("取消", role: .cancel) {}
            Button("移入废纸篓", role: .destructive) {
                viewModel.cleanBasket()
            }
        } message: {
            Text(viewModel.basketConfirmMessage)
        }
        .sheet(isPresented: $viewModel.showCompletion) {
            let result = viewModel.lastCleanResult
            CleanupCompletionView(
                cleanedSize: result?.freedSpace ?? 0,
                cleanedCount: result?.cleanedItems ?? 0,
                permanentlyFreed: result?.permanentlyFreed ?? 0,
                failedCount: result?.errors.count ?? 0,
                onUndo: result?.historySessionID == nil ? nil : {
                    Task {
                        await viewModel.undoLastClean()
                        viewModel.showCompletion = false
                    }
                },
                onDismiss: { viewModel.showCompletion = false }
            )
        }
    }
}

@MainActor
final class SpaceLensViewModel: ObservableObject {
    enum Phase {
        case intro
        case scanning
        case results
    }
    
    @Published var phase: Phase = .intro
    @Published var rootItem: SpaceLensItem?
    @Published var diskInfo: DiskInfo?
    @Published var currentPath: [SpaceLensItem.ID] = []
    @Published var selectedIDs: Set<SpaceLensItem.ID> = []
    @Published var scannedPath: String = ""
    @Published var scannedItems: Int = 0
    @Published var scanProgress: Double = 0
    @Published var recentScannedPaths: [String] = []
    @Published var isDeleting = false
    @Published var isLoadingDirectory = false
    @Published var errorMessage: String?
    @Published var showBasketConfirm = false
    @Published var showBasketList = false
    /// 暂存篮：跨层级收集待清理项目，扫描结果存在期间一直保留（切换页面、钻取都不丢）。
    @Published var basket = StorageBasket()
    /// 键盘焦点行（鼠标悬停或上下键移动），B / 空格作用于它。
    @Published var focusedID: SpaceLensItem.ID?
    @Published var basketToast: BasketToast?
    @Published var basketPulse: BasketPulse?
    /// 卷上系统可自动释放的空间；nil 表示尚未读取或读取失败。
    @Published var purgeableSpace: Int64?

    struct BasketToast: Equatable {
        let id = UUID()
        let message: String
        var isWarning = false
    }

    /// 加入暂存篮后底栏上短暂浮起的「+X GB」。
    struct BasketPulse: Equatable {
        let id = UUID()
        let bytes: Int64
    }

    /// 暂存篮显示路径与 PathGuard 判断用的主目录；截图测试会换成合成目录。
    var homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    private var toastTask: Task<Void, Never>?
    @Published var showCompletion = false
    @Published var lastCleanResult: CleanResult?
    @Published var lastRestoreResult: RestoreResult?
    @Published var unreadableCount: Int = 0

    /// 最近一次删除前的整棵树，撤销时直接换回，免得为几个文件重扫整盘。
    private var treeBeforeLastClean: SpaceLensItem?
    private var lastCleanedIDs: [SpaceLensItem.ID: String] = [:]

    private static let maxRecentPaths = 7
    
    private var scanTask: Task<Void, Never>?
    
    var currentItem: SpaceLensItem? {
        guard let rootItem else { return nil }
        return node(in: rootItem, path: currentPath)
    }
    
    var currentChildren: [SpaceLensItem] {
        currentItem?.sortedChildren ?? []
    }
    
    var selectedItems: [SpaceLensItem] {
        currentChildren.filter { selectedIDs.contains($0.id) }
    }
    
    var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }
    
    var selectedSizeText: String {
        ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file)
    }
    
    var canNavigateBack: Bool {
        !currentPath.isEmpty
    }

    /// 焦点项：列表行，或树状图里嵌套一层的格子。
    var focusedItem: SpaceLensItem? {
        guard let focusedID else { return nil }
        let children = currentChildren
        return children.first { $0.id == focusedID }
            ?? children.lazy.flatMap(\.children).first { $0.id == focusedID }
    }

    /// 地图外的占用：已用空间里没被扫描树覆盖的部分（快照、权限外目录、系统卷等）。
    var unmappedSpace: Int64? {
        guard let diskInfo, let rootItem else { return nil }
        return max(0, diskInfo.usedSpace - rootItem.size)
    }
    
    func startScan() {
        scanTask?.cancel()
        phase = .scanning
        rootItem = nil
        diskInfo = nil
        currentPath = []
        selectedIDs = []
        scannedPath = "/"
        scannedItems = 0
        scanProgress = 0
        recentScannedPaths = []
        errorMessage = nil
        unreadableCount = 0
        lastCleanResult = nil
        lastRestoreResult = nil
        treeBeforeLastClean = nil
        lastCleanedIDs = [:]
        basket = StorageBasket()
        focusedID = nil
        basketToast = nil
        basketPulse = nil
        purgeableSpace = nil

        scanTask = Task {
            do {
                let result = try await DiskAnalyzer.scanSpaceLens(rootURL: URL(fileURLWithPath: "/")) { progress in
                    Task { @MainActor in
                        self.scannedPath = progress.scannedPath
                        self.scannedItems = progress.scannedItems
                        self.scanProgress = progress.progress
                        var paths = self.recentScannedPaths
                        paths.insert(progress.scannedPath, at: 0)
                        self.recentScannedPaths = Array(paths.prefix(SpaceLensViewModel.maxRecentPaths))
                    }
                }

                try Task.checkCancellation()
                rootItem = result.root
                diskInfo = result.diskInfo
                unreadableCount = result.unreadableCount
                scanProgress = 1
                phase = .results
                UsageAnalytics.shared.recordScanCompleted()
                purgeableSpace = await Task.detached { DiskAnalyzer.purgeableSpace() }.value
            } catch is CancellationError {
                phase = .intro
            } catch {
                errorMessage = String(localized: "扫描失败：\(error.localizedDescription)")
                phase = .intro
            }
        }
    }
    
    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        phase = .intro
    }
    
    func restart() {
        startScan()
    }
    
    func enter(_ item: SpaceLensItem) {
        guard item.isDirectory, item.isReadable, !item.isVirtual else { return }
        // 树状图可直接双击嵌套一层的文件夹：先补上它的父文件夹
        let children = currentChildren
        if !children.contains(where: { $0.id == item.id }),
           let parent = children.first(where: { $0.children.contains { $0.id == item.id } }) {
            currentPath.append(parent.id)
        }
        currentPath.append(item.id)
        selectedIDs = []
        focusedID = nil
        if item.children.isEmpty {
            loadDirectory(item)
        }
    }
    
    func goBack() {
        guard !currentPath.isEmpty else { return }
        currentPath.removeLast()
        selectedIDs = []
        focusedID = nil
    }
    
    func goRoot() {
        currentPath = []
        selectedIDs = []
        focusedID = nil
    }
    
    func toggleSelection(_ item: SpaceLensItem) {
        guard !item.isVirtual else { return }
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }
    
    // MARK: - 暂存篮

    func addToBasket(_ item: SpaceLensItem) {
        addToBasket([item])
    }

    func addSelectionToBasket() {
        addToBasket(selectedItems)
    }

    /// 键盘 B：有多选时加入所选，否则加入焦点行。
    func addKeyboardTargetToBasket() {
        if !selectedItems.isEmpty {
            addSelectionToBasket()
        } else if let focusedItem {
            addToBasket(focusedItem)
        }
    }

    func addToBasket(_ items: [SpaceLensItem]) {
        guard !items.isEmpty, !isDeleting else { return }
        let before = basket.totalSize
        var notes: [BasketToast] = []
        var addedCount = 0
        var skippedCount = 0
        for item in items {
            switch basket.add(item, homeDirectory: homeDirectory) {
            case .added(let absorbed):
                addedCount += 1
                if absorbed > 0 {
                    notes.append(BasketToast(message: String(localized: "「\(item.name)」已包含 \(absorbed) 个子项")))
                }
            case .duplicate:
                skippedCount += 1
                notes.append(BasketToast(message: String(localized: "「\(item.name)」已在暂存篮中")))
            case .coveredBy(let name):
                skippedCount += 1
                notes.append(BasketToast(message: String(localized: "已在暂存篮的「\(name)」中")))
            case .rejected(let reason):
                skippedCount += 1
                notes.append(BasketToast(message: "\(item.name)：\(reason)", isWarning: true))
            }
        }
        selectedIDs.subtract(items.map(\.id))

        let delta = basket.totalSize - before
        if delta > 0 {
            basketPulse = BasketPulse(bytes: delta)
        }
        if items.count == 1 || notes.count == 1, let note = notes.first {
            showToast(note)
        } else if skippedCount > 0 {
            let isWarning = notes.contains { $0.isWarning }
            showToast(BasketToast(message: String(localized: "已加入 \(addedCount) 项，\(skippedCount) 项未加入"), isWarning: isWarning))
        }
    }

    /// 拖放到暂存篮：载荷只带节点 ID，先在当前层找，找不到再遍历整棵树。
    @discardableResult
    func handleBasketDrop(_ payloads: [String]) -> Bool {
        let ids = payloads.compactMap(StorageBasketDropPayload.decode)
        let items = ids.compactMap { id in
            currentChildren.first { $0.id == id } ?? rootItem.flatMap { Self.findItem(id, in: $0) }
        }
        addToBasket(items)
        return !items.isEmpty
    }

    func removeFromBasket(_ id: SpaceLensItem.ID) {
        basket.remove(id: id)
        if basket.isEmpty { showBasketList = false }
    }

    func clearBasket() {
        basket.removeAll()
        showBasketList = false
    }

    func requestCleanBasket() {
        guard !basket.isEmpty, !isDeleting else { return }

        showBasketList = false
        showBasketConfirm = true
    }

    var basketTotalText: String {
        ByteCountFormatter.string(fromByteCount: basket.totalSize, countStyle: .file)
    }

    var basketConfirmMessage: String {
        var lines = [String(localized: "将 \(basket.count) 个项目（共 \(basketTotalText)）移入废纸篓，可在「清理记录」中恢复。")]
        let personal = basket.personalEntries(homeDirectory: homeDirectory)
        if !personal.isEmpty {
            let names = personal.prefix(3).map { String(localized: "「\($0.name)」") }.joined(separator: String(localized: "、"))
            lines.append(String(localized: "注意：\(names) 位于文稿、桌面、图片、影片或音乐文件夹，可能是个人资料。"))
        }
        let large = basket.largeEntries
        if !large.isEmpty {
            let names = large.prefix(3).map { String(localized: "「\($0.name)」") }.joined(separator: String(localized: "、"))
            lines.append(String(localized: "注意：\(names) 超过 10 GB，请确认不再需要。"))
        }
        return lines.joined(separator: "\n\n")
    }

    /// 走 CleanupManager（PathGuard 的 SpaceLens 规则 + 清理记录），删除后可在完成页或「清理记录」中撤销。
    /// 成功移走的条目离开暂存篮，失败的留下并标注原因。
    func cleanBasket() {
        let entries = basket.entries
        guard !entries.isEmpty, !isDeleting else { return }

        isDeleting = true
        errorMessage = nil
        lastRestoreResult = nil
        let cleanables = entries.map { entry -> CleanableItem in
            var cleanable = CleanableItem(
                name: entry.name,
                path: entry.path,
                size: entry.size,
                category: .spaceLens,
                isSelected: true,
                description: nil,
                lastModified: nil
            )
            cleanable.removesContainer = true
            return cleanable
        }

        Task {
            let snapshot = rootItem
            do {
                lastCleanResult = try await CleanupManager.shared.clean(items: cleanables)
            } catch {
                lastCleanResult = nil
                errorMessage = String(localized: "删除失败：\(error.localizedDescription)")
            }

            // 只把确实已离开原位置的节点从树里摘掉，受保护或失败的保留在树和暂存篮里。
            let paths = entries.map(\.path)
            let remaining = await Task.detached {
                Set(paths.filter { FileManager.default.fileExists(atPath: $0) })
            }.value
            var failureMessages: [String: String] = [:]
            for error in lastCleanResult?.errors ?? [] where failureMessages[error.path] == nil {
                failureMessages[error.path] = error.message
            }
            let deleted = basket.applyCleanOutcome(
                attempted: entries,
                stillExists: { remaining.contains($0) },
                failureMessages: failureMessages
            )
            let deletedIDs = Set(deleted.map(\.id))
            if !deletedIDs.isEmpty, var rootItem {
                treeBeforeLastClean = snapshot
                lastCleanedIDs = Dictionary(uniqueKeysWithValues: deleted.map { ($0.id, $0.path) })
                removeItems(deletedIDs, from: &rootItem)
                self.rootItem = rootItem
                selectedIDs.subtract(deletedIDs)
                if let focusedID, deletedIDs.contains(focusedID) { self.focusedID = nil }
            }
            isDeleting = false
            if !basket.failedEntries.isEmpty {
                showToast(BasketToast(message: String(localized: "\(basket.failedEntries.count) 项未能清理，已留在暂存篮"), isWarning: true))
            }
            if lastCleanResult != nil {
                showCompletion = true
            }
        }
    }

    // MARK: - 键盘与快速查看

    /// 上下键移动焦点行；快速查看开着时跟着换预览。
    func moveFocus(by offset: Int) {
        let children = currentChildren
        guard !children.isEmpty else { return }
        let index = focusedID.flatMap { id in children.firstIndex { $0.id == id } }
        let next = index.map { min(max($0 + offset, 0), children.count - 1) } ?? (offset > 0 ? 0 : children.count - 1)
        focusedID = children[next].id
        if !children[next].isVirtual {
            StorageQuickLook.shared.followIfVisible(children[next].path)
        }
    }

    /// 空格：预览焦点行，没有焦点时预览第一个所选项。
    func toggleQuickLook() {
        guard let target = focusedItem ?? selectedItems.first, !target.isVirtual else { return }
        StorageQuickLook.shared.toggle(target.path)
    }

    func quickLook(_ item: SpaceLensItem) {
        guard !item.isVirtual else { return }
        StorageQuickLook.shared.show(item.path)
    }

    func quickLook(path: String) {
        StorageQuickLook.shared.show(path)
    }

    private func showToast(_ toast: BasketToast) {
        basketToast = toast
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled, self?.basketToast?.id == toast.id else { return }
            self?.basketToast = nil
        }
    }

    private static func findItem(_ id: SpaceLensItem.ID, in item: SpaceLensItem) -> SpaceLensItem? {
        if item.id == id { return item }
        for child in item.children {
            if let found = findItem(id, in: child) { return found }
        }
        return nil
    }

    func undoLastClean() async {
        guard let sessionID = lastCleanResult?.historySessionID else { return }
        lastRestoreResult = await CleanupManager.shared.restore(sessionID: sessionID)
        lastCleanResult = nil

        // 换回删除前的树；没能放回原处的节点再摘掉一次，保证占用数字与磁盘一致。
        if var restored = treeBeforeLastClean {
            let fileManager = FileManager.default
            let stillMissing = Set(lastCleanedIDs.filter { !fileManager.fileExists(atPath: $0.value) }.keys)
            if !stillMissing.isEmpty {
                removeItems(stillMissing, from: &restored)
            }
            rootItem = restored
        }
        treeBeforeLastClean = nil
        lastCleanedIDs = [:]
        selectedIDs = []
    }
    
    /// 兜底重扫：全树已在 startScan 中建好，正常情况下 children 不为空，这里很少被触发。
    private func loadDirectory(_ item: SpaceLensItem) {
        isLoadingDirectory = true
        scannedPath = item.path
        let targetID = item.id
        let targetPath = item.path

        Task {
            do {
                var loadedItem = try await DiskAnalyzer.scanSpaceLensDirectory(at: URL(fileURLWithPath: targetPath)) { progress in
                    Task { @MainActor in
                        self.scannedPath = progress.scannedPath
                        self.scanProgress = progress.progress
                    }
                }
                loadedItem.id = targetID

                if var rootItem {
                    replaceItem(loadedItem, in: &rootItem)
                    self.rootItem = rootItem
                }
            } catch {
                errorMessage = String(localized: "无法读取 \(item.name)：\(error.localizedDescription)")
            }
            isLoadingDirectory = false
        }
    }
    
    @discardableResult
    private func replaceItem(_ replacement: SpaceLensItem, in item: inout SpaceLensItem) -> Bool {
        for index in item.children.indices {
            if item.children[index].id == replacement.id {
                item.children[index] = replacement
                return true
            }
            if replaceItem(replacement, in: &item.children[index]) {
                return true
            }
        }
        return false
    }
    
    /// 从树中移除已删除的节点，并把被删数据从各层祖先的 size/itemCount 中扣除。
    /// 注意：不能用 `children.reduce(0) { $0 + $1.size }` 重算 size ——
    /// 每层还聚合了未建模为子节点的直属文件（"其他"节点之外的部分），
    /// 用 children 求和重算会把这部分大小丢掉。正确做法是从原 size 中减去被删子项 size 之和。
    @discardableResult
    private func removeItems(_ ids: Set<SpaceLensItem.ID>, from item: inout SpaceLensItem) -> (size: Int64, count: Int) {
        var removedSize: Int64 = 0
        var removedCount = 0

        var directRemovedIndices: [Int] = []
        for (index, child) in item.children.enumerated() where ids.contains(child.id) {
            removedSize += child.size
            removedCount += 1 + child.itemCount
            directRemovedIndices.append(index)
        }
        for index in directRemovedIndices.reversed() {
            item.children.remove(at: index)
        }

        for index in item.children.indices {
            let removedBelow = removeItems(ids, from: &item.children[index])
            removedSize += removedBelow.size
            removedCount += removedBelow.count
        }

        if removedSize != 0 || removedCount != 0 {
            item.size -= removedSize
            item.itemCount -= removedCount
        }

        return (removedSize, removedCount)
    }
    
    private func node(in root: SpaceLensItem, path: [SpaceLensItem.ID]) -> SpaceLensItem? {
        guard let nextID = path.first else { return root }
        guard let next = root.children.first(where: { $0.id == nextID }) else { return root }
        return node(in: next, path: Array(path.dropFirst()))
    }
}

private struct SpaceLensBackground: View {
    var body: some View {
        AppTheme.primaryGradient
            .ignoresSafeArea()
    }
}

private struct SpaceLensTopBar: View {
    let leading: AnyView?

    init<Leading: View>(@ViewBuilder leading: () -> Leading) {
        self.leading = AnyView(leading())
    }

    init() {
        self.leading = nil
    }

    var body: some View {
        PageHeader(title: String(localized: "存储地图"), subtitle: String(localized: "可视化整盘占用，找到吃掉空间的目录")) {
            HStack(spacing: 12) {
                if let leading {
                    leading
                }
                StorageMapModePicker()
            }
        }
    }
}

private struct SpaceLensIntroView: View {
    @ObservedObject var viewModel: SpaceLensViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            SpaceLensTopBar()

            ScrollView(showsIndicators: false) {
                ScanIntroView(
                    icon: "chart.pie",
                    title: String(localized: "看清每一 GB 去了哪里"),
                    message: String(localized: "扫描整盘目录占用，按大小层层浏览，找到真正吃掉空间的文件夹并安全清理。"),
                    points: [String(localized: "存储占用可视化分布"), String(localized: "包含隐藏文件与系统目录"), String(localized: "删除先入废纸篓，可随时恢复"), String(localized: "支持逐层钻取与多选")],
                    action: { viewModel.startScan() }
                )
                .padding(.horizontal, CosmicSizes.pagePadding)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.danger)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: CosmicSizes.controlRadius)
                            .fill(AppTheme.danger.opacity(0.12))
                    )
                    .padding(.leading, CosmicSizes.pagePadding)
                    .padding(.bottom, 28)
            }
        }
    }
}

private struct SpaceLensScanningView: View {
    @ObservedObject var viewModel: SpaceLensViewModel

    var body: some View {
        VStack(spacing: 0) {
            SpaceLensTopBar()

            Spacer()

            VStack(spacing: 32) {
                ZStack {
                    Circle()
                        .stroke(AppTheme.ink(0.08), lineWidth: 4)
                        .frame(width: 132, height: 132)
                    Circle()
                        .trim(from: 0, to: max(0.02, min(viewModel.scanProgress, 0.98)))
                        .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 132, height: 132)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.2), value: viewModel.scanProgress)
                    Text("\(Int(viewModel.scanProgress * 100))%")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(AppTheme.textPrimary)
                }

                VStack(spacing: 16) {
                    Text("正在扫描存储空间...")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)

                    SpaceLensPathTicker(
                        paths: viewModel.recentScannedPaths,
                        scannedItems: viewModel.scannedItems
                    )
                    .frame(maxWidth: 720)
                }
            }

            Spacer()

            Button("停止扫描", action: viewModel.stopScan)
                .buttonStyle(NeonOutlineButtonStyle())
                .padding(.bottom, 32)
        }
    }
}

private struct SpaceLensPathTicker: View {
    let paths: [String]
    let scannedItems: Int

    private static let opacities: [Double] = [0.82, 0.56, 0.38, 0.24, 0.14, 0.08, 0.04]
    private static let sizes: [CGFloat]    = [15,   13,   12,   11,   11,   10,   10]

    var body: some View {
        VStack(spacing: 0) {
            // Scrolling path ticker
            ZStack(alignment: .top) {
                ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                    let opacity = index < Self.opacities.count ? Self.opacities[index] : 0.03
                    let fontSize = index < Self.sizes.count ? Self.sizes[index] : 10
                    Text(displayName(for: path))
                        .font(.system(size: fontSize, weight: index == 0 ? .semibold : .regular, design: .monospaced))
                        .foregroundColor(AppTheme.ink(opacity))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity)
                        .padding(.top, CGFloat(index) * 19)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                        .id(path)
                }
            }
            .frame(height: 148, alignment: .top)
            .clipped()
            .animation(.easeOut(duration: 0.14), value: paths)

            Text("已扫描 \(scannedItems) 个文件夹")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppTheme.ink(0.36))
                .padding(.top, 10)
        }
    }

    private func displayName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let last = url.lastPathComponent
        if last.isEmpty || path == "/" { return "/" }
        // Show last two path components for context: "Library / Caches"
        let parent = url.deletingLastPathComponent().lastPathComponent
        if parent.isEmpty || parent == "/" { return "/\(last)" }
        return "\(parent) / \(last)"
    }
}

private struct SpaceLensResultsView: View {
    @ObservedObject var viewModel: SpaceLensViewModel
    @FocusState private var keyboardFocused: Bool
    @AppStorage(FolderMapStyle.storageKey) private var mapStyle: FolderMapStyle = .bubbles
    
    var body: some View {
        VStack(spacing: 0) {
            SpaceLensTopBar {
                Button(action: viewModel.restart) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12, weight: .medium))
                        Text("重新扫描")
                    }
                }
                .buttonStyle(NeonOutlineButtonStyle())
            }

            navigationBar
                .padding(.top, 20)
            
            HStack(alignment: .top, spacing: 20) {
                directoryList
                    .frame(width: 400)

                switch mapStyle {
                case .bubbles:
                    SpaceLensBubbleMap(
                        items: Array(viewModel.currentChildren.prefix(10)),
                        totalSize: max(viewModel.currentItem?.size ?? 1, 1),
                        selectedIDs: viewModel.selectedIDs,
                        basket: viewModel.basket,
                        selectAction: viewModel.toggleSelection,
                        enterAction: viewModel.enter,
                        basketAction: viewModel.addToBasket,
                        removeFromBasket: viewModel.removeFromBasket,
                        quickLookAction: viewModel.quickLook
                    )
                case .treemap:
                    StorageTreemapView(viewModel: viewModel)
                        .padding(.bottom, 16)
                }
            }
            .padding(.horizontal, CosmicSizes.pagePadding)
            .padding(.top, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CosmicSizes.pagePadding)
                    .padding(.top, 8)
            } else if let restore = viewModel.lastRestoreResult {
                (restore.failedPaths.isEmpty
                     ? Text("已恢复 \(restore.restoredCount) 项")
                     : Text("已恢复 \(restore.restoredCount) 项，\(restore.failedPaths.count) 项未能恢复"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CosmicSizes.pagePadding)
                    .padding(.top, 8)
            }

            if viewModel.unreadableCount > 0 {
                HStack(spacing: 10) {
                    Text("有 \(viewModel.unreadableCount) 个目录因系统权限未纳入统计，授权后重新扫描即可看到完整占用")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button("授予完全磁盘访问权限") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(NeonOutlineButtonStyle())
                    .controlSize(.small)
                }
                .padding(.horizontal, CosmicSizes.pagePadding)
                .padding(.vertical, 8)
            }

            StorageBasketBar(viewModel: viewModel)
        }
        .overlay(alignment: .bottom) {
            if let toast = viewModel.basketToast {
                StorageBasketToastView(toast: toast)
                    .padding(.bottom, 92)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .id(toast.id)
            }
        }
        .animation(.easeOut(duration: 0.2), value: viewModel.basketToast)
        // 键盘：B 加入暂存篮、空格快速查看、上下键移动焦点、回车进入文件夹。
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        .onAppear { keyboardFocused = true }
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            switch press.key {
            case .upArrow:
                viewModel.moveFocus(by: -1)
            case .downArrow:
                viewModel.moveFocus(by: 1)
            case .space:
                viewModel.toggleQuickLook()
            case .return:
                guard let item = viewModel.focusedItem else { return .ignored }
                viewModel.enter(item)
            case .delete:
                viewModel.goBack()
            default:
                guard press.characters.lowercased() == "b" else { return .ignored }
                viewModel.addKeyboardTargetToBasket()
            }
            return .handled
        }
    }
    
    private var navigationBar: some View {
        HStack(spacing: 8) {
            Button(action: viewModel.goBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: CosmicSizes.controlRadius))
            .foregroundColor(viewModel.canNavigateBack ? AppTheme.textPrimary : AppTheme.textMuted.opacity(0.5))
            .background(RoundedRectangle(cornerRadius: CosmicSizes.controlRadius).fill(AppTheme.ink(0.07)))
            .disabled(!viewModel.canNavigateBack)

            Button(action: viewModel.goRoot) {
                Image(systemName: "house")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: CosmicSizes.controlRadius))
            .foregroundColor(AppTheme.textSecondary)
            .background(RoundedRectangle(cornerRadius: CosmicSizes.controlRadius).fill(AppTheme.ink(0.07)))

            HStack(spacing: 8) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textSecondary)
                Text(viewModel.currentItem?.name ?? "Macintosh HD")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: CosmicSizes.controlRadius)
                    .fill(AppTheme.ink(0.05))
                    .overlay(RoundedRectangle(cornerRadius: CosmicSizes.controlRadius).stroke(AppTheme.surfaceBorder, lineWidth: 1))
            )

            FolderMapStylePicker(style: $mapStyle)
        }
        .padding(.horizontal, CosmicSizes.pagePadding)
    }
    
    private var directoryList: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let item = viewModel.currentItem {
                HStack(spacing: 12) {
                    Image(systemName: item.path == "/" ? "internaldrive" : "folder")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(AppTheme.textSecondary)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 10).fill(AppTheme.ink(0.06)))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(AppTheme.textPrimary)
                        Text("\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) · \(item.children.count) 项")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.textMuted)
                    }
                }
            }

            HiddenSpaceNote(purgeable: viewModel.purgeableSpace, unmapped: viewModel.unmappedSpace)

            HStack(spacing: 8) {
                (viewModel.selectedItems.isEmpty ? Text("未选择项目") : Text("已选 \(viewModel.selectedItems.count) 项 · \(viewModel.selectedSizeText)"))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textSecondary)
                Spacer()
                if viewModel.selectedItems.isEmpty {
                    Text("悬停后按 B 加入暂存篮，空格快速查看")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.textMuted)
                        .lineLimit(1)
                } else {
                    Button(action: viewModel.addSelectionToBasket) {
                        Label("加入暂存篮", systemImage: "tray.and.arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(NeonOutlineButtonStyle(color: AppTheme.accent))
                    .controlSize(.small)
                    .disabled(viewModel.isDeleting)
                }
            }
            .frame(height: 28)

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    if viewModel.isLoadingDirectory && viewModel.currentChildren.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .tint(AppTheme.textSecondary)
                            Text("正在读取当前文件夹...")
                                .font(.system(size: 13))
                                .foregroundColor(AppTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }

                    ForEach(viewModel.currentChildren) { item in
                        SpaceLensListRow(
                            item: item,
                            isSelected: viewModel.selectedIDs.contains(item.id),
                            isFocused: viewModel.focusedID == item.id,
                            basketState: BasketMembership(item: item, basket: viewModel.basket),
                            selectAction: { viewModel.toggleSelection(item) },
                            enterAction: { viewModel.enter(item) },
                            basketAction: { viewModel.addToBasket(item) },
                            removeFromBasket: { viewModel.removeFromBasket(item.id) },
                            quickLookAction: { viewModel.quickLook(item) },
                            hoverAction: { hovering in
                                if hovering {
                                    viewModel.focusedID = item.id
                                }
                            }
                        )
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .themeCard()
    }
}

/// 某个节点与暂存篮的关系：本身在篮中、被上层文件夹包含、或其下有子项在篮中。
enum BasketMembership: Equatable {
    case none
    case entry
    case coveredBy(String)
    case hasDescendants(Int)

    init(item: SpaceLensItem, basket: StorageBasket) {
        guard !basket.isEmpty, !item.isVirtual else { self = .none; return }
        if basket.contains(id: item.id) {
            self = .entry
        } else if let ancestor = basket.entry(covering: item.path) {
            self = .coveredBy(ancestor.name)
        } else {
            let count = basket.descendantCount(of: item.path)
            self = count > 0 ? .hasDescendants(count) : .none
        }
    }

    var isInBasket: Bool {
        switch self {
        case .entry, .coveredBy: return true
        case .none, .hasDescendants: return false
        }
    }
}

private struct SpaceLensListRow: View {
    let item: SpaceLensItem
    let isSelected: Bool
    let isFocused: Bool
    let basketState: BasketMembership
    let selectAction: () -> Void
    let enterAction: () -> Void
    let basketAction: () -> Void
    let removeFromBasket: () -> Void
    let quickLookAction: () -> Void
    let hoverAction: (Bool) -> Void

    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 10) {
            Button(action: selectAction) {
                Image(systemName: item.isVirtual ? "ellipsis.circle" : (isSelected ? "checkmark.square.fill" : "square"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(item.isVirtual ? AppTheme.textMuted : (isSelected ? AppTheme.accent : AppTheme.textMuted))
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .disabled(item.isVirtual || basketState.isInBasket)

            Button(action: enterAction) {
                HStack(spacing: 10) {
                    Image(systemName: item.isDirectory ? "folder" : "doc")
                        .font(.system(size: 15))
                        .foregroundColor(basketState.isInBasket ? AppTheme.accent : (item.isReadable ? AppTheme.textSecondary : AppTheme.textMuted.opacity(0.6)))
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(item.isReadable ? AppTheme.textPrimary : AppTheme.textMuted)
                            .lineLimit(1)
                        subtitle
                    }

                    Spacer(minLength: 6)

                    if !(isHovered || isFocused) || item.isVirtual {
                        Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(basketState.isInBasket ? AppTheme.accent : AppTheme.textSecondary)
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!item.isDirectory || !item.isReadable || item.isVirtual)

            if (isHovered || isFocused) && !item.isVirtual {
                HStack(spacing: 2) {
                    RowIconButton(systemName: "eye", help: String(localized: "快速查看（空格）"), action: quickLookAction)
                    if !basketState.isInBasket {
                        RowIconButton(systemName: "tray.and.arrow.down", help: String(localized: "加入暂存篮（B）"), tint: AppTheme.accent, action: basketAction)
                    }
                }
            }

            basketBadge
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: CosmicSizes.controlRadius)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CosmicSizes.controlRadius)
                .stroke(basketState == .entry ? AppTheme.accent.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .onHover { hovering in
            isHovered = hovering
            hoverAction(hovering)
        }
        .draggable(StorageBasketDropPayload.encode(item.id)) {
            BasketDragPreview(name: item.name, size: item.size, isDirectory: item.isDirectory)
        }
        .contextMenu {
            if !item.isVirtual {
                Button {
                    SpaceLensFinderOpener.open(item)
                } label: {
                    Label("在 Finder 中打开", systemImage: "folder")
                }
                Button {
                    quickLookAction()
                } label: {
                    Label("快速查看", systemImage: "eye")
                }
                Divider()
                if basketState == .entry {
                    Button {
                        removeFromBasket()
                    } label: {
                        Label("移出暂存篮", systemImage: "tray.and.arrow.up")
                    }
                } else if !basketState.isInBasket {
                    Button {
                        basketAction()
                    } label: {
                        Label("加入暂存篮", systemImage: "tray.and.arrow.down")
                    }
                }
                Button(isSelected ? String(localized: "取消选择") : String(localized: "选择")) { selectAction() }
                    .disabled(basketState.isInBasket)
                if item.isDirectory && item.isReadable {
                    Button("进入目录") { enterAction() }
                }
            }
        }
    }

    private var rowFill: Color {
        if basketState.isInBasket { return AppTheme.accentSoft }
        if isSelected { return AppTheme.ink(0.08) }
        if isHovered || isFocused { return AppTheme.ink(0.045) }
        return Color.clear
    }

    @ViewBuilder
    private var subtitle: some View {
        switch basketState {
        case .coveredBy(let name):
            Text("已在暂存篮的「\(name)」中")
                .font(.system(size: 11))
                .foregroundColor(AppTheme.accent)
                .lineLimit(1)
        case .hasDescendants(let count):
            Text("\(count) 个子项在暂存篮中")
                .font(.system(size: 11))
                .foregroundColor(AppTheme.accent)
                .lineLimit(1)
        case .none, .entry:
            Text(SpaceLensItem.cleanPath(item.path))
                .font(.system(size: 11))
                .foregroundColor(AppTheme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var basketBadge: some View {
        switch basketState {
        case .entry:
            Button(action: removeFromBasket) {
                Image(systemName: "basket.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppTheme.accent)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "已在暂存篮中，点按移出"))
        case .coveredBy:
            Image(systemName: "basket")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppTheme.accent.opacity(0.7))
                .frame(width: 22, height: 22)
        case .none, .hasDescendants:
            EmptyView()
        }
    }
}

private struct RowIconButton: View {
    let systemName: String
    let help: String
    var tint: Color = AppTheme.textSecondary
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(AppTheme.ink(isHovered ? 0.10 : 0.05))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 拖动行或气泡时跟手的小卡片。
struct BasketDragPreview: View {
    let name: String
    let size: Int64
    let isDirectory: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isDirectory ? "folder.fill" : "doc.fill")
                .foregroundColor(AppTheme.accent)
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppTheme.textPrimary)
                .lineLimit(1)
            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundColor(AppTheme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: CosmicSizes.controlRadius)
                .fill(AppTheme.surfaceHover)
                .overlay(RoundedRectangle(cornerRadius: CosmicSizes.controlRadius).stroke(AppTheme.accent.opacity(0.5), lineWidth: 1))
        )
    }
}

/// 目录地图摘要里的小提示：系统可自动释放的空间与地图外占用，并可跳到「系统数据」。
private struct HiddenSpaceNote: View {
    let purgeable: Int64?
    let unmapped: Int64?

    @AppStorage(StorageMapMode.storageKey) private var mode: StorageMapMode = .folderMap

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.textMuted)
                Text("隐藏与可清除空间")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppTheme.textSecondary)
                Spacer(minLength: 6)
                Button {
                    mode = .systemData
                } label: {
                    HStack(spacing: 2) {
                        Text("查看系统数据")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(AppTheme.textMuted)
                .monospacedDigit()
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: CosmicSizes.controlRadius)
                .fill(AppTheme.ink(0.035))
        )
    }

    private var detail: String {
        let purgeableText = purgeable.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        var text = String(localized: "可清除 \(purgeableText)，系统需要时自动释放")
        if let unmapped, unmapped > 0 {
            let unmappedText = ByteCountFormatter.string(fromByteCount: unmapped, countStyle: .file)
            text += String(localized: " · 地图外占用 \(unmappedText)")
        }
        return text
    }
}

/// 在 Finder 中打开空间透镜节点：目录直接进入其内部，文件则在父目录中选中定位。
enum SpaceLensFinderOpener {
    static func open(_ item: SpaceLensItem) {
        let url = URL(fileURLWithPath: item.path)
        if item.isDirectory {
            NSWorkspace.shared.open(url)
        } else {
            // 文件与包（.app 等）：在父目录中定位选中，避免误启动
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

private struct SpaceLensBubbleMap: View {
    let items: [SpaceLensItem]
    let totalSize: Int64
    let selectedIDs: Set<SpaceLensItem.ID>
    let basket: StorageBasket
    let selectAction: (SpaceLensItem) -> Void
    let enterAction: (SpaceLensItem) -> Void
    let basketAction: (SpaceLensItem) -> Void
    let removeFromBasket: (SpaceLensItem.ID) -> Void
    let quickLookAction: (SpaceLensItem) -> Void
    
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let diameter = bubbleDiameter(for: item, in: proxy.size, index: index)
                    let position = bubblePosition(index: index, size: proxy.size, diameter: diameter)
                    SpaceLensBubble(
                        item: item,
                        diameter: diameter,
                        isSelected: selectedIDs.contains(item.id),
                        basketState: BasketMembership(item: item, basket: basket),
                        selectAction: { selectAction(item) },
                        enterAction: { enterAction(item) },
                        basketAction: { basketAction(item) },
                        removeFromBasket: { removeFromBasket(item.id) },
                        quickLookAction: { quickLookAction(item) }
                    )
                    .position(position)
                }
            }
        }
    }
    
    private func bubbleDiameter(for item: SpaceLensItem, in size: CGSize, index: Int) -> CGFloat {
        let maxDiameter = min(size.width, size.height) * 0.46
        let minDiameter: CGFloat = index < 4 ? 110 : 82
        let ratio = sqrt(Double(max(item.size, 1)) / Double(max(totalSize, 1)))
        return max(minDiameter, maxDiameter * CGFloat(ratio))
    }
    
    private func bubblePosition(index: Int, size: CGSize, diameter: CGFloat) -> CGPoint {
        let points = [
            CGPoint(x: size.width * 0.39, y: size.height * 0.48),
            CGPoint(x: size.width * 0.73, y: size.height * 0.46),
            CGPoint(x: size.width * 0.63, y: size.height * 0.18),
            CGPoint(x: size.width * 0.76, y: size.height * 0.75),
            CGPoint(x: size.width * 0.48, y: size.height * 0.82),
            CGPoint(x: size.width * 0.24, y: size.height * 0.80),
            CGPoint(x: size.width * 0.90, y: size.height * 0.30),
            CGPoint(x: size.width * 0.47, y: size.height * 0.22),
            CGPoint(x: size.width * 0.86, y: size.height * 0.70),
            CGPoint(x: size.width * 0.58, y: size.height * 0.62)
        ]
        let point = points[index % points.count]
        let radius = diameter / 2
        return CGPoint(
            x: min(max(point.x, radius + 8), size.width - radius - 8),
            y: min(max(point.y, radius + 8), size.height - radius - 8)
        )
    }
}

private struct SpaceLensBubble: View {
    let item: SpaceLensItem
    let diameter: CGFloat
    let isSelected: Bool
    let basketState: BasketMembership
    let selectAction: () -> Void
    let enterAction: () -> Void
    let basketAction: () -> Void
    let removeFromBasket: () -> Void
    let quickLookAction: () -> Void

    private var isHighlighted: Bool { isSelected || basketState.isInBasket }
    
    var body: some View {
        Button(action: item.isDirectory && item.isReadable && !item.isVirtual ? enterAction : selectAction) {
            ZStack {
                Circle()
                    .fill(isHighlighted ? AppTheme.accent.opacity(basketState.isInBasket ? 0.12 : 0.16) : AppTheme.ink(0.06))
                    .overlay(
                        Circle().stroke(
                            isHighlighted ? AppTheme.accent : AppTheme.ink(0.14),
                            style: StrokeStyle(lineWidth: isHighlighted ? 2 : 1, dash: basketState.isInBasket ? [6, 4] : [])
                        )
                    )

                VStack(spacing: max(4, diameter * 0.03)) {
                    Image(systemName: basketState.isInBasket ? "basket.fill" : (item.isVirtual ? "ellipsis.circle" : (item.isDirectory ? "folder" : "doc")))
                        .font(.system(size: max(16, diameter * 0.16), weight: .medium))
                        .foregroundColor(isHighlighted ? AppTheme.accent : AppTheme.textSecondary)
                    Text(item.name)
                        .font(.system(size: max(11, diameter * 0.075), weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                        .font(.system(size: max(10, diameter * 0.065), weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(AppTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                }
                .padding(diameter * 0.12)
            }
            .frame(width: diameter, height: diameter)
            .overlay(alignment: .topTrailing) {
                if case .hasDescendants(let count) = basketState {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.onAccent)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Circle().fill(AppTheme.accent))
                        .offset(x: -diameter * 0.1, y: diameter * 0.1)
                        .help(String(localized: "\(count) 个子项在暂存篮中"))
                }
            }
        }
        .buttonStyle(.plain)
        .draggable(StorageBasketDropPayload.encode(item.id)) {
            BasketDragPreview(name: item.name, size: item.size, isDirectory: item.isDirectory)
        }
        .contextMenu {
            if !item.isVirtual {
                Button {
                    SpaceLensFinderOpener.open(item)
                } label: {
                    Label("在 Finder 中打开", systemImage: "folder")
                }
                Button {
                    quickLookAction()
                } label: {
                    Label("快速查看", systemImage: "eye")
                }
                Divider()
                if basketState == .entry {
                    Button {
                        removeFromBasket()
                    } label: {
                        Label("移出暂存篮", systemImage: "tray.and.arrow.up")
                    }
                } else if !basketState.isInBasket {
                    Button {
                        basketAction()
                    } label: {
                        Label("加入暂存篮", systemImage: "tray.and.arrow.down")
                    }
                }
                Button(isSelected ? String(localized: "取消选择") : String(localized: "选择")) { selectAction() }
                    .disabled(basketState.isInBasket)
            }
            if item.isDirectory && item.isReadable && !item.isVirtual {
                Button("进入目录") { enterAction() }
            }
        }
    }
}

private struct SpaceLensFeatureRow: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppTheme.accent)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(AppTheme.textSecondary)
        }
    }
}
