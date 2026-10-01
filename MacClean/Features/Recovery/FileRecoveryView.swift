//
//  FileRecoveryView.swift
//  MacClean
//
//  找回文件：从 APFS 本地快照和时间机器备份里把误删的文件复制回来。
//  只复制、绝不覆盖；没有快照或备份时如实说明无法找回，并给出其他可能的途径。
//

import AppKit
import Quartz
import SwiftUI

struct FileRecoveryView: View {
    @ObservedObject private var viewModel: FileRecoveryViewModel

    @State private var showRestoreConfirm = false
    @State private var showAllSources = false

    init() {
        _viewModel = ObservedObject(wrappedValue: FileRecoveryViewModel.shared)
    }

    init(viewModel: FileRecoveryViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "找回文件"), subtitle: String(localized: "从本地快照和时间机器备份里找回误删的文件——包括已经清空废纸篓的")) {
                if viewModel.phase != .intro {
                    HStack(spacing: 8) {
                        if let date = viewModel.lastCheckedAt {
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                Text("查找于 \(context.date.timeIntervalSince(date) < 60 ? String(localized: "刚刚") : date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                                    .font(.system(size: 11))
                                    .foregroundColor(AppTheme.textMuted)
                            }
                        }
                        Button {
                            viewModel.discover()
                        } label: {
                            HStack(spacing: 6) {
                                if viewModel.phase == .discovering {
                                    ProgressView().scaleEffect(0.6).tint(AppTheme.textPrimary)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                Text("重新查找来源")
                            }
                        }
                        .buttonStyle(NeonOutlineButtonStyle())
                        .disabled(viewModel.phase == .discovering || viewModel.isMounting || viewModel.isUnmounting)
                    }
                }
            }

            switch viewModel.phase {
            case .intro:
                ScrollView {
                    ScanIntroView(
                        icon: "clock.arrow.circlepath",
                        title: String(localized: "找回误删的文件"),
                        message: String(localized: "macOS 会自动给磁盘拍本地快照，时间机器会定期备份。只要文件在快照或备份时还在，就能把它复制回来。"),
                        points: [
                            String(localized: "从 APFS 本地快照中找回"),
                            String(localized: "从时间机器备份中找回"),
                            String(localized: "只复制回来，绝不覆盖现有文件"),
                            String(localized: "需要管理员密码挂载快照（只读）"),
                        ],
                        buttonTitle: String(localized: "查找可用的快照与备份"),
                        footnote: String(localized: "查找来源只读取信息，不会修改磁盘上的任何东西"),
                        action: { viewModel.discover() }
                    )
                    .padding(.horizontal, CosmicSizes.pagePadding)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                }

            case .discovering where viewModel.lastCheckedAt == nil:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.regular)
                    Text("正在查找本地快照与时间机器备份…")
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            default:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if viewModel.discovery.needsFullDiskAccess || viewModel.permissionDenied {
                            RecoveryFullDiskAccessBanner()
                        }
                        if viewModel.hasAnySource {
                            sourcesCard
                            searchCard
                            if viewModel.isScanning || viewModel.hasSearched {
                                resultsSection
                            }
                        } else {
                            RecoveryEmptyState(timeMachineConfigured: viewModel.discovery.timeMachineConfigured)
                        }
                    }
                    .padding(.horizontal, CosmicSizes.pagePadding)
                    .padding(.vertical, 20)
                }

                if viewModel.hasSearched && !viewModel.results.isEmpty {
                    restoreBar
                }
            }
        }
        .alert("恢复所选项目？", isPresented: $showRestoreConfirm) {
            Button("取消", role: .cancel) {}
            Button("恢复") { viewModel.restoreSelected() }
        } message: {
            Text("\(viewModel.selection.count) 项（\(sizeText(viewModel.selectedSize, partial: viewModel.selectedSizeIsPartial))）将复制回 \(viewModel.selectedDestinationSummary)。同名项目已存在时另存为「（恢复）」副本，不会覆盖任何现有文件。")
        }
        .sheet(item: Binding(
            get: { viewModel.restoreReport.map(RestoreReportBox.init) },
            set: { if $0 == nil { viewModel.restoreReport = nil } }
        )) { box in
            RecoveryRestoreResultView(report: box.report, home: viewModel.home) {
                viewModel.restoreReport = nil
            }
        }
    }

    private func sizeText(_ size: Int64, partial: Bool) -> String {
        let text = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return partial ? String(localized: "至少 \(text)") : text
    }

    // MARK: - 可用来源

    private var sourcesCard: some View {
        let sources = viewModel.discovery.sources
        let visible = showAllSources ? sources : Array(sources.prefix(6))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("可用来源")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text(sourceCountText)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
                    .monospacedDigit()
                Spacer()
                if sources.count > 1 {
                    let allOn = sources.allSatisfy { viewModel.selectedSourceIDs.contains($0.id) }
                    Button(allOn ? String(localized: "取消全选") : String(localized: "全选")) {
                        viewModel.selectedSourceIDs = allOn ? [] : Set(sources.map(\.id))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if !viewModel.snapshots.isEmpty {
                snapshotHint
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            Divider().overlay(AppTheme.divider)

            ForEach(visible) { source in
                RecoverySourceRow(
                    source: source,
                    isSelected: viewModel.selectedSourceIDs.contains(source.id),
                    isMounted: viewModel.isMounted(source),
                    isReachable: viewModel.isReady(source) || source.kind == .localSnapshot,
                    onToggle: { viewModel.toggleSource(source) }
                )
                Divider().overlay(AppTheme.divider).padding(.leading, 60)
            }

            if sources.count > 6 {
                Button(showAllSources ? String(localized: "收起") : String(localized: "显示全部 \(sources.count) 个来源")) {
                    withAnimation(CosmicAnimations.smooth) { showAllSources.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(AppTheme.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            mountFooter
        }
        .themeCard()
    }

    private var sourceCountText: String {
        let snapshots = viewModel.snapshots.count
        let backups = viewModel.backups.count
        switch (snapshots, backups) {
        case (_, 0): return String(localized: "\(snapshots) 个本地快照")
        case (0, _): return String(localized: "\(backups) 个时间机器备份")
        default: return String(localized: "\(snapshots) 个本地快照 · \(backups) 个时间机器备份")
        }
    }

    private var snapshotHint: some View {
        let dates = viewModel.snapshots.compactMap(\.date)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hourglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppTheme.warning)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("本地快照通常只保留最近约 24 小时，macOS 会自动删除旧快照，请尽快找回。")
                    .foregroundColor(AppTheme.textSecondary)
                if let oldest = dates.min(), let newest = dates.max() {
                    Text("现有快照：最早 \(RecoveryFormat.shortDate(oldest))，最新 \(RecoveryFormat.shortDate(newest))")
                        .foregroundColor(AppTheme.textMuted)
                        .monospacedDigit()
                }
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var mountFooter: some View {
        let unmounted = viewModel.selectedUnmountedSnapshots
        let mountedCount = viewModel.mountedSnapshots.count
        if !unmounted.isEmpty || mountedCount > 0 || viewModel.notice != nil {
            VStack(alignment: .leading, spacing: 10) {
                if !unmounted.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.open.display")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(AppTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("所选的 \(unmounted.count) 个本地快照需要先挂载")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(AppTheme.textPrimary)
                            Text("只读挂载，不会改动快照或磁盘；需要输入一次管理员密码。")
                                .font(.system(size: 12))
                                .foregroundColor(AppTheme.textMuted)
                        }
                        Spacer()
                        Button {
                            viewModel.mountSelectedSnapshots()
                        } label: {
                            HStack(spacing: 6) {
                                if viewModel.isMounting {
                                    ProgressView().scaleEffect(0.55).tint(.white)
                                } else {
                                    Image(systemName: "externaldrive.badge.plus")
                                }
                                Text("挂载所选快照")
                            }
                        }
                        .buttonStyle(NeonButtonStyle())
                        .disabled(viewModel.isMounting || viewModel.isUnmounting)
                    }
                }
                if mountedCount > 0 {
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.fill.badge.checkmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(AppTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("已挂载 \(mountedCount) 个快照（只读）")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(AppTheme.textPrimary)
                            Text("不会出现在访达侧栏；找回后请卸载，重启 Mac 也会自动卸载。")
                                .font(.system(size: 12))
                                .foregroundColor(AppTheme.textMuted)
                        }
                        Spacer()
                        Button {
                            viewModel.unmountAll()
                        } label: {
                            HStack(spacing: 6) {
                                if viewModel.isUnmounting {
                                    ProgressView().scaleEffect(0.55).tint(AppTheme.textPrimary)
                                } else {
                                    Image(systemName: "eject")
                                }
                                Text("完成，卸载快照")
                            }
                        }
                        .buttonStyle(NeonOutlineButtonStyle())
                        .disabled(viewModel.isMounting || viewModel.isUnmounting || viewModel.isRestoring)
                    }
                }
                if let notice = viewModel.notice {
                    Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(notice.isError ? AppTheme.danger : AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(AppTheme.ink(0.025))
        }
    }

    // MARK: - 查找条件

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Picker("", selection: $viewModel.mode) {
                    Text("最近删掉的文件").tag(RecoverySearchMode.missing)
                    Text("按文件名搜索").tag(RecoverySearchMode.name)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Toggle("包含隐藏文件", isOn: $viewModel.includeHidden)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textSecondary)

                Spacer()
            }

            Text(viewModel.mode == .missing
                 ? String(localized: "列出所选来源里有、但原位置现在已经没有的文件和文件夹。整个文件夹都不在了时只列一行。")
                 : String(localized: "在所选来源中按名称查找（不区分大小写，支持 * 通配符）。现在仍存在的文件也会列出，恢复时另存为副本。"))
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            RecoveryFlowLayout(spacing: 8) {
                    ForEach(RecoveryFolder.quickPicks) { folder in
                        FolderChip(title: folder.title, icon: folder.icon, isOn: viewModel.folder == folder) {
                            viewModel.folder = folder
                        }
                    }
                    if case .custom = viewModel.folder {
                        FolderChip(title: viewModel.folder.title, icon: viewModel.folder.icon, isOn: true) {}
                    }
                    FolderChip(title: String(localized: "其他文件夹…"), icon: "folder.badge.plus", isOn: false) {
                        chooseCustomFolder()
                    }
            }

            HStack(spacing: 12) {
                if viewModel.mode == .name {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.textMuted)
                        TextField("文件名，例如 报告 或 *.pdf", text: $viewModel.searchTerm)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .onSubmit { viewModel.startSearch() }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: CosmicSizes.controlRadius, style: .continuous)
                            .fill(AppTheme.ink(0.045))
                            .overlay(
                                RoundedRectangle(cornerRadius: CosmicSizes.controlRadius, style: .continuous)
                                    .strokeBorder(AppTheme.surfaceBorder, lineWidth: 1)
                            )
                    )
                    .frame(maxWidth: 360)
                } else {
                    Text("查找范围：\(viewModel.folder.relativePath.isEmpty ? "~" : "~/" + viewModel.folder.relativePath)")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if let hint = searchDisabledHint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }

                if viewModel.isScanning {
                    Button("停止") { viewModel.cancelSearch() }
                        .buttonStyle(NeonOutlineButtonStyle())
                } else {
                    Button {
                        viewModel.startSearch()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                            Text(viewModel.hasSearched ? "重新查找" : "开始查找")
                        }
                    }
                    .buttonStyle(NeonButtonStyle())
                    .disabled(!viewModel.canSearch || viewModel.isRestoring)
                }
            }
        }
        .padding(16)
        .themeCard()
    }

    private var searchDisabledHint: String? {
        guard !viewModel.isScanning else { return nil }
        if viewModel.selectedSourceIDs.isEmpty { return String(localized: "先在上方勾选来源") }
        if viewModel.readySelectedSources.isEmpty {
            return viewModel.selectedUnmountedSnapshots.isEmpty
                ? String(localized: "所选备份的磁盘未连接")
                : String(localized: "先挂载所选快照")
        }
        if viewModel.mode == .name && viewModel.searchTerm.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "输入要找的文件名")
        }
        return nil
    }

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = viewModel.home
        panel.prompt = String(localized: "选择")
        panel.message = String(localized: "选择主目录中的一个文件夹，在快照和备份里的同一位置查找")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = viewModel.home.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == home {
            viewModel.folder = .home
        } else if path.hasPrefix(home + "/") {
            viewModel.folder = .custom(String(path.dropFirst(home.count + 1)))
        } else {
            viewModel.folder = .home
        }
    }

    // MARK: - 结果

    private var resultsSection: some View {
        let items = viewModel.sortedResults
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if viewModel.isScanning {
                    ProgressView().scaleEffect(0.6).tint(AppTheme.textSecondary)
                    Text("正在查找… 已检查 \(viewModel.checkedCount.formatted()) 项")
                        .monospacedDigit()
                } else {
                    Text("找到 \(items.count) 项 · 查找了 \(viewModel.searchedSources.count) 个来源、\(viewModel.checkedCount.formatted()) 个项目")
                        .monospacedDigit()
                }
                Spacer()
                if !items.isEmpty && !viewModel.isScanning {
                    Picker("", selection: $viewModel.sort) {
                        ForEach(RecoveryResultSort.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    let selectable = items.filter { !viewModel.restoredIDs.contains($0.id) }
                    let allOn = !selectable.isEmpty && selectable.allSatisfy { viewModel.isSelected($0) }
                    Button(allOn ? String(localized: "取消全选") : String(localized: "全选")) { viewModel.selectAll(!allOn) }
                        .buttonStyle(.plain)
                        .foregroundColor(AppTheme.accent)
                }
            }
            .font(.system(size: 13))
            .foregroundColor(AppTheme.textSecondary)

            if viewModel.truncated {
                Label("结果过多，请缩小文件夹范围。每个来源最多列出 \(RecoveryScanner.resultLimit.formatted()) 项。", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.warning)
            }
            if !viewModel.sourcesWithoutHome.isEmpty {
                Label("\(viewModel.sourcesWithoutHome.count) 个来源里没有找到你的主目录，已跳过。", systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
            }

            if items.isEmpty && !viewModel.isScanning {
                noResults
            } else if !items.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        RecoveryResultRow(
                            item: item,
                            sourceLabel: viewModel.source(for: item).map(RecoveryFormat.sourceLabel) ?? "",
                            size: viewModel.size(of: item),
                            isSelected: viewModel.isSelected(item),
                            isRestored: viewModel.restoredIDs.contains(item.id),
                            onToggle: { viewModel.toggle(item) }
                        )
                        Divider().overlay(AppTheme.divider).padding(.leading, 76)
                    }
                }
                .themeCard()
            }
        }
    }

    private var noResults: some View {
        VStack(spacing: 10) {
            Image(systemName: viewModel.mode == .missing ? "checkmark.circle" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(AppTheme.accent)
            Text(viewModel.mode == .missing
                 ? String(localized: "所选来源里没有「原位置已经不在」的项目")
                 : String(localized: "所选来源里没有名称匹配的项目"))
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(AppTheme.textPrimary)
            Text("试试勾选更早的来源、换成「整个主目录」，或打开「包含隐藏文件」。快照或备份之后才新建的文件无法从这里找回。")
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .themeCard()
    }

    // MARK: - 底部操作栏

    private var restoreBar: some View {
        HStack(spacing: 16) {
            if viewModel.isRestoring {
                ProgressView(value: Double(viewModel.restoreProgress), total: Double(max(viewModel.selection.count, 1)))
                    .tint(AppTheme.accent)
                    .frame(width: 180)
                Text("正在恢复…")
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.textSecondary)
            } else {
                Text("已选 \(viewModel.selection.count) 项 · \(sizeText(viewModel.selectedSize, partial: viewModel.selectedSizeIsPartial))")
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.textSecondary)
                    .monospacedDigit()
                if viewModel.selectedItems.contains(where: \.existsNow) {
                    Label("含当前仍存在的项目，将另存为副本", systemImage: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                }
            }

            Spacer()

            Button {
                guard ProGate.allowAction() else { return }
                showRestoreConfirm = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward.circle")
                    Text("恢复所选")
                }
            }
            .buttonStyle(NeonButtonStyle(isLarge: true))
            .disabled(viewModel.selection.isEmpty || viewModel.isRestoring || viewModel.isScanning)
        }
        .padding(.horizontal, CosmicSizes.pagePadding)
        .padding(.vertical, 14)
        .background(
            Rectangle()
                .fill(AppTheme.sidebarColor.opacity(0.92))
                .overlay(Rectangle().fill(AppTheme.divider).frame(height: 1), alignment: .top)
        )
    }
}

// MARK: - 格式化

enum RecoveryFormat {
    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func sourceLabel(_ source: RecoverySource) -> String {
        let date = source.date.map(shortDate) ?? (source.name as NSString).lastPathComponent
        switch source.kind {
        case .localSnapshot: return String(localized: "本地快照 · \(date)")
        case .timeMachine: return String(localized: "时间机器 · \(date)")
        }
    }
}

private struct RestoreReportBox: Identifiable {
    let id = UUID()
    let report: RecoveryRestoreReport
}

// MARK: - 来源行

private struct RecoverySourceRow: View {
    let source: RecoverySource
    let isSelected: Bool
    let isMounted: Bool
    let isReachable: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .toggleStyle(CosmicCheckboxStyle(accentColor: AppTheme.accent))
                .labelsHidden()

            GradientIconTile(
                systemName: source.kind == .localSnapshot ? "camera.metering.center.weighted" : "clock.arrow.circlepath",
                gradient: source.kind == .localSnapshot
                    ? AppTheme.tileGradient(Color(hex: 0x34D3B4), Color(hex: 0x0F8F9E))
                    : AppTheme.tileGradient(Color(hex: 0x5AB8F5), Color(hex: 0x2F86D8)),
                size: 28,
                glyphRatio: 0.5,
                shadowColor: source.kind == .localSnapshot ? Color(hex: 0x0F8F9E) : Color(hex: 0x2F86D8)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(RecoveryFormat.sourceLabel(source))
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.textPrimary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(source.name)

            Spacer(minLength: 12)

            statusBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(isSelected ? AppTheme.accent.opacity(0.05) : (isHovered ? AppTheme.surfaceHover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovered = $0 }
    }

    private var detail: String {
        let relative = source.date.map { $0.formatted(.relative(presentation: .named)) }
        switch source.kind {
        case .localSnapshot:
            return relative.map { String(localized: "\($0) · 启动磁盘") } ?? String(localized: "启动磁盘")
        case .timeMachine:
            return relative.map { String(localized: "\($0) · 备份磁盘") } ?? String(localized: "备份磁盘")
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch source.kind {
        case .localSnapshot:
            badge(isMounted ? String(localized: "已挂载") : String(localized: "未挂载"), color: isMounted ? AppTheme.accent : AppTheme.textMuted)
        case .timeMachine:
            badge(isReachable ? String(localized: "可直接浏览") : String(localized: "备份磁盘未连接"), color: isReachable ? AppTheme.accent : AppTheme.warning)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - 文件夹标签

private struct FolderChip: View {
    let title: String
    let icon: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(isOn ? AppTheme.onAccent : AppTheme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(isOn ? AppTheme.accent : AppTheme.ink(0.06)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 自动换行排布（文件夹标签）

private struct RecoveryFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width && !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - 结果行

private struct RecoveryResultRow: View {
    let item: RecoveryItem
    let sourceLabel: String
    let size: Int64?
    let isSelected: Bool
    let isRestored: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    private var location: String {
        let parent = (item.relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? "~" : "~/" + parent
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .toggleStyle(CosmicCheckboxStyle(accentColor: AppTheme.accent))
                .labelsHidden()
                .disabled(isRestored)
                .opacity(isRestored ? 0.4 : 1)

            Image(nsImage: RecoveryIconCache.icon(for: item.sourcePath))
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isRestored {
                        tag(String(localized: "已恢复"), color: AppTheme.accent)
                    } else if item.existsNow {
                        tag(String(localized: "当前仍存在"), color: AppTheme.warning)
                    }
                    if item.isDirectory && !item.isPackage {
                        tag(String(localized: "文件夹"), color: AppTheme.textMuted)
                    }
                }
                Text(location)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help("~/" + item.relativePath)

            Spacer(minLength: 12)

            if isHovered {
                HStack(spacing: 10) {
                    Button {
                        RecoveryQuickLook.shared.show(URL(fileURLWithPath: item.sourcePath))
                    } label: {
                        Image(systemName: "eye")
                    }
                    .help("快速查看")
                    Button {
                        NSWorkspace.shared.selectFile(item.sourcePath, inFileViewerRootedAtPath: "")
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("在访达中显示")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textSecondary)
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text(sourceLabel)
                    .lineLimit(1)
                if item.duplicateCount > 0 {
                    Text("另有 \(item.duplicateCount) 个来源相同")
                        .foregroundColor(AppTheme.textMuted.opacity(0.8))
                }
            }
            .font(.system(size: 11))
            .foregroundColor(AppTheme.textMuted)
            .frame(width: 190, alignment: .trailing)

            Text(item.modified.map(RecoveryFormat.shortDate) ?? "—")
                .font(.system(size: 11))
                .foregroundColor(AppTheme.textMuted)
                .monospacedDigit()
                .frame(width: 96, alignment: .trailing)

            Group {
                if let size {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                } else {
                    ProgressView().scaleEffect(0.45).frame(height: 14)
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(AppTheme.textPrimary)
            .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? AppTheme.accent.opacity(0.06) : (isHovered ? AppTheme.surfaceHover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { if !isRestored { onToggle() } }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("快速查看") { RecoveryQuickLook.shared.show(URL(fileURLWithPath: item.sourcePath)) }
            Button("在访达中显示") { NSWorkspace.shared.selectFile(item.sourcePath, inFileViewerRootedAtPath: "") }
            Button("拷贝原始路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("~/" + item.relativePath, forType: .string)
            }
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Capsule().fill(color.opacity(0.12)))
            .fixedSize()
    }
}

enum RecoveryIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        if cache.count > 2_000 { cache.removeAll() }
        cache[path] = icon
        return icon
    }
}

// MARK: - 快速查看

final class RecoveryQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = RecoveryQuickLook()
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.open(url)
            return
        }
        panel.dataSource = self
        panel.reloadData()
        if panel.isVisible {
            panel.refreshCurrentPreviewItem()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}

// MARK: - 完全磁盘访问权限提示

private struct RecoveryFullDiskAccessBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppTheme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("需要「完全磁盘访问权限」才能读取时间机器备份和快照里的文件")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text("在「系统设置 › 隐私与安全性 › 完全磁盘访问权限」中打开 MacClean，然后点「重新查找来源」。")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("打开系统设置") { FullDiskAccess.openSettings() }
                .buttonStyle(NeonOutlineButtonStyle())
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: CosmicSizes.cardRadius, style: .continuous)
                .fill(AppTheme.warning.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: CosmicSizes.cardRadius, style: .continuous)
                        .strokeBorder(AppTheme.warning.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

// MARK: - 没有任何来源

private struct RecoveryEmptyState: View {
    let timeMachineConfigured: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 结论：如实说明
            HStack(alignment: .top, spacing: 16) {
                GradientIconTile(
                    systemName: "externaldrive.badge.xmark",
                    gradient: AppTheme.tileGradient(Color(hex: 0x9AA5B8), Color(hex: 0x5F6B80)),
                    size: 48,
                    cornerRatio: 0.27,
                    glyphRatio: 0.46,
                    shadowColor: Color(hex: 0x5F6B80)
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text("没有找到可用的快照或备份")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                    Text("这台 Mac 上没有可用的快照或时间机器备份，彻底删除的文件无法从这里找回。")
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("清空废纸篓后，固态硬盘会很快抹掉这些数据所在的空间，任何软件（包括 MacClean）都无法把它们找回来。下面这些地方可能还留着副本：")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themeCard()

            // 其他可能的途径
            VStack(alignment: .leading, spacing: 0) {
                Text("还可以去这些地方找找")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 6)

                checklistRow(
                    icon: "icloud",
                    color: AppTheme.sky,
                    title: String(localized: "iCloud 云盘「最近删除」"),
                    detail: String(localized: "存放在 iCloud 云盘里的文件删除后会保留 30 天，可在 iCloud.com 的「最近删除」里恢复。"),
                    action: (String(localized: "打开 iCloud.com"), { open("https://www.icloud.com/iclouddrive/") })
                )
                Divider().overlay(AppTheme.divider).padding(.leading, 58)
                checklistRow(
                    icon: "photo.on.rectangle",
                    color: AppTheme.pink,
                    title: String(localized: "「照片」App 的「最近删除」"),
                    detail: String(localized: "照片和视频删除后会在「最近删除」相簿里保留 30 天。"),
                    action: (String(localized: "打开照片"), { openApp("com.apple.Photos") })
                )
                Divider().overlay(AppTheme.divider).padding(.leading, 58)
                checklistRow(
                    icon: "note.text",
                    color: AppTheme.warning,
                    title: String(localized: "备忘录 / 邮件的「最近删除」"),
                    detail: String(localized: "备忘录的「最近删除」文件夹和邮件的「废纸篓」里可能还有副本。"),
                    action: nil
                )
                Divider().overlay(AppTheme.divider).padding(.leading, 58)
                checklistRow(
                    icon: "exclamationmark.triangle",
                    color: AppTheme.danger,
                    title: String(localized: "在找回之前，尽量不要往这块磁盘写入大量数据"),
                    detail: String(localized: "例如下载大文件、安装应用或拷贝视频，以免覆盖可能还残留的数据。"),
                    action: nil
                )
            }
            .padding(.bottom, 6)
            .themeCard()

            // 以后的保障
            HStack(spacing: 14) {
                GradientIconTile(
                    systemName: "clock.arrow.circlepath",
                    gradient: AppTheme.tileGradient(Color(hex: 0x34D3B4), Color(hex: 0x0F8F9E)),
                    size: 40,
                    cornerRatio: 0.27,
                    glyphRatio: 0.46,
                    shadowColor: Color(hex: 0x0F8F9E)
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text("开启时间机器，以后误删也能找回")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                    Text(timeMachineConfigured
                         ? String(localized: "已设置了备份磁盘，但还没有完成过备份。连接备份磁盘后，时间机器会每小时自动备份，并在启动磁盘上保留本地快照。")
                         : String(localized: "接上一块外置硬盘或网络磁盘，时间机器会每小时自动备份，并在启动磁盘上保留本地快照。"))
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button {
                    openTimeMachineSettings()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape")
                        Text("打开时间机器设置")
                    }
                }
                .buttonStyle(NeonButtonStyle())
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: CosmicSizes.cardRadius, style: .continuous)
                    .fill(LinearGradient(colors: [AppTheme.accent.opacity(0.08), AppTheme.accent.opacity(0)], startPoint: .leading, endPoint: .trailing))
            )
            .themeCard()
        }
    }

    private func checklistRow(icon: String, color: Color, title: String, detail: String, action: (String, () -> Void)?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppTheme.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(NeonOutlineButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    private func openApp(_ bundleID: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func openTimeMachineSettings() {
        for string in ["x-apple.systempreferences:com.apple.Time-Machine-Settings.extension", "x-apple.systempreferences:com.apple.prefs.backup"] {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}

// MARK: - 恢复结果

private struct RecoveryRestoreResultView: View {
    let report: RecoveryRestoreReport
    let home: URL
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                GradientIconTile(
                    systemName: report.failed.isEmpty ? "checkmark" : "exclamationmark",
                    gradient: report.failed.isEmpty ? AppTheme.brandGradient : AppTheme.warningGradient,
                    size: 44,
                    cornerRatio: 0.27,
                    glyphRatio: 0.46,
                    shadowColor: report.failed.isEmpty ? AppTheme.accent : AppTheme.warning
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.failed.isEmpty ? "恢复完成" : "部分项目未能恢复")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                    Text("已恢复 \(report.restored.count) 项，失败 \(report.failed.count) 项")
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.textSecondary)
                        .monospacedDigit()
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(report.restored, id: \.self) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(AppTheme.accent)
                            Text(displayPath(entry.destination))
                                .foregroundColor(AppTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if (entry.destination as NSString).lastPathComponent != entry.item.name {
                                Text("另存为副本")
                                    .foregroundColor(AppTheme.textMuted)
                            }
                        }
                    }
                    ForEach(report.failed, id: \.self) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(AppTheme.danger)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("~/" + entry.item.relativePath)
                                    .foregroundColor(AppTheme.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(entry.reason)
                                    .foregroundColor(AppTheme.textMuted)
                            }
                        }
                    }
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: CosmicSizes.controlRadius, style: .continuous).fill(AppTheme.ink(0.04)))

            HStack {
                Spacer()
                if !report.restored.isEmpty {
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting(report.restored.map { URL(fileURLWithPath: $0.destination) })
                    }
                    .buttonStyle(NeonOutlineButtonStyle())
                }
                Button("完成", action: onDismiss)
                    .buttonStyle(NeonButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(AppTheme.primaryGradient)
    }

    private func displayPath(_ path: String) -> String {
        let homePath = home.standardizedFileURL.path
        return path.hasPrefix(homePath + "/") ? "~/" + path.dropFirst(homePath.count + 1) : path
    }
}
