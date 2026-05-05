//
//  MenuBarView.swift
//  MacClean
//
//  菜单栏弹出窗口视图
//

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        VStack(spacing: 0) {
            // 头部
            headerSection
            
            Divider()
            
            // 磁盘信息
            diskInfoSection
            
            Divider()
            
            // 可清理空间
            cleanableSection
            
            Divider()
            
            // 操作按钮
            actionsSection
            
            Divider()
            
            // 底部菜单
            footerSection
        }
        .frame(width: 280)
        .background(.regularMaterial)
    }
    
    // MARK: - 头部
    private var headerSection: some View {
        HStack {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.title2)
                .foregroundColor(.accentColor)
            
            Text("MacClean")
                .font(.headline)
            
            Spacer()
            
            // 许可证状态
            if appState.isLicensed {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
            } else {
                Text("trial")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.2))
                    .foregroundColor(.orange)
                    .cornerRadius(4)
            }
        }
        .padding()
    }
    
    // MARK: - 磁盘信息
    private var diskInfoSection: some View {
        VStack(spacing: 12) {
            if let diskInfo = appState.diskInfo {
                // 圆环进度
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 8)
                    
                    Circle()
                        .trim(from: 0, to: CGFloat(diskInfo.usedPercentage))
                        .stroke(usageColor(diskInfo.usedPercentage), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    
                    VStack(spacing: 2) {
                        Text("\(Int(diskInfo.usedPercentage * 100))%")
                            .font(.title2.bold())
                        Text("used")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 80, height: 80)
                
                // 空间详情
                HStack {
                    VStack(alignment: .leading) {
                        Text("used")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: diskInfo.usedSpace, countStyle: .file))
                            .font(.subheadline.bold())
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing) {
                        Text("available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: diskInfo.freeSpace, countStyle: .file))
                            .font(.subheadline.bold())
                    }
                }
            } else {
                // 未扫描状态
                VStack(spacing: 8) {
                    Image(systemName: "externaldrive")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("no_disk_info")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(height: 80)
            }
        }
        .padding()
    }
    
    // MARK: - 可清理空间
    private var cleanableSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("cleanable")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(ByteCountFormatter.string(fromByteCount: appState.totalCleanableSize, countStyle: .file))
                    .font(.subheadline.bold())
                    .foregroundColor(appState.totalCleanableSize > 0 ? .orange : .secondary)
            }
            
            if appState.isScanning {
                ProgressView(value: appState.scanProgress)
                    .progressViewStyle(.linear)
                Text(appState.scanStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
    
    // MARK: - 操作按钮
    private var actionsSection: some View {
        VStack(spacing: 8) {
            // 快速清理按钮
            Button(action: {
                appState.startQuickClean()
            }) {
                HStack {
                    if appState.isCleaning {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "trash.fill")
                    }
                    Text("quick_clean")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.isCleaning || appState.totalCleanableSize == 0)
            
            // 扫描按钮
            Button(action: {
                appState.startDiskScan()
            }) {
                HStack {
                    if appState.isScanning {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("scan_disk")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(appState.isScanning)
        }
        .padding()
    }
    
    // MARK: - 底部菜单
    private var footerSection: some View {
        VStack(spacing: 4) {
            Button(action: {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.title == "MacClean" || $0.isKeyWindow }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }) {
                HStack {
                    Text("open_macclean")
                    Spacer()
                    Image(systemName: "arrow.up.forward.square")
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 6)
            
            Button(action: {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }) {
                HStack {
                    Text("preferences")
                    Spacer()
                    Text("⌘,")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 6)
            
            Divider()
            
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack {
                    Text("quit")
                    Spacer()
                    Text("⌘Q")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Helper
    private func usageColor(_ percentage: Double) -> Color {
        if percentage > 0.9 {
            return .red
        } else if percentage > 0.75 {
            return .orange
        } else {
            return .accentColor
        }
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState.shared)
}
