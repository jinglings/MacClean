//
//  SimilarPhotosView.swift
//  MacClean
//
//  「重复与相似」页面入口 + 相似照片模式：按画面相似度分组，默认一张都不勾选；
//  「智能选择」为每组保留推荐的一张、勾选其余。整组全部勾选时会显式警告。删除走废纸篓，可撤销。
//

import SwiftUI
import Combine
import ImageIO

// MARK: - ViewModel

@MainActor
final class SimilarPhotosViewModel: ObservableObject {
    @Published private(set) var groups: [SimilarPhotoGroup] = []
    @Published private(set) var selected: Set<String> = []
    @Published var sensitivity: SimilarPhotoFinder.Sensitivity = .standard
    @Published private(set) var folders: [URL]

    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var progress: (done: Int, total: Int) = (0, 0)

    @Published private(set) var isCleaning = false
    @Published private(set) var cleanProgress: Double = 0
    @Published private(set) var lastCleanResult: CleanResult?
    @Published private(set) var lastRestoreResult: RestoreResult?

    private var scanTask: Task<Void, Never>?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        folders = ["Pictures", "Desktop", "Downloads", "Documents"].map { home.appendingPathComponent($0) }
    }

    var photoCount: Int { groups.reduce(0) { $0 + $1.photos.count } }
    var reclaimableSize: Int64 { groups.reduce(0) { $0 + $1.reclaimableSize } }
    var selectedSize: Int64 {
        groups.flatMap(\.photos).filter { selected.contains($0.path) }.reduce(0) { $0 + $1.size }
    }
    /// 所有照片都被勾选的组数（会整组删光）。
    var fullySelectedGroupCount: Int {
        groups.filter { group in group.photos.allSatisfy { selected.contains($0.path) } }.count
    }

    // MARK: - 范围

    func addFolder(_ url: URL) {
        guard !folders.contains(url) else { return }
        folders.append(url)
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }
    }

    // MARK: - 扫描

    func scan() {
        scanTask?.cancel()
        isScanning = true
        progress = (0, 0)
        lastRestoreResult = nil
        let folders = self.folders
        let maxDistance = sensitivity.maxDistance
        let ref = WeakRef(self)

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let found = (try? SimilarPhotoFinder.find(
                in: folders,
                maxDistance: maxDistance,
                progress: { done, total in
                    Task { @MainActor in ref.object?.progress = (done, total) }
                }
            )) ?? []
            let ignored = IgnoreList.paths()
            let filtered = found.compactMap { group -> SimilarPhotoGroup? in
                let photos = group.photos.filter { !IgnoreList.isIgnored($0.path, in: ignored) }
                return photos.count >= 2 ? SimilarPhotoGroup(photos: photos) : nil
            }
            let cancelled = Task.isCancelled
            await self?.finishScan(filtered, cancelled: cancelled)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        isScanning = false
    }

    private func finishScan(_ groups: [SimilarPhotoGroup], cancelled: Bool) {
        guard !cancelled else { return }
        self.groups = groups
        selected = []
        isScanning = false
        hasScanned = true
        UsageAnalytics.shared.recordScanCompleted()
    }

    // MARK: - 选择

    func isSelected(_ photo: PhotoRecord) -> Bool { selected.contains(photo.path) }

    func toggle(_ photo: PhotoRecord) {
        if selected.contains(photo.path) {
            selected.remove(photo.path)
        } else {
            selected.insert(photo.path)
        }
    }

    /// 每组保留推荐的一张，勾选其余。
    func smartSelect() {
        selected = Set(groups.flatMap { $0.photos.dropFirst().map(\.path) })
    }

    func keepBest(in group: SimilarPhotoGroup) {
        selected.remove(group.best.path)
        selected.formUnion(group.photos.dropFirst().map(\.path))
    }

    func clearSelection() { selected = [] }

    func ignore(_ photo: PhotoRecord) {
        IgnoreList.add(photo.path)
        selected.remove(photo.path)
        groups = groups.compactMap { group in
            let photos = group.photos.filter { $0.path != photo.path }
            return photos.count >= 2 ? SimilarPhotoGroup(photos: photos) : nil
        }
    }

    // MARK: - 清理

    func cleanSelected() async {
        guard !isCleaning else { return }
        let targets = groups.flatMap(\.photos).filter { selected.contains($0.path) }
        guard !targets.isEmpty else { return }

        isCleaning = true
        cleanProgress = 0
        lastRestoreResult = nil

        let items = targets.map { photo -> CleanableItem in
            var item = CleanableItem(
                name: photo.name,
                path: photo.path,
                size: photo.size,
                category: .similarPhotos,
                isSelected: true,
                description: nil,
                lastModified: photo.modified
            )
            item.removesContainer = true
            return item
        }

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

        // 移除已不在原位置的照片；剩余不足两张的组不再是「相似组」。
        let fileManager = FileManager.default
        groups = groups.compactMap { group in
            let remaining = group.photos.filter { fileManager.fileExists(atPath: $0.path) }
            return remaining.count >= 2 ? SimilarPhotoGroup(photos: SimilarPhotoFinder.rankForKeeping(remaining)) : nil
        }
        selected = selected.filter { fileManager.fileExists(atPath: $0) }
        isCleaning = false
    }

    func undoLastClean() async {
        guard let sessionID = lastCleanResult?.historySessionID else { return }
        lastRestoreResult = await CleanupManager.shared.restore(sessionID: sessionID)
        lastCleanResult = nil
        scan()
    }
}

// MARK: - 页面（重复与相似）

/// 侧栏「重复与相似」的页面入口（沿用 SimilarPhotosView 这个名字，ContentView 按 AppTab.similarPhotos 挂载）。
/// 顶部分段切换两个模式：完全相同的文件（DuplicatesViewModel）与相似照片（SimilarPhotosViewModel）；
/// 两个 ViewModel 都常驻在 PageModelStore，切换模式或侧栏都不丢结果。
struct SimilarPhotosView: View {
    @ObservedObject private var duplicates = PageModelStore.shared.duplicates
    @ObservedObject private var photos = PageModelStore.shared.similarPhotos

    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "重复与相似"), subtitle: String(localized: "找出内容完全相同的文件和画面相似的照片，每组只留一份")) {
                HStack(spacing: 8) {
                    Button {
                        showHistory = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 12, weight: .medium))
                            Text("清理记录")
                        }
                    }
                    .buttonStyle(NeonOutlineButtonStyle())

                    switch duplicates.mode {
                    case .exact: ExactDuplicatesScanControls(viewModel: duplicates)
                    case .similar: SimilarPhotosScanControls(viewModel: photos)
                    }
                }
            }

            HStack {
                ModeSwitch(selection: $duplicates.mode)
                Spacer()
            }
            .padding(.horizontal, CosmicSizes.pagePadding)
            .padding(.top, 18)

            switch duplicates.mode {
            case .exact: ExactDuplicatesPane(viewModel: duplicates)
            case .similar: SimilarPhotosPane(viewModel: photos)
            }
        }
        .sheet(isPresented: $showHistory) {
            CleanupHistoryView(onRestored: {
                if duplicates.hasScanned { duplicates.scan() }
                if photos.hasScanned { photos.scan() }
            })
            .frame(width: 640, height: 520)
        }
    }
}

// MARK: - 模式切换

private struct ModeSwitch: View {
    @Binding var selection: DuplicatesMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DuplicatesMode.allCases) { mode in
                let isOn = mode == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = mode }
                } label: {
                    Text(mode.title)
                        .font(.system(size: 12.5, weight: isOn ? .semibold : .medium))
                        .foregroundColor(isOn ? AppTheme.textPrimary : AppTheme.textSecondary)
                        .padding(.horizontal, 16)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isOn ? AppTheme.surfaceHover : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(isOn ? AppTheme.ink(0.10) : Color.clear, lineWidth: 1)
                                )
                                .shadow(color: .black.opacity(isOn ? 0.10 : 0), radius: 2, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(AppTheme.ink(0.06)))
    }
}

// MARK: - 相似照片：页头按钮

struct SimilarPhotosScanControls: View {
    @ObservedObject var viewModel: SimilarPhotosViewModel

    var body: some View {
        if viewModel.isScanning {
            Button("停止") { viewModel.cancelScan() }
                .buttonStyle(NeonOutlineButtonStyle())
        } else if viewModel.hasScanned {
            Button {
                viewModel.scan()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.hasScanned ? "arrow.clockwise" : "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                    viewModel.hasScanned ? Text("重新扫描") : Text("开始扫描")
                }
            }
            .buttonStyle(NeonButtonStyle())
            .disabled(viewModel.folders.isEmpty || viewModel.isCleaning)
        }
    }
}

// MARK: - 相似照片：内容

struct SimilarPhotosPane: View {
    @ObservedObject var viewModel: SimilarPhotosViewModel

    @State private var showConfirm = false
    @State private var showCompletion = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    scopeCard
                    if viewModel.isScanning {
                        scanningCard
                    } else if !viewModel.hasScanned {
                        ScanIntroView(
                            icon: "photo.on.rectangle.angled",
                            title: String(localized: "只留最好的那一张"),
                            message: viewModel.folders.isEmpty ? String(localized: "先在上方添加至少一个要扫描的文件夹。") : String(localized: "按画面内容比对上方文件夹里的照片，把连拍和重复导出归成一组，帮你挑出值得保留的一张。"),
                            points: [String(localized: "连拍与重复导出"), String(localized: "轻微裁剪或压缩过的副本"), String(localized: "每组自动推荐保留项"), String(localized: "删除先入废纸篓，可一键恢复")],
                            compact: true,
                            action: { viewModel.scan() }
                        )
                        .disabled(viewModel.folders.isEmpty || viewModel.isCleaning)
                    } else {
                        resultsHeader
                        ForEach(viewModel.groups) { group in
                            SimilarGroupCard(group: group, viewModel: viewModel)
                        }
                    }
                }
                .padding(.horizontal, CosmicSizes.pagePadding)
                .padding(.vertical, 20)
            }

            if viewModel.hasScanned {
            SelectionFooterBar(
                selectedCount: viewModel.selected.count,
                selectedSize: viewModel.selectedSize,
                isCleaning: viewModel.isCleaning,
                cleanProgress: viewModel.cleanProgress,
                restoreResult: viewModel.lastRestoreResult,
                warning: viewModel.fullySelectedGroupCount > 0 ? String(localized: "\(viewModel.fullySelectedGroupCount) 组将被整组删除") : nil,
                action: { showConfirm = true }
            )
            }
        }
        .alert("确认清理", isPresented: $showConfirm) {
            Button("取消", role: .cancel) {}
            Button("移入废纸篓", role: .destructive) {
                Task {
                    await viewModel.cleanSelected()
                    showCompletion = true
                }
            }
        } message: {
            Text(confirmMessage)
        }
        .sheet(isPresented: $showCompletion) {
            let result = viewModel.lastCleanResult
            CleanupCompletionView(
                cleanedSize: result?.freedSpace ?? 0,
                cleanedCount: result?.cleanedItems ?? 0,
                failedCount: result?.errors.count ?? 0,
                onUndo: result?.historySessionID == nil ? nil : {
                    Task {
                        await viewModel.undoLastClean()
                        showCompletion = false
                    }
                },
                onDismiss: { showCompletion = false }
            )
        }
    }

    private var confirmMessage: String {
        var text = String(localized: "\(viewModel.selected.count) 张照片（\(ByteCountFormatter.string(fromByteCount: viewModel.selectedSize, countStyle: .file))）将移入废纸篓，可在「清理记录」中一键恢复。")
        if viewModel.fullySelectedGroupCount > 0 {
            text += "\n" + String(localized: "注意：有 \(viewModel.fullySelectedGroupCount) 组的所有照片都被选中，这些画面将一张不留。")
        }
        return text
    }

    // MARK: - 扫描范围

    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("扫描范围")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text("「照片」App 图库不在范围内，请在「照片」中使用「重复项」相簿管理")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
            }

            FlowRow(spacing: 8) {
                ForEach(viewModel.folders, id: \.self) { folder in
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                        Text(folder.lastPathComponent)
                            .font(.system(size: 12))
                        Button {
                            viewModel.removeFolder(folder)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isScanning)
                    }
                    .foregroundColor(AppTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Capsule().fill(AppTheme.ink(0.06)))
                    .help(folder.path)
                }
                Button {
                    chooseFolder()
                } label: {
                    Label("添加文件夹…", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.accent)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Capsule().stroke(AppTheme.accent.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isScanning)
            }

            HStack(spacing: 12) {
                Text("相似度")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.textMuted)
                Picker("", selection: $viewModel.sensitivity) {
                    ForEach(SimilarPhotoFinder.Sensitivity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .disabled(viewModel.isScanning)
                Text(viewModel.sensitivity.detail)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "添加")
        if panel.runModal() == .OK {
            panel.urls.forEach { viewModel.addFolder($0) }
        }
    }

    // MARK: - 状态

    private var scanningCard: some View {
        let (done, total) = viewModel.progress
        return VStack(alignment: .leading, spacing: 10) {
            (total == 0 ? Text("正在查找照片…") : Text("正在分析画面 \(done.formatted()) / \(total.formatted())"))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundColor(AppTheme.textSecondary)
            ProgressView(value: total == 0 ? 0 : Double(done) / Double(total))
                .tint(AppTheme.accent)
            Text("分析在本机完成，照片不会离开你的 Mac。")
                .font(.system(size: 11))
                .foregroundColor(AppTheme.textMuted)
        }
        .padding(16)
        .themeCard()
    }

    @ViewBuilder
    private var resultsHeader: some View {
        if viewModel.groups.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(AppTheme.accent)
                Text("没有发现相似照片")
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.textSecondary)
            }
            .padding(.top, 8)
        } else {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(viewModel.groups.count) 组 · \(viewModel.photoCount) 张照片")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                    Text("每组只留推荐的一张可释放 \(ByteCountFormatter.string(fromByteCount: viewModel.reclaimableSize, countStyle: .file))")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundColor(AppTheme.textMuted)
                }
                Spacer()
                Button("取消选择") { viewModel.clearSelection() }
                    .buttonStyle(NeonOutlineButtonStyle())
                    .disabled(viewModel.selected.isEmpty)
                Button {
                    viewModel.smartSelect()
                } label: {
                    Label("智能选择", systemImage: "wand.and.stars")
                }
                .buttonStyle(NeonOutlineButtonStyle())
            }
        }
    }
}

// MARK: - 分组卡片

private struct SimilarGroupCard: View {
    let group: SimilarPhotoGroup
    @ObservedObject var viewModel: SimilarPhotosViewModel

    private var allSelected: Bool { group.photos.allSatisfy { viewModel.isSelected($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(group.photos.count) 张相似")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text("可释放 \(ByteCountFormatter.string(fromByteCount: group.reclaimableSize, countStyle: .file))")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textMuted)
                if allSelected {
                    Label("整组都将被删除", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.danger)
                }
                Spacer()
                Button("保留最佳，选中其余") { viewModel.keepBest(in: group) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.accent)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(group.photos) { photo in
                    PhotoTile(
                        photo: photo,
                        isBest: photo.path == group.best.path,
                        isSelected: viewModel.isSelected(photo),
                        onToggle: { viewModel.toggle(photo) },
                        onIgnore: { viewModel.ignore(photo) }
                    )
                }
            }
        }
        .padding(16)
        .themeCard()
    }
}

// MARK: - 照片缩略图

private struct PhotoTile: View {
    let photo: PhotoRecord
    let isBest: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    let onIgnore: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                PhotoThumbnail(path: photo.path)
                    .frame(height: 118)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? AppTheme.danger : (isHovered ? AppTheme.ink(0.25) : Color.clear), lineWidth: 2)
                    )
                    .opacity(isSelected ? 0.55 : 1)

                HStack {
                    Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                        .toggleStyle(CosmicCheckboxStyle(accentColor: AppTheme.accent))
                        .labelsHidden()
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
                    Spacer()
                    if isBest {
                        Text("推荐保留")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(AppTheme.onAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(AppTheme.accent))
                    }
                }
                .padding(6)
            }

            Text(photo.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(photo.pixelWidth)×\(photo.pixelHeight) · \(ByteCountFormatter.string(fromByteCount: photo.size, countStyle: .file))")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundColor(AppTheme.textMuted)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovered = $0 }
        .help(photo.path)
        .contextMenu {
            Button("用预览打开") { NSWorkspace.shared.open(URL(fileURLWithPath: photo.path)) }
            Button("在访达中显示") { NSWorkspace.shared.selectFile(photo.path, inFileViewerRootedAtPath: "") }
            Divider()
            Button("始终忽略此照片", action: onIgnore)
        }
    }
}

/// 异步加载的缩略图，结果缓存在内存中。
struct PhotoThumbnail: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            AppTheme.ink(0.05)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .foregroundColor(AppTheme.textMuted)
            }
        }
        .clipped()
        .task(id: path) {
            image = await ThumbnailCache.image(for: path)
        }
    }
}

enum ThumbnailCache {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        return cache
    }()

    nonisolated static func image(for path: String) async -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 360,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
        if let image { cache.setObject(image, forKey: path as NSString) }
        return image
    }
}

// MARK: - 自动换行布局

struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
