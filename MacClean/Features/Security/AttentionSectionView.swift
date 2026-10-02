//
//  AttentionSectionView.swift
//  MacClean
//
//  安全中心 · 值得留意：后台启动项、应用签名、描述文件、浏览器扩展。
//  结论只基于签名与位置等客观信息，附原因；「提示」类多数情况下没问题，单独列出。
//

import SwiftUI

struct AttentionSectionView: View {
    @ObservedObject var viewModel: SecurityCenterViewModel
    let onTrash: (PersistenceFinding) -> Void

    private static let loginItemsSettingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
    private static let profilesSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension")!

    private var result: SuspiciousScanResult? { viewModel.suspicious }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            summaryCard
            launchItemsSection
            appsSection
            profilesSection
            extensionsSection
        }
    }

    // MARK: - 汇总

    private var summaryCard: some View {
        HStack(alignment: .center, spacing: 14) {
            let calm = viewModel.attentionCount == 0
            Image(systemName: calm ? "checkmark.seal.fill" : "eye.fill")
                .font(.system(size: 22))
                .foregroundColor(calm ? AppTheme.accent : AppTheme.warning)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("值得留意 \(viewModel.attentionCount) 项 · 提示 \(viewModel.infoCount) 项")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text("已检查 \(result?.launchItemCount ?? 0) 个启动项、\(result?.appCount ?? 0) 个应用、\(viewModel.extensions.count) 个扩展")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textSecondary)
                Text("只根据签名、存放位置等客观信息给出提醒，并附上原因；是否处理由你决定。「提示」类多数情况下没有问题。")
                    .font(.system(size: 11.5))
                    .foregroundColor(AppTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .themeCard()
    }

    // MARK: - 后台启动项

    private var launchItemsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecuritySectionHeader(
                title: String(localized: "后台启动项"),
                count: viewModel.persistenceAttention.count,
                note: String(localized: "开机或登录后自动运行的程序。检查签名、存放位置，以及是否冒充系统组件。")
            )
            if viewModel.persistenceAttention.isEmpty {
                calmRow(String(localized: "\(result?.launchItemCount ?? 0) 个启动项都没有发现值得留意的地方"))
            } else {
                findingList(viewModel.persistenceAttention)
            }
            if !viewModel.persistenceInfo.isEmpty {
                InfoDisclosure(title: String(localized: "提示 \(viewModel.persistenceInfo.count) 项")) {
                    findingList(viewModel.persistenceInfo)
                }
            }
        }
    }

    private func findingList(_ findings: [PersistenceFinding]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(findings.enumerated()), id: \.element.id) { index, finding in
                if index > 0 { Divider().overlay(AppTheme.divider).padding(.leading, 60) }
                PersistenceRow(
                    finding: finding,
                    isBusy: viewModel.busyIDs.contains(finding.id),
                    onDisable: { viewModel.disable(finding) },
                    onTrash: { onTrash(finding) },
                    onOpenLoginItems: { NSWorkspace.shared.open(Self.loginItemsSettingsURL) }
                )
            }
        }
        .themeCard()
    }

    // MARK: - 应用

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                SecuritySectionHeader(
                    title: String(localized: "应用"),
                    count: viewModel.appsAttention.count,
                    note: String(localized: "检查「应用程序」文件夹里 \(result?.appCount ?? 0) 个应用的签名；只校验签名和主程序，不逐个校验资源文件。")
                )
                Spacer(minLength: 12)
                if !(result?.apps.isEmpty ?? true) {
                    Button {
                        viewModel.openAppManager()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 12, weight: .medium))
                            Text("在应用管家中查看")
                        }
                    }
                    .buttonStyle(NeonOutlineButtonStyle())
                }
            }
            revocationLine
            if viewModel.appsAttention.isEmpty {
                calmRow(String(localized: "没有发现未签名、签名无效或证书被吊销的应用"))
            } else {
                appList(viewModel.appsAttention)
            }
            if !viewModel.appsInfo.isEmpty {
                InfoDisclosure(title: String(localized: "提示 \(viewModel.appsInfo.count) 项")) {
                    appList(viewModel.appsInfo)
                }
            }
        }
    }

    @ViewBuilder
    private var revocationLine: some View {
        switch viewModel.revocation {
        case .idle:
            EmptyView()
        case .checking(let count):
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                Text("正在联网检查 \(count) 个应用的证书是否被吊销…")
            }
            .font(.system(size: 11.5))
            .foregroundColor(AppTheme.textMuted)
        case .done(let checked, let revoked):
            if checked > 0 {
                Label(revoked == 0
                      ? String(localized: "已联网检查 \(checked) 个应用的证书，都没有被吊销")
                      : String(localized: "已联网检查 \(checked) 个应用的证书，\(revoked) 个已被吊销"),
                      systemImage: "network")
                    .font(.system(size: 11.5))
                    .foregroundColor(AppTheme.textMuted)
            }
        case .incomplete(let checked):
            Label(String(localized: "网络不可用或响应太慢，证书吊销检查只完成了 \(checked) 个应用"), systemImage: "wifi.slash")
                .font(.system(size: 11.5))
                .foregroundColor(AppTheme.textMuted)
        }
    }

    private func appList(_ apps: [AppFinding]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                if index > 0 { Divider().overlay(AppTheme.divider).padding(.leading, 60) }
                AppFindingRow(app: app)
            }
        }
        .themeCard()
    }

    // MARK: - 描述文件

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                SecuritySectionHeader(
                    title: String(localized: "描述文件"),
                    count: viewModel.profiles.count,
                    note: String(localized: "描述文件可以改变代理、DNS、证书和浏览器设置，是广告软件劫持浏览器的常见手段。")
                )
                Spacer(minLength: 12)
                if !viewModel.profiles.isEmpty {
                    Button {
                        NSWorkspace.shared.open(Self.profilesSettingsURL)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 12, weight: .medium))
                            Text("在系统设置中查看")
                        }
                    }
                    .buttonStyle(NeonOutlineButtonStyle())
                }
            }
            if result?.profiles.couldNotCheck == true {
                calmRow(String(localized: "无法读取描述文件列表"), icon: "questionmark.circle", tint: AppTheme.textMuted)
            } else if viewModel.profiles.isEmpty {
                calmRow(String(localized: "没有安装描述文件"))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.profiles.enumerated()), id: \.element.id) { index, profile in
                        if index > 0 { Divider().overlay(AppTheme.divider).padding(.leading, 60) }
                        ProfileRow(profile: profile)
                    }
                }
                .themeCard()
            }
        }
    }

    // MARK: - 浏览器扩展

    private var extensionsSection: some View {
        let broad = viewModel.broadExtensions
        let others = viewModel.extensions.filter { !$0.hasBroadPermissions }
        return VStack(alignment: .leading, spacing: 10) {
            SecuritySectionHeader(
                title: String(localized: "浏览器扩展"),
                count: viewModel.extensions.count,
                note: String(localized: "Chrome、Edge、Brave、Firefox 与 Safari 中安装的扩展。")
            )
            if viewModel.extensions.isEmpty {
                calmRow(String(localized: "没有找到浏览器扩展"))
            } else {
                if !broad.isEmpty {
                    Label("「权限较大」的扩展可以读取所有网站的内容，并能拦截或转发网络请求。广告拦截、翻译、开发工具类扩展需要这些权限是正常的；不认识的扩展建议在浏览器中移除。", systemImage: "info.circle")
                        .font(.system(size: 11.5))
                        .foregroundColor(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    extensionList(broad)
                }
                if !others.isEmpty {
                    InfoDisclosure(title: String(localized: "其他 \(others.count) 个扩展")) {
                        extensionList(others)
                    }
                }
            }
        }
    }

    private func extensionList(_ extensions: [BrowserExtension]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(extensions.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().overlay(AppTheme.divider).padding(.leading, 16) }
                ExtensionRow(item: item)
            }
        }
        .themeCard()
    }

    private func calmRow(_ text: String, icon: String = "checkmark.circle.fill", tint: Color = AppTheme.accent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(tint)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundColor(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .themeCard()
    }
}

// MARK: - 可展开的「提示」分组

private struct InfoDisclosure<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: "info.circle")
                        .font(.system(size: 11.5))
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundColor(AppTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                content
            }
        }
    }
}

// MARK: - 理由列表

private struct ReasonList: View {
    let reasons: [FindingReason]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(reasons, id: \.self) { reason in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Circle()
                        .fill(reason.severity == .attention ? AppTheme.warning : AppTheme.textMuted)
                        .frame(width: 5, height: 5)
                        .offset(y: -1)
                    Text(String(localized: "\(reason.title)：\(reason.explanation)"))
                        .font(.system(size: 11.5))
                        .foregroundColor(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - 启动项行

private struct PersistenceRow: View {
    let finding: PersistenceFinding
    let isBusy: Bool
    let onDisable: () -> Void
    let onTrash: () -> Void
    let onOpenLoginItems: () -> Void

    private var item: LaunchItem { finding.item }

    private var kindLabel: String {
        switch item.kind {
        case .userAgent: return String(localized: "当前用户的启动代理")
        case .globalAgent: return String(localized: "系统级启动代理")
        case .globalDaemon: return String(localized: "系统级守护进程")
        case .loginApp: return String(localized: "登录时打开")
        case .appService: return String(localized: "应用后台服务")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.textPrimary)
                        .lineLimit(1)
                    SecurityBadge(title: kindLabel, tint: AppTheme.textSecondary)
                    if item.isDisabled {
                        SecurityBadge(title: String(localized: "已停用"), tint: AppTheme.textMuted)
                    }
                }
                Text(item.label)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let path = finding.executable ?? item.detailPath {
                    Text(securityShortPath(path))
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                ReasonList(reasons: finding.reasons)
                    .padding(.top, 2)
                if !item.isEditable, item.kind == .globalAgent || item.kind == .globalDaemon {
                    Label("系统级项目对所有用户生效，修改需要管理员权限，这里只读显示。不认识的话，可以在 Finder 中查看它属于哪个软件。", systemImage: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().scaleEffect(0.55).frame(width: 20, height: 20)
                }
                if let path = item.revealPath {
                    SecurityIconButton(systemName: "magnifyingglass", help: String(localized: "在 Finder 中显示")) {
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    }
                }
                if item.isEditable {
                    if !item.isDisabled {
                        Button("停用", action: onDisable)
                            .buttonStyle(NeonOutlineButtonStyle())
                            .disabled(isBusy)
                            .help("停用后不再自动运行，可在「启动项」中重新开启")
                    }
                    Button("移到废纸篓", action: onTrash)
                        .buttonStyle(NeonOutlineButtonStyle(color: AppTheme.danger))
                        .disabled(isBusy)
                } else if item.kind == .loginApp || item.kind == .appService {
                    Button("在系统设置中管理", action: onOpenLoginItems)
                        .buttonStyle(NeonOutlineButtonStyle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contextMenu {
            if let path = item.revealPath {
                Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
            }
            if let path = finding.executable ?? item.detailPath {
                Button("拷贝路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let appPath = item.appPath {
            Image(nsImage: AppLookup.fileIcon(path: appPath))
                .resizable()
                .frame(width: 32, height: 32)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.ink(0.06))
                .overlay(
                    Image(systemName: item.kind == .globalDaemon ? "gearshape.2" : "gearshape")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(AppTheme.textSecondary)
                )
                .frame(width: 32, height: 32)
        }
    }
}

// MARK: - 应用行

private struct AppFindingRow: View {
    let app: AppFinding

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: AppLookup.fileIcon(path: app.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppTheme.textPrimary)
                Text(securityShortPath(app.path))
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ReasonList(reasons: app.reasons)
                    .padding(.top, 2)
            }
            Spacer(minLength: 12)
            SecurityIconButton(systemName: "magnifyingglass", help: String(localized: "在 Finder 中显示")) {
                NSWorkspace.shared.selectFile(app.path, inFileViewerRootedAtPath: "")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - 描述文件行

private struct ProfileRow: View {
    let profile: ConfigurationProfile

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.warning.opacity(0.12))
                .overlay(
                    Image(systemName: "doc.badge.gearshape")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(AppTheme.warning)
                )
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.identifier)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.textPrimary)
                        .textSelection(.enabled)
                    SecurityBadge(
                        title: profile.isComputerLevel ? String(localized: "对整台电脑生效") : String(localized: "当前用户"),
                        tint: AppTheme.textSecondary
                    )
                }
                ReasonList(reasons: [.configurationProfile])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - 扩展行

private struct ExtensionRow: View {
    let item: BrowserExtension

    @State private var isHovered = false

    private var source: String {
        [item.browser, item.profile, item.version.map { "v" + $0 }].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(item.isActive ? AppTheme.textPrimary : AppTheme.textSecondary)
                        .lineLimit(1)
                    if item.hasBroadPermissions {
                        SecurityBadge(title: String(localized: "权限较大"), tint: AppTheme.textSecondary)
                    }
                    if !item.isActive {
                        SecurityBadge(title: String(localized: "已停用"), tint: AppTheme.textMuted)
                    }
                }
                Text(source)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if let path = item.path {
                SecurityIconButton(systemName: "magnifyingglass", help: String(localized: "在 Finder 中显示")) {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
                .opacity(isHovered ? 1 : 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isHovered ? AppTheme.surfaceHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
