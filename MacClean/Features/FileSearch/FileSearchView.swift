//
//  FileSearchView.swift
//  MacClean
//
//  文件搜索页面：输入即搜（Spotlight 索引），可按范围/类型/大小/时间筛选，
//  支持打开、快速查看、在访达中显示、移到废纸篓（可撤销）。找不到时可改为直接遍历磁盘。
//

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class FileSearchViewModel: ObservableObject {
    enum Engine: Equatable {
        /// 正在检测 Spotlight 状态
        case detecting
        case spotlight
        /// MacClean 自建文件名索引
        case index
    }

    @Published var query = FileSearchQuery()
    @Published private(set) var selected: Set<String> = []

    @Published private(set) var engine: Engine = .detecting
    /// Spotlight 在当前范围是否关闭（决定是否自动改用自建索引）
    @Published private(set) var spotlightDisabled = false
    @Published var includeLibrary = false

    @Published private(set) var indexResults: [FileSearchResult] = []
    @Published private(set) var indexTotal = 0
    @Published private(set) var isIndexSearching = false
    @Published private(set) var isBuildingIndex = false
    @Published private(set) var indexedEntries = 0
    @Published private(set) var indexBuiltAt: Date?

    @Published private(set) var isCleaning = false
    @Published private(set) var lastCleanResult: CleanResult?
    @Published private(set) var lastRestoreResult: RestoreResult?

    let spotlight = SpotlightSearch()
    let limit = 1_000
    private var cancellables = Set<AnyCancellable>()
    private var indexTask: Task<Void, Never>?

    init() {
        spotlight.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // 输入防抖：停止输入 250ms 后再查询
        $query
            .removeDuplicates()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.run() }
            .store(in: &cancellables)

        $includeLibrary
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.run() } }
            .store(in: &cancellables)
    }

    var results: [FileSearchResult] { engine == .index ? indexResults : spotlight.results }
    var totalCount: Int { engine == .index ? indexTotal : spotlight.totalCount }
    var isSearching: Bool { engine == .index ? (isIndexSearching || isBuildingIndex) : spotlight.isSearching }
    var selectedResults: [FileSearchResult] { results.filter { selected.contains($0.path) } }
    var selectedSize: Int64 { selectedResults.reduce(0) { $0 + $1.size } }

    // MARK: 引擎选择

    /// 检测当前范围的 Spotlight 状态：关闭则自动改用自建索引。
    func detectEngine() {
        let path: String
        switch query.scope {
        case .home, .computer: path = FileManager.default.homeDirectoryForCurrentUser.path
        case .folders(let urls): path = urls.first?.path ?? "/"
        }
        engine = .detecting
        let ref = WeakRef(self)
        Task.detached(priority: .userInitiated) {
            let enabled = SpotlightStatus.isIndexingEnabled(for: path)
            await MainActor.run {
                guard let model = ref.object else { return }
                model.spotlightDisabled = !enabled
                model.engine = enabled ? .spotlight : .index
                model.run()
            }
        }
    }

    func useIndex() {
        engine = .index
        run()
    }

    func useSpotlight() {
        guard !spotlightDisabled else { return }
        indexTask?.cancel()
        engine = .spotlight
        run()
    }

    func setScope(_ scope: SearchScope) {
        query.scope = scope
        detectEngine()
    }

    // MARK: 查询

    private func run() {
        selected = []
        switch engine {
        case .detecting:
            return
        case .spotlight:
            spotlight.run(query)
        case .index:
            spotlight.stop()
            runIndexSearch(rebuild: false)
        }
    }

    func rebuildIndex() {
        runIndexSearch(rebuild: true)
    }

    private func runIndexSearch(rebuild: Bool) {
        indexTask?.cancel()
        let request = query
        let key = FileIndexStore.key(for: request.scope, includeLibrary: includeLibrary)
        let limit = self.limit
        let ref = WeakRef(self)

        indexTask = Task { [weak self] in
            guard let self else { return }
            var index = rebuild ? nil : await FileIndexStore.shared.cached(key)
            if index == nil {
                isBuildingIndex = true
                indexedEntries = 0
                index = await FileIndexStore.shared.index(for: key, rebuild: rebuild, progress: { count in
                    Task { @MainActor in ref.object?.indexedEntries = count }
                })
                isBuildingIndex = false
            }
            guard let index, !Task.isCancelled else { return }
            indexBuiltAt = index.builtAt

            guard !request.isEmpty else {
                indexResults = []
                indexTotal = 0
                return
            }
            isIndexSearching = true
            let found = await Task.detached(priority: .userInitiated) {
                index.search(request, limit: limit)
            }.value
            guard !Task.isCancelled else { return }
            indexResults = found.results
            indexTotal = found.totalMatches
            isIndexSearching = false
        }
    }

    func stop() {
        spotlight.stop()
        indexTask?.cancel()
    }

    // MARK: 选择与操作

    func toggle(_ result: FileSearchResult) {
        if selected.contains(result.path) { selected.remove(result.path) } else { selected.insert(result.path) }
    }

    func moveSelectedToTrash() async {
        guard !isCleaning else { return }
        let targets = selectedResults
        guard !targets.isEmpty else { return }
        isCleaning = true
        lastRestoreResult = nil
        let items = targets.map { result -> CleanableItem in
            var item = CleanableItem(
                name: result.name, path: result.path, size: result.size,
                category: .largeFiles, isSelected: true, description: nil, lastModified: result.modified
            )
            item.removesContainer = true
            return item
        }
        lastCleanResult = try? await CleanupManager.shared.clean(items: items)

        let gone = Set(targets.map(\.path).filter { !FileManager.default.fileExists(atPath: $0) })
        spotlight.remove(paths: gone)
        indexResults.removeAll { gone.contains($0.path) }
        selected.subtract(gone)
        isCleaning = false
    }

    func undoLastClean() async {
        guard let sessionID = lastCleanResult?.historySessionID else { return }
        lastRestoreResult = await CleanupManager.shared.restore(sessionID: sessionID)
        lastCleanResult = nil
        run()
    }
}

// MARK: - 文件操作

enum FileActions {
    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// 用系统的 qlmanage 弹出「快速查看」窗口。
    static func quickLook(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

// MARK: - 页面

struct FileSearchView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var viewModel = PageModelStore.shared.fileSearch
    @FocusState private var isFieldFocused: Bool

    @State private var showConfirm = false
    @State private var showCompletion = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "文件搜索"), subtitle: String(localized: "基于 Spotlight 索引，输入即出结果；也可以直接在磁盘上查找隐藏或未索引的文件"))

            VStack(spacing: 12) {
                searchField
                filterBar
            }
            .padding(.horizontal, CosmicSizes.pagePadding)
            .padding(.top, 20)

            statusBar
                .padding(.horizontal, CosmicSizes.pagePadding)
                .padding(.vertical, 10)

            resultsList

            if !viewModel.selected.isEmpty || viewModel.lastRestoreResult != nil {
                SelectionFooterBar(
                    selectedCount: viewModel.selected.count,
                    selectedSize: viewModel.selectedSize,
                    isCleaning: viewModel.isCleaning,
                    cleanProgress: 0,
                    restoreResult: viewModel.lastRestoreResult,
                    action: { guard ProGate.allowAction() else { return }; showConfirm = true }
                )
            }
        }
        .onAppear {
            consumePendingTerm()
            isFieldFocused = true
            viewModel.detectEngine()
        }
        .onChange(of: appState.pendingSearchTerm) { _, _ in consumePendingTerm() }
        .onDisappear { viewModel.stop() }
        .alert("移到废纸篓", isPresented: $showConfirm) {
            Button("取消", role: .cancel) {}
            Button("移到废纸篓", role: .destructive) {
                Task {
                    await viewModel.moveSelectedToTrash()
                    showCompletion = true
                }
            }
        } message: {
            Text("\(viewModel.selected.count) 项（\(ByteCountFormatter.string(fromByteCount: viewModel.selectedSize, countStyle: .file))）将移入废纸篓，可在「清理记录」中一键恢复。主目录以外与受保护的位置会被自动跳过。")
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
    }

    private func consumePendingTerm() {
        guard let term = appState.pendingSearchTerm else { return }
        viewModel.query.term = term
        appState.pendingSearchTerm = nil
    }

    // MARK: 搜索框

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(AppTheme.textMuted)
            TextField("搜索文件名，支持 * 通配，如 *.dmg、报告*2025", text: $viewModel.query.term)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundColor(AppTheme.textPrimary)
                .focused($isFieldFocused)
                .onSubmit {
                    if let first = viewModel.results.first { FileActions.open(first.path) }
                }
            if !viewModel.query.term.isEmpty {
                Button {
                    viewModel.query.term = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(AppTheme.textMuted)
                }
                .buttonStyle(.plain)
            }
            Toggle("匹配文件内容", isOn: $viewModel.query.matchContents)
                .toggleStyle(.checkbox)
                .disabled(viewModel.engine == .index)
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textSecondary)
                .help("同时搜索文档正文（PDF、Word、文本等，依赖 Spotlight 索引）")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: CosmicSizes.cardRadius)
                .fill(AppTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: CosmicSizes.cardRadius)
                        .stroke(isFieldFocused ? AppTheme.accent.opacity(0.6) : AppTheme.surfaceBorder, lineWidth: 1)
                )
        )
    }

    // MARK: 筛选

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Menu {
                    Button("主目录") { viewModel.setScope(.home) }
                    Button("整台 Mac") { viewModel.setScope(.computer) }
                    Divider()
                    Button("选择文件夹…", action: chooseFolders)
                } label: {
                    Label("范围：\(viewModel.query.scope.title)", systemImage: "scope")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Picker("", selection: $viewModel.query.size) {
                    ForEach(SearchSizeFilter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()

                Picker("", selection: $viewModel.query.date) {
                    ForEach(SearchDateFilter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()

                Spacer()

                Picker("", selection: $viewModel.query.sort) {
                    ForEach(SearchSort.allCases) { Text("按\($0.title)").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SearchKindFilter.allCases) { kind in
                        let isOn = viewModel.query.kinds.contains(kind)
                        Button {
                            if isOn { viewModel.query.kinds.remove(kind) } else { viewModel.query.kinds.insert(kind) }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: kind.icon).font(.system(size: 11))
                                Text(kind.title).font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(isOn ? AppTheme.onAccent : AppTheme.textSecondary)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Capsule().fill(isOn ? AppTheme.accent : AppTheme.ink(0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "在这里搜索")
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            viewModel.setScope(.folders(panel.urls))
        }
    }

    // MARK: 状态栏

    @ViewBuilder
    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.engine == .index {
                indexBanner
            }
            HStack(spacing: 10) {
                if viewModel.isBuildingIndex {
                    ProgressView().scaleEffect(0.5).tint(AppTheme.textSecondary)
                    Text("正在建立文件索引（仅首次，约 10–30 秒）… 已收录 \(viewModel.indexedEntries.formatted()) 项")
                        .monospacedDigit()
                    Spacer()
                } else if viewModel.query.isEmpty {
                    Text("输入文件名开始搜索，或选择类型、大小、时间筛选")
                    Spacer()
                } else {
                    if viewModel.isSearching {
                        ProgressView().scaleEffect(0.5).tint(AppTheme.textSecondary)
                    }
                    Text(countText).monospacedDigit()
                    Spacer()
                    if viewModel.engine == .spotlight && !viewModel.isSearching {
                        Button("找不到？用 MacClean 索引查找") { viewModel.useIndex() }
                            .buttonStyle(.plain)
                            .foregroundColor(AppTheme.accent)
                            .help("MacClean 自己遍历磁盘建立文件名索引：能找到隐藏文件和 Spotlight 未收录的位置（不支持内容匹配）")
                    } else if viewModel.engine == .index && !viewModel.spotlightDisabled {
                        Button("返回 Spotlight") { viewModel.useSpotlight() }
                            .buttonStyle(.plain)
                            .foregroundColor(AppTheme.accent)
                    }
                }
            }
        }
        .font(.system(size: 12))
        .foregroundColor(AppTheme.textSecondary)
    }

    private var indexBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .foregroundColor(AppTheme.textMuted)
            (viewModel.spotlightDisabled
                 ? Text("此位置的 Spotlight 索引不可用，正在使用 MacClean 自建的文件名索引（不支持内容匹配）")
                 : Text("正在使用 MacClean 自建的文件名索引（含隐藏文件）"))
                .foregroundColor(AppTheme.textSecondary)
            if let builtAt = viewModel.indexBuiltAt {
                Text("· 建立于 \(builtAt.formatted(.relative(presentation: .named)))")
                    .foregroundColor(AppTheme.textMuted)
            }
            Spacer()
            if case .home = viewModel.query.scope {
                Toggle("包含 ~/Library", isOn: $viewModel.includeLibrary)
                    .toggleStyle(.checkbox)
                    .help("资源库里有大量缓存与应用数据，收录后索引更大")
            }
            Button("刷新索引") { viewModel.rebuildIndex() }
                .buttonStyle(.plain)
                .foregroundColor(AppTheme.accent)
                .disabled(viewModel.isBuildingIndex)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: CosmicSizes.controlRadius).fill(AppTheme.ink(0.04)))
    }

    private var countText: String {
        let total = viewModel.totalCount
        let isIndex = viewModel.engine == .index
        if total > viewModel.limit {
            return isIndex
                ? String(localized: "索引查找：共 \(total.formatted()) 个结果，显示前 \(viewModel.limit) 个，可加筛选缩小范围")
                : String(localized: "共 \(total.formatted()) 个结果，显示前 \(viewModel.limit) 个，可加筛选缩小范围")
        }
        return isIndex
            ? String(localized: "索引查找：\(total.formatted()) 个结果")
            : String(localized: "\(total.formatted()) 个结果")
    }

    // MARK: 结果

    @ViewBuilder
    private var resultsList: some View {
        if viewModel.results.isEmpty {
            if viewModel.query.isEmpty {
                quickStart
            } else {
                VStack(spacing: 12) {
                    GradientIconTile(systemName: "questionmark.folder.fill", gradient: AppTab.fileSearch.tileGradient, size: 56, glyphRatio: 0.44, shadowColor: AppTab.fileSearch.tileShadow)
                    if !viewModel.isSearching {
                        Text("没有找到匹配的文件")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(AppTheme.textPrimary)
                        Text("换个关键词，或放宽大小、时间筛选试试")
                            .font(.system(size: 12.5))
                            .foregroundColor(AppTheme.textMuted)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.results) { result in
                        SearchResultRow(
                            result: result,
                            term: viewModel.query.trimmedTerm,
                            isSelected: viewModel.selected.contains(result.path),
                            onToggle: { viewModel.toggle(result) }
                        )
                        Divider().overlay(AppTheme.divider).padding(.leading, 76)
                    }
                }
                .themeCard()
                .padding(.horizontal, CosmicSizes.pagePadding)
                .padding(.bottom, 20)
            }
        }
    }
}

// MARK: - 快速开始

private struct SearchPreset: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
    let tint: Color
    let apply: (inout FileSearchQuery) -> Void
}

extension FileSearchView {
    private var presets: [SearchPreset] {
        [
            SearchPreset(icon: "externaldrive.fill", title: String(localized: "超过 1 GB 的文件"), detail: String(localized: "最快找回空间的地方"), tint: AppTheme.amber) { $0.size = .gb1; $0.sort = .size },
            SearchPreset(icon: "opticaldiscdrive.fill", title: String(localized: "安装包与磁盘映像"), detail: String(localized: "装完就没用的 .dmg / .pkg"), tint: AppTheme.sky) { $0.kinds = [.diskImage]; $0.sort = .size },
            SearchPreset(icon: "film.fill", title: String(localized: "100 MB 以上的视频"), detail: String(localized: "录屏、导出的大视频"), tint: AppTheme.pink) { $0.kinds = [.video]; $0.size = .mb100; $0.sort = .size },
            SearchPreset(icon: "doc.text.fill", title: String(localized: "最近 7 天的文档"), detail: String(localized: "刚刚编辑过的文件"), tint: AppTheme.violet) { $0.kinds = [.document]; $0.date = .week }
        ]
    }

    var quickStart: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("快速开始")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.textSecondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(presets) { preset in
                        PresetCard(preset: preset) { preset.apply(&viewModel.query) }
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundColor(AppTheme.amber)
                    Text(String(localized: "小技巧：用 * 通配，例如 \"*.mov\"、\"报告*2025\"；⌘F 可随时回到这里"))
                }
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textMuted)
                .padding(.top, 6)
            }
            .padding(.horizontal, CosmicSizes.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }
}

private struct PresetCard: View {
    let preset: SearchPreset
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                GradientIconTile(systemName: preset.icon, gradient: AppTheme.tileGradient(preset.tint, preset.tint.opacity(0.75)), size: 36, glyphRatio: 0.45, shadowColor: preset.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                    Text(preset.detail)
                        .font(.system(size: 11.5))
                        .foregroundColor(AppTheme.textMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppTheme.textMuted)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themeCard(isHovered: isHovered)
            .offset(y: isHovered ? -1 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - 结果行

struct SearchResultRow: View {
    let result: FileSearchResult
    let term: String
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    private var location: String {
        let parent = (result.path as NSString).deletingLastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .toggleStyle(CosmicCheckboxStyle(accentColor: AppTheme.accent))
                .labelsHidden()

            Image(nsImage: AppLookup.fileIcon(path: result.path))
                .resizable()
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                highlightedName
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(location)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(result.path)

            Spacer(minLength: 12)

            if isHovered {
                HStack(spacing: 10) {
                    iconButton("eye", help: String(localized: "快速查看")) { FileActions.quickLook(result.path) }
                    iconButton("magnifyingglass", help: String(localized: "在访达中显示")) { FileActions.reveal(result.path) }
                }
            }

            Text(result.modified.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "")
                .font(.system(size: 11))
                .foregroundColor(AppTheme.textMuted)
                .frame(width: 96, alignment: .trailing)

            Text(result.isDirectory ? String(localized: "文件夹") : ByteCountFormatter.string(fromByteCount: result.size, countStyle: .file))
                .font(.system(size: 12, design: .rounded))
                .monospacedDigit()
                .foregroundColor(AppTheme.textSecondary)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(isSelected ? AppTheme.accent.opacity(0.06) : (isHovered ? AppTheme.surfaceHover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { FileActions.open(result.path) }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("打开") { FileActions.open(result.path) }
            Button("快速查看") { FileActions.quickLook(result.path) }
            Button("在访达中显示") { FileActions.reveal(result.path) }
            Button("拷贝路径") { FileActions.copyPath(result.path) }
            Divider()
            Button(isSelected ? String(localized: "取消选择") : String(localized: "选择"), action: onToggle)
        }
    }

    /// 高亮文件名中与关键词匹配的部分（通配查询不高亮）。
    private var highlightedName: Text {
        let name = result.name
        guard !term.isEmpty, !term.contains("*"), !term.contains("?"),
              let range = name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(name).foregroundColor(AppTheme.textPrimary)
        }
        return Text(String(name[..<range.lowerBound])).foregroundColor(AppTheme.textPrimary)
            + Text(String(name[range])).foregroundColor(AppTheme.accent).bold()
            + Text(String(name[range.upperBound...])).foregroundColor(AppTheme.textPrimary)
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
