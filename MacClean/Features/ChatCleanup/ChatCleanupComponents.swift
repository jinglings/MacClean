//
//  ChatCleanupComponents.swift
//  MacClean
//
//  聊天清理页面的组成部分：应用 / 账号切换、汇总卡、快捷筛选、会话卡片、缩略图、提示条。
//

import AppKit
import QuickLookThumbnailing
import SwiftUI

// MARK: - 类型配色

extension ChatMediaType {
    var tint: Color {
        switch self {
        case .image: return AppTheme.sky
        case .video: return AppTheme.violet
        case .file: return AppTheme.warning
        case .voice: return AppTheme.pink
        case .sticker: return AppTheme.teal
        case .other: return AppTheme.slate
        case .cache: return AppTheme.accent
        }
    }
}

private func formatSize(_ size: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
}

/// 月份分组的标题本身就是月份，不再重复显示范围。
private func dateRange(_ group: ChatGroup) -> String? {
    if case .month = group.kind { return nil }
    guard let range = group.monthRange else { return nil }
    let style = Date.FormatStyle.dateTime.year().month(.abbreviated)
    let from = range.lowerBound.start().formatted(style)
    let to = range.upperBound.start().formatted(style)
    return from == to ? from : "\(from) – \(to)"
}

// MARK: - 应用切换

struct ChatAppSwitcher: View {
    @ObservedObject var viewModel: ChatCleanupViewModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ChatApp.allCases) { app in
                let available = viewModel.availableApps.contains(app)
                let isOn = viewModel.app == app
                Button {
                    viewModel.app = app
                } label: {
                    HStack(spacing: 7) {
                        ChatAppIcon(app: app, size: 18)
                        Text(app.title)
                            .font(.system(size: 12.5, weight: .medium))
                        if let size = viewModel.results[app]?.size, size > 0 {
                            Text(formatSize(size))
                                .font(.system(size: 11, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(isOn ? AppTheme.onAccent.opacity(0.8) : AppTheme.textMuted)
                        }
                    }
                    .foregroundColor(isOn ? AppTheme.onAccent : AppTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(
                        Capsule().fill(isOn ? AnyShapeStyle(AppTab.chatCleanup.tileGradient) : AnyShapeStyle(AppTheme.ink(0.06)))
                    )
                }
                .buttonStyle(.plain)
                .disabled(!available || viewModel.isCleaning)
                .opacity(available ? 1 : 0.45)
                .help(available ? app.title : String(localized: "未安装\(app.title)，或本机没有它的数据"))
            }
            Spacer()
        }
    }
}

/// 已安装时用应用自己的图标，否则用通用符号。
struct ChatAppIcon: View {
    let app: ChatApp
    let size: CGFloat

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: size * 0.6))
                .frame(width: size, height: size)
        }
    }
}

// MARK: - 账号切换

struct ChatAccountPicker: View {
    @ObservedObject var viewModel: ChatCleanupViewModel

    var body: some View {
        HStack(spacing: 8) {
            Text("账号")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppTheme.textMuted)
            ForEach(Array(viewModel.accounts.enumerated()), id: \.element.id) { index, account in
                let isOn = viewModel.account?.id == account.id
                Button {
                    viewModel.selectAccount(account)
                } label: {
                    HStack(spacing: 6) {
                        Text("账号 \(index + 1)")
                            .font(.system(size: 12, weight: .semibold))
                        Text(account.shortID)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(isOn ? AppTheme.onAccent.opacity(0.75) : AppTheme.textMuted)
                        if account.isLegacy {
                            Text("旧版")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(isOn ? AppTheme.onAccent.opacity(0.2) : AppTheme.ink(0.08)))
                        }
                        Text(formatSize(account.size))
                            .font(.system(size: 11, design: .rounded))
                            .monospacedDigit()
                    }
                    .foregroundColor(isOn ? AppTheme.onAccent : AppTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Capsule().fill(isOn ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(AppTheme.ink(0.06))))
                }
                .buttonStyle(.plain)
                .help(account.isLegacy ? String(localized: "微信 3.x 留下的旧版数据") : account.directoryName)
            }
            Spacer()
        }
    }
}

// MARK: - 汇总卡

struct ChatSummaryCard: View {
    @ObservedObject var viewModel: ChatCleanupViewModel
    let account: ChatAccount

    var body: some View {
        let types = ChatMediaType.allCases.filter { account.size(of: $0) > 0 }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(formatSize(account.size))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textPrimary)
                Text("\(viewModel.app.title)聊天媒体")
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.textSecondary)
                Spacer()
                Text(viewModel.app.groupsByConversation
                     ? String(localized: "\(account.groups.filter { $0.conversationHash != nil }.count) 个会话")
                     : String(localized: "\(account.groups.count) 个月份"))
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
            }

            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(types) { type in
                        let fraction = Double(account.size(of: type)) / Double(max(account.size, 1))
                        Rectangle()
                            .fill(type.tint)
                            .frame(width: max(3, (proxy.size.width - CGFloat(types.count - 1) * 2) * fraction))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .frame(height: 12)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(types) { type in
                    HStack(spacing: 7) {
                        Circle().fill(type.tint).frame(width: 8, height: 8)
                        Text(type.title)
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.textSecondary)
                            .fixedSize()
                        Text(formatSize(account.size(of: type)))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(AppTheme.textPrimary)
                    }
                }
            }

            Divider().overlay(AppTheme.divider)

            VStack(alignment: .leading, spacing: 8) {
                Text("快速选择")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.textMuted)
                FlowChips(viewModel: viewModel)
            }
        }
        .padding(18)
        .themeCard()
    }
}

private struct FlowChips: View {
    @ObservedObject var viewModel: ChatCleanupViewModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ChatQuickFilter.allCases) { filter in
                let size = viewModel.matchSize(filter)
                let isOn = viewModel.isActive(filter)
                Button {
                    viewModel.apply(filter)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isOn ? "checkmark" : filter.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(filter.title)
                            .font(.system(size: 12, weight: .medium))
                        if size > 0 {
                            Text(formatSize(size))
                                .font(.system(size: 11, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(isOn ? AppTheme.onAccent.opacity(0.75) : AppTheme.textMuted)
                        }
                    }
                    .fixedSize()
                    .foregroundColor(isOn ? AppTheme.onAccent : AppTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Capsule().fill(isOn ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(AppTheme.ink(0.06))))
                }
                .buttonStyle(.plain)
                .disabled(size == 0)
                .opacity(size == 0 ? 0.45 : 1)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 隐私说明

struct ChatPrivacyNote: View {
    let app: ChatApp
    let account: ChatAccount

    private var detail: String {
        switch app {
        case .wechat where account.isLegacy:
            return String(localized: "聊天数据库是加密的，MacClean 不会解密，也不读取任何消息内容，只看媒体文件的大小和日期，所以会话只能按编号显示。可以凭缩略图认出会话，点铅笔图标给它起个名字（只保存在这台 Mac 上）。")
        case .wechat:
            return String(localized: "聊天数据库是加密的，MacClean 不会解密，也不读取任何消息内容，只看媒体文件的大小和日期，所以会话只能按编号显示，可以点铅笔图标给它起个名字（只保存在这台 Mac 上）。微信 4.x 的图片以加密格式保存，无法预览；视频和收到的文件按月份存放、不区分会话，列在最后的「视频、文件与缓存」里。")
        case .qq:
            return String(localized: "QQ 按月份存放图片、视频和语音，不区分会话，所以这里按月份和类型列出。MacClean 不读取聊天数据库和消息内容，只看媒体文件的大小和日期。")
        case .wecom:
            return String(localized: "企业微信的缓存目录不区分会话，所以这里按月份和类型列出。MacClean 不读取聊天数据库和消息内容，只看媒体文件的大小和日期。")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 16))
                .foregroundColor(AppTheme.accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.groupsByConversation ? String(localized: "为什么看不到聊天名称？") : String(localized: "为什么按月份列出？"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: CosmicSizes.cardRadius, style: .continuous)
                .fill(AppTheme.accentSoft)
        )
    }
}

// MARK: - 大文件

struct ChatLargeFilesCard: View {
    @ObservedObject var viewModel: ChatCleanupViewModel
    let account: ChatAccount
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(CosmicAnimations.smooth) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 14))
                        .foregroundColor(AppTheme.warning)
                    Text("超过 100 MB 的文件")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                    Text("\(account.largeFiles.count) 个 · \(formatSize(account.largeFiles.reduce(0) { $0 + $1.size }))")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundColor(AppTheme.textMuted)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(AppTheme.textMuted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(account.largeFiles) { file in
                    Divider().overlay(AppTheme.divider)
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(get: { viewModel.isSelected(file) }, set: { _ in viewModel.toggle(file) }))
                            .toggleStyle(CosmicCheckboxStyle(accentColor: AppTheme.accent))
                            .labelsHidden()
                        Image(systemName: file.type.icon)
                            .font(.system(size: 12))
                            .foregroundColor(file.type.tint)
                            .frame(width: 18)
                        Text(file.name)
                            .font(.system(size: 12.5))
                            .foregroundColor(AppTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if file.type == .file { ReceivedFileBadge() }
                        Spacer(minLength: 12)
                        Text(file.modified.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 11))
                            .foregroundColor(AppTheme.textMuted)
                        Text(formatSize(file.size))
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(AppTheme.textPrimary)
                            .frame(width: 76, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contextMenu {
                        Button("在访达中显示") { NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "") }
                    }
                }
            }
        }
        .themeCard()
    }
}

// MARK: - 「收到的文件」提示

struct ReceivedFileBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9.5))
            Text("你收到的文件，删除后需要重新下载，过期则无法找回")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(AppTheme.warning)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(AppTheme.warning.opacity(0.12)))
    }
}

// MARK: - 会话 / 月份卡片

struct ChatGroupCard: View {
    @ObservedObject var viewModel: ChatCleanupViewModel
    let account: ChatAccount
    let group: ChatGroup

    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var draftName = ""

    private var isExpanded: Bool { viewModel.expanded.contains(group.id) }

    private var icon: String {
        switch group.kind {
        case .conversation: return "bubble.left.fill"
        case .month: return "calendar"
        case .shared: return "tray.full.fill"
        }
    }

    private var countsLine: String {
        group.types.map { "\($0.title) \(group.count(of: $0).formatted())" }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !group.thumbnails.isEmpty {
                ChatThumbnailStrip(paths: group.thumbnails)
                    .padding(.leading, 16 + 17 + 12 + 36 + 12)
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
            }
            if isExpanded {
                Divider().overlay(AppTheme.divider)
                VStack(spacing: 0) {
                    ForEach(group.types) { type in
                        ChatTypeRow(viewModel: viewModel, groupID: group.id, type: type, buckets: group.buckets(of: type))
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .themeCard(isHovered: isHovered)
        .onHover { isHovered = $0 }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TriStateCheckbox(state: viewModel.state(of: group.buckets)) {
                viewModel.toggle(group.buckets)
            }

            GradientIconTile(
                systemName: icon,
                gradient: group.conversationHash != nil ? AppTab.chatCleanup.tileGradient : AppTheme.tileGradient(AppTheme.slate, AppTheme.slate.opacity(0.75)),
                size: 36,
                cornerRatio: 0.27,
                glyphRatio: 0.44,
                shadowColor: AppTab.chatCleanup.tileShadow
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(viewModel.label(for: group, in: account))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                        .lineLimit(1)
                    if let hash = group.conversationHash {
                        Text(String(hash.prefix(8)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(AppTheme.textMuted)
                            .help(hash)
                        Button {
                            draftName = viewModel.hasCustomLabel(group, in: account) ? viewModel.label(for: group, in: account) : ""
                            isRenaming = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(AppTheme.textMuted)
                        }
                        .buttonStyle(.plain)
                        .opacity(isHovered || viewModel.hasCustomLabel(group, in: account) ? 1 : 0)
                        .help(String(localized: "给这个会话起个名字（只保存在这台 Mac 上）"))
                        .popover(isPresented: $isRenaming, arrowEdge: .bottom) { renamePopover }
                    }
                }
                HStack(spacing: 6) {
                    if let range = dateRange(group) {
                        Text(range)
                    }
                    Text(countsLine)
                        .lineLimit(1)
                }
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundColor(AppTheme.textMuted)
            }

            Spacer(minLength: 12)

            Text(formatSize(group.size))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(AppTheme.textPrimary)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.textMuted)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(CosmicAnimations.smooth) {
                if isExpanded { viewModel.expanded.remove(group.id) } else { viewModel.expanded.insert(group.id) }
            }
        }
    }

    private var renamePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("给会话起个名字")
                .font(.system(size: 13, weight: .semibold))
            TextField(String(localized: "例如：家人群"), text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(save)
            Text("只保存在这台 Mac 上，用来帮你认出会话。")
                .font(.system(size: 11))
                .foregroundColor(AppTheme.textMuted)
            HStack {
                if viewModel.hasCustomLabel(group, in: account) {
                    Button("恢复编号") {
                        viewModel.rename(group, in: account, to: nil)
                        isRenaming = false
                    }
                }
                Spacer()
                Button("取消") { isRenaming = false }
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private func save() {
        viewModel.rename(group, in: account, to: draftName)
        isRenaming = false
    }
}

// MARK: - 类型行 / 月份行

private struct ChatTypeRow: View {
    @ObservedObject var viewModel: ChatCleanupViewModel
    let groupID: String
    let type: ChatMediaType
    let buckets: [ChatBucket]

    private var key: String { groupID + "|" + type.rawValue }
    private var isExpanded: Bool { viewModel.expanded.contains(key) }
    private var size: Int64 { buckets.reduce(0) { $0 + $1.size } }
    private var count: Int { buckets.reduce(0) { $0 + $1.count } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TriStateCheckbox(state: viewModel.state(of: buckets)) { viewModel.toggle(buckets) }
                Image(systemName: type.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(type.tint)
                    .frame(width: 18)
                Text(type.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppTheme.textPrimary)
                if type == .file { ReceivedFileBadge() }
                if type.isRegenerable {
                    Text("会自动重建")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.accent)
                }
                Spacer(minLength: 12)
                Text(buckets.count > 1 ? String(localized: "\(buckets.count) 个月 · \(count.formatted()) 个") : String(localized: "\(count.formatted()) 个"))
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textMuted)
                Text(formatSize(size))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textPrimary)
                    .frame(width: 80, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AppTheme.textMuted)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(buckets.count > 1 ? 1 : 0)
            }
            .padding(.leading, 16 + 17 + 12)
            .padding(.trailing, 16)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture {
                guard buckets.count > 1 else { viewModel.toggle(buckets); return }
                withAnimation(CosmicAnimations.smooth) {
                    if isExpanded { viewModel.expanded.remove(key) } else { viewModel.expanded.insert(key) }
                }
            }

            if isExpanded && buckets.count > 1 {
                ForEach(buckets) { bucket in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { viewModel.selectedBuckets.contains(bucket.id) },
                            set: { _ in viewModel.toggle([bucket]) }
                        ))
                        .toggleStyle(CosmicCheckboxStyle(accentColor: AppTheme.accent))
                        .labelsHidden()
                        Text(bucket.month.start().formatted(.dateTime.year().month(.wide)))
                            .font(.system(size: 12.5))
                            .foregroundColor(AppTheme.textSecondary)
                        Spacer(minLength: 12)
                        Text("\(bucket.count.formatted()) 个")
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundColor(AppTheme.textMuted)
                        Text(formatSize(bucket.size))
                            .font(.system(size: 12.5, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(AppTheme.textSecondary)
                            .frame(width: 80, alignment: .trailing)
                        Color.clear.frame(width: 10)
                    }
                    .padding(.leading, 16 + 17 + 12 + 28)
                    .padding(.trailing, 16)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.toggle([bucket]) }
                }
            }
        }
    }
}

// MARK: - 缩略图

/// 本地生成的缩略图缓存（QuickLookThumbnailing，在系统的后台队列上生成）。
@MainActor
final class ChatThumbnailCache {
    static let shared = ChatThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private var failed: Set<String> = []

    func image(for path: String) -> NSImage? { cache.object(forKey: path as NSString) }

    func load(_ path: String, side: CGFloat = 96) async -> NSImage? {
        if let cached = image(for: path) { return cached }
        guard !failed.contains(path),
              ChatMediaScanner.previewableExtensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: side, height: side),
            scale: 2,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            failed.insert(path)
            return nil
        }
        let image = representation.nsImage
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

struct ChatThumbnailStrip: View {
    let paths: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(paths, id: \.self) { path in
                ChatThumbnail(path: path)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ChatThumbnail: View {
    let path: String
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        // 生成不了缩略图的（格式不认识、文件损坏）直接不占位
        if !failed { tile }
    }

    private var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(AppTheme.ink(0.06))
            if let image = image ?? ChatThumbnailCache.shared.image(for: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.textMuted)
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(AppTheme.ink(0.08), lineWidth: 1))
        .task(id: path) {
            image = await ChatThumbnailCache.shared.load(path)
            failed = image == nil
        }
    }
}

// MARK: - 提示条

struct ChatRunningBanner: View {
    let app: ChatApp
    let onQuit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppTheme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("请先退出\(app.title)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text("\(app.title)运行时会读写这些文件，退出后才能清理；扫描和浏览不受影响。")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
            }
            Spacer()
            Button("退出", action: onQuit)
                .buttonStyle(NeonOutlineButtonStyle())
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: CosmicSizes.cardRadius, style: .continuous)
                .fill(AppTheme.warning.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: CosmicSizes.cardRadius, style: .continuous)
                        .strokeBorder(AppTheme.warning.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

struct ChatFullDiskAccessBanner: View {
    let app: ChatApp
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppTheme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("无法读取\(app.title)的数据")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text("在「系统设置 › 隐私与安全性 › 完全磁盘访问权限」中打开 MacClean；如果系统询问是否允许访问其他应用的数据，请选择「允许」，然后重新扫描。")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("打开系统设置") { FullDiskAccess.openSettings() }
                .buttonStyle(NeonOutlineButtonStyle())
            Button("重新扫描", action: onRetry)
                .buttonStyle(NeonOutlineButtonStyle())
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: CosmicSizes.cardRadius, style: .continuous)
                .fill(AppTheme.warning.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: CosmicSizes.cardRadius, style: .continuous)
                        .strokeBorder(AppTheme.warning.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

struct ChatScanProgressRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.6).tint(AppTheme.textSecondary)
            Text("正在扫描… 已检查 \(count.formatted()) 个文件")
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundColor(AppTheme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .themeCard()
    }
}

struct ChatEmptyState: View {
    /// nil：本机没有安装任何支持的聊天应用。
    let app: ChatApp?
    let unreadable: Bool

    private var message: String {
        guard let app else { return String(localized: "这台 Mac 上没有找到微信、QQ 或企业微信的数据") }
        return unreadable ? String(localized: "授权后才能看到\(app.title)的聊天媒体") : String(localized: "没有找到\(app.title)的聊天图片、视频或文件")
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: unreadable ? "lock" : "checkmark.circle")
                .font(.system(size: 28))
                .foregroundColor(unreadable ? AppTheme.warning : AppTheme.accent)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .themeCard()
    }
}
