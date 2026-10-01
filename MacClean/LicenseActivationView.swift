//
//  LicenseActivationView.swift
//  MacClean
//
//  购买 / 激活许可证页（sheet），以及设置页「许可证」标签用的紧凑面板 LicenseStatusView。
//

import SwiftUI
import AppKit

// MARK: - 购买 / 激活 sheet

struct LicenseActivationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var license = LicenseManager.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AppBackdrop()

            VStack(spacing: 0) {
                // 已激活时内容较少，整体垂直居中
                if license.status == .licensed { Spacer(minLength: 0) }
                header
                    .padding(.top, 34)
                    .padding(.bottom, 22)

                if license.status == .licensed {
                    licensedContent
                } else {
                    purchaseContent
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 26)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(AppTheme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(AppTheme.ink(0.07)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("关闭")
            .padding(14)
        }
        .frame(width: 520, height: 560)
    }

    private var header: some View {
        VStack(spacing: 12) {
            GradientIconTile(systemName: "sparkles", size: 56)
            (license.status == .licensed ? Text("MacClean 完整版已激活") : Text("解锁 MacClean 完整版"))
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(AppTheme.textPrimary)
            LicenseStatusBadge()
        }
    }

    // MARK: 未激活

    private var purchaseContent: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                benefitRow("wand.and.stars", "清理、卸载、启动项与系统维护等全部操作")
                benefitRow("magnifyingglass", "扫描与浏览始终免费，可以先看清再决定")
                benefitRow("infinity", LocalizedStringKey(LicenseConfig.pricingHeadline), detail: LocalizedStringKey(LicenseConfig.pricingDetail))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .themeCard()

            Button {
                NSWorkspace.shared.open(LicenseConfig.purchaseURL)
            } label: {
                Label("购买许可证", systemImage: "cart.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NeonButtonStyle(isLarge: true))

            VStack(alignment: .leading, spacing: 8) {
                Text("已有许可证？")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.textMuted)
                LicenseKeyEntry()
            }
            .padding(.top, 4)
        }
    }

    private func benefitRow(_ icon: String, _ title: LocalizedStringKey, detail: LocalizedStringKey? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppTheme.accent)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AppTheme.accentSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(AppTheme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: 已激活

    private var licensedContent: some View {
        VStack(spacing: 18) {
            LicenseInfoGrid()
                .padding(18)
                .themeCard()

            Text("感谢支持！所有功能均已解锁。")
                .font(.system(size: 13))
                .foregroundColor(AppTheme.textSecondary)

            HStack(spacing: 10) {
                LicenseDeactivateButton()
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(NeonButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - 设置页紧凑面板

/// 设置窗口「许可证」标签：状态 + 激活 / 停用 + 购买。
struct LicenseStatusView: View {
    @ObservedObject private var license = LicenseManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                GradientIconTile(systemName: "sparkles", size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                LicenseStatusBadge()
            }

            if license.status == .licensed {
                LicenseInfoGrid()
                HStack {
                    Spacer()
                    LicenseDeactivateButton()
                }
            } else {
                LicenseKeyEntry()
                HStack {
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(LicenseConfig.purchaseURL)
                    } label: {
                        Label("购买许可证", systemImage: "cart.fill")
                    }
                    .buttonStyle(NeonButtonStyle())
                }
            }
        }
        .padding(20)
        .themeCard()
    }

    private var title: LocalizedStringKey {
        switch license.status {
        case .licensed: return "MacClean 完整版"
        case .trial: return "MacClean 试用版"
        case .expired: return "MacClean 免费版"
        }
    }

    private var subtitle: LocalizedStringKey {
        switch license.status {
        case .licensed:
            return "感谢支持！所有功能均已解锁。"
        case .trial:
            let end = license.trialEndDate?.formatted(date: .abbreviated, time: .omitted) ?? ""
            return "试用至 \(end)，期间所有功能均可使用。"
        case .expired:
            return "扫描与浏览仍然免费；清理、卸载等操作需要许可证。"
        }
    }
}

// MARK: - 共用组件

/// 「试用还剩 N 天」/「试用已结束」/「已激活 · 套餐」胶囊。
struct LicenseStatusBadge: View {
    @ObservedObject private var license = LicenseManager.shared

    var body: some View {
        let (icon, color) = style
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            text
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(color.opacity(0.13)))
    }

    private var style: (String, Color) {
        switch license.status {
        case .licensed: return ("checkmark.seal.fill", AppTheme.accent)
        case .trial: return ("clock.fill", AppTheme.sky)
        case .expired: return ("hourglass", AppTheme.warning)
        }
    }

    private var text: Text {
        switch license.status {
        case .licensed:
            if let plan = license.planName { return Text("已激活 · \(plan)") }
            return Text("已激活")
        case .trial:
            return Text("试用还剩 \(license.trialDaysRemaining) 天")
        case .expired:
            return Text("试用已结束")
        }
    }
}

/// 许可证密钥输入框 + 激活按钮 + 行内错误。
struct LicenseKeyEntry: View {
    @ObservedObject private var license = LicenseManager.shared
    @State private var key = ""
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if license.needsOnlineValidation {
                messageRow("wifi.exclamationmark", "许可证超过 \(LicenseConfig.offlineGraceDays) 天未能联网验证，请连接网络后重新验证。", color: AppTheme.warning) {
                    Button("重新验证") { Task { await license.revalidate() } }
                        .buttonStyle(NeonOutlineButtonStyle())
                        .disabled(license.isLoading)
                }
            } else if let notice = license.notice {
                messageRow("exclamationmark.triangle.fill", LocalizedStringKey(notice), color: AppTheme.warning) { EmptyView() }
            }

            HStack(spacing: 8) {
                TextField("粘贴许可证密钥，例如 XXXX-XXXX-XXXX-XXXX", text: $key)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(AppTheme.textPrimary)
                    .focused($focused)
                    .onSubmit(activate)
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: CosmicSizes.controlRadius, style: .continuous)
                            .fill(AppTheme.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: CosmicSizes.controlRadius, style: .continuous)
                                    .strokeBorder(focused ? AppTheme.accent.opacity(0.6) : AppTheme.surfaceBorder, lineWidth: 1)
                            )
                    )
                    .disabled(license.isLoading)

                Button(action: activate) {
                    ZStack {
                        Text("激活").opacity(license.isLoading ? 0 : 1)
                        if license.isLoading {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(minWidth: 40)
                }
                .buttonStyle(NeonOutlineButtonStyle())
                .disabled(license.isLoading || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .animation(CosmicAnimations.smooth, value: errorMessage)
        .onChange(of: key) { _, _ in errorMessage = nil }
    }

    private func activate() {
        guard !license.isLoading else { return }
        let input = key
        Task {
            do {
                try await license.activate(key: input)
                key = ""
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func messageRow<Trailing: View>(_ icon: String, _ text: LocalizedStringKey, color: Color, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: CosmicSizes.controlRadius, style: .continuous).fill(color.opacity(0.10)))
    }
}

/// 已激活许可证的信息表。
struct LicenseInfoGrid: View {
    @ObservedObject private var license = LicenseManager.shared

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            row("许可证") {
                Text(license.maskedKey ?? "—")
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
            }
            row("版本") { Text(license.planName ?? String(localized: "完整版")) }
            if let date = license.activatedAt {
                row("激活时间") { Text(date.formatted(date: .abbreviated, time: .shortened)) }
            }
            if let date = license.lastValidated {
                row("上次验证") { Text(date.formatted(.relative(presentation: .named))) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<Value: View>(_ label: LocalizedStringKey, @ViewBuilder value: () -> Value) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundColor(AppTheme.textMuted)
            value()
                .font(.system(size: 13))
                .foregroundColor(AppTheme.textPrimary)
        }
    }
}

/// 「在此 Mac 上停用」按钮（带确认和错误提示）。
struct LicenseDeactivateButton: View {
    @ObservedObject private var license = LicenseManager.shared
    @State private var confirming = false
    @State private var errorMessage: String?

    var body: some View {
        Button {
            confirming = true
        } label: {
            HStack(spacing: 6) {
                if license.isLoading { ProgressView().controlSize(.small) }
                Text("在此 Mac 上停用")
            }
        }
        .buttonStyle(NeonOutlineButtonStyle(color: AppTheme.danger))
        .disabled(license.isLoading)
        .alert("在此 Mac 上停用许可证？", isPresented: $confirming) {
            Button("停用", role: .destructive) {
                Task {
                    do { try await license.deactivate() } catch { errorMessage = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("停用后会释放一个激活名额，可以在另一台 Mac 上使用同一个许可证。")
        }
        .alert("停用失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}
