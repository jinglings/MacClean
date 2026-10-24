//
//  LoginItemsView.swift
//  MacClean
//
//  启动项：列出登录时打开的应用、用户 / 系统级启动代理与守护进程；
//  当前用户的启动代理可停用 / 启用，程序已不存在的失效项可移入废纸篓（可撤销）。
//  系统级（/Library）条目只读，修改需要管理员权限。
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class LoginItemsViewModel: ObservableObject {
    /// 页面视图会随侧栏切换销毁重建，结果常驻在这里
    static let shared = LoginItemsViewModel()

    struct Banner: Equatable {
        enum Style { case error, success }
        let style: Style
        let message: String
        /// 有值时横幅显示「撤销」
        var undoSessionID: UUID? = nil
    }

    @Published private(set) var items: [LaunchItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var lastScannedAt: Date?
    /// 正在启用 / 停用 / 移除的条目
    @Published private(set) var busyIDs: Set<String> = []
    @Published var banner: Banner?

    private var scanTask: Task<Void, Never>?

    var brokenItems: [LaunchItem] { items.filter { $0.isBroken } }
    var loginApps: [LaunchItem] { items.filter { $0.kind == .loginApp || $0.kind == .appService } }
    var userAgents: [LaunchItem] { items.filter { $0.kind == .userAgent && !$0.isBroken } }
    var systemItems: [LaunchItem] {
        items.filter { ($0.kind == .globalAgent || $0.kind == .globalDaemon) && !$0.isBroken }
    }
    var removableBroken: [LaunchItem] { brokenItems.filter(\.isEditable) }
    var activeCount: Int { items.filter { !$0.isDisabled && !$0.isBroken }.count }

    // MARK: - 扫描

    func scan() {
        scanTask?.cancel()
        isScanning = true
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let found = LoginItemsScanner.scan()
            let cancelled = Task.isCancelled
            await self?.finishScan(found, cancelled: cancelled)
        }
    }

    private func finishScan(_ found: [LaunchItem], cancelled: Bool) {
        guard !cancelled else { return }
        items = found.sorted { lhs, rhs in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        isScanning = false
        hasScanned = true
        lastScannedAt = Date()
        UsageAnalytics.shared.recordScanCompleted()
    }

    // MARK: - 启用 / 停用

    func setEnabled(_ enabled: Bool, for item: LaunchItem) {
        guard item.isEditable, let plistPath = item.plistPath, !busyIDs.contains(item.id) else { return }

        busyIDs.insert(item.id)
        banner = nil
        let label = item.label
        Task.detached(priority: .userInitiated) { [weak self] in
            let failure = enabled
                ? LaunchCtl.enableUserAgent(label: label, plistPath: plistPath)
                : LaunchCtl.disableUserAgent(label: label, plistPath: plistPath)
            await self?.finishChange(itemID: item.id, failure: failure)
        }
    }

    private func finishChange(itemID: String, failure: String?) {
        busyIDs.remove(itemID)
        if let failure {
            banner = Banner(style: .error, message: failure)
        }
        scan()
    }

    // MARK: - 移除失效项

    /// 调用方先展示操作确认，清理仍经过路径与权限检查。
    func remove(_ targets: [LaunchItem]) async {
        let targets = targets.filter { $0.isEditable && $0.isBroken && $0.plistPath != nil }
        guard !targets.isEmpty else { return }
        busyIDs.formUnion(targets.map(\.id))
        banner = nil

        let paths = targets.compactMap(\.plistPath)
        await Task.detached(priority: .userInitiated) {
            for path in paths { LaunchCtl.bootoutUserAgent(plistPath: path) }
        }.value

        let cleanables = targets.map { item -> CleanableItem in
            var cleanable = CleanableItem(
                name: (item.plistPath! as NSString).lastPathComponent,
                path: item.plistPath!,
                size: 0,
                category: .brokenLoginItems,
                isSelected: true,
                description: item.executablePath.map { String(localized: "指向不存在的程序: \($0)") },
                lastModified: nil
            )
            cleanable.removesContainer = true
            return cleanable
        }

        do {
            let result = try await CleanupManager.shared.clean(items: cleanables)
            if result.errors.isEmpty {
                banner = Banner(style: .success, message: String(localized: "已将 \(result.cleanedItems) 个失效项移入废纸篓"), undoSessionID: result.historySessionID)
            } else {
                let detail = result.errors.first?.message ?? ""
                banner = Banner(style: .error, message: String(localized: "有 \(result.errors.count) 个失效项未能移除：\(detail)"), undoSessionID: result.historySessionID)
            }
        } catch {
            banner = Banner(style: .error, message: String(localized: "移除失败：\(error.localizedDescription)"))
        }
        busyIDs.subtract(targets.map(\.id))
        scan()
    }

    func undo(sessionID: UUID) async {
        let result = await CleanupManager.shared.restore(sessionID: sessionID)
        banner = result.failedPaths.isEmpty
            ? Banner(style: .success, message: String(localized: "已恢复 \(result.restoredCount) 个启动项，下次登录时生效"))
            : Banner(style: .error, message: String(localized: "有 \(result.failedPaths.count) 个项目未能恢复，可能已从废纸篓清空"))
        scan()
    }
}

// MARK: - 页面

struct LoginItemsView: View {
    @ObservedObject private var viewModel = LoginItemsViewModel.shared

    @State private var pendingRemoval: [LaunchItem] = []

    private static let loginItemsSettingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "启动项"), subtitle: String(localized: "开机或登录后在后台自动运行的程序；关掉不需要的，开机更快、更安静")) {
                HStack(spacing: 8) {
                    LastScannedLabel(date: viewModel.lastScannedAt)
                    ScanButton(hasScanned: viewModel.hasScanned, isScanning: viewModel.isScanning) { viewModel.scan() }
                }
            }

            if !viewModel.hasScanned {
                ScrollView {
                    ScanIntroView(
                        icon: "power.circle",
                        title: String(localized: "检查启动项"),
                        message: String(localized: "找出开机和登录时自动运行的应用、启动代理与守护进程，标出卸载后残留的失效项。"),
                        points: [String(localized: "登录时自动打开的应用"), String(localized: "后台常驻的启动代理"), String(localized: "已卸载应用留下的失效项"), String(localized: "关闭后可随时重新开启")],
                        buttonTitle: viewModel.isScanning ? String(localized: "正在检查…") : String(localized: "开始检查"),
                        footnote: String(localized: "检查只读取配置，不会改动任何启动项"),
                        action: { viewModel.scan() }
                    )
                    .disabled(viewModel.isScanning)
                    .padding(.horizontal, CosmicSizes.pagePadding)
                    .padding(.top, 24)
                }
            } else {
                content
            }
        }
        .alert("移除失效启动项？", isPresented: Binding(
            get: { !pendingRemoval.isEmpty },
            set: { if !$0 { pendingRemoval = [] } }
        )) {
            Button("取消", role: .cancel) { pendingRemoval = [] }
            Button("移入废纸篓", role: .destructive) {
                let targets = pendingRemoval
                pendingRemoval = []
                Task { await viewModel.remove(targets) }
            }
        } message: {
            if pendingRemoval.count == 1, let item = pendingRemoval.first {
                Text("「\(item.displayName)」指向的程序已不存在。它的配置文件将移入废纸篓，可随时撤销。")
            } else {
                Text("\(pendingRemoval.count) 个失效启动项的配置文件将移入废纸篓，可随时撤销。")
            }
        }
    }

    private func confirmRemoval(_ items: [LaunchItem]) {
        guard !items.isEmpty else { return }
        pendingRemoval = items
    }

    // MARK: - 结果

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let banner = viewModel.banner {
                    BannerView(banner: banner, onUndo: { id in
                        Task { await viewModel.undo(sessionID: id) }
                    }, onClose: { viewModel.banner = nil })
                }

                summary

                if !viewModel.brokenItems.isEmpty {
                    section(
                        title: "失效项（程序已不存在）",
                        note: "应用卸载后留下的配置，每次登录都会尝试启动并失败，可以放心移除",
                        tint: AppTheme.warning,
                        items: viewModel.brokenItems
                    ) {
                        if viewModel.removableBroken.count > 1 {
                            Button("全部移除") { confirmRemoval(viewModel.removableBroken) }
                                .buttonStyle(NeonOutlineButtonStyle())
                        }
                    }
                }

                if !viewModel.loginApps.isEmpty {
                    section(
                        title: "登录时打开的应用",
                        note: "由应用自行注册，在「系统设置 → 通用 → 登录项与扩展」中开关",
                        tint: nil,
                        items: viewModel.loginApps
                    ) {
                        Button {
                            NSWorkspace.shared.open(Self.loginItemsSettingsURL)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 12, weight: .medium))
                                Text("在系统设置中管理")
                            }
                        }
                        .buttonStyle(NeonOutlineButtonStyle())
                    }
                }

                section(
                    title: "当前用户的启动代理",
                    note: "位于 ~/Library/LaunchAgents，关闭后不再自动运行，随时可以重新开启",
                    tint: nil,
                    items: viewModel.userAgents
                ) { EmptyView() }

                section(
                    title: "系统级启动代理与守护进程（只读，需管理员权限修改）",
                    note: "位于 /Library/LaunchAgents 与 /Library/LaunchDaemons，对所有用户生效；如需关闭，请在应用自身设置或「登录项与扩展」中操作",
                    tint: nil,
                    items: viewModel.systemItems
                ) { EmptyView() }
            }
            .padding(.horizontal, CosmicSizes.pagePadding)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            StatTile(value: viewModel.items.count, title: "启动项", tint: AppTheme.textPrimary)
            StatTile(value: viewModel.activeCount, title: "自动运行中", tint: AppTheme.accent)
            StatTile(value: viewModel.brokenItems.count, title: "失效项", tint: viewModel.brokenItems.isEmpty ? AppTheme.textPrimary : AppTheme.warning)
        }
    }

    private func section<Actions: View>(
        title: LocalizedStringKey,
        note: LocalizedStringKey,
        tint: Color?,
        items: [LaunchItem],
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if tint != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13))
                        }
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                        Text("\(items.count)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(AppTheme.textMuted)
                    }
                    .foregroundColor(tint ?? AppTheme.textPrimary)
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                actions()
            }

            if items.isEmpty {
                Text("没有条目")
                    .font(.system(size: 12.5))
                    .foregroundColor(AppTheme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .themeCard()
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider().overlay(AppTheme.divider).padding(.leading, 60)
                        }
                        LaunchItemRow(
                            item: item,
                            isBusy: viewModel.busyIDs.contains(item.id),
                            onToggle: { viewModel.setEnabled($0, for: item) },
                            onRemove: { confirmRemoval([item]) },
                            onOpenSettings: { NSWorkspace.shared.open(Self.loginItemsSettingsURL) }
                        )
                    }
                }
                .themeCard()
            }
        }
    }
}

// MARK: - 统计块

private struct StatTile: View {
    let value: Int
    let title: LocalizedStringKey
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(tint)
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }
}

// MARK: - 横幅

private struct BannerView: View {
    let banner: LoginItemsViewModel.Banner
    let onUndo: (UUID) -> Void
    let onClose: () -> Void

    private var tint: Color { banner.style == .error ? AppTheme.danger : AppTheme.accent }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.style == .error ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(tint)
            Text(banner.message)
                .font(.system(size: 12.5))
                .foregroundColor(AppTheme.textPrimary)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let sessionID = banner.undoSessionID {
                Button("撤销") { onUndo(sessionID) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(AppTheme.accent)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AppTheme.textMuted)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(tint.opacity(0.25), lineWidth: 1)
                )
        )
    }
}

// MARK: - 条目行

private struct LaunchItemRow: View {
    let item: LaunchItem
    let isBusy: Bool
    let onToggle: (Bool) -> Void
    let onRemove: () -> Void
    let onOpenSettings: () -> Void

    @State private var isHovered = false

    private var shortPath: String? {
        guard let path = item.detailPath else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private var isEnabled: Bool { !item.isDisabled }

    var body: some View {
        HStack(spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isEnabled || item.isBroken ? AppTheme.textPrimary : AppTheme.textSecondary)
                        .lineLimit(1)
                    badges
                }
                Text(item.label)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let shortPath {
                    Text(shortPath)
                        .font(.system(size: 11))
                        .foregroundColor(item.isBroken ? AppTheme.warning : AppTheme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .help(helpText)

            Spacer(minLength: 16)

            if isHovered, let path = item.revealPath {
                Button {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("在 Finder 中显示")
            }

            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isHovered ? AppTheme.surfaceHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            if let path = item.revealPath {
                Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
            }
            if let path = item.detailPath {
                Button("拷贝路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
            Button("拷贝标识") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.label, forType: .string)
            }
            if item.kind == .loginApp || item.kind == .appService {
                Divider()
                Button("在系统设置中管理", action: onOpenSettings)
            }
        }
    }

    private var helpText: String {
        var lines = [item.label]
        if let plist = item.plistPath { lines.append(String(localized: "配置：\(plist)")) }
        if let executable = item.executablePath { lines.append(String(localized: "程序：\(executable)")) }
        if let developer = item.developer { lines.append(String(localized: "开发者：\(developer)")) }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private var icon: some View {
        if let appPath = item.appPath {
            Image(nsImage: AppLookup.fileIcon(path: appPath))
                .resizable()
                .frame(width: 32, height: 32)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.ink(0.06))
                .overlay(
                    Image(systemName: item.kind == .globalDaemon ? "gearshape.2" : "gearshape")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(AppTheme.textSecondary)
                )
                .frame(width: 32, height: 32)
        }
    }

    @ViewBuilder
    private var badges: some View {
        if item.isBroken {
            Badge(title: "程序不存在", tint: AppTheme.warning)
        }
        if item.isRunning {
            Badge(title: "运行中", tint: AppTheme.accent)
        }
        if item.kind == .loginApp {
            Badge(title: "登录时打开", tint: AppTheme.textSecondary)
        } else if item.kind == .appService {
            Badge(title: "应用后台服务", tint: AppTheme.textSecondary)
        } else {
            if item.runAtLoad { Badge(title: "开机运行", tint: AppTheme.textSecondary) }
            if item.keepAlive { Badge(title: "常驻", tint: AppTheme.textSecondary) }
        }
        if item.isBlockedInSettings {
            Badge(title: "系统设置中已关闭", tint: AppTheme.textMuted)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 10) {
            if isBusy {
                ProgressView().scaleEffect(0.55).frame(width: 20, height: 20)
            }
            if item.isEditable && item.isBroken {
                Button("移除", action: onRemove)
                    .buttonStyle(NeonOutlineButtonStyle())
                    .disabled(isBusy)
            }
            if item.isEditable {
                Toggle("", isOn: Binding(get: { isEnabled }, set: { onToggle($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(AppTheme.accent)
                    .disabled(isBusy)
                    .help(isEnabled ? Text("停用后不再自动运行") : Text("重新开启"))
            } else if item.kind == .loginApp || item.kind == .appService {
                (isEnabled ? Text("已开启") : Text("已关闭"))
                    .font(.system(size: 11.5))
                    .foregroundColor(isEnabled ? AppTheme.accent : AppTheme.textMuted)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                    (isEnabled ? Text("已启用") : Text("已停用"))
                        .font(.system(size: 11.5))
                }
                .foregroundColor(AppTheme.textMuted)
                .help("系统级项目对所有用户生效，修改需要管理员权限，这里只读显示")
            }
        }
    }
}

private struct Badge: View {
    let title: LocalizedStringKey
    let tint: Color

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(tint)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Capsule().fill(tint.opacity(0.12)))
            .fixedSize()
    }
}
