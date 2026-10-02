//
//  StorageBasketViews.swift
//  MacClean
//
//  暂存篮的界面：目录地图底部的常驻栏（也是拖放目标）、清单弹出框与提示条。
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 底栏

struct StorageBasketBar: View {
    @ObservedObject var viewModel: SpaceLensViewModel
    @State private var isDropTargeted = false
    @State private var bump = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var basket: StorageBasket { viewModel.basket }

    var body: some View {
        HStack(spacing: 18) {
            diskUsage

            Rectangle()
                .fill(AppTheme.divider)
                .frame(width: 1, height: 34)

            basketSummary

            Spacer(minLength: 12)

            if !basket.isEmpty {
                Button {
                    viewModel.showBasketList.toggle()
                } label: {
                    Label("查看", systemImage: "list.bullet")
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(NeonOutlineButtonStyle())
                .popover(isPresented: $viewModel.showBasketList, arrowEdge: .top) {
                    StorageBasketListView(viewModel: viewModel)
                }

                Button("清空暂存篮", action: viewModel.clearBasket)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundColor(AppTheme.textSecondary)
                    .disabled(viewModel.isDeleting)

                Button(action: viewModel.requestCleanBasket) {
                    HStack(spacing: 6) {
                        if viewModel.isDeleting {
                            ProgressView().scaleEffect(0.55).tint(AppTheme.onAccent)
                        } else {
                            Image(systemName: "trash")
                        }
                        Text("清理")
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .buttonStyle(NeonButtonStyle(isLarge: true))
                .disabled(viewModel.isDeleting)
            }
        }
        .padding(.horizontal, CosmicSizes.pagePadding)
        .padding(.vertical, 14)
        .background(
            Rectangle()
                .fill(AppTheme.sidebarColor.opacity(0.92))
                .overlay(Rectangle().fill(isDropTargeted ? AppTheme.accentSoft : Color.clear))
                .overlay(Rectangle().fill(isDropTargeted ? AppTheme.accent : AppTheme.divider).frame(height: isDropTargeted ? 2 : 1), alignment: .top)
        )
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .dropDestination(for: String.self) { payloads, _ in
            viewModel.handleBasketDrop(payloads)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .onChange(of: viewModel.basketPulse) { _, pulse in
            guard pulse != nil, !reduceMotion else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { bump = true }
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(.easeOut(duration: 0.2)) { bump = false }
            }
        }
    }

    private var diskUsage: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let diskInfo = viewModel.diskInfo {
                Text("\(diskInfo.volumeName) · 已用 \(ByteCountFormatter.string(fromByteCount: diskInfo.usedSpace, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: diskInfo.totalSpace, countStyle: .file))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.ink(0.10))
                    Capsule()
                        .fill(AppTheme.accent)
                        .frame(width: proxy.size.width * CGFloat(viewModel.diskInfo?.usedPercentage ?? 0))
                }
            }
            .frame(height: 5)
        }
        .frame(minWidth: 140, maxWidth: 240, alignment: .leading)
    }

    private var basketSummary: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                GradientIconTile(
                    systemName: "basket.fill",
                    gradient: basket.isEmpty ? AppTheme.tileGradient(AppTheme.slate, AppTheme.slate) : AppTheme.brandGradient,
                    size: 34,
                    glyphRatio: 0.46,
                    shadowColor: basket.isEmpty ? AppTheme.slate : AppTheme.accent
                )
                .opacity(basket.isEmpty ? 0.55 : 1)
                if !basket.isEmpty {
                    Text("\(basket.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(AppTheme.onAccent)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(Capsule().fill(AppTheme.accent))
                        .overlay(Capsule().stroke(AppTheme.sidebarColor, lineWidth: 1.5))
                        .offset(x: 6, y: -6)
                }
            }
            .scaleEffect(bump ? 1.12 : 1)

            VStack(alignment: .leading, spacing: 2) {
                if basket.isEmpty {
                    Text("暂存篮")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.textSecondary)
                    Text(isDropTargeted ? String(localized: "松手加入暂存篮") : String(localized: "拖入文件夹、按 B 或点行尾的加入按钮，最后统一清理"))
                        .font(.system(size: 11.5))
                        .foregroundColor(isDropTargeted ? AppTheme.accent : AppTheme.textMuted)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 8) {
                        Text("暂存篮 · \(basket.count) 项")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                        if !basket.failedEntries.isEmpty {
                            Label("\(basket.failedEntries.count) 项未能清理", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(AppTheme.warning)
                                .lineLimit(1)
                        }
                    }
                    HStack(spacing: 6) {
                        Text("可释放 \(viewModel.basketTotalText)")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(AppTheme.textPrimary)
                            .lineLimit(1)
                            .fixedSize()
                            .contentTransition(.numericText())
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: basket.totalSize)
                            .overlay {
                                if let pulse = viewModel.basketPulse {
                                    // 贴在总数右侧浮起并淡出，不占布局
                                    GeometryReader { proxy in
                                        BasketPulseLabel(bytes: pulse.bytes)
                                            .id(pulse.id)
                                            .offset(x: proxy.size.width + 8, y: proxy.size.height / 2 - 8)
                                    }
                                }
                            }
                    }
                }
            }
        }
    }
}

/// 加入后在总数旁浮起并淡出的「+X GB」；减弱动态效果时只淡出不位移。
private struct BasketPulseLabel: View {
    let bytes: Int64
    @State private var faded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text("+\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
            .font(.system(size: 11.5, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(AppTheme.accent)
            .fixedSize()
            .opacity(faded ? 0 : 1)
            .offset(y: faded && !reduceMotion ? -8 : 0)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: reduceMotion ? 0.6 : 1.1).delay(0.35)) { faded = true }
            }
    }
}

// MARK: - 提示条

struct StorageBasketToastView: View {
    let toast: SpaceLensViewModel.BasketToast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.isWarning ? "lock.fill" : "basket.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(toast.isWarning ? AppTheme.warning : AppTheme.accent)
            Text(toast.message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(AppTheme.textPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 520)
        .background(
            Capsule()
                .fill(AppTheme.surfaceHover)
                .overlay(Capsule().stroke(AppTheme.surfaceBorder, lineWidth: 1))
                .shadow(color: AppTheme.cardShadow, radius: 10, y: 4)
        )
        .allowsHitTesting(false)
    }
}

// MARK: - 清单

struct StorageBasketListView: View {
    @ObservedObject var viewModel: SpaceLensViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("暂存篮")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text("\(viewModel.basket.count) 项 · 可释放 \(viewModel.basketTotalText)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textMuted)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().overlay(AppTheme.divider)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.basket.entries.sorted { $0.size > $1.size }) { entry in
                        StorageBasketEntryRow(
                            entry: entry,
                            displayPath: StorageBasket.displayPath(entry.path, homeDirectory: viewModel.homeDirectory),
                            quickLook: { viewModel.quickLook(path: entry.path) },
                            reveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) },
                            remove: { viewModel.removeFromBasket(entry.id) }
                        )
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 340)

            Divider().overlay(AppTheme.divider)

            HStack {
                Button("清空暂存篮", action: viewModel.clearBasket)
                    .buttonStyle(NeonOutlineButtonStyle())
                Spacer()
                Button(action: viewModel.requestCleanBasket) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("清理 \(viewModel.basketTotalText)")
                            .monospacedDigit()
                    }
                }
                .buttonStyle(NeonButtonStyle())
            }
            .disabled(viewModel.isDeleting)
            .padding(12)
        }
        .frame(width: 480)
        .background(AppTheme.primaryGradient)
    }
}

private struct StorageBasketEntryRow: View {
    let entry: StorageBasket.Entry
    let displayPath: String
    let quickLook: () -> Void
    let reveal: () -> Void
    let remove: () -> Void

    @State private var isHovered = false

    /// 路径已不在（例如被别处移走）时退回通用文件夹 / 文件图标。
    private var icon: NSImage {
        if FileManager.default.fileExists(atPath: entry.path) {
            return NSWorkspace.shared.icon(forFile: entry.path)
        }
        return NSWorkspace.shared.icon(for: entry.isDirectory ? .folder : .data)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(displayPath)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let reason = entry.failureReason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.warning)
                        .lineLimit(2)
                } else if entry.absorbedCount > 0 {
                    Text("已包含 \(entry.absorbedCount) 个子项")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.accent)
                }
            }

            Spacer(minLength: 8)

            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(AppTheme.textSecondary)

            HStack(spacing: 2) {
                BasketIconButton(systemName: "eye", help: String(localized: "快速查看"), action: quickLook)
                BasketIconButton(systemName: "magnifyingglass", help: String(localized: "在 Finder 中显示"), action: reveal)
                BasketIconButton(systemName: "xmark", help: String(localized: "移出暂存篮"), action: remove)
            }
            .opacity(isHovered ? 1 : 0.55)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: CosmicSizes.controlRadius)
                .fill(isHovered ? AppTheme.ink(0.05) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}

private struct BasketIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
