//
//  ThemeConstants.swift
//  MacClean
//
//  MacAura-inspired visual system: deep violet workspace, translucent panels,
//  pink-purple scan accents, and a compact dark sidebar.
//

import SwiftUI

typealias MacCleanTheme = CosmicTheme

struct CosmicTheme {
    static let primaryGradient = LinearGradient(
        colors: [
            Color(hex: 0x120E36),
            Color(hex: 0x26104D),
            Color(hex: 0x4B1261),
            Color(hex: 0x130E36)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let sidebarGradient = LinearGradient(
        colors: [
            Color(hex: 0x25144B),
            Color(hex: 0x17143B),
            Color(hex: 0x111133)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    
    static let accentColor = Color(hex: 0xF05CFF)
    static let accentGlow = Color(hex: 0xF05CFF).opacity(0.58)
    
    static let accentCyan = Color(hex: 0x55A8FF)
    static let accentPurple = Color(hex: 0xA765FF)
    static let accentPink = Color(hex: 0xFF5ACD)
    static let accentGreen = Color(hex: 0x6FEC83)
    static let accentOrange = Color(hex: 0xFFB04F)
    
    static let accentGradient = LinearGradient(
        colors: [Color(hex: 0xFF6BDF), Color(hex: 0xAD62FF)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let glowCyan = Color(hex: 0x55A8FF).opacity(0.45)
    static let glowPurple = Color(hex: 0xF05CFF).opacity(0.48)
    
    static let orbGradient = AngularGradient(
        colors: [
            Color(hex: 0xFF72E4),
            Color(hex: 0xB369FF),
            Color(hex: 0x6D7BFF),
            Color(hex: 0xFF72E4)
        ],
        center: .center
    )
    
    static let successGradient = LinearGradient(
        colors: [Color(hex: 0x6FEC83), Color(hex: 0x39C95F)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let warningGradient = LinearGradient(
        colors: [Color(hex: 0xFFB04F), Color(hex: 0xE58A39)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let dangerGradient = LinearGradient(
        colors: [Color(hex: 0xFF5ACD), Color(hex: 0xC743A3)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let buttonGradient = LinearGradient(
        colors: [Color(hex: 0xFF62E0), Color(hex: 0xB25DFF)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let glassBackground = Color.white.opacity(0.075)
    static let glassBorder = Color.white.opacity(0.15)
    static let glassHighlight = Color.white.opacity(0.28)
    
    static let cardBackground = LinearGradient(
        colors: [
            Color.white.opacity(0.12),
            Color.white.opacity(0.045)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.72)
    static let textMuted = Color.white.opacity(0.46)
    static let textGlow = Color(hex: 0xFF6BDF)
    
    static let starColors: [Color] = [
        Color(hex: 0xFFFFFF),
        Color(hex: 0xFFB8F2),
        Color(hex: 0xA765FF),
        Color(hex: 0x55A8FF),
        Color(hex: 0xF05CFF)
    ]
    
    static func categoryColor(_ category: CleanableCategory) -> Color {
        switch category {
        case .userCache: return accentPink
        case .browserCache: return accentPurple
        case .developerTools: return accentCyan
        case .systemLogs: return Color(hex: 0x8B83B8)
        case .largeFiles: return accentOrange
        case .oldFiles: return Color(hex: 0xFFD36B)
        case .duplicates: return accentOrange
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
}

struct CosmicSizes {
    static let orbSize: CGFloat = 220
    static let cardRadius: CGFloat = 18
    static let buttonRadius: CGFloat = 18
    static let iconSize: CGFloat = 24
    static let sidebarWidth: CGFloat = 286
    static let cardPadding: CGFloat = 22
}

struct CosmicAnimations {
    static let orbFloat = Animation.easeInOut(duration: 3).repeatForever(autoreverses: true)
    static let orbGlow = Animation.easeInOut(duration: 2).repeatForever(autoreverses: true)
    static let orbRotation = Animation.linear(duration: 15).repeatForever(autoreverses: false)
    static let particleFloat = Animation.easeInOut(duration: 4).repeatForever(autoreverses: true)
    static let springy = Animation.spring(response: 0.4, dampingFraction: 0.72)
    static let smooth = Animation.easeInOut(duration: 0.25)
    static let glowPulse = Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)
}
