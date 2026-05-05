//
//  JunkCleanerView.swift
//  MacClean
//
//  垃圾清理管理器视图 - 类似 CleanMyMac 的三栏布局
//

import SwiftUI
import Combine

// MARK: - 垃圾分类
enum JunkCategory: String, CaseIterable, Identifiable {
    case systemJunk = "system_junk"
    case mailAttachments = "mail_attachments"
    case trash = "trash_bin"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .systemJunk: return "系统垃圾"
        case .mailAttachments: return "邮件附件"
        case .trash: return "废纸篓"
        }
    }
    
    var icon: String {
        switch self {
        case .systemJunk: return "gearshape.fill"
        case .mailAttachments: return "envelope.fill"
        case .trash: return "trash.fill"
        }
    }
}

// MARK: - 系统垃圾子分类
enum SystemJunkType: String, CaseIterable, Identifiable {
    case userCacheFiles = "user_cache_files"
    case universalBinaries = "universal_binaries"
    case systemLogFiles = "system_log_files"
    case userLogFiles = "user_log_files"
    case languageFiles = "language_files"
    case brokenLoginItems = "broken_login_items"
    case systemCacheFiles = "system_cache_files"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .userCacheFiles: return "用户缓存文件"
        case .universalBinaries: return "通用二进制文件"
        case .systemLogFiles: return "系统日志文件"
        case .userLogFiles: return "用户日志文件"
        case .languageFiles: return "语言文件"
        case .brokenLoginItems: return "损坏的登录项"
        case .systemCacheFiles: return "系统缓存文件"
        }
    }
    
    var description: String {
        switch self {
        case .userCacheFiles: return "冗余文件会占用存储空间，影响设备发挥最佳性能。"
        case .universalBinaries: return "移除不需要的处理器架构支持文件"
        case .systemLogFiles: return "系统生成的诊断日志文件"
        case .userLogFiles: return "应用程序生成的日志文件"
        case .languageFiles: return "未使用的语言本地化文件"
        case .brokenLoginItems: return "已失效或损坏的登录项目"
        case .systemCacheFiles: return "系统级别的缓存文件"
        }
    }
    
    var icon: String {
        switch self {
        case .userCacheFiles: return "folder.badge.person.crop"
        case .universalBinaries: return "cpu"
        case .systemLogFiles: return "doc.text.fill"
        case .userLogFiles: return "doc.text"
        case .languageFiles: return "globe"
        case .brokenLoginItems: return "exclamationmark.triangle.fill"
        case .systemCacheFiles: return "internaldrive"
        }
    }
    
    var color: Color {
        switch self {
        case .userCacheFiles: return .green
        case .universalBinaries: return .blue
        case .systemLogFiles: return .purple
        case .userLogFiles: return .orange
        case .languageFiles: return .cyan
        case .brokenLoginItems: return .red
        case .systemCacheFiles: return .gray
        }
    }
}

// MARK: - 详细项目模型
struct JunkDetailItem: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var path: String
    var size: Int64
    var isSelected: Bool
    var appIcon: NSImage?
    var type: SystemJunkType
    
    static func == (lhs: JunkDetailItem, rhs: JunkDetailItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 分类汇总模型
struct JunkTypeSummary: Identifiable {
    let id = UUID()
    let type: SystemJunkType
    var items: [JunkDetailItem]
    var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }
    var selectedSize: Int64 {
        items.filter { $0.isSelected }.reduce(0) { $0 + $1.size }
    }
    var selectedCount: Int {
        items.filter { $0.isSelected }.count
    }
}

// MARK: - 主视图
struct JunkCleanerView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = JunkCleanerViewModel()
    @State private var selectedCategory: JunkCategory = .systemJunk
    @State private var selectedType: SystemJunkType? = .userCacheFiles
    
    var body: some View {
        ZStack {
            // 浅色背景
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // 顶部导航栏
                topNavigationBar
                
                Divider()
                
                // 三栏布局
                HStack(spacing: 0) {
                    // 左侧：主分类
                    leftCategoryPanel
                        .frame(width: 140)
                    
                    Divider()
                    
                    // 中间：子分类列表
                    middleTypePanel
                        .frame(width: 280)
                    
                    Divider()
                    
                    // 右侧：详细项目列表
                    rightDetailPanel
                }
                
                Divider()
                
                // 底部操作栏
                bottomActionBar
            }
        }
        .onAppear {
            if viewModel.summaries.isEmpty {
                viewModel.scanJunk()
            }
        }
    }
    
    // MARK: - 顶部导航栏
    private var topNavigationBar: some View {
        HStack {
            // 返回按钮
            Button(action: {
                appState.currentTab = .diskAnalysis
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("后退")
                }
                .foregroundColor(MacCleanTheme.accentColor)
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            Text("垃圾清理管理器")
                .font(.headline)
            
            Spacer()
            
            // 搜索和排序
            HStack(spacing: 16) {
                Button(action: {}) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                
                HStack(spacing: 4) {
                    Text("排序方式按:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Menu {
                        Button("大小") {}
                        Button("名称") {}
                        Button("日期") {}
                    } label: {
                        HStack(spacing: 2) {
                            Text("大小")
                                .foregroundColor(MacCleanTheme.accentColor)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundColor(MacCleanTheme.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }
    
    // MARK: - 左侧分类面板
    private var leftCategoryPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(JunkCategory.allCases) { category in
                CategoryRow(
                    category: category,
                    isSelected: selectedCategory == category,
                    itemCount: category == .systemJunk ? viewModel.summaries.count : 0
                ) {
                    selectedCategory = category
                    if category == .systemJunk {
                        selectedType = viewModel.summaries.first?.type
                    }
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
    
    // MARK: - 中间子分类面板
    private var middleTypePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题区域
            VStack(alignment: .leading, spacing: 8) {
                Text(selectedCategory.displayName)
                    .font(.title2.bold())
                
                Text(selectedType?.description ?? "冗余文件会占用存储空间，影响设备发挥最佳性能。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .padding()
            
            Divider()
            
            // 子分类列表
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.summaries) { summary in
                        JunkTypeRow(
                            summary: summary,
                            isSelected: selectedType == summary.type
                        ) {
                            selectedType = summary.type
                        }
                        
                        Divider()
                            .padding(.leading, 60)
                    }
                }
            }
        }
    }
    
    // MARK: - 右侧详细面板
    private var rightDetailPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let type = selectedType,
               let summaryIndex = viewModel.summaries.firstIndex(where: { $0.type == type }) {
                let summary = viewModel.summaries[summaryIndex]
                
                // 标题
                VStack(alignment: .leading, spacing: 8) {
                    Text(type.displayName)
                        .font(.title3.bold())
                    
                    Text("应用程序的缓存文件原本用来缩短开机时间，但最终会大量堆积，并导致无法正常运行或整体性能下降。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    
                    // 选择控制
                    HStack {
                        Text("选择:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Menu {
                            Button("智能") {
                                viewModel.smartSelect(for: type)
                            }
                            Button("全部") {
                                viewModel.selectAll(for: type, selected: true)
                            }
                            Button("无") {
                                viewModel.selectAll(for: type, selected: false)
                            }
                        } label: {
                            HStack(spacing: 2) {
                                Text("智能")
                                    .foregroundColor(MacCleanTheme.accentColor)
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                                    .foregroundColor(MacCleanTheme.accentColor)
                            }
                        }
                        .buttonStyle(.plain)
                        
                        Spacer()
                    }
                }
                .padding()
                
                Divider()
                
                // 详细项目列表
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(summary.items.enumerated()), id: \.element.id) { index, item in
                            DetailItemRow(
                                item: binding(for: item, in: type),
                                onShowInFinder: {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.path)
                                }
                            )
                            
                            if index < summary.items.count - 1 {
                                Divider()
                                    .padding(.leading, 60)
                            }
                        }
                    }
                }
            } else {
                // 空状态
                VStack {
                    Spacer()
                    Text("选择一个分类查看详情")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private func binding(for item: JunkDetailItem, in type: SystemJunkType) -> Binding<JunkDetailItem> {
        Binding(
            get: {
                if let summaryIndex = viewModel.summaries.firstIndex(where: { $0.type == type }),
                   let itemIndex = viewModel.summaries[summaryIndex].items.firstIndex(where: { $0.id == item.id }) {
                    return viewModel.summaries[summaryIndex].items[itemIndex]
                }
                return item
            },
            set: { newValue in
                if let summaryIndex = viewModel.summaries.firstIndex(where: { $0.type == type }),
                   let itemIndex = viewModel.summaries[summaryIndex].items.firstIndex(where: { $0.id == item.id }) {
                    viewModel.summaries[summaryIndex].items[itemIndex] = newValue
                }
            }
        )
    }
    
    // MARK: - 底部操作栏
    private var bottomActionBar: some View {
        HStack {
            Spacer()
            
            // 已选择统计
            VStack(spacing: 2) {
                Text("已选择 \(viewModel.totalSelectedCount) 项")
                    .font(.subheadline)
                Text(ByteCountFormatter.string(fromByteCount: viewModel.totalSelectedSize, countStyle: .file))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // 完成按钮
            Button(action: {
                viewModel.cleanSelected()
            }) {
                Text("完成")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(MacCleanTheme.accentColor)
                    )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.totalSelectedSize == 0 || viewModel.isCleaning)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - 分类行
struct CategoryRow: View {
    let category: JunkCategory
    let isSelected: Bool
    let itemCount: Int
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Text(category.displayName)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundColor(isSelected ? .primary : .secondary)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(isSelected ? MacCleanTheme.accentColor.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 子分类行
struct JunkTypeRow: View {
    let summary: JunkTypeSummary
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // 图标
                ZStack {
                    Circle()
                        .fill(summary.type.color.opacity(0.15))
                        .frame(width: 40, height: 40)
                    
                    Image(systemName: summary.type.icon)
                        .font(.system(size: 16))
                        .foregroundColor(summary.type.color)
                }
                
                // 名称和大小
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.type.displayName)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    
                    Text(ByteCountFormatter.string(fromByteCount: summary.totalSize, countStyle: .file))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // 大小标签
                Text(ByteCountFormatter.string(fromByteCount: summary.totalSize, countStyle: .file))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(summary.type.color)
                    )
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(isSelected ? MacCleanTheme.accentColor.opacity(0.08) : (isHovered ? Color.gray.opacity(0.05) : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 详细项目行
struct DetailItemRow: View {
    @Binding var item: JunkDetailItem
    let onShowInFinder: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            // 选择状态指示
            selectionIndicator
            
            // 应用图标
            if let icon = item.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.blue)
                    .frame(width: 32, height: 32)
            }
            
            // 名称
            Text(item.name)
                .font(.subheadline)
                .foregroundColor(.primary)
                .lineLimit(1)
            
            Spacer()
            
            // 大小
            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                .font(.caption)
                .foregroundColor(.secondary)
            
            // 箭头 / 展开详情
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(isHovered ? Color.gray.opacity(0.05) : Color.clear)
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            item.isSelected.toggle()
        }
    }
    
    private var selectionIndicator: some View {
        Button(action: {
            item.isSelected.toggle()
        }) {
            ZStack {
                if item.isSelected {
                    // 选中状态 - 对勾
                    Circle()
                        .fill(MacCleanTheme.accentColor)
                        .frame(width: 22, height: 22)
                    
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    // 未选中 - 减号（表示可以排除）
                    Circle()
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                    
                    Image(systemName: "minus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.gray.opacity(0.5))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ViewModel
@MainActor
class JunkCleanerViewModel: ObservableObject {
    @Published var summaries: [JunkTypeSummary] = []
    @Published var isScanning = false
    @Published var isCleaning = false
    
    private let fileManager = FileManager.default
    
    var totalSelectedSize: Int64 {
        summaries.reduce(0) { $0 + $1.selectedSize }
    }
    
    var totalSelectedCount: Int {
        summaries.reduce(0) { $0 + $1.selectedCount }
    }
    
    func scanJunk() {
        isScanning = true
        
        // 使用 detached task 在后台线程执行，避免阻塞主线程
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            var newSummaries: [JunkTypeSummary] = []
            let homeDir = NSHomeDirectory()
            
            // 扫描用户缓存文件
            let userCacheItems = await self.scanUserCaches(homeDir: homeDir)
            if !userCacheItems.isEmpty {
                newSummaries.append(JunkTypeSummary(type: .userCacheFiles, items: userCacheItems))
            }
            
            // 扫描系统日志
            let systemLogItems = await self.scanSystemLogs(homeDir: homeDir)
            if !systemLogItems.isEmpty {
                newSummaries.append(JunkTypeSummary(type: .systemLogFiles, items: systemLogItems))
            }
            
            // 扫描用户日志
            let userLogItems = await self.scanUserLogs(homeDir: homeDir)
            if !userLogItems.isEmpty {
                newSummaries.append(JunkTypeSummary(type: .userLogFiles, items: userLogItems))
            }
            
            // 扫描语言文件 (模拟)
            let languageItems = await self.scanLanguageFiles(homeDir: homeDir)
            if !languageItems.isEmpty {
                newSummaries.append(JunkTypeSummary(type: .languageFiles, items: languageItems))
            }
            
            // 按大小排序
            newSummaries.sort { $0.totalSize > $1.totalSize }
            
            await MainActor.run {
                self.summaries = newSummaries
                self.isScanning = false
            }
        }
    }
    
    private func scanUserCaches(homeDir: String) async -> [JunkDetailItem] {
        var items: [JunkDetailItem] = []
        let cachesPath = homeDir + "/Library/Caches"
        
        guard let contents = try? fileManager.contentsOfDirectory(atPath: cachesPath) else {
            return items
        }
        
        for folder in contents {
            let folderPath = cachesPath + "/" + folder
            let size = calculateDirectorySize(at: folderPath)
            
            if size > 5_000_000 { // 大于 5MB
                // 尝试获取应用图标
                var appIcon: NSImage? = nil
                let appName = extractAppName(from: folder)
                if let appPath = findAppPath(for: appName) {
                    appIcon = NSWorkspace.shared.icon(forFile: appPath)
                }
                
                items.append(JunkDetailItem(
                    name: appName.isEmpty ? folder : appName,
                    path: folderPath,
                    size: size,
                    isSelected: true,
                    appIcon: appIcon,
                    type: .userCacheFiles
                ))
            }
        }
        
        return items.sorted { $0.size > $1.size }
    }
    
    private func scanSystemLogs(homeDir: String) async -> [JunkDetailItem] {
        var items: [JunkDetailItem] = []
        let logsPath = "/var/log"
        
        if let contents = try? fileManager.contentsOfDirectory(atPath: logsPath) {
            for file in contents {
                let filePath = logsPath + "/" + file
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: filePath, isDirectory: &isDir) {
                    let size = isDir.boolValue ? calculateDirectorySize(at: filePath) : getFileSize(at: filePath)
                    if size > 1_000_000 {
                        items.append(JunkDetailItem(
                            name: file,
                            path: filePath,
                            size: size,
                            isSelected: true,
                            appIcon: nil,
                            type: .systemLogFiles
                        ))
                    }
                }
            }
        }
        
        return items.sorted { $0.size > $1.size }
    }
    
    private func scanUserLogs(homeDir: String) async -> [JunkDetailItem] {
        var items: [JunkDetailItem] = []
        let logsPath = homeDir + "/Library/Logs"
        
        if let contents = try? fileManager.contentsOfDirectory(atPath: logsPath) {
            for folder in contents {
                let folderPath = logsPath + "/" + folder
                let size = calculateDirectorySize(at: folderPath)
                
                if size > 1_000_000 {
                    var appIcon: NSImage? = nil
                    let appName = extractAppName(from: folder)
                    if let appPath = findAppPath(for: appName) {
                        appIcon = NSWorkspace.shared.icon(forFile: appPath)
                    }
                    
                    items.append(JunkDetailItem(
                        name: folder,
                        path: folderPath,
                        size: size,
                        isSelected: true,
                        appIcon: appIcon,
                        type: .userLogFiles
                    ))
                }
            }
        }
        
        return items.sorted { $0.size > $1.size }
    }
    
    private func scanLanguageFiles(homeDir: String) async -> [JunkDetailItem] {
        // 暂时返回空，语言文件扫描较复杂
        return []
    }
    
    private func calculateDirectorySize(at path: String, maxDepth: Int = 5, maxFiles: Int = 3000) -> Int64 {
        var totalSize: Int64 = 0
        var fileCount = 0
        
        let url = URL(fileURLWithPath: path)
        
        // 尝试使用系统 API 快速获取大小
        if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]) {
            if let size = values.totalFileAllocatedSize {
                return Int64(size)
            }
        }
        
        // 降级到手动遍历，但限制深度和数量
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return 0
        }
        
        while let fileURL = enumerator.nextObject() as? URL {
            fileCount += 1
            if fileCount > maxFiles {
                // 估算剩余大小
                if fileCount > 0 {
                    let avgSize = totalSize / Int64(fileCount)
                    totalSize += avgSize * 50
                }
                break
            }
            
            // 限制深度
            let depth = fileURL.pathComponents.count - url.pathComponents.count
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true,
               let size = values.fileSize {
                totalSize += Int64(size)
            }
        }
        
        return totalSize
    }
    
    private func getFileSize(at path: String) -> Int64 {
        if let attributes = try? fileManager.attributesOfItem(atPath: path),
           let fileSize = attributes[.size] as? Int64 {
            return fileSize
        }
        return 0
    }
    
    private func extractAppName(from bundleId: String) -> String {
        // 尝试从 bundle id 提取应用名称
        let components = bundleId.components(separatedBy: ".")
        if components.count >= 3 {
            return components.last ?? bundleId
        }
        return bundleId
    }
    
    private func findAppPath(for appName: String) -> String? {
        let applicationPaths = [
            "/Applications",
            NSHomeDirectory() + "/Applications"
        ]
        
        for basePath in applicationPaths {
            let appPath = basePath + "/" + appName + ".app"
            if fileManager.fileExists(atPath: appPath) {
                return appPath
            }
        }
        
        return nil
    }
    
    func selectAll(for type: SystemJunkType, selected: Bool) {
        if let index = summaries.firstIndex(where: { $0.type == type }) {
            for i in summaries[index].items.indices {
                summaries[index].items[i].isSelected = selected
            }
        }
    }
    
    func smartSelect(for type: SystemJunkType) {
        // 智能选择：选择大于 10MB 的项目
        if let index = summaries.firstIndex(where: { $0.type == type }) {
            for i in summaries[index].items.indices {
                summaries[index].items[i].isSelected = summaries[index].items[i].size > 10_000_000
            }
        }
    }
    
    func cleanSelected() {
        isCleaning = true
        
        Task {
            for summaryIndex in summaries.indices {
                let selectedItems = summaries[summaryIndex].items.filter { $0.isSelected }
                
                for item in selectedItems {
                    do {
                        // 清理目录内容而不是删除目录本身
                        if let contents = try? fileManager.contentsOfDirectory(atPath: item.path) {
                            for file in contents {
                                let filePath = item.path + "/" + file
                                try fileManager.removeItem(atPath: filePath)
                            }
                        }
                    } catch {
                        print("清理失败: \(item.path) - \(error)")
                    }
                }
                
                // 移除已清理的项目
                await MainActor.run {
                    summaries[summaryIndex].items.removeAll { $0.isSelected }
                }
            }
            
            await MainActor.run {
                // 移除空的分类
                summaries.removeAll { $0.items.isEmpty }
                isCleaning = false
            }
        }
    }
}

#Preview {
    JunkCleanerView()
        .environmentObject(AppState.shared)
        .frame(width: 1000, height: 700)
}
