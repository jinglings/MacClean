//
//  CleanGroupViews.swift
//  MacClean
//
//  分组清理页面：页头 + 汇总 + 可展开分组卡片 + 底部操作栏 + 完成/撤销 + 清理记录。
//  「释放空间」与「开发缓存」共用。
//

import SwiftUI

// MARK: - 页面

struct CleanGroupsPage: View {
    let title: String
    let subtitle: String
    @ObservedObject var viewModel: CleanGroupsViewModel
    /// 未扫描时引导卡片上的说明
    var introIcon = "magnifyingglass"
    var introMessage = ""
    var introPoints: [String] = []

    @State private var expandedGroups: Set<String> = []
    @State private var showConfirm = false
    @State private var showCompletion = false
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: localizedTitle, subtitle: Self.localized(subtitle)) {
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
                    ScanButton(hasScanned: viewModel.hasScanned, isScanning: viewModel.isScanning) {
                        viewModel.scanAll()
                    }
                    .disabled(viewModel.isCleaning)
                }
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if !viewModel.hasScanned && !viewModel.isScanning {
                        ScanIntroView(
                            icon: introIcon,
                            title: String(localized: "扫描\(localizedTitle)"),
                            message: Self.localized(introMessage),
                            points: introPoints.map(Self.localized),
                            action: { viewModel.scanAll() }
                        )
                    } else {
                    summaryCard
                        .padding(.bottom, 4)

                    ForEach($viewModel.groups) { $group in
                        CleanGroupCard(
                            group: $group,
                            isExpanded: expandedGroups.contains(group.id),
                            onToggleExpanded: { toggle(group.id) },
                            onSelectAll: { viewModel.setSelection(groupID: group.id, selected: $0) },
                            onIgnore: { viewModel.ignore($0) }
                        )
                    }
                    }
                }
                .padding(.horizontal, CosmicSizes.pagePadding)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }

            if viewModel.hasScanned || viewModel.isScanning {
                footerBar
            }
        }
        .alert("确认清理", isPresented: $showConfirm) {
            Button("取消", role: .cancel) {}
            Button(viewModel.permanentSelectedSize > 0 ? String(localized: "清理并永久删除") : String(localized: "移入废纸篓"), role: .destructive) {
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
                permanentlyFreed: result?.permanentlyFreed ?? 0,
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
            CleanupHistoryView(onRestored: { viewModel.scanAll() })
                .frame(width: 640, height: 520)
        }
    }

    /// 调用方传入的文案按本地化 key 查表；已是译文时查不到，原样返回。
    private static func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }

    private var localizedTitle: String { Self.localized(title) }

    private func toggle(_ id: String) {
        withAnimation(CosmicAnimations.smooth) {
            if expandedGroups.contains(id) {
                expandedGroups.remove(id)
            } else {
                expandedGroups.insert(id)
            }
        }
    }

    private var confirmMessage: String {
        let selected = viewModel.selectedItems
        let recoverable = viewModel.selectedSize - viewModel.permanentSelectedSize
        var lines: [String] = []
        if recoverable > 0 {
            lines.append(String(localized: "\(ByteCountFormatter.string(fromByteCount: recoverable, countStyle: .file)) 将移入废纸篓，可在「清理记录」中一键恢复。"))
        }
        if viewModel.permanentSelectedSize > 0 {
            lines.append(String(localized: "废纸篓中的 \(ByteCountFormatter.string(fromByteCount: viewModel.permanentSelectedSize, countStyle: .file)) 将被永久删除，无法恢复。"))
        }
        lines.append(String(localized: "共 \(selected.count) 项。"))
        return lines.joined(separator: "\n")
    }

    // MARK: - 汇总

    private var summaryCard: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                (viewModel.isScanning ? Text("正在扫描…") : Text("共发现"))
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.textSecondary)
                Text(ByteCountFormatter.string(fromByteCount: viewModel.totalSize, countStyle: .file))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textPrimary)
                    .contentTransition(.numericText())
            }

            Rectangle()
                .fill(AppTheme.divider)
                .frame(width: 1, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text("已选择")
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.textSecondary)
                Text(ByteCountFormatter.string(fromByteCount: viewModel.selectedSize, countStyle: .file))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.accent)
                    .contentTransition(.numericText())
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Label("移入废纸篓，可恢复", systemImage: "arrow.uturn.backward.circle")
                Label("受保护路径自动跳过", systemImage: "lock.shield")
            }
            .font(.system(size: 11))
            .foregroundColor(AppTheme.textMuted)
        }
        .padding(20)
        .themeCard()
    }

    // MARK: - 底部操作栏

    private var footerBar: some View {
        SelectionFooterBar(
            selectedCount: viewModel.selectedItems.count,
            selectedSize: viewModel.selectedSize,
            isCleaning: viewModel.isCleaning,
            cleanProgress: viewModel.cleanProgress,
            restoreResult: viewModel.lastRestoreResult,
            warning: viewModel.permanentSelectedSize > 0 ? String(localized: "含永久删除") : nil,
            action: { guard ProGate.allowAction() else { return }; showConfirm = true }
        )
    }
}

// MARK: - 通用底部操作栏

struct SelectionFooterBar: View {
    let selectedCount: Int
    let selectedSize: Int64
    let isCleaning: Bool
    let cleanProgress: Double
    let restoreResult: RestoreResult?
    var warning: String? = nil
    let action: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            if isCleaning {
                ProgressView(value: cleanProgress)
                    .tint(AppTheme.accent)
                    .frame(width: 180)
                Text("正在清理…")
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.textSecondary)
            } else if let restore = restoreResult {
                Label(
                    "已恢复 \(restore.restoredCount) 项 · \(ByteCountFormatter.string(fromByteCount: restore.restoredSize, countStyle: .file))",
                    systemImage: "arrow.uturn.backward.circle"
                )
                .font(.system(size: 13))
                .foregroundColor(AppTheme.textSecondary)
            } else {
                Text("已选 \(selectedCount) 项")
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.textSecondary)
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.danger)
                }
            }

            Spacer()

            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text("清理 \(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file))")
                        .monospacedDigit()
                }
            }
            .buttonStyle(NeonButtonStyle(isLarge: true))
            .disabled(selectedCount == 0 || isCleaning)
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

// MARK: - 分组卡片

struct CleanGroupCard: View {
    @Binding var group: CleanGroupState
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onSelectAll: (Bool) -> Void
    let onIgnore: (CleanableItem) -> Void

    @State private var isHovered = false

    private var selectionState: Bool? {
        let count = group.selectedCount
        if count == 0 { return false }
        if count == group.items.count { return true }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                TriStateCheckbox(state: selectionState) {
                    onSelectAll(selectionState != true)
                }
                .disabled(group.items.isEmpty)
                .opacity(group.items.isEmpty ? 0.4 : 1)

                Button(action: onToggleExpanded) {
                    HStack(spacing: 14) {
                        let palette = AppTheme.groupPalette(for: group.descriptor.id)
                        GradientIconTile(
                            systemName: group.descriptor.icon,
                            gradient: palette.gradient,
                            size: 40,
                            cornerRatio: 0.27,
                            glyphRatio: 0.42,
                            shadowColor: palette.shadow
                        )
                        .saturation(group.items.isEmpty ? 0.2 : 1)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(group.descriptor.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(AppTheme.textPrimary)
                                if !group.items.isEmpty {
                                    Text("\(group.selectedCount)/\(group.items.count)")
                                        .font(.system(size: 11, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundColor(AppTheme.textMuted)
                                }
                                if let risk = group.descriptor.riskNote {
                                    Text(risk)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(AppTheme.danger)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(AppTheme.danger.opacity(0.14)))
                                }
                            }
                            Text(group.descriptor.subtitle)
                                .font(.system(size: 12))
                                .foregroundColor(AppTheme.textMuted)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer(minLength: 12)

                        if group.isScanning {
                            ProgressView()
                                .scaleEffect(0.6)
                                .tint(AppTheme.textSecondary)
                        } else {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(ByteCountFormatter.string(fromByteCount: group.totalSize, countStyle: .file))
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(group.totalSize > 0 ? AppTheme.textPrimary : AppTheme.textMuted)
                                if group.selectedSize > 0 && group.selectedSize != group.totalSize {
                                    Text("已选 \(ByteCountFormatter.string(fromByteCount: group.selectedSize, countStyle: .file))")
                                        .font(.system(size: 11))
                                        .monospacedDigit()
                                        .foregroundColor(AppTheme.textMuted)
                                }
                            }
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppTheme.textMuted)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if isExpanded {
                Divider().overlay(AppTheme.divider)
                if group.items.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: group.isScanning ? "hourglass" : "checkmark.circle")
                            .foregroundColor(group.isScanning ? AppTheme.textMuted : AppTheme.accent)
                        (group.isScanning ? Text("正在扫描…") : Text("没有发现可清理的项目"))
                            .font(.system(size: 13))
                            .foregroundColor(AppTheme.textSecondary)
                        Spacer()
                    }
                    .padding(16)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach($group.items) { $item in
                            CleanItemRow(item: $item, onIgnore: { onIgnore(item) })
                            if item.id != group.items.last?.id {
                                Divider().overlay(AppTheme.divider).padding(.leading, 84)
                            }
                        }
                    }
                }
            }
        }
        .themeCard(isHovered: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 条目行

struct CleanItemRow: View {
    @Binding var item: CleanableItem
    let onIgnore: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $item.isSelected)
                .toggleStyle(CosmicCheckboxStyle(accentColor: AppTheme.accent))
                .labelsHidden()
                .padding(.leading, 26)

            Image(nsImage: AppLookup.icon(for: item))
                .resizable()
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(AppLookup.displayName(for: item))
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(item.description ?? SpaceLensItem.cleanPath(item.path))
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(item.path)

            Spacer()

            if isHovered {
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.path)
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("在访达中显示")
            }

            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                .font(.system(size: 12, design: .rounded))
                .monospacedDigit()
                .foregroundColor(AppTheme.textSecondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHovered ? AppTheme.surfaceHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("在访达中显示") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.path)
            }
            Button("拷贝路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
            Divider()
            Button("始终忽略此项", action: onIgnore)
        }
    }
}

// MARK: - 三态复选框

struct TriStateCheckbox: View {
    /// true 全选、false 未选、nil 部分选中
    let state: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(state == false ? AnyShapeStyle(AppTheme.surface) : AnyShapeStyle(AppTheme.brandGradient))
                    .frame(width: 17, height: 17)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(state == false ? AppTheme.ink(0.28) : Color.clear, lineWidth: 1.2)
                    )
                if let state {
                    if state {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9.5, weight: .heavy))
                            .foregroundColor(.white)
                    }
                } else {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(AppTheme.onAccent)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 应用名称/图标解析

/// ~/Library/Caches 下的目录多为 bundle id（com.tinyspeck.slackmacgap），解析为应用名与图标更易辨认。
@MainActor
enum AppLookup {
    private static var nameCache: [String: String] = [:]
    private static var iconCache: [String: NSImage] = [:]

    static func displayName(for item: CleanableItem) -> String {
        guard item.category == .userCache, looksLikeBundleID(item.name) else { return item.name }
        if let cached = nameCache[item.name] { return cached }
        var name = item.name
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.name) {
            name = FileManager.default.displayName(atPath: appURL.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        nameCache[item.name] = name
        return name
    }

    static func icon(for item: CleanableItem) -> NSImage {
        let key = item.category == .userCache && looksLikeBundleID(item.name) ? item.name : item.path
        if let cached = iconCache[key] { return cached }
        let icon: NSImage
        if key == item.name, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.name) {
            icon = NSWorkspace.shared.icon(forFile: appURL.path)
        } else {
            icon = NSWorkspace.shared.icon(forFile: item.path)
        }
        iconCache[key] = icon
        return icon
    }

    static func fileIcon(path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = icon
        return icon
    }

    private static func looksLikeBundleID(_ name: String) -> Bool {
        name.split(separator: ".").count >= 3 && !name.contains(" ")
    }
}

// MARK: - 清理记录

struct CleanupHistoryView: View {
    var onRestored: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [CleanupSession] = []
    @State private var ignoredPaths: [String] = []
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("清理记录")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                    Text("只要还没清空废纸篓，就可以把整次清理原样放回原位置。")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                }
                Spacer()
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

            Divider().overlay(AppTheme.divider)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let message {
                        Label(message, systemImage: "checkmark.circle")
                            .font(.system(size: 13))
                            .foregroundColor(AppTheme.accent)
                    }

                    if sessions.isEmpty {
                        Text("还没有清理记录")
                            .font(.system(size: 13))
                            .foregroundColor(AppTheme.textSecondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(sessions) { session in
                                sessionRow(session)
                                if session.id != sessions.last?.id {
                                    Divider().overlay(AppTheme.divider)
                                }
                            }
                        }
                        .themeCard()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("始终忽略")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(AppTheme.textPrimary)
                        Text("在任意条目上右键选择「始终忽略此项」即可加入，扫描时不再列出。")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.textMuted)
                        if ignoredPaths.isEmpty {
                            Text("暂无")
                                .font(.system(size: 13))
                                .foregroundColor(AppTheme.textSecondary)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(ignoredPaths, id: \.self) { path in
                                    HStack {
                                        Text(SpaceLensItem.cleanPath(path))
                                            .font(.system(size: 12))
                                            .foregroundColor(AppTheme.textSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        Button("移除") {
                                            IgnoreList.remove(path)
                                            ignoredPaths = IgnoreList.paths()
                                        }
                                        .buttonStyle(NeonOutlineButtonStyle())
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                }
                            }
                            .themeCard()
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(AppTheme.primaryGradient)
        .onAppear(perform: reload)
    }

    private func sessionRow(_ session: CleanupSession) -> some View {
        let restorable = session.restorableEntries
        let restorableSize = restorable.reduce(Int64(0)) { $0 + $1.size }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppTheme.textPrimary)
                Text(statusText(session: session, restorableCount: restorable.count, restorableSize: restorableSize))
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: session.totalSize, countStyle: .file))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(AppTheme.textSecondary)
            Button("恢复") {
                let result = CleanupHistoryStore.shared.restore(sessionID: session.id)
                message = result.failedPaths.isEmpty
                    ? String(localized: "已恢复 \(result.restoredCount) 项")
                    : String(localized: "已恢复 \(result.restoredCount) 项，\(result.failedPaths.count) 项失败")
                reload()
                onRestored()
            }
            .buttonStyle(NeonOutlineButtonStyle())
            .disabled(restorable.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func statusText(session: CleanupSession, restorableCount: Int, restorableSize: Int64) -> String {
        let count = session.entries.count
        if restorableCount == 0 {
            return session.restoredAt != nil
                ? String(localized: "\(count) 项 · 已恢复")
                : String(localized: "\(count) 项 · 已不在废纸篓中")
        }
        return String(localized: "\(count) 项 · 可恢复 \(restorableCount) 项（\(ByteCountFormatter.string(fromByteCount: restorableSize, countStyle: .file))）")
    }

    private func reload() {
        sessions = CleanupHistoryStore.shared.sessions()
        ignoredPaths = IgnoreList.paths()
    }
}
