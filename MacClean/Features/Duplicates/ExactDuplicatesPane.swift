//
//  ExactDuplicatesPane.swift
//  MacClean
//
//  「重复与相似 → 完全相同的文件」：范围与条件卡片、扫描进度、按可释放空间排序的重复组、底部清理栏。
//  页头与模式切换在 SimilarPhotosView（页面入口）里。
//

import SwiftUI

// MARK: - 页头按钮

struct ExactDuplicatesScanControls: View {
    @ObservedObject var viewModel: DuplicatesViewModel

    var body: some View {
        LastScannedLabel(date: viewModel.isScanning ? nil : viewModel.lastScannedAt)
        if viewModel.isScanning {
            Button("停止") { viewModel.cancelScan() }
                .buttonStyle(NeonOutlineButtonStyle())
        } else if viewModel.hasScanned || viewModel.wasCancelled {
            Button {
                viewModel.scan()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                    Text("重新扫描")
                }
            }
            .buttonStyle(NeonButtonStyle())
            .disabled(viewModel.folders.isEmpty || viewModel.isCleaning)
        }
    }
}

// MARK: - 内容

struct ExactDuplicatesPane: View {
    @ObservedObject var viewModel: DuplicatesViewModel

    @State private var showConfirm = false
    @State private var showCompletion = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    configCard
                    if viewModel.isScanning {
                        scanningCard
                    } else if !viewModel.hasScanned {
                        introCard
                    } else {
                        if viewModel.wasCancelled {
                            noteRow(icon: "pause.circle", text: String(localized: "扫描已取消，下面是上一次的结果"))
                        }
                        if viewModel.settingsChangedSinceScan {
                            settingsChangedRow
                        }
                        if !viewModel.deniedFolders.isEmpty {
                            permissionBanner
                        }
                        resultsHeader
                        ForEach(viewModel.groups) { group in
                            DuplicateGroupCard(group: group, viewModel: viewModel)
                        }
                    }
                }
                .padding(.horizontal, CosmicSizes.pagePadding)
                .padding(.vertical, 20)
            }

            if viewModel.hasScanned && !viewModel.isScanning && !viewModel.groups.isEmpty {
                DuplicatesFooterBar(viewModel: viewModel) {

                    showConfirm = true
                }
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
            Text("\(viewModel.selectedCount) 个副本（\(ByteCountFormatter.string(fromByteCount: viewModel.selectedSize, countStyle: .file))）将移入废纸篓，每组保留的那一份不会动。可在「清理记录」中一键恢复。")
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

    // MARK: - 引导

    @ViewBuilder
    private var introCard: some View {
        if viewModel.wasCancelled {
            ScanIntroView(
                icon: "doc.on.doc",
                title: String(localized: "扫描已取消"),
                message: String(localized: "已停止比对，没有改动任何文件。可以调整范围后重新开始。"),
                buttonTitle: String(localized: "重新扫描"),
                compact: true,
                action: { viewModel.scan() }
            )
            .disabled(viewModel.folders.isEmpty || viewModel.isCleaning)
        } else {
            ScanIntroView(
                icon: "doc.on.doc",
                title: String(localized: "找出完全相同的文件"),
                message: viewModel.folders.isEmpty
                    ? String(localized: "先在上方添加至少一个要扫描的文件夹。")
                    : String(localized: "逐个比对上方文件夹里文件的内容，找出散落在各处、一模一样的副本。"),
                points: [
                    String(localized: "按文件内容比对，100% 相同才算重复"),
                    String(localized: "每组自动保留一份，绝不会整组删除"),
                    String(localized: "支持任意类型的文件"),
                    String(localized: "删除先移入废纸篓，可一键撤销"),
                ],
                compact: true,
                action: { viewModel.scan() }
            )
            .disabled(viewModel.folders.isEmpty || viewModel.isCleaning)
        }
    }

    // MARK: - 范围与条件

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("扫描范围")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text("始终跳过 ~/Library、废纸篓、隐藏文件、应用包内部和符号链接；iCloud 云盘需手动添加，且只比对已下载的文件")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(2)
            }

            FlowRow(spacing: 8) {
                ForEach(viewModel.folders, id: \.self) { folder in
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                        Text(viewModel.folderTitle(folder))
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
                configLabel(String(localized: "最小大小"))
                Picker("", selection: $viewModel.minSize) {
                    ForEach(DuplicateSizeFloor.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .disabled(viewModel.isScanning)
                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: 12) {
                configLabel(String(localized: "类型"))
                    .frame(height: 28)
                FlowRow(spacing: 8) {
                    TypeChip(title: String(localized: "全部"), icon: "square.grid.2x2", isOn: viewModel.types.isEmpty) {
                        viewModel.types = []
                    }
                    ForEach(DuplicateTypeFilter.allCases) { type in
                        TypeChip(title: type.title, icon: type.icon, isOn: viewModel.types.contains(type)) {
                            viewModel.toggleType(type)
                        }
                    }
                }
                .disabled(viewModel.isScanning)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    private func configLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(AppTheme.textMuted)
            .frame(minWidth: 52, alignment: .leading)
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

    // MARK: - 扫描中

    private var scanningCard: some View {
        let progress = viewModel.progress
        return VStack(alignment: .leading, spacing: 10) {
            Group {
                switch progress.phase {
                case .counting:
                    Text("正在清点文件… 已检查 \(progress.filesChecked.formatted()) 个")
                case .gathering:
                    Text("正在收集大小相同的文件… 共检查 \(progress.filesChecked.formatted()) 个")
                case .comparing:
                    Text("正在比对内容 \(progress.candidatesDone.formatted()) / \(progress.candidatesTotal.formatted())")
                }
            }
            .font(.system(size: 13))
            .monospacedDigit()
            .foregroundColor(AppTheme.textSecondary)

            if progress.phase == .comparing, progress.candidatesTotal > 0 {
                ProgressView(value: Double(progress.candidatesDone), total: Double(progress.candidatesTotal))
                    .tint(AppTheme.accent)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(AppTheme.accent)
            }

            HStack(spacing: 6) {
                Text("已检查 \(progress.filesChecked.formatted()) 个文件 · 已读取 \(ByteCountFormatter.string(fromByteCount: progress.bytesHashed, countStyle: .file))")
                    .monospacedDigit()
                    .layoutPriority(1)
                if !progress.currentFolder.isEmpty {
                    Text(verbatim: "·")
                    Text(viewModel.displayPath(progress.currentFolder))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.system(size: 11.5))
            .foregroundColor(AppTheme.textMuted)

            Text("只读取文件内容计算指纹，在本机完成，不会改动任何文件。")
                .font(.system(size: 11))
                .foregroundColor(AppTheme.textMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    // MARK: - 提示

    private func noteRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(AppTheme.textMuted)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private var settingsChangedRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundColor(AppTheme.warning)
            Text("扫描范围或条件已更改，重新扫描后生效")
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textSecondary)
            Button("重新扫描") { viewModel.scan() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppTheme.accent)
                .disabled(viewModel.folders.isEmpty || viewModel.isCleaning)
        }
    }

    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppTheme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("有 \(viewModel.deniedFolders.count) 个文件夹没有读取权限，结果可能不完整")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text(viewModel.deniedFolders.prefix(3).map(viewModel.displayPath).joined(separator: "、"))
                    .font(.system(size: 11.5))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button("授予完全磁盘访问权限") { FullDiskAccess.openSettings() }
                .buttonStyle(NeonOutlineButtonStyle())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CosmicSizes.cardRadius, style: .continuous)
                .fill(AppTheme.warning.opacity(0.08))
        )
        .themeCard()
    }

    // MARK: - 结果

    @ViewBuilder
    private var resultsHeader: some View {
        if viewModel.groups.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 30))
                    .foregroundColor(AppTheme.accent)
                Text("没有发现完全相同的文件")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text("已比对 \(viewModel.filesChecked.formatted()) 个文件，没有内容一模一样的副本。可以试试降低最小大小或添加其他文件夹。")
                    .font(.system(size: 12.5))
                    .foregroundColor(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 40)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .themeCard()
        } else {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(viewModel.groups.count) 组重复 · \(viewModel.copyCount) 个多余副本")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundColor(AppTheme.accent)
                        Text("每组只留一份可释放 \(ByteCountFormatter.string(fromByteCount: viewModel.reclaimableSize, countStyle: .file))；保留的那一份不能勾选，不会整组删除")
                            .monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
                }
                Spacer()
                Button("取消选择") { viewModel.clearSelection() }
                    .buttonStyle(NeonOutlineButtonStyle())
                    .disabled(viewModel.selected.isEmpty)
                Button {
                    viewModel.selectAllCopies()
                } label: {
                    Label("选中全部副本", systemImage: "checkmark.circle")
                }
                .buttonStyle(NeonOutlineButtonStyle())
            }
        }
    }
}

// MARK: - 类型标签

private struct TypeChip: View {
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
            }
            .foregroundColor(isOn ? AppTheme.onAccent : AppTheme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(isOn ? AppTheme.accent : AppTheme.ink(0.06)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 重复组卡片

private struct DuplicateGroupCard: View {
    let group: DuplicateGroup
    @ObservedObject var viewModel: DuplicatesViewModel

    private var keeper: String { viewModel.keeperPath(of: group) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: AppLookup.fileIcon(path: keeper))
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text((keeper as NSString).lastPathComponent)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(group.files.count) 份完全相同 · 每份 \(ByteCountFormatter.string(fromByteCount: group.size, countStyle: .file))")
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundColor(AppTheme.textMuted)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("可释放")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.textMuted)
                    Text(ByteCountFormatter.string(fromByteCount: group.reclaimableSize, countStyle: .file))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(AppTheme.textPrimary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            ForEach(group.files) { file in
                Divider().overlay(AppTheme.divider)
                DuplicateFileRow(
                    file: file,
                    location: viewModel.displayPath(file.path),
                    folder: (file.parentPath as NSString).lastPathComponent,
                    isKeeper: file.path == keeper,
                    isSelected: viewModel.isSelected(file),
                    onToggle: { viewModel.toggle(file, in: group) },
                    onKeep: { viewModel.keep(file, in: group) },
                    onIgnore: { viewModel.ignore(file) }
                )
            }
        }
        .themeCard()
    }
}

private struct DuplicateFileRow: View {
    let file: DuplicateFile
    let location: String
    let folder: String
    let isKeeper: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    let onKeep: () -> Void
    let onIgnore: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            if isKeeper {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AppTheme.accent)
                    .frame(width: 17, height: 17)
                    .help("这是保留的一份，不能勾选；要删除它，请先在另一份上点「保留这个」")
            } else {
                Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                    .toggleStyle(CosmicCheckboxStyle(accentColor: AppTheme.accent))
                    .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(location)
                    .font(.system(size: 12.5))
                    .foregroundColor(isSelected ? AppTheme.textSecondary : AppTheme.textPrimary)
                    .strikethrough(isSelected, color: AppTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("位于「\(folder)」 · 修改于 \(file.modified.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(1)
            }
            .help(file.path)

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                iconButton("eye", help: String(localized: "快速查看")) {
                    RecoveryQuickLook.shared.show(URL(fileURLWithPath: file.path))
                }
                iconButton("magnifyingglass", help: String(localized: "在 Finder 中显示")) {
                    NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
                }
            }
            .opacity(isHovered ? 1 : 0.55)

            if isKeeper {
                Text("保留")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppTheme.onAccent)
                    .padding(.horizontal, 10)
                    .frame(width: 84, height: 24)
                    .background(Capsule().fill(AppTheme.accent))
            } else {
                Button(action: onKeep) {
                    Text("保留这个")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.accent)
                        .frame(width: 84, height: 24)
                        .background(Capsule().stroke(AppTheme.accent.opacity(0.45), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(isSelected ? AppTheme.danger.opacity(0.05) : (isHovered ? AppTheme.surfaceHover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { if !isKeeper { onToggle() } }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("快速查看") { RecoveryQuickLook.shared.show(URL(fileURLWithPath: file.path)) }
            Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "") }
            Button("拷贝路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
            if !isKeeper {
                Divider()
                Button("保留这个", action: onKeep)
            }
            Divider()
            Button("始终忽略此文件", action: onIgnore)
        }
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 底部栏

private struct DuplicatesFooterBar: View {
    @ObservedObject var viewModel: DuplicatesViewModel
    let action: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            if viewModel.isCleaning {
                ProgressView(value: viewModel.cleanProgress)
                    .tint(AppTheme.accent)
                    .frame(width: 180)
                Text("正在清理…")
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.textSecondary)
            } else if let restore = viewModel.lastRestoreResult {
                Label(
                    "已恢复 \(restore.restoredCount) 项 · \(ByteCountFormatter.string(fromByteCount: restore.restoredSize, countStyle: .file))",
                    systemImage: "arrow.uturn.backward.circle"
                )
                .font(.system(size: 13))
                .foregroundColor(AppTheme.textSecondary)
            } else {
                Text("已选 \(viewModel.selectedCount) 个副本 · 可释放 \(ByteCountFormatter.string(fromByteCount: viewModel.selectedSize, countStyle: .file))")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textSecondary)
                Label("每组保留一份", systemImage: "lock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.accent)
            }

            Spacer()

            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text("清理")
                }
            }
            .buttonStyle(NeonButtonStyle(isLarge: true))
            .disabled(viewModel.selectedCount == 0 || viewModel.isCleaning)
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
