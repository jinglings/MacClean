//
//  OnboardingView.swift
//  MacClean
//
//  首次启动引导：欢迎 → 安全承诺 → 完全磁盘访问 → 通知 → 开始体检
//

import SwiftUI
import UserNotifications

enum OnboardingKeys {
    static let hasCompleted = "hasCompletedOnboarding"
}

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var scheduler = DiskAlertScheduler.shared
    @AppStorage(OnboardingKeys.hasCompleted) private var hasCompletedOnboarding = false
    @AppStorage(NotificationSettingsKey.lowDiskEnabled) private var lowDiskEnabled = true

    @State private var currentStep = 0
    @State private var fullDiskAccessGranted = FullDiskAccess.isGranted
    @State private var isRequestingNotifications = false

    private enum Step: Int, CaseIterable {
        case welcome, safety, fullDiskAccess, notifications, start
    }

    private var step: Step { Step(rawValue: currentStep) ?? .welcome }

    private func content(for step: Step) -> CosmicOnboardingStep {
        switch step {
        case .welcome:
            return CosmicOnboardingStep(
                icon: "sparkles",
                title: "欢迎使用 MacClean",
                description: "看清磁盘去向、清掉冗余文件，释放宝贵的存储空间。一次体检，两三分钟完成。",
                gradient: LinearGradient(colors: [Color(hex: 0x10B981), Color(hex: 0x0891B2)], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        case .safety:
            return CosmicOnboardingStep(
                icon: "arrow.uturn.backward.circle.fill",
                title: "删错了也能找回",
                description: "清理的文件都会先移入废纸篓，不会直接删除；需要时可在「清理记录」中一键恢复到原位置。扫描全部在本地完成，数据不会离开你的 Mac。",
                gradient: LinearGradient(colors: [Color(hex: 0x8E7CFF), Color(hex: 0x6247E8)], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        case .fullDiskAccess:
            return CosmicOnboardingStep(
                icon: "lock.open.fill",
                title: "完全磁盘访问权限",
                description: "邮件附件、Safari 缓存、部分应用数据受系统保护。授权后 MacClean 才能统计并清理这些位置，否则会被跳过。MacClean 只读取文件大小与日期，不读取内容。",
                gradient: LinearGradient(colors: [Color(hex: 0xF5B342), Color(hex: 0xE4801C)], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        case .notifications:
            return CosmicOnboardingStep(
                icon: "bell.badge.fill",
                title: "空间不够时提醒你",
                description: "启动盘可用空间低于 10 GB 时发一条通知，24 小时内最多一次。可随时在设置中调整阈值或关闭。",
                gradient: LinearGradient(colors: [Color(hex: 0x4C8DF6), Color(hex: 0x2A5FE0)], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        case .start:
            return CosmicOnboardingStep(
                icon: "checkmark.seal.fill",
                title: "准备就绪",
                description: "先做一次一键体检：缓存、重复文件、大文件和失效的登录项，一次看全。扫描只读取，不会删除任何东西。",
                gradient: LinearGradient(colors: [Color(hex: 0x33C7A0), Color(hex: 0x14A06F)], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
    }

    var body: some View {
        ZStack {
            AppBackdrop()

            VStack(spacing: 0) {
                CosmicOnboardingStepView(step: content(for: step)) {
                    accessory
                }
                .id(currentStep)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: 24)),
                    removal: .opacity
                ))
                .frame(height: 470)

                // 步骤指示器
                HStack(spacing: 14) {
                    ForEach(Step.allCases, id: \.rawValue) { item in
                        Capsule()
                            .fill(
                                item.rawValue == currentStep ?
                                    AnyShapeStyle(CosmicTheme.accentGradient) :
                                    AnyShapeStyle(AppTheme.ink(0.2))
                            )
                            .frame(width: item.rawValue == currentStep ? 24 : 7, height: 7)
                            .animation(CosmicAnimations.springy, value: currentStep)
                    }
                }
                .padding(.vertical, 16)

                Spacer()

                footer
                    .padding(.horizontal, 36)
                    .padding(.bottom, 32)
            }
        }
        .frame(width: 600, height: 640)
        .animation(.easeOut(duration: 0.25), value: currentStep)
        .task(id: currentStep) {
            // 停留在授权步骤时每 2 秒复查一次，用户在系统设置里勾选后立即反映
            guard step == .fullDiskAccess else { return }
            while !Task.isCancelled {
                fullDiskAccessGranted = await Task.detached(priority: .utility) { FullDiskAccess.isGranted }.value
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task { await scheduler.refreshAuthorizationStatus() }
    }

    // MARK: - 步骤附加内容

    @ViewBuilder
    private var accessory: some View {
        switch step {
        case .fullDiskAccess:
            if fullDiskAccessGranted {
                statusPill("已授权", icon: "checkmark.circle.fill", color: AppTheme.accent)
            } else {
                VStack(spacing: 10) {
                    Button {
                        FullDiskAccess.openSettings()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "gearshape.fill")
                            Text("打开系统设置")
                        }
                    }
                    .buttonStyle(NeonOutlineButtonStyle())
                    Text("在列表中打开 MacClean 的开关；授权后这里会自动显示 ✓")
                        .font(.system(size: 11.5))
                        .foregroundColor(AppTheme.textMuted)
                }
            }
        case .notifications:
            switch scheduler.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                statusPill(lowDiskEnabled ? "已开启提醒" : "通知已允许", icon: "checkmark.circle.fill", color: AppTheme.accent)
            case .denied:
                VStack(spacing: 10) {
                    statusPill("通知已被系统关闭", icon: "bell.slash.fill", color: AppTheme.warning)
                    Button("打开通知设置") { DiskAlertScheduler.openSystemNotificationSettings() }
                        .buttonStyle(NeonOutlineButtonStyle())
                }
            default:
                Button {
                    enableNotifications()
                } label: {
                    HStack(spacing: 8) {
                        if isRequestingNotifications {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "bell.fill")
                        }
                        Text("开启磁盘空间提醒")
                    }
                }
                .buttonStyle(NeonOutlineButtonStyle())
                .disabled(isRequestingNotifications)
            }
        default:
            EmptyView()
        }
    }

    private func statusPill(_ title: LocalizedStringKey, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(color.opacity(0.12)))
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    // MARK: - 底部按钮

    private var footer: some View {
        HStack(spacing: 16) {
            if currentStep > 0 {
                Button(action: { go(-1) }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.left")
                        Text("上一步")
                    }
                }
                .buttonStyle(NeonOutlineButtonStyle())
            }

            Spacer()

            if step == .start {
                Button("稍后再说") { finish() }
                    .buttonStyle(NeonOutlineButtonStyle())

                Button(action: {
                    finish()
                    appState.startSmartCareScan()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("开始一键体检")
                    }
                }
                .buttonStyle(NeonButtonStyle(isLarge: true))
            } else if step == .fullDiskAccess && !fullDiskAccessGranted {
                Button("稍后再说") { go(1) }
                    .buttonStyle(NeonOutlineButtonStyle())
            } else {
                Button(action: { go(1) }) {
                    HStack(spacing: 8) {
                        Text("下一步")
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(NeonButtonStyle())
            }
        }
    }

    private func go(_ delta: Int) {
        withAnimation(CosmicAnimations.springy) {
            currentStep = min(max(currentStep + delta, 0), Step.allCases.count - 1)
        }
    }

    private func enableNotifications() {
        isRequestingNotifications = true
        lowDiskEnabled = true
        Task {
            await scheduler.requestAuthorization()
            isRequestingNotifications = false
        }
    }

    private func finish() {
        hasCompletedOnboarding = true
        dismiss()
    }
}

// MARK: - 引导步骤模型
struct CosmicOnboardingStep {
    let icon: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let gradient: LinearGradient
}

// MARK: - 步骤视图
struct CosmicOnboardingStepView<Accessory: View>: View {
    let step: CosmicOnboardingStep
    @ViewBuilder let accessory: Accessory

    @State private var iconScale: CGFloat = 0.5
    @State private var iconOpacity: Double = 0
    @State private var textOpacity: Double = 0

    init(step: CosmicOnboardingStep, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.step = step
        self.accessory = accessory()
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // 图标区域
            ZStack {
                Circle()
                    .strokeBorder(AppTheme.ink(0.06), lineWidth: 1)
                    .frame(width: 190, height: 190)
                Circle()
                    .strokeBorder(AppTheme.ink(0.08), lineWidth: 1)
                    .frame(width: 144, height: 144)
                GradientIconTile(systemName: step.icon, gradient: step.gradient, size: 96, cornerRatio: 0.26, glyphRatio: 0.44, shadowColor: Color(hex: 0x2F6FE0))
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)
            }

            // 文字内容
            VStack(spacing: 12) {
                Text(step.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(AppTheme.textPrimary)

                Text(step.description)
                    .font(.system(size: 14))
                    .foregroundColor(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(textOpacity)

            accessory
                .opacity(textOpacity)
                .animation(.easeOut(duration: 0.2), value: textOpacity)

            Spacer()
        }
        .onAppear {
            animateIn()
        }
    }

    private func animateIn() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            iconScale = 1.0
            iconOpacity = 1.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.25)) {
                textOpacity = 1.0
            }
        }
    }
}

#Preview {
    OnboardingView()
        .environmentObject(AppState.shared)
}
