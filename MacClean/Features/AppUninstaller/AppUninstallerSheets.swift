//
//  AppUninstallerSheets.swift
//  MacClean
//
//  应用管家的详情 Sheet：管理应用 / 未使用应用 / 残留文件 / 安装包 / 可用更新。
//  每个会删除东西的 Sheet 自己持有确认弹窗；确认后先关 Sheet，再由主页面显示进度与完成页。
//

import SwiftUI
import AppKit

// MARK: - 共用组件

private struct SheetHeader: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                }
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(AppTheme.textMuted)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }
}

private struct SheetFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) { content }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .background(AppTheme.surface)
    }
}

private struct EmptySheetState: View {
    let icon: String
    let title: LocalizedStringKey

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(AppTheme.accent)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(AppTheme.textPrimary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private func formatSize(_ size: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
}

private func checkbox(_ isOn: Binding<Bool>) -> some View {
    Toggle("", isOn: isOn)
        .toggleStyle(CosmicCheckboxStyle(accentColor: AppTheme.accent))
        .labelsHidden()
}

private func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

private let shortDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
}()

// MARK: - 应用管理 Sheet
struct AppManagerSheet: View {
    @ObservedObject var viewModel: AppUninstallerViewModel
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""
    @State private var selectedID: AppInfo.ID?
    @State private var confirm: AppManagerConfirm?

    private var filteredApps: [AppInfo] {
        guard let apps = viewModel.scanResult?.apps else { return [] }
        guard !searchText.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) || $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "管理应用程序", subtitle: "选择应用查看占用与关联文件；卸载会把应用连同勾选的关联文件移入废纸篓") { dismiss() }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(AppTheme.textMuted)
                TextField("搜索应用…", text: $searchText)
                    .textFieldStyle(.plain)
                    .foregroundColor(AppTheme.textPrimary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(AppTheme.ink(0.05)))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            HStack(spacing: 0) {
                List(filteredApps, selection: $selectedID) { app in
                    AppListRow(app: app)
                        .tag(app.id)
                }
                .listStyle(.sidebar)
                .frame(width: 320)

                Divider()

                if let id = selectedID, let app = viewModel.app(withID: id) {
                    AppDetailView(
                        app: app,
                        refusal: viewModel.refusalReason(for: app),
                        isRunning: viewModel.isRunning(app),
                        onToggle: { viewModel.toggleRelated(appID: app.id, fileID: $0) },
                        onUninstall: { confirm = viewModel.uninstallRequest(for: [app], dismiss: { dismiss() }) }
                    )
                } else {
                    EmptySheetState(icon: "square.grid.2x2", title: "选择一个应用查看详情")
                }
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        .appManagerConfirm($confirm)
    }
}

// MARK: - 应用列表行
struct AppListRow: View {
    let app: AppInfo

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(path: app.path, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: app.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(verbatim: formatSize(app.totalSize))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textMuted)
            }

            Spacer()

            if app.isFromAppStore {
                Image(systemName: "bag")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .help("来自 App Store")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - 应用详情视图
struct AppDetailView: View {
    let app: AppInfo
    let refusal: String?
    let isRunning: Bool
    let onToggle: (RelatedFile.ID) -> Void
    let onUninstall: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 16) {
                        AppIconView(path: app.path, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: app.name)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(AppTheme.textPrimary)
                            Text("版本 \(app.version) · \(app.bundleIdentifier)")
                                .font(.system(size: 12))
                                .foregroundColor(AppTheme.textSecondary)
                                .textSelection(.enabled)
                            if let lastUsed = app.lastUsedDate {
                                Text("上次打开：\(lastUsed, formatter: shortDate)")
                                    .font(.system(size: 12))
                                    .foregroundColor(AppTheme.textMuted)
                            } else {
                                Text("上次打开：没有使用记录")
                                    .font(.system(size: 12))
                                    .foregroundColor(AppTheme.textMuted)
                            }
                        }
                        Spacer()
                        Button(action: { revealInFinder(app.path) }) {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(NeonOutlineButtonStyle())
                        .help("在访达中显示")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("存储空间")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(AppTheme.textPrimary)

                        HStack {
                            Image(systemName: "app.fill")
                                .foregroundColor(AppTheme.textMuted)
                                .frame(width: 18)
                            Text("应用本体")
                                .foregroundColor(AppTheme.textPrimary)
                            Spacer()
                            Text(verbatim: formatSize(app.size))
                                .monospacedDigit()
                                .foregroundColor(AppTheme.textSecondary)
                        }
                        .font(.system(size: 13))

                        if app.relatedFiles.isEmpty {
                            Text("没有在资源库中找到它的关联文件")
                                .font(.system(size: 12))
                                .foregroundColor(AppTheme.textMuted)
                        } else {
                            Text("关联文件（勾选的会随应用一起移入废纸篓）")
                                .font(.system(size: 12))
                                .foregroundColor(AppTheme.textMuted)
                                .padding(.top, 4)
                            ForEach(app.relatedFiles) { file in
                                HStack(alignment: .top, spacing: 10) {
                                    checkbox(Binding(get: { file.isSelected }, set: { _ in onToggle(file.id) }))
                                        .disabled(refusal != nil)
                                    Image(systemName: file.type.icon)
                                        .foregroundColor(AppTheme.textMuted)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(LocalizedStringKey(file.type.rawValue))
                                            .font(.system(size: 13))
                                            .foregroundColor(AppTheme.textPrimary)
                                        Text(verbatim: AppUninstallerViewModel.abbreviate(file.path))
                                            .font(.system(size: 11))
                                            .foregroundColor(AppTheme.textMuted)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .help(file.path)
                                    }
                                    Spacer()
                                    Text(verbatim: formatSize(file.size))
                                        .font(.system(size: 13))
                                        .monospacedDigit()
                                        .foregroundColor(AppTheme.textSecondary)
                                }
                            }
                        }

                        Divider().padding(.vertical, 4)

                        HStack {
                            Text("卸载可释放")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(AppTheme.textPrimary)
                            Spacer()
                            Text(verbatim: formatSize(app.totalSize))
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(AppTheme.danger)
                        }
                    }
                    .padding(16)
                    .themeCard()
                }
                .padding(20)
            }

            SheetFooter {
                if let refusal {
                    Image(systemName: "lock.fill")
                        .foregroundColor(AppTheme.textMuted)
                    Text(verbatim: refusal)
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                } else if isRunning {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundColor(AppTheme.warning)
                    Text("正在运行，卸载时会先退出它")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textSecondary)
                }
                Spacer()
                Button(action: onUninstall) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("卸载")
                    }
                }
                .buttonStyle(NeonButtonStyle(gradient: AppTheme.dangerGradient))
                .disabled(refusal != nil)
                .opacity(refusal != nil ? 0.5 : 1)
            }
        }
        .frame(minWidth: 460)
    }
}

// MARK: - 未使用应用 Sheet
struct UnusedAppsSheet: View {
    @ObservedObject var viewModel: AppUninstallerViewModel
    @Environment(\.dismiss) var dismiss
    @State private var selected: Set<AppInfo.ID> = []
    @State private var confirm: AppManagerConfirm?

    private var unusedApps: [AppInfo] { viewModel.scanResult?.unusedApps ?? [] }
    private var unknownApps: [AppInfo] { viewModel.scanResult?.unknownUsageApps ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "近期未使用的应用", subtitle: "根据 Spotlight 记录的上次打开时间；系统自带应用不在此列") { dismiss() }

            if unusedApps.isEmpty && unknownApps.isEmpty {
                EmptySheetState(icon: "checkmark.circle.fill", title: "所有应用最近都打开过")
            } else {
                List {
                    Section {
                        if unusedApps.isEmpty {
                            Text("没有超过 30 天未打开的应用")
                                .font(.system(size: 12))
                                .foregroundColor(AppTheme.textMuted)
                        }
                        ForEach(unusedApps) { app in row(app) }
                    } header: {
                        Text("超过 30 天未打开（\(unusedApps.count)）")
                    }

                    if !unknownApps.isEmpty {
                        Section {
                            ForEach(unknownApps) { app in row(app) }
                        } header: {
                            Text("没有使用记录（\(unknownApps.count)）")
                        } footer: {
                            Text("Spotlight 没有这些应用的打开记录：可能从未打开过，也可能是索引缺失。请自行判断是否还需要。")
                                .font(.system(size: 11))
                                .foregroundColor(AppTheme.textMuted)
                        }
                    }
                }
            }

            SheetFooter {
                let apps = (unusedApps + unknownApps).filter { selected.contains($0.id) }
                Text("已选择 \(apps.count) 个应用，共 \(formatSize(apps.reduce(0) { $0 + $1.totalSize }))")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textSecondary)
                Spacer()
                Button("卸载选中的应用") {
                    confirm = viewModel.uninstallRequest(for: apps, dismiss: { dismiss() })
                }
                .buttonStyle(NeonButtonStyle(gradient: AppTheme.dangerGradient))
                .disabled(apps.isEmpty)
                .opacity(apps.isEmpty ? 0.5 : 1)
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .appManagerConfirm($confirm)
    }

    private func row(_ app: AppInfo) -> some View {
        HStack(spacing: 12) {
            checkbox(Binding(
                get: { selected.contains(app.id) },
                set: { if $0 { selected.insert(app.id) } else { selected.remove(app.id) } }
            ))
            AppIconView(path: app.path, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: app.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                if let lastUsed = app.lastUsedDate {
                    Text("上次打开：\(lastUsed, formatter: shortDate)")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.textMuted)
                } else {
                    Text("没有使用记录")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.textMuted)
                }
            }
            Spacer()
            Text(verbatim: formatSize(app.totalSize))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundColor(AppTheme.textSecondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 残留文件 Sheet
struct LeftoversSheet: View {
    @ObservedObject var viewModel: AppUninstallerViewModel
    @Environment(\.dismiss) var dismiss
    @State private var confirm: AppManagerConfirm?

    private var leftovers: [RelatedFile] { viewModel.scanResult?.leftoverFiles ?? [] }
    private var fromTrash: [RelatedFile] { leftovers.filter(\.fromTrashedApp) }
    private var orphans: [RelatedFile] { leftovers.filter { !$0.fromTrashedApp } }
    private var selectedFiles: [RelatedFile] { leftovers.filter(\.isSelected) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "应用残留文件", subtitle: "已卸载应用留在资源库中的文件。默认不勾选，请确认路径后再选择") { dismiss() }

            if leftovers.isEmpty {
                EmptySheetState(icon: "checkmark.circle.fill", title: "没有发现残留文件")
            } else {
                List {
                    if !fromTrash.isEmpty {
                        Section {
                            ForEach(fromTrash) { file in row(file) }
                        } header: {
                            Text("废纸篓中的应用留下的（\(fromTrash.count)）")
                        }
                    }
                    if !orphans.isEmpty {
                        Section {
                            ForEach(orphans) { file in row(file) }
                        } header: {
                            Text("疑似已卸载应用的残留（\(orphans.count)）")
                        } footer: {
                            Text("按名称推断：找不到任何已安装应用使用这些 bundle id。Apple、共享目录与最近 7 天内有改动的条目已排除。")
                                .font(.system(size: 11))
                                .foregroundColor(AppTheme.textMuted)
                        }
                    }
                }
            }

            SheetFooter {
                Text("已选择 \(selectedFiles.count) 项，共 \(formatSize(selectedFiles.reduce(0) { $0 + $1.size }))")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textSecondary)
                Spacer()
                if !leftovers.isEmpty {
                    let allSelected = selectedFiles.count == leftovers.count
                    Button(allSelected ? String(localized: "全不选") : String(localized: "全选")) {
                        viewModel.setLeftovers(Set(leftovers.map(\.id)), selected: !allSelected)
                    }
                    .buttonStyle(NeonOutlineButtonStyle())
                }
                Button("移入废纸篓") {
                    confirm = viewModel.leftoverRequest(for: selectedFiles, dismiss: { dismiss() })
                }
                .buttonStyle(NeonButtonStyle(gradient: AppTheme.dangerGradient))
                .disabled(selectedFiles.isEmpty)
                .opacity(selectedFiles.isEmpty ? 0.5 : 1)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .appManagerConfirm($confirm)
    }

    private func row(_ file: RelatedFile) -> some View {
        HStack(spacing: 12) {
            checkbox(Binding(
                get: { file.isSelected },
                set: { viewModel.setLeftovers([file.id], selected: $0) }
            ))
            Image(systemName: file.type.icon)
                .font(.system(size: 16))
                .foregroundColor(AppTheme.sky)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: file.owner)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                    Text(LocalizedStringKey(file.type.rawValue))
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.textMuted)
                }
                Text(verbatim: AppUninstallerViewModel.abbreviate(file.path))
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(file.path)
            }
            Spacer()
            Text(verbatim: formatSize(file.size))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundColor(AppTheme.textSecondary)
            Button(action: { revealInFinder(file.path) }) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(AppTheme.textMuted)
            }
            .buttonStyle(.plain)
            .help("在访达中显示")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 安装包 Sheet
struct InstallersSheet: View {
    @ObservedObject var viewModel: AppUninstallerViewModel
    @Environment(\.dismiss) var dismiss
    @State private var selected: Set<InstallerFile.ID> = []
    @State private var confirm: AppManagerConfirm?

    private var installers: [InstallerFile] { viewModel.scanResult?.installers ?? [] }
    private var selectedInstallers: [InstallerFile] { installers.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "安装包文件", subtitle: "下载文件夹中的 .dmg / .pkg / .xip 安装文件") { dismiss() }

            if installers.isEmpty {
                EmptySheetState(icon: "checkmark.circle.fill", title: "下载文件夹里没有安装包")
            } else {
                List(installers) { installer in
                    HStack(spacing: 12) {
                        checkbox(Binding(
                            get: { selected.contains(installer.id) },
                            set: { if $0 { selected.insert(installer.id) } else { selected.remove(installer.id) } }
                        ))
                        Image(systemName: installer.name.lowercased().hasSuffix(".dmg") ? "externaldrive.fill" : "shippingbox.fill")
                            .font(.system(size: 16))
                            .foregroundColor(AppTheme.violet)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: installer.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(AppTheme.textPrimary)
                                .lineLimit(1)
                            if let modified = installer.modified {
                                Text("下载于 \(modified, formatter: shortDate)")
                                    .font(.system(size: 11))
                                    .foregroundColor(AppTheme.textMuted)
                            }
                        }
                        Spacer()
                        Text(verbatim: formatSize(installer.size))
                            .font(.system(size: 13))
                            .monospacedDigit()
                            .foregroundColor(AppTheme.textSecondary)
                        Button(action: { revealInFinder(installer.path) }) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(AppTheme.textMuted)
                        }
                        .buttonStyle(.plain)
                        .help("在访达中显示")
                    }
                    .padding(.vertical, 4)
                }
            }

            SheetFooter {
                Text("已选择 \(selectedInstallers.count) 个文件，共 \(formatSize(selectedInstallers.reduce(0) { $0 + $1.size }))")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textSecondary)
                Spacer()
                if !installers.isEmpty {
                    let allSelected = selected.count == installers.count
                    Button(allSelected ? String(localized: "全不选") : String(localized: "全选")) {
                        selected = allSelected ? [] : Set(installers.map(\.id))
                    }
                    .buttonStyle(NeonOutlineButtonStyle())
                }
                Button("移入废纸篓") {
                    confirm = viewModel.installerRequest(for: selectedInstallers, dismiss: { dismiss() })
                }
                .buttonStyle(NeonButtonStyle(gradient: AppTheme.dangerGradient))
                .disabled(selectedInstallers.isEmpty)
                .opacity(selectedInstallers.isEmpty ? 0.5 : 1)
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .appManagerConfirm($confirm)
    }
}

// MARK: - 可用更新 Sheet
struct UpdatesSheet: View {
    @ObservedObject var viewModel: AppUninstallerViewModel
    @Environment(\.dismiss) var dismiss
    @State private var launchError: AppManagerConfirm?

    private var appStoreCount: Int { viewModel.scanResult?.appStoreAppsCount ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "可用更新", subtitle: "通过应用自带的 Sparkle 更新源检查；更新由应用自己完成") { dismiss() }

            if case .checking(let done, let total) = viewModel.updateCheck {
                VStack(alignment: .leading, spacing: 8) {
                    Text("正在检查 \(done) / \(total) 个应用…")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundColor(AppTheme.textSecondary)
                    ProgressView(value: total == 0 ? 0 : Double(done) / Double(total))
                        .tint(AppTheme.accent)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            if viewModel.updatableApps.isEmpty {
                if viewModel.updateCheck == .finished {
                    EmptySheetState(icon: "checkmark.circle.fill", title: "已检查的应用都是最新版本")
                } else {
                    Spacer()
                }
            } else {
                List(viewModel.updatableApps) { app in
                    HStack(spacing: 12) {
                        AppIconView(path: app.path, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: app.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(AppTheme.textPrimary)
                            Text("\(app.currentVersion) → \(app.latestVersion)")
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundColor(AppTheme.accent)
                        }
                        Spacer()
                        if app.infoURL != nil {
                            Button("发布说明") { viewModel.openReleaseNotes(app) }
                                .buttonStyle(NeonOutlineButtonStyle())
                        }
                        Button("打开以更新") {
                            Task {
                                if let message = await viewModel.launchForUpdate(app) {
                                    launchError = AppManagerConfirm(title: "无法打开应用", message: message)
                                }
                            }
                        }
                            .buttonStyle(NeonButtonStyle())
                            .help("打开应用，由它自带的更新器下载并安装新版本")
                    }
                    .padding(.vertical, 4)
                }
            }

            SheetFooter {
                Image(systemName: "bag")
                    .foregroundColor(AppTheme.textMuted)
                Text("\(appStoreCount) 个 App Store 应用请在 App Store 中更新")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textSecondary)
                Spacer()
                Button("打开 App Store 更新") { viewModel.openAppStoreUpdates() }
                    .buttonStyle(NeonOutlineButtonStyle())
            }
        }
        .frame(minWidth: 600, minHeight: 440)
        .appManagerConfirm($launchError)
    }
}
