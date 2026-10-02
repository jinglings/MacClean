//
//  ChatCleanupView.swift
//  MacClean
//
//  聊天清理：按会话、日期和类型清理微信、QQ、企业微信里的图片、视频和文件。
//  只移动媒体文件（进废纸篓、可恢复），聊天文字记录与数据库一律不碰；聊天应用运行时禁止清理。
//

import SwiftUI

struct ChatCleanupView: View {
    @ObservedObject private var viewModel: ChatCleanupViewModel

    @State private var showConfirm = false
    @State private var showCompletion = false
    @State private var showHistory = false
    @State private var showRunningAlert = false

    init() {
        self.init(viewModel: .shared)
    }

    init(viewModel: ChatCleanupViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: String(localized: "聊天清理"),
                subtitle: String(localized: "按会话、日期和类型清理微信、QQ、企业微信里的图片、视频和文件，聊天文字记录不受影响")
            ) {
                HStack(spacing: 8) {
                    Button {
                        showHistory = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 12, weight: .medium))
                            Text("清理记录")
                        }
                    }
                    .buttonStyle(NeonOutlineButtonStyle())

                    LastScannedLabel(date: viewModel.lastScannedAt[viewModel.app])
                    if viewModel.isScanning {
                        Button("停止") { viewModel.cancelScan() }
                            .buttonStyle(NeonOutlineButtonStyle())
                    } else {
                        ScanButton(hasScanned: viewModel.hasScanned, isScanning: false) { viewModel.scan() }
                            .disabled(viewModel.isCleaning || !viewModel.availableApps.contains(viewModel.app))
                    }
                }
            }

            ChatAppSwitcher(viewModel: viewModel)
                .padding(.horizontal, CosmicSizes.pagePadding)
                .padding(.top, 18)

            content
        }
        .onAppear {
            viewModel.refreshAvailability()
            viewModel.refreshRunning()
        }
        .alert(String(localized: "确认清理"), isPresented: $showConfirm) {
            Button("取消", role: .cancel) {}
            Button("移入废纸篓", role: .destructive) {
                Task {
                    switch await viewModel.cleanSelected() {
                    case .cleaned: showCompletion = true
                    case .blockedByRunningApp: showRunningAlert = true
                    case .nothingSelected: break
                    }
                }
            }
        } message: {
            Text(confirmMessage)
        }
        .alert(String(localized: "请先退出\(viewModel.app.title)"), isPresented: $showRunningAlert) {
            Button("取消", role: .cancel) {}
            Button("退出") { viewModel.quitApp() }
        } message: {
            Text("\(viewModel.app.title)正在使用这些文件，退出后才能清理。")
        }
        .sheet(isPresented: $showCompletion) {
            let result = viewModel.lastCleanResult
            CleanupCompletionView(
                cleanedSize: result?.freedSpace ?? 0,
                cleanedCount: result?.cleanedItems ?? 0,
                failedCount: result?.errors.count ?? 0,
                onUndo: result?.historySessionID == nil ? nil : {
                    Task {
                        await viewModel.undoLastClean()
                        showCompletion = false
                    }
                },
                onDismiss: { showCompletion = false }
            )
        }
        .sheet(isPresented: $showHistory) {
            CleanupHistoryView(onRestored: { viewModel.scan() })
                .frame(width: 640, height: 520)
        }
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        let scanningThisApp = viewModel.isScanning && viewModel.scanningApp == viewModel.app
        if let result = viewModel.result, !(scanningThisApp && result.accounts.isEmpty) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    banners(unreadable: result.unreadable)
                    if scanningThisApp {
                        ChatScanProgressRow(count: viewModel.scannedFiles)
                    }
                    if let account = viewModel.account {
                        resultsBody(account)
                    } else {
                        ChatEmptyState(app: viewModel.app, unreadable: result.unreadable)
                    }
                }
                .padding(.horizontal, CosmicSizes.pagePadding)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
            .onAppear {
                guard let target = viewModel.scrollTarget else { return }
                viewModel.scrollTarget = nil
                DispatchQueue.main.async { proxy.scrollTo(target, anchor: UnitPoint(x: 0, y: 0.04)) }
            }
            }

            SelectionFooterBar(
                selectedCount: viewModel.selectedCount,
                selectedSize: viewModel.selectedSize,
                isCleaning: viewModel.isCleaning,
                cleanProgress: viewModel.cleanProgress,
                restoreResult: viewModel.lastRestoreResult,
                warning: viewModel.isAppRunning ? String(localized: "请先退出\(viewModel.app.title)") : nil,
                action: {
                    viewModel.refreshRunning()
                    if viewModel.isAppRunning { showRunningAlert = true; return }
                    guard ProGate.allowAction() else { return }
                    showConfirm = true
                }
            )
        } else if scanningThisApp {
            VStack {
                ChatScanProgressRow(count: viewModel.scannedFiles)
                    .padding(.horizontal, CosmicSizes.pagePadding)
                    .padding(.top, 16)
                Spacer()
            }
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    banners(unreadable: false)
                    if viewModel.availableApps.isEmpty {
                        ChatEmptyState(app: nil, unreadable: false)
                    } else {
                        ScanIntroView(
                            icon: "bubble.left.and.bubble.right",
                            title: String(localized: "扫描\(viewModel.app.title)的聊天媒体"),
                            message: String(localized: "找出聊天里的图片、视频、文件和语音占了多少空间，按会话、日期和类型挑选要清理的部分。"),
                            points: [
                                String(localized: "按会话找出最占空间的聊天"),
                                String(localized: "按日期清理，比如一年前的视频"),
                                String(localized: "图片、视频、文件、语音分开选择"),
                                String(localized: "只删媒体文件，不碰聊天记录，可在清理记录中恢复"),
                            ],
                            compact: true,
                            action: { viewModel.scan() }
                        )
                    }
                }
                .padding(.horizontal, CosmicSizes.pagePadding)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
        }
    }

    @ViewBuilder
    private func banners(unreadable: Bool) -> some View {
        if viewModel.isAppRunning {
            ChatRunningBanner(app: viewModel.app, onQuit: { viewModel.quitApp() })
        }
        if unreadable {
            ChatFullDiskAccessBanner(app: viewModel.app, onRetry: { viewModel.scan() })
        }
    }

    @ViewBuilder
    private func resultsBody(_ account: ChatAccount) -> some View {
        if viewModel.accounts.count > 1 {
            ChatAccountPicker(viewModel: viewModel)
        }
        ChatSummaryCard(viewModel: viewModel, account: account)
        ChatPrivacyNote(app: viewModel.app, account: account)
        if !account.largeFiles.isEmpty {
            ChatLargeFilesCard(viewModel: viewModel, account: account)
        }
        Text(viewModel.app.groupsByConversation ? String(localized: "按会话") : String(localized: "按月份"))
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(AppTheme.textPrimary)
            .padding(.top, 4)
            .id(Self.groupsAnchor)
        LazyVStack(spacing: 10) {
            ForEach(account.groups) { group in
                ChatGroupCard(viewModel: viewModel, account: account, group: group)
            }
        }
    }

    static let groupsAnchor = "chat-groups"

    // MARK: - 确认文案

    private var confirmMessage: String {
        let byType = viewModel.selectedSizeByType
        let lines = ChatMediaType.allCases.compactMap { type -> String? in
            guard let size = byType[type], size > 0 else { return nil }
            return "\(type.title)  \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
        }
        let total = ByteCountFormatter.string(fromByteCount: viewModel.selectedSize, countStyle: .file)
        let appName = viewModel.app.title
        return [
            String(localized: "共 \(total)："),
            lines.joined(separator: "\n"),
            "",
            String(localized: "删除后，\(appName)里对应的图片、视频和文件会显示为「已过期」或「已被清理」；聊天文字记录不受影响。"),
            String(localized: "移入废纸篓，可在「清理记录」中恢复。"),
        ].joined(separator: "\n")
    }
}
