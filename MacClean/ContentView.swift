//
//  ContentView.swift
//  MacClean
//
//  主窗口框架 + 「释放空间」「开发缓存」页面入口。
//  石墨 + 薄荷设计系统：全部页面共享同一背景与控件词汇。
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: AppTab = .diskAnalysis
    @AppStorage(OnboardingKeys.hasCompleted) private var hasCompletedOnboarding = false

    var body: some View {
        HStack(spacing: 0) {
            CoolSidebarView(selectedTab: $selectedTab)

            ZStack {
                AppBackdrop()

                switch selectedTab {
                case .smartCare:
                    SmartCareView()

                case .diskAnalysis:
                    DiskAnalysisView()

                case .cacheCleanup:
                    CosmicCacheView()

                case .largeOldFiles:
                    LargeOldFilesView()

                case .similarPhotos:
                    SimilarPhotosView()

                case .appStorage:
                    AppStorageView()

                case .fileSearch:
                    FileSearchView()

                case .developerTools:
                    CosmicDeveloperToolsView()

                case .privacy:
                    PrivacyCleanupView()

                case .loginItems:
                    LoginItemsView()

                case .maintenance:
                    MaintenanceView()

                case .recovery:
                    FileRecoveryView()

                case .appUninstaller:
                    CosmicAppUninstallerView()
                }
            }
            .environment(\.currentAppTab, selectedTab)
        }
        .background(AppTheme.sidebarColor)
        .tint(AppTheme.accent)
        .ignoresSafeArea()
        .sheet(isPresented: $appState.showOnboarding, onDismiss: {
            hasCompletedOnboarding = true
        }) {
            OnboardingView()
                .environmentObject(appState)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $appState.showLicenseActivation) {
            LicenseActivationView()
        }
        .onAppear {
            selectedTab = appState.currentTab
            if !hasCompletedOnboarding {
                appState.showOnboarding = true
            }
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

// MARK: - 当前功能页（供页头 / 引导页取图标与配色）

private struct CurrentAppTabKey: EnvironmentKey {
    static let defaultValue: AppTab? = nil
}

extension EnvironmentValues {
    var currentAppTab: AppTab? {
        get { self[CurrentAppTabKey.self] }
        set { self[CurrentAppTabKey.self] = newValue }
    }
}

// MARK: - 页面背景（全局唯一）

/// 柔和渐变底 + 右上角极淡的品牌色光晕，让内容区有空气感
struct AppBackdrop: View {
    var body: some View {
        ZStack {
            AppTheme.primaryGradient
            GeometryReader { proxy in
                let w = proxy.size.width
                ZStack {
                    RadialGradient(
                        colors: [AppTheme.accent.opacity(0.13), AppTheme.accent.opacity(0)],
                        center: UnitPoint(x: 0.92, y: -0.05),
                        startRadius: 0,
                        endRadius: w * 0.55
                    )
                    RadialGradient(
                        colors: [AppTheme.sky.opacity(0.08), AppTheme.sky.opacity(0)],
                        center: UnitPoint(x: 0.05, y: 1.05),
                        startRadius: 0,
                        endRadius: w * 0.5
                    )
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

struct AuraPageBackground: View {
    var body: some View {
        AppBackdrop()
    }
}

// MARK: - 统一页头

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: Trailing
    @Environment(\.currentAppTab) private var tab

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let tab {
                GradientIconTile(systemName: tab.filledIcon, gradient: tab.tileGradient, size: 40, glyphRatio: 0.46, shadowColor: tab.tileShadow)
                    .shadow(color: tab.tileShadow.opacity(0.25), radius: 8, y: 4)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(AppTheme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundColor(AppTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.horizontal, CosmicSizes.pagePadding)
        .padding(.top, 30)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - 旧接口：区块页头（遗留调用点）

struct AuraSectionHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    let actionTitle: String
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        PageHeader(title: title, subtitle: subtitle) {
            Button(action: action) {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(AppTheme.textPrimary)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                    isLoading ? Text("扫描中") : Text(actionTitle)
                }
            }
            .buttonStyle(NeonOutlineButtonStyle())
            .disabled(isLoading)
        }
    }
}

// MARK: - 「释放空间」页面

struct CosmicCacheView: View {
    @ObservedObject private var viewModel = PageModelStore.shared.reclaim

    var body: some View {
        CleanGroupsPage(
            title: String(localized: "释放空间"),
            subtitle: String(localized: "缓存、日志、安装包、邮件附件、设备备份与废纸篓；除清空废纸篓外，全部先移入废纸篓"),
            viewModel: viewModel,
            introIcon: "trash",
            introMessage: String(localized: "查找系统与应用产生的冗余文件，通常几秒内完成。扫描只读取，不会删除任何东西。"),
            introPoints: [String(localized: "应用与浏览器缓存、7 天前的日志"), String(localized: "下载与桌面里的安装包、邮件附件"), String(localized: "iPhone / iPad 备份与固件、废纸篓")]
        )
    }
}

// MARK: - 「开发缓存」页面

struct CosmicDeveloperToolsView: View {
    @ObservedObject private var viewModel = PageModelStore.shared.devCaches

    var body: some View {
        CleanGroupsPage(
            title: String(localized: "开发缓存"),
            subtitle: String(localized: "Xcode、JavaScript、Python、JVM、Rust/Go、IDE 缓存，以及闲置项目里可重建的依赖目录"),
            viewModel: viewModel,
            introIcon: "hammer",
            introMessage: String(localized: "查找开发工具的缓存与闲置项目的依赖目录。查找闲置项目需要遍历主目录，可能需要半分钟左右。"),
            introPoints: [String(localized: "Xcode DerivedData、旧设备符号、模拟器缓存"), String(localized: "npm / pip / Gradle / Cargo 等包管理器缓存"), String(localized: "30 天未修改项目中的 node_modules、target、.venv 等")]
        )
    }
}

struct CosmicAppUninstallerView: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        AppUninstallerView().environmentObject(appState)
    }
}

// MARK: - 辅助组件

struct CosmicCheckboxStyle: ToggleStyle {
    let accentColor: Color
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(configuration.isOn ? AnyShapeStyle(AppTheme.brandGradient) : AnyShapeStyle(AppTheme.surface))
                    .frame(width: 17, height: 17)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(configuration.isOn ? Color.clear : AppTheme.ink(0.28), lineWidth: 1.2)
                    )
                if configuration.isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .heavy))
                        .foregroundColor(.white)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView().environmentObject(AppState.shared).frame(width: 1000, height: 700)
}
