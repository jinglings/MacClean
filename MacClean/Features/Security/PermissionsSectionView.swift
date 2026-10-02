//
//  PermissionsSectionView.swift
//  MacClean
//
//  安全中心 · 应用权限：按权限分组列出已获授权的应用。
//  只读展示；撤销授权只能由用户在系统设置中操作。
//

import SwiftUI

struct PermissionsSectionView: View {
    @ObservedObject var viewModel: SecurityCenterViewModel

    private var report: PermissionsReport { viewModel.permissions }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SecuritySectionHeader(
                title: String(localized: "应用权限"),
                count: report.needsFullDiskAccess ? nil : report.thirdPartyClientCount,
                note: String(localized: "只列出已允许的授权。macOS 只允许你在「系统设置」中撤销权限，MacClean 只读取，不会也无法修改任何授权。")
            )

            if report.needsFullDiskAccess {
                fullDiskAccessCard
            } else {
                if report.isPartial {
                    Label("只读到了部分授权记录，列表可能不完整", systemImage: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                }
                if report.groups.isEmpty {
                    Text("没有应用获得这些权限")
                        .font(.system(size: 12.5))
                        .foregroundColor(AppTheme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .themeCard()
                }
                ForEach(report.groups) { group in
                    PermissionGroupCard(group: group)
                }
            }
        }
    }

    private var fullDiskAccessCard: some View {
        HStack(alignment: .center, spacing: 14) {
            GradientIconTile(systemName: "internaldrive.fill", gradient: AppTheme.warningGradient, size: 40, cornerRatio: 0.27, glyphRatio: 0.42, shadowColor: AppTheme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text("需要完全磁盘访问权限")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text("应用的隐私授权记录受 macOS 保护。授予 MacClean 完全磁盘访问权限后，才能列出哪些应用拿到了摄像头、麦克风、屏幕录制等权限。授权后点「重新扫描」。")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(spacing: 8) {
                Button("前往授权") { FullDiskAccess.openSettings() }
                    .buttonStyle(NeonButtonStyle())
                Button("重新扫描") { viewModel.scan() }
                    .buttonStyle(NeonOutlineButtonStyle())
                    .disabled(viewModel.isScanning)
            }
        }
        .padding(16)
        .themeCard()
    }
}

// MARK: - 一个权限分组

private struct PermissionGroupCard: View {
    let group: PermissionGroup

    @State private var showAll = false
    @State private var showApple = false

    private static let collapsedLimit = 5

    private var visibleClients: [PermissionClient] {
        showAll ? group.clients : Array(group.clients.prefix(Self.collapsedLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            ForEach(visibleClients) { client in
                Divider().overlay(AppTheme.divider).padding(.leading, 60)
                PermissionClientRow(client: client, service: group.service)
            }

            if group.clients.count > Self.collapsedLimit {
                Divider().overlay(AppTheme.divider)
                footerButton(showAll ? String(localized: "收起") : String(localized: "显示全部 \(group.clients.count) 个应用"), expanded: showAll) {
                    withAnimation(.easeOut(duration: 0.2)) { showAll.toggle() }
                }
            }

            if !group.appleClients.isEmpty {
                Divider().overlay(AppTheme.divider)
                footerButton(String(localized: "系统组件 \(group.appleClients.count) 个"), expanded: showApple) {
                    withAnimation(.easeOut(duration: 0.2)) { showApple.toggle() }
                }
                if showApple {
                    ForEach(group.appleClients) { client in
                        Divider().overlay(AppTheme.divider).padding(.leading, 60)
                        PermissionClientRow(client: client, service: group.service)
                    }
                }
            }
        }
        .themeCard()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            let palette = AppTheme.groupPalette(for: group.service.rawValue)
            GradientIconTile(systemName: group.service.icon, gradient: palette.gradient, size: 32, cornerRatio: 0.27, glyphRatio: 0.44, shadowColor: palette.shadow)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.service.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                    Text("\(group.clients.count)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(AppTheme.textMuted)
                    if group.attentionCount > 0 {
                        SecurityBadge(title: String(localized: "值得留意 \(group.attentionCount)"), tint: AppTheme.warning)
                    }
                    if group.staleCount > 0 {
                        SecurityBadge(title: String(localized: "已失效 \(group.staleCount)"), tint: AppTheme.textMuted)
                            .help(String(localized: "这些授权对应的应用在本机已找不到，可能已经卸载。授权已经没用了，可以在系统设置中移除。"))
                    }
                }
                Text(group.service.explanation)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
            }
            Spacer(minLength: 12)
            Button {
                NSWorkspace.shared.open(group.service.settingsURL)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                    Text("在系统设置中管理")
                }
            }
            .buttonStyle(NeonOutlineButtonStyle())
        }
    }

    private func footerButton(_ title: String, expanded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(AppTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 一个获得授权的应用

private struct PermissionClientRow: View {
    let client: PermissionClient
    let service: PermissionService

    @State private var isHovered = false

    private var subtitle: String {
        var parts: [String] = []
        if !client.details.isEmpty {
            parts.append(service == .automation
                ? String(localized: "可控制：\(client.details.joined(separator: "、"))")
                : client.details.joined(separator: "、"))
        }
        if client.isMissing {
            parts.append(String(localized: "本机已找不到这个应用，授权已失效，可以在系统设置中移除"))
        } else {
            parts.append(client.isPath ? securityShortPath(client.client) : client.client)
        }
        return parts.joined(separator: " · ")
    }

    private var attentionNote: String? {
        if client.signatureProblem != nil {
            return String(localized: "无法通过签名确认这个程序的来源，也无法确认它没有被改动过。如果不认识它，建议在系统设置中关闭这项权限。")
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(client.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(client.isMissing ? AppTheme.textSecondary : AppTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if client.isMissing {
                        SecurityBadge(title: String(localized: "应用已不存在"), tint: AppTheme.textMuted)
                    }
                    if let problem = client.signatureProblem {
                        SecurityBadge(title: problem, tint: AppTheme.warning)
                    }
                    if client.isLimited {
                        SecurityBadge(title: String(localized: "部分允许"), tint: AppTheme.textSecondary)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let attentionNote {
                    Text(attentionNote)
                        .font(.system(size: 11.5))
                        .foregroundColor(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .help(client.path ?? client.client)

            Spacer(minLength: 12)

            if let date = client.lastModified {
                Text("授权于 \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .fixedSize()
            }
            if let path = client.path {
                SecurityIconButton(systemName: "magnifyingglass", help: String(localized: "在 Finder 中显示")) {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
                .opacity(isHovered ? 1 : 0)
            } else {
                // 与有按钮的行对齐日期列
                Color.clear.frame(width: 26, height: 26)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(isHovered ? AppTheme.surfaceHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            if let path = client.path {
                Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
            }
            Button("拷贝标识") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(client.client, forType: .string)
            }
            Button("在系统设置中管理") { NSWorkspace.shared.open(service.settingsURL) }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let path = client.path {
            Image(nsImage: AppLookup.fileIcon(path: path))
                .resizable()
                .frame(width: 32, height: 32)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.ink(0.06))
                .overlay(
                    Image(systemName: "questionmark.app.dashed")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(AppTheme.textMuted)
                )
                .frame(width: 32, height: 32)
        }
    }
}
