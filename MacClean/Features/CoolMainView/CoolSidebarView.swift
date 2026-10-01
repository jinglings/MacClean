//
//  CoolSidebarView.swift
//  MacClean
//
//  石墨 + 薄荷侧边栏：紧凑导航 + 底部磁盘概览。
//

import SwiftUI

struct CoolSidebarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var license = LicenseManager.shared
    @Binding var selectedTab: AppTab
    @State private var fullDiskAccessGranted = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 为系统自带的关闭/最小化/缩放按钮留出位置（窗口使用 hiddenTitleBar，按钮由系统绘制）
            Color.clear
                .frame(height: 12)
                .padding(.top, 14)
                .padding(.bottom, 14)

            brandHeader
                .padding(.horizontal, 18)
                .padding(.bottom, 16)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sections, id: \.title) { section in
                        Text(section.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppTheme.textMuted)
                            .padding(.horizontal, 10)
                            .padding(.top, section.title == sections.first?.title ? 0 : 10)
                            .padding(.bottom, 4)
                        ForEach(section.tabs) { tab in
                            sidebarRow(tab)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }

            Spacer()

            if !fullDiskAccessGranted {
                fullDiskAccessCard
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }

            diskCard
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
        }
        .frame(width: CosmicSizes.sidebarWidth)
        .task {
            // 启动即显示，之后每 15 秒刷新一次（视图消失时任务自动取消）
            while !Task.isCancelled {
                appState.refreshDiskInfo()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .task {
            await refreshFullDiskAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.refreshDiskInfo()
            Task { await refreshFullDiskAccess() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macCleanDiskUsageChanged)) { _ in
            appState.refreshDiskInfo()
        }
        .background(
            ZStack {
                VisualEffectBackground(material: .sidebar)
                AppTheme.sidebarGradient
            }
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(AppTheme.divider)
                .frame(width: 1)
        }
    }

    private var sections: [(title: String, tabs: [AppTab])] {
        [
            (String(localized: "概览"), [.smartCare, .diskAnalysis]),
            (String(localized: "清理"), [.cacheCleanup, .largeOldFiles, .similarPhotos, .developerTools, .privacy]),
            (String(localized: "优化"), [.loginItems, .maintenance]),
            (String(localized: "管理"), [.appStorage, .appUninstaller, .fileSearch])
        ]
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(AppTheme.brandGradient)
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0)], startPoint: .top, endPoint: .center))
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
            .shadow(color: Color(hex: 0x12A99A).opacity(0.35), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text("MacClean")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(AppTheme.textPrimary)
                    .fixedSize()
                Text(licenseCaption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .font(.system(size: 11, weight: license.status == .expired ? .semibold : .regular))
                    .foregroundColor(license.status == .expired ? AppTheme.warning : AppTheme.textMuted)
            }
            Spacer(minLength: 4)
            if license.status != .licensed {
                Button {
                    appState.showLicenseActivation = true
                } label: {
                    Text("升级")
                        .font(.system(size: 11, weight: .bold))
                        .fixedSize()
                        .foregroundColor(.white)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(AppTheme.brandGradient))
                        .shadow(color: Color(hex: 0x12A99A).opacity(0.3), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .help("解锁完整版")
            }
        }
    }

    private var licenseCaption: String {
        switch license.status {
        case .licensed: return String(localized: "完整版")
        case .trial: return String(localized: "试用剩余 \(license.trialDaysRemaining) 天")
        case .expired: return String(localized: "试用已结束")
        }
    }

    private func refreshFullDiskAccess() async {
        let granted = await Task.detached(priority: .utility) { FullDiskAccess.isGranted }.value
        withAnimation(CosmicAnimations.smooth) { fullDiskAccessGranted = granted }
    }

    private var fullDiskAccessCard: some View {
        Button {
            FullDiskAccess.openSettings()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text("授予完全磁盘访问权限")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                    Text("否则部分文件无法扫描")
                        .font(.system(size: 10.5))
                        .foregroundColor(AppTheme.textMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(AppTheme.textMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.warning.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(AppTheme.warning.opacity(0.25), lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sidebarRow(_ tab: AppTab) -> some View {
        SidebarNavRow(
            tab: tab,
            title: tab.localizedName,
            isSelected: tab == selectedTab
        ) {
            withAnimation(CosmicAnimations.smooth) {
                selectedTab = tab
            }
        }
    }

    private var diskCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(AppTheme.ink(0.10), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: CGFloat(Double(diskPercent) / 100.0))
                    .stroke(
                        diskPercent >= 90 ? AnyShapeStyle(AppTheme.danger) : AnyShapeStyle(AngularGradient(colors: [Color(hex: 0x15B985), Color(hex: 0x0E9BB5), Color(hex: 0x15B985)], center: .center)),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Text("\(diskPercent)%")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textPrimary)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(appState.diskInfo?.volumeName ?? "Macintosh HD")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(diskFreeText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(diskPercent >= 90 ? AppTheme.danger : AppTheme.accent)
                    .lineLimit(1)
                Text(diskUsageText)
                    .font(.system(size: 10.5))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .themeCard()
    }

    private var diskFreeText: String {
        guard let diskInfo = appState.diskInfo else { return String(localized: "正在读取…") }
        return String(localized: "可用 \(ByteCountFormatter.string(fromByteCount: diskInfo.freeSpace, countStyle: .file))")
    }

    private var diskPercent: Int {
        guard let diskInfo = appState.diskInfo else { return 0 }
        return Int(diskInfo.usedPercentage * 100)
    }

    private var diskUsageText: String {
        guard let diskInfo = appState.diskInfo else { return "" }
        let total = ByteCountFormatter.string(fromByteCount: diskInfo.totalSpace, countStyle: .file)
        return String(localized: "共 \(total)")
    }
}

// MARK: - 导航行

private struct SidebarNavRow: View {
    let tab: AppTab
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                GradientIconTile(systemName: tab.filledIcon, gradient: tab.tileGradient, size: 22, cornerRatio: 0.27, glyphRatio: 0.5, shadowColor: tab.tileShadow)
                    .saturation(isSelected || isHovered ? 1 : 0.85)

                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? AppTheme.textPrimary : AppTheme.textSecondary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 7)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? AppTheme.surfaceHover : (isHovered ? AppTheme.ink(0.05) : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(isSelected ? AppTheme.surfaceBorder : Color.clear, lineWidth: 1)
                    )
                    .shadow(color: isSelected ? AppTheme.cardShadow : .clear, radius: 4, y: 2)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}
