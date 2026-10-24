//
//  AboutView.swift
//  MacClean
//
//  「关于 MacClean」窗口与设置页「关于」共用的内容。
//

import SwiftUI

/// 对外链接集中在这里。
/// 为 nil 的链接不显示。
enum AppLinks {
    static let website: URL? = URL(string: "https://thulem.com/")
    static let privacy: URL? = URL(string: "https://thulem.com/privacy.html")
    static let terms: URL? = URL(string: "https://thulem.com/terms.html")
    static let support: URL? = URL(string: "https://thulem.com/support.html")
}

enum AppVersionInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

struct AboutView: View {
    var body: some View {
        ZStack {
            AppBackdrop()

            VStack(spacing: 16) {
                GradientIconTile(systemName: "sparkles", size: 84, cornerRatio: 0.26, glyphRatio: 0.44)
                    .padding(.top, 36)

                VStack(spacing: 4) {
                    Text("MacClean")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(AppTheme.textPrimary)
                    Text("个人与企业内部免费使用")
                        .font(.system(size: 12.5))
                        .foregroundColor(AppTheme.textSecondary)
                }

                Text("版本 \(AppVersionInfo.version)（\(AppVersionInfo.build)）")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(AppTheme.ink(0.06)))

                AboutLinksRow()
                    .padding(.top, 4)

                Text("© 2026 MacClean")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity)
        }
        .tint(AppTheme.accent)
    }
}

/// 官网 / 隐私政策 / 支持
struct AboutLinksRow: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(links.enumerated()), id: \.offset) { index, item in
                if index > 0 { dot }
                link(item.title, item.url)
            }
        }
        .font(.system(size: 12, weight: .medium))
    }

    private var links: [(title: LocalizedStringKey, url: URL)] {
        [("官网", AppLinks.website), ("隐私政策", AppLinks.privacy), ("支持", AppLinks.support), ("使用许可", AppLinks.terms)]
            .compactMap { title, url in url.map { (title, $0) } }
    }

    private var dot: some View {
        Circle().fill(AppTheme.ink(0.2)).frame(width: 3, height: 3)
    }

    @ViewBuilder
    private func link(_ title: LocalizedStringKey, _ url: URL?) -> some View {
        if let url {
            Link(title, destination: url)
                .foregroundColor(AppTheme.accent)
        }
    }
}

#Preview {
    AboutView().frame(width: 360)
}
