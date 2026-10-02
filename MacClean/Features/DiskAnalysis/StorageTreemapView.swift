//
//  StorageTreemapView.swift
//  MacClean
//
//  目录地图的「树状图」视图：Canvas 一次画完所有格子，悬停 / 点按 / 拖动靠自己的命中测试。
//  与列表共用 SpaceLensViewModel 的选择、焦点与暂存篮。
//

import AppKit
import SwiftUI

// MARK: - 气泡图 / 树状图切换

struct FolderMapStylePicker: View {
    @Binding var style: FolderMapStyle

    var body: some View {
        HStack(spacing: 2) {
            segment(.bubbles, title: String(localized: "气泡图"), icon: "circle.grid.2x2")
            segment(.treemap, title: String(localized: "树状图"), icon: "square.grid.3x3.square")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: CosmicSizes.controlRadius).fill(AppTheme.ink(0.07)))
        .fixedSize()
    }

    private func segment(_ value: FolderMapStyle, title: String, icon: String) -> some View {
        let isSelected = style == value
        return Button {
            style = value
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(isSelected ? AppTheme.textPrimary : AppTheme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? AppTheme.surfaceHover : Color.clear)
                    .shadow(color: isSelected ? AppTheme.cardShadow : .clear, radius: 2, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - 布局缓存

/// 按「文件夹 + 尺寸」缓存布局；悬停只改高亮，不重算。子项很多时放到后台算。
/// 同时记下上一份布局，用来算钻取 / 返回时缩放动画的起点。
@MainActor
private final class TreemapLayoutCache {
    struct Key: Equatable {
        let id: SpaceLensItem.ID
        let size: Int64
        let childCount: Int
        let width: Int
        let height: Int
    }

    private var key: Key?
    private var layout: StorageTreemapLayout?
    private var path: [SpaceLensItem.ID] = []
    private var pendingKey: Key?
    /// 新内容在动画起点时整体铺在哪个框里；nil 表示不做缩放。
    private(set) var zoomStart: CGRect?

    func layout(
        for item: SpaceLensItem,
        path: [SpaceLensItem.ID],
        size: CGSize,
        onAsyncReady: @escaping () -> Void
    ) -> StorageTreemapLayout? {
        let key = Key(id: item.id, size: item.size, childCount: item.children.count,
                      width: Int(size.width.rounded()), height: Int(size.height.rounded()))
        if key == self.key { return layout }

        if item.children.count > StorageTreemapLayout.asyncChildThreshold {
            if pendingKey != key {
                pendingKey = key
                Task.detached(priority: .userInitiated) {
                    let computed = StorageTreemapLayout.make(for: item, size: size)
                    await MainActor.run {
                        guard self.pendingKey == key else { return }
                        self.pendingKey = nil
                        self.store(computed, key: key, path: path)
                        onAsyncReady()
                    }
                }
            }
            // 同一文件夹只是改了尺寸时先沿用旧布局，换了文件夹就显示加载中
            return self.key?.id == item.id ? layout : nil
        }

        pendingKey = nil
        let computed = StorageTreemapLayout.make(for: item, size: size)
        store(computed, key: key, path: path)
        return computed
    }

    private func store(_ new: StorageTreemapLayout, key: Key, path newPath: [SpaceLensItem.ID]) {
        if key.id != self.key?.id {
            zoomStart = Self.zoomStart(from: layout, oldPath: path, to: new, newPath: newPath)
        }
        self.key = key
        layout = new
        path = newPath
    }

    /// 进入：新内容从被点开的格子处放大；返回：新内容从「刚才那个文件夹铺满全图」缩回原位。
    private static func zoomStart(
        from old: StorageTreemapLayout?,
        oldPath: [SpaceLensItem.ID],
        to new: StorageTreemapLayout,
        newPath: [SpaceLensItem.ID]
    ) -> CGRect? {
        guard let old else { return nil }
        if newPath.count > oldPath.count, Array(newPath.prefix(oldPath.count)) == oldPath {
            let candidates = [newPath.last, newPath[oldPath.count]].compactMap { $0 }
            guard let rect = candidates.lazy.compactMap({ old.index(of: $0) }).first.map({ old.tiles[$0].rect }),
                  rect.width > 1, rect.height > 1 else { return nil }
            return rect
        }
        if oldPath.count > newPath.count, Array(oldPath.prefix(newPath.count)) == newPath {
            let candidates = [oldPath.last, oldPath[newPath.count]].compactMap { $0 }
            guard let rect = candidates.lazy.compactMap({ new.index(of: $0) }).first.map({ new.tiles[$0].rect }),
                  rect.width > 1, rect.height > 1 else { return nil }
            let size = new.size
            let scaleX = size.width / rect.width
            let scaleY = size.height / rect.height
            return CGRect(x: -rect.minX * scaleX, y: -rect.minY * scaleY,
                          width: size.width * scaleX, height: size.height * scaleY)
        }
        return nil
    }
}

/// 把整块内容从 start 框插值到自身边界。
private struct TreemapZoomEffect: GeometryEffect {
    let start: CGRect?
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        guard let start, size.width > 0, size.height > 0 else { return ProjectionTransform(.identity) }
        let t = CGFloat(progress)
        let width = start.width + (size.width - start.width) * t
        let height = start.height + (size.height - start.height) * t
        let transform = CGAffineTransform(translationX: start.minX * (1 - t), y: start.minY * (1 - t))
            .scaledBy(x: width / size.width, y: height / size.height)
        return ProjectionTransform(transform)
    }
}

// MARK: - 树状图

struct StorageTreemapView: View {
    @ObservedObject var viewModel: SpaceLensViewModel

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cache = TreemapLayoutCache()
    @State private var asyncGeneration = 0
    @State private var hoverPoint: CGPoint?
    @State private var tooltipSize: CGSize = .zero

    /// 截图测试用：出现时模拟鼠标停在这个点上。
    static var snapshotHoverPoint: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let _ = asyncGeneration
            if let item = viewModel.currentItem {
                let layout = cache.layout(for: item, path: viewModel.currentPath, size: proxy.size) {
                    asyncGeneration += 1
                }
                let zoomStart = reduceMotion ? nil : cache.zoomStart
                ZStack(alignment: .topLeading) {
                    if let layout {
                        treemap(layout)
                            .id(item.id)
                            .transition(.asymmetric(
                                insertion: .modifier(
                                    active: TreemapZoomEffect(start: zoomStart, progress: 0),
                                    identity: TreemapZoomEffect(start: zoomStart, progress: 1)
                                ).combined(with: .opacity),
                                removal: .opacity
                            ))
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .animation(zoomStart == nil ? nil : .easeOut(duration: 0.25), value: item.id)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: CosmicSizes.cardRadius, style: .continuous)
                .fill(AppTheme.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: CosmicSizes.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CosmicSizes.cardRadius, style: .continuous)
                .strokeBorder(AppTheme.surfaceBorder, lineWidth: 1)
        )
        .onAppear {
            if let point = Self.snapshotHoverPoint { hoverPoint = point }
        }
    }

    private func treemap(_ layout: StorageTreemapLayout) -> some View {
        let hoveredIndex = hoverPoint.flatMap { layout.tileIndex(at: $0) }
        let highlightIndex = hoveredIndex ?? viewModel.focusedID.flatMap { layout.index(of: $0) }
        let hovered = hoveredIndex.map { layout.tiles[$0] }

        return ZStack(alignment: .topLeading) {
            TreemapTilesCanvas(
                layout: layout,
                selectedIDs: viewModel.selectedIDs,
                basket: viewModel.basket,
                isDark: colorScheme == .dark
            )
            .equatable()

            if let highlightIndex {
                let rect = layout.tiles[highlightIndex].rect.insetBy(dx: 1, dy: 1)
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(AppTheme.textPrimary, lineWidth: 2)
                    .frame(width: max(rect.width, 0), height: max(rect.height, 0))
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }

            if let hovered, let hoverPoint {
                tooltip(for: hovered, layout: layout, at: hoverPoint)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                hoverPoint = point
                let id = layout.tileIndex(at: point).map { layout.tiles[$0].id }
                if let id, viewModel.focusedID != id {
                    viewModel.focusedID = id
                    if let item = layout.index(of: id).map({ layout.tiles[$0].item }), !item.isVirtual {
                        StorageQuickLook.shared.followIfVisible(item.path)
                    }
                }
            case .ended:
                hoverPoint = nil
            }
        }
        .onTapGesture(count: 1, coordinateSpace: .local) { point in
            guard let index = layout.tileIndex(at: point) else { return }
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                open(index, in: layout)
            } else {
                select(index, in: layout)
            }
        }
        .draggable(hovered.flatMap { $0.item.isVirtual ? nil : StorageBasketDropPayload.encode($0.id) } ?? "") {
            if let hovered {
                BasketDragPreview(name: hovered.item.name, size: hovered.item.size, isDirectory: hovered.item.isDirectory)
            }
        }
        .contextMenu {
            if let hovered, !hovered.item.isVirtual {
                contextMenu(for: hovered, in: layout)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "树状图"))
        .accessibilityChildren {
            accessibilityTiles(layout)
        }
    }

    // MARK: 交互

    /// 单击：选中当前层对应的列表行（嵌套格子选中它所在的顶层文件夹）。
    private func select(_ index: Int, in layout: StorageTreemapLayout) {
        let top = layout.topLevelTile(for: index)
        guard !top.item.isVirtual, !BasketMembership(item: top.item, basket: viewModel.basket).isInBasket else { return }
        viewModel.toggleSelection(top.item)
    }

    /// 双击：进入文件夹（嵌套文件夹直接进两层）；文件进入它所在的文件夹，顶层文件则快速查看。
    private func open(_ index: Int, in layout: StorageTreemapLayout) {
        let tile = layout.tiles[index]
        let item = tile.item
        if item.isDirectory, item.isReadable, !item.isVirtual {
            viewModel.enter(item)
        } else if tile.parentIndex != nil {
            viewModel.enter(layout.topLevelTile(for: index).item)
        } else if !item.isVirtual {
            viewModel.quickLook(item)
        }
    }

    @ViewBuilder
    private func contextMenu(for tile: StorageTreemapTile, in layout: StorageTreemapLayout) -> some View {
        let item = tile.item
        let state = BasketMembership(item: item, basket: viewModel.basket)
        if state == .entry {
            Button {
                viewModel.removeFromBasket(item.id)
            } label: {
                Label("移出暂存篮", systemImage: "tray.and.arrow.up")
            }
        } else if !state.isInBasket {
            Button {
                viewModel.addToBasket(item)
            } label: {
                Label("加入暂存篮", systemImage: "tray.and.arrow.down")
            }
        }
        Button {
            viewModel.quickLook(item)
        } label: {
            Label("快速查看", systemImage: "eye")
        }
        Button {
            SpaceLensFinderOpener.open(item)
        } label: {
            Label("在 Finder 中打开", systemImage: "folder")
        }
        if item.isDirectory && item.isReadable {
            Divider()
            Button("进入目录") { viewModel.enter(item) }
        }
    }

    // MARK: 悬停提示

    private func tooltip(for tile: StorageTreemapTile, layout: StorageTreemapLayout, at point: CGPoint) -> some View {
        let item = tile.item
        let state = BasketMembership(item: item, basket: viewModel.basket)
        let width: CGFloat = 270
        let x = point.x + 16 + width <= layout.size.width ? point.x + 16 : max(4, point.x - 16 - width)
        let y = point.y + 18 + tooltipSize.height <= layout.size.height ? point.y + 18 : max(4, point.y - 12 - tooltipSize.height)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: tile.isAggregate ? "square.stack.3d.down.right" : (item.isDirectory ? "folder.fill" : "doc.fill"))
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textSecondary)
                Text(Self.displayName(tile))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("\(Self.sizeText(item.size)) · 占当前文件夹 \(Self.percentText(item.size, of: layout.totalSize))")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundColor(AppTheme.textSecondary)
            if tile.isAggregate {
                Text("较小的项目合并显示，可在左侧列表中逐项查看")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !item.isVirtual {
                Text(SpaceLensItem.cleanPath(item.path))
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            switch state {
            case .entry:
                Label("已在暂存篮中", systemImage: "basket.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.accent)
            case .coveredBy(let name):
                Text("已在暂存篮的「\(name)」中")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.accent)
            case .hasDescendants(let count):
                Text("\(count) 个子项在暂存篮中")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.accent)
            case .none:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CosmicSizes.controlRadius)
                .fill(AppTheme.surfaceHover)
                .overlay(RoundedRectangle(cornerRadius: CosmicSizes.controlRadius).strokeBorder(AppTheme.surfaceBorder, lineWidth: 1))
                .shadow(color: AppTheme.cardShadow, radius: 10, y: 4)
        )
        .background(GeometryReader { proxy in
            Color.clear.preference(key: TreemapTooltipSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(TreemapTooltipSizeKey.self) { tooltipSize = $0 }
        .offset(x: x, y: y)
        .allowsHitTesting(false)
    }

    // MARK: 辅助功能

    private func accessibilityTiles(_ layout: StorageTreemapLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(layout.tiles.indices), id: \.self) { index in
                let tile = layout.tiles[index]
                let item = tile.item
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: tile.rect.width, height: tile.rect.height)
                    .offset(x: tile.rect.minX, y: tile.rect.minY)
                    .accessibilityElement()
                    .accessibilityLabel(String(localized: "\(Self.displayName(tile))，\(Self.sizeText(item.size))，\(Self.percentText(item.size, of: layout.totalSize))"))
                    .accessibilityAddTraits(viewModel.selectedIDs.contains(item.id) ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { select(index, in: layout) }
                    .accessibilityAction(named: Text("进入目录")) { open(index, in: layout) }
                    .accessibilityAction(named: Text("加入暂存篮")) {
                        if !item.isVirtual { viewModel.addToBasket(item) }
                    }
                    .accessibilityAction(named: Text("快速查看")) { viewModel.quickLook(item) }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    // MARK: 文本

    static func displayName(_ tile: StorageTreemapTile) -> String {
        guard tile.isAggregate else { return tile.item.name }
        return tile.aggregatedCount > 0 ? String(localized: "其他 \(tile.aggregatedCount) 项") : String(localized: "其他")
    }

    static func sizeText(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static func percentText(_ size: Int64, of total: Int64) -> String {
        let fraction = Double(size) / Double(max(total, 1))
        return fraction.formatted(.percent.precision(.fractionLength(fraction < 0.1 ? 1 : 0)))
    }
}

private struct TreemapTooltipSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

// MARK: - 绘制

/// 所有格子一次画完。只在布局、选择、暂存篮或外观变化时重画，悬停不会触发。
private struct TreemapTilesCanvas: View, Equatable {
    let layout: StorageTreemapLayout
    let selectedIDs: Set<SpaceLensItem.ID>
    let basket: StorageBasket
    let isDark: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.layout.id == rhs.layout.id && lhs.selectedIDs == rhs.selectedIDs
            && lhs.basket == rhs.basket && lhs.isDark == rhs.isDark
    }

    var body: some View {
        let states = layout.basketStates(in: basket)
        Canvas { context, _ in
            for (index, tile) in layout.tiles.enumerated() {
                drawTile(tile, state: states[index], in: &context)
            }
            for (index, tile) in layout.tiles.enumerated() {
                drawDecorations(tile, state: states[index], in: &context)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawTile(_ tile: StorageTreemapTile, state: BasketMembership, in context: inout GraphicsContext) {
        let inset: CGFloat = tile.depth == 0 ? 1 : 0.75
        let rect = tile.rect.insetBy(dx: inset, dy: inset)
        guard rect.width > 0.5, rect.height > 0.5 else { return }
        let radius: CGFloat = tile.depth == 0 ? 4 : 2.5
        let shape = Path(roundedRect: rect, cornerRadius: min(radius, rect.width / 2, rect.height / 2))
        let fill = StorageTreemapPalette.fill(for: tile, isDark: isDark, inBasket: state.isInBasket)
        context.fill(shape, with: .color(Color(rgb: fill)))

        // 文件夹带一圈细内描边，文件保持平涂
        if tile.item.isDirectory, !tile.item.isVirtual, !tile.isContainer, rect.width > 6, rect.height > 6 {
            let border = Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: max(radius - 1, 1))
            context.stroke(border, with: .color(AppTheme.ink(isDark ? 0.16 : 0.13)), lineWidth: 1)
        }

        let text = Color(rgb: StorageTreemapPalette.label(on: fill))
        if let header = tile.headerRect {
            drawHeader(tile, in: header.insetBy(dx: inset, dy: 0), color: text, state: state, context: &context)
        } else {
            drawLabel(tile, in: rect, color: text, context: &context)
        }
    }

    private func drawHeader(_ tile: StorageTreemapTile, in header: CGRect, color: Color, state: BasketMembership, context: inout GraphicsContext) {
        var trailing = header.maxX - 7
        if case .hasDescendants(let count) = state {
            trailing = drawCountBadge(count, trailingAt: trailing, midY: header.midY, context: &context) - 5
        }
        let sizeText = context.resolve(Text(StorageTreemapView.sizeText(tile.item.size))
            .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit().foregroundColor(color))
        let sizeWidth = sizeText.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width
        let nameStart = header.minX + 7
        var nameMax = trailing - nameStart
        if nameMax - sizeWidth - 8 > 30 {
            context.draw(sizeText, at: CGPoint(x: trailing, y: header.midY), anchor: .trailing)
            nameMax -= sizeWidth + 8
        }
        if let name = Self.fitted(tile.item.name, font: .system(size: 11.5, weight: .semibold), color: color, maxWidth: nameMax, context: context) {
            context.draw(name, at: CGPoint(x: nameStart, y: header.midY), anchor: .leading)
        }
    }

    private func drawLabel(_ tile: StorageTreemapTile, in rect: CGRect, color: Color, context: inout GraphicsContext) {
        guard rect.width >= 42, rect.height >= 22 else { return }
        let large = tile.depth == 0 && rect.width >= 180 && rect.height >= 110
        let nameFont: Font = .system(size: large ? 14 : (tile.depth == 0 ? 12 : 11), weight: .semibold)
        let sizeFont: Font = .system(size: large ? 12 : (tile.depth == 0 ? 11 : 10), weight: .medium, design: .rounded)
        let maxWidth = rect.width - 10
        guard let name = Self.fitted(StorageTreemapView.displayName(tile), font: nameFont, color: color, maxWidth: maxWidth, context: context) else { return }
        let showsSize = rect.height >= (large ? 48 : 36)
        if showsSize {
            let size = context.resolve(Text(StorageTreemapView.sizeText(tile.item.size)).font(sizeFont).monospacedDigit().foregroundColor(color))
            let gap: CGFloat = large ? 9 : 7.5
            context.draw(name, at: CGPoint(x: rect.midX, y: rect.midY - gap), anchor: .center)
            if size.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width <= maxWidth {
                context.draw(size, at: CGPoint(x: rect.midX, y: rect.midY + gap), anchor: .center)
            }
        } else {
            context.draw(name, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
        }
    }

    /// 选中与暂存篮标记画在所有格子之上，免得被嵌套格子盖住。
    private func drawDecorations(_ tile: StorageTreemapTile, state: BasketMembership, in context: inout GraphicsContext) {
        let rect = tile.rect.insetBy(dx: 1.5, dy: 1.5)
        guard rect.width > 4, rect.height > 4 else { return }
        let shape = Path(roundedRect: rect, cornerRadius: tile.depth == 0 ? 4 : 2.5)

        if state == .entry {
            context.stroke(shape, with: .color(AppTheme.accent), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            if rect.width >= 34, rect.height >= 26, tile.headerRect == nil {
                var icon = context.resolve(Image(systemName: "basket.fill"))
                icon.shading = .color(AppTheme.accent)
                context.draw(icon, at: CGPoint(x: rect.maxX - 12, y: rect.minY + 12), anchor: .center)
            }
        }
        if case .hasDescendants(let count) = state, tile.headerRect == nil, rect.width >= 40, rect.height >= 30 {
            _ = drawCountBadge(count, trailingAt: rect.maxX - 4, midY: rect.minY + 13, context: &context)
        }
        if tile.depth == 0, selectedIDs.contains(tile.id) {
            context.stroke(shape, with: .color(AppTheme.accent), lineWidth: 3)
            let center = CGPoint(x: rect.minX + 11, y: rect.maxY - 11)
            if rect.width >= 30, rect.height >= 30 {
                context.fill(Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)), with: .color(AppTheme.accent))
                let check = context.resolve(Text(Image(systemName: "checkmark")).font(.system(size: 8, weight: .heavy)).foregroundColor(AppTheme.onAccent))
                context.draw(check, at: center, anchor: .center)
            }
        }
    }

    /// 画「n 个子项在暂存篮」角标，返回角标左边缘的 x。
    private func drawCountBadge(_ count: Int, trailingAt trailing: CGFloat, midY: CGFloat, context: inout GraphicsContext) -> CGFloat {
        let label = context.resolve(Text("\(count)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(AppTheme.onAccent))
        let width = max(16, label.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width + 9)
        let badge = CGRect(x: trailing - width, y: midY - 8, width: width, height: 16)
        context.fill(Path(roundedRect: badge, cornerRadius: 8), with: .color(AppTheme.accent))
        context.draw(label, at: CGPoint(x: badge.midX, y: badge.midY), anchor: .center)
        return badge.minX
    }

    /// 放得下就原样，否则截尾加省略号；连三个字都放不下就不画。
    static func fitted(_ string: String, font: Font, color: Color, maxWidth: CGFloat, context: GraphicsContext) -> GraphicsContext.ResolvedText? {
        guard maxWidth > 12 else { return nil }
        let unbounded = CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
        func resolve(_ text: String) -> GraphicsContext.ResolvedText {
            context.resolve(Text(verbatim: text).font(font).foregroundColor(color))
        }
        let full = resolve(string)
        if full.measure(in: unbounded).width <= maxWidth { return full }
        let characters = Array(string)
        var low = 3
        var high = characters.count - 1
        var best: GraphicsContext.ResolvedText?
        while low <= high {
            let mid = (low + high) / 2
            let candidate = resolve(String(characters.prefix(mid)) + "…")
            if candidate.measure(in: unbounded).width <= maxWidth {
                best = candidate
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }
}

extension StorageTreemapLayout {
    /// 每个格子与暂存篮的关系（与 tiles 一一对应）：本身在篮中画虚线、被上层包含染色、其下有条目显示数字角标。
    func basketStates(in basket: StorageBasket) -> [BasketMembership] {
        tiles.map { BasketMembership(item: $0.item, basket: basket) }
    }
}

private extension Color {
    init(rgb: TreemapRGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}
