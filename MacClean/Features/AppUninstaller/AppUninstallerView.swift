//
//  AppUninstallerView.swift
//  MacClean
//
//  应用卸载视图 - 完整功能版本
//

import SwiftUI
import Combine

// MARK: - 视图状态
enum AppUninstallerState {
    case initial      // 初始状态
    case scanning     // 扫描中
    case results      // 显示结果
    case uninstalling // 卸载中
}

// MARK: - 主视图
struct AppUninstallerView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = AppUninstallerViewModel()
    
    var body: some View {
        ZStack {
            AuraPageBackground()
            
            VStack(spacing: 0) {
                // 顶部栏
                topBar
                
                // 主内容区域
                switch viewModel.state {
                case .initial:
                    initialView
                case .scanning:
                    scanningView
                case .results:
                    resultsView
                case .uninstalling:
                    uninstallingView
                }
            }
        }
    }
    
    // MARK: - 顶部栏
    private var topBar: some View {
        HStack {
            if viewModel.state == .results {
                Button(action: {
                    withAnimation {
                        viewModel.resetToInitial()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("重新开始")
                    }
                    .font(.subheadline)
                    .foregroundColor(MacCleanTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            
            Spacer()
            
            Text("应用程序")
                .font(.headline)
                .foregroundColor(.white)
            
            Spacer()
            
            // 升级按钮
            if !appState.isLicensed {
                Button(action: {
                    appState.showLicenseActivation = true
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "crown.fill")
                        Text("解锁完整版")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: 0xFFD700), Color(hex: 0xFFA500)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 50)
        .padding(.bottom, 20)
    }
    
    // MARK: - 初始视图
    private var initialView: some View {
        VStack(spacing: 30) {
            Spacer()
            
            // 3D 图标
            AppUninstallerIcon3D()
                .frame(width: 200, height: 200)
            
            // 标题
            Text("应用程序")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.white)
            
            // 描述
            VStack(spacing: 8) {
                Text("掌控您的应用程序。卸载、更新")
                    .foregroundColor(MacCleanTheme.textSecondary)
                Text("或删除旧的应用程序残留文件。")
                    .foregroundColor(MacCleanTheme.textSecondary)
            }
            .font(.subheadline)
            .multilineTextAlignment(.center)
            
            Spacer()
            
            // 扫描按钮
            Button(action: {
                viewModel.startScan()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("扫描")
                }
            }
            .buttonStyle(NeonButtonStyle(isLarge: true))
            .padding(.bottom, 50)
        }
    }
    
    // MARK: - 扫描中视图
    private var scanningView: some View {
        VStack(spacing: 30) {
            Spacer()
            
            // 扫描动画图标
            ZStack {
                AppUninstallerIcon3D()
                    .frame(width: 180, height: 180)
                
                // 扫描进度环
                Circle()
                    .trim(from: 0, to: viewModel.scanProgress)
                    .stroke(
                        MacCleanTheme.accentGlow,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .frame(width: 200, height: 200)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: viewModel.scanProgress)
            }
            
            // 状态文字
            Text("正在扫描应用程序文件...")
                .font(.title2.bold())
                .foregroundColor(.white)
            
            Text("正在查找应用程序、更新和残留文件。")
                .font(.subheadline)
                .foregroundColor(MacCleanTheme.textSecondary)
            
            if !viewModel.currentScanningItem.isEmpty {
                Text(viewModel.currentScanningItem)
                    .font(.caption)
                    .foregroundColor(MacCleanTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 400)
            }
            
            Spacer()
            
            // 停止按钮
            Button(action: {
                viewModel.stopScan()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill")
                    Text("停止")
                }
            }
            .buttonStyle(NeonOutlineButtonStyle(color: CosmicTheme.textSecondary))
            .padding(.bottom, 50)
        }
    }
    
    // MARK: - 结果视图
    private var resultsView: some View {
        VStack(spacing: 24) {
            // 顶部汇总
            VStack(spacing: 16) {
                Text("我们在您的 Mac 电脑上找到了 \(viewModel.scanResult?.totalAppsCount ?? 0) 个 App。")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                
                Button(action: {
                    viewModel.showAppManager = true
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                        Text("管理我的应用程序")
                    }
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
            
            // 结果卡片网格
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 16) {
                    // 可更新应用卡片
                    if let result = viewModel.scanResult {
                        ResultCard(
                            title: "\(result.updatableApps.count) 个可用的应用程序更新",
                            description: "更新您的软件，以获得最新的功能和兼容性改进。",
                            icons: result.updatableApps.prefix(3).map { $0.icon },
                            color: .green,
                            onCheck: { viewModel.showUpdates = true },
                            onAction: { viewModel.updateApps() },
                            actionTitle: "更新"
                        )
                        
                        // 未使用应用卡片
                        ResultCard(
                            title: "已发现 \(result.unusedApps.count) 个未使用的应用程序",
                            description: "您可能不需要这些应用程序，但它们占用了 \(ByteCountFormatter.string(fromByteCount: result.unusedAppsSize, countStyle: .file)) 的存储空间。",
                            icons: result.unusedApps.prefix(3).map { $0.icon },
                            color: .orange,
                            onCheck: { viewModel.showUnusedApps = true },
                            onAction: nil,
                            actionTitle: nil
                        )
                        
                        // 残留文件卡片
                        ResultCard(
                            title: "发现 \(ByteCountFormatter.string(fromByteCount: result.leftoverSize, countStyle: .file)) 的 \(result.leftoverFiles.count) 个应用程序残留文件",
                            description: nil,
                            icons: [],
                            color: .blue,
                            iconSystemName: "wrench.and.screwdriver.fill",
                            onCheck: { viewModel.showLeftovers = true },
                            onAction: { viewModel.removeLeftovers() },
                            actionTitle: "移除"
                        )
                        
                        // 安装包卡片
                        ResultCard(
                            title: "已发现 \(ByteCountFormatter.string(fromByteCount: result.installerSize, countStyle: .file)) 的安装文件",
                            description: nil,
                            icons: [],
                            color: .purple,
                            iconSystemName: "externaldrive.fill",
                            onCheck: { viewModel.showInstallers = true },
                            onAction: nil,
                            actionTitle: nil
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $viewModel.showAppManager) {
            AppManagerSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showUnusedApps) {
            UnusedAppsSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showLeftovers) {
            LeftoversSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showInstallers) {
            InstallersSheet(viewModel: viewModel)
        }
    }
    
    // MARK: - 卸载中视图
    private var uninstallingView: some View {
        VStack(spacing: 30) {
            Spacer()
            
            ProgressView()
                .scaleEffect(2)
                .tint(MacCleanTheme.accentGlow)
            
            Text("正在卸载应用...")
                .font(.title2.bold())
                .foregroundColor(.white)
            
            Text(viewModel.uninstallStatus)
                .font(.subheadline)
                .foregroundColor(MacCleanTheme.textSecondary)
            
            Spacer()
        }
    }
}

// MARK: - 3D 应用图标
struct AppUninstallerIcon3D: View {
    @State private var rotation: Double = 0
    
    var body: some View {
        ZStack {
            // 外层光晕
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(hex: 0x4A90E2).opacity(0.3),
                            Color(hex: 0x4A90E2).opacity(0.0)
                        ],
                        center: .center,
                        startRadius: 60,
                        endRadius: 120
                    )
                )
                .frame(width: 220, height: 220)
            
            // 六边形背景
            HexagonShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: 0x3B7DD8),
                            Color(hex: 0x2E5A9E),
                            Color(hex: 0x1E3A6E)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 160, height: 160)
                .shadow(color: Color(hex: 0x4A90E2).opacity(0.5), radius: 20, x: 0, y: 10)
            
            // 玻璃效果层
            HexagonShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.2),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .frame(width: 160, height: 160)
            
            // 工具图标
            VStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
                    .rotationEffect(.degrees(rotation))
                
                // 底部装饰点
                HStack(spacing: 6) {
                    ForEach(0..<5) { i in
                        Circle()
                            .fill(Color.white.opacity(0.8))
                            .frame(width: 6, height: 6)
                            .offset(y: sin(rotation / 180 * .pi + Double(i)) * 3)
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                rotation = 10
            }
        }
    }
}

// MARK: - 六边形形状
struct HexagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        
        for i in 0..<6 {
            let angle = CGFloat(i) * .pi / 3 - .pi / 2
            let point = CGPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle)
            )
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - 结果卡片
struct ResultCard: View {
    let title: String
    let description: String?
    let icons: [NSImage?]
    let color: Color
    var iconSystemName: String? = nil
    let onCheck: () -> Void
    let onAction: (() -> Void)?
    let actionTitle: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
                .lineLimit(2)
            
            // 描述
            if let description = description {
                Text(description)
                    .font(.caption)
                    .foregroundColor(MacCleanTheme.textSecondary)
                    .lineLimit(2)
            }
            
            Spacer()
            
            // 底部区域
            HStack {
                // 图标展示
                if !icons.isEmpty {
                    HStack(spacing: -8) {
                        ForEach(0..<min(icons.count, 3), id: \.self) { index in
                            if let icon = icons[index] {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                                    )
                            }
                        }
                    }
                } else if let systemName = iconSystemName {
                    ZStack {
                        Circle()
                            .fill(color.opacity(0.2))
                            .frame(width: 40, height: 40)
                        
                        Image(systemName: systemName)
                            .font(.system(size: 18))
                            .foregroundColor(color)
                    }
                }
                
                Spacer()
                
                // 操作按钮
                HStack(spacing: 8) {
                    Button(action: onCheck) {
                        Text("检查")
                            .font(.caption.bold())
                            .foregroundColor(MacCleanTheme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .stroke(MacCleanTheme.textSecondary.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    
                    if let action = onAction, let title = actionTitle {
                        Button(action: action) {
                            Text(title)
                                .font(.caption.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(color)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .frame(height: 160)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

// MARK: - ViewModel
@MainActor
class AppUninstallerViewModel: ObservableObject {
    @Published var state: AppUninstallerState = .initial
    @Published var scanProgress: Double = 0
    @Published var currentScanningItem: String = ""
    @Published var scanResult: AppScanResult?
    @Published var uninstallStatus: String = ""
    
    // Sheet 状态
    @Published var showAppManager = false
    @Published var showUnusedApps = false
    @Published var showLeftovers = false
    @Published var showInstallers = false
    @Published var showUpdates = false
    
    // 选中的应用
    @Published var selectedApps: [AppInfo] = []
    
    private var scanTask: Task<Void, Never>?
    
    func startScan() {
        state = .scanning
        scanProgress = 0
        currentScanningItem = ""
        
        scanTask = Task {
            do {
                // 模拟扫描进度
                for i in 1...10 {
                    try? await Task.sleep(nanoseconds: 200_000_000) // 0.2秒
                    
                    if Task.isCancelled { return }
                    
                    scanProgress = Double(i) / 10.0
                    
                    switch i {
                    case 1...3:
                        currentScanningItem = "正在扫描 /Applications..."
                    case 4...5:
                        currentScanningItem = "正在查找未使用的应用..."
                    case 6...7:
                        currentScanningItem = "正在扫描残留文件..."
                    case 8...9:
                        currentScanningItem = "正在检查安装包..."
                    default:
                        currentScanningItem = "正在完成..."
                    }
                }
                
                // 执行真正的扫描
                let result = try await AppManager.shared.scanApplications()
                
                await MainActor.run {
                    self.scanResult = result
                    self.state = .results
                }
            } catch {
                print("扫描失败: \(error)")
                state = .initial
            }
        }
    }
    
    func stopScan() {
        scanTask?.cancel()
        state = .initial
    }
    
    func resetToInitial() {
        state = .initial
        scanResult = nil
        scanProgress = 0
    }
    
    func updateApps() {
        // TODO: 实现更新功能
    }
    
    func removeLeftovers() {
        guard let result = scanResult else { return }
        
        state = .uninstalling
        uninstallStatus = "正在删除残留文件..."
        
        Task {
            do {
                try await AppManager.shared.deleteFiles(result.leftoverFiles)
                
                // 重新扫描
                startScan()
            } catch {
                print("删除失败: \(error)")
                state = .results
            }
        }
    }
    
    func uninstallSelectedApps() {
        guard !selectedApps.isEmpty else { return }
        
        state = .uninstalling
        
        Task {
            for app in selectedApps {
                uninstallStatus = "正在卸载 \(app.name)..."
                do {
                    try await AppManager.shared.uninstallApp(app)
                } catch {
                    print("卸载失败: \(error)")
                }
            }
            
            selectedApps.removeAll()
            startScan()
        }
    }
}

// MARK: - 应用管理 Sheet
struct AppManagerSheet: View {
    @ObservedObject var viewModel: AppUninstallerViewModel
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""
    @State private var selectedApp: AppInfo?
    
    private var filteredApps: [AppInfo] {
        guard let apps = viewModel.scanResult?.apps else { return [] }
        if searchText.isEmpty {
            return apps
        }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("管理应用程序")
                    .font(.title2.bold())
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            // 搜索栏
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索应用...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)
            
            // 应用列表
            HStack(spacing: 0) {
                // 左侧应用列表
                List(filteredApps, selection: $selectedApp) { app in
                    AppListRow(app: app, isSelected: selectedApp?.id == app.id)
                        .tag(app)
                }
                .listStyle(.sidebar)
                .frame(minWidth: 300)
                
                Divider()
                
                // 右侧详情
                if let app = selectedApp {
                    AppDetailView(app: app, onUninstall: {
                        viewModel.selectedApps = [app]
                        dismiss()
                        viewModel.uninstallSelectedApps()
                    })
                } else {
                    VStack {
                        Spacer()
                        Text("选择一个应用查看详情")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

// MARK: - 应用列表行
struct AppListRow: View {
    let app: AppInfo
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.blue)
                    .frame(width: 32, height: 32)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.subheadline.bold())
                
                Text(ByteCountFormatter.string(fromByteCount: app.totalSize, countStyle: .file))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - 应用详情视图
struct AppDetailView: View {
    let app: AppInfo
    let onUninstall: () -> Void
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // 应用图标和名称
                VStack(spacing: 16) {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 80, height: 80)
                    }
                    
                    Text(app.name)
                        .font(.title.bold())
                    
                    Text("版本 \(app.version)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 24)
                
                Divider()
                
                // 存储信息
                VStack(alignment: .leading, spacing: 16) {
                    Text("存储空间")
                        .font(.headline)
                    
                    HStack {
                        Text("应用本体")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: app.size, countStyle: .file))
                            .foregroundColor(.secondary)
                    }
                    
                    if !app.relatedFiles.isEmpty {
                        ForEach(app.relatedFiles) { file in
                            HStack {
                                Image(systemName: file.type.icon)
                                    .foregroundColor(.secondary)
                                Text(file.type.rawValue)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    Divider()
                    
                    HStack {
                        Text("总计")
                            .font(.headline)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: app.totalSize, countStyle: .file))
                            .font(.headline)
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal)
                
                Spacer()
                
                // 卸载按钮
                Button(action: onUninstall) {
                    HStack {
                        Image(systemName: "trash.fill")
                        Text("卸载")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.red)
                    )
                }
                .buttonStyle(.plain)
                .padding()
            }
        }
        .frame(minWidth: 400)
    }
}

// MARK: - 未使用应用 Sheet
struct UnusedAppsSheet: View {
    @ObservedObject var viewModel: AppUninstallerViewModel
    @Environment(\.dismiss) var dismiss
    @State private var selectedApps: Set<UUID> = []
    
    private var unusedApps: [AppInfo] {
        viewModel.scanResult?.unusedApps ?? []
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                VStack(alignment: .leading) {
                    Text("未使用的应用程序")
                        .font(.title2.bold())
                    Text("这些应用在过去 30 天内未被使用")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            // 应用列表
            List {
                ForEach(unusedApps) { app in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { selectedApps.contains(app.id) },
                            set: { isSelected in
                                if isSelected {
                                    selectedApps.insert(app.id)
                                } else {
                                    selectedApps.remove(app.id)
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 40, height: 40)
                        }
                        
                        VStack(alignment: .leading) {
                            Text(app.name)
                                .font(.headline)
                            if let lastUsed = app.lastUsedDate {
                                Text("上次使用: \(lastUsed, formatter: dateFormatter)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Spacer()
                        
                        Text(ByteCountFormatter.string(fromByteCount: app.totalSize, countStyle: .file))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            
            Divider()
            
            // 底部操作栏
            HStack {
                let selectedSize = unusedApps.filter { selectedApps.contains($0.id) }.reduce(0) { $0 + $1.totalSize }
                
                Text("已选择 \(selectedApps.count) 个应用，共 \(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: {
                    let appsToUninstall = unusedApps.filter { selectedApps.contains($0.id) }
                    viewModel.selectedApps = appsToUninstall
                    dismiss()
                    viewModel.uninstallSelectedApps()
                }) {
                    Text("卸载选中的应用")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(selectedApps.isEmpty ? Color.gray : Color.red)
                        )
                }
                .buttonStyle(.plain)
                .disabled(selectedApps.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 600, minHeight: 500)
    }
    
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }
}

// MARK: - 残留文件 Sheet
struct LeftoversSheet: View {
    @ObservedObject var viewModel: AppUninstallerViewModel
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                VStack(alignment: .leading) {
                    Text("应用程序残留文件")
                        .font(.title2.bold())
                    Text("这些文件来自已卸载的应用程序")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            // 残留文件列表
            if let leftovers = viewModel.scanResult?.leftoverFiles, !leftovers.isEmpty {
                List(leftovers) { file in
                    HStack(spacing: 12) {
                        Image(systemName: file.type.icon)
                            .font(.title2)
                            .foregroundColor(.orange)
                            .frame(width: 32)
                        
                        VStack(alignment: .leading) {
                            Text(file.name)
                                .font(.subheadline)
                            Text(file.path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                VStack {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.green)
                    Text("没有发现残留文件")
                        .font(.headline)
                        .padding(.top)
                    Spacer()
                }
            }
            
            Divider()
            
            // 底部操作栏
            HStack {
                if let leftovers = viewModel.scanResult?.leftoverFiles {
                    let totalSize = leftovers.reduce(0) { $0 + $1.size }
                    Text("共 \(leftovers.count) 个文件，\(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: {
                    dismiss()
                    viewModel.removeLeftovers()
                }) {
                    Text("删除全部")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(Color.red)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding()
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

// MARK: - 安装包 Sheet
struct InstallersSheet: View {
    @ObservedObject var viewModel: AppUninstallerViewModel
    @Environment(\.dismiss) var dismiss
    @State private var selectedInstallers: Set<UUID> = []
    
    private var installers: [InstallerFile] {
        viewModel.scanResult?.installers ?? []
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                VStack(alignment: .leading) {
                    Text("安装包文件")
                        .font(.title2.bold())
                    Text("下载文件夹中的安装包")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            // 安装包列表
            List {
                ForEach(installers) { installer in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { selectedInstallers.contains(installer.id) },
                            set: { isSelected in
                                if isSelected {
                                    selectedInstallers.insert(installer.id)
                                } else {
                                    selectedInstallers.remove(installer.id)
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        
                        Image(systemName: installer.name.lowercased().hasSuffix(".dmg") ? "externaldrive.fill" : "doc.zipper")
                            .font(.title2)
                            .foregroundColor(.purple)
                            .frame(width: 32)
                        
                        VStack(alignment: .leading) {
                            Text(installer.name)
                                .font(.subheadline)
                            Text(installer.path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        Text(ByteCountFormatter.string(fromByteCount: installer.size, countStyle: .file))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            
            Divider()
            
            // 底部操作栏
            HStack {
                let selectedSize = installers.filter { selectedInstallers.contains($0.id) }.reduce(0) { $0 + $1.size }
                
                Text("已选择 \(selectedInstallers.count) 个文件，共 \(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: {
                    // 删除选中的安装包
                    Task {
                        let toDelete = installers.filter { selectedInstallers.contains($0.id) }
                        try? await AppManager.shared.deleteInstallers(toDelete)
                        dismiss()
                        viewModel.startScan()
                    }
                }) {
                    Text("删除选中的文件")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(selectedInstallers.isEmpty ? Color.gray : Color.red)
                        )
                }
                .buttonStyle(.plain)
                .disabled(selectedInstallers.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

// MARK: - Preview
#Preview {
    AppUninstallerView()
        .environmentObject(AppState.shared)
        .frame(width: 900, height: 700)
}
