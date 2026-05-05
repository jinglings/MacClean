//
//  CleanupCompletionView.swift
//  MacClean
//
//  清理完成动画视图 & 宇宙主题动画组件集合
//  包含: QuantumOrbView, StarfieldBackgroundView, Buttons, Cards 等
//

import SwiftUI

// MARK: - 清理完成视图 (替换原有实现)
struct CleanupCompletionView: View {
    let cleanedSize: Int64
    let cleanedCount: Int
    let onDismiss: () -> Void
    
    @State private var showCheckmark = false
    @State private var showRings = false
    @State private var showStats = false
    @State private var showButton = false
    @State private var ringScale: CGFloat = 0.5
    @State private var checkmarkScale: CGFloat = 0.5
    @State private var particlesBurst = false
    
    var body: some View {
        ZStack {
            // 背景
            CosmicTheme.primaryGradient
                .ignoresSafeArea()
            
            GridBackgroundView(gridSize: 58, lineColor: Color.white.opacity(0.018))
            
            VStack(spacing: 50) {
                Spacer()
                
                // 成功动画
                successAnimation
                
                // 统计信息
                statsView
                
                Spacer()
                
                // 完成按钮
                Button(action: onDismiss) {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark")
                        Text("完成")
                    }
                }
                .buttonStyle(NeonButtonStyle(isLarge: true))
                .opacity(showButton ? 1 : 0)
                .scaleEffect(showButton ? 1 : 0.8)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: showButton)
                .padding(.bottom, 60)
            }
        }
        .frame(width: 550, height: 550)
        .onAppear {
            startAnimation()
        }
    }
    
    private var successAnimation: some View {
        ZStack {
            // 外圈能量环
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [
                                CosmicTheme.accentCyan.opacity(0.5 - Double(index) * 0.15),
                                CosmicTheme.accentPurple.opacity(0.3 - Double(index) * 0.1),
                                CosmicTheme.accentCyan.opacity(0.5 - Double(index) * 0.15)
                            ],
                            center: .center
                        ),
                        lineWidth: 3 - CGFloat(index) * 0.5
                    )
                    .frame(
                        width: 180 + CGFloat(index) * 50,
                        height: 180 + CGFloat(index) * 50
                    )
                    .scaleEffect(showRings ? 1 : 0.3)
                    .opacity(showRings ? 1 : 0)
                    .animation(
                        .spring(response: 0.6, dampingFraction: 0.6)
                            .delay(Double(index) * 0.1),
                        value: showRings
                    )
            }
            
            // 发光背景
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            CosmicTheme.accentGreen.opacity(0.4),
                            CosmicTheme.accentCyan.opacity(0.2),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 40,
                        endRadius: 120
                    )
                )
                .frame(width: 240, height: 240)
                .scaleEffect(showCheckmark ? 1.2 : 0.8)
                .opacity(showCheckmark ? 1 : 0)
                .animation(.easeOut(duration: 0.5).repeatForever(autoreverses: true), value: showCheckmark)
            
            // 主圆
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            CosmicTheme.accentGreen,
                            Color(hex: 0x00CC7D)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 130, height: 130)
                .overlay(
                    // 高光
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.4), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .center
                            )
                        )
                        .frame(width: 120, height: 120)
                        .offset(x: -10, y: -10)
                        .mask(Circle().frame(width: 130, height: 130))
                )
                .shadow(color: CosmicTheme.accentGreen.opacity(0.6), radius: 40, y: 10)
                .scaleEffect(checkmarkScale)
            
            // 勾选图标
            Image(systemName: "checkmark")
                .font(.system(size: 52, weight: .bold))
                .foregroundColor(.white)
                .scaleEffect(showCheckmark ? 1 : 0)
                .animation(.spring(response: 0.4, dampingFraction: 0.5).delay(0.3), value: showCheckmark)
        }
    }
    
    private var statsView: some View {
        VStack(spacing: 20) {
            Text("清理完成")
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(.white)
                .opacity(showStats ? 1 : 0)
                .offset(y: showStats ? 0 : 20)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.1), value: showStats)
            
            HStack(spacing: 12) {
                Text("成功释放")
                    .font(.title3)
                    .foregroundColor(CosmicTheme.textSecondary)
                
                Text(ByteCountFormatter.string(fromByteCount: cleanedSize, countStyle: .file))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(CosmicTheme.accentGradient)
                
                Text("空间")
                    .font(.title3)
                    .foregroundColor(CosmicTheme.textSecondary)
            }
            .opacity(showStats ? 1 : 0)
            .offset(y: showStats ? 0 : 20)
            .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.2), value: showStats)
            
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(CosmicTheme.accentGreen)
                Text("已清理 \(cleanedCount) 个项目")
                    .foregroundColor(CosmicTheme.textMuted)
            }
            .font(.subheadline)
            .opacity(showStats ? 1 : 0)
            .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.3), value: showStats)
        }
    }
    
    private func startAnimation() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
            showRings = true
            ringScale = 1.0
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                showCheckmark = true
                checkmarkScale = 1.0
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            particlesBurst = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                showStats = true
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                showButton = true
            }
        }
    }
}

// MARK: - ===== 共享组件 =====

// MARK: - 量子球体视图
struct QuantumOrbView: View {
    let state: OrbState
    let progress: Double
    let scannedSize: Int64
    
    @State private var rotation: Double = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var glowIntensity: Double = 0.5
    @State private var floatOffset: CGFloat = 0
    @State private var energyRingRotation: Double = 0
    
    enum OrbState {
        case idle, scanning, cleaning, complete
    }
    
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            stateColor.opacity(glowIntensity * 0.16),
                            stateColor.opacity(glowIntensity * 0.08),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 28,
                        endRadius: 170
                    )
                )
                .frame(width: 330, height: 330)
                .blur(radius: 28)
            
            if state == .scanning || state == .cleaning {
                ForEach(0..<2, id: \.self) { index in
                    Circle()
                        .stroke(
                            stateColor.opacity(index == 0 ? 0.22 : 0.12),
                            lineWidth: 1
                        )
                        .frame(width: 168 + Double(index) * 38, height: 168 + Double(index) * 38)
                }
            }
            
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            stateColor.opacity(0.72),
                            Color(hex: 0x24584A).opacity(0.88),
                            Color(hex: 0x101A2D).opacity(0.98)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 100
                    )
                )
                .frame(width: 200, height: 200)
                .overlay(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.4), Color.white.opacity(0.1), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .center
                            )
                        )
                        .frame(width: 190, height: 190)
                        .offset(x: -15, y: -15)
                        .mask(Circle().frame(width: 200, height: 200))
                )
                .shadow(color: Color.black.opacity(0.32), radius: 24, x: 0, y: 16)
                .scaleEffect(pulseScale)
            
            Circle()
                .fill(RadialGradient(colors: [stateColor.opacity(0.42), Color.clear], center: .center, startRadius: 4, endRadius: 62))
                .frame(width: 120, height: 120)
                .blur(radius: 8)
            
            if state == .scanning || state == .cleaning {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(CosmicTheme.accentGradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 180, height: 180)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: stateColor.opacity(0.22), radius: 6)
            }
            
            VStack(spacing: 6) {
                switch state {
                case .idle:
                    Image(systemName: "magnifyingglass").font(.system(size: 34, weight: .semibold)).foregroundColor(.white.opacity(0.92))
                    Text("开始扫描").font(.caption.weight(.medium)).foregroundColor(CosmicTheme.textSecondary)
                case .scanning:
                    Text("\(Int(progress * 100))%").font(.system(size: 36, weight: .bold, design: .rounded)).foregroundStyle(CosmicTheme.accentGradient)
                    Text("正在扫描").font(.caption.weight(.medium)).foregroundColor(CosmicTheme.textSecondary)
                case .cleaning:
                    Image(systemName: "trash.fill").font(.system(size: 34, weight: .medium)).foregroundStyle(CosmicTheme.accentGradient)
                    Text("清理中").font(.caption.weight(.medium)).foregroundColor(CosmicTheme.textSecondary)
                case .complete:
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 48, weight: .medium)).foregroundStyle(CosmicTheme.successGradient)
                    Text("清理完成").font(.caption.weight(.medium)).foregroundColor(CosmicTheme.textSecondary)
                }
            }
        }
        .offset(y: floatOffset)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { pulseScale = 1.015; glowIntensity = 0.72 }
            withAnimation(.easeInOut(duration: 3.6).repeatForever(autoreverses: true)) { floatOffset = -4 }
        }
    }
    
    private var stateColor: Color {
        switch state {
        case .idle, .scanning: return CosmicTheme.accentGreen
        case .cleaning: return CosmicTheme.accentGreen
        case .complete: return CosmicTheme.accentGreen
        }
    }
}

// MARK: - 星空背景
struct StarfieldBackgroundView: View {
    @State private var stars: [StarParticle] = []
    
    struct StarParticle: Identifiable {
        let id = UUID()
        var x: CGFloat; var y: CGFloat; var size: CGFloat
        var opacity: Double; var twinklePhase: Double; var color: Color
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(stars) { star in
                    Circle()
                        .fill(star.color)
                        .frame(width: star.size, height: star.size)
                        .opacity(star.opacity * (0.5 + 0.5 * sin(star.twinklePhase + Date().timeIntervalSince1970 * 2)))
                        .position(x: star.x, y: star.y)
                        .blur(radius: star.size > 3 ? 1 : 0)
                }
            }
            .onAppear {
                generateStars(in: geometry.size)
                startTwinkling()
            }
        }
    }
    
    private func generateStars(in size: CGSize) {
        stars = (0..<80).map { _ in
            StarParticle(
                x: CGFloat.random(in: 0...size.width),
                y: CGFloat.random(in: 0...size.height),
                size: CGFloat.random(in: 1...4),
                opacity: Double.random(in: 0.2...0.8),
                twinklePhase: Double.random(in: 0...(2 * .pi)),
                color: CosmicTheme.starColors.randomElement() ?? .white
            )
        }
    }
    
    private func startTwinkling() {
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            for i in stars.indices { stars[i].twinklePhase += 0.1 }
        }
    }
}

// MARK: - 按钮样式
struct NeonButtonStyle: ButtonStyle {
    let gradient: LinearGradient
    let isLarge: Bool
    init(gradient: LinearGradient = CosmicTheme.buttonGradient, isLarge: Bool = false) {
        self.gradient = gradient
        self.isLarge = isLarge
    }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isLarge ? .headline : .subheadline).fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.horizontal, isLarge ? 36 : 24).padding(.vertical, isLarge ? 16 : 12)
            .background(
                ZStack {
                    Capsule().fill(gradient)
                    Capsule().fill(LinearGradient(colors: [Color.white.opacity(0.20), Color.clear], startPoint: .top, endPoint: .center)).padding(1)
                }
            )
            .shadow(color: CosmicTheme.accentGreen.opacity(0.18), radius: configuration.isPressed ? 4 : 10, y: 6)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.25), value: configuration.isPressed)
    }
}

struct NeonOutlineButtonStyle: ButtonStyle {
    let color: Color
    init(color: Color = CosmicTheme.accentCyan) { self.color = color }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline).fontWeight(.medium).foregroundColor(color)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(
                Capsule().stroke(color.opacity(0.36), lineWidth: 1.2)
                    .background(Capsule().fill(color.opacity(configuration.isPressed ? 0.12 : 0.055)))
            )
            .shadow(color: color.opacity(0.10), radius: configuration.isPressed ? 2 : 6, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.25), value: configuration.isPressed)
    }
}

// MARK: - 侧边栏按钮
struct CosmicSidebarButton: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let badgeCount: Int?
    let action: () -> Void
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isSelected ? AnyShapeStyle(CosmicTheme.accentGreen) : isHovered ? AnyShapeStyle(Color.white.opacity(0.72)) : AnyShapeStyle(Color.white.opacity(0.46)))
                        .frame(width: 38, height: 38)
                    
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color(hex: 0x607067)))
                        .frame(width: 38, height: 38)
                    
                    if let count = badgeCount {
                        ZStack {
                            Circle().fill(CosmicTheme.accentPink).frame(width: 18, height: 18)
                            Text("\(count)").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                        }
                        .offset(x: 4, y: -4)
                    }
                }
                Text(label)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color(hex: 0x15231D)) : AnyShapeStyle(Color(hex: 0x66766D)))
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? Color.white.opacity(0.86) : Color.clear)
                    .shadow(color: isSelected ? Color.black.opacity(0.07) : Color.clear, radius: 14, y: 8)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .overlay(alignment: .leading) {
            if isSelected { Capsule().fill(CosmicTheme.accentGradient).frame(width: 4, height: 24).offset(x: -2) }
        }
    }
}

// MARK: - 毛玻璃卡片
struct CosmicGlassCard<Content: View>: View {
    let content: Content
    let showBorder: Bool
    init(showBorder: Bool = true, @ViewBuilder content: () -> Content) {
        self.showBorder = showBorder
        self.content = content()
    }
    var body: some View {
        content
            .padding(CosmicSizes.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: CosmicSizes.cardRadius)
                    .fill(CosmicTheme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: CosmicSizes.cardRadius)
                            .stroke(
                                LinearGradient(
                                    colors: [CosmicTheme.glassHighlight, CosmicTheme.glassBorder, CosmicTheme.glassBorder],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                lineWidth: showBorder ? 1 : 0
                            )
                    )
            )
            .shadow(color: Color.black.opacity(0.16), radius: 18, x: 0, y: 10)
    }
}

// MARK: - 量子爆发
struct QuantumBurstView: View {
    let isActive: Bool
    @State private var particles: [QuantumParticle] = []
    
    struct QuantumParticle: Identifiable {
        let id = UUID()
        var x: CGFloat; var y: CGFloat; var rotation: Double; var scale: CGFloat
        var opacity: Double; var color: Color; var shape: Int
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(particles) { particle in
                    Group {
                        switch particle.shape {
                        case 0: Circle().fill(particle.color)
                        case 1: Rectangle().fill(particle.color)
                        default: Diamond().fill(particle.color)
                        }
                    }
                    .frame(width: 12, height: 12)
                    .scaleEffect(particle.scale)
                    .rotationEffect(.degrees(particle.rotation))
                    .opacity(particle.opacity)
                    .position(x: particle.x, y: particle.y)
                    .blur(radius: 1)
                }
            }
            .onChange(of: isActive) { _, active in
                if active { burstParticles(in: geometry.size) }
            }
        }
    }
    
    private func burstParticles(in size: CGSize) {
        let centerX = size.width / 2
        let centerY = size.height / 2 - 50
        particles = (0..<60).map { _ in
            QuantumParticle(
                x: centerX + CGFloat.random(in: -20...20),
                y: centerY + CGFloat.random(in: -20...20),
                rotation: 0,
                scale: CGFloat.random(in: 0.5...1.5),
                opacity: 1.0,
                color: CosmicTheme.starColors.randomElement() ?? CosmicTheme.accentCyan,
                shape: Int.random(in: 0...2)
            )
        }
        withAnimation(.easeOut(duration: 2.5)) {
            for i in particles.indices {
                let angle = Double.random(in: 0...(2 * .pi))
                let distance = CGFloat.random(in: 150...450)
                particles[i].x += cos(angle) * distance
                particles[i].y += sin(angle) * distance + CGFloat.random(in: -50...100)
                particles[i].rotation = Double.random(in: 360...1080)
                particles[i].scale *= CGFloat.random(in: 0.3...0.8)
                particles[i].opacity = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { particles = [] }
    }
}

struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

// MARK: - 清理进度
struct CosmicCleaningProgressView: View {
    let progress: Double
    let currentFile: String
    @State private var rotation: Double = 0
    @State private var pulseScale: CGFloat = 1.0
    
    var body: some View {
        VStack(spacing: 40) {
            ZStack {
                ForEach(0..<2, id: \.self) { index in
                    Circle().stroke(
                        AngularGradient(
                            colors: [CosmicTheme.accentCyan.opacity(0.8), CosmicTheme.accentCyan.opacity(0.1), CosmicTheme.accentPurple.opacity(0.8), CosmicTheme.accentPurple.opacity(0.1), CosmicTheme.accentCyan.opacity(0.8)],
                            center: .center
                        ), lineWidth: 3 - CGFloat(index)
                    )
                    .frame(width: 160 + Double(index) * 30, height: 160 + Double(index) * 30)
                    .rotationEffect(.degrees(index == 0 ? rotation : -rotation * 0.7))
                }
                Circle().trim(from: 0, to: progress)
                    .stroke(CosmicTheme.accentGradient, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 130, height: 130).rotationEffect(.degrees(-90)).shadow(color: CosmicTheme.glowCyan, radius: 10)
                Image(systemName: "trash.fill").font(.system(size: 36)).foregroundStyle(CosmicTheme.accentGradient).scaleEffect(pulseScale)
            }
            VStack(spacing: 12) {
                Text("\(Int(progress * 100))%").font(.system(size: 32, weight: .bold, design: .rounded)).foregroundStyle(CosmicTheme.accentGradient)
                Text("正在清理...").font(.subheadline).foregroundColor(CosmicTheme.textSecondary)
                Text(currentFile).font(.caption).foregroundColor(CosmicTheme.textMuted).lineLimit(1).truncationMode(.middle).frame(maxWidth: 300)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) { rotation = 360 }
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulseScale = 1.1 }
        }
    }
}
