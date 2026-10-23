//
//  SystemDataView.swift
//  MacClean
//
//  存储地图 →「系统数据」：逐项说明系统数据里有什么、多大、是否正常、该怎么处理。只读。
//

import AppKit
import Combine
import SwiftUI

// MARK: - 模式切换

enum StorageMapMode: String {
    case folderMap
    case systemData

    static let storageKey = "storageMap.mode"
}

struct StorageMapModePicker: View {
    @AppStorage(StorageMapMode.storageKey) private var mode: StorageMapMode = .folderMap

    var body: some View {
        Picker("", selection: $mode) {
            Text("目录地图").tag(StorageMapMode.folderMap)
            Text("系统数据").tag(StorageMapMode.systemData)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - ViewModel

@MainActor
final class SystemDataViewModel: ObservableObject {
    static let shared = SystemDataViewModel()

    enum Phase {
        case intro
        case scanning
        case results
    }

    enum CategoryScanState: Equatable {
        case pending
        case measuring
        case done(Int64?)
    }

    @Published var phase: Phase = .intro
    @Published var report: SystemDataReport?
    @Published var scanStates: [SystemDataCategoryID: CategoryScanState] = [:]
    @Published var scannedBytes: Int64 = 0
    @Published var expanded: Set<SystemDataCategoryID> = []
    @Published var errorMessage: String?
    @Published var scannedAt: Date?
    /// 第二阶段：系统数据已显示，对照项与「其他未分类」仍在后台测量
    @Published var isMeasuringComparison = false
    /// 第二阶段被用户停止
    @Published var comparisonStopped = false
    /// 第二阶段各项已统计的字节
    @Published var categoryBytes: [SystemDataCategoryID: Int64] = [:]

    private var scanTask: Task<Void, Never>?
    private var generation = 0
    /// 已收到完整报告的扫描批次，防止晚到的第一阶段报告覆盖它
    private var completedGeneration = -1

    var isBusy: Bool { phase == .scanning || isMeasuringComparison }

    func startScan() {
        scanTask?.cancel()
        generation += 1
        let current = generation
        phase = .scanning
        errorMessage = nil
        scannedBytes = 0
        expanded = []
        isMeasuringComparison = false
        comparisonStopped = false
        categoryBytes = [:]
        scanStates = Dictionary(uniqueKeysWithValues: SystemDataCategoryID.allCases.map { ($0, .pending) })

        // 视图模型常驻：用户切到别的页面时测量继续
        let model = self
        scanTask = Task.detached(priority: .userInitiated) {
            do {
                let report = try await SystemDataAnalyzer.analyze(
                    progress: { event in
                        Task { @MainActor in model.apply(event, generation: current) }
                    },
                    onSystemData: { partial in
                        Task { @MainActor in
                            guard model.generation == current, model.completedGeneration != current else { return }
                            model.show(partial)
                        }
                    }
                )
                try Task.checkCancellation()
                await MainActor.run {
                    guard model.generation == current else { return }
                    model.completedGeneration = current
                    model.show(report)
                    UsageAnalytics.shared.recordScanCompleted()
                }
            } catch {
                await MainActor.run {
                    guard model.generation == current else { return }
                    if !(error is CancellationError) {
                        model.errorMessage = String(localized: "扫描失败：\(error.localizedDescription)")
                    }
                    model.phase = model.report == nil ? .intro : .results
                }
            }
        }
    }

    /// 停止两个阶段。系统数据已经显示时保留它，对照项标为「已停止」。
    func stopScan() {
        generation += 1
        scanTask?.cancel()
        scanTask = nil
        if isMeasuringComparison {
            isMeasuringComparison = false
            comparisonStopped = true
        }
        phase = report == nil ? .intro : .results
    }

    /// 显示一份报告；comparisonPending 的报告来自第一阶段，对照项继续在后台测量。
    func show(_ report: SystemDataReport) {
        self.report = report
        scannedAt = Date()
        phase = .results
        isMeasuringComparison = report.comparisonPending
        if !report.comparisonPending {
            scanTask = nil
        }
    }

    func toggle(_ id: SystemDataCategoryID) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    private func apply(_ event: SystemDataProgress, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .started(let id):
            if scanStates[id] == .pending { scanStates[id] = .measuring }
        case .finished(let id, let size):
            scanStates[id] = .done(size)
        case .bytes(let bytes):
            scannedBytes = max(scannedBytes, bytes)
        case .categoryBytes(let id, let bytes):
            categoryBytes[id] = max(categoryBytes[id] ?? 0, bytes)
        }
    }

    func perform(_ action: SystemDataAction) {
        switch action {
        case .openTab(let destination):
            AppState.shared.currentTab = destination.tab
        case .revealInFinder(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .openSystemSettings(let link):
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        case .showFolderMap:
            UserDefaults.standard.set(StorageMapMode.folderMap.rawValue, forKey: StorageMapMode.storageKey)
        case .automatic, .systemManaged:
            break
        }
    }
}

extension SystemDataDestination {
    var tab: AppTab {
        switch self {
        case .reclaim: return .cacheCleanup
        case .devCaches: return .developerTools
        case .appStorage: return .appStorage
        case .maintenance: return .maintenance
        case .recovery: return .recovery
        case .appManager: return .appUninstaller
        }
    }
}

// MARK: - 文案与图标

extension SystemDataCategoryID {
    var title: String {
        switch self {
        case .snapshots: return String(localized: "本地快照与可清除空间")
        case .timeMachine: return String(localized: "Time Machine")
        case .macOS: return String(localized: "macOS 系统本身")
        case .systemAssets: return String(localized: "系统资源与 Apple 智能模型")
        case .spotlight: return String(localized: "Spotlight 索引")
        case .mediaAnalysis: return String(localized: "照片与媒体分析缓存")
        case .iosBackups: return String(localized: "iPhone / iPad 备份")
        case .xcode: return String(localized: "Xcode 与模拟器")
        case .virtualMachines: return String(localized: "Docker 与虚拟机")
        case .aiModels: return String(localized: "本地 AI 模型")
        case .appCaches: return String(localized: "应用缓存")
        case .logs: return String(localized: "日志")
        case .appData: return String(localized: "应用容器与支持数据")
        case .mailMessages: return String(localized: "邮件与信息附件")
        case .virtualMemory: return String(localized: "虚拟内存与睡眠映像")
        case .installers: return String(localized: "macOS 安装器与更新")
        case .trash: return String(localized: "废纸篓")
        case .commandLineTools: return String(localized: "Homebrew 与命令行工具")
        case .tempFiles: return String(localized: "临时文件")
        case .applications: return String(localized: "应用程序")
        case .personalFiles: return String(localized: "你的个人文件")
        case .otherUsers: return String(localized: "其他用户与共享文件夹")
        case .other: return String(localized: "其他未分类")
        }
    }

    var icon: String {
        switch self {
        case .snapshots: return "camera.on.rectangle.fill"
        case .timeMachine: return "clock.arrow.circlepath"
        case .macOS: return "apple.logo"
        case .systemAssets: return "sparkles"
        case .spotlight: return "magnifyingglass"
        case .mediaAnalysis: return "photo.on.rectangle.angled"
        case .iosBackups: return "iphone"
        case .xcode: return "hammer.fill"
        case .virtualMachines: return "shippingbox.fill"
        case .aiModels: return "brain"
        case .appCaches: return "archivebox.fill"
        case .logs: return "doc.text.fill"
        case .appData: return "square.stack.3d.up.fill"
        case .mailMessages: return "envelope.fill"
        case .virtualMemory: return "memorychip.fill"
        case .installers: return "arrow.down.circle.fill"
        case .trash: return "trash.fill"
        case .commandLineTools: return "terminal.fill"
        case .tempFiles: return "clock.badge.xmark"
        case .applications: return "square.grid.2x2.fill"
        case .personalFiles: return "person.crop.circle.fill"
        case .otherUsers: return "person.2.fill"
        case .other: return "questionmark.folder.fill"
        }
    }

    /// 「这是什么」
    var explanation: String {
        switch self {
        case .snapshots:
            return String(localized: "Time Machine 与系统更新留下的 APFS 本地快照，以及 macOS 标记为「可清除」的文件。磁盘紧张时 macOS 会自动释放这部分空间。")
        case .timeMachine:
            return String(localized: "备份盘不在身边时，Time Machine 会先把备份以本地快照的形式留在本机，已计入上面的「本地快照」。")
        case .macOS:
            return String(localized: "只读的系统卷，以及启动 (Preboot)、恢复 (Recovery) 用的辅助卷。系统设置把它单独列为「macOS」，并不算在系统数据里。")
        case .systemAssets:
            return String(localized: "macOS 按需下载的资源：Apple 智能与 Siri 模型、字典、字体、语音等。")
        case .spotlight:
            return String(localized: "Spotlight 搜索用的索引。macOS 15 曾有缺陷让 CoreSpotlight 索引膨胀到数百 GB。")
        case .mediaAnalysis:
            return String(localized: "系统分析照片和视频（识别人物、场景、文字）时留下的缓存，已知有时会异常膨胀。")
        case .iosBackups:
            return String(localized: "用访达备份 iPhone 或 iPad 时保存在本机的完整备份。")
        case .xcode:
            return String(localized: "Xcode 的构建缓存 (DerivedData)、设备支持文件、模拟器设备与运行时，都可以重新生成。")
        case .virtualMachines:
            return String(localized: "Docker 的虚拟磁盘 Docker.raw 与 UTM / Parallels 虚拟机。Docker.raw 只会变大、不会自己缩小。")
        case .aiModels:
            return String(localized: "Ollama、Hugging Face、LM Studio 等下载到本机的模型文件，单个模型常有几 GB 到几十 GB。")
        case .appCaches:
            return String(localized: "应用为了加快速度保存的临时文件，删除后应用会按需重新生成。")
        case .logs:
            return String(localized: "应用与系统的运行日志、诊断报告。系统日志会自动轮换，你自己的日志可以安全清理。")
        case .appData:
            return String(localized: "应用存放在资源库里的数据：沙盒容器、共享组容器与 Application Support。下面列出占用最多的 5 个应用。")
        case .mailMessages:
            return String(localized: "「邮件」下载的邮件与附件，以及「信息」里收到的图片、视频等附件。")
        case .virtualMemory:
            return String(localized: "内存不够用时写到磁盘的交换文件，以及合盖睡眠时保存内存内容的睡眠映像。")
        case .installers:
            return String(localized: "下载过的「安装 macOS」应用与系统更新包。")
        case .trash:
            return String(localized: "已删除但还没清空的文件，仍然占用磁盘空间。")
        case .commandLineTools:
            return String(localized: "Homebrew 等安装在 /opt 与 /usr/local 的命令行工具、开发库及其下载缓存。")
        case .tempFiles:
            return String(localized: "应用与系统的临时文件和按用户存放的缓存（/private/var/folders），macOS 会定期清理，重启后也会减少一部分。")
        case .applications:
            return String(localized: "「应用程序」文件夹里的应用（不含上面已计入的「安装 macOS」）。")
        case .personalFiles:
            return String(localized: "你的主目录里除「资源库」和废纸篓以外的文件：文稿、桌面、下载、照片图库等，以及 iCloud 云盘在本机的副本。")
        case .otherUsers:
            return String(localized: "本机其他用户的主目录与「共享」文件夹。")
        case .other:
            return String(localized: "未归入以上任何一项的空间，通常是系统数据库、缓存索引等零散文件。")
        }
    }
}

extension SystemDataStatus {
    var label: String {
        switch self {
        case .normal: return String(localized: "正常")
        case .large: return String(localized: "偏大")
        case .abnormal: return String(localized: "异常")
        }
    }

    var color: Color {
        switch self {
        case .normal: return AppTheme.accent
        case .large: return AppTheme.warning
        case .abnormal: return AppTheme.danger
        }
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: - 根视图

struct SystemDataView: View {
    @ObservedObject var viewModel: SystemDataViewModel

    var body: some View {
        ZStack {
            AppBackdrop()

            switch viewModel.phase {
            case .intro:
                SystemDataIntroView(viewModel: viewModel)
                    .transition(.opacity)
            case .scanning:
                SystemDataScanningView(viewModel: viewModel)
                    .transition(.opacity)
            case .results:
                if let report = viewModel.report {
                    SystemDataResultsView(viewModel: viewModel, report: report)
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: viewModel.phase)
    }
}

private struct SystemDataHeader<Trailing: View>: View {
    @ViewBuilder let trailing: Trailing

    var body: some View {
        PageHeader(title: String(localized: "存储地图"), subtitle: String(localized: "逐项看清「系统数据」里有什么、是否正常、该怎么处理")) {
            HStack(spacing: 12) {
                trailing
                StorageMapModePicker()
            }
            .fixedSize()
        }
    }
}

// MARK: - 引导

private struct SystemDataIntroView: View {
    @ObservedObject var viewModel: SystemDataViewModel

    var body: some View {
        VStack(spacing: 0) {
            SystemDataHeader { EmptyView() }

            ScrollView(showsIndicators: false) {
                ScanIntroView(
                    icon: "internaldrive",
                    title: String(localized: "系统数据里到底是什么"),
                    message: String(localized: "macOS 只告诉你「系统数据」有多大，却不说里面是什么。这里逐项测量本机的系统数据，用大白话说明每一项。"),
                    points: [
                        String(localized: "逐项列出占用与原因"),
                        String(localized: "识别已知的 macOS 异常（如 Spotlight 索引膨胀）"),
                        String(localized: "告诉你哪些能安全处理、该怎么处理"),
                        String(localized: "只读检查，不会自动删除任何东西"),
                    ],
                    footnote: String(localized: "只读检查，不需要管理员密码，不会删除任何东西"),
                    action: { viewModel.startScan() }
                )
                .padding(.horizontal, CosmicSizes.pagePadding)
                .padding(.vertical, 24)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.danger)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: CosmicSizes.controlRadius).fill(AppTheme.danger.opacity(0.12)))
                    .padding(.leading, CosmicSizes.pagePadding)
                    .padding(.bottom, 28)
            }
        }
    }
}

// MARK: - 扫描中

private struct SystemDataScanningView: View {
    @ObservedObject var viewModel: SystemDataViewModel

    private static let order: [SystemDataCategoryID] = [
        .spotlight, .mediaAnalysis, .iosBackups, .xcode, .virtualMachines, .aiModels, .systemAssets, .appCaches,
        .logs, .appData, .mailMessages, .virtualMemory, .installers, .trash, .snapshots, .timeMachine, .macOS,
        .commandLineTools, .tempFiles,
    ]

    private var doneCount: Int {
        Self.order.filter { if case .done = viewModel.scanStates[$0] { return true } else { return false } }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            SystemDataHeader { EmptyView() }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("正在逐项测量系统数据…")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(AppTheme.textPrimary)
                            Text("已统计 \(formatBytes(viewModel.scannedBytes)) · 完成 \(doneCount) / \(Self.order.count) 项")
                                .font(.system(size: 12.5))
                                .monospacedDigit()
                                .foregroundColor(AppTheme.textSecondary)
                        }
                        Spacer()
                        Text("首次扫描约需 1–2 分钟，取决于文件数量")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.textMuted)
                        Button("停止扫描", action: viewModel.stopScan)
                            .buttonStyle(NeonOutlineButtonStyle())
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(AppTheme.ink(0.08))
                            Capsule()
                                .fill(AppTheme.brandGradient)
                                .frame(width: max(6, proxy.size.width * CGFloat(doneCount) / CGFloat(Self.order.count)))
                                .animation(.easeOut(duration: 0.2), value: doneCount)
                        }
                    }
                    .frame(height: 6)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 8) {
                        ForEach(Self.order, id: \.self) { id in
                            scanRow(id)
                        }
                    }
                }
                .padding(22)
                .themeCard()
                .padding(.horizontal, CosmicSizes.pagePadding)
                .padding(.vertical, 24)
            }
        }
    }

    private func scanRow(_ id: SystemDataCategoryID) -> some View {
        let state = viewModel.scanStates[id] ?? .pending
        return HStack(spacing: 10) {
            Group {
                switch state {
                case .pending:
                    Image(systemName: "circle")
                        .foregroundColor(AppTheme.textMuted)
                case .measuring:
                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(AppTheme.accent)
                }
            }
            .font(.system(size: 13))
            .frame(width: 16)

            Text(id.title)
                .font(.system(size: 12.5))
                .foregroundColor(state == .pending ? AppTheme.textMuted : AppTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if case .done(let size) = state {
                Text(size.map(formatBytes) ?? "—")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: CosmicSizes.controlRadius, style: .continuous).fill(AppTheme.ink(0.035)))
    }
}

// MARK: - 结果

/// 按大小排名取色，保证占比最大的几项颜色互不相同。
private enum SystemDataPalette {
    private static let pairs: [(UInt, UInt)] = [
        (0x5AB8F5, 0x2F86D8), (0x33C7A0, 0x14A06F), (0xF5B342, 0xE4801C), (0x8E7CFF, 0x6247E8),
        (0xF2709C, 0xD9457A), (0x4FD1C5, 0x0E9BB5), (0xFF9F6B, 0xE0603A), (0x3FB4F0, 0x5C6CF2),
    ]
    private static let rest: (UInt, UInt) = (0x8C95A6, 0x5E6878)

    static let legendLimit = pairs.count

    static func pair(rank: Int?) -> (UInt, UInt) {
        guard let rank, rank < pairs.count else { return rest }
        return pairs[rank]
    }

    static func color(rank: Int?) -> Color { Color(hex: pair(rank: rank).1) }

    static func gradient(rank: Int?) -> LinearGradient {
        let p = pair(rank: rank)
        return AppTheme.tileGradient(Color(hex: p.0), Color(hex: p.1))
    }
}

private struct SystemDataResultsView: View {
    @ObservedObject var viewModel: SystemDataViewModel
    let report: SystemDataReport

    /// 有大小的系统数据类别按大小排名（对照项与「其他」用灰色）
    private var ranks: [SystemDataCategoryID: Int] {
        let sized = report.categories.filter { $0.id != .other && !$0.id.isComparison && ($0.size ?? 0) > 0 }
        return Dictionary(uniqueKeysWithValues: sized.enumerated().map { ($0.element.id, $0.offset) })
    }

    private var needsFullDiskAccess: Bool {
        report.categories.contains { $0.unmeasured.contains { $0.reason == .fullDiskAccess } }
    }

    var body: some View {
        VStack(spacing: 0) {
            SystemDataHeader {
                if viewModel.isMeasuringComparison {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                        Text("仍在测量应用与个人文件")
                            .font(.system(size: 11.5))
                            .foregroundColor(AppTheme.textMuted)
                    }
                    Button(action: viewModel.stopScan) {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .medium))
                            Text("停止")
                        }
                    }
                    .buttonStyle(NeonOutlineButtonStyle())
                } else {
                    LastScannedLabel(date: viewModel.scannedAt)
                    Button(action: viewModel.startScan) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 12, weight: .medium))
                            Text("重新扫描")
                        }
                    }
                    .buttonStyle(NeonOutlineButtonStyle())
                }
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SystemDataSummaryCard(
                        report: report,
                        ranks: ranks,
                        comparisonState: report.comparisonPending
                            ? (viewModel.comparisonStopped ? .stopped : .measuring(SystemDataCategoryID.allCases.filter(\.isComparison).reduce(0) { $0 + (viewModel.categoryBytes[$1] ?? 0) }))
                            : .done
                    )

                    categoryCard(report.categories.filter { $0.id != .other && !$0.id.isComparison })

                    VStack(alignment: .leading, spacing: 3) {
                        Text("不属于系统数据（供对照）")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(AppTheme.textPrimary)
                        Text("把应用和你自己的文件也量出来，剩下的「其他未分类」才名副其实。")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.textMuted)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 8)

                    if report.comparisonPending {
                        pendingComparisonCard
                    } else {
                        categoryCard(report.categories.filter { $0.id == .other || $0.id.isComparison })
                    }

                    footer
                }
                .padding(.horizontal, CosmicSizes.pagePadding)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
        }
    }

    /// 第二阶段进行中：对照项与「其他未分类」的占位行，各自显示进度。
    private var pendingComparisonCard: some View {
        let ids: [SystemDataCategoryID] = [.personalFiles, .applications, .otherUsers, .other]
        return VStack(spacing: 0) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                if index > 0 {
                    Rectangle().fill(AppTheme.divider).frame(height: 1)
                        .padding(.leading, 66)
                }
                SystemDataPendingRow(
                    id: id,
                    state: viewModel.scanStates[id] ?? .pending,
                    measuredBytes: viewModel.categoryBytes[id] ?? 0,
                    stopped: viewModel.comparisonStopped
                )
            }
        }
        .padding(.vertical, 6)
        .themeCard()
    }

    private func categoryCard(_ categories: [SystemDataCategoryResult]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                if index > 0 {
                    Rectangle().fill(AppTheme.divider).frame(height: 1)
                        .padding(.leading, 66)
                }
                SystemDataCategoryRow(
                    category: category,
                    rank: ranks[category.id],
                    isExpanded: viewModel.expanded.contains(category.id),
                    toggle: { withAnimation(.easeOut(duration: 0.18)) { viewModel.toggle(category.id) } },
                    perform: viewModel.perform
                )
            }
        }
        .padding(.vertical, 6)
        .themeCard()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            footnote("info.circle", String(localized: "系统设置里「系统数据」的数字可能与这里不同：Apple 没有公开它的计算方式，各类别的归属也会随系统版本变化。"))
            footnote("lock", String(localized: "有些位置需要完全磁盘访问权限或管理员权限才能测量，这里会标明「无法测量」，不做估算。"))
            footnote("square.on.square", String(localized: "硬链接与 APFS 克隆的共享部分只计一次；嵌套的文件夹只归入最具体的一项，不会重复计算。"))
            if needsFullDiskAccess {
                Button("授予完全磁盘访问权限") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(NeonOutlineButtonStyle())
                .controlSize(.small)
                .padding(.top, 4)
            }
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.danger)
            }
        }
        .padding(.horizontal, 4)
    }

    private func footnote(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(AppTheme.textMuted)
    }
}

// MARK: - 汇总卡

private struct SystemDataSummaryCard: View {
    enum ComparisonState {
        case done
        case measuring(Int64)
        case stopped
    }

    let report: SystemDataReport
    let ranks: [SystemDataCategoryID: Int]
    var comparisonState: ComparisonState = .done

    private struct Segment: Identifiable {
        let id: String
        let title: String
        let size: Int64
        let color: Color
        /// 与前一段之间留出分组间隙（系统数据 → 对照项 → 其他）
        var startsGroup = false
    }

    /// 对照项用逐级变浅的灰色，与彩色的系统数据区分开
    private static let comparisonOpacities: [Double] = [0.42, 0.32, 0.24]

    private var segments: [Segment] {
        let sized = report.categories.filter { $0.id != .other && !$0.id.isComparison && ($0.size ?? 0) > 0 }
        var result: [Segment] = sized.prefix(SystemDataPalette.legendLimit).map {
            Segment(id: $0.id.rawValue, title: $0.id.title, size: $0.size ?? 0, color: SystemDataPalette.color(rank: ranks[$0.id]))
        }
        let restSize = sized.dropFirst(SystemDataPalette.legendLimit).reduce(0) { $0 + ($1.size ?? 0) }
        if restSize > 0 {
            result.append(Segment(id: "rest", title: String(localized: "其余各项"), size: restSize, color: SystemDataPalette.color(rank: nil)))
        }
        let comparison = report.categories.filter { $0.id.isComparison && ($0.size ?? 0) > 0 }
        for (index, category) in comparison.enumerated() {
            let opacity = Self.comparisonOpacities[min(index, Self.comparisonOpacities.count - 1)]
            result.append(Segment(id: category.id.rawValue, title: category.id.title, size: category.size ?? 0,
                                  color: AppTheme.ink(opacity), startsGroup: index == 0 && !result.isEmpty))
        }
        if let other = report.categories.first(where: { $0.id == .other }), let size = other.size, size > 0 {
            result.append(Segment(id: "other", title: String(localized: "其他未分类"), size: size, color: AppTheme.ink(0.13), startsGroup: !result.isEmpty))
        }
        return result
    }

    var body: some View {
        let volume = report.volume
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(volume.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.textSecondary)
                    HStack(alignment: .bottom, spacing: 28) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("系统数据（已解释）")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(AppTheme.textSecondary)
                            Text(formatBytes(report.explained))
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(AppTheme.textPrimary)
                        }
                        .fixedSize()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("应用与个人文件")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(AppTheme.textMuted)
                            comparisonValue
                                .padding(.bottom, 3)
                        }
                        .fixedSize()
                    }
                    Text("磁盘上实际占用 \(formatBytes(volume.usedOnDisk))，其中 \(formatBytes(volume.purgeable)) 为可清除空间")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                        .fixedSize()
                }
                Spacer(minLength: 12)
                stat(String(localized: "总容量"), volume.total)
                stat(String(localized: "已用"), volume.used)
                stat(String(localized: "可用"), max(volume.available, volume.availableForImportantUsage))
            }

            GeometryReader { proxy in
                let total = max(volume.usedOnDisk, segments.reduce(0) { $0 + $1.size }, 1)
                let spacing: CGFloat = 2
                let groupGap: CGFloat = 6
                let gaps = CGFloat(segments.filter(\.startsGroup).count)
                let usable = max(0, proxy.size.width - spacing * CGFloat(max(segments.count - 1, 0)) - groupGap * gaps)
                HStack(spacing: spacing) {
                    ForEach(segments) { segment in
                        if segment.startsGroup {
                            Color.clear.frame(width: groupGap)
                        }
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(2, usable * CGFloat(Double(segment.size) / Double(total))))
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
            .background(Capsule().fill(AppTheme.ink(0.06)))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(segments) { segment in
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(segment.color)
                            .frame(width: 10, height: 10)
                        Text(segment.title)
                            .font(.system(size: 11.5))
                            .foregroundColor(AppTheme.textSecondary)
                            .lineLimit(1)
                        Text(formatBytes(segment.size))
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(AppTheme.textPrimary)
                    }
                }
            }
        }
        .padding(20)
        .themeCard()
    }

    @ViewBuilder
    private var comparisonValue: some View {
        switch comparisonState {
        case .done:
            Text(formatBytes(report.comparisonTotal))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(AppTheme.textSecondary)
        case .measuring(let bytes):
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                Text("正在测量… 已统计 \(formatBytes(bytes))")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textMuted)
            }
            .frame(height: 26)
        case .stopped:
            Text("已停止测量")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppTheme.textMuted)
                .frame(height: 26)
        }
    }

    private func stat(_ title: String, _ value: Int64) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundColor(AppTheme.textMuted)
            Text(formatBytes(value))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(AppTheme.textPrimary)
        }
    }
}

// MARK: - 类别行

private struct SystemDataCategoryRow: View {
    let category: SystemDataCategoryResult
    let rank: Int?
    let isExpanded: Bool
    let toggle: () -> Void
    let perform: (SystemDataAction) -> Void

    @State private var isHovered = false

    private var isUnmeasurable: Bool { category.size == nil && !category.unmeasured.isEmpty }
    private var showsStatus: Bool {
        category.id != .other && category.id != .timeMachine && !category.id.isComparison && category.size != nil
    }
    private var isMuted: Bool { category.id == .other || category.id.isComparison }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                GradientIconTile(
                    systemName: category.id.icon,
                    gradient: isMuted ? AppTheme.tileGradient(AppTheme.ink(0.30), AppTheme.ink(0.45)) : SystemDataPalette.gradient(rank: rank),
                    size: 36,
                    glyphRatio: 0.46,
                    shadowColor: SystemDataPalette.color(rank: rank)
                )

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(category.id.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(isMuted ? AppTheme.textSecondary : AppTheme.textPrimary)
                        badge
                        Spacer(minLength: 8)
                        sizeLabel
                    }

                    Text(category.id.explanation)
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textSecondary)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)

                    if let note = SystemDataNotes.summary(for: category) {
                        Text(note)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(category.status == .normal ? AppTheme.textSecondary : category.status.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        ForEach((category.id == .aiModels ? [.openTab(.devCaches)] : []) + category.actions, id: \.self) { action in
                            actionView(action)
                        }
                        Spacer(minLength: 0)
                        if hasDetail {
                            Button(action: toggle) {
                                HStack(spacing: 4) {
                                    Text(isExpanded ? "收起" : "详情")
                                    Image(systemName: "chevron.down")
                                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                                }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(AppTheme.textSecondary)
                                .padding(.horizontal, 8)
                                .frame(height: 26)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 2)

                    if isExpanded {
                        SystemDataDetail(category: category)
                            .padding(.top, 6)
                            .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: CosmicSizes.controlRadius, style: .continuous)
                .fill(isHovered ? AppTheme.ink(0.025) : Color.clear)
                .padding(.horizontal, 6)
        )
        .onHover { isHovered = $0 }
    }

    private var hasDetail: Bool {
        !category.entries.isEmpty || !category.unmeasured.isEmpty || category.thresholds != .none
            || !category.snapshotNames.isEmpty || category.unreadableDirectories > 0
    }

    @ViewBuilder
    private var badge: some View {
        if isUnmeasurable {
            pill(String(localized: "无法测量"), color: AppTheme.textMuted)
        } else if category.id == .timeMachine {
            switch category.timeMachineConfigured {
            case .some(true): pill(String(localized: "已设置"), color: AppTheme.textSecondary)
            case .some(false): pill(String(localized: "未设置"), color: AppTheme.textSecondary)
            case .none: EmptyView()
            }
        } else if showsStatus {
            pill(category.status.label, color: category.status.color)
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(color.opacity(0.13)))
    }

    @ViewBuilder
    private var sizeLabel: some View {
        if let size = category.size {
            Text(formatBytes(size))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(AppTheme.textPrimary)
        } else {
            Text(isUnmeasurable ? "—" : "")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(AppTheme.textMuted)
        }
    }

    @ViewBuilder
    private func actionView(_ action: SystemDataAction) -> some View {
        switch action {
        case .automatic, .systemManaged:
            HStack(spacing: 5) {
                Image(systemName: action == .automatic ? "checkmark.circle" : "lock")
                    .font(.system(size: 11))
                Text(action == .automatic ? String(localized: "无需处理（系统会自动管理）") : String(localized: "系统管理，无法手动删除"))
                    .font(.system(size: 12))
            }
            .foregroundColor(AppTheme.textMuted)
            .frame(height: 26)
        default:
            Button {
                perform(action)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: SystemDataNotes.actionIcon(action))
                        .font(.system(size: 11, weight: .medium))
                    Text(SystemDataNotes.actionTitle(action, category: category.id))
                }
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(NeonOutlineButtonStyle())
            .controlSize(.small)
        }
    }
}

// MARK: - 第二阶段占位行

private struct SystemDataPendingRow: View {
    let id: SystemDataCategoryID
    let state: SystemDataViewModel.CategoryScanState
    let measuredBytes: Int64
    let stopped: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            GradientIconTile(
                systemName: id.icon,
                gradient: AppTheme.tileGradient(AppTheme.ink(0.22), AppTheme.ink(0.34)),
                size: 36,
                glyphRatio: 0.46,
                shadowColor: .clear
            )
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(id.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppTheme.textSecondary)
                    Spacer(minLength: 8)
                    status
                }
                Text(id.explanation)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var status: some View {
        if case .done(let size) = state {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.accent)
                Text(size.map(formatBytes) ?? "—")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textSecondary)
            }
        } else if stopped {
            Text("已停止")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppTheme.textMuted)
        } else if id == .other {
            Text("等上面几项测完后计算")
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textMuted)
        } else {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                Text(measuredBytes > 0 ? String(localized: "正在测量… 已统计 \(formatBytes(measuredBytes))") : String(localized: "正在测量…"))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textMuted)
            }
        }
    }
}

// MARK: - 详情

private struct SystemDataDetail: View {
    let category: SystemDataCategoryResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let threshold = SystemDataNotes.thresholdText(category.thresholds) {
                detailLine("ruler", threshold)
            }
            ForEach(SystemDataNotes.details(for: category), id: \.self) { line in
                detailLine("lightbulb", line)
            }
            ForEach(category.unmeasured, id: \.self) { item in
                detailLine("lock", "\(item.path) · \(SystemDataNotes.unmeasurableText(item.reason))")
            }
            if category.unreadableDirectories > 0 {
                detailLine("exclamationmark.triangle", String(localized: "有 \(category.unreadableDirectories) 个子文件夹无法读取，实际占用可能更大。"))
            }

            if !category.entries.isEmpty {
                let maxSize = max(category.entries.map(\.size).max() ?? 1, 1)
                VStack(spacing: 6) {
                    ForEach(category.entries) { entry in
                        HStack(spacing: 10) {
                            Text(entry.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(AppTheme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 240, alignment: .leading)
                                .help(entry.path)
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(AppTheme.accent.opacity(0.55))
                                    .frame(width: max(3, proxy.size.width * CGFloat(Double(entry.size) / Double(maxSize))))
                                    .frame(maxHeight: .infinity)
                            }
                            .frame(height: 5)
                            Text(formatBytes(entry.size))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(AppTheme.textSecondary)
                                .frame(width: 76, alignment: .trailing)
                            if !entry.path.isEmpty {
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                                } label: {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 11))
                                        .foregroundColor(AppTheme.textMuted)
                                }
                                .buttonStyle(.plain)
                                .help(String(localized: "在 Finder 中显示"))
                            }
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: CosmicSizes.controlRadius, style: .continuous).fill(AppTheme.ink(0.03)))
            }
        }
    }

    private func detailLine(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(AppTheme.textMuted)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 动态说明

enum SystemDataNotes {
    /// 显示在行内的一句话（随本机情况变化）
    static func summary(for category: SystemDataCategoryResult) -> String? {
        switch category.id {
        case .snapshots:
            return category.snapshotNames.isEmpty
                ? String(localized: "本机目前没有本地快照，这部分主要是 macOS 标记为可清除的缓存和已存到 iCloud 的文件。")
                : String(localized: "本机有 \(category.snapshotNames.count) 个本地快照，它们也是「找回文件」的恢复来源。")
        case .timeMachine:
            switch category.timeMachineConfigured {
            case .some(false): return String(localized: "本机没有设置 Time Machine，不会因此产生额外的系统数据。")
            case .some(true): return String(localized: "已设置 Time Machine；本地快照的占用已计入「本地快照与可清除空间」。")
            case .none: return String(localized: "无法读取 Time Machine 设置。")
            }
        case .spotlight where category.status != .normal:
            return String(localized: "索引明显偏大，可能遇到了已知的索引膨胀问题。修复：「系统维护」→「重建 Spotlight 索引」。")
        case .mediaAnalysis where category.status != .normal:
            return String(localized: "缓存明显偏大。可以在 Finder 中删除这个文件夹里的内容，系统需要时会重新分析。")
        case .systemAssets:
            if let size = category.intelligenceSize, size > 0 {
                return String(localized: "其中 Apple 智能与 Siri 模型约 \(formatBytes(size))。")
            }
            return nil
        case .virtualMemory:
            return String(localized: "系统自动管理，重启后会减少。")
        case .other:
            return String(localized: "切换到「目录地图」可以看清这部分具体是哪些文件夹。")
        default:
            if category.size == nil && !category.unmeasured.isEmpty {
                return unmeasurableText(category.unmeasured[0].reason)
            }
            return nil
        }
    }

    /// 展开详情里的补充说明
    static func details(for category: SystemDataCategoryResult) -> [String] {
        switch category.id {
        case .snapshots:
            var lines = [String(localized: "可清除空间 = 「可用于重要用途的空间」减去「真正空闲的空间」，macOS 需要时会自动释放，不必手动处理。")]
            if !category.snapshotNames.isEmpty {
                lines.append(String(localized: "快照：\(category.snapshotNames.joined(separator: "、"))"))
                lines.append(String(localized: "删除快照后就无法再从中找回文件；确实要删，请到「系统维护」操作（会再次提醒）。"))
            }
            return lines
        case .virtualMachines:
            return [String(localized: "Docker 删除镜像、容器后，Docker.raw 不会自动缩小：在「应用占用」→ Docker 清理，或在 Docker 设置里调小虚拟磁盘上限。")]
        case .aiModels:
            return [String(localized: "删除前确认不再使用这些模型；Ollama 可以用 ollama rm 删除单个模型。")]
        case .systemAssets:
            return [String(localized: "这些资源由 macOS 下载和清理，删除后系统会重新下载，因此不提供删除。")]
        case .logs:
            return [String(localized: "「释放空间」只清理你自己的日志（~/Library/Logs）；系统日志由 macOS 自动轮换。")]
        case .appData:
            return [String(localized: "这些是应用的数据，可能包含聊天记录、文稿等，请在「应用占用」里按应用查看后再处理。")]
        case .mailMessages:
            return [String(localized: "「信息」附件可在 系统设置 → 通用 → 储存空间 → 信息 中按大小查看和删除。")]
        case .installers:
            return [String(localized: "「安装 macOS」应用装完系统后可以直接移到废纸篓；系统更新包会在安装后自动清理。")]
        case .commandLineTools:
            return [String(localized: "Homebrew 可以用 brew cleanup 删除旧版本和下载缓存；卸载不用的软件包用 brew uninstall。")]
        case .personalFiles:
            return [String(localized: "不含「资源库」与废纸篓；已归入上面类别的文件夹（如 ~/.ollama 模型、虚拟机）只计一次。iCloud 云盘只计已下载到本机的部分。")]
        case .otherUsers:
            return [String(localized: "其他用户的私人文件夹通常无法读取，这时显示的大小只是能读到的部分。")]
        default:
            return []
        }
    }

    static func thresholdText(_ thresholds: SystemDataThresholds) -> String? {
        switch (thresholds.large, thresholds.abnormal) {
        case let (large?, abnormal?):
            return String(localized: "判断标准：不超过 \(formatBytes(large)) 为正常，超过 \(formatBytes(large)) 为偏大，超过 \(formatBytes(abnormal)) 为异常。")
        case let (large?, nil):
            return String(localized: "判断标准：不超过 \(formatBytes(large)) 为正常，超过为偏大。")
        case let (nil, abnormal?):
            return String(localized: "判断标准：超过 \(formatBytes(abnormal)) 为异常。")
        case (nil, nil):
            return nil
        }
    }

    static func unmeasurableText(_ reason: SystemDataUnmeasurableReason) -> String {
        switch reason {
        case .fullDiskAccess: return String(localized: "无法测量（需要完全磁盘访问权限）")
        case .admin: return String(localized: "无法测量（需要管理员权限）")
        }
    }

    static func actionTitle(_ action: SystemDataAction, category: SystemDataCategoryID) -> String {
        switch action {
        case .openTab(.recovery): return String(localized: "去找回文件")
        case .openTab(.maintenance):
            return category == .spotlight ? String(localized: "去系统维护重建索引") : String(localized: "去系统维护管理快照")
        case .openTab(.reclaim): return String(localized: "去释放空间清理")
        case .openTab(.devCaches): return String(localized: "去开发缓存清理")
        case .openTab(.appManager): return String(localized: "去应用管家查看")
        case .openTab(.appStorage):
            return category == .virtualMachines ? String(localized: "去应用占用清理 Docker") : String(localized: "去应用占用查看")
        case .revealInFinder: return String(localized: "在 Finder 中显示")
        case .openSystemSettings:
            return category == .timeMachine ? String(localized: "打开 Time Machine 设置") : String(localized: "在系统设置中管理")
        case .showFolderMap: return String(localized: "切换到目录地图")
        case .automatic: return String(localized: "无需处理（系统会自动管理）")
        case .systemManaged: return String(localized: "系统管理，无法手动删除")
        }
    }

    static func actionIcon(_ action: SystemDataAction) -> String {
        switch action {
        case .openTab: return "arrow.right.circle"
        case .revealInFinder: return "folder"
        case .openSystemSettings: return "gearshape"
        case .showFolderMap: return "chart.pie"
        case .automatic: return "checkmark.circle"
        case .systemManaged: return "lock"
        }
    }
}
