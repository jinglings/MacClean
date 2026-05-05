//
//  OnboardingView.swift
//  MacClean
//
//  宇宙主题首次使用引导视图 (原名 CosmicOnboardingView)
//

import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentStep = 0
    
    private let steps = [
        CosmicOnboardingStep(
            icon: "atom",
            title: "欢迎使用 MacClean",
            description: "MacClean 帮助您分析磁盘使用情况，清理不必要的文件，释放宝贵的存储空间。",
            gradient: LinearGradient(colors: [CosmicTheme.accentCyan, CosmicTheme.accentPurple], startPoint: .leading, endPoint: .trailing)
        ),
        CosmicOnboardingStep(
            icon: "waveform.circle.fill",
            title: "智能扫描",
            description: "深度分析您的磁盘空间，可视化展示使用情况，快速发现占用空间的大文件。",
            gradient: LinearGradient(colors: [CosmicTheme.accentCyan, Color(hex: 0x5B8DEF)], startPoint: .leading, endPoint: .trailing)
        ),
        CosmicOnboardingStep(
            icon: "sparkles",
            title: "一键清理",
            description: "安全清理用户缓存、浏览器缓存和开发工具缓存，每个文件都会说明为何可以安全删除。",
            gradient: LinearGradient(colors: [Color(hex: 0xFF9F43), Color(hex: 0xF7B236)], startPoint: .leading, endPoint: .trailing)
        ),
        CosmicOnboardingStep(
            icon: "lock.shield.fill",
            title: "隐私优先",
            description: "所有操作都在本地完成，您的数据永远不会离开您的 Mac。无需账户，无需网络。",
            gradient: LinearGradient(colors: [CosmicTheme.accentPurple, CosmicTheme.accentPink], startPoint: .leading, endPoint: .trailing)
        ),
        CosmicOnboardingStep(
            icon: "folder.badge.questionmark",
            title: "权限说明",
            description: "为了扫描和清理缓存文件，MacClean 需要访问部分目录。我们会在需要时请求您的授权。",
            gradient: LinearGradient(colors: [Color(hex: 0xFF6B6B), Color(hex: 0xEE5253)], startPoint: .leading, endPoint: .trailing)
        )
    ]
    
    var body: some View {
        ZStack {
            // 深色渐变背景
            CosmicTheme.primaryGradient
                .ignoresSafeArea()
            
            // 星空背景
            StarfieldBackgroundView()
            
            // 流动背景
            CosmicFlowBackground()
                .opacity(0.4)
            
            VStack(spacing: 0) {
                // 内容区域
                TabView(selection: $currentStep) {
                    ForEach(0..<steps.count, id: \.self) { index in
                        CosmicOnboardingStepView(step: steps[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(.automatic)
                .frame(height: 400)
                
                // 步骤指示器
                HStack(spacing: 14) {
                    ForEach(0..<steps.count, id: \.self) { index in
                        Capsule()
                            .fill(
                                index == currentStep ?
                                    AnyShapeStyle(CosmicTheme.accentGradient) :
                                    AnyShapeStyle(Color.white.opacity(0.2))
                            )
                            .frame(width: index == currentStep ? 28 : 8, height: 8)
                            .animation(CosmicAnimations.springy, value: currentStep)
                    }
                }
                .padding(.vertical, 20)
                
                Spacer()
                
                // 底部按钮
                HStack(spacing: 16) {
                    if currentStep > 0 {
                        Button(action: {
                            withAnimation(CosmicAnimations.springy) {
                                currentStep -= 1
                            }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.left")
                                Text("上一步")
                            }
                        }
                        .buttonStyle(NeonOutlineButtonStyle())
                    }
                    
                    Spacer()
                    
                    if currentStep < steps.count - 1 {
                        Button(action: {
                            withAnimation(CosmicAnimations.springy) {
                                currentStep += 1
                            }
                        }) {
                            HStack(spacing: 8) {
                                Text("下一步")
                                Image(systemName: "arrow.right")
                            }
                        }
                        .buttonStyle(NeonButtonStyle())
                    } else {
                        Button(action: {
                            dismiss()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                Text("开始使用")
                            }
                        }
                        .buttonStyle(NeonButtonStyle(isLarge: true))
                    }
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 36)
            }
        }
        .frame(width: 600, height: 600)
    }
}

// MARK: - 引导步骤模型
struct CosmicOnboardingStep {
    let icon: String
    let title: String
    let description: String
    let gradient: LinearGradient
}

// MARK: - 步骤视图
struct CosmicOnboardingStepView: View {
    let step: CosmicOnboardingStep
    
    @State private var iconScale: CGFloat = 0.5
    @State private var iconOpacity: Double = 0
    @State private var textOpacity: Double = 0
    @State private var showPulse: Bool = false
    @State private var floatOffset: CGFloat = 0
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // 图标区域
            ZStack {
                // 脉冲动画
                if showPulse {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .stroke(
                                step.gradient.opacity(0.3 - Double(index) * 0.1),
                                lineWidth: 2
                            )
                            .frame(
                                width: 120 + CGFloat(index) * 40,
                                height: 120 + CGFloat(index) * 40
                            )
                            .scaleEffect(showPulse ? 1.3 : 0.8)
                            .opacity(showPulse ? 0 : 1)
                            .animation(
                                .easeOut(duration: 2.5)
                                    .repeatForever(autoreverses: false)
                                    .delay(Double(index) * 0.4),
                                value: showPulse
                            )
                    }
                }
                
                // 光晕背景
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                CosmicTheme.accentCyan.opacity(0.3),
                                CosmicTheme.accentPurple.opacity(0.15),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 30,
                            endRadius: 100
                        )
                    )
                    .frame(width: 200, height: 200)
                    .blur(radius: 25)
                
                // 图标背景圆
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.1), Color.white.opacity(0.03)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                    .overlay(
                        Circle()
                            .stroke(step.gradient.opacity(0.5), lineWidth: 2)
                    )
                
                // 图标
                Image(systemName: step.icon)
                    .font(.system(size: 48))
                    .foregroundStyle(step.gradient)
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)
            }
            .offset(y: floatOffset)
            
            // 文字内容
            VStack(spacing: 16) {
                Text(step.title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
                
                Text(step.description)
                    .font(.body)
                    .foregroundColor(CosmicTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)
                    .lineSpacing(6)
            }
            .opacity(textOpacity)
            
            Spacer()
        }
        .onAppear {
            animateIn()
        }
        .onChange(of: step.icon) { _, _ in
            // 切换时重置动画
            iconScale = 0.5
            iconOpacity = 0
            textOpacity = 0
            showPulse = false
            floatOffset = 0
            animateIn()
        }
    }
    
    private func animateIn() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
            iconScale = 1.0
            iconOpacity = 1.0
        }
        
        withAnimation(CosmicAnimations.orbFloat) {
            floatOffset = -6
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeOut(duration: 0.5)) {
                textOpacity = 1.0
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            showPulse = true
        }
    }
}

#Preview {
    OnboardingView()
}
