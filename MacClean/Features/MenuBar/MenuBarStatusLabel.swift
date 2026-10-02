//
//  MenuBarStatusLabel.swift
//  MacClean
//
//  菜单栏图标。设置里开启「在菜单栏图标旁显示 CPU 温度」后，图标右侧显示如「62°」。
//

import SwiftUI

struct MenuBarStatusLabel: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @AppStorage(SensorSettingsKey.showTemperatureInMenuBar) private var showsTemperature = false

    var body: some View {
        if showsTemperature, let cpuMax = monitor.sensors?.cpuMax {
            HStack(spacing: 3) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                Text("\(Int(cpuMax.rounded()))°")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            .accessibilityLabel(Text("MacClean"))
        } else {
            Label("MacClean", systemImage: "gauge.with.dots.needle.33percent")
        }
    }
}
