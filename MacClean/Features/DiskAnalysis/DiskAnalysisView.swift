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
        .alert("删除所选项目？", isPresented: $viewModel.showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("移到废纸篓", role: .destructive) {
                viewModel.deleteSelectedItems()
            }
        } message: {
            Text("将 \(viewModel.selectedItems.count) 个项目移到废纸篓，释放约 \(viewModel.selectedSizeText)。可在「清理记录」中恢复。")
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
    @Published var showDeleteConfirmation = false
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

                rootItem = result.root
                diskInfo = result.diskInfo
                unreadableCount = result.unreadableCount
                scanProgress = 1
                phase = .results
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
        currentPath.append(item.id)
        selectedIDs = []
        if item.children.isEmpty {
            loadDirectory(item)
        }
    }
    
    func goBack() {
        guard !currentPath.isEmpty else { return }
        currentPath.removeLast()
        selectedIDs = []
    }
    
    func goRoot() {
        currentPath = []
        selectedIDs = []
    }
    
    func toggleSelection(_ item: SpaceLensItem) {
        guard !item.isVirtual else { return }
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }
    
    func requestDeleteSelected() {
        guard !selectedItems.isEmpty, !isDeleting else { return }
        guard ProGate.allowAction() else { return }
        showDeleteConfirmation = true
    }
    
    /// 走 CleanupManager（PathGuard 的 SpaceLens 规则 + 清理记录），删除后可在完成页或「清理记录」中撤销。
    func deleteSelectedItems() {
        let itemsToDelete = selectedItems.filter { !$0.isVirtual }
        guard !itemsToDelete.isEmpty, !isDeleting else { return }

        isDeleting = true
        errorMessage = nil
        lastRestoreResult = nil
        let cleanables = itemsToDelete.map { item -> CleanableItem in
            var cleanable = CleanableItem(
                name: item.name,
                path: item.path,
                size: item.size,
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

            // 只把确实已离开原位置的节点从树里摘掉，受保护或失败的保留。
            let fileManager = FileManager.default
            let deleted = itemsToDelete.filter { !fileManager.fileExists(atPath: $0.path) }
            let deletedIDs = Set(deleted.map(\.id))
            if !deletedIDs.isEmpty, var rootItem {
                treeBeforeLastClean = snapshot
                lastCleanedIDs = Dictionary(uniqueKeysWithValues: deleted.map { ($0.id, $0.path) })
                removeItems(deletedIDs, from: &rootItem)
                self.rootItem = rootItem
                selectedIDs.subtract(deletedIDs)
            }
            isDeleting = false
            if lastCleanResult != nil {
                showCompletion = true
            }
        }
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

                SpaceLensBubbleMap(
                    items: Array(viewModel.currentChildren.prefix(10)),
                    totalSize: max(viewModel.currentItem?.size ?? 1, 1),
                    selectedIDs: viewModel.selectedIDs,
                    selectAction: viewModel.toggleSelection,
                    enterAction: viewModel.enter
                )
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

            resultFooter
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
        }
        .padding(.horizontal, CosmicSizes.pagePadding)
    }
    
    private var directoryList: some View {
        VStack(alignment: .leading, spacing: 16) {
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

            HStack {
                (viewModel.selectedItems.isEmpty ? Text("未选择项目") : Text("已选 \(viewModel.selectedItems.count) 项"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.textSecondary)
                Spacer()
                Text(viewModel.selectedSizeText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textMuted)
            }

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
                            selectAction: { viewModel.toggleSelection(item) },
                            enterAction: { viewModel.enter(item) }
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
    
    private var resultFooter: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if let diskInfo = viewModel.diskInfo {
                    Text("\(diskInfo.volumeName) · 已用 \(ByteCountFormatter.string(fromByteCount: diskInfo.usedSpace, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: diskInfo.totalSpace, countStyle: .file))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.textSecondary)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppTheme.ink(0.10))
                        Capsule()
                            .fill(AppTheme.accent)
                            .frame(width: proxy.size.width * CGFloat(viewModel.diskInfo?.usedPercentage ?? 0))
                    }
                }
                .frame(width: 260, height: 5)
            }

            Spacer()

            Text("已勾选 \(viewModel.selectedItems.count) 项 · \(viewModel.selectedSizeText)")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundColor(AppTheme.textSecondary)

            Button(action: viewModel.requestDeleteSelected) {
                HStack(spacing: 6) {
                    if viewModel.isDeleting {
                        ProgressView().scaleEffect(0.6).tint(AppTheme.onAccent)
                    } else {
                        Image(systemName: "trash")
                    }
                    Text("移到废纸篓")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(viewModel.selectedItems.isEmpty ? AppTheme.textMuted : AppTheme.onAccent)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: CosmicSizes.controlRadius)
                        .fill(viewModel.selectedItems.isEmpty ? AppTheme.ink(0.08) : AppTheme.danger)
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.selectedItems.isEmpty || viewModel.isDeleting)
        }
        .padding(.horizontal, CosmicSizes.pagePadding)
        .padding(.vertical, 16)
        .background(
            Rectangle()
                .fill(AppTheme.sidebarColor.opacity(0.92))
                .overlay(Rectangle().fill(AppTheme.divider).frame(height: 1), alignment: .top)
        )
    }
}

private struct SpaceLensListRow: View {
    let item: SpaceLensItem
    let isSelected: Bool
    let selectAction: () -> Void
    let enterAction: () -> Void
    
    var body: some View {
        HStack(spacing: 10) {
            Button(action: selectAction) {
                Image(systemName: item.isVirtual ? "ellipsis.circle" : (isSelected ? "checkmark.square.fill" : "square"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(item.isVirtual ? AppTheme.textMuted : (isSelected ? AppTheme.accent : AppTheme.textMuted))
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .disabled(item.isVirtual)

            Button(action: enterAction) {
                HStack(spacing: 10) {
                    Image(systemName: item.isDirectory ? "folder" : "doc")
                        .font(.system(size: 15))
                        .foregroundColor(item.isReadable ? AppTheme.textSecondary : AppTheme.textMuted.opacity(0.6))
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(item.isReadable ? AppTheme.textPrimary : AppTheme.textMuted)
                            .lineLimit(1)
                        Text(SpaceLensItem.cleanPath(item.path))
                            .font(.system(size: 11))
                            .foregroundColor(AppTheme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(AppTheme.textSecondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!item.isDirectory || !item.isReadable || item.isVirtual)
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: CosmicSizes.controlRadius)
                .fill(isSelected ? AppTheme.ink(0.08) : Color.clear)
        )
        .contextMenu {
            if !item.isVirtual {
                Button {
                    SpaceLensFinderOpener.open(item)
                } label: {
                    Label("在 Finder 中打开", systemImage: "folder")
                }
                Button(isSelected ? String(localized: "取消选择") : String(localized: "选择")) { selectAction() }
                if item.isDirectory && item.isReadable {
                    Button("进入目录") { enterAction() }
                }
            }
        }
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
    let selectAction: (SpaceLensItem) -> Void
    let enterAction: (SpaceLensItem) -> Void
    
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
                        selectAction: { selectAction(item) },
                        enterAction: { enterAction(item) }
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
    let selectAction: () -> Void
    let enterAction: () -> Void
    
    var body: some View {
        Button(action: item.isDirectory && item.isReadable && !item.isVirtual ? enterAction : selectAction) {
            ZStack {
                Circle()
                    .fill(isSelected ? AppTheme.accent.opacity(0.16) : AppTheme.ink(0.06))
                    .overlay(
                        Circle().stroke(
                            isSelected ? AppTheme.accent : AppTheme.ink(0.14),
                            lineWidth: isSelected ? 2 : 1
                        )
                    )

                VStack(spacing: max(4, diameter * 0.03)) {
                    Image(systemName: item.isVirtual ? "ellipsis.circle" : (item.isDirectory ? "folder" : "doc"))
                        .font(.system(size: max(16, diameter * 0.16), weight: .medium))
                        .foregroundColor(isSelected ? AppTheme.accent : AppTheme.textSecondary)
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
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !item.isVirtual {
                Button {
                    SpaceLensFinderOpener.open(item)
                } label: {
                    Label("在 Finder 中打开", systemImage: "folder")
                }
                Button(isSelected ? String(localized: "取消选择") : String(localized: "选择")) { selectAction() }
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
