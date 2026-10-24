//
//  AppStorageView.swift
//  MacClean
//
//  应用占用：每个应用「本体 + 数据 + 缓存」的真实占用，展开后可按规则清理（微信/QQ 专门规则、Docker 专门面板）。
//  应用运行时禁止清理其数据，需先退出，避免损坏正在读写的数据库。
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class AppStorageViewModel: ObservableObject {
    @Published private(set) var apps: [AppStorageInfo] = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var lastScannedAt: Date?
    @Published private(set) var progress: (done: Int, total: Int) = (0, 0)
    @Published private(set) var runningBundleIDs: Set<String> = []

    @Published private(set) var cleaningApp: String?
    @Published private(set) var lastCleanResult: CleanResult?
    @Published private(set) var lastRestoreResult: RestoreResult?

    @Published private(set) var docker: DockerStatus?
    @Published private(set) var dockerMessage: String?
    @Published private(set) var isPruning = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        refreshRunning()
        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: center.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .sink { [weak self] _ in self?.refreshRunning() }
            .store(in: &cancellables)
    }

    var totalSize: Int64 { apps.reduce(0) { $0 + $1.totalSize } }
    var largestSize: Int64 { apps.first?.totalSize ?? 1 }

    func isRunning(_ app: AppStorageInfo) -> Bool { runningBundleIDs.contains(app.bundleID) }

    private func refreshRunning() {
        runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    // MARK: 扫描

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        progress = (0, 0)
        let ref = WeakRef(self)
        Task.detached(priority: .userInitiated) {
            let results = AppStorageScanner.scan(progress: { done, total in
                Task { @MainActor in ref.object?.progress = (done, total) }
            })
            let ignored = IgnoreList.paths()
            let filtered = results.map { app -> AppStorageInfo in
                var app = app
                app.candidates.removeAll { IgnoreList.isIgnored($0.path, in: ignored) }
                return app
            }
            await ref.object?.finishScan(filtered)
        }
        refreshDocker()
    }

    private func finishScan(_ results: [AppStorageInfo]) {
        apps = results
        isScanning = false
        hasScanned = true
        lastScannedAt = Date()
        UsageAnalytics.shared.recordScanCompleted()
    }

    /// 清理后只重新统计这一个应用。
    private func rescan(bundleID: String) {
        guard let current = apps.first(where: { $0.bundleID == bundleID }) else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let installed = AppStorageScanner.InstalledApp(
            bundleID: current.bundleID, name: current.name, path: current.bundlePath,
            groups: AppStorageScanner.appGroups(ofAppAt: current.bundlePath),
            version: (NSDictionary(contentsOfFile: current.bundlePath + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String)
        )
        let claims = Dictionary(uniqueKeysWithValues: current.locations.filter(\.isShared).map { (($0.path as NSString).lastPathComponent, 2) })
        let ref = WeakRef(self)
        Task.detached(priority: .userInitiated) {
            let updated = AppStorageScanner.analyze(installed, home: home, groupClaims: claims)
            await ref.object?.replace(updated)
        }
    }

    private func replace(_ app: AppStorageInfo) {
        guard let index = apps.firstIndex(where: { $0.bundleID == app.bundleID }) else { return }
        apps[index] = app
        apps.sort { $0.totalSize > $1.totalSize }
    }

    // MARK: 选择

    func toggle(_ candidate: AppCleanupCandidate, in app: AppStorageInfo) {
        guard let appIndex = apps.firstIndex(where: { $0.id == app.id }),
              let index = apps[appIndex].candidates.firstIndex(where: { $0.id == candidate.id }) else { return }
        apps[appIndex].candidates[index].isSelected.toggle()
    }

    func selectedSize(of app: AppStorageInfo) -> Int64 {
        app.candidates.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    func ignore(_ candidate: AppCleanupCandidate) {
        IgnoreList.add(candidate.path)
        for index in apps.indices { apps[index].candidates.removeAll { $0.path == candidate.path } }
    }

    // MARK: 退出与清理

    func quit(_ app: AppStorageInfo) {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).forEach { $0.terminate() }
    }

    func clean(_ app: AppStorageInfo) async {
        guard cleaningApp == nil, !isRunning(app) else { return }
        let selected = app.candidates.filter(\.isSelected)
        guard !selected.isEmpty else { return }

        cleaningApp = app.bundleID
        lastRestoreResult = nil
        let items = selected.map { candidate -> CleanableItem in
            var item = CleanableItem(
                name: "\(app.name) · \(candidate.title)",
                path: candidate.path,
                size: candidate.size,
                category: .appData,
                isSelected: true,
                description: candidate.note,
                lastModified: nil
            )
            item.removesContainer = candidate.removesContainer
            return item
        }
        lastCleanResult = try? await CleanupManager.shared.clean(items: items)
        cleaningApp = nil
        rescan(bundleID: app.bundleID)
    }

    func undoLastClean() async {
        guard let sessionID = lastCleanResult?.historySessionID else { return }
        lastRestoreResult = await CleanupManager.shared.restore(sessionID: sessionID)
        lastCleanResult = nil
        scan()
    }

    // MARK: Docker

    func refreshDocker() {
        let ref = WeakRef(self)
        Task.detached(priority: .utility) {
            let status = DockerTool.status()
            await MainActor.run { ref.object?.docker = status }
        }
    }

    func prune(_ level: DockerPruneLevel) {
        guard !isPruning else { return }
        isPruning = true
        dockerMessage = nil
        let ref = WeakRef(self)
        Task.detached(priority: .userInitiated) {
            let result = DockerTool.prune(level)
            let status = DockerTool.status()
            await MainActor.run {
                guard let model = ref.object else { return }
                model.isPruning = false
                model.docker = status
                model.dockerMessage = result.ok
                    ? String(localized: "\(result.message)。Docker 会在后台回收磁盘映像空间，Docker.raw 的占用可能需要几分钟才会下降。")
                    : String(localized: "执行失败：\(result.message)")
            }
        }
    }

    func launchDocker() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.docker.docker") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            dockerMessage = String(localized: "正在启动 Docker，启动完成后点「刷新」查看可回收空间。")
        }
    }
}

// MARK: - 页面

struct AppStorageView: View {
    @ObservedObject private var viewModel = PageModelStore.shared.appStorage
    @State private var expanded: Set<String> = []
    @State private var showCompletion = false
    @State private var showHistory = false
    @State private var confirmApp: AppStorageInfo?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "应用占用"), subtitle: String(localized: "每个应用连同聊天记录、缓存、虚拟磁盘等数据实际占了多少空间")) {
                HStack(spacing: 8) {
                    Button {
                        showHistory = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 12, weight: .medium))
                            Text("清理记录")
                        }
                    }
                    .buttonStyle(NeonOutlineButtonStyle())

                    LastScannedLabel(date: viewModel.lastScannedAt)
                    ScanButton(hasScanned: viewModel.hasScanned, isScanning: viewModel.isScanning) { viewModel.scan() }
                }
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    summary
                    ForEach(viewModel.apps) { app in
                        AppStorageRow(
                            app: app,
                            viewModel: viewModel,
                            isExpanded: expanded.contains(app.id),
                            onToggle: { toggle(app.id) },
                            onClean: { confirmApp = app }
                        )
                    }
                }
                .padding(.horizontal, CosmicSizes.pagePadding)
                .padding(.vertical, 20)
            }
        }
        .alert(
            "确认清理",
            isPresented: Binding(get: { confirmApp != nil }, set: { if !$0 { confirmApp = nil } }),
            presenting: confirmApp
        ) { app in
            Button("取消", role: .cancel) {}
            Button("移入废纸篓", role: .destructive) {
                Task {
                    await viewModel.clean(app)
                    showCompletion = true
                }
            }
        } message: { app in
            Text(confirmMessage(for: app))
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

    private func toggle(_ id: String) {
        withAnimation(CosmicAnimations.smooth) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private func confirmMessage(for app: AppStorageInfo) -> String {
        let selected = app.candidates.filter(\.isSelected)
        let size = ByteCountFormatter.string(fromByteCount: viewModel.selectedSize(of: app), countStyle: .file)
        var text = String(localized: "将把「\(app.name)」的 \(selected.count) 项数据（\(size)）移入废纸篓，可在「清理记录」中一键恢复。")
        let userData = selected.filter { $0.risk == .userData }
        if !userData.isEmpty {
            let titles = userData.map(\.title).joined(separator: String(localized: "、"))
            text += "\n\n" + String(localized: "其中包含聊天内容：\(titles)。删除后这些内容在\(app.name)里需要重新下载，已过期的将无法找回。")
        }
        return text
    }

    @ViewBuilder
    private var summary: some View {
        if !viewModel.hasScanned && !viewModel.isScanning {
            ScanIntroView(
                icon: "shippingbox",
                title: String(localized: "扫描应用占用"),
                message: String(localized: "统计每个已安装应用连同聊天记录、缓存、虚拟磁盘等数据的真实占用，并找出可清理的部分。"),
                points: [String(localized: "微信、QQ 聊天数据与旧版本、Docker 虚拟磁盘"), String(localized: "VS Code、Claude 等应用的缓存"), String(localized: "约需 20 秒；macOS 可能询问是否允许访问其他应用的数据")],
                action: { viewModel.scan() }
            )
        } else if viewModel.isScanning {
            let (done, total) = viewModel.progress
            VStack(alignment: .leading, spacing: 8) {
                (total == 0 ? Text("正在查找已安装的应用…") : Text("正在统计 \(done) / \(total) 个应用"))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textSecondary)
                ProgressView(value: total == 0 ? 0 : Double(done) / Double(total))
                    .tint(AppTheme.accent)
            }
            .padding(16)
            .themeCard()
        } else if viewModel.hasScanned {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(viewModel.apps.count) 个应用共占用")
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.textSecondary)
                    Text(ByteCountFormatter.string(fromByteCount: viewModel.totalSize, countStyle: .file))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(AppTheme.textPrimary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach([AppStorageKind.bundle, .data, .cache], id: \.self) { kind in
                        HStack(spacing: 6) {
                            Circle().fill(color(for: kind)).frame(width: 8, height: 8)
                            Text(kind.title)
                                .font(.system(size: 11))
                                .foregroundColor(AppTheme.textMuted)
                        }
                    }
                }
            }
            .padding(20)
            .themeCard()

            if viewModel.apps.contains(where: \.hasUnreadableData) {
                Label("部分应用的数据目录没有读取权限，大小可能偏小。可在「系统设置 › 隐私与安全性 › 完全磁盘访问权限」中允许 MacClean。", systemImage: "lock")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

func color(for kind: AppStorageKind) -> Color {
    switch kind {
    case .bundle: return AppTheme.slate
    case .data: return AppTheme.sky
    case .cache: return AppTheme.accent
    }
}

// MARK: - 应用行

private struct AppStorageRow: View {
    let app: AppStorageInfo
    @ObservedObject var viewModel: AppStorageViewModel
    let isExpanded: Bool
    let onToggle: () -> Void
    let onClean: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundlePath))
                        .resizable()
                        .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(app.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(AppTheme.textPrimary)
                            if viewModel.isRunning(app) {
                                Text("运行中")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(AppTheme.textSecondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(AppTheme.ink(0.08)))
                            }
                            if app.cleanableSize > 0 {
                                Text("可清理 \(ByteCountFormatter.string(fromByteCount: app.cleanableSize, countStyle: .file))")
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundColor(AppTheme.accent)
                            }
                        }
                        StackedBar(app: app, scale: Double(app.totalSize) / Double(max(viewModel.largestSize, 1)))
                            .frame(height: 6)
                        Text(breakdownText)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundColor(AppTheme.textMuted)
                    }

                    Text(ByteCountFormatter.string(fromByteCount: app.totalSize, countStyle: .file))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(AppTheme.textPrimary)
                        .frame(width: 90, alignment: .trailing)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(AppTheme.textMuted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().overlay(AppTheme.divider)
                AppStorageDetail(app: app, viewModel: viewModel, onClean: onClean)
                    .padding(16)
            }
        }
        .themeCard(isHovered: isHovered)
        .onHover { isHovered = $0 }
    }

    private var breakdownText: String {
        [AppStorageKind.bundle, .data, .cache]
            .map { kind in (kind, app.size(of: kind)) }
            .filter { $0.1 > 0 }
            .map { "\($0.0.title) \(ByteCountFormatter.string(fromByteCount: $0.1, countStyle: .file))" }
            .joined(separator: " · ")
    }
}

private struct StackedBar: View {
    let app: AppStorageInfo
    /// 相对最大应用的比例，让各行长度可直接比较。
    let scale: Double

    var body: some View {
        GeometryReader { proxy in
            let total = max(Double(app.totalSize), 1)
            let width = proxy.size.width * CGFloat(max(scale, 0.02))
            HStack(spacing: 1) {
                ForEach([AppStorageKind.bundle, .data, .cache], id: \.self) { kind in
                    let size = Double(app.size(of: kind))
                    if size > 0 {
                        Rectangle()
                            .fill(color(for: kind))
                            .frame(width: max(2, width * CGFloat(size / total)))
                    }
                }
                Spacer(minLength: 0)
            }
            .clipShape(Capsule())
            .background(Capsule().fill(AppTheme.ink(0.05)))
        }
    }
}

// MARK: - 展开详情

private struct AppStorageDetail: View {
    let app: AppStorageInfo
    @ObservedObject var viewModel: AppStorageViewModel
    let onClean: () -> Void

    private var isDocker: Bool { app.bundleID == "com.docker.docker" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("占用明细")
            VStack(spacing: 4) {
                ForEach(app.locations) { location in
                    HStack(spacing: 8) {
                        Circle().fill(color(for: location.kind)).frame(width: 6, height: 6)
                        Text(location.isShared ? String(localized: "\(location.label)（与其他应用共用，不计入合计）") : location.label)
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.textSecondary)
                        Text(SpaceLensItem.cleanPath(location.path).replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                            .font(.system(size: 11))
                            .foregroundColor(AppTheme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(location.isUnreadable ? String(localized: "无权读取") : ByteCountFormatter.string(fromByteCount: location.size, countStyle: .file))
                            .font(.system(size: 12, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(location.isUnreadable ? AppTheme.warning : AppTheme.textSecondary)
                        Button {
                            NSWorkspace.shared.selectFile(location.path, inFileViewerRootedAtPath: "")
                        } label: {
                            Image(systemName: "magnifyingglass").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(AppTheme.textMuted)
                        .help("在访达中显示")
                    }
                }
            }

            if isDocker {
                DockerSection(viewModel: viewModel)
            }

            if !app.candidates.isEmpty {
                section("可清理")
                if viewModel.isRunning(app) {
                    HStack(spacing: 10) {
                        Label("\(app.name) 正在运行。清理前请先退出，避免损坏它正在使用的数据。", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.warning)
                        Spacer()
                        Button("退出 \(app.name)") { viewModel.quit(app) }
                            .buttonStyle(NeonOutlineButtonStyle())
                    }
                }
                VStack(spacing: 2) {
                    ForEach(app.candidates) { candidate in
                        CandidateRow(
                            candidate: candidate,
                            onToggle: { viewModel.toggle(candidate, in: app) },
                            onIgnore: { viewModel.ignore(candidate) }
                        )
                    }
                }
                HStack {
                    Text("聊天图片、视频、文件属于你的数据，默认不勾选")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.textMuted)
                    Spacer()
                    Button {
                        onClean()
                    } label: {
                        HStack(spacing: 6) {
                            if viewModel.cleaningApp == app.bundleID {
                                ProgressView().scaleEffect(0.5).tint(AppTheme.onAccent)
                            } else {
                                Image(systemName: "trash")
                            }
                            Text("清理 \(ByteCountFormatter.string(fromByteCount: viewModel.selectedSize(of: app), countStyle: .file))")
                                .monospacedDigit()
                        }
                    }
                    .buttonStyle(NeonButtonStyle())
                    .disabled(viewModel.selectedSize(of: app) == 0 || viewModel.isRunning(app) || viewModel.cleaningApp != nil)
                }
            } else if !isDocker {
                Text("没有可自动清理的项目。如不再使用，可在「应用管家」中卸载。")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
            }
        }
    }

    private func section(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(AppTheme.textMuted)
    }
}

private struct CandidateRow: View {
    let candidate: AppCleanupCandidate
    let onToggle: () -> Void
    let onIgnore: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { candidate.isSelected }, set: { _ in onToggle() }))
                .toggleStyle(CosmicCheckboxStyle(accentColor: AppTheme.accent))
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(candidate.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.textPrimary)
                    if candidate.risk == .userData {
                        Text("聊天内容")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(AppTheme.warning)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(AppTheme.warning.opacity(0.14)))
                    }
                }
                Text(candidate.note)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(2)
            }
            .help(candidate.path)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: candidate.size, countStyle: .file))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(AppTheme.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? AppTheme.surfaceHover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("在访达中显示") { NSWorkspace.shared.selectFile(candidate.path, inFileViewerRootedAtPath: "") }
            Divider()
            Button("始终忽略此项", action: onIgnore)
        }
    }
}

// MARK: - Docker

private struct DockerSection: View {
    @ObservedObject var viewModel: AppStorageViewModel
    @State private var confirmLevel: DockerPruneLevel?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Docker 数据")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppTheme.textMuted)
                Spacer()
                Button("刷新") { viewModel.refreshDocker() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.accent)
            }

            Text("镜像、容器、数据卷都存放在一个虚拟磁盘文件（Docker.raw）里，直接删除它会丢失全部数据。请通过 Docker 自己清理：")
                .font(.system(size: 11))
                .foregroundColor(AppTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            switch viewModel.docker {
            case .none:
                ProgressView().scaleEffect(0.6).tint(AppTheme.textSecondary)
            case .notInstalled:
                Text("未找到 docker 命令行工具")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textSecondary)
            case .notRunning:
                HStack {
                    Text("Docker 未运行，启动后才能查看可回收的空间")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textSecondary)
                    Spacer()
                    Button("启动 Docker") { viewModel.launchDocker() }
                        .buttonStyle(NeonOutlineButtonStyle())
                }
            case .running(let rows):
                VStack(spacing: 4) {
                    ForEach(rows, id: \.type) { row in
                        HStack {
                            Text(row.title)
                                .font(.system(size: 12))
                                .foregroundColor(AppTheme.textSecondary)
                                .frame(width: 70, alignment: .leading)
                            Text("\(row.totalCount) 个 · 使用中 \(row.active)")
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundColor(AppTheme.textMuted)
                            Spacer()
                            Text(row.size)
                                .font(.system(size: 12, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(AppTheme.textSecondary)
                            Text("可回收 \(row.reclaimable)")
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundColor(AppTheme.accent)
                                .frame(width: 130, alignment: .trailing)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(DockerPruneLevel.allCases, id: \.self) { level in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(level.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(AppTheme.textPrimary)
                                Text(level.detail)
                                    .font(.system(size: 10))
                                    .foregroundColor(AppTheme.textMuted)
                            }
                            Spacer()
                            Button("执行") { confirmLevel = level }
                                .buttonStyle(NeonOutlineButtonStyle(color: level == .allUnusedImages ? AppTheme.danger : AppTheme.textPrimary))
                                .disabled(viewModel.isPruning)
                        }
                    }
                }
            }

            if viewModel.isPruning {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.5).tint(AppTheme.textSecondary)
                    Text("正在清理 Docker 数据…").font(.system(size: 11)).foregroundColor(AppTheme.textSecondary)
                }
            }
            if let message = viewModel.dockerMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: CosmicSizes.controlRadius).fill(AppTheme.ink(0.04)))
        .alert(
            "确认清理 Docker 数据",
            isPresented: Binding(get: { confirmLevel != nil }, set: { if !$0 { confirmLevel = nil } }),
            presenting: confirmLevel
        ) { level in
            Button("取消", role: .cancel) {}
            Button(level.title, role: .destructive) { viewModel.prune(level) }
        } message: { level in
            Text("\(level.detail)。\n由 Docker 直接删除，不经过废纸篓，无法撤销；数据卷不会被删除。")
        }
    }
}
