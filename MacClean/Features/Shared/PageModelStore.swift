//
//  PageModelStore.swift
//  MacClean
//
//  各页面 ViewModel 的统一持有者 + 手动扫描相关的共用视图。
//
//  侧栏切换时页面视图会被销毁重建；如果 ViewModel 跟着视图（@StateObject）走，
//  扫描结果会一起丢失，切回来又得重扫。这里让 ViewModel 在应用生命周期内常驻，
//  切换菜单不丢结果，也不会自动触发扫描——扫描一律由用户点击按钮开始。
//

import SwiftUI

@MainActor
final class PageModelStore {
    static let shared = PageModelStore()

    private init() {}

    lazy var smartCare = SmartCareViewModel()
    lazy var reclaim = CleanGroupsViewModel(descriptors: CleanGroupDescriptor.reclaimGroups)
    lazy var devCaches = CleanGroupsViewModel(descriptors: CleanGroupDescriptor.devGroups)
    lazy var largeOldFiles = LargeOldFilesViewModel()
    lazy var similarPhotos = SimilarPhotosViewModel()
    lazy var duplicates = DuplicatesViewModel()
    lazy var appStorage = AppStorageViewModel()
    lazy var fileSearch = FileSearchViewModel()
    lazy var spaceLens = SpaceLensViewModel()
    lazy var appUninstaller = AppUninstallerViewModel()
}

// MARK: - 未扫描时的引导卡片

struct ScanIntroView: View {
    let icon: String
    let title: String
    let message: String
    var points: [String] = []
    var buttonTitle = String(localized: "开始扫描")
    var footnote = String(localized: "扫描只读取文件信息，不会删除任何东西")
    /// 页面上方已有配置卡片时使用更矮的版本，保证按钮在首屏内
    var compact = false
    let action: () -> Void

    @Environment(\.currentAppTab) private var tab

    private var tint: Color { tab?.tileShadow ?? AppTheme.accent }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(0.28), tint.opacity(0)], center: .center, startRadius: 20, endRadius: 100))
                    .frame(width: 200, height: 200)
                Circle()
                    .strokeBorder(tint.opacity(0.14), lineWidth: 1)
                    .frame(width: 132, height: 132)
                Circle()
                    .strokeBorder(tint.opacity(0.08), lineWidth: 1)
                    .frame(width: 176, height: 176)
                GradientIconTile(
                    systemName: tab?.filledIcon ?? icon,
                    gradient: tab?.tileGradient ?? AppTheme.brandGradient,
                    size: compact ? 64 : 84,
                    cornerRatio: 0.26,
                    glyphRatio: 0.44,
                    shadowColor: tint
                )
            }
            .frame(height: compact ? 120 : 176)
            .clipped()
            .padding(.bottom, compact ? 12 : 20)

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(AppTheme.textPrimary)
                Text(message)
                    .font(.system(size: 13.5))
                    .foregroundColor(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 500)

            if !points.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10, alignment: .leading)], spacing: 10) {
                    ForEach(points, id: \.self) { point in
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, tint)
                            Text(point)
                                .font(.system(size: 12.5))
                                .foregroundColor(AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(AppTheme.ink(0.035))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(AppTheme.ink(0.06), lineWidth: 1)
                                )
                        )
                    }
                }
                .frame(maxWidth: 560)
                .padding(.top, 24)
            }

            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text(buttonTitle)
                }
                .frame(minWidth: 140)
            }
            .buttonStyle(NeonButtonStyle(isLarge: true))
            .keyboardShortcut(.defaultAction)
            .padding(.top, compact ? 20 : 28)

            if !footnote.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 11))
                    Text(footnote)
                        .font(.system(size: 11.5))
                }
                .foregroundColor(AppTheme.textMuted)
                .padding(.top, 14)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, compact ? 24 : 40)
        .frame(maxWidth: .infinity, minHeight: compact ? 0 : 520)
        .background(
            RoundedRectangle(cornerRadius: CosmicSizes.cardRadius, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.09), tint.opacity(0)], startPoint: .top, endPoint: .center))
        )
        .themeCard()
    }
}

// MARK: - 「扫描于 X 前」

/// 结果会常驻，显示扫描时间提醒用户结果可能已过时；每分钟自动刷新文字。
struct LastScannedLabel: View {
    let date: Date?

    var body: some View {
        if let date {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text("扫描于 \(relative(date, now: context.date))")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
            }
        }
    }

    private func relative(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? String(localized: "刚刚") : date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

/// 页头右侧的「开始扫描 / 重新扫描」按钮。
struct ScanButton: View {
    let hasScanned: Bool
    let isScanning: Bool
    let action: () -> Void

    var body: some View {
        // 未扫描时引导卡片里已有主按钮，页头不再重复
        if hasScanned || isScanning {
            button
        }
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isScanning {
                    ProgressView().scaleEffect(0.6).tint(AppTheme.textPrimary)
                } else {
                    Image(systemName: hasScanned ? "arrow.clockwise" : "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                }
                isScanning ? Text("扫描中") : (hasScanned ? Text("重新扫描") : Text("开始扫描"))
            }
        }
        .buttonStyle(NeonOutlineButtonStyle())
        .disabled(isScanning)
    }
}
