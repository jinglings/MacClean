//
//  AppUninstallerView.swift
//  MacClean
//
//  应用管家：汇总卡 + 四张结果卡（可用更新 / 未使用 / 残留 / 安装包）+ 各自的详情 Sheet。
//  所有数字来自真实扫描；所有删除都经 CleanupManager 移入废纸篓，可在完成页或「清理记录」中撤销。
//

import SwiftUI
import AppKit
import Combine
import os

// MARK: - 视图状态
enum AppUninstallerState {
    case initial      // 初始状态
    case scanning     // 扫描中
    case results      // 显示结果
    case uninstalling // 卸载 / 清理中
}

// MARK: - 主视图
struct AppUninstallerView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var viewModel = PageModelStore.shared.appUninstaller

    var body: some View {
        ZStack {
            AuraPageBackground()

            VStack(spacing: 0) {
                topBar

                switch viewModel.state {
                case .initial:
                    initialView
                case .scanning:
                    scanningView
                case .results:
                    resultsView
                case .uninstalling:
                    uninstallingView
                }
            }
        }
        .sheet(isPresented: $viewModel.showCompletion, onDismiss: { viewModel.completionDismissed() }) {
            let result = viewModel.lastCleanResult
            CleanupCompletionView(
                cleanedSize: result?.freedSpace ?? 0,
                cleanedCount: result?.cleanedItems ?? 0,
                failedCount: result?.errors.count ?? 0,
                onUndo: result?.historySessionID == nil ? nil : {
                    viewModel.showCompletion = false
                    Task { await viewModel.undoLastClean() }
                },
                onDismiss: { viewModel.showCompletion = false }
            )
        }
        .alert(
            "操作未完成",
            isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } }),
            presenting: viewModel.errorMessage
        ) { _ in
            Button("好", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: - 顶部栏
    private var topBar: some View {
        PageHeader(title: String(localized: "应用管家"), subtitle: String(localized: "盘点应用、卸载残留与安装包")) {
            if viewModel.state == .results {
                Button(action: { viewModel.startScan() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12, weight: .medium))
                        Text("重新扫描")
                    }
                }
                .buttonStyle(NeonOutlineButtonStyle())
            }
        }
    }

    // MARK: - 初始视图
    private var initialView: some View {
        ScrollView(showsIndicators: false) {
            ScanIntroView(
                icon: "square.grid.2x2",
                title: String(localized: "掌控你的应用"),
                message: String(localized: "盘点已安装的应用，彻底卸载不再使用的软件，连同残留文件与安装包一起清掉。"),
                points: [String(localized: "列出全部应用与真实占用、30 天未打开的应用"), String(localized: "检查 Sparkle 应用的可用更新"), String(localized: "已卸载应用留下的残留文件与安装包"), String(localized: "macOS 可能询问是否允许访问其他应用的数据")],
                action: { viewModel.startScan() }
            )
            .padding(.horizontal, CosmicSizes.pagePadding)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: - 扫描中视图
    private var scanningView: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(AppTheme.ink(0.08), lineWidth: 4)
                    .frame(width: 120, height: 120)
                Circle()
                    .trim(from: 0, to: max(0.02, viewModel.scanProgress))
                    .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.15), value: viewModel.scanProgress)
                Text("\(Int(viewModel.scanProgress * 100))%")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textPrimary)
            }

            VStack(spacing: 8) {
                Text("正在扫描应用程序…")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text("统计每个应用的真实占用、上次打开时间与关联文件")
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.textSecondary)
            }

            if !viewModel.currentScanningItem.isEmpty {
                Text(verbatim: viewModel.currentScanningItem)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 400)
            }

            Spacer()

            Button("停止扫描") {
                viewModel.stopScan()
            }
            .buttonStyle(NeonOutlineButtonStyle())
            .padding(.bottom, 40)
        }
    }

    // MARK: - 结果视图
    private var resultsView: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("共找到 \(viewModel.scanResult?.totalAppsCount ?? 0) 个应用")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                    Text("合计占用 \(ByteCountFormatter.string(fromByteCount: viewModel.totalAppsSize, countStyle: .file))（含关联文件）· 按需卸载、更新，或清掉残留与安装包")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                }
                Spacer()
                Button(action: { viewModel.showAppManager = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 12, weight: .medium))
                        Text("管理我的应用")
                    }
                }
                .buttonStyle(NeonOutlineButtonStyle())
            }
            .padding(20)
            .themeCard()
            .padding(.horizontal, CosmicSizes.pagePadding)
            .padding(.top, 12)

            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 16) {
                    if let result = viewModel.scanResult {
                        updatesCard(result)

                        ResultCard(
                            title: "\(result.unusedApps.count) 个应用超过 30 天未打开",
                            description: "它们连同关联文件占用 \(ByteCountFormatter.string(fromByteCount: result.unusedAppsSize, countStyle: .file))；另有 \(result.unknownUsageApps.count) 个应用没有使用记录。",
                            iconPaths: result.unusedApps.prefix(3).map(\.path),
                            color: AppTheme.amber,
                            iconSystemName: "moon.zzz",
                            onCheck: { viewModel.showUnusedApps = true },
                            onAction: nil,
                            actionTitle: nil
                        )

                        ResultCard(
                            title: "\(result.leftoverFiles.count) 个残留文件，共 \(ByteCountFormatter.string(fromByteCount: result.leftoverSize, countStyle: .file))",
                            description: "已卸载应用留在资源库里的配置与数据。默认不勾选，请逐项确认后再移除。",
                            iconPaths: [],
                            color: AppTheme.sky,
                            iconSystemName: "wrench.and.screwdriver",
                            onCheck: { viewModel.showLeftovers = true },
                            onAction: nil,
                            actionTitle: nil
                        )

                        ResultCard(
                            title: "\(result.installers.count) 个安装包，共 \(ByteCountFormatter.string(fromByteCount: result.installerSize, countStyle: .file))",
                            description: "下载文件夹中的 .dmg / .pkg / .xip 安装文件，装好应用后通常不再需要。",
                            iconPaths: [],
                            color: AppTheme.violet,
                            iconSystemName: "externaldrive",
                            onCheck: { viewModel.showInstallers = true },
                            onAction: result.installers.isEmpty ? nil : { viewModel.showInstallers = true },
                            actionTitle: "清理"
                        )
                    }
                }
                .padding(.horizontal, CosmicSizes.pagePadding)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $viewModel.showAppManager) {
            AppManagerSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showUnusedApps) {
            UnusedAppsSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showLeftovers) {
            LeftoversSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showInstallers) {
            InstallersSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showUpdates) {
            UpdatesSheet(viewModel: viewModel)
        }
    }

    @ViewBuilder
    private func updatesCard(_ result: AppScanResult) -> some View {
        switch viewModel.updateCheck {
        case .checking(let done, let total):
            ResultCard(
                title: "正在检查更新… \(done)/\(total)",
                description: "向支持 Sparkle 的应用的更新源查询最新版本。",
                iconPaths: [],
                color: AppTheme.mint,
                iconSystemName: "arrow.triangle.2.circlepath",
                onCheck: { viewModel.showUpdates = true },
                onAction: nil,
                actionTitle: nil
            )
        case .idle, .finished:
            ResultCard(
                title: "\(viewModel.updatableApps.count) 个应用有可用更新",
                description: "已检查 \(viewModel.checkedForUpdatesCount) 个支持 Sparkle 的应用；\(result.appStoreAppsCount) 个 App Store 应用请在 App Store 中更新。",
                iconPaths: viewModel.updatableApps.prefix(3).map(\.path),
                color: AppTheme.mint,
                iconSystemName: "arrow.down.circle",
                onCheck: { viewModel.showUpdates = true },
                onAction: viewModel.updatableApps.isEmpty ? nil : { viewModel.showUpdates = true },
                actionTitle: "更新"
            )
        }
    }

    // MARK: - 卸载中视图
    private var uninstallingView: some View {
        VStack(spacing: 20) {
            Spacer()

            ProgressView(value: viewModel.cleanProgress)
                .tint(AppTheme.accent)
                .frame(width: 260)

            Text(verbatim: viewModel.uninstallStatus)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppTheme.textPrimary)

            Text("移入废纸篓的内容可在完成页或「清理记录」中恢复")
                .font(.system(size: 13))
                .foregroundColor(AppTheme.textSecondary)

            Spacer()
        }
    }
}

// MARK: - 结果卡片
struct ResultCard: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey?
    let iconPaths: [String]
    let color: Color
    var iconSystemName: String? = nil
    let onCheck: () -> Void
    let onAction: (() -> Void)?
    let actionTitle: LocalizedStringKey?

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(AppTheme.textPrimary)
                .lineLimit(2)

            if let description = description {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(2)
            }

            Spacer()

            HStack {
                if !iconPaths.isEmpty {
                    HStack(spacing: -8) {
                        ForEach(iconPaths, id: \.self) { path in
                            AppIconView(path: path, size: 32)
                        }
                    }
                } else if let systemName = iconSystemName {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(color.opacity(0.14))
                            .frame(width: 36, height: 36)
                        Image(systemName: systemName)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(color)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Button("查看", action: onCheck)
                        .buttonStyle(NeonOutlineButtonStyle())

                    if let action = onAction, let title = actionTitle {
                        Button(title, action: action)
                            .buttonStyle(NeonButtonStyle())
                    }
                }
            }
        }
        .padding(16)
        .frame(height: 150)
        .themeCard(isHovered: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 应用图标

/// NSImage 不是 Sendable，扫描结果只带路径，图标在主线程按需取并缓存。
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}

struct AppIconView: View {
    let path: String
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: AppIconCache.icon(for: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

// MARK: - 确认弹窗

struct AppManagerConfirm: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let message: String
    var confirmTitle: LocalizedStringKey = "移入废纸篓"
    /// nil 表示只是提示，只有「好」按钮。
    var action: (() -> Void)? = nil
}

extension View {
    func appManagerConfirm(_ request: Binding<AppManagerConfirm?>) -> some View {
        alert(
            request.wrappedValue?.title ?? "",
            isPresented: Binding(get: { request.wrappedValue != nil }, set: { if !$0 { request.wrappedValue = nil } }),
            presenting: request.wrappedValue
        ) { confirm in
            if let action = confirm.action {
                Button("取消", role: .cancel) {}
                Button(confirm.confirmTitle, role: .destructive, action: action)
            } else {
                Button("好", role: .cancel) {}
            }
        } message: { confirm in
            Text(confirm.message)
        }
    }
}

// MARK: - ViewModel
@MainActor
final class AppUninstallerViewModel: ObservableObject {
    enum UpdateCheckState: Equatable {
        case idle
        case checking(done: Int, total: Int)
        case finished
    }

    @Published var state: AppUninstallerState = .initial
    @Published var scanProgress: Double = 0
    @Published var currentScanningItem: String = ""
    @Published var scanResult: AppScanResult?
    @Published var uninstallStatus: String = ""
    @Published var cleanProgress: Double = 0

    @Published private(set) var updateCheck: UpdateCheckState = .idle
    @Published private(set) var updatableApps: [UpdatableApp] = []
    @Published private(set) var checkedForUpdatesCount = 0

    @Published var lastCleanResult: CleanResult?
    @Published var showCompletion = false
    @Published var errorMessage: String?
    /// 完成页关闭后再弹出的错误（两个弹层不能同时出现）。
    private var pendingErrorMessage: String?

    // Sheet 状态
    @Published var showAppManager = false
    @Published var showUnusedApps = false
    @Published var showLeftovers = false
    @Published var showInstallers = false
    @Published var showUpdates = false

    private var scanTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var scanGeneration = UUID()

    private let ownBundleID = Bundle.main.bundleIdentifier ?? ""

    var totalAppsSize: Int64 { scanResult?.apps.reduce(0) { $0 + $1.totalSize } ?? 0 }

    // MARK: 扫描

    func startScan() {
        scanTask?.cancel()
        updateTask?.cancel()
        let generation = UUID()
        scanGeneration = generation
        state = .scanning
        scanProgress = 0
        currentScanningItem = ""
        updatableApps = []
        updateCheck = .idle

        let ref = WeakRef(self)
        scanTask = Task.detached(priority: .userInitiated) {
            let result = AppManager.scan(progress: { fraction, label in
                Task { @MainActor in ref.object?.reportProgress(fraction, label, generation: generation) }
            })
            await ref.object?.finishScan(result, generation: generation)
        }
    }

    private func reportProgress(_ fraction: Double, _ label: String, generation: UUID) {
        guard generation == scanGeneration, state == .scanning else { return }
        scanProgress = max(scanProgress, fraction)
        currentScanningItem = label
    }

    private func finishScan(_ result: AppScanResult?, generation: UUID) {
        guard generation == scanGeneration, state == .scanning, let result else { return }
        scanResult = result
        scanProgress = 1
        state = .results
        UsageAnalytics.shared.recordScanCompleted()
        startUpdateCheck(apps: result.apps, generation: generation)
    }

    func stopScan() {
        scanTask?.cancel()
        updateTask?.cancel()
        scanGeneration = UUID()
        state = scanResult == nil ? .initial : .results
    }

    func resetToInitial() {
        stopScan()
        state = .initial
        scanResult = nil
        scanProgress = 0
    }

    // MARK: 更新检查

    private func startUpdateCheck(apps: [AppInfo], generation: UUID) {
        let candidates = apps.compactMap(AppUpdateChecker.candidate(for:))
        checkedForUpdatesCount = candidates.count
        guard !candidates.isEmpty else {
            updateCheck = .finished
            return
        }
        updateCheck = .checking(done: 0, total: candidates.count)
        let ref = WeakRef(self)
        updateTask = Task.detached(priority: .utility) {
            let found = await AppUpdateChecker.check(candidates, progress: { done, total in
                Task { @MainActor in
                    guard let model = ref.object, model.scanGeneration == generation, case .checking = model.updateCheck else { return }
                    model.updateCheck = .checking(done: done, total: total)
                }
            })
            await ref.object?.finishUpdateCheck(found, generation: generation)
        }
    }

    private func finishUpdateCheck(_ found: [UpdatableApp], generation: UUID) {
        guard generation == scanGeneration else { return }
        updatableApps = found
        updateCheck = .finished
    }

    /// 打开应用，让它自带的 Sparkle 更新器接手；失败时返回给 Sheet 显示的错误。
    func launchForUpdate(_ app: UpdatableApp) async -> String? {
        do {
            _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration())
            return nil
        } catch {
            return String(localized: "无法打开「\(app.name)」：\(error.localizedDescription)")
        }
    }

    func openReleaseNotes(_ app: UpdatableApp) {
        guard let url = app.infoURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openAppStoreUpdates() {
        if let url = URL(string: "macappstore://showUpdatesPage") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 选择

    func toggleRelated(appID: AppInfo.ID, fileID: RelatedFile.ID) {
        guard let appIndex = scanResult?.apps.firstIndex(where: { $0.id == appID }),
              let fileIndex = scanResult?.apps[appIndex].relatedFiles.firstIndex(where: { $0.id == fileID }) else { return }
        scanResult?.apps[appIndex].relatedFiles[fileIndex].isSelected.toggle()
    }

    func setLeftovers(_ ids: Set<RelatedFile.ID>, selected: Bool) {
        guard var files = scanResult?.leftoverFiles else { return }
        for index in files.indices where ids.contains(files[index].id) {
            files[index].isSelected = selected
        }
        scanResult?.leftoverFiles = files
    }

    func app(withID id: AppInfo.ID) -> AppInfo? {
        scanResult?.apps.first { $0.id == id }
    }

    // MARK: 付费墙

    /// 动手前检查授权。不允许时先关掉当前 Sheet，再弹出购买页（两个 Sheet 不能叠在一起）。
    func allowAction(dismiss: () -> Void) -> Bool {
        if ProGate.allowAction() { return true }
        let appState = AppState.shared
        appState.showLicenseActivation = false
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            appState.showLicenseActivation = true
        }
        return false
    }

    // MARK: 卸载

    func refusalReason(for app: AppInfo) -> String? {
        if !ownBundleID.isEmpty, app.bundleIdentifier == ownBundleID { return String(localized: "这是 MacClean 自己") }
        if app.isAppleApp { return String(localized: "系统自带应用不能卸载") }
        let parent = (app.path as NSString).deletingLastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if parent != "/Applications" && parent != home + "/Applications" { return String(localized: "只能卸载「应用程序」文件夹中的应用") }
        return nil
    }

    func isRunning(_ app: AppInfo) -> Bool {
        !app.bundleIdentifier.isEmpty && !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).isEmpty
    }

    /// 生成卸载确认（或拒绝说明）。dismiss 用于在执行前关闭发起操作的 Sheet。
    func uninstallRequest(for apps: [AppInfo], dismiss: @escaping () -> Void) -> AppManagerConfirm? {
        guard !apps.isEmpty, allowAction(dismiss: dismiss) else { return nil }

        let refused = apps.compactMap { app in refusalReason(for: app).map { String(localized: "「\(app.name)」：\($0)") } }
        if !refused.isEmpty {
            return AppManagerConfirm(title: "无法卸载", message: refused.joined(separator: "\n"))
        }

        let items = uninstallItems(for: apps)
        let listing = Self.listing(items)
        let running = apps.filter(isRunning)
        if !running.isEmpty {
            let names = running.map { String(localized: "「\($0.name)」") }.joined(separator: String(localized: "、"))
            return AppManagerConfirm(
                title: "需要先退出应用",
                message: String(localized: "\(names)正在运行，卸载前会先让它退出（请先保存未保存的内容）。") + "\n\n" + listing,
                confirmTitle: "退出并卸载",
                action: { [weak self] in
                    dismiss()
                    Task { await self?.quitThenUninstall(apps) }
                }
            )
        }
        return AppManagerConfirm(
            title: "确认卸载",
            message: listing,
            confirmTitle: "卸载",
            action: { [weak self] in
                dismiss()
                Task { await self?.uninstall(apps) }
            }
        )
    }

    private func uninstallItems(for apps: [AppInfo]) -> [CleanableItem] {
        apps.flatMap { app -> [CleanableItem] in
            var bundle = CleanableItem(name: app.name, path: app.path, size: app.size, category: .applications, isSelected: true)
            bundle.removesContainer = true
            let related = app.relatedFiles.filter(\.isSelected).map { file -> CleanableItem in
                var item = CleanableItem(name: "\(app.name) · \(file.name)", path: file.path, size: file.size, category: .appLeftovers, isSelected: true)
                item.removesContainer = true
                return item
            }
            return [bundle] + related
        }
    }

    private func quitThenUninstall(_ apps: [AppInfo]) async {
        let running = apps.filter(isRunning)
        state = .uninstalling
        cleanProgress = 0
        uninstallStatus = String(localized: "正在退出 \(running.map(\.name).joined(separator: String(localized: "、")))…")
        for app in running {
            NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).forEach { $0.terminate() }
        }
        for _ in 0..<40 where apps.contains(where: isRunning) {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let stillRunning = apps.filter(isRunning)
        guard stillRunning.isEmpty else {
            state = .results
            let names = stillRunning.map { String(localized: "「\($0.name)」") }.joined(separator: String(localized: "、"))
            errorMessage = String(localized: "\(names)没有退出（可能在等待保存），请手动退出后再卸载。")
            return
        }
        await uninstall(apps)
    }

    private func uninstall(_ apps: [AppInfo]) async {
        let status = apps.count == 1 ? String(localized: "正在卸载「\(apps[0].name)」…") : String(localized: "正在卸载 \(apps.count) 个应用…")
        await performClean(uninstallItems(for: apps), status: status)
    }

    // MARK: 残留与安装包

    func leftoverRequest(for files: [RelatedFile], dismiss: @escaping () -> Void) -> AppManagerConfirm? {
        guard !files.isEmpty, allowAction(dismiss: dismiss) else { return nil }
        let items = files.map { file -> CleanableItem in
            var item = CleanableItem(name: file.name, path: file.path, size: file.size, category: .appLeftovers, isSelected: true, description: file.owner)
            item.removesContainer = true
            return item
        }
        return AppManagerConfirm(
            title: "移除残留文件",
            message: Self.listing(items),
            action: { [weak self] in
                dismiss()
                Task { await self?.performClean(items, status: String(localized: "正在移除残留文件…")) }
            }
        )
    }

    func installerRequest(for installers: [InstallerFile], dismiss: @escaping () -> Void) -> AppManagerConfirm? {
        guard !installers.isEmpty, allowAction(dismiss: dismiss) else { return nil }
        let items = installers.map { installer -> CleanableItem in
            var item = CleanableItem(name: installer.name, path: installer.path, size: installer.size, category: .installers, isSelected: true, lastModified: installer.modified)
            item.removesContainer = true
            return item
        }
        return AppManagerConfirm(
            title: "清理安装包",
            message: Self.listing(items),
            action: { [weak self] in
                dismiss()
                Task { await self?.performClean(items, status: String(localized: "正在清理安装包…")) }
            }
        )
    }

    // MARK: 执行与撤销

    private func performClean(_ items: [CleanableItem], status: String) async {
        guard !items.isEmpty else { return }
        state = .uninstalling
        uninstallStatus = status
        cleanProgress = 0
        lastCleanResult = nil
        // 等发起操作的 Sheet 收起，否则很快完成时完成页会和正在消失的 Sheet 冲突
        try? await Task.sleep(nanoseconds: 350_000_000)
        let ref = WeakRef(self)
        do {
            let result = try await CleanupManager.shared.clean(items: items) { fraction in
                Task { @MainActor in ref.object?.cleanProgress = fraction }
            }
            lastCleanResult = result
            scanResult?.pruneMissing()
            state = .results
            let failure = result.errors.isEmpty ? nil : Self.failureText(result.errors)
            if result.cleanedItems == 0 {
                errorMessage = failure ?? String(localized: "没有移除任何内容。")
            } else {
                pendingErrorMessage = failure
                showCompletion = true
            }
            if let failure { AppManager.log.error("App manager clean errors: \(failure, privacy: .public)") }
        } catch {
            state = .results
            errorMessage = String(localized: "操作失败：\(error.localizedDescription)")
        }
    }

    func completionDismissed() {
        guard let message = pendingErrorMessage else { return }
        pendingErrorMessage = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.errorMessage = message
        }
    }

    func undoLastClean() async {
        guard let sessionID = lastCleanResult?.historySessionID else { return }
        pendingErrorMessage = nil
        let restore = await CleanupManager.shared.restore(sessionID: sessionID)
        lastCleanResult = nil
        if !restore.failedPaths.isEmpty {
            errorMessage = String(localized: "有 \(restore.failedPaths.count) 项没能放回原处，可在废纸篓中手动找回：") + "\n" + restore.failedPaths.prefix(5).map { "• \(Self.abbreviate($0))" }.joined(separator: "\n")
        }
        startScan()
    }

    // MARK: 文案

    nonisolated static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// 确认弹窗里的清单：逐项列出路径与大小（最多 12 行），末尾给出总数与总大小。
    static func listing(_ items: [CleanableItem]) -> String {
        let format = { (size: Int64) in ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
        var lines = items.prefix(12).map { String(localized: "• \(abbreviate($0.path))（\(format($0.size))）") }
        if items.count > 12 { lines.append(String(localized: "…以及另外 \(items.count - 12) 项")) }
        let total = items.reduce(0) { $0 + $1.size }
        return String(localized: "以下内容将移入废纸篓，可在完成页或「清理记录」中恢复：") + "\n\n" + lines.joined(separator: "\n") + "\n\n" + String(localized: "共 \(items.count) 项，\(format(total))")
    }

    static func failureText(_ errors: [CleanError]) -> String {
        var lines = errors.prefix(6).map { String(localized: "• \(abbreviate($0.path))：\($0.message)") }
        if errors.count > 6 { lines.append(String(localized: "…以及另外 \(errors.count - 6) 项")) }
        return String(localized: "以下 \(errors.count) 项没能移入废纸篓：") + "\n" + lines.joined(separator: "\n") + "\n\n" + String(localized: "管理员安装的应用需要在访达中手动移到废纸篓；其他应用的容器数据可能需要在「系统设置 › 隐私与安全性 › 完全磁盘访问权限」中允许 MacClean。")
    }
}

// MARK: - Preview
#Preview {
    AppUninstallerView()
        .environmentObject(AppState.shared)
        .frame(width: 900, height: 700)
}
