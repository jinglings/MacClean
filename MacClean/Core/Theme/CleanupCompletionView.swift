//
//  CleanupCompletionView.swift
//  MacClean
//
//  清理完成视图 & 共享控件（按钮样式、卡片、进度组件）。
//  石墨 + 薄荷设计系统：动效只表达状态，一次性弹入，无循环发光。
//

import SwiftUI

// MARK: - 清理完成视图
struct CleanupCompletionView: View {
    let cleanedSize: Int64
    let cleanedCount: Int
    /// 清空废纸篓永久释放的空间（立即生效、不可恢复）。
    var permanentlyFreed: Int64 = 0
    /// 失败/跳过的项目数（权限不足、受保护路径等）。
    var failedCount: Int = 0
    /// 非 nil 时显示「撤销」按钮，把本次移入废纸篓的项目放回原处。
    var onUndo: (() -> Void)? = nil
    let onDismiss: () -> Void

    @State private var showCheckmark = false
    @State private var showStats = false

    var body: some View {
        ZStack {
            AppTheme.primaryGradient
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(AppTheme.accentSoft)
                        .frame(width: 136, height: 136)
                    Circle()
                        .fill(AppTheme.accentSoft)
                        .frame(width: 108, height: 108)
                    Circle()
                        .fill(AppTheme.brandGradient)
                        .frame(width: 80, height: 80)
                        .shadow(color: Color(hex: 0x12A99A).opacity(0.4), radius: 16, y: 8)
                    Image(systemName: "checkmark")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
                }
                .scaleEffect(showCheckmark ? 1 : 0.6)
                .opacity(showCheckmark ? 1 : 0)

                VStack(spacing: 14) {
                    Text("清理完成")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                        .padding(.top, 32)

                    if cleanedSize > 0 || permanentlyFreed == 0 {
                        HStack(spacing: 6) {
                            Text("已移入废纸篓")
                                .font(.system(size: 15))
                                .foregroundColor(AppTheme.textSecondary)
                            Text(ByteCountFormatter.string(fromByteCount: cleanedSize, countStyle: .file))
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(AppTheme.accent)
                        }
                    }

                    if permanentlyFreed > 0 {
                        HStack(spacing: 6) {
                            Text("已永久释放")
                                .font(.system(size: 15))
                                .foregroundColor(AppTheme.textSecondary)
                            Text(ByteCountFormatter.string(fromByteCount: permanentlyFreed, countStyle: .file))
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(AppTheme.accent)
                        }
                    }

                    Text(footnote)
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 48)
                }
                .opacity(showStats ? 1 : 0)
                .offset(y: showStats ? 0 : 10)

                Spacer()

                HStack(spacing: 12) {
                    if let onUndo, cleanedSize > 0 {
                        Button {
                            onUndo()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.uturn.backward")
                                Text("撤销")
                            }
                        }
                        .buttonStyle(NeonOutlineButtonStyle())
                    }
                    Button("完成", action: onDismiss)
                        .buttonStyle(NeonButtonStyle(isLarge: true))
                }
                .opacity(showStats ? 1 : 0)
                .padding(.bottom, 44)
            }
        }
        .frame(width: 480, height: 460)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showCheckmark = true
            }
            withAnimation(.easeOut(duration: 0.25).delay(0.2)) {
                showStats = true
            }
        }
    }

    private var footnote: String {
        var parts = [String(localized: "共 \(cleanedCount) 个项目")]
        if cleanedSize > 0 {
            parts.append(String(localized: "可在「清理记录」中一键恢复，清空废纸篓后才会真正释放这部分空间"))
        }
        if failedCount > 0 {
            parts.append(String(localized: "\(failedCount) 项因权限或保护规则被跳过"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - ===== 共享控件 =====

// MARK: - 主按钮（品牌渐变填充、白色文字）
struct NeonButtonStyle: ButtonStyle {
    let gradient: LinearGradient
    let isLarge: Bool
    init(gradient: LinearGradient = AppTheme.buttonGradient, isLarge: Bool = false) {
        self.gradient = gradient
        self.isLarge = isLarge
    }
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, gradient: gradient, isLarge: isLarge)
    }

    private struct PrimaryButtonBody: View {
        let configuration: Configuration
        let gradient: LinearGradient
        let isLarge: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            let radius: CGFloat = isLarge ? 11 : CosmicSizes.controlRadius
            configuration.label
                .font(.system(size: isLarge ? 15 : 13, weight: .semibold))
                .foregroundColor(AppTheme.onAccent)
                .padding(.horizontal, isLarge ? 30 : 18)
                .frame(height: isLarge ? 44 : 32)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(gradient)
                        .overlay(
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(LinearGradient(colors: [Color.white.opacity(0.12), Color.white.opacity(0)], startPoint: .top, endPoint: .center))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                        )
                        .brightness(configuration.isPressed ? -0.06 : (isHovered ? 0.04 : 0))
                )
                .shadow(color: Color(hex: 0x12A99A).opacity(isEnabled ? (isLarge ? 0.35 : 0.22) : 0), radius: isLarge ? 12 : 6, y: isLarge ? 6 : 3)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: isHovered)
        }
    }
}

// MARK: - 次要按钮（中性填充 + 描边）
struct NeonOutlineButtonStyle: ButtonStyle {
    let color: Color
    init(color: Color = AppTheme.textPrimary) { self.color = color }
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration, color: color)
    }

    private struct SecondaryButtonBody: View {
        let configuration: Configuration
        let color: Color
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(color)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: CosmicSizes.controlRadius, style: .continuous)
                        .fill(configuration.isPressed ? AppTheme.ink(0.10) : (isHovered ? AppTheme.surfaceHover : AppTheme.surface))
                        .overlay(
                            RoundedRectangle(cornerRadius: CosmicSizes.controlRadius, style: .continuous)
                                .strokeBorder(AppTheme.surfaceBorder, lineWidth: 1)
                        )
                        .shadow(color: AppTheme.cardShadow.opacity(0.6), radius: 2, y: 1)
                )
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.15), value: isHovered)
        }
    }
}
