//
//  MenuBarView.swift
//  MacClean
//
//  菜单栏状态面板：综合状态 + 磁盘 / 内存 / 电池 / CPU / 网络 / 外接设备卡片，
//  磁盘与内存可直接「释放」，网络可测速，外接设备可推出。石墨 + 薄荷设计系统。
//

import SwiftUI

enum MenuBarPanel: Equatable {
    case disk, memory, network, devices, thermal
}

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var monitor = SystemMonitor.shared
    @StateObject private var permissions = PermissionCenter.shared
    @Environment(\.openWindow) private var openWindow
    @State private var panel: MenuBarPanel?
    @StateObject private var quickSearch = SpotlightSearch(limit: 8)
    @State private var searchTerm = ""
    /// Spotlight 索引关闭时，若 MacClean 已建立主目录索引则改用索引结果
    @State private var spotlightOff = false
    @State private var indexResults: [FileSearchResult]?
    @State private var indexTotal = 0
    @FocusState private var isSearchFocused: Bool

    init(initialPanel: MenuBarPanel? = nil) {
        _panel = State(initialValue: initialPanel)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            quickSearchField
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            Group {
                if !searchTerm.trimmingCharacters(in: .whitespaces).isEmpty {
                    quickSearchResults
                } else {
                switch panel {
                case .none: overview
                case .disk: DiskReleasePanel(onBack: back, openMain: openMain)
                case .memory: MemoryReleasePanel(onBack: back)
                case .network: NetworkPanel(onBack: back)
                case .devices: DevicesPanel(onBack: back)
                case .thermal: ThermalPanel(onBack: back)
                }
                }
            }
            .padding(.horizontal, 12)
            .transition(.opacity)

            footer
        }
        .frame(width: 400)
        .background(AppTheme.primaryGradient)
        .onAppear { monitor.start() }
        .onDisappear {
            monitor.stop()
            panel = nil
            searchTerm = ""
            quickSearch.stop()
        }
        .onChange(of: searchTerm) { _, term in
            var query = FileSearchQuery()
            query.term = term
            Task {
                if spotlightOff,
                   let index = await FileIndexStore.shared.cached(FileIndexStore.key(for: .home, includeLibrary: false)) {
                    quickSearch.stop()
                    let found = await Task.detached { index.search(query, limit: 8) }.value
                    guard term == searchTerm else { return }
                    indexResults = found.results
                    indexTotal = found.totalMatches
                } else {
                    indexResults = nil
                    quickSearch.run(query)
                }
            }
        }
        .task {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            spotlightOff = await Task.detached { !SpotlightStatus.isIndexingEnabled(for: home) }.value
        }
    }

    private func back() {
        withAnimation(CosmicAnimations.smooth) { panel = nil }
    }

    private func show(_ target: MenuBarPanel) {
        withAnimation(CosmicAnimations.smooth) { panel = target }
    }

    private func openMain(_ tab: AppTab?) {
        if let tab { appState.currentTab = tab }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text("Mac 状态：")
                        .foregroundColor(AppTheme.textPrimary)
                    (monitor.health.level == .good ? Text("良好") : Text("需要注意"))
                        .foregroundColor(monitor.health.level == .good ? AppTheme.accent : AppTheme.warning)
                }
                .font(.system(size: 17, weight: .semibold))

                Text(monitor.modelName)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textSecondary)

                if !monitor.health.issues.isEmpty {
                    Text(monitor.health.issues.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.warning)
                        .lineLimit(2)
                }
            }
            Spacer()
            Image(nsImage: NSImage(named: NSImage.computerName) ?? NSImage())
                .resizable()
                .frame(width: 44, height: 44)
        }
    }

    // MARK: - 快速搜索

    private var quickSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppTheme.textMuted)
            TextField("快速搜索文件", text: $searchTerm)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(AppTheme.textPrimary)
                .focused($isSearchFocused)
                .onSubmit {
                    if let first = (indexResults ?? quickSearch.results).first { FileActions.open(first.path) }
                }
            if !searchTerm.isEmpty {
                Button {
                    searchTerm = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(AppTheme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: CosmicSizes.controlRadius)
                .fill(AppTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: CosmicSizes.controlRadius)
                        .stroke(isSearchFocused ? AppTheme.accent.opacity(0.6) : AppTheme.surfaceBorder, lineWidth: 1)
                )
        )
    }

    private var quickSearchResults: some View {
        VStack(alignment: .leading, spacing: 2) {
            let shown = indexResults ?? quickSearch.results
            if spotlightOff && indexResults == nil {
                Label("Spotlight 索引不可用，结果可能不全。点下方在 MacClean 中搜索会建立完整索引。", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.warning)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            if shown.isEmpty {
                (indexResults == nil && quickSearch.isSearching ? Text("正在搜索…") : Text("没有找到匹配的文件"))
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
                    .padding(12)
            } else {
                ForEach(shown) { result in
                    QuickSearchRow(result: result, term: searchTerm)
                }
            }
            Divider().overlay(AppTheme.divider).padding(.vertical, 4)
            Button {
                appState.pendingSearchTerm = searchTerm
                openMain(.fileSearch)
            } label: {
                HStack {
                    let total = indexResults == nil ? quickSearch.totalCount : indexTotal
                    (total > shown.count
                         ? Text("在 MacClean 中查看全部 \(total.formatted()) 个结果")
                         : Text("在 MacClean 中打开搜索（可筛选类型、大小）"))
                    Spacer()
                    Image(systemName: "arrow.up.forward").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 12))
                .foregroundColor(AppTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .themeCard()
    }

    // MARK: - 概览卡片

    private var overview: some View {
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            diskCard
            memoryCard
            if monitor.battery != nil { batteryCard }
            cpuCard
            networkCard
            devicesCard
        }
    }

    private var diskCard: some View {
        let disk = monitor.disk
        let low = (disk?.freeRatio ?? 1) < 0.10
        return StatusCard(
            icon: "internaldrive",
            title: disk?.volumeName ?? String(localized: "磁盘"),
            lines: [
                StatusLine(text: String(localized: "可用 \(bytes(disk?.available))"), color: low ? AppTheme.danger : AppTheme.textSecondary),
            ],
            meter: disk.map { 1 - $0.freeRatio },
            meterColor: low ? AppTheme.danger : AppTheme.accent,
            actionTitle: String(localized: "释放"),
            action: { show(.disk) }
        )
    }

    private var memoryCard: some View {
        let memory = monitor.memory
        let pressure = memory?.pressure ?? 0
        return StatusCard(
            icon: "memorychip",
            title: String(localized: "内存"),
            lines: [
                StatusLine(text: String(localized: "压力 \(pressure)%"), color: pressure >= 70 ? AppTheme.warning : AppTheme.textSecondary),
                StatusLine(text: String(localized: "已用 \(bytes(memory?.used)) / \(bytes(memory?.total))"), color: AppTheme.textMuted),
            ],
            meter: memory.map { Double($0.pressure) / 100 },
            meterColor: pressure >= 70 ? AppTheme.warning : AppTheme.accent,
            actionTitle: String(localized: "释放"),
            action: { show(.memory) }
        )
    }

    private var batteryCard: some View {
        let battery = monitor.battery
        var lines: [StatusLine] = [StatusLine(text: batteryStatusText(battery), color: AppTheme.textSecondary)]
        if let health = battery?.healthPercent {
            let cycles = battery?.cycleCount.map { String(localized: " · 循环 \($0) 次") } ?? ""
            lines.append(StatusLine(text: String(localized: "健康度 \(health)%\(cycles)"), color: health < 80 ? AppTheme.warning : AppTheme.textMuted))
        }
        return StatusCard(
            icon: batteryIcon(battery),
            title: String(localized: "电池"),
            trailing: battery.map { "\($0.percent)%" },
            trailingColor: (battery?.percent ?? 100) <= 20 ? AppTheme.danger : AppTheme.textPrimary,
            lines: lines
        )
    }

    private var cpuCard: some View {
        let thermal = monitor.thermal
        let sensors = monitor.sensors
        var lines = [StatusLine(text: String(localized: "负载 \(monitor.cpuLoad.map { "\($0)%" } ?? "—")"), color: AppTheme.textSecondary)]
        if let cpuMax = sensors?.cpuMax {
            lines.append(StatusLine(text: String(localized: "温度 \(SensorFormat.celsius(cpuMax))"), color: TemperatureLevel.of(cpuMax).color))
        }
        if let sensors, sensors.hasFans {
            let idle = sensors.fans.allSatisfy(\.isIdle)
            lines.append(StatusLine(
                text: idle ? String(localized: "风扇 静止") : String(localized: "风扇 \(SensorFormat.rpm(sensors.fanRPM ?? 0))"),
                color: AppTheme.textMuted
            ))
        }
        if sensors?.cpuMax == nil {
            lines.append(StatusLine(text: String(localized: "温度状态由系统热管理报告"), color: AppTheme.textMuted))
        }
        return StatusCard(
            icon: "cpu",
            title: "CPU",
            trailing: thermal.title,
            trailingColor: thermal.color,
            lines: lines,
            meter: monitor.cpuLoad.map { Double($0) / 100 },
            meterColor: (monitor.cpuLoad ?? 0) >= 90 ? AppTheme.warning : AppTheme.accent,
            actionTitle: String(localized: "详情"),
            action: { show(.thermal) }
        )
    }

    private var networkCard: some View {
        let network = monitor.network
        let title: String
        let icon: String
        var hint: String?
        switch network.kind {
        case .wifi:
            title = network.ssid ?? "Wi-Fi"
            icon = "wifi"
            if network.ssid == nil {
                switch permissions.location {
                case .notDetermined: hint = String(localized: "显示网络名称")
                case .denied: hint = String(localized: "在系统设置中允许定位以显示名称")
                case .disabled: hint = String(localized: "开启定位服务以显示名称")
                case .granted: hint = nil
                }
            }
        case .wired:
            title = String(localized: "有线网络")
            icon = "cable.connector"
        case .none:
            title = String(localized: "未连接网络")
            icon = "wifi.slash"
        }
        return StatusCard(
            icon: icon,
            title: title,
            lines: [
                StatusLine(text: "↑ " + rate(monitor.uploadRate), color: AppTheme.textSecondary),
                StatusLine(text: "↓ " + rate(monitor.downloadRate), color: AppTheme.textSecondary),
            ],
            hint: hint,
            hintAction: { permissions.requestLocation() },
            actionTitle: network.kind == .none ? nil : String(localized: "测速"),
            action: { show(.network) }
        )
    }

    private var devicesCard: some View {
        let volumes = monitor.volumes
        let bluetooth = monitor.bluetoothDevices
        var lines: [StatusLine] = bluetooth.map { device in
            let battery = device.battery?.summary.map { " · \($0)" } ?? ""
            let low = (device.battery?.lowest ?? 100) <= 20
            return StatusLine(text: device.name + battery, color: low ? AppTheme.warning : AppTheme.textSecondary)
        }
        lines += volumes.map { StatusLine(text: String(localized: "\($0.name) · 可用 \(bytes($0.available))"), color: AppTheme.textSecondary) }

        let maxLines = 3
        if lines.count > maxLines {
            let extra = lines.count - (maxLines - 1)
            lines = Array(lines.prefix(maxLines - 1)) + [StatusLine(text: String(localized: "还有 \(extra) 个设备"), color: AppTheme.textMuted)]
        }
        if lines.isEmpty {
            lines = [StatusLine(text: String(localized: "尚未连接任何设备"), color: AppTheme.textMuted)]
        }

        let hint: String?
        switch permissions.bluetooth {
        case .notDetermined: hint = String(localized: "显示蓝牙设备")
        case .denied, .disabled: hint = String(localized: "在系统设置中允许蓝牙")
        case .granted: hint = nil
        }

        return StatusCard(
            icon: "externaldrive.connected.to.line.below",
            title: String(localized: "已连接的设备"),
            lines: lines,
            hint: hint,
            hintAction: { permissions.requestBluetooth() },
            actionTitle: bluetooth.isEmpty && volumes.isEmpty ? nil : String(localized: "管理"),
            action: { show(.devices) }
        )
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 4) {
            FooterButton(title: "打开 MacClean", icon: "macwindow") { openMain(nil) }
            Spacer()
            FooterButton(title: nil, icon: "gearshape") {
                openMain(nil)
                appState.showSettingsWindow = true
            }
            .help("设置")
            FooterButton(title: nil, icon: "power") { NSApp.terminate(nil) }
                .help("退出 MacClean")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Rectangle().fill(AppTheme.divider).frame(height: 1), alignment: .top)
        .padding(.top, 12)
    }

    // MARK: - 格式化

    private func bytes(_ value: Int64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
    }

    private func bytes(_ value: UInt64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "—"
    }

    private func rate(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return String(localized: "\(ByteCountFormatter.string(fromByteCount: value, countStyle: .file))/秒")
    }

    private func batteryStatusText(_ battery: BatteryStats?) -> String {
        guard let battery else { return "—" }
        if battery.isCharging {
            return battery.minutesToFull.map { String(localized: "充电中 · 约 \(duration($0)) 充满") } ?? String(localized: "充电中")
        }
        if battery.isOnAC { return String(localized: "已接通电源") }
        return battery.minutesToEmpty.map { String(localized: "剩余 \(duration($0))") } ?? String(localized: "正在估算剩余时间")
    }

    private func duration(_ minutes: Int) -> String {
        minutes >= 60 ? String(localized: "\(minutes / 60) 小时 \(minutes % 60) 分钟") : String(localized: "\(minutes) 分钟")
    }

    private func batteryIcon(_ battery: BatteryStats?) -> String {
        guard let battery else { return "battery.100" }
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

// MARK: - 卡片

struct StatusLine {
    let text: String
    let color: Color
}

private struct StatusCard: View {
    let icon: String
    let title: String
    var trailing: String? = nil
    var trailingColor: Color = AppTheme.textPrimary
    let lines: [StatusLine]
    var meter: Double? = nil
    var meterColor: Color = AppTheme.accent
    /// 次要操作链接（如请求权限），显示在内容行下方。
    var hint: String? = nil
    var hintAction: () -> Void = {}
    var actionTitle: String? = nil
    var action: () -> Void = {}

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppTheme.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(trailingColor)
                }
            }

            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.text)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundColor(line.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .truncationMode(.middle)
            }

            if let hint {
                Button(action: hintAction) {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.open")
                            .font(.system(size: 9, weight: .semibold))
                        Text(hint)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(AppTheme.accent)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            HStack(alignment: .center) {
                if let meter {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(AppTheme.ink(0.08))
                            Capsule()
                                .fill(meterColor)
                                .frame(width: max(4, proxy.size.width * CGFloat(min(max(meter, 0), 1))))
                        }
                    }
                    .frame(height: 4)
                } else {
                    Spacer()
                }
                if let actionTitle {
                    Button(actionTitle, action: action)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppTheme.accent)
                        .padding(.leading, 8)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .themeCard(isHovered: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct FooterButton: View {
    let title: LocalizedStringKey?
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                if let title {
                    Text(title).font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundColor(isHovered ? AppTheme.textPrimary : AppTheme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? AppTheme.ink(0.07) : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 面板骨架

struct PanelContainer<Content: View>: View {
    let title: LocalizedStringKey
    let onBack: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppTheme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(AppTheme.ink(0.07)))
                }
                .buttonStyle(.plain)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Spacer()
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }
}

// MARK: - 快速搜索结果行

private struct QuickSearchRow: View {
    let result: FileSearchResult
    let term: String
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppLookup.fileIcon(path: result.path))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.name)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(((result.path as NSString).deletingLastPathComponent).replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.system(size: 10))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if isHovered {
                Button {
                    FileActions.reveal(result.path)
                } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(AppTheme.textSecondary)
                .help("在访达中显示")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? AppTheme.surfaceHover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { FileActions.open(result.path) }
        .onHover { isHovered = $0 }
        .help(result.path)
    }
}
