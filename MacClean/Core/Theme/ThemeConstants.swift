//
//  ThemeConstants.swift
//  MacClean
//
//  原生工具设计系统：中性工作台、系统蓝交互与彩色功能符号。
//  旧代码中的 CosmicTheme / MacCleanTheme 引用统一映射到本主题。
//

import AppKit
import SwiftUI

typealias MacCleanTheme = AppTheme
typealias CosmicTheme = AppTheme

struct AppTheme {
    // MARK: - 背景层（浅色 / 深色自动跟随系统）

    /// 全局纯色工作区；保留渐变类型兼容已有调用。
    static let primaryGradient = LinearGradient(
        colors: [
            Color(light: 0xFFFFFF, dark: 0x1E1E20),
            Color(light: 0xFFFFFF, dark: 0x1E1E20)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// 侧栏毛玻璃之上的轻微着色（毛玻璃不可用时也作为底色）
    static let sidebarGradient = LinearGradient(
        colors: [
            Color(light: 0xEAF0F7, dark: 0x1E2128, lightAlpha: 0.55, darkAlpha: 0.55),
            Color(light: 0xEAF0F7, dark: 0x17191E, lightAlpha: 0.55, darkAlpha: 0.55)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let sidebarColor = Color(light: 0xEAF0F7, dark: 0x1C1F25)

    // MARK: - 品牌色

    /// 实色强调：图标、选中、进度
    static let accent = Color(light: 0x007AFF, dark: 0x0A84FF)
    /// 第二品牌色（渐变终点）
    static let accentAlt = Color(light: 0x008C9E, dark: 0x40C8E0)
    /// 品牌渐变填充上的文字
    static let onAccent = Color.white
    static let accentColor = accent
    static let accentGlow = accent.opacity(0.35)

    /// 实色系统蓝填充；保留旧接口。
    static let brandGradient = LinearGradient(
        colors: [accent, accent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// 选中态 / 柔和强调底
    static let accentSoft = Color(light: 0x007AFF, dark: 0x0A84FF, lightAlpha: 0.11, darkAlpha: 0.14)

    // MARK: - 语义色

    static let warning = Color(light: 0xC77800, dark: 0xFFB340)
    static let danger = Color(light: 0xD9342B, dark: 0xFF6961)

    // MARK: - 分类色

    static let mint = Color(light: 0x248A3D, dark: 0x30D158)
    static let sky = Color(light: 0x007AFF, dark: 0x64B5FF)
    static let amber = warning
    static let coral = danger
    static let violet = Color(light: 0x8950D5, dark: 0xBF9AFF)
    static let slate = Color(light: 0x6B7385, dark: 0x8B93A7)
    static let pink = Color(light: 0xE0457B, dark: 0xF27BA5)
    static let teal = accentAlt

    // 旧命名映射
    static let accentCyan = sky
    static let accentPurple = violet
    static let accentPink = coral
    static let accentGreen = mint
    static let accentOrange = amber

    static let accentGradient = brandGradient

    static let glowCyan = Color.black.opacity(0.12)
    static let glowPurple = Color.black.opacity(0.12)

    static let orbGradient = AngularGradient(
        colors: [Color(hex: 0x15B985), Color(hex: 0x0E9BB5), Color(hex: 0x15B985)],
        center: .center
    )

    static let successGradient = brandGradient

    static let warningGradient = LinearGradient(
        colors: [Color(hex: 0xF2B44A), Color(hex: 0xE08A1E)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let dangerGradient = LinearGradient(
        colors: [Color(hex: 0xF26B5B), Color(hex: 0xD9434F)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let buttonGradient = brandGradient

    /// 给功能图标用的双色渐变
    static func tileGradient(_ base: Color, _ end: Color) -> LinearGradient {
        LinearGradient(colors: [base, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - 表面层

    /// 与背景反差的「墨色」：深色下为白、浅色下为黑；用于细描边、轨道、hover 底
    static func ink(_ opacity: Double) -> Color {
        Color(light: 0x0B1220, dark: 0xFFFFFF, lightAlpha: min(1, opacity * 0.85), darkAlpha: opacity)
    }

    static let surface = Color(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 1, darkAlpha: 0.035)
    static let surfaceHover = Color(light: 0xF2F6FC, dark: 0xFFFFFF, lightAlpha: 1, darkAlpha: 0.07)
    static let surfaceBorder = Color(light: 0x0B1220, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.09)
    static let divider = ink(0.07)

    static let glassBackground = surface
    static let glassBorder = surfaceBorder
    static let glassHighlight = ink(0.12)

    static let cardBackground = LinearGradient(
        colors: [surface, surface],
        startPoint: .top,
        endPoint: .bottom
    )

    static let cardShadow = Color(light: 0x1B2433, dark: 0x000000, lightAlpha: 0.04, darkAlpha: 0.16)

    // MARK: - 文本

    static let textPrimary = Color(light: 0x161A21, dark: 0xF2F4F7)
    static let textSecondary = Color(light: 0x161A21, dark: 0xFFFFFF, lightAlpha: 0.68, darkAlpha: 0.72)
    static let textMuted = Color(light: 0x161A21, dark: 0xFFFFFF, lightAlpha: 0.60, darkAlpha: 0.60)
    static let textGlow = accent

    static let starColors: [Color] = [textMuted, slate, sky]

    static func categoryColor(_ category: CleanableCategory) -> Color {
        switch category {
        case .userCache: return mint
        case .browserCache: return sky
        case .developerTools: return violet
        case .systemLogs: return slate
        case .largeFiles: return amber
        case .oldFiles: return amber
        case .duplicates: return sky
        case .brokenLoginItems: return coral
        case .trash: return coral
        case .installers: return amber
        case .mailAttachments: return sky
        case .iosBackups, .iosUpdates: return violet
        case .projectArtifacts: return violet
        case .similarPhotos: return pink
        case .appData: return amber
        case .applications: return sky
        case .appLeftovers: return amber
        case .privacyData: return teal
        case .spaceLens: return sky
        case .aiModels: return violet
        }
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// 浅色 / 深色外观各自取值的动态颜色
    init(light: UInt, dark: UInt, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        })
    }
}

struct CosmicSizes {
    static let orbSize: CGFloat = 200
    static let cardRadius: CGFloat = 8
    static let controlRadius: CGFloat = 6
    static let buttonRadius: CGFloat = 6
    static let iconSize: CGFloat = 20
    static let sidebarWidth: CGFloat = 216
    static let cardPadding: CGFloat = 16
    static let pagePadding: CGFloat = 24
}

struct CosmicAnimations {
    static let springy = Animation.spring(response: 0.35, dampingFraction: 0.82)
    static let smooth = Animation.easeOut(duration: 0.2)
    // 旧循环动画引用一律退化为一次性过渡（动效只表达状态，不做常驻发光）
    static let orbFloat = smooth
    static let orbGlow = smooth
    static let orbRotation = smooth
    static let particleFloat = smooth
    static let glowPulse = smooth
}

// MARK: - 通用卡片背景

struct ThemeCard: ViewModifier {
    var isHovered = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: CosmicSizes.cardRadius, style: .continuous)
                    .fill(isHovered ? AppTheme.surfaceHover : AppTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: CosmicSizes.cardRadius, style: .continuous)
                            .strokeBorder(AppTheme.surfaceBorder, lineWidth: 1)
                    )
            )

    }
}

extension View {
    func themeCard(isHovered: Bool = false) -> some View {
        modifier(ThemeCard(isHovered: isHovered))
    }
}

// MARK: - 毛玻璃

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

// MARK: - 彩色功能符号（保留旧类型名兼容调用）

struct GradientIconTile: View {
    let systemName: String
    var gradient: LinearGradient = AppTheme.brandGradient
    var size: CGFloat = 28
    var cornerRatio: CGFloat = 0.28
    var glyphRatio: CGFloat = 0.5
    var shadowColor: Color = AppTheme.accent

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * max(glyphRatio, 0.62), weight: .regular))
            .foregroundStyle(shadowColor)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - 清理分组的图标配色（按 id 稳定取色）

extension AppTheme {
    private static let groupPairs: [(UInt, UInt)] = [
        (0x33C7A0, 0x14A06F), (0x5AB8F5, 0x2F86D8), (0xF5B342, 0xE4801C),
        (0x8E7CFF, 0x6247E8), (0xF2709C, 0xD9457A), (0x3FB4F0, 0x5C6CF2),
        (0x7C8799, 0x4E5767)
    ]

    static func groupPalette(for id: String) -> (gradient: LinearGradient, shadow: Color) {
        let index = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % groupPairs.count
        let pair = groupPairs[index]
        return (
            LinearGradient(colors: [Color(hex: pair.0), Color(hex: pair.1)], startPoint: .topLeading, endPoint: .bottomTrailing),
            Color(hex: pair.1)
        )
    }
}

// MARK: - 各功能的图标渐变

extension AppTab {
    var tileGradient: LinearGradient {
        let pair: (UInt, UInt)
        switch self {
        case .smartCare: pair = (0x1CC88A, 0x0E9BB5)
        case .diskAnalysis: pair = (0x4C8DF6, 0x2A5FE0)
        case .cacheCleanup: pair = (0x33C7A0, 0x14A06F)
        case .chatCleanup: pair = (0x4CD964, 0x1AAD3B)
        case .largeOldFiles: pair = (0xF5B342, 0xE4801C)
        case .similarPhotos: pair = (0xF2709C, 0xD9457A)
        case .appStorage: pair = (0x8E7CFF, 0x6247E8)
        case .fileSearch: pair = (0x5AB8F5, 0x2F86D8)
        case .developerTools: pair = (0x7C8799, 0x4E5767)
        case .privacy: pair = (0x4FC3D9, 0x1E8FB8)
        case .security: pair = (0x6E8BFF, 0x3B50E0)
        case .loginItems: pair = (0xFF8A5B, 0xE5533D)
        case .maintenance: pair = (0x9AA5B8, 0x5F6B80)
        case .recovery: pair = (0x34D3B4, 0x0F8F9E)
        case .appUninstaller: pair = (0x3FB4F0, 0x5C6CF2)
        }
        return LinearGradient(colors: [Color(hex: pair.0), Color(hex: pair.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var tileShadow: Color {
        switch self {
        case .smartCare, .privacy, .recovery: return AppTheme.teal
        case .cacheCleanup, .diskAnalysis, .fileSearch, .appUninstaller: return AppTheme.sky
        case .largeOldFiles, .loginItems: return AppTheme.amber
        case .similarPhotos, .appStorage: return AppTheme.violet
        case .developerTools, .maintenance: return AppTheme.slate
        case .security: return Color(light: 0x5856D6, dark: 0xA29BFE)
        case .chatCleanup: return AppTheme.mint
        }
    }

    /// 实心 SF Symbol（用于渐变图标块）
    var filledIcon: String {
        switch self {
        case .smartCare: return "checkmark.seal.fill"
        case .diskAnalysis: return "chart.pie.fill"
        case .cacheCleanup: return "trash"
        case .chatCleanup: return "bubble.left.and.bubble.right.fill"
        case .largeOldFiles: return "doc.fill"
        case .similarPhotos: return "doc.on.doc.fill"
        case .appStorage: return "shippingbox.fill"
        case .fileSearch: return "magnifyingglass"
        case .developerTools: return "hammer.fill"
        case .privacy: return "hand.raised.fill"
        case .loginItems: return "power"
        case .security: return "lock.shield.fill"
        case .maintenance: return "wrench.and.screwdriver.fill"
        case .recovery: return "clock.arrow.circlepath"
        case .appUninstaller: return "square.grid.2x2.fill"
        }
    }
}
