//
//  PrivacyCleanupView.swift
//  MacClean
//
//  隐私清理：按浏览器分组列出历史、Cookie、下载记录等，用户自行勾选后移入废纸篓（可撤销）。
//  浏览器运行时禁止清理它的数据库；Safari 数据需要完全磁盘访问权限。
//

import SwiftUI

struct PrivacyCleanupView: View {
    @ObservedObject private var viewModel = PrivacyViewModel.shared

    @State private var expanded: Set<PrivacyBrowser> = Set(PrivacyBrowser.allCases)
    @State private var showConfirm = false
    @State private var showCompletion = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "隐私清理"), subtitle: String(localized: "清除浏览器与系统留下的使用痕迹，书签和保存的密码不会被触碰")) {
                HStack(spacing: 8) {
                    LastScannedLabel(date: viewModel.lastScannedAt)
                    ScanButton(hasScanned: viewModel.hasScanned, isScanning: viewModel.isScanning) {
                        viewModel.scan()
                    }
                    .disabled(viewModel.isCleaning)
                }
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if !viewModel.hasScanned && !viewModel.isScanning {
                        ScanIntroView(
                            icon: "hand.raised.fill",
                            title: String(localized: "扫描隐私痕迹"),
                            message: String(localized: "查找 Safari、Chrome、Edge、Brave、Firefox 的浏览历史、Cookie、下载记录与会话，以及系统的「最近使用的项目」。"),
                            points: [
                                String(localized: "默认不勾选任何项目，由你决定清除什么"),
                                String(localized: "从不触碰书签与保存的密码"),
                                String(localized: "浏览器运行时自动锁定，避免损坏数据库"),
                                String(localized: "移入废纸篓，可一键撤销"),
                            ],
                            action: { viewModel.scan() }
                        )
                    } else if viewModel.isScanning && !viewModel.hasScanned {
                        scanningCard
                    } else {
                        if viewModel.result.safariNeedsFullDiskAccess {
                            fullDiskAccessBanner
                        }
                        if viewModel.browsers.isEmpty {
                            emptyCard
                        }
                        ForEach(viewModel.browsers) { browser in
                            PrivacyBrowserCard(
                                browser: browser,
                                viewModel: viewModel,
                                isExpanded: expanded.contains(browser),
                                onToggleExpanded: { toggle(browser) }
                            )
                        }
                    }
                }
                .padding(.horizontal, CosmicSizes.pagePadding)
                .padding(.vertical, 24)
            }

            if viewModel.hasScanned {
                SelectionFooterBar(
                    selectedCount: viewModel.selectedEntries.count,
                    selectedSize: viewModel.selectedSize,
                    isCleaning: viewModel.isCleaning,
                    cleanProgress: viewModel.cleanProgress,
                    restoreResult: viewModel.lastRestoreResult,
                    warning: viewModel.selectedEntries.contains { $0.kind == .cookies } ? String(localized: "将退出网站登录") : nil,
                    action: {

                        showConfirm = true
                    }
                )
            }
        }
        .alert("确认清除隐私数据", isPresented: $showConfirm) {
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
        .onAppear { viewModel.refreshRunningBrowsers() }
    }

    private func toggle(_ browser: PrivacyBrowser) {
        withAnimation(CosmicAnimations.smooth) {
            if expanded.contains(browser) {
                expanded.remove(browser)
            } else {
                expanded.insert(browser)
            }
        }
    }

    private var confirmMessage: String {
        let entries = viewModel.selectedEntries
        var lines = entries.map { entry in
            var line = String(localized: "· \(entry.browser.displayName)：\(entry.kind.title)")
            if let profile = entry.profileName, viewModel.entries(for: entry.browser).contains(where: { $0.profileDirectory != entry.profileDirectory }) {
                line += String(localized: "（\(profile)）")
            }
            return line
        }
        var warnings: [String] = []
        if entries.contains(where: { $0.kind == .cookies }) {
            warnings.append(String(localized: "清除 Cookie 会退出所有网站的登录。"))
        }
        if entries.contains(where: { $0.kind == .autofill }) {
            warnings.append(String(localized: "自动填充数据包含保存的地址和银行卡信息，清除后需重新填写。"))
        }
        if entries.contains(where: { $0.kind == .sessions }) {
            warnings.append(String(localized: "清除会话后，浏览器将无法恢复上次打开的标签页。"))
        }
        if !warnings.isEmpty {
            lines.append("")
            lines += warnings
        }
        lines.append("")
        lines.append(String(localized: "文件将移入废纸篓，可在完成页撤销。"))
        return lines.joined(separator: "\n")
    }

    // MARK: - 辅助卡片

    private var scanningCard: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.7).tint(AppTheme.textSecondary)
            Text("正在扫描…")
                .font(.system(size: 13))
                .foregroundColor(AppTheme.textSecondary)
            Spacer()
        }
        .padding(20)
        .themeCard()
    }

    private var emptyCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundColor(AppTheme.accent)
            Text("没有发现可清理的隐私痕迹")
                .font(.system(size: 13))
                .foregroundColor(AppTheme.textSecondary)
            Spacer()
        }
        .padding(20)
        .themeCard()
    }

    private var fullDiskAccessBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppTheme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("需要「完全磁盘访问权限」才能读取 Safari 数据")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text("在「系统设置 › 隐私与安全性 › 完全磁盘访问权限」中打开 MacClean，然后重新扫描。")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
            }
            Spacer()
            Button("打开系统设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(NeonOutlineButtonStyle())
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: CosmicSizes.cardRadius, style: .continuous)
                .fill(AppTheme.warning.opacity(0.08))
        )
        .themeCard()
    }
}

// MARK: - 浏览器分组卡片

private struct PrivacyBrowserCard: View {
    let browser: PrivacyBrowser
    @ObservedObject var viewModel: PrivacyViewModel
    let isExpanded: Bool
    let onToggleExpanded: () -> Void

    @State private var isHovered = false

    private var entries: [PrivacyEntry] { viewModel.entries(for: browser) }
    private var isRunning: Bool { viewModel.runningBrowsers.contains(browser) }
    private var showsProfile: Bool { Set(entries.map(\.profileDirectory)).count > 1 }

    private var selectionState: Bool? {
        let count = entries.filter { viewModel.isSelected($0) }.count
        if count == 0 { return false }
        if count == entries.count { return true }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                TriStateCheckbox(state: selectionState) {
                    viewModel.setSelection(browser: browser, selected: selectionState != true)
                }
                .disabled(entries.isEmpty || isRunning)
                .opacity(entries.isEmpty || isRunning ? 0.4 : 1)

                Button(action: onToggleExpanded) {
                    HStack(spacing: 14) {
                        browserIcon

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(browser.displayName)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(AppTheme.textPrimary)
                                if !entries.isEmpty {
                                    Text("\(entries.filter { viewModel.isSelected($0) }.count)/\(entries.count)")
                                        .font(.system(size: 11, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundColor(AppTheme.textMuted)
                                }
                            }
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundColor(isRunning ? AppTheme.warning : AppTheme.textMuted)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 12)

                        Text(ByteCountFormatter.string(fromByteCount: entries.reduce(0) { $0 + $1.size }, countStyle: .file))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(AppTheme.textPrimary)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppTheme.textMuted)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isRunning {
                    Button("退出") { viewModel.quit(browser) }
                        .buttonStyle(NeonOutlineButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if isExpanded {
                Divider().overlay(AppTheme.divider)
                VStack(spacing: 0) {
                    if entries.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .foregroundColor(AppTheme.accent)
                            Text("没有发现可清理的项目")
                                .font(.system(size: 13))
                                .foregroundColor(AppTheme.textSecondary)
                            Spacer()
                        }
                        .padding(16)
                    }
                    ForEach(entries) { entry in
                        PrivacyEntryRow(
                            entry: entry,
                            profileLabel: showsProfile ? entry.profileName : nil,
                            isSelected: Binding(
                                get: { viewModel.isSelected(entry) },
                                set: { viewModel.setSelected(entry, $0) }
                            ),
                            isLocked: isRunning
                        )
                        if entry.id != entries.last?.id {
                            Divider().overlay(AppTheme.divider).padding(.leading, 84)
                        }
                    }
                    if browser == .firefox {
                        noteRow(String(localized: "Firefox 的浏览历史与书签存放在同一个数据库中，为保护书签不在此清除。请在 Firefox「设置 › 隐私与安全」中清除历史记录。"))
                    }
                }
            }
        }
        .themeCard(isHovered: isHovered)
        .onHover { isHovered = $0 }
    }

    private var subtitle: String {
        if isRunning { return String(localized: "请先退出 \(browser.displayName)，正在运行时无法安全清除") }
        if entries.isEmpty { return String(localized: "没有可清理的项目") }
        return entries.map(\.kind).uniqued().map(\.shortTitle).joined(separator: " · ")
    }

    @ViewBuilder
    private var browserIcon: some View {
        if let bundleID = browser.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 40, height: 40)
                .saturation(isRunning ? 0.3 : 1)
        } else {
            let palette = AppTheme.groupPalette(for: browser.rawValue)
            GradientIconTile(
                systemName: browser == .system ? "desktopcomputer" : "globe",
                gradient: palette.gradient,
                size: 40,
                cornerRatio: 0.27,
                glyphRatio: 0.42,
                shadowColor: palette.shadow
            )
        }
    }

    private func noteRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textMuted)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(AppTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppTheme.ink(0.025))
    }
}

// MARK: - 条目行

private struct PrivacyEntryRow: View {
    let entry: PrivacyEntry
    let profileLabel: String?
    @Binding var isSelected: Bool
    let isLocked: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(CosmicCheckboxStyle(accentColor: AppTheme.accent))
                .labelsHidden()
                .padding(.leading, 26)
                .disabled(isLocked)

            Image(systemName: entry.kind.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppTheme.textSecondary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.kind.title)
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.textPrimary)
                    if let profileLabel {
                        Text(profileLabel)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(AppTheme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(AppTheme.ink(0.06)))
                    }
                }
                Text(entry.kind.detail)
                    .font(.system(size: 11))
                    .foregroundColor(entry.kind.isRisky ? AppTheme.warning : AppTheme.textMuted)
                    .lineLimit(1)
            }
            .help(entry.paths.joined(separator: "\n"))

            Spacer()

            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                .font(.system(size: 12, design: .rounded))
                .monospacedDigit()
                .foregroundColor(AppTheme.textSecondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .opacity(isLocked ? 0.5 : 1)
        .background(isHovered && !isLocked ? AppTheme.surfaceHover : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { if !isLocked { isSelected.toggle() } }
        .onHover { isHovered = $0 }
        .contextMenu {
            if let first = entry.paths.first {
                Button("在访达中显示") {
                    NSWorkspace.shared.selectFile(first, inFileViewerRootedAtPath: "")
                }
            }
        }
    }
}

// MARK: - 小工具

private extension PrivacyKind {
    /// 分组副标题里用的短名称。
    var shortTitle: String {
        switch self {
        case .autofill: return String(localized: "自动填充")
        case .sessions: return String(localized: "会话")
        default: return title
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
