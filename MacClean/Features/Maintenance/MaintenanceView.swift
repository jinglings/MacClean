//
//  MaintenanceView.swift
//  MacClean
//
//  系统维护：一组系统自带的维护命令，逐个运行或勾选后批量运行（管理员任务只需输入一次密码）。
//  只描述每个任务实际做什么，不做「让 Mac 变快」之类的承诺。
//

import Combine
import SwiftUI

// MARK: - 状态

enum MaintenanceTaskState: Equatable {
    case idle
    case running
    case finished(MaintenanceOutcome)
}

@MainActor
final class MaintenanceViewModel: ObservableObject {
    static let shared = MaintenanceViewModel()

    @Published var selected: Set<MaintenanceTask> = []
    @Published private(set) var states: [MaintenanceTask: MaintenanceTaskState] = [:]
    @Published private(set) var lastRun: [MaintenanceTask: Date] = [:]
    /// nil 表示尚未读取。
    @Published private(set) var snapshotCount: Int?

    private let defaults = UserDefaults.standard

    private init() {
        for task in MaintenanceTask.allCases {
            let time = defaults.double(forKey: Self.lastRunKey(task))
            if time > 0 { lastRun[task] = Date(timeIntervalSince1970: time) }
        }
    }

    nonisolated static func lastRunKey(_ task: MaintenanceTask) -> String {
        "maintenance.lastRun.\(task.rawValue)"
    }

    var tasks: [MaintenanceTask] { MaintenanceTask.allCases }

    var isRunning: Bool { states.values.contains(.running) }

    func state(of task: MaintenanceTask) -> MaintenanceTaskState { states[task] ?? .idle }

    func canRun(_ task: MaintenanceTask) -> Bool {
        guard task.isAvailable else { return false }
        if task == .deleteLocalSnapshots, snapshotCount == 0 { return false }
        return true
    }

    func refreshSnapshotCount() {
        Task {
            let dates = await Task.detached(priority: .utility) {
                MaintenanceRunner.localSnapshotDates()
            }.value
            snapshotCount = dates.count
        }
    }

    func run(_ tasks: [MaintenanceTask]) {
        let runnable = tasks.filter { canRun($0) && state(of: $0) != .running }
        guard !runnable.isEmpty else { return }
        for task in runnable { states[task] = .running }

        Task {
            let outcomes = await Task.detached(priority: .userInitiated) {
                MaintenanceRunner.run(runnable)
            }.value
            let now = Date()
            for task in runnable {
                let outcome = outcomes[task] ?? .failure(String(localized: "没有返回结果"))
                states[task] = .finished(outcome)
                if case .success = outcome {
                    lastRun[task] = now
                    defaults.set(now.timeIntervalSince1970, forKey: Self.lastRunKey(task))
                }
            }
            selected.subtract(runnable)
            if runnable.contains(.deleteLocalSnapshots) { refreshSnapshotCount() }
        }
    }
}

// MARK: - 页面

struct MaintenanceView: View {
    @ObservedObject private var viewModel = MaintenanceViewModel.shared

    @State private var pendingTasks: [MaintenanceTask] = []
    @State private var showConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "系统维护"), subtitle: String(localized: "调用 macOS 自带的维护命令，解决具体的小毛病")) {
                Button {
                    request(viewModel.tasks.filter { viewModel.selected.contains($0) })
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("运行所选（\(viewModel.selected.count)）")
                    }
                }
                .buttonStyle(NeonButtonStyle())
                .disabled(viewModel.selected.isEmpty || viewModel.isRunning)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(viewModel.tasks) { task in
                        MaintenanceTaskCard(
                            task: task,
                            viewModel: viewModel,
                            onRun: { request([task]) }
                        )
                    }

                    HStack(spacing: 5) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 11))
                        Text("带「需要管理员密码」标记的任务会弹出系统授权框；一次运行多个时只需输入一次。")
                            .font(.system(size: 11.5))
                    }
                    .foregroundColor(AppTheme.textMuted)
                    .padding(.top, 6)
                }
                .padding(.horizontal, CosmicSizes.pagePadding)
                .padding(.vertical, 24)
            }
        }
        .onAppear { viewModel.refreshSnapshotCount() }
        .alert("确认运行", isPresented: $showConfirm) {
            Button("取消", role: .cancel) { pendingTasks = [] }
            Button("运行") {
                viewModel.run(pendingTasks)
                pendingTasks = []
            }
        } message: {
            Text(confirmMessage)
        }
    }

    /// 付费校验后，有副作用提示的任务先确认，其余直接运行。
    private func request(_ tasks: [MaintenanceTask]) {
        guard !tasks.isEmpty else { return }
        guard ProGate.allowAction() else { return }
        if tasks.contains(where: { $0.warning != nil }) {
            pendingTasks = tasks
            showConfirm = true
        } else {
            viewModel.run(tasks)
        }
    }

    private var confirmMessage: String {
        var lines = pendingTasks.map { "· \($0.title)" }
        let warnings = pendingTasks.compactMap { task in task.warning.map { String(localized: "\(task.title)：\($0)") } }
        if !warnings.isEmpty {
            lines.append("")
            lines += warnings
        }
        if pendingTasks.contains(where: \.requiresAdmin) {
            lines.append("")
            lines.append(String(localized: "需要输入管理员密码。"))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 任务卡片

private struct MaintenanceTaskCard: View {
    let task: MaintenanceTask
    @ObservedObject var viewModel: MaintenanceViewModel
    let onRun: () -> Void

    @State private var isHovered = false

    private var state: MaintenanceTaskState { viewModel.state(of: task) }
    private var canRun: Bool { viewModel.canRun(task) }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Toggle("", isOn: Binding(
                get: { viewModel.selected.contains(task) },
                set: { selected in
                    if selected { viewModel.selected.insert(task) } else { viewModel.selected.remove(task) }
                }
            ))
            .toggleStyle(CosmicCheckboxStyle(accentColor: AppTheme.accent))
            .labelsHidden()
            .disabled(!canRun || state == .running)

            let palette = AppTheme.groupPalette(for: task.rawValue)
            GradientIconTile(
                systemName: task.icon,
                gradient: palette.gradient,
                size: 40,
                cornerRatio: 0.27,
                glyphRatio: 0.42,
                shadowColor: palette.shadow
            )
            .saturation(task.isAvailable ? 1 : 0.2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(task.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                    if task.requiresAdmin {
                        Label("需要管理员密码", systemImage: "lock.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(AppTheme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(AppTheme.ink(0.06)))
                    }
                }
                Text(task.summary)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let warning = task.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.warning)
                }
                statusLine
            }

            Spacer(minLength: 12)

            runButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .themeCard(isHovered: isHovered)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 10) {
            if !task.isAvailable {
                Text("此 macOS 版本已不再提供，系统会自动处理")
                    .foregroundColor(AppTheme.textMuted)
            } else {
                Text(lastRunText)
                    .foregroundColor(AppTheme.textMuted)
                if task == .deleteLocalSnapshots, let count = viewModel.snapshotCount {
                    (count == 0 ? Text("没有本地快照") : Text("本地快照：\(count) 个"))
                        .foregroundColor(count == 0 ? AppTheme.textMuted : AppTheme.textSecondary)
                }
                outcomeLabel
            }
        }
        .font(.system(size: 11))
        .padding(.top, 1)
    }

    @ViewBuilder
    private var outcomeLabel: some View {
        if case .finished(let outcome) = state {
            switch outcome {
            case .success(let message):
                Label(message.map { String(localized: "完成：\($0)") } ?? String(localized: "完成"), systemImage: "checkmark.circle.fill")
                    .foregroundColor(AppTheme.accent)
                    .lineLimit(1)
                    .help(message ?? "")
            case .failure(let message):
                Label("失败：\(message)", systemImage: "xmark.circle.fill")
                    .foregroundColor(AppTheme.danger)
                    .lineLimit(2)
                    .help(message)
            case .cancelled:
                Label("已取消", systemImage: "minus.circle")
                    .foregroundColor(AppTheme.textMuted)
            }
        }
    }

    private var lastRunText: String {
        guard let date = viewModel.lastRun[task] else { return String(localized: "上次运行：从未") }
        return String(localized: "上次运行：\(date.formatted(date: .abbreviated, time: .shortened))")
    }

    @ViewBuilder
    private var runButton: some View {
        if state == .running {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6).tint(AppTheme.textSecondary)
                Text("运行中")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textSecondary)
            }
            .frame(minWidth: 72)
        } else {
            Button("运行", action: onRun)
                .buttonStyle(NeonOutlineButtonStyle())
                .disabled(!canRun || viewModel.isRunning)
        }
    }
}
