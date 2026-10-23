//
//  LargeOldFilesView.swift
//  MacClean
//
//  大型与陈旧文件：一次扫描，按大小 / 闲置时长 / 类型即时筛选，勾选后移入废纸篓（可撤销）。
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class LargeOldFilesViewModel: ObservableObject {
    @Published private(set) var records: [LargeFileRecord] = []
    @Published var filter = LargeFileFilter() {
        didSet { pruneSelection() }
    }
    @Published private(set) var selected: Set<String> = []

    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var lastScannedAt: Date?
    @Published private(set) var scannedEntries = 0

    @Published private(set) var isCleaning = false
    @Published private(set) var cleanProgress: Double = 0
    @Published private(set) var lastCleanResult: CleanResult?
    @Published private(set) var lastRestoreResult: RestoreResult?

    private var scanTask: Task<Void, Never>?
    private let home = FileManager.default.homeDirectoryForCurrentUser

    var visibleRecords: [LargeFileRecord] { filter.apply(to: records) }
    var selectedRecords: [LargeFileRecord] { records.filter { selected.contains($0.path) } }
    var selectedSize: Int64 { selectedRecords.reduce(0) { $0 + $1.size } }

    /// 各类型在「当前尺寸 + 闲置」条件下的数量与大小（不受类型筛选影响，用于类型标签）。
    var kindStats: [FileKind: (count: Int, size: Int64)] {
        var base = filter
        base.kinds = []
        var stats: [FileKind: (count: Int, size: Int64)] = [:]
        for record in records where base.matches(record) {
            let current = stats[record.kind] ?? (0, 0)
            stats[record.kind] = (current.count + 1, current.size + record.size)
        }
        return stats
    }

    // MARK: - 扫描

    func scan() {
        scanTask?.cancel()
        isScanning = true
        scannedEntries = 0
        lastRestoreResult = nil
        let home = self.home
        let ref = WeakRef(self)

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            // 下限取所有筛选档位中最小的 50MB，之后切换尺寸档位无需重扫。
            let found = (try? await LargeOldFileScanner.scan(
                under: home,
                minSize: LargeFileFilter.SizeFloor.mb50.rawValue,
                progress: { count in
                    Task { @MainActor in ref.object?.scannedEntries = count }
                }
            )) ?? []
            let ignored = IgnoreList.paths()
            let visible = found.filter { !IgnoreList.isIgnored($0.path, in: ignored) }
            let cancelled = Task.isCancelled
            await self?.finishScan(visible, cancelled: cancelled)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        isScanning = false
    }

    private func finishScan(_ records: [LargeFileRecord], cancelled: Bool) {
        guard !cancelled else { return }
        self.records = records
        isScanning = false
        hasScanned = true
        lastScannedAt = Date()
        UsageAnalytics.shared.recordScanCompleted()
        pruneSelection()
    }

    // MARK: - 选择

    func isSelected(_ record: LargeFileRecord) -> Bool { selected.contains(record.path) }

    func toggle(_ record: LargeFileRecord) {
        if selected.contains(record.path) {
            selected.remove(record.path)
        } else {
            selected.insert(record.path)
        }
    }

    func selectAllVisible(_ on: Bool) {
        let paths = visibleRecords.map(\.path)
        if on {
            selected.formUnion(paths)
        } else {
            selected.subtract(paths)
        }
    }

    /// 被筛选隐藏的项目不应在看不见的情况下被删除，筛选条件变化时取消其勾选。
    private func pruneSelection() {
        let visible = Set(visibleRecords.map(\.path))
        selected.formIntersection(visible)
    }

    func ignore(_ record: LargeFileRecord) {
        IgnoreList.add(record.path)
        records.removeAll { $0.path == record.path }
        selected.remove(record.path)
    }

    // MARK: - 清理

    func cleanSelected() async {
        guard !isCleaning else { return }
        let targets = selectedRecords
        guard !targets.isEmpty else { return }

        isCleaning = true
        cleanProgress = 0
        lastRestoreResult = nil

        let items = targets.map { record -> CleanableItem in
            var item = CleanableItem(
                name: record.name,
                path: record.path,
                size: record.size,
                category: .largeFiles,
                isSelected: true,
                description: nil,
                lastModified: record.modified
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

        // 只移除确实已经不在原位置的文件，失败的保留在列表里。
        let fileManager = FileManager.default
        records.removeAll { record in
            selected.contains(record.path) && !fileManager.fileExists(atPath: record.path)
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

// MARK: - 页面

struct LargeOldFilesView: View {
    @ObservedObject private var viewModel = PageModelStore.shared.largeOldFiles

    @State private var showConfirm = false
    @State private var showCompletion = false
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "大型与陈旧文件"), subtitle: String(localized: "找出主目录里最占空间、最久没打开过的文件；不含 ~/Library 与应用包内部")) {
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

                    LastScannedLabel(date: viewModel.lastScannedAt)
                    if viewModel.isScanning {
                        Button("停止") { viewModel.cancelScan() }
                            .buttonStyle(NeonOutlineButtonStyle())
                    } else {
                        ScanButton(hasScanned: viewModel.hasScanned, isScanning: false) { viewModel.scan() }
                            .disabled(viewModel.isCleaning)
                    }
                }
            }

            if !viewModel.hasScanned && !viewModel.isScanning {
                ScrollView {
                    ScanIntroView(
                        icon: "doc.badge.clock",
                        title: String(localized: "扫描大型与陈旧文件"),
                        message: String(localized: "遍历主目录，找出 50 MB 以上的文件及其上次打开时间。之后切换大小、闲置时长、类型筛选无需重扫。"),
                        points: [String(localized: "不含 ~/Library 与应用包内部"), String(localized: "通常 10 秒左右（取决于文件数量）"), String(localized: "只读取，不会删除任何东西")],
                        action: { viewModel.scan() }
                    )
                    .padding(.horizontal, CosmicSizes.pagePadding)
                    .padding(.top, 24)
                }
            } else {
            filterCard
                .padding(.horizontal, CosmicSizes.pagePadding)
                .padding(.top, 20)

            listArea

            SelectionFooterBar(
                selectedCount: viewModel.selected.count,
                selectedSize: viewModel.selectedSize,
                isCleaning: viewModel.isCleaning,
                cleanProgress: viewModel.cleanProgress,
                restoreResult: viewModel.lastRestoreResult,
                action: { guard ProGate.allowAction() else { return }; showConfirm = true }
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
            Text("\(viewModel.selected.count) 个文件（\(ByteCountFormatter.string(fromByteCount: viewModel.selectedSize, countStyle: .file))）将移入废纸篓，可在「清理记录」中一键恢复。")
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
        .sheet(isPresented: $showHistory) {
            CleanupHistoryView(onRestored: { viewModel.scan() })
                .frame(width: 640, height: 520)
        }
    }

    // MARK: - 筛选

    private var filterCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                filterLabel(String(localized: "大小"))
                Picker("", selection: $viewModel.filter.sizeFloor) {
                    ForEach(LargeFileFilter.SizeFloor.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)

                Spacer()

                filterLabel(String(localized: "闲置"))
                Picker("", selection: $viewModel.filter.idleAge) {
                    ForEach(LargeFileFilter.IdleAge.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)

                Picker("", selection: $viewModel.filter.sort) {
                    ForEach(LargeFileFilter.SortOrder.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    KindChip(title: String(localized: "全部类型"), icon: "square.grid.2x2", detail: nil, isOn: viewModel.filter.kinds.isEmpty) {
                        viewModel.filter.kinds = []
                    }
                    let stats = viewModel.kindStats
                    ForEach(FileKind.allCases) { kind in
                        if let stat = stats[kind] {
                            KindChip(
                                title: kind.title,
                                icon: kind.icon,
                                detail: "\(stat.count) · \(ByteCountFormatter.string(fromByteCount: stat.size, countStyle: .file))",
                                isOn: viewModel.filter.kinds.contains(kind)
                            ) {
                                if viewModel.filter.kinds.contains(kind) {
                                    viewModel.filter.kinds.remove(kind)
                                } else {
                                    viewModel.filter.kinds.insert(kind)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .themeCard()
    }

    private func filterLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(AppTheme.textMuted)
    }

    // MARK: - 列表

    @ViewBuilder
    private var listArea: some View {
        let visible = viewModel.visibleRecords
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if viewModel.isScanning {
                    ProgressView().scaleEffect(0.6).tint(AppTheme.textSecondary)
                    Text("正在扫描… 已检查 \(viewModel.scannedEntries.formatted()) 个项目")
                        .monospacedDigit()
                } else {
                    Text("\(visible.count) 个文件 · 共 \(ByteCountFormatter.string(fromByteCount: visible.reduce(0) { $0 + $1.size }, countStyle: .file))")
                        .monospacedDigit()
                }
                Spacer()
                if !visible.isEmpty {
                    let allOn = visible.allSatisfy { viewModel.isSelected($0) }
                    Button(allOn ? String(localized: "取消全选") : String(localized: "全选当前结果")) { viewModel.selectAllVisible(!allOn) }
                        .buttonStyle(.plain)
                        .foregroundColor(AppTheme.accent)
                }
            }
            .font(.system(size: 13))
            .foregroundColor(AppTheme.textSecondary)
            .padding(.horizontal, CosmicSizes.pagePadding)
            .padding(.vertical, 12)

            if visible.isEmpty && viewModel.hasScanned && !viewModel.isScanning {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                        .foregroundColor(AppTheme.accent)
                    Text("没有符合条件的文件，试试放宽大小或闲置时长")
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { record in
                            LargeFileRow(
                                record: record,
                                isSelected: viewModel.isSelected(record),
                                onToggle: { viewModel.toggle(record) },
                                onIgnore: { viewModel.ignore(record) }
                            )
                            Divider().overlay(AppTheme.divider).padding(.leading, 76)
                        }
                    }
                    .themeCard()
                    .padding(.horizontal, CosmicSizes.pagePadding)
                    .padding(.bottom, 20)
                }
            }
        }
    }
}

// MARK: - 类型标签

private struct KindChip: View {
    let title: String
    let icon: String
    let detail: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundColor(isOn ? AppTheme.onAccent.opacity(0.75) : AppTheme.textMuted)
                }
            }
            .foregroundColor(isOn ? AppTheme.onAccent : AppTheme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                Capsule().fill(isOn ? AppTheme.accent : AppTheme.ink(0.06))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 文件行

private struct LargeFileRow: View {
    let record: LargeFileRecord
    let isSelected: Bool
    let onToggle: () -> Void
    let onIgnore: () -> Void

    @State private var isHovered = false

    private var location: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let parent = (record.path as NSString).deletingLastPathComponent
        return parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
    }

    private var usageText: String {
        let relative = record.lastUsed.formatted(.relative(presentation: .named))
        if let opened = record.lastOpened, opened >= record.modified {
            return String(localized: "\(relative)打开")
        }
        return String(localized: "\(relative)修改")
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .toggleStyle(CosmicCheckboxStyle(accentColor: AppTheme.accent))
                .labelsHidden()

            Image(nsImage: AppLookup.fileIcon(path: record.path))
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(location)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(record.path)

            Spacer(minLength: 16)

            if isHovered {
                Button {
                    NSWorkspace.shared.selectFile(record.path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("在访达中显示")
            }

            Text(record.kind.title)
                .font(.system(size: 11))
                .foregroundColor(AppTheme.textMuted)
                .frame(width: 96, alignment: .leading)

            Text(usageText)
                .font(.system(size: 11))
                .foregroundColor(AppTheme.textMuted)
                .frame(width: 96, alignment: .leading)

            Text(ByteCountFormatter.string(fromByteCount: record.size, countStyle: .file))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(AppTheme.textPrimary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? AppTheme.accent.opacity(0.06) : (isHovered ? AppTheme.surfaceHover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("打开") { NSWorkspace.shared.open(URL(fileURLWithPath: record.path)) }
            Button("在访达中显示") { NSWorkspace.shared.selectFile(record.path, inFileViewerRootedAtPath: "") }
            Button("拷贝路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.path, forType: .string)
            }
            Divider()
            Button("始终忽略此文件", action: onIgnore)
        }
    }
}
