//
//  MenuBarThermalPanel.swift
//  MacClean
//
//  菜单栏「温度与风扇」二级面板：分类温度、10 分钟走势、风扇转速、全部传感器。只读。
//

import SwiftUI

extension TemperatureLevel {
    var color: Color {
        switch self {
        case .normal: return AppTheme.textPrimary
        case .warm: return AppTheme.warning
        case .hot: return AppTheme.danger
        }
    }
}

extension ThermalLevel {
    /// 用大白话解释系统热状态。
    var explanation: String {
        switch self {
        case .nominal: return String(localized: "温度正常，性能不受影响")
        case .fair: return String(localized: "温度略高，风扇可能会加速，性能基本不受影响")
        case .serious, .critical: return String(localized: "系统已降低性能以控制温度")
        }
    }

    var color: Color {
        switch self {
        case .nominal: return AppTheme.accent
        case .fair: return AppTheme.warning
        case .serious, .critical: return AppTheme.danger
        }
    }
}

struct ThermalPanel: View {
    let onBack: () -> Void

    @ObservedObject private var monitor = SystemMonitor.shared
    @State private var showsAllSensors = false

    var body: some View {
        PanelContainer(title: "温度与风扇", onBack: onBack) {
            thermalState

            if let sample = monitor.sensors {
                if sample.isUnavailable {
                    unavailable
                } else {
                    metrics(sample)
                    Divider().overlay(AppTheme.divider)
                    trends(sample)
                    if sample.hasFans {
                        Divider().overlay(AppTheme.divider)
                        fans(sample.fans)
                    }
                    Divider().overlay(AppTheme.divider)
                    allSensors(sample)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.5).tint(AppTheme.textSecondary)
                    Text("正在读取传感器…")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textSecondary)
                }
            }

            Text("读数来自系统传感器，只读；MacClean 不会调节风扇")
                .font(.system(size: 10))
                .foregroundColor(AppTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear { monitor.wantsAllSensors = false }
    }

    // MARK: 热状态

    private var thermalState: some View {
        let thermal = monitor.thermal
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: thermal == .nominal ? "thermometer.low" : "thermometer.high")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(thermal.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("系统热状态：\(thermal.title)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text(thermal.explanation)
                    .font(.system(size: 11))
                    .foregroundColor(thermal == .nominal ? AppTheme.textMuted : thermal.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var unavailable: some View {
        HStack(spacing: 8) {
            Image(systemName: "sensor")
                .foregroundColor(AppTheme.textMuted)
            Text("此机型暂不支持读取温度与风扇")
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textSecondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CosmicSizes.controlRadius).fill(AppTheme.ink(0.04)))
    }

    // MARK: 分类温度

    private func metrics(_ sample: ThermalSample) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .leading), count: 3)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            metric(label: String(localized: "CPU 平均"), value: sample.cpuAverage)
            metric(label: String(localized: "CPU 最高"), value: sample.cpuMax)
            metric(label: "GPU", value: sample.gpu)
            metric(label: String(localized: "电池"), value: sample.battery)
            metric(label: String(localized: "固态硬盘"), value: sample.ssd)
        }
    }

    private func metric(label: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(AppTheme.textMuted)
            if let value {
                Text(SensorFormat.celsius(value))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(TemperatureLevel.of(value).color)
            } else {
                Text("不可用")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
                    .frame(height: 19, alignment: .center)
            }
        }
    }

    // MARK: 走势

    private func trends(_ sample: ThermalSample) -> some View {
        let points = monitor.thermalHistory.points(now: sample.date)
        return VStack(alignment: .leading, spacing: 10) {
            Text("最近 10 分钟")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.textMuted)
            TrendRow(
                title: String(localized: "CPU 最高温度"),
                current: SensorFormat.celsius(sample.cpuMax),
                currentColor: sample.cpuMax.map { TemperatureLevel.of($0).color } ?? AppTheme.textMuted,
                samples: points.compactMap { point in point.cpuMax.map { (point.date, $0) } },
                end: sample.date,
                unit: "°C",
                color: AppTheme.accent
            )
            if sample.hasFans {
                TrendRow(
                    title: String(localized: "风扇转速"),
                    current: sample.fanRPM.map(SensorFormat.rpm) ?? "—",
                    currentColor: AppTheme.textPrimary,
                    samples: points.compactMap { point in point.fanRPM.map { (point.date, $0) } },
                    end: sample.date,
                    unit: " rpm",
                    color: AppTheme.sky
                )
            }
        }
    }

    // MARK: 风扇

    private func fans(_ fans: [FanReading]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(fans) { fan in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("风扇 \(fan.index + 1)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.textPrimary)
                        Spacer()
                        Text(fan.isIdle ? String(localized: "静止") : SensorFormat.rpm(fan.actual))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(AppTheme.textSecondary)
                    }
                    MeterBar(value: fan.fraction, color: AppTheme.sky)
                    if let minimum = fan.minimum, let maximum = fan.maximum {
                        Text("最低 \(SensorFormat.rpm(minimum)) · 最高 \(SensorFormat.rpm(maximum))")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundColor(AppTheme.textMuted)
                    }
                }
            }
        }
    }

    // MARK: 全部传感器

    private func allSensors(_ sample: ThermalSample) -> some View {
        let groups = sample.groups
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(CosmicAnimations.smooth) { showsAllSensors.toggle() }
                monitor.wantsAllSensors = showsAllSensors
                if showsAllSensors { monitor.refresh() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showsAllSensors ? 90 : 0))
                    Text("全部传感器")
                        .font(.system(size: 12, weight: .medium))
                    if sample.includesAllSensors {
                        Text("\(groups.count)")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundColor(AppTheme.textMuted)
                    }
                    Spacer()
                }
                .foregroundColor(AppTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsAllSensors {
                if !sample.includesAllSensors {
                    ProgressView().scaleEffect(0.5).tint(AppTheme.textSecondary)
                } else {
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(groups) { group in
                                HStack(spacing: 8) {
                                    Text(group.name)
                                        .font(.system(size: 11))
                                        .foregroundColor(AppTheme.textSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 6)
                                    Text(group.category.title)
                                        .font(.system(size: 10))
                                        .foregroundColor(AppTheme.textMuted)
                                    Text(SensorFormat.celsius(group.celsius))
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundColor(TemperatureLevel.of(group.celsius).color)
                                        .frame(width: 42, alignment: .trailing)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            }
        }
    }
}

// MARK: - 走势小图

private struct TrendRow: View {
    let title: String
    let current: String
    let currentColor: Color
    let samples: [(Date, Double)]
    let end: Date
    let unit: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textSecondary)
                if let range {
                    Text(range)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundColor(AppTheme.textMuted)
                }
                Spacer()
                Text(current)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(currentColor)
            }
            if samples.count >= 2 {
                Sparkline(samples: samples, end: end, color: color)
                    .frame(height: 34)
            } else {
                Text("正在收集数据…")
                    .font(.system(size: 10))
                    .foregroundColor(AppTheme.textMuted)
                    .frame(height: 34)
            }
        }
    }

    private var range: String? {
        let values = samples.map(\.1)
        guard samples.count >= 2, let low = values.min(), let high = values.max() else { return nil }
        return "\(Int(low.rounded()).formatted())–\(Int(high.rounded()).formatted())\(unit)"
    }
}

/// 按时间铺在最近 10 分钟的横轴上；纵轴用数据自身的范围（至少留出 4 个单位，避免噪声被放大成锯齿）。
private struct Sparkline: View {
    let samples: [(Date, Double)]
    let end: Date
    let color: Color

    var body: some View {
        Canvas { context, size in
            let values = samples.map(\.1)
            guard let low = values.min(), let high = values.max() else { return }
            let span = max(high - low, 4)
            let floor = low - (span - (high - low)) / 2
            let start = end.addingTimeInterval(-ThermalHistory.window)

            func point(_ sample: (Date, Double)) -> CGPoint {
                let x = CGFloat(sample.0.timeIntervalSince(start) / ThermalHistory.window) * size.width
                let y = size.height - CGFloat((sample.1 - floor) / span) * (size.height - 4) - 2
                return CGPoint(x: min(max(x, 0), size.width), y: y)
            }

            var line = Path()
            for (index, sample) in samples.enumerated() {
                index == 0 ? line.move(to: point(sample)) : line.addLine(to: point(sample))
            }
            var area = line
            if let first = samples.first, let last = samples.last {
                area.addLine(to: CGPoint(x: point(last).x, y: size.height))
                area.addLine(to: CGPoint(x: point(first).x, y: size.height))
                area.closeSubpath()
            }
            context.fill(area, with: .linearGradient(
                Gradient(colors: [color.opacity(0.22), color.opacity(0.02)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .background(
            RoundedRectangle(cornerRadius: 6).fill(AppTheme.ink(0.035))
        )
    }
}
