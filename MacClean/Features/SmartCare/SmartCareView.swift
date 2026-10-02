//
//  SmartCareView.swift
//  MacClean
//
//  智能呵护：一键扫描 + 一键清理的仪表盘首页
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class SmartCareViewModel: ObservableObject {

    @Published var junkItems: [CleanableItem] = []
    @Published var duplicateItems: [CleanableItem] = []
    @Published var largeFileItems: [CleanableItem] = []
    @Published var brokenLoginItems: [CleanableItem] = []

    @Published var isScanningJunk = false
    @Published var isScanningDuplicates = false
    @Published var isScanningLargeFiles = false
    @Published var isScanningBrokenLoginItems = false

    @Published var isCleaning = false
    @Published var lastCleanResult: CleanResult?
    @Published var lastError: String?
    @Published var lastRestoreResult: RestoreResult?

    @Published private(set) var hasScanned = false
    @Published private(set) var lastScannedAt: Date?

    /// 大文件扫描已遍历的条目数（用于进度展示）。
    @Published var largeFileScanProgress = 0

    var isScanningAny: Bool {
        isScanningJunk || isScanningDuplicates || isScanningLargeFiles || isScanningBrokenLoginItems
    }

    /// 四个模块各自结束时调用，全部结束后记录扫描时间。
    private func moduleFinished() {
        if !isScanningAny { lastScannedAt = Date() }
    }

    // MARK: - 扫描

    func scanAll() {
        guard !isScanningAny else { return }

        hasScanned = true
        isScanningJunk = true
        isScanningDuplicates = true
        isScanningLargeFiles = true
        isScanningBrokenLoginItems = true

        let home = FileManager.default.homeDirectoryForCurrentUser

        // 四个模块各自独立并发扫描，互不阻塞，各自完成各自刷新对应状态。
        Task.detached(priority: .userInitiated) { [weak self] in
            // 一键体检只纳入「删了也会自动重建」的低风险分组；安装包、设备备份、废纸篓需要用户在「释放空间」里明确选择。
            let safeGroups: [JunkGroupID] = [.appCaches, .browserCaches, .logs, .mailAttachments]
            let junk = safeGroups.flatMap { JunkScanner.scan($0, home: home) }
                + DevCacheCatalog.scanDefaultSelected(home: home)
            let filtered = IgnoreList.filter(junk).sorted { $0.size > $1.size }
            await MainActor.run {
                self?.junkItems = filtered
                self?.isScanningJunk = false
                self?.moduleFinished()
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            // 顺序即「原件」位置优先级：同一份内容在文稿和下载里各有一份时，保留文稿里的那份。
            let directories = [
                home.appendingPathComponent("Documents"),
                home.appendingPathComponent("Desktop"),
                home.appendingPathComponent("Downloads"),
            ]
            let items = IgnoreList.filter((try? await DuplicateFinder.findDuplicates(in: directories)) ?? [])
            await MainActor.run {
                self?.duplicateItems = items
                self?.isScanningDuplicates = false
                self?.moduleFinished()
            }
        }

        largeFileScanProgress = 0
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = (try? await LargeFileFinder.findLargeFiles(under: home, progress: { count in
                Task { @MainActor [weak self] in
                    self?.largeFileScanProgress = count
                }
            })) ?? []
            let items = IgnoreList.filter(found)
            await MainActor.run {
                self?.largeFileItems = items
                self?.isScanningLargeFiles = false
                self?.moduleFinished()
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            let items = BrokenLoginItemFinder.findBrokenLoginItems(home: home)
            await MainActor.run {
                self?.brokenLoginItems = items
                self?.isScanningBrokenLoginItems = false
                self?.moduleFinished()
            }
        }
    }

    // MARK: - 清理

    /// 清理所有勾选项。成功返回 true（此时 lastCleanResult 有值）；抛错返回 false，错误信息在 lastError。
    @discardableResult
    func runSelected() async -> Bool {
        guard !isCleaning else { return false }
        let selected = (junkItems + duplicateItems + largeFileItems + brokenLoginItems).filter { $0.isSelected }
        guard !selected.isEmpty else { return false }

        isCleaning = true
        lastError = nil
        lastCleanResult = nil
        lastRestoreResult = nil

        var succeeded = false
        do {
            lastCleanResult = try await CleanupManager.shared.clean(items: selected)
            succeeded = true
        } catch {
            lastError = error.localizedDescription
        }

        isCleaning = false
        scanAll()
        return succeeded
    }

    func undoLastClean() async {
        guard let sessionID = lastCleanResult?.historySessionID else { return }
        lastRestoreResult = await CleanupManager.shared.restore(sessionID: sessionID)
        lastCleanResult = nil
        scanAll()
    }

    // MARK: - 汇总

    var selectedTotalSize: Int64 {
        (junkItems + duplicateItems + largeFileItems + brokenLoginItems)
            .filter { $0.isSelected }
            .reduce(0) { $0 + $1.size }
    }

    /// 确认框里逐模块列出的勾选摘要，没勾选的模块不列。
    var selectionSummary: String {
        let modules: [(String, [CleanableItem])] = [
            (String(localized: "冗余文件"), junkItems),
            (String(localized: "重复文件"), duplicateItems),
            (String(localized: "大文件"), largeFileItems),
            (String(localized: "失效启动项"), brokenLoginItems),
        ]
        return modules.compactMap { title, items in
            let picked = items.filter { $0.isSelected }
            guard !picked.isEmpty else { return nil }
            let size = ByteCountFormatter.string(fromByteCount: picked.reduce(0) { $0 + $1.size }, countStyle: .file)
            return String(localized: "\(title) \(picked.count) 项 · \(size)")
        }.joined(separator: "\n")
    }

    var junkTotalSize: Int64 { junkItems.reduce(0) { $0 + $1.size } }
    var duplicateTotalSize: Int64 { duplicateItems.reduce(0) { $0 + $1.size } }
    var duplicateSelectedSize: Int64 { duplicateItems.filter { $0.isSelected }.reduce(0) { $0 + $1.size } }
    var largeFileTotalSize: Int64 { largeFileItems.reduce(0) { $0 + $1.size } }
}


// MARK: - View

struct SmartCareView: View {
    @ObservedObject private var viewModel = PageModelStore.shared.smartCare

    @State private var activeSheet: SmartCareModule?
    @State private var showCompletionSheet = false
    @State private var showConfirm = false
    @State private var showError = false

    private enum SmartCareModule: Identifiable {
        case junk, duplicates, largeFiles, brokenLoginItems
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "一键体检"), subtitle: String(localized: "一次扫描四个方面，勾选后统一清理")) {
                HStack(spacing: 8) {
                    LastScannedLabel(date: viewModel.lastScannedAt)
                    ScanButton(hasScanned: viewModel.hasScanned, isScanning: viewModel.isScanningAny) { viewModel.scanAll() }
                }
            }

            if !viewModel.hasScanned {
                ScrollView {
                    ScanIntroView(
                        icon: "checkmark.seal",
                        title: String(localized: "一键体检"),
                        message: String(localized: "同时检查冗余文件、重复文件、大文件与失效启动项，完成后可勾选统一清理。"),
                        points: [String(localized: "缓存、日志与开发工具缓存"), String(localized: "下载、桌面、文稿中的重复文件"), String(localized: "主目录中 500 MB 以上的大文件（默认不勾选）"), String(localized: "指向已删除程序的登录项")],
                        action: { viewModel.scanAll() }
                    )
                    .padding(.horizontal, CosmicSizes.pagePadding)
                    .padding(.top, 24)
                }
            } else {
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                    SmartCareCard(
                        title: String(localized: "冗余文件"),
                        icon: "trash.fill",
                        tint: AppTheme.mint,
                        isScanning: viewModel.isScanningJunk,
                        summary: viewModel.isScanningJunk ? nil : ByteCountFormatter.string(fromByteCount: viewModel.junkTotalSize, countStyle: .file),
                        detail: String(localized: "系统与应用产生的缓存、日志")
                    ) {
                        activeSheet = .junk
                    }

                    SmartCareCard(
                        title: String(localized: "重复文件"),
                        icon: "doc.on.doc.fill",
                        tint: AppTheme.sky,
                        isScanning: viewModel.isScanningDuplicates,
                        summary: viewModel.isScanningDuplicates ? nil : String(localized: "\(viewModel.duplicateItems.count) 个重复 · \(ByteCountFormatter.string(fromByteCount: viewModel.duplicateTotalSize, countStyle: .file))"),
                        detail: String(localized: "文稿、桌面与下载中的重复文件，每组保留一份")
                    ) {
                        activeSheet = .duplicates
                    }

                    SmartCareCard(
                        title: String(localized: "大文件"),
                        icon: "doc.fill",
                        tint: AppTheme.amber,
                        isScanning: viewModel.isScanningLargeFiles,
                        scanningText: viewModel.largeFileScanProgress > 0
                            ? String(localized: "已扫描 \(viewModel.largeFileScanProgress.formatted()) 项")
                            : nil,
                        summary: viewModel.isScanningLargeFiles ? nil : String(localized: "\(viewModel.largeFileItems.count) 个 · \(ByteCountFormatter.string(fromByteCount: viewModel.largeFileTotalSize, countStyle: .file))"),
                        detail: String(localized: "仅供盘点，默认不选中，请确认后再清理")
                    ) {
                        activeSheet = .largeFiles
                    }

                    SmartCareCard(
                        title: String(localized: "失效启动项"),
                        icon: "exclamationmark.triangle.fill",
                        tint: AppTheme.coral,
                        isScanning: viewModel.isScanningBrokenLoginItems,
                        summary: viewModel.isScanningBrokenLoginItems ? nil : String(localized: "\(viewModel.brokenLoginItems.count) 个损坏项"),
                        detail: String(localized: "指向不存在程序的登录项")
                    ) {
                        activeSheet = .brokenLoginItems
                    }
                }
                .padding(.horizontal, CosmicSizes.pagePadding)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }

            actionBar
            }
        }
        .sheet(item: $activeSheet) { module in
            sheetContent(for: module)
                .frame(minWidth: 720, minHeight: 480)
        }
        .alert("确认清理", isPresented: $showConfirm) {
            Button("取消", role: .cancel) {}
            Button("移入废纸篓", role: .destructive) {
                Task {
                    if await viewModel.runSelected() {
                        showCompletionSheet = true
                    } else if viewModel.lastError != nil {
                        showError = true
                    }
                }
            }
        } message: {
            Text("\(viewModel.selectionSummary)\n\n全部移入废纸篓，可在「清理记录」中恢复。")
        }
        .alert("清理失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.lastError ?? "")
        }
        .sheet(isPresented: $showCompletionSheet) {
            let result = viewModel.lastCleanResult
            CleanupCompletionView(
                cleanedSize: result?.freedSpace ?? 0,
                cleanedCount: result?.cleanedItems ?? 0,
                permanentlyFreed: result?.permanentlyFreed ?? 0,
                failedCount: result?.errors.count ?? 0,
                onUndo: result?.historySessionID == nil ? nil : {
                    Task {
                        await viewModel.undoLastClean()
                        showCompletionSheet = false
                    }
                },
                onDismiss: { showCompletionSheet = false }
            )
        }
    }

    private var actionBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("已选择")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                Text(ByteCountFormatter.string(fromByteCount: viewModel.selectedTotalSize, countStyle: .file))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textPrimary)
            }

            if let error = viewModel.lastError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.danger)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                guard ProGate.allowAction() else { return }
                showConfirm = true
            } label: {
                HStack(spacing: 6) {
                    if viewModel.isCleaning {
                        ProgressView().scaleEffect(0.6).tint(AppTheme.onAccent)
                    } else {
                        Image(systemName: "trash")
                    }
                    (viewModel.isCleaning ? Text("清理中") : Text("清理所选"))
                }
            }
            .buttonStyle(NeonButtonStyle(isLarge: true))
            .disabled(viewModel.isCleaning || viewModel.selectedTotalSize == 0)
        }
        .padding(.horizontal, CosmicSizes.pagePadding)
        .padding(.vertical, 16)
        .background(
            Rectangle()
                .fill(AppTheme.sidebarColor.opacity(0.92))
                .overlay(Rectangle().fill(AppTheme.divider).frame(height: 1), alignment: .top)
        )
    }

    @ViewBuilder
    private func sheetContent(for module: SmartCareModule) -> some View {
        switch module {
        case .junk:
            SmartCareDetailListView(title: String(localized: "清理"), items: $viewModel.junkItems)
        case .duplicates:
            SmartCareDetailListView(title: String(localized: "重复文件"), items: $viewModel.duplicateItems, onViewAll: {
                // 体检只扫文稿/桌面/下载里 1 MB 以上的文件；完整扫描在「重复与相似」页面
                activeSheet = nil
                PageModelStore.shared.duplicates.mode = .exact
                AppState.shared.currentTab = .similarPhotos
            })
        case .largeFiles:
            SmartCareDetailListView(title: String(localized: "大文件"), items: $viewModel.largeFileItems, showRevealInFinder: true, footnote: String(localized: "大文件仅供盘点，默认不选中，请确认后再清理"))
        case .brokenLoginItems:
            SmartCareDetailListView(title: String(localized: "启动项"), items: $viewModel.brokenLoginItems)
        }
    }
}

// MARK: - 卡片

private struct SmartCareCard: View {
    let title: String
    let icon: String
    let tint: Color
    let isScanning: Bool
    var scanningText: String? = nil
    let summary: String?
    let detail: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    GradientIconTile(
                        systemName: icon,
                        gradient: AppTheme.tileGradient(tint, tint.opacity(0.72)),
                        size: 42,
                        cornerRatio: 0.27,
                        glyphRatio: 0.44,
                        shadowColor: tint
                    )
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(AppTheme.textMuted)
                }

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)

                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(AppTheme.textSecondary)
                        if let scanningText {
                            Text(scanningText)
                                .font(.system(size: 12))
                                .foregroundColor(AppTheme.textSecondary)
                        }
                    }
                    .frame(height: 24, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(summary ?? "—")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(AppTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(height: 24, alignment: .leading)
                }

                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(2)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 148)
            .contentShape(RoundedRectangle(cornerRadius: CosmicSizes.cardRadius))
        }
        .buttonStyle(.plain)
        .themeCard(isHovered: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 通用明细列表

struct SmartCareDetailListView: View {
    let title: String
    @Binding var items: [CleanableItem]
    var showRevealInFinder: Bool = false
    var footnote: String? = nil
    var onViewAll: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Spacer()
                if let onViewAll {
                    Button("查看全部", action: onViewAll)
                        .buttonStyle(NeonOutlineButtonStyle())
                }
                Button("全选") { setAll(true) }
                    .buttonStyle(NeonOutlineButtonStyle())
                Button("取消全选") { setAll(false) }
                    .buttonStyle(NeonOutlineButtonStyle())
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(AppTheme.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            if let footnote {
                Text(footnote)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            Divider().overlay(AppTheme.divider)

            if items.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 32))
                        .foregroundColor(AppTheme.accent)
                    Text("没有发现可清理的项目")
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.textSecondary)
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach($items) { $item in
                            SmartCareItemRow(item: $item, showRevealInFinder: showRevealInFinder)
                            Divider().overlay(AppTheme.divider)
                        }
                    }
                }
            }
        }
        .background(AppTheme.primaryGradient)
    }

    private func setAll(_ selected: Bool) {
        for index in items.indices {
            items[index].isSelected = selected
        }
    }
}

private struct SmartCareItemRow: View {
    @Binding var item: CleanableItem
    let showRevealInFinder: Bool

    var body: some View {
        HStack(spacing: 14) {
            Toggle("", isOn: $item.isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(item.description ?? item.path)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(AppTheme.textSecondary)

            if showRevealInFinder {
                Button {
                    NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .foregroundColor(AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
