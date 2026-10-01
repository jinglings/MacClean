//
//  MenuBarPanels.swift
//  MacClean
//
//  菜单栏状态面板的二级面板：磁盘释放、内存释放、网络测速、外接设备。
//

import SwiftUI

// MARK: - 磁盘释放

struct DiskReleasePanel: View {
    let onBack: () -> Void
    let openMain: (AppTab?) -> Void

    @StateObject private var model = QuickReleaseModel()
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        PanelContainer(title: "释放磁盘空间", onBack: onBack) {
            if let disk = monitor.disk {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("可用 \(ByteCountFormatter.string(fromByteCount: disk.available, countStyle: .file))")
                            .foregroundColor(AppTheme.textPrimary)
                        Spacer()
                        Text("共 \(ByteCountFormatter.string(fromByteCount: disk.total, countStyle: .file))")
                            .foregroundColor(AppTheme.textMuted)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    MeterBar(value: 1 - disk.freeRatio, color: disk.freeRatio < 0.1 ? AppTheme.danger : AppTheme.accent)
                }
            }

            ReleaseRow(
                icon: "square.stack.3d.up",
                title: "缓存与日志",
                detail: "应用与浏览器缓存、7 天前的日志，删除后会自动重建",
                size: model.isScanning ? nil : model.junkSize,
                buttonTitle: "移入废纸篓",
                isDestructive: false,
                isDisabled: model.junkSize == 0 || model.isCleaning
            ) {
                guard ProGate.allowAction() else { openMain(nil); return }
                Task { await model.cleanJunk() }
            }

            ReleaseRow(
                icon: "trash",
                title: "废纸篓",
                detail: model.isConfirmingEmptyTrash ? LocalizedStringKey(emptyTrashWarning) : "清空后才会真正释放空间",
                size: model.isScanning ? nil : model.trashSize,
                buttonTitle: model.isConfirmingEmptyTrash ? "确认清空" : "清空",
                isDestructive: model.isConfirmingEmptyTrash,
                isDisabled: model.trashSize == 0 || model.isCleaning
            ) {
                guard ProGate.allowAction() else { openMain(nil); return }
                if model.isConfirmingEmptyTrash {
                    Task { await model.emptyTrash() }
                } else {
                    model.trashPreview = TrashPreview.load()
                    model.isConfirmingEmptyTrash = true
                }
            }

            if model.isCleaning {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.5).tint(AppTheme.textSecondary)
                    Text("正在清理…").font(.system(size: 11)).foregroundColor(AppTheme.textSecondary)
                }
            } else if let message = model.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(AppTheme.divider)

            VStack(alignment: .leading, spacing: 6) {
                LinkRow(title: "查看全部可清理项目", icon: "trash") { openMain(.cacheCleanup) }
                LinkRow(title: "大型与陈旧文件", icon: "doc.badge.clock") { openMain(.largeOldFiles) }
                LinkRow(title: "开发缓存", icon: "hammer") { openMain(.developerTools) }
            }
        }
        .onAppear { model.scan() }
    }
}

// MARK: - 内存释放

struct MemoryReleasePanel: View {
    let onBack: () -> Void

    @ObservedObject private var monitor = SystemMonitor.shared
    @State private var apps: [AppMemoryUsage] = []
    @State private var isLoading = false
    @State private var message: String?
    @State private var isPurging = false

    var body: some View {
        PanelContainer(title: "释放内存", onBack: onBack) {
            if let memory = monitor.memory {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("内存压力 \(memory.pressure)%")
                            .foregroundColor(memory.pressure >= 70 ? AppTheme.warning : AppTheme.textPrimary)
                        Spacer()
                        Text("已用 \(format(memory.used)) / \(format(memory.total))")
                            .foregroundColor(AppTheme.textMuted)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    MeterBar(value: Double(memory.pressure) / 100, color: memory.pressure >= 70 ? AppTheme.warning : AppTheme.accent)
                    Text("已压缩 \(format(memory.compressed)) · 交换 \(format(memory.swapUsed))")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundColor(AppTheme.textMuted)
                }
            }

            Text("占用内存最多的应用")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppTheme.textSecondary)

            if isLoading && apps.isEmpty {
                ProgressView().scaleEffect(0.6).tint(AppTheme.textSecondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(apps) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundlePath))
                                .resizable()
                                .frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name)
                                    .font(.system(size: 12))
                                    .foregroundColor(AppTheme.textPrimary)
                                    .lineLimit(1)
                                if app.processCount > 1 {
                                    Text("含 \(app.processCount) 个进程")
                                        .font(.system(size: 10))
                                        .foregroundColor(AppTheme.textMuted)
                                }
                            }
                            Spacer()
                            Text(format(app.footprint))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(AppTheme.textSecondary)
                            Button("退出") { quit(app) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(AppTheme.accent)
                                .frame(width: 32)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            Divider().overlay(AppTheme.divider)

            HStack(spacing: 10) {
                Button {
                    purge()
                } label: {
                    HStack(spacing: 6) {
                        if isPurging {
                            ProgressView().scaleEffect(0.5).tint(AppTheme.textPrimary)
                        }
                        Text("清除非活跃内存")
                    }
                }
                .buttonStyle(NeonOutlineButtonStyle())
                .disabled(isPurging)
                Text("使用系统 purge 命令，需要管理员密码")
                    .font(.system(size: 10))
                    .foregroundColor(AppTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.accent)
            }
        }
        .onAppear(perform: loadApps)
    }

    private func format(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    private func loadApps() {
        isLoading = true
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .compactMap { app -> (pid: pid_t, name: String, bundlePath: String)? in
                guard let path = app.bundleURL?.path else { return nil }
                return (app.processIdentifier, app.localizedName ?? (path as NSString).lastPathComponent, path)
            }
        Task.detached(priority: .userInitiated) {
            let top = MemoryActions.topApps(apps: running)
            await MainActor.run {
                apps = top
                isLoading = false
            }
        }
    }

    private func quit(_ usage: AppMemoryUsage) {
        guard let app = NSRunningApplication(processIdentifier: usage.pid) else { return }
        app.terminate()
        message = String(localized: "已请求退出 \(usage.name)，可释放约 \(format(usage.footprint))")
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            loadApps()
            SystemMonitor.shared.refresh()
        }
    }

    private func purge() {
        guard ProGate.allowAction() else { return }
        isPurging = true
        let before = monitor.memory?.used ?? 0
        Task {
            let error = await MemoryActions.purgeInactiveMemory()
            isPurging = false
            if let error {
                message = error
                return
            }
            let after = SystemStats.memory().used
            let freed = before > after ? before - after : 0
            message = freed > 0 ? String(localized: "已释放约 \(format(freed))") : String(localized: "已清除非活跃内存")
            SystemMonitor.shared.refresh()
        }
    }
}

// MARK: - 网络测速

struct NetworkPanel: View {
    let onBack: () -> Void

    @ObservedObject private var monitor = SystemMonitor.shared
    @State private var result: SpeedTestResult?
    @State private var isTesting = false
    @State private var errorText: String?
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        PanelContainer(title: "网络测速", onBack: onBack) {
            HStack(spacing: 20) {
                metric(label: "当前上传", value: rate(monitor.uploadRate))
                metric(label: "当前下载", value: rate(monitor.downloadRate))
            }

            if isTesting {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.5).tint(AppTheme.textSecondary)
                    Text("正在测速，约需 15–20 秒…")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textSecondary)
                    Spacer()
                    Button("取消") {
                        testTask?.cancel()
                        isTesting = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.accent)
                }
            } else if let result {
                HStack(spacing: 20) {
                    metric(label: "下载带宽", value: NetworkSpeedTest.format(bitsPerSecond: result.download), highlight: true)
                    metric(label: "上传带宽", value: NetworkSpeedTest.format(bitsPerSecond: result.upload), highlight: true)
                    if let rpm = result.responsiveness {
                        metric(label: "响应能力", value: "\(rpm) RPM")
                    }
                }
            } else if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.danger)
            }

            HStack {
                Button(result == nil ? LocalizedStringKey("开始测速") : LocalizedStringKey("重新测速"), action: startTest)
                    .buttonStyle(NeonButtonStyle())
                    .disabled(isTesting)
                Spacer()
                Text("使用 macOS 自带的 networkQuality")
                    .font(.system(size: 10))
                    .foregroundColor(AppTheme.textMuted)
            }
        }
        .onDisappear { testTask?.cancel() }
    }

    private func metric(label: LocalizedStringKey, value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(AppTheme.textMuted)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(highlight ? AppTheme.accent : AppTheme.textPrimary)
        }
    }

    private func rate(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return String(localized: "\(ByteCountFormatter.string(fromByteCount: value, countStyle: .file))/秒")
    }

    private func startTest() {
        isTesting = true
        errorText = nil
        testTask = Task {
            do {
                let value = try await Task.detached(priority: .userInitiated) {
                    try await NetworkSpeedTest.run()
                }.value
                result = value
            } catch is CancellationError {
                // 用户取消
            } catch {
                errorText = String(localized: "测速失败：\(error.localizedDescription)")
            }
            isTesting = false
        }
    }
}

// MARK: - 外接设备

struct DevicesPanel: View {
    let onBack: () -> Void

    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var permissions = PermissionCenter.shared
    @State private var ejecting: Set<URL> = []
    @State private var message: String?

    var body: some View {
        PanelContainer(title: "已连接的设备", onBack: onBack) {
            sectionTitle("蓝牙")
            bluetoothSection

            Divider().overlay(AppTheme.divider)

            sectionTitle("存储设备")
            volumesSection

            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(AppTheme.textMuted)
    }

    // MARK: 蓝牙

    @ViewBuilder
    private var bluetoothSection: some View {
        switch permissions.bluetooth {
        case .granted:
            if monitor.bluetoothDevices.isEmpty {
                Text("没有已连接的蓝牙设备")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
            } else {
                VStack(spacing: 8) {
                    ForEach(monitor.bluetoothDevices) { device in
                        bluetoothRow(device)
                    }
                }
            }
        case .notDetermined, .denied, .disabled:
            HStack(spacing: 10) {
                (permissions.bluetooth == .notDetermined
                     ? Text("允许蓝牙权限后，这里会显示已连接的耳机、键盘、鼠标及其电量。")
                     : Text("蓝牙权限已被拒绝，可在「系统设置 › 隐私与安全性 › 蓝牙」中开启。"))
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(permissions.bluetooth == .notDetermined ? LocalizedStringKey("允许") : LocalizedStringKey("打开设置")) {
                    permissions.requestBluetooth()
                }
                .buttonStyle(NeonOutlineButtonStyle())
            }
        }
    }

    private func bluetoothRow(_ device: BluetoothDeviceInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: device.kind.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppTheme.textSecondary)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.textPrimary)
                    .lineLimit(1)
                if let summary = device.battery?.summary {
                    HStack(spacing: 6) {
                        if let lowest = device.battery?.lowest {
                            MeterBar(value: Double(lowest) / 100, color: lowest <= 20 ? AppTheme.warning : AppTheme.accent)
                                .frame(width: 44)
                        }
                        Text(summary)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundColor((device.battery?.lowest ?? 100) <= 20 ? AppTheme.warning : AppTheme.textMuted)
                    }
                } else {
                    Text("设备未提供电量")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.textMuted)
                }
            }
            Spacer()
            Button {
                let ok = monitor.disconnect(device)
                message = ok ? String(localized: "已断开「\(device.name)」，设备仍保持配对，可随时重新连接") : String(localized: "无法断开「\(device.name)」")
            } label: {
                Label("断开", systemImage: "xmark.circle")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(AppTheme.accent)
        }
    }

    // MARK: 存储设备

    @ViewBuilder
    private var volumesSection: some View {
        if monitor.volumes.isEmpty {
            Text("没有外接存储设备")
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textMuted)
        } else {
            VStack(spacing: 8) {
                ForEach(monitor.volumes) { volume in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: volume.url.path))
                            .resizable()
                            .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(volume.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(AppTheme.textPrimary)
                            Text("可用 \(ByteCountFormatter.string(fromByteCount: volume.available, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: volume.total, countStyle: .file))")
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundColor(AppTheme.textMuted)
                        }
                        Spacer()
                        if ejecting.contains(volume.url) {
                            ProgressView().scaleEffect(0.5).tint(AppTheme.textSecondary)
                        } else {
                            Button {
                                eject([volume])
                            } label: {
                                Label("推出", systemImage: "eject")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(AppTheme.accent)
                        }
                    }
                }
            }
            if monitor.volumes.count > 1 {
                Button("全部推出") { eject(monitor.volumes) }
                    .buttonStyle(NeonOutlineButtonStyle())
            }
        }
    }

    private func eject(_ volumes: [ExternalVolume]) {
        for volume in volumes {
            ejecting.insert(volume.url)
            let url = volume.url
            let name = volume.name
            Task.detached(priority: .userInitiated) {
                var failure: String?
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                } catch {
                    failure = String(localized: "无法推出「\(name)」：可能有应用正在使用它")
                }
                let failureText = failure
                await MainActor.run {
                    ejecting.remove(url)
                    message = failureText ?? String(localized: "已推出「\(name)」，可以安全拔出")
                    SystemMonitor.shared.refresh()
                }
            }
        }
    }
}

// MARK: - 共用小组件

struct MeterBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AppTheme.ink(0.08))
                Capsule()
                    .fill(color)
                    .frame(width: max(4, proxy.size.width * CGFloat(min(max(value, 0), 1))))
            }
        }
        .frame(height: 5)
    }
}

extension DiskReleasePanel {
    /// 第二次确认时的提示：列出将被永久删除的内容
    fileprivate var emptyTrashWarning: String {
        let what = model.trashPreview?.summary ?? ""
        return String(localized: "\(what)将永久删除，MacClean 无法撤销。再点一次确认。")
    }
}

private struct ReleaseRow: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let size: Int64?
    let buttonTitle: LocalizedStringKey
    let isDestructive: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppTheme.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                    if let size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(AppTheme.textSecondary)
                    } else {
                        ProgressView().scaleEffect(0.4).frame(width: 14, height: 14)
                    }
                }
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(isDestructive ? AppTheme.danger : AppTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(buttonTitle, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isDisabled ? AppTheme.textMuted : (isDestructive ? AppTheme.danger : AppTheme.accent))
                .disabled(isDisabled)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: CosmicSizes.controlRadius).fill(AppTheme.ink(0.04)))
    }
}

private struct LinkRow: View {
    let title: LocalizedStringKey
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(AppTheme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
