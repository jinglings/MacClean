//
//  SecurityCenterView.swift
//  MacClean
//
//  安全中心：系统防护体检、应用权限、值得留意的后台程序 / 应用 / 描述文件 / 浏览器扩展。
//  只检查、不打分；每条结论附原因与建议，修改都跳转到系统设置或由用户确认后执行。
//

import SwiftUI

struct SecurityCenterView: View {
    @ObservedObject private var viewModel = SecurityCenterViewModel.shared

    @State private var pendingTrash: PersistenceFinding?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: String(localized: "安全中心"),
                subtitle: String(localized: "检查 macOS 自带防护是否开启、哪些应用拿到了敏感权限、有没有来路不明的后台程序")
            ) {
                HStack(spacing: 8) {
                    LastScannedLabel(date: viewModel.lastScannedAt)
                    ScanButton(hasScanned: viewModel.hasScanned, isScanning: viewModel.isScanning) { viewModel.scan() }
                }
            }

            if !viewModel.hasScanned {
                ScrollView {
                    ScanIntroView(
                        icon: "lock.shield",
                        title: String(localized: "检查这台 Mac 的安全状况"),
                        message: String(localized: "读取系统设置、隐私授权记录和后台程序的签名信息，几秒到半分钟即可完成。"),
                        points: [
                            String(localized: "系统防护是否开启"),
                            String(localized: "哪些应用能访问摄像头、麦克风、屏幕"),
                            String(localized: "来路不明或签名有问题的后台程序"),
                            String(localized: "只检查不修改，结论附原因"),
                        ],
                        buttonTitle: viewModel.isScanning ? String(localized: "正在检查…") : String(localized: "开始安全检查"),
                        footnote: String(localized: "检查只读取信息，不会改动任何设置或文件"),
                        action: { viewModel.scan() }
                    )
                    .disabled(viewModel.isScanning)
                    .padding(.horizontal, CosmicSizes.pagePadding)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                }
            } else {
                content
            }
        }
        .alert("将启动项移到废纸篓？", isPresented: Binding(
            get: { pendingTrash != nil },
            set: { if !$0 { pendingTrash = nil } }
        )) {
            Button("取消", role: .cancel) { pendingTrash = nil }
            Button("移到废纸篓", role: .destructive) {
                guard let target = pendingTrash else { return }
                pendingTrash = nil
                Task { await viewModel.moveToTrash(target) }
            }
        } message: {
            if let item = pendingTrash?.item {
                Text("「\(item.displayName)」的配置文件将移入废纸篓，以后不会再自动运行；它指向的程序不会被删除。可随时撤销。")
            }
        }
    }

    private func confirmTrash(_ finding: PersistenceFinding) {

        pendingTrash = finding
    }

    // MARK: - 结果

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let banner = viewModel.banner {
                    SecurityBannerView(banner: banner, onUndo: { id in
                        Task { await viewModel.undo(sessionID: id) }
                    }, onClose: { viewModel.banner = nil })
                }

                sectionPicker

                switch viewModel.section {
                case .protection:
                    ProtectionSectionView(viewModel: viewModel)
                case .permissions:
                    PermissionsSectionView(viewModel: viewModel)
                case .attention:
                    AttentionSectionView(viewModel: viewModel, onTrash: confirmTrash)
                }
            }
            .padding(.horizontal, CosmicSizes.pagePadding)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
    }

    // MARK: - 三个分区（同时充当摘要卡）

    private var sectionPicker: some View {
        HStack(spacing: 12) {
            SectionTab(
                icon: "shield.lefthalf.filled",
                title: String(localized: "系统防护"),
                summary: protectionSummary,
                flagged: viewModel.protectionAttentionCount,
                isSelected: viewModel.section == .protection
            ) { viewModel.section = .protection }

            SectionTab(
                icon: "hand.raised.fill",
                title: String(localized: "应用权限"),
                summary: permissionsSummary,
                flagged: viewModel.permissions.attentionClients.count,
                isSelected: viewModel.section == .permissions
            ) { viewModel.section = .permissions }

            SectionTab(
                icon: "eye.fill",
                title: String(localized: "值得留意"),
                summary: String(localized: "值得留意 \(viewModel.attentionCount) 项 · 提示 \(viewModel.infoCount) 项"),
                flagged: viewModel.attentionCount,
                isSelected: viewModel.section == .attention
            ) { viewModel.section = .attention }
        }
    }

    private var protectionSummary: String {
        let total = viewModel.protection.count
        var text = String(localized: "\(total) 项中 \(viewModel.protectionGoodCount) 项正常")
        if viewModel.protectionUnknownCount > 0 {
            text += String(localized: " · \(viewModel.protectionUnknownCount) 项无法检测")
        }
        return text
    }

    private var permissionsSummary: String {
        if viewModel.permissions.needsFullDiskAccess { return String(localized: "需要完全磁盘访问权限") }
        return String(localized: "\(viewModel.permissions.thirdPartyClientCount) 个应用拿到了敏感权限")
    }
}

// MARK: - 分区标签

private struct SectionTab: View {
    let icon: String
    let title: String
    let summary: String
    let flagged: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                let palette = AppTheme.groupPalette(for: icon)
                GradientIconTile(systemName: icon, gradient: palette.gradient, size: 34, cornerRatio: 0.27, glyphRatio: 0.44, shadowColor: palette.shadow)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppTheme.textPrimary)
                        if flagged > 0 {
                            Text("\(flagged)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(AppTheme.warning)
                                .padding(.horizontal, 6)
                                .frame(height: 17)
                                .background(Capsule().fill(AppTheme.warning.opacity(0.14)))
                        }
                    }
                    Text(summary)
                        .font(.system(size: 11.5))
                        .foregroundColor(AppTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themeCard(isHovered: isHovered || isSelected)
            .overlay(
                RoundedRectangle(cornerRadius: CosmicSizes.cardRadius, style: .continuous)
                    .strokeBorder(isSelected ? AppTheme.accent.opacity(0.7) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - 系统防护

private struct ProtectionSectionView: View {
    @ObservedObject var viewModel: SecurityCenterViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecuritySectionHeader(
                title: String(localized: "系统防护"),
                count: nil,
                note: String(localized: "这些都是 macOS 自带的防护，只读取状态，不做任何修改。")
            )
            LazyVStack(spacing: 0) {
                ForEach(Array(viewModel.protection.enumerated()), id: \.element.id) { index, check in
                    if index > 0 {
                        Divider().overlay(AppTheme.divider).padding(.leading, 60)
                    }
                    ProtectionRow(check: check) { viewModel.openSettings(check.kind.settingsURLs) }
                }
            }
            .themeCard()
        }
    }
}

private struct ProtectionRow: View {
    let check: ProtectionCheck
    let onOpenSettings: () -> Void

    private var tint: Color {
        switch check.health {
        case .good: return AppTheme.accent
        case .attention: return AppTheme.warning
        case .unknown: return AppTheme.textMuted
        }
    }

    private var statusIcon: String {
        switch check.health {
        case .good: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.12))
                .overlay(
                    Image(systemName: check.kind.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(tint)
                )
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(check.kind.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                    HStack(spacing: 4) {
                        Image(systemName: statusIcon)
                            .font(.system(size: 11))
                        Text(check.state)
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundColor(tint)
                    .padding(.horizontal, 7)
                    .frame(height: 19)
                    .background(Capsule().fill(tint.opacity(0.12)))
                    .fixedSize()
                }
                Text(check.kind.why)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = check.detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundColor(AppTheme.textMuted)
                        .textSelection(.enabled)
                }
                if let advice = check.advice {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 10.5))
                        Text(advice)
                            .font(.system(size: 11.5))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .foregroundColor(AppTheme.textSecondary)
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 12)

            if check.health != .good, !check.kind.settingsURLs.isEmpty {
                Button(action: onOpenSettings) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12, weight: .medium))
                        Text("打开系统设置")
                    }
                }
                .buttonStyle(NeonOutlineButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

// MARK: - 共用小组件

struct SecuritySectionHeader: View {
    let title: String
    let count: Int?
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(AppTheme.textMuted)
                }
            }
            Text(note)
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SecurityBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(tint)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Capsule().fill(tint.opacity(0.12)))
            .fixedSize()
    }
}

/// 行尾的小图标按钮（在 Finder 中显示等）
struct SecurityIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textSecondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AppTheme.ink(0.05)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct SecurityBannerView: View {
    let banner: SecurityCenterViewModel.Banner
    let onUndo: (UUID) -> Void
    let onClose: () -> Void

    private var tint: Color { banner.style == .error ? AppTheme.danger : AppTheme.accent }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.style == .error ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(tint)
            Text(banner.message)
                .font(.system(size: 12.5))
                .foregroundColor(AppTheme.textPrimary)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let sessionID = banner.undoSessionID {
                Button("撤销") { onUndo(sessionID) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(AppTheme.accent)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AppTheme.textMuted)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(tint.opacity(0.25), lineWidth: 1)
                )
        )
    }
}

/// 主目录缩写成 ~
func securityShortPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}
