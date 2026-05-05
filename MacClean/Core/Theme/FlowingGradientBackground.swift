//
//  FlowingGradientBackground.swift
//  MacClean
//
//  流动渐变背景动画
//

import SwiftUI

// MARK: - 流动渐变背景
struct FlowingGradientBackground: View {
    @State private var animationPhase: CGFloat = 0
    
    let colors: [Color]
    
    init(colors: [Color] = [
        Color(hex: 0x0D4D2E),
        Color(hex: 0x0A3D24),
        Color(hex: 0x1A5A3A),
        Color(hex: 0x062818)
    ]) {
        self.colors = colors
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 基础渐变
                LinearGradient(
                    colors: colors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                
                // 流动的渐变球
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    MacCleanTheme.accentGlow.opacity(0.15),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 50,
                                endRadius: 200
                            )
                        )
                        .frame(width: 400, height: 400)
                        .offset(
                            x: sin(animationPhase + Double(index) * .pi * 2 / 3) * geometry.size.width * 0.3,
                            y: cos(animationPhase + Double(index) * .pi * 2 / 3) * geometry.size.height * 0.3
                        )
                        .blur(radius: 60)
                }
            }
            .onAppear {
                withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                    animationPhase = .pi * 2
                }
            }
        }
    }
}

// MARK: - 网格背景
struct GridBackgroundView: View {
    let gridSize: CGFloat
    let lineColor: Color
    
    init(gridSize: CGFloat = 50, lineColor: Color = Color.white.opacity(0.03)) {
        self.gridSize = gridSize
        self.lineColor = lineColor
    }
    
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                // 垂直线
                var x: CGFloat = 0
                while x < size.width {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(lineColor), lineWidth: 0.5)
                    x += gridSize
                }
                
                // 水平线
                var y: CGFloat = 0
                while y < size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(lineColor), lineWidth: 0.5)
                    y += gridSize
                }
            }
        }
    }
}

// MARK: - 脉冲圆环
struct PulsingRingView: View {
    let color: Color
    let ringCount: Int
    
    @State private var animate = false
    
    init(color: Color = MacCleanTheme.accentGlow, ringCount: Int = 3) {
        self.color = color
        self.ringCount = ringCount
    }
    
    var body: some View {
        ZStack {
            ForEach(0..<ringCount, id: \.self) { index in
                Circle()
                    .stroke(color.opacity(0.5 - Double(index) * 0.15), lineWidth: 2)
                    .scaleEffect(animate ? 1 + CGFloat(index) * 0.3 : 0.8)
                    .opacity(animate ? 0 : 1)
                    .animation(
                        .easeOut(duration: 2)
                            .repeatForever(autoreverses: false)
                            .delay(Double(index) * 0.4),
                        value: animate
                    )
            }
        }
        .onAppear {
            animate = true
        }
    }
}

// MARK: - 扫描光束效果
struct ScanBeamView: View {
    @State private var position: CGFloat = 0
    let isActive: Bool
    
    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            MacCleanTheme.accentGlow.opacity(0.3),
                            MacCleanTheme.accentGlow.opacity(0.6),
                            MacCleanTheme.accentGlow.opacity(0.3),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 100, height: geometry.size.height)
                .offset(x: isActive ? position : -100)
                .blur(radius: 5)
                .onChange(of: isActive) { _, active in
                    if active {
                        startAnimation(width: geometry.size.width)
                    }
                }
                .onAppear {
                    if isActive {
                        startAnimation(width: geometry.size.width)
                    }
                }
        }
    }
    
    private func startAnimation(width: CGFloat) {
        position = -100
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            position = width + 100
        }
    }
}

// MARK: - 数据流视觉效果
struct DataFlowView: View {
    let isActive: Bool
    
    @State private var streams: [DataStream] = []
    
    struct DataStream: Identifiable {
        let id = UUID()
        var x: CGFloat
        var segments: [StreamSegment]
    }
    
    struct StreamSegment: Identifiable {
        let id = UUID()
        var y: CGFloat
        var length: CGFloat
        var opacity: Double
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(streams) { stream in
                    ForEach(stream.segments) { segment in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(MacCleanTheme.accentGlow)
                            .frame(width: 2, height: segment.length)
                            .opacity(segment.opacity)
                            .position(x: stream.x, y: segment.y)
                    }
                }
            }
            .onAppear {
                if isActive {
                    initStreams(size: geometry.size)
                }
            }
            .onChange(of: isActive) { _, active in
                if active {
                    initStreams(size: geometry.size)
                } else {
                    streams = []
                }
            }
        }
    }
    
    private func initStreams(size: CGSize) {
        streams = (0..<10).map { i in
            DataStream(
                x: CGFloat(i) * size.width / 10 + CGFloat.random(in: -20...20),
                segments: (0..<5).map { _ in
                    StreamSegment(
                        y: CGFloat.random(in: 0...size.height),
                        length: CGFloat.random(in: 20...60),
                        opacity: Double.random(in: 0.2...0.8)
                    )
                }
            )
        }
        
        animateStreams(size: size)
    }
    
    private func animateStreams(size: CGSize) {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            guard isActive else {
                timer.invalidate()
                return
            }
            
            for i in streams.indices {
                for j in streams[i].segments.indices {
                    streams[i].segments[j].y += 5
                    if streams[i].segments[j].y > size.height + streams[i].segments[j].length {
                        streams[i].segments[j].y = -streams[i].segments[j].length
                        streams[i].segments[j].opacity = Double.random(in: 0.2...0.8)
                    }
                }
            }
        }
    }
}

// MARK: - 圆形进度指示器
struct CircularProgressIndicator: View {
    let progress: Double
    let lineWidth: CGFloat
    let size: CGFloat
    let gradientColors: [Color]
    
    @State private var rotation: Double = 0
    
    init(
        progress: Double,
        lineWidth: CGFloat = 8,
        size: CGFloat = 100,
        gradientColors: [Color] = [MacCleanTheme.accentGlow, MacCleanTheme.accentColor]
    ) {
        self.progress = progress
        self.lineWidth = lineWidth
        self.size = size
        self.gradientColors = gradientColors
    }
    
    var body: some View {
        ZStack {
            // 背景环
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: lineWidth)
            
            // 进度环
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        colors: gradientColors + [gradientColors.first ?? .clear],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90 + rotation))
            
            // 端点亮点
            Circle()
                .fill(gradientColors.last ?? .clear)
                .frame(width: lineWidth, height: lineWidth)
                .offset(y: -size / 2)
                .rotationEffect(.degrees(360 * progress - 90 + rotation))
                .shadow(color: gradientColors.last?.opacity(0.8) ?? .clear, radius: 5)
        }
        .frame(width: size, height: size)
        .onAppear {
            if progress < 1 {
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
        }
    }
}

// MARK: - 紫色光晕背景
struct CosmicFlowBackground: View {
    @State private var animationPhase: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    glowBlob(index: index, size: geometry.size)
                }
            }
            .onAppear {
                withAnimation(.linear(duration: 28).repeatForever(autoreverses: false)) {
                    animationPhase = 2 * .pi
                }
            }
        }
    }
    
    private func glowBlob(index: Int, size: CGSize) -> some View {
        let colors = [
            CosmicTheme.accentPink,
            CosmicTheme.accentPurple,
            CosmicTheme.accentCyan
        ]
        
        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        colors[index].opacity(0.16),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 30,
                    endRadius: 230
                )
            )
            .frame(width: 460, height: 460)
            .offset(
                x: sin(animationPhase + Double(index) * .pi * 2 / 3) * size.width * 0.22,
                y: cos(animationPhase + Double(index) * .pi * 2 / 3) * size.height * 0.18
            )
            .blur(radius: 70)
    }
}

// MARK: - 预览
#Preview("流动背景") {
    FlowingGradientBackground()
        .frame(width: 600, height: 400)
}

#Preview("脉冲圆环") {
    ZStack {
        MacCleanTheme.primaryGradient
        PulsingRingView()
            .frame(width: 200, height: 200)
    }
    .frame(width: 400, height: 400)
}

#Preview("进度指示器") {
    ZStack {
        MacCleanTheme.primaryGradient
        CircularProgressIndicator(progress: 0.7, size: 150)
    }
    .frame(width: 300, height: 300)
}
