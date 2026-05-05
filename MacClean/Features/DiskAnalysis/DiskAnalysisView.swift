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
    @StateObject private var viewModel = SpaceLensViewModel()
    
    var body: some View {
        ZStack {
            SpaceLensBackground()
            
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
            Text("将 \(viewModel.selectedItems.count) 个项目移到废纸篓，释放约 \(viewModel.selectedSizeText)。")
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

        scanTask = Task {
            do {
                let result = try await DiskAnalyzer.shared.scanSpaceLens(rootURL: URL(fileURLWithPath: "/")) { progress in
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
                scanProgress = 1
                phase = .results
            } catch is CancellationError {
                phase = .intro
            } catch {
                errorMessage = "扫描失败：\(error.localizedDescription)"
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
        showDeleteConfirmation = true
    }
    
    func deleteSelectedItems() {
        let itemsToDelete = selectedItems.filter { !$0.isVirtual }
        guard !itemsToDelete.isEmpty else { return }
        
        isDeleting = true
        Task {
            var deletedIDs: Set<SpaceLensItem.ID> = []
            for item in itemsToDelete {
                do {
                    try await moveToTrash(path: item.path)
                    deletedIDs.insert(item.id)
                } catch {
                    errorMessage = "无法删除 \(item.name)：\(error.localizedDescription)"
                }
            }
            
            if !deletedIDs.isEmpty, var rootItem {
                removeItems(deletedIDs, from: &rootItem)
                self.rootItem = rootItem
                selectedIDs.subtract(deletedIDs)
            }
            isDeleting = false
        }
    }
    
    private func moveToTrash(path: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle([URL(fileURLWithPath: path)]) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
    
    private func loadDirectory(_ item: SpaceLensItem) {
        isLoadingDirectory = true
        scannedPath = item.path
        let targetID = item.id
        let targetPath = item.path
        
        Task {
            do {
                var loadedItem = try await DiskAnalyzer.shared.scanSpaceLensDirectory(at: URL(fileURLWithPath: targetPath), progress: { progress in
                    Task { @MainActor in
                        self.scannedPath = progress.scannedPath
                        self.scanProgress = progress.progress
                    }
                }, partialResult: { partialItem in
                    Task { @MainActor in
                        var updatedItem = partialItem
                        updatedItem.id = targetID
                        if var rootItem = self.rootItem {
                            self.replaceItem(updatedItem, in: &rootItem)
                            self.rootItem = rootItem
                        }
                    }
                }
                )
                loadedItem.id = targetID
                
                if var rootItem {
                    replaceItem(loadedItem, in: &rootItem)
                    self.rootItem = rootItem
                }
            } catch {
                errorMessage = "无法读取 \(item.name)：\(error.localizedDescription)"
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
    
    @discardableResult
    private func removeItems(_ ids: Set<SpaceLensItem.ID>, from item: inout SpaceLensItem) -> Bool {
        let beforeCount = item.children.count
        item.children.removeAll { ids.contains($0.id) }
        var changed = beforeCount != item.children.count
        
        for index in item.children.indices {
            if removeItems(ids, from: &item.children[index]) {
                changed = true
            }
        }
        
        if changed {
            item.size = item.children.reduce(0) { $0 + $1.size }
            item.itemCount = item.children.count + item.children.reduce(0) { $0 + $1.itemCount }
        }
        return changed
    }
    
    private func node(in root: SpaceLensItem, path: [SpaceLensItem.ID]) -> SpaceLensItem? {
        guard let nextID = path.first else { return root }
        guard let next = root.children.first(where: { $0.id == nextID }) else { return root }
        return node(in: next, path: Array(path.dropFirst()))
    }
}

private struct SpaceLensBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hex: 0x120834),
                    Color(hex: 0x260A55),
                    Color(hex: 0x4A0D78),
                    Color(hex: 0x0D092A)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(hex: 0x7E2EFF).opacity(0.48), Color.clear],
                center: UnitPoint(x: 0.34, y: 0.50),
                startRadius: 30,
                endRadius: 620
            )
            RadialGradient(
                colors: [Color(hex: 0xB16BFF).opacity(0.28), Color.clear],
                center: UnitPoint(x: 0.60, y: 0.93),
                startRadius: 20,
                endRadius: 340
            )
        }
        .ignoresSafeArea()
    }
}

private struct SpaceLensTopBar: View {
    @EnvironmentObject var appState: AppState
    let leading: AnyView?
    
    init<Leading: View>(@ViewBuilder leading: () -> Leading) {
        self.leading = AnyView(leading())
    }
    
    init() {
        self.leading = nil
    }
    
    var body: some View {
        ZStack {
            HStack {
                if let leading {
                    leading
                }
                Spacer()
                if !appState.isLicensed {
                    Button(action: { appState.showLicenseActivation = true }) {
                        Text("解锁完整版")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Color(hex: 0x211A02))
                            .padding(.horizontal, 28)
                            .frame(height: 48)
                            .background(Capsule().fill(Color(hex: 0xFFD23F)))
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Text("空间透镜")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Color.white.opacity(0.74))
        }
        .padding(.horizontal, 34)
        .padding(.top, 20)
    }
}

private struct SpaceLensIntroView: View {
    @ObservedObject var viewModel: SpaceLensViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            SpaceLensTopBar()
            
            HStack(alignment: .center, spacing: 78) {
                SpaceLensHeroIcon()
                    .frame(width: 430, height: 430)
                    .padding(.leading, 46)
                
                VStack(alignment: .leading, spacing: 34) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("空间透镜")
                            .font(.system(size: 54, weight: .regular))
                            .foregroundColor(.white)
                        Text("直观地查看磁盘空间占用详情，快速清理存储。")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.64))
                    }
                    
                    VStack(alignment: .leading, spacing: 22) {
                        SpaceLensFeatureRow(icon: "internaldrive", title: "存储空间可视化分布图")
                        SpaceLensFeatureRow(icon: "doc.text.magnifyingglass", title: "显示被隐藏的文件")
                        SpaceLensFeatureRow(icon: "folder.fill", title: "大文件夹概览")
                    }
                    
                    HStack(spacing: 12) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 24))
                            .foregroundColor(Color.white.opacity(0.70))
                            .frame(width: 38, height: 38)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.14)))
                        Text("Macintosh HD")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Color.white.opacity(0.62))
                    }
                    .padding(.horizontal, 16)
                    .frame(width: 330, height: 62)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.white.opacity(0.16))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.18), lineWidth: 1))
                    )
                }
                .frame(maxWidth: 560, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            SpaceLensBottomButton(title: "扫描", isLoading: false, action: viewModel.startScan)
                .padding(.bottom, 18)
        }
        .overlay(alignment: .bottomLeading) {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: 0xFFD2EA))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.24)))
                    .padding(.leading, 34)
                    .padding(.bottom, 34)
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
                SpaceLensHeroIcon(isLarge: true)
                    .frame(width: 500, height: 390)

                VStack(spacing: 18) {
                    Text("正在可视化存储空间...")
                        .font(.system(size: 46, weight: .regular))
                        .foregroundColor(.white)

                    SpaceLensPathTicker(
                        paths: viewModel.recentScannedPaths,
                        scannedItems: viewModel.scannedItems
                    )
                    .frame(maxWidth: 860)
                }
            }

            Spacer()

            SpaceLensBottomButton(
                title: "停止",
                isLoading: true,
                progress: viewModel.scanProgress,
                action: viewModel.stopScan
            )
            .padding(.bottom, 18)
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
                        .foregroundColor(.white.opacity(opacity))
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
                .foregroundColor(Color.white.opacity(0.36))
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
                    HStack(spacing: 9) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("重新开始")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.72))
                }
                .buttonStyle(.plain)
            }
            
            navigationBar
                .padding(.top, 20)
            
            HStack(alignment: .top, spacing: 28) {
                directoryList
                    .frame(width: 430)
                
                SpaceLensBubbleMap(
                    items: Array(viewModel.currentChildren.prefix(10)),
                    totalSize: max(viewModel.currentItem?.size ?? 1, 1),
                    selectedIDs: viewModel.selectedIDs,
                    selectAction: viewModel.toggleSelection,
                    enterAction: viewModel.enter
                )
            }
            .padding(.horizontal, 34)
            .padding(.top, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            
            resultFooter
        }
    }
    
    private var navigationBar: some View {
        HStack(spacing: 12) {
            Button(action: viewModel.goBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .frame(width: 52, height: 52)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .foregroundColor(viewModel.canNavigateBack ? .white.opacity(0.78) : .white.opacity(0.22))
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.10)))
            .disabled(!viewModel.canNavigateBack)
            
            Button(action: viewModel.goRoot) {
                Image(systemName: "house.fill")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .frame(width: 52, height: 52)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .foregroundColor(.white.opacity(0.70))
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.10)))
            
            HStack(spacing: 10) {
                Image(systemName: "internaldrive")
                    .foregroundColor(Color.white.opacity(0.62))
                Text(viewModel.currentItem?.name ?? "Macintosh HD")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.13))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.13), lineWidth: 1))
            )
        }
        .padding(.horizontal, 34)
    }
    
    private var directoryList: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let item = viewModel.currentItem {
                HStack(spacing: 16) {
                    Image(systemName: item.path == "/" ? "internaldrive" : "folder.fill")
                        .font(.system(size: 38))
                        .foregroundColor(Color(hex: 0x59C7EE))
                        .frame(width: 58, height: 58)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.name)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                        Text("\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))  |  \(item.children.count) 项")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.58))
                    }
                }
            }
            
            HStack {
                Text("选择：\(viewModel.selectedItems.isEmpty ? "无" : "\(viewModel.selectedItems.count) 项")")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.80))
                Spacer()
                Text(viewModel.selectedSizeText)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.54))
            }
            
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    if viewModel.isLoadingDirectory {
                        HStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(0.78)
                                .tint(.white)
                            Text("正在读取当前文件夹...")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Color.white.opacity(0.62))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
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
                .padding(.bottom, 20)
            }
        }
        .padding(22)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.11))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.15), lineWidth: 1))
        )
    }
    
    private var resultFooter: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(viewModel.diskInfo?.volumeName ?? "Macintosh HD")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.25))
                        Capsule()
                            .fill(Color.white.opacity(0.72))
                            .frame(width: proxy.size.width * CGFloat(viewModel.diskInfo?.usedPercentage ?? 0))
                    }
                }
                .frame(width: 340, height: 8)
            }
            
            if let diskInfo = viewModel.diskInfo {
                Text("已用空间：\(ByteCountFormatter.string(fromByteCount: diskInfo.usedSpace, countStyle: .file))（共 \(ByteCountFormatter.string(fromByteCount: diskInfo.totalSpace, countStyle: .file))）")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.68))
            }
            
            Spacer()
            
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(Color.white.opacity(0.48))
                Text("已勾选 \(viewModel.selectedItems.count) 项  |  \(viewModel.selectedSizeText)")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.84))
            }
            
            Button(action: viewModel.requestDeleteSelected) {
                HStack(spacing: 8) {
                    if viewModel.isDeleting {
                        ProgressView().scaleEffect(0.72).tint(.white)
                    } else {
                        Image(systemName: "trash.fill")
                    }
                    Text("移到废纸篓")
                }
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(viewModel.selectedItems.isEmpty ? Color.white.opacity(0.32) : .white)
                .padding(.horizontal, 24)
                .frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(viewModel.selectedItems.isEmpty ? Color.white.opacity(0.10) : Color(hex: 0xB51E9D).opacity(0.78))
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.selectedItems.isEmpty || viewModel.isDeleting)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 20)
    }
}

private struct SpaceLensListRow: View {
    let item: SpaceLensItem
    let isSelected: Bool
    let selectAction: () -> Void
    let enterAction: () -> Void
    
    var body: some View {
        HStack(spacing: 14) {
            Button(action: selectAction) {
                Image(systemName: item.isVirtual ? "ellipsis.circle.fill" : (isSelected ? "checkmark.square.fill" : "info.square.fill"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(item.isVirtual ? Color.white.opacity(0.36) : (isSelected ? Color(hex: 0xFFD23F) : Color.white.opacity(0.54)))
                    .frame(width: 28)
            }
            .buttonStyle(.plain)
            .disabled(item.isVirtual)
            
            Button(action: enterAction) {
                HStack(spacing: 14) {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                        .font(.system(size: 26))
                        .foregroundColor(item.isReadable ? Color(hex: 0x55C4EB) : Color.white.opacity(0.30))
                        .frame(width: 36)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(item.isReadable ? .white : Color.white.opacity(0.44))
                            .lineLimit(1)
                        Text(SpaceLensItem.cleanPath(item.path))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.34))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    Spacer()
                    
                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.68))
                        .monospacedDigit()
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!item.isDirectory || !item.isReadable || item.isVirtual)
        }
        .padding(.horizontal, 10)
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.white.opacity(0.16) : Color.clear)
        )
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
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(isSelected ? 0.34 : 0.22),
                                Color(hex: 0x8E4BEF).opacity(0.50),
                                Color(hex: 0x2B0E63).opacity(0.80)
                            ],
                            center: .top,
                            startRadius: 8,
                            endRadius: diameter
                        )
                    )
                    .overlay(Circle().stroke(isSelected ? Color(hex: 0xFFD23F) : Color(hex: 0xB987FF).opacity(0.76), lineWidth: isSelected ? 3 : 2))
                    .shadow(color: Color(hex: 0x925CFF).opacity(0.35), radius: 18)
                
                VStack(spacing: max(6, diameter * 0.035)) {
                    Image(systemName: item.isVirtual ? "ellipsis.circle.fill" : (item.isDirectory ? "folder.fill" : "doc.fill"))
                        .font(.system(size: max(24, diameter * 0.20), weight: .medium))
                        .foregroundStyle(LinearGradient(colors: [Color(hex: 0x72D9FF), Color(hex: 0x2FA5D4)], startPoint: .top, endPoint: .bottom))
                    Text(item.name)
                        .font(.system(size: max(13, diameter * 0.082), weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                        .font(.system(size: max(12, diameter * 0.072), weight: .bold))
                        .foregroundColor(.white.opacity(0.88))
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
                Button(isSelected ? "取消选择" : "选择") { selectAction() }
            }
            if item.isDirectory && item.isReadable && !item.isVirtual {
                Button("进入目录") { enterAction() }
            }
        }
    }
}

private struct SpaceLensHeroIcon: View {
    var isLarge = false
    @State private var glow = false
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: isLarge ? 78 : 64)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x7D54FF), Color(hex: 0x241680)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: isLarge ? 78 : 64)
                        .stroke(Color.white.opacity(0.20), lineWidth: 3)
                )
                .shadow(color: Color(hex: 0x6F48FF).opacity(glow ? 0.80 : 0.44), radius: glow ? 42 : 28)
                .rotation3DEffect(.degrees(10), axis: (x: 1, y: 0, z: 0))
            
            Circle()
                .stroke(
                    LinearGradient(colors: [Color.white.opacity(0.92), Color(hex: 0x9D83FF)], startPoint: .top, endPoint: .bottom),
                    lineWidth: isLarge ? 42 : 34
                )
                .frame(width: isLarge ? 160 : 126, height: isLarge ? 160 : 126)
                .offset(x: -16, y: -22)
                .shadow(color: Color.white.opacity(0.22), radius: 16)
            
            Capsule()
                .fill(LinearGradient(colors: [Color(hex: 0xDDD5FF), Color(hex: 0x8B78FF)], startPoint: .top, endPoint: .bottom))
                .frame(width: isLarge ? 58 : 48, height: isLarge ? 90 : 74)
                .rotationEffect(.degrees(-35))
                .offset(x: isLarge ? 112 : 88, y: isLarge ? 76 : 58)
        }
        .padding(isLarge ? 38 : 46)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
    }
}

private struct SpaceLensFeatureRow: View {
    let icon: String
    let title: String
    
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 12).fill(CosmicTheme.accentGradient))
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white.opacity(0.92))
        }
    }
}

private struct SpaceLensBottomButton: View {
    let title: String
    let isLoading: Bool
    var progress: Double = 0
    let action: () -> Void
    @State private var rotation: Double = 0
    
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: 0x8E18FF), Color(hex: 0x4E05C8), Color(hex: 0x26006E)],
                            center: .top,
                            startRadius: 4,
                            endRadius: 72
                        )
                    )
                    .frame(width: 118, height: 118)
                    .overlay(Circle().stroke(Color.white.opacity(0.62), lineWidth: 2.4).padding(6))
                    .shadow(color: Color(hex: 0x8D2DFF).opacity(0.75), radius: 32)
                
                if isLoading {
                    Circle()
                        .trim(from: 0, to: max(0.10, min(progress, 0.96)))
                        .stroke(Color.white.opacity(0.86), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .frame(width: 112, height: 112)
                        .rotationEffect(.degrees(rotation - 90))
                        .animation(.easeInOut(duration: 0.18), value: progress)
                }
                
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            if isLoading {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
        }
    }
}
