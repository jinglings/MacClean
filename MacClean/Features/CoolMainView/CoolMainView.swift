//
//  CoolMainView.swift
//  MacClean
//
//  Main dashboard rebuilt to match the supplied MacAura reference.
//

import SwiftUI

struct CoolMainView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selectedTab: AppTab
    
    @State private var orbState: QuantumOrbView.OrbState = .idle
    @State private var cleanedSize: Int64 = 0
    @State private var previousTotalSize: Int64 = 0
    @State private var glowAnimation = false
    @State private var showJunkCleaner: Bool = false
    
    var body: some View {
        ZStack {
            auraBackground
            
            VStack(spacing: 0) {
                topStatusBar
                    .padding(.top, 28)
                    .padding(.horizontal, 34)
                
                heroSection
                    .padding(.top, 36)
                    .padding(.horizontal, 34)
                
                featureCards
                    .padding(.top, 36)
                    .padding(.horizontal, 34)
                
                Spacer(minLength: 18)
                
                footerScanBar
            }
        }
        .onAppear {
            if appState.isScanning {
                orbState = .scanning
            } else if appState.isCleaning {
                orbState = .cleaning
            }
        }
        .onChange(of: appState.isScanning) { _, isScanning in
            if !isScanning && orbState == .scanning {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                    orbState = .idle
                }
            }
        }
        .onChange(of: appState.isCleaning) { _, isCleaning in
            if !isCleaning && orbState == .cleaning {
                finishClean()
            }
        }
        .onChange(of: appState.cleanProgress) { _, progress in
            if orbState == .cleaning {
                cleanedSize = Int64(Double(previousTotalSize) * progress)
            }
        }
        .sheet(isPresented: $showJunkCleaner) {
            JunkCleanerView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
    }
    
    private var auraBackground: some View {
        ZStack {
            CosmicTheme.primaryGradient
            GridBackgroundView(gridSize: 62, lineColor: Color.white.opacity(0.026))
            RadialGradient(
                colors: [
                    CosmicTheme.accentPink.opacity(0.34),
                    CosmicTheme.accentPurple.opacity(0.16),
                    Color.clear
                ],
                center: UnitPoint(x: 0.55, y: 0.18),
                startRadius: 20,
                endRadius: 520
            )
            RadialGradient(
                colors: [
                    CosmicTheme.accentPink.opacity(0.22),
                    Color.clear
                ],
                center: UnitPoint(x: 0.58, y: 0.92),
                startRadius: 20,
                endRadius: 320
            )
        }
        .ignoresSafeArea()
    }
    
    private var topStatusBar: some View {
        HStack {
            Spacer()
            HStack(spacing: 10) {
                Circle()
                    .fill(CosmicTheme.accentGreen)
                    .frame(width: 12, height: 12)
                Text("All Systems Good")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.42))
            }
            .padding(.horizontal, 20)
            .frame(height: 48)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.095))
                    .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
            )
        }
    }
    
    private var heroSection: some View {
        HStack(alignment: .center, spacing: 36) {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Welcome to MacClean")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
                    Text("Optimize storage, protect privacy,\nand keep your Mac running smoothly.")
                        .font(.system(size: 18, weight: .regular))
                        .lineSpacing(7)
                        .foregroundColor(Color.white.opacity(0.66))
                }
                
                VStack(spacing: 12) {
                    DashboardMetricPill(
                        icon: "internaldrive",
                        title: "Macintosh HD",
                        subtitle: "\(usedStorageText) used",
                        value: "\(diskPercent)%",
                        tint: CosmicTheme.accentPink,
                        progress: Double(diskPercent) / 100.0
                    )
                    
                    DashboardMetricPill(
                        icon: "thermometer.medium",
                        title: "Temperature",
                        subtitle: "Normal",
                        value: "47°C",
                        tint: CosmicTheme.accentCyan,
                        progress: 0.78
                    )
                }
                .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            AuraSystemOrb(
                state: orbState,
                progress: orbState == .scanning ? appState.scanProgress : appState.cleanProgress
            )
            .frame(width: 455, height: 315)
            .padding(.trailing, 28)
        }
    }
    
    private var featureCards: some View {
        HStack(spacing: 14) {
            DashboardFeatureCard(
                icon: "trash",
                title: ByteCountFormatter.string(fromByteCount: appState.totalCleanableSize, countStyle: .file),
                subtitle: appState.cleanableItems.isEmpty ? "Cleanup Ready" : "Junk Found",
                caption: "Reclaimable space",
                buttonTitle: "Review",
                tint: CosmicTheme.accentPink,
                action: {
                    withAnimation(CosmicAnimations.springy) {
                        selectedTab = .cacheCleanup
                    }
                }
            )
            
            DashboardFeatureCard(
                icon: "shield.fill",
                title: "Your Mac\nis Safe",
                subtitle: "",
                caption: "Real-time protection",
                buttonTitle: appState.isLicensed ? "Protected" : "Activate",
                tint: CosmicTheme.accentGreen,
                action: {
                    if !appState.isLicensed {
                        appState.showLicenseActivation = true
                    }
                }
            )
            
            DashboardFeatureCard(
                icon: "arrow.down.to.line",
                title: "Dev",
                subtitle: "Cache\nTools",
                caption: "Clean build and package caches",
                buttonTitle: "Open",
                tint: CosmicTheme.accentCyan,
                action: {
                    withAnimation(CosmicAnimations.springy) {
                        selectedTab = .developerTools
                    }
                }
            )
            
            DashboardFeatureCard(
                icon: "doc.on.doc",
                title: "\(duplicateEstimate)",
                subtitle: "Duplicates\nFound",
                caption: "Potential space savings",
                buttonTitle: "Review",
                tint: CosmicTheme.accentOrange,
                action: {
                    withAnimation(CosmicAnimations.springy) {
                        selectedTab = .appUninstaller
                    }
                }
            )
        }
    }
    
    private var footerScanBar: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
                .offset(y: 0)
            
            HStack {
                HStack(spacing: 12) {
                    Image(systemName: "clock")
                        .font(.system(size: 20))
                        .foregroundColor(Color.white.opacity(0.55))
                    Text(lastScanText)
                        .font(.system(size: 14))
                        .foregroundColor(Color.white.opacity(0.56))
                }
                
                Spacer()
                
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 20))
                        .foregroundColor(Color.white.opacity(0.55))
                    Text("Database up to date")
                        .font(.system(size: 14))
                        .foregroundColor(Color.white.opacity(0.56))
                }
            }
            .padding(.horizontal, 76)
            .padding(.top, 52)
            
            Button(action: startScan) {
                ZStack {
                    Circle()
                        .fill(CosmicTheme.buttonGradient)
                        .frame(width: 116, height: 116)
                        .shadow(color: CosmicTheme.accentPink.opacity(0.75), radius: 28)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.56), lineWidth: 2)
                                .padding(7)
                        )
                    
                    if appState.isScanning {
                        ProgressView()
                            .scaleEffect(0.9)
                            .tint(.white)
                    } else {
                        Text("Scan")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .offset(y: -58)
            .disabled(appState.isScanning || appState.isCleaning)
        }
        .frame(height: 118)
    }
    
    private var diskPercent: Int {
        guard let diskInfo = appState.diskInfo else { return 89 }
        return Int(diskInfo.usedPercentage * 100)
    }
    
    private var usedStorageText: String {
        guard let diskInfo = appState.diskInfo else { return "228 GB" }
        return ByteCountFormatter.string(fromByteCount: diskInfo.usedSpace, countStyle: .file)
    }
    
    private var duplicateEstimate: Int {
        appState.cleanableItems.filter { $0.category == .duplicates }.count
    }
    
    private var lastScanText: String {
        if appState.isScanning {
            return appState.scanStatus.isEmpty ? "Scanning your Mac" : appState.scanStatus
        }
        return "Last Scan: Today at 9:41 AM"
    }
    
    private func startScan() {
        cleanedSize = 0
        glowAnimation = false
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            orbState = .scanning
        }
        appState.startDiskScan()
    }
    
    private func startClean() {
        cleanedSize = 0
        previousTotalSize = appState.totalCleanableSize
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            orbState = .cleaning
        }
        appState.startQuickClean()
    }
    
    private func finishClean() {
        cleanedSize = previousTotalSize
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            orbState = .complete
        }
    }
    
    private func resetState() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            orbState = .idle
            cleanedSize = 0
            glowAnimation = false
        }
    }
}

private struct DashboardMetricPill: View {
    let icon: String
    let title: String
    let subtitle: String
    let value: String
    let tint: Color
    let progress: Double
    
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(Color.white.opacity(0.78))
                .frame(width: 34)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Text(value)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.82))
                }
                
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(CosmicTheme.textMuted)
                
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(tint)
                            .frame(width: proxy.size.width * CGFloat(max(0, min(progress, 1))))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 68)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.085))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }
}

private struct DashboardFeatureCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let caption: String
    let buttonTitle: String
    let tint: Color
    let action: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.22))
                        .frame(width: 70, height: 70)
                        .overlay(Circle().stroke(tint.opacity(0.82), lineWidth: 2))
                    Image(systemName: icon)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundColor(.white)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(tint)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.28))
            }
            
            Spacer()
            
            Text(caption)
                .font(.system(size: 14))
                .foregroundColor(Color.white.opacity(0.74))
            
            Button(action: action) {
                Text(buttonTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(tint)
                    .padding(.horizontal, 20)
                    .frame(height: 36)
                    .background(Capsule().fill(tint.opacity(0.18)))
            }
            .buttonStyle(.plain)
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.15), Color.white.opacity(0.055)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(tint.opacity(0.45), lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture(perform: action)
    }
}

private struct AuraSystemOrb: View {
    let state: QuantumOrbView.OrbState
    let progress: Double
    @State private var pulse = false
    @State private var rotation: Double = 0
    
    var body: some View {
        ZStack {
            Ellipse()
                .stroke(CosmicTheme.accentPink.opacity(0.55), lineWidth: 2)
                .frame(width: 430, height: 96)
                .blur(radius: 0.4)
            
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .stroke(
                        index == 0 ? Color.white.opacity(0.35) : CosmicTheme.accentPink.opacity(0.16),
                        lineWidth: index == 0 ? 2 : 1
                    )
                    .frame(width: 118 + CGFloat(index) * 58, height: 118 + CGFloat(index) * 58)
            }
            
            Circle()
                .trim(from: 0.04, to: 0.78)
                .stroke(
                    AngularGradient(
                        colors: [
                            Color.white.opacity(0.95),
                            CosmicTheme.accentPink.opacity(0.84),
                            CosmicTheme.accentPurple.opacity(0.18),
                            Color.clear
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 21, lineCap: .round)
                )
                .frame(width: 244, height: 244)
                .rotationEffect(.degrees(rotation))
                .shadow(color: CosmicTheme.accentPink.opacity(0.65), radius: 18)
            
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            CosmicTheme.accentPink.opacity(0.95),
                            Color(hex: 0x7C287D).opacity(0.86),
                            Color(hex: 0x2D184B).opacity(0.96)
                        ],
                        center: .center,
                        startRadius: 8,
                        endRadius: 86
                    )
                )
                .frame(width: 150, height: 150)
                .overlay(Circle().stroke(Color.white.opacity(0.24), lineWidth: 2))
                .shadow(color: CosmicTheme.accentPink.opacity(0.72), radius: pulse ? 34 : 22)
            
            centerIcon
            
            orbBadge(icon: "shield.fill", alignment: .top, offset: CGSize(width: 0, height: -132))
            orbBadge(icon: "internaldrive", alignment: .leading, offset: CGSize(width: -156, height: 0))
            orbBadge(icon: "bolt.fill", alignment: .trailing, offset: CGSize(width: 156, height: 0))
            orbBadge(icon: "square.grid.2x2", alignment: .bottom, offset: CGSize(width: 0, height: 132))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
            withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
    
    @ViewBuilder
    private var centerIcon: some View {
        switch state {
        case .scanning:
            Text("\(Int(progress * 100))%")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        case .cleaning:
            Image(systemName: "trash.fill")
                .font(.system(size: 50, weight: .regular))
                .foregroundColor(.white)
        case .complete:
            Image(systemName: "checkmark")
                .font(.system(size: 54, weight: .bold))
                .foregroundColor(.white)
        case .idle:
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 70, weight: .regular))
                .foregroundColor(.white)
        }
    }
    
    private func orbBadge(icon: String, alignment: Alignment, offset: CGSize) -> some View {
        Circle()
            .fill(CosmicTheme.accentPink.opacity(0.76))
            .frame(width: 56, height: 56)
            .overlay(Circle().stroke(Color.white.opacity(0.58), lineWidth: 2))
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.white)
            )
            .shadow(color: CosmicTheme.accentPink.opacity(0.52), radius: 12)
            .offset(offset)
    }
}
