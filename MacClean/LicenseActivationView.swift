//
//  LicenseActivationView.swift
//  MacClean
//
//  宇宙主题许可证激活视图
//

import SwiftUI
import StoreKit

struct LicenseActivationView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var licenseManager = LicenseManager.shared
    @State private var products: [Product] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedProductId: String?
    @State private var showSuccessBurst = false
    
    var body: some View {
        ZStack {
            // 背景
            CosmicTheme.primaryGradient
                .ignoresSafeArea()
            
            // 星空背景
            StarfieldBackgroundView()
            
            VStack(spacing: 0) {
                // 关闭按钮
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(CosmicTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                
                ScrollView {
                    VStack(spacing: 32) {
                        // 标题区域
                        headerSection
                        
                        // 功能亮点
                        featuresSection
                        
                        // 价格选项
                        pricingSection
                        
                        // 恢复购买
                        Button("恢复已购买的许可证") {
                            Task {
                                try? await licenseManager.restorePurchases()
                                if licenseManager.isLicensed {
                                    showSuccessBurst = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                        dismiss()
                                    }
                                }
                            }
                        }
                        .font(.caption)
                        .foregroundColor(CosmicTheme.textMuted)
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
            }
            
            // 成功粒子爆发
            QuantumBurstView(isActive: showSuccessBurst)
        }
        .frame(width: 500, height: 680)
        .task {
            await loadProducts()
        }
    }
    
    // MARK: - 标题区域
    private var headerSection: some View {
        VStack(spacing: 16) {
            // 皇冠图标
            ZStack {
                // 光晕
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(hex: 0xFFD700).opacity(0.3),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 30,
                            endRadius: 70
                        )
                    )
                    .frame(width: 140, height: 140)
                    .blur(radius: 20)
                
                // 实体圆
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0xFFD700), Color(hex: 0xFFA500)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)
                    .shadow(color: Color(hex: 0xFFD700).opacity(0.5), radius: 15, y: 8)
                
                Image(systemName: "crown.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.white)
            }
            .scaleEffect(showSuccessBurst ? 1.2 : 1.0)
            .animation(.spring(response: 0.5, dampingFraction: 0.6), value: showSuccessBurst)
            
            Text("升级到 Pro 版本")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
            
            Text("解锁全部功能，享受完整的 MacClean 体验")
                .font(.subheadline)
                .foregroundColor(CosmicTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }
    
    // MARK: - 功能亮点
    private var featuresSection: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                CoolFeatureItem(icon: "globe", title: "浏览器清理", description: "清理所有浏览器缓存")
                CoolFeatureItem(icon: "hammer.fill", title: "开发工具", description: "Xcode, npm 等")
            }
            
            HStack(spacing: 16) {
                CoolFeatureItem(icon: "app.badge.checkmark", title: "应用卸载", description: "完整卸载应用")
                CoolFeatureItem(icon: "sparkles", title: "自动优化", description: "智能清理建议")
            }
        }
    }
    
    // MARK: - 价格选项
    private var pricingSection: some View {
        VStack(spacing: 16) {
            if isLoading {
                ProgressView()
                    .tint(.white)
                    .frame(height: 150)
            } else if let error = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundColor(Color(hex: 0xFF6B6B))
                    Text(error)
                        .foregroundColor(CosmicTheme.textSecondary)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    
                    Button("重试") {
                        Task { await loadProducts() }
                    }
                    .buttonStyle(NeonOutlineButtonStyle())
                }
            } else {
                ForEach(products, id: \.id) { product in
                    CoolPricingCard(
                        product: product,
                        isSelected: selectedProductId == product.id,
                        isRecommended: product.id.contains("lifetime")
                    ) {
                        selectedProductId = product.id
                        Task {
                            await purchase(product)
                        }
                    }
                }
            }
        }
    }
    
    private func loadProducts() async {
        isLoading = true
        errorMessage = nil
        do {
            products = try await licenseManager.getProducts()
            products.sort { $0.price < $1.price }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
    
    private func purchase(_ product: Product) async {
        do {
            try await licenseManager.purchase(product.id)
            showSuccessBurst = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                dismiss()
            }
        } catch LicenseError.userCancelled {
            selectedProductId = nil
        } catch {
            errorMessage = error.localizedDescription
            selectedProductId = nil
        }
    }
}

// MARK: - 功能项组件
struct CoolFeatureItem: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(CosmicTheme.accentCyan.opacity(0.15))
                    .frame(width: 40, height: 40)
                
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(CosmicTheme.accentCyan)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                
                Text(description)
                    .font(.caption)
                    .foregroundColor(CosmicTheme.textMuted)
            }
            
            Spacer()
        }
        .padding()
        .background(
            CosmicGlassCard(showBorder: true) { EmptyView() }
                .padding(-CosmicSizes.cardPadding) // Hack to use the style
        )
    }
}

// MARK: - 价格卡片
struct CoolPricingCard: View {
    let product: Product
    let isSelected: Bool
    let isRecommended: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                // 推荐标签
                if isRecommended {
                    HStack {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                        Text("最佳选择")
                            .font(.caption.bold())
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        LinearGradient(
                            colors: [Color(hex: 0xFFD700), Color(hex: 0xFFA500)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(Capsule())
                    .offset(y: -12)
                }
                
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(product.displayName)
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        Text(product.description)
                            .font(.caption)
                            .foregroundColor(CosmicTheme.textMuted)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(product.displayPrice)
                            .font(.title2.bold())
                            .foregroundColor(CosmicTheme.accentGlow)
                        
                        if !product.id.contains("lifetime") {
                            Text("每年")
                                .font(.caption)
                                .foregroundColor(CosmicTheme.textMuted)
                        }
                    }
                }
                .padding()
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isRecommended ? CosmicTheme.accentCyan.opacity(0.1) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                isRecommended ? CosmicTheme.accentCyan : 
                                isHovered ? Color.white.opacity(0.3) : Color.white.opacity(0.1),
                                lineWidth: isRecommended ? 2 : 1
                            )
                    )
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .shadow(color: isRecommended ? CosmicTheme.accentCyan.opacity(0.2) : Color.clear, radius: 10)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}
