//
//  ContentView.swift
//  MacClean
//
//  宇宙主题主窗口内容视图
//  包含 CacheCleanupView 和 DeveloperToolsView 的新实现
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: AppTab = .diskAnalysis
    
    var body: some View {
        HStack(spacing: 0) {
            // 宇宙主题侧边栏
            CoolSidebarView(selectedTab: $selectedTab)
            
            // 主内容区
            ZStack {
                // 深空背景
                CosmicTheme.primaryGradient
                    .ignoresSafeArea()
                
                // 根据选中的标签显示不同内容
                switch selectedTab {
                case .diskAnalysis:
                    DiskAnalysisView()
                    
                case .cacheCleanup:
                    CosmicCacheView()
                    
                case .developerTools:
                    CosmicDeveloperToolsView()
                    
                case .appUninstaller:
                    CosmicAppUninstallerView()
                }
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented: $appState.showOnboarding) {
            OnboardingView()
        }
        .sheet(isPresented: $appState.showLicenseActivation) {
            LicenseActivationView()
        }
        .sheet(isPresented: $appState.showSettingsWindow) {
            SettingsView()
        }
        .onAppear {
            selectedTab = appState.currentTab
        }
        .onChange(of: selectedTab) { _, newValue in
            appState.currentTab = newValue
        }
        .onChange(of: appState.currentTab) { _, newValue in
            if selectedTab != newValue {
                selectedTab = newValue
            }
        }
    }
}

struct AuraPageBackground: View {
    var body: some View {
        ZStack {
            CosmicTheme.primaryGradient
            GridBackgroundView(gridSize: 62, lineColor: Color.white.opacity(0.024))
            CosmicFlowBackground().opacity(0.28)
        }
        .ignoresSafeArea()
    }
}

struct AuraSectionHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    let actionTitle: String
    let isLoading: Bool
    let action: () -> Void
    
    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                Circle()
                    .fill(CosmicTheme.accentGradient)
                    .frame(width: 58, height: 58)
                    .shadow(color: CosmicTheme.accentPink.opacity(0.36), radius: 16)
                Image(systemName: icon)
                    .font(.system(size: 25, weight: .medium))
                    .foregroundColor(.white)
            }
            
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundColor(CosmicTheme.textSecondary)
            }
            
            Spacer()
            
            Button(action: action) {
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.76)
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isLoading ? "Scanning" : actionTitle)
                }
            }
            .buttonStyle(NeonOutlineButtonStyle(color: CosmicTheme.accentPink))
            .disabled(isLoading)
        }
        .padding(.top, 32)
        .padding(.horizontal, 34)
    }
}

// MARK: - 宇宙主题缓存清理视图
struct CosmicCacheView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = CacheCleanupViewModel()
    @State private var showCompletionSheet = false
    @State private var showAllJunk = false
    @State private var cleanedSize: Int64 = 0
    
    var body: some View {
        ZStack {
            CleanupGreenBackground()
            
            VStack(spacing: 0) {
                cleanupTopBar
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 56) {
                        heroSummary
                        
                        HStack(alignment: .top, spacing: 26) {
                            CleanupLargeCard(
                                title: "已发现 \(ByteCountFormatter.string(fromByteCount: systemJunkSize, countStyle: .file)) 的系统垃圾",
                                subtitle: "清理系统和应用程序生成的所有已不再有用的文件。",
                                icon: "doc.text.fill",
                                centerIcon: "checkmark",
                                size: systemJunkSize,
                                isScanning: viewModel.isScanning,
                                checkAction: { showAllJunk = true },
                                cleanAction: {
                                    cleanedSize = systemJunkSize
                                    viewModel.cleanCategory(.systemJunk)
                                    showCompletionSheet = true
                                }
                            )
                            .frame(width: 360)
                            .frame(minHeight: 430)
                            
                            VStack(spacing: 24) {
                                CleanupWideCard(
                                    title: "已发现 \(ByteCountFormatter.string(fromByteCount: binaryJunkSize, countStyle: .file)) 的额外二进制文件",
                                    subtitle: "从应用程序中删除未使用的代码版本。您的系统仅需保留适合的版本。",
                                    icon: "circle.lefthalf.filled",
                                    tint: Color(hex: 0xA5F28F),
                                    isScanning: viewModel.isScanning,
                                    action: { showAllJunk = true }
                                )
                                
                                CleanupWideCard(
                                    title: "已发现 \(ByteCountFormatter.string(fromByteCount: xcodeJunkSize, countStyle: .file)) 的 Xcode 垃圾",
                                    subtitle: "您的 Xcode 已生成大量派生数据。您可以删除这些数据，以释放空间。",
                                    icon: "hammer.fill",
                                    tint: Color(hex: 0x87E872),
                                    isScanning: viewModel.isScanning,
                                    action: { showAllJunk = true }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 54)
                    .padding(.top, 66)
                    .padding(.bottom, 48)
                }
            }
        }
        .onAppear { if viewModel.userCaches.isEmpty { viewModel.scanCaches() } }
        .sheet(isPresented: $showCompletionSheet) {
            CleanupCompletionView(cleanedSize: cleanedSize, cleanedCount: viewModel.allItems.count) { showCompletionSheet = false }
        }
        .sheet(isPresented: $showAllJunk) {
            CleanupJunkListSheet(items: viewModel.allItems)
                .frame(minWidth: 760, minHeight: 520)
        }
    }
    
    private var cleanupTopBar: some View {
        ZStack {
            HStack {
                Button(action: { viewModel.scanCaches() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("重新开始")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.72))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isScanning)
                
                Spacer()
                
                if !appState.isLicensed {
                    Button(action: { appState.showLicenseActivation = true }) {
                        Text("解锁完整版")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Color(hex: 0x1E2108))
                            .padding(.horizontal, 28)
                            .frame(height: 48)
                            .background(Capsule().fill(Color(hex: 0xFFD23F)))
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Text("垃圾清理")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Color.white.opacity(0.78))
        }
        .padding(.horizontal, 34)
        .padding(.top, 22)
    }
    
    private var heroSummary: some View {
        VStack(spacing: 24) {
            if viewModel.isScanning {
                ProgressView()
                    .scaleEffect(1.1)
                    .tint(.white)
            }
            
            Text(viewModel.isScanning ? "正在扫描您的 Mac..." : "您的 Mac 上有 \(ByteCountFormatter.string(fromByteCount: viewModel.totalScannedSize, countStyle: .file)) 的垃圾文件。")
                .font(.system(size: 31, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            
            Button(action: { showAllJunk = true }) {
                Text("查看所有垃圾文件")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.white.opacity(0.20))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.24), lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.allItems.isEmpty)
        }
    }
    
    private var systemJunkSize: Int64 { viewModel.userCaches.reduce(0) { $0 + $1.size } }
    private var binaryJunkSize: Int64 { viewModel.browserCaches.reduce(0) { $0 + $1.size } }
    private var xcodeJunkSize: Int64 { viewModel.appCaches.reduce(0) { $0 + $1.size } }
}

struct CleanupGreenBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hex: 0x053313),
                    Color(hex: 0x0C4919),
                    Color(hex: 0x005D1F),
                    Color(hex: 0x003112)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(hex: 0x5CAB26).opacity(0.50), Color.clear],
                center: UnitPoint(x: 0.18, y: 0.48),
                startRadius: 30,
                endRadius: 520
            )
            RadialGradient(
                colors: [Color(hex: 0x009A3C).opacity(0.26), Color.clear],
                center: UnitPoint(x: 0.72, y: 0.95),
                startRadius: 40,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

struct CleanupLargeCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let centerIcon: String
    let size: Int64
    let isScanning: Bool
    let checkAction: () -> Void
    let cleanAction: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
            Text(subtitle)
                .font(.system(size: 17, weight: .semibold))
                .lineSpacing(5)
                .foregroundColor(Color.white.opacity(0.72))
            
            Spacer()
            
            HStack(alignment: .center) {
                Image(systemName: icon)
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(greenIconGradient)
                Spacer()
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Color(hex: 0x87EA5E), Color(hex: 0x0B7D2F)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 108, height: 108)
                        .overlay(Circle().stroke(Color.white.opacity(0.42), lineWidth: 5))
                        .shadow(color: Color.black.opacity(0.28), radius: 12, y: 8)
                    Image(systemName: centerIcon)
                        .font(.system(size: 52, weight: .bold))
                        .foregroundColor(.white)
                }
                Spacer()
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 50, weight: .medium))
                    .foregroundStyle(greenIconGradient)
            }
            .padding(.vertical, 36)
            
            HStack {
                Spacer()
                Button(action: checkAction) {
                    Text("检查")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 64, height: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
                
                Button(action: cleanAction) {
                    Text("清理")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color(hex: 0x13210D))
                        .frame(width: 70, height: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.92)))
                }
                .buttonStyle(.plain)
                .disabled(size == 0 || isScanning)
            }
        }
        .padding(26)
        .background(cleanupCardBackground)
    }
    
    private var greenIconGradient: LinearGradient {
        LinearGradient(colors: [Color(hex: 0x86F176), Color(hex: 0x178839)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct CleanupWideCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let isScanning: Bool
    let action: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 17, weight: .semibold))
                    .lineSpacing(5)
                    .foregroundColor(Color.white.opacity(0.72))
                Spacer()
                Button(action: action) {
                    Text("检查")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 64, height: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .disabled(isScanning)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            
            Image(systemName: icon)
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Color.white.opacity(0.94), tint, Color(hex: 0x0E7E31)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 86, height: 86)
                .padding(.top, 4)
        }
        .padding(26)
        .frame(minHeight: 190)
        .background(cleanupCardBackground)
    }
}

private var cleanupCardBackground: some View {
    RoundedRectangle(cornerRadius: 18)
        .fill(Color.white.opacity(0.22))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.20), lineWidth: 1.2))
        .shadow(color: Color.black.opacity(0.15), radius: 18, y: 10)
}

struct CleanupJunkListSheet: View {
    let items: [CacheItem]
    
    var body: some View {
        ZStack {
            CleanupGreenBackground()
            VStack(alignment: .leading, spacing: 20) {
                Text("所有垃圾文件")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { item in
                            HStack(spacing: 14) {
                                Image(systemName: icon(for: item.category))
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(Color(hex: 0x9AF07B))
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.white)
                                    Text(item.path)
                                        .font(.caption)
                                        .foregroundColor(Color.white.opacity(0.55))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.12)))
                        }
                    }
                }
            }
            .padding(28)
        }
    }
    
    private func icon(for category: CacheItem.CacheCategory) -> String {
        switch category {
        case .systemJunk: return "doc.text"
        case .binaryJunk: return "circle.lefthalf.filled"
        case .xcodeJunk: return "hammer"
        }
    }
}

// MARK: - 宇宙主题开发工具视图
struct CosmicDeveloperToolsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = DeveloperToolsViewModel()
    
    var body: some View {
        ZStack {
            AuraPageBackground()
            
            VStack(spacing: 0) {
                AuraSectionHeader(
                    title: "Performance",
                    subtitle: "Clean developer caches for Xcode, Homebrew, npm, and CocoaPods.",
                    icon: "bolt",
                    actionTitle: "Scan All",
                    isLoading: viewModel.isScanning,
                    action: { viewModel.scanAll() }
                )
                
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)], spacing: 20) {
                        CosmicDevToolCard(title: "Xcode", description: "DerivedData、Archives、Device Support", icon: "hammer.fill", accentColor: CosmicTheme.accentCyan, items: $viewModel.xcodeItems, isScanning: viewModel.isScanning, scanAction: viewModel.scanXcode, cleanAction: viewModel.cleanXcode)
                        CosmicDevToolCard(title: "Homebrew", description: "下载缓存、日志文件", icon: "mug.fill", accentColor: CosmicTheme.accentOrange, items: $viewModel.homebrewItems, isScanning: viewModel.isScanning, scanAction: viewModel.scanHomebrew, cleanAction: viewModel.cleanHomebrew)
                        CosmicDevToolCard(title: "npm / yarn", description: "包缓存、临时文件", icon: "shippingbox.fill", accentColor: CosmicTheme.accentPink, items: $viewModel.npmItems, isScanning: viewModel.isScanning, scanAction: viewModel.scanNpm, cleanAction: viewModel.cleanNpm)
                        CosmicDevToolCard(title: "CocoaPods", description: "Pods 缓存目录", icon: "cube.fill", accentColor: CosmicTheme.accentPurple, items: $viewModel.cocoapodsItems, isScanning: viewModel.isScanning, scanAction: viewModel.scanCocoapods, cleanAction: viewModel.cleanCocoapods)
                    }
                    .padding(.horizontal, 34)
                    .padding(.top, 28)
                    .padding(.bottom, 120)
                }
                
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Selected")
                            .font(.caption)
                            .foregroundColor(CosmicTheme.textMuted)
                        Text(ByteCountFormatter.string(fromByteCount: viewModel.totalSelectedSize, countStyle: .file)).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(CosmicTheme.accentGradient)
                    }
                    Spacer()
                    Button(action: { viewModel.cleanAll() }) {
                        HStack(spacing: 8) { Image(systemName: "trash"); Text("Clean All") }
                    }
                    .buttonStyle(NeonButtonStyle(isLarge: true))
                    .disabled(viewModel.totalSelectedSize == 0 || viewModel.isCleaning)
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 20)
                .background(
                    Rectangle()
                        .fill(Color(hex: 0x100D31).opacity(0.78))
                        .overlay(Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1), alignment: .top)
                )
            }
        }
        .onAppear { viewModel.scanAll() }
    }
}

struct CosmicAppUninstallerView: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        ZStack {
            AuraPageBackground()
            AppUninstallerView().environmentObject(appState)
        }
    }
}

// MARK: - 辅助组件 (Category Card, Item Row, Dev Tool Card)

struct CosmicCacheCategoryCard: View {
    let title: String; let subtitle: String; let icon: String; let accentColor: Color; @Binding var items: [CacheItem]; let isScanning: Bool
    @State private var isExpanded: Bool = true; @State private var isHovered: Bool = false
    private var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    private var selectedCount: Int { items.filter { $0.isSelected }.count }
    
    var body: some View {
        VStack(spacing: 0) {
            Button(action: { withAnimation(CosmicAnimations.springy) { isExpanded.toggle() } }) {
                HStack(spacing: 16) {
                    ZStack {
                        Circle().fill(accentColor.opacity(0.22)).frame(width: 56, height: 56)
                            .overlay(Circle().stroke(accentColor.opacity(0.72), lineWidth: 1.5))
                        Image(systemName: icon).font(.system(size: 24)).foregroundColor(accentColor)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(title).font(.headline).foregroundColor(.white)
                            if items.count > 0 { Text("\(selectedCount)/\(items.count)").font(.caption).foregroundColor(CosmicTheme.textMuted).padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Color.white.opacity(0.1))) }
                        }
                        Text(subtitle).font(.caption).foregroundColor(CosmicTheme.textMuted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if isScanning { ProgressView().scaleEffect(0.7).tint(accentColor) } 
                        else { Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)).font(.title3.bold()).foregroundColor(totalSize > 0 ? accentColor : CosmicTheme.textMuted) }
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold)).foregroundColor(CosmicTheme.textSecondary).frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.05)))
                }
                .padding(20)
            }
            .buttonStyle(.plain)
            
            if isExpanded && !items.isEmpty {
                Divider().background(accentColor.opacity(0.2))
                VStack(spacing: 0) {
                    ForEach($items) { $item in
                        CosmicCacheItemRow(item: $item, accentColor: accentColor)
                        if item.id != items.last?.id { Divider().background(Color.white.opacity(0.05)).padding(.leading, 68) }
                    }
                }
            }
            
            if isExpanded && items.isEmpty && !isScanning {
                HStack { Image(systemName: "checkmark.circle").foregroundColor(CosmicTheme.accentGreen); Text("没有发现可清理的缓存").font(.subheadline).foregroundColor(CosmicTheme.textSecondary) }.padding(20)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [accentColor.opacity(0.12), Color.white.opacity(0.055)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(isHovered ? accentColor.opacity(0.5) : Color.white.opacity(0.14), lineWidth: 1)
                )
        )
        .shadow(color: isHovered ? accentColor.opacity(0.18) : Color.black.opacity(0.12), radius: isHovered ? 20 : 14, y: 10)
        .onHover { isHovered = $0 }
    }
}

struct CosmicCacheItemRow: View {
    @Binding var item: CacheItem; let accentColor: Color; @State private var isHovered: Bool = false
    var body: some View {
        HStack(spacing: 14) {
            Toggle("", isOn: $item.isSelected).toggleStyle(CosmicCheckboxStyle(accentColor: accentColor))
            if let icon = item.appIcon { Image(nsImage: icon).resizable().frame(width: 28, height: 28).cornerRadius(6) } 
            else { ZStack { RoundedRectangle(cornerRadius: 6).fill(accentColor.opacity(0.1)).frame(width: 28, height: 28); Image(systemName: "folder.fill").font(.system(size: 14)).foregroundColor(accentColor.opacity(0.7)) } }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.subheadline).foregroundColor(.white)
                Text(item.path).font(.caption).foregroundColor(CosmicTheme.textMuted).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.subheadline.monospacedDigit()).foregroundColor(CosmicTheme.textSecondary)
            if isHovered { Button(action: { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.path) }) { Image(systemName: "arrow.right.circle.fill").font(.system(size: 18)).foregroundColor(accentColor) }.buttonStyle(.plain) }
        }
        .padding(.horizontal, 20).padding(.vertical, 12).background(isHovered ? Color.white.opacity(0.03) : Color.clear)
        .onHover { isHovered = $0 }
    }
}

struct CosmicDevToolCard: View {
    let title: String; let description: String; let icon: String; let accentColor: Color; @Binding var items: [DevToolItem]; let isScanning: Bool; let scanAction: () -> Void; let cleanAction: () -> Void
    @State private var isHovered: Bool = false
    private var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    private var selectedSize: Int64 { items.filter { $0.isSelected }.reduce(0) { $0 + $1.size } }
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(accentColor.opacity(0.22))
                            .frame(width: 56, height: 56)
                            .overlay(Circle().stroke(accentColor.opacity(0.72), lineWidth: 1.5))
                        Image(systemName: icon)
                            .font(.system(size: 24))
                            .foregroundColor(accentColor)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if isScanning { ProgressView().scaleEffect(0.7).tint(accentColor) } 
                        else { Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)).font(.title2.bold()).foregroundColor(totalSize > 0 ? accentColor : CosmicTheme.textMuted) }
                        if items.count > 0 { Text("\(items.count) 项").font(.caption).foregroundColor(CosmicTheme.textMuted) }
                    }
                }
                VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline).foregroundColor(.white); Text(description).font(.caption).foregroundColor(CosmicTheme.textMuted).lineLimit(2) }
            }
            .padding(20)
            Divider().background(accentColor.opacity(0.24))
            HStack {
                Button(action: scanAction) { HStack(spacing: 6) { Image(systemName: "magnifyingglass"); Text("扫描") }.font(.caption.weight(.medium)).foregroundColor(CosmicTheme.textSecondary) }.buttonStyle(.plain).disabled(isScanning)
                Spacer()
                Button(action: cleanAction) { HStack(spacing: 6) { Image(systemName: "trash"); Text("清理") }.font(.caption.weight(.medium)).foregroundColor(selectedSize > 0 ? accentColor : CosmicTheme.textMuted) }.buttonStyle(.plain).disabled(selectedSize == 0)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [accentColor.opacity(0.13), Color.white.opacity(0.055)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(isHovered ? accentColor.opacity(0.5) : Color.white.opacity(0.14), lineWidth: 1)
                )
        )
        .shadow(color: isHovered ? accentColor.opacity(0.2) : Color.black.opacity(0.12), radius: isHovered ? 20 : 14, y: 10)
        .onHover { isHovered = $0 }
    }
}

struct CosmicCheckboxStyle: ToggleStyle {
    let accentColor: Color
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(configuration.isOn ? accentColor : Color.clear).frame(width: 20, height: 20).overlay(RoundedRectangle(cornerRadius: 5).stroke(configuration.isOn ? accentColor : CosmicTheme.textSecondary.opacity(0.5), lineWidth: 1.5)).shadow(color: configuration.isOn ? accentColor.opacity(0.4) : Color.clear, radius: 4)
                if configuration.isOn { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white) }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView().environmentObject(AppState.shared).frame(width: 1000, height: 700)
}
