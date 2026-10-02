//
//  StorageTreemap.swift
//  MacClean
//
//  存储地图 → 目录地图的「树状图」：squarified 布局（Bruls 等）、两层嵌套、小项聚合、命中测试与配色。
//  纯计算，不碰界面，全部 nonisolated，可在后台线程计算、可单元测试。
//

import CoreGraphics
import Foundation

// MARK: - 显示方式

enum FolderMapStyle: String, CaseIterable {
    case bubbles
    case treemap

    static let storageKey = "storageMap.folderStyle"
}

// MARK: - 布局

nonisolated struct StorageTreemapTile: Identifiable, Sendable {
    /// 普通格子用节点 ID；聚合的「其他 N 项」用合成节点的 ID。
    var id: SpaceLensItem.ID { item.id }
    /// 聚合格子是一个 isVirtual 的合成节点（不进暂存篮、不能快速查看），与扫描树里的「其他」一致。
    let item: SpaceLensItem
    let rect: CGRect
    /// 0 = 当前文件夹的直接子项；1 = 子文件夹里嵌套的一层。
    let depth: Int
    /// 所属顶层格子的序号，决定色相。
    let group: Int
    /// 在同一父格子里的序号，决定深浅。
    let shade: Int
    /// 聚合进「其他」格子的项目数；普通格子为 0。
    let aggregatedCount: Int
    let isAggregate: Bool
    /// 顶层文件夹展开为嵌套时的标题条（名称 + 大小）。
    var headerRect: CGRect?
    /// 嵌套子格子在 tiles 中的下标范围。
    var childRange: Range<Int>?
    /// 嵌套格子的父格子下标。
    let parentIndex: Int?

    var isContainer: Bool { childRange != nil }
}

nonisolated struct StorageTreemapLayout: Sendable {
    static let minTileSide: CGFloat = 18
    static let minFraction = 0.005
    static let headerMinSize = CGSize(width: 120, height: 60)
    static let headerHeight: CGFloat = 20
    static let innerPadding: CGFloat = 3
    /// 每层最多画多少格；超出部分并入「其他」。
    static let maxTilesPerLevel = 300
    /// 子项超过这个数时放到后台线程计算布局。
    static let asyncChildThreshold = 2_000
    static let otherPathSuffix = "/.treemap-other"

    /// 每次计算都不同，绘制层据此判断是否需要重画。
    let id = UUID()
    let size: CGSize
    /// 顶层格子在前、各自的嵌套格子紧随其后（父格子总在子格子之前，绘制顺序即层级顺序）。
    let tiles: [StorageTreemapTile]
    let topLevel: [Int]
    /// 当前文件夹大小，用于计算占比。
    let totalSize: Int64

    static let empty = StorageTreemapLayout(size: .zero, tiles: [], topLevel: [], totalSize: 0)

    // MARK: 命中测试

    /// 点 → 最深一层的格子下标：先在顶层格子里找，再在它的嵌套格子里找。
    func tileIndex(at point: CGPoint) -> Int? {
        for top in topLevel where tiles[top].rect.contains(point) {
            if let range = tiles[top].childRange {
                for index in range where tiles[index].rect.contains(point) {
                    return index
                }
            }
            return top
        }
        return nil
    }

    func tile(at point: CGPoint) -> StorageTreemapTile? {
        tileIndex(at: point).map { tiles[$0] }
    }

    func index(of id: SpaceLensItem.ID) -> Int? {
        tiles.firstIndex { $0.id == id }
    }

    /// 嵌套格子对应的顶层格子（当前层的列表行）；顶层格子返回自己。
    func topLevelTile(for index: Int) -> StorageTreemapTile {
        let tile = tiles[index]
        return tile.parentIndex.map { tiles[$0] } ?? tile
    }

    // MARK: 构建

    static func make(for item: SpaceLensItem, size: CGSize) -> StorageTreemapLayout {
        let bounds = CGRect(origin: .zero, size: size)
        guard size.width >= 1, size.height >= 1 else {
            return StorageTreemapLayout(size: size, tiles: [], topLevel: [], totalSize: item.size)
        }
        var tiles: [StorageTreemapTile] = []
        var topLevel: [Int] = []

        for (group, placed) in level(of: item, in: bounds).enumerated() {
            let index = tiles.count
            topLevel.append(index)
            tiles.append(StorageTreemapTile(
                item: placed.item, rect: placed.rect, depth: 0, group: group, shade: 0,
                aggregatedCount: placed.aggregatedCount, isAggregate: placed.isAggregate,
                headerRect: nil, childRange: nil, parentIndex: nil
            ))

            let child = placed.item
            let rect = placed.rect
            guard !placed.isAggregate, child.isDirectory, !child.isVirtual, !child.children.isEmpty,
                  rect.width >= headerMinSize.width, rect.height >= headerMinSize.height else { continue }
            let header = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight)
            let inner = CGRect(
                x: rect.minX + innerPadding,
                y: rect.minY + headerHeight,
                width: rect.width - innerPadding * 2,
                height: rect.height - headerHeight - innerPadding
            )
            let nested = level(of: child, in: inner)
            guard !nested.isEmpty else { continue }
            let start = tiles.count
            for (shade, inner) in nested.enumerated() {
                tiles.append(StorageTreemapTile(
                    item: inner.item, rect: inner.rect, depth: 1, group: group, shade: shade,
                    aggregatedCount: inner.aggregatedCount, isAggregate: inner.isAggregate,
                    headerRect: nil, childRange: nil, parentIndex: index
                ))
            }
            tiles[index].headerRect = header
            tiles[index].childRange = start..<tiles.count
        }
        return StorageTreemapLayout(size: size, tiles: tiles, topLevel: topLevel, totalSize: item.size)
    }

    private struct Placed {
        let item: SpaceLensItem
        let rect: CGRect
        var aggregatedCount = 0
        var isAggregate = false
    }

    /// 一层的布局：按大小降序 squarify；占比太小或画出来不足 minTileSide 的尾部项并入「其他 N 项」。
    /// 父节点大小里没建模为子项的部分（直属零散文件）也算进「其他」，保证面积如实。
    private static func level(of parent: SpaceLensItem, in rect: CGRect) -> [Placed] {
        guard rect.width >= 1, rect.height >= 1 else { return [] }
        let children = parent.children
            .filter { $0.size > 0 }
            .sorted { $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size }
        let childSum = children.reduce(Int64(0)) { $0 + $1.size }
        let remainder = max(0, parent.size - childSum)
        let total = Double(childSum + remainder)
        guard total > 0 else { return [] }
        // 零散剩余太小就不单独成格，免得出现一条细缝
        let unmodeled = Double(remainder) / total >= minFraction ? remainder : 0

        var keep = min(children.prefix { Double($0.size) / total >= minFraction }.count, maxTilesPerLevel)
        var rects: [CGRect] = []
        var otherSize: Int64 = 0
        for _ in 0..<16 {
            // 只剩一项要聚合且没有零散剩余时，直接画它本身，不必叫「其他 1 项」
            if children.count - keep == 1 && unmodeled == 0 { keep = children.count }
            otherSize = children[keep...].reduce(Int64(0)) { $0 + $1.size } + unmodeled
            var sizes = children[..<keep].map { Double($0.size) }
            if otherSize > 0 { sizes.append(Double(otherSize)) }
            rects = squarify(sizes: sizes, in: rect)
            guard let tooSmall = (0..<keep).first(where: { min(rects[$0].width, rects[$0].height) < minTileSide }) else { break }
            // squarify 按大小降序摆放，第一个过小的之后都更小：从它开始并入「其他」
            let next = tooSmall
            if next >= keep || (children.count - next == 1 && unmodeled == 0) { break }
            keep = next
        }

        var placed = (0..<keep).map { Placed(item: children[$0], rect: rects[$0]) }
        if otherSize > 0, rects.count > keep {
            let count = children.count - keep
            placed.append(Placed(
                item: SpaceLensItem(
                    name: String(localized: "其他"),
                    path: parent.path + otherPathSuffix,
                    size: otherSize,
                    isDirectory: false,
                    children: [],
                    itemCount: count,
                    isReadable: false,
                    isVirtual: true,
                    lastModified: nil
                ),
                rect: rects[keep],
                aggregatedCount: count,
                isAggregate: true
            ))
        }
        return placed
    }

    // MARK: Squarify

    /// Squarified treemap（Bruls, Huizing, van Wijk 2000）。
    /// 返回与 sizes 一一对应的矩形，面积与 size 成正比、铺满 rect；0、负数或非有限值得到零面积矩形。
    static func squarify(sizes: [Double], in rect: CGRect) -> [CGRect] {
        var result = Array(repeating: CGRect(origin: rect.origin, size: .zero), count: sizes.count)
        let order = sizes.indices
            .filter { sizes[$0] > 0 && sizes[$0].isFinite }
            .sorted { sizes[$0] == sizes[$1] ? $0 < $1 : sizes[$0] > sizes[$1] }
        let total = order.reduce(0.0) { $0 + sizes[$1] }
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }

        let scale = Double(rect.width) * Double(rect.height) / total
        let areas = order.map { sizes[$0] * scale }
        var remaining = rect
        var start = 0

        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var end = start + 1
            var rowSum = areas[start]
            var currentWorst = worstRatio(sum: rowSum, largest: areas[start], smallest: areas[start], side: side)
            while end < areas.count {
                let candidateSum = rowSum + areas[end]
                let candidate = worstRatio(sum: candidateSum, largest: areas[start], smallest: areas[end], side: side)
                if candidate > currentWorst { break }
                rowSum = candidateSum
                currentWorst = candidate
                end += 1
            }

            // 一行沿较短边排开；最后一行直接吃掉剩余空间，避免浮点误差留缝
            let isLastRow = end == areas.count
            if remaining.width >= remaining.height {
                let thickness = isLastRow ? remaining.width : min(remaining.width, CGFloat(rowSum / Double(remaining.height)))
                var y = remaining.minY
                for k in start..<end {
                    let height = k == end - 1 ? remaining.maxY - y : CGFloat(areas[k] / rowSum) * remaining.height
                    result[order[k]] = CGRect(x: remaining.minX, y: y, width: thickness, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                                   width: max(0, remaining.width - thickness), height: remaining.height)
            } else {
                let thickness = isLastRow ? remaining.height : min(remaining.height, CGFloat(rowSum / Double(remaining.width)))
                var x = remaining.minX
                for k in start..<end {
                    let width = k == end - 1 ? remaining.maxX - x : CGFloat(areas[k] / rowSum) * remaining.width
                    result[order[k]] = CGRect(x: x, y: remaining.minY, width: width, height: thickness)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                                   width: remaining.width, height: max(0, remaining.height - thickness))
            }
            start = end
        }
        return result
    }

    /// 一行里最差的长宽比：max(w²·r⁺/s², s²/(w²·r⁻))。
    private static func worstRatio(sum: Double, largest: Double, smallest: Double, side: Double) -> Double {
        guard sum > 0, smallest > 0, side > 0 else { return .infinity }
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
    }
}

// MARK: - 配色

/// sRGB 0…1 颜色，方便算亮度与对比度。
nonisolated struct TreemapRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ hex: UInt) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// WCAG 相对亮度。
    var luminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    func contrast(with other: TreemapRGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    func mixed(with other: TreemapRGB, _ amount: Double) -> TreemapRGB {
        let t = min(max(amount, 0), 1)
        return TreemapRGB(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t
        )
    }
}

/// 树状图配色：每个顶层格子一个色相，嵌套格子取同色相的深浅；浅色模式用明亮色配深字，深色模式用沉稳色配白字。
nonisolated enum StorageTreemapPalette {
    static let white = TreemapRGB(0xFFFFFF)
    /// 与 AppTheme.textPrimary 浅色值一致的深色文字。
    static let ink = TreemapRGB(0x161A21)
    static let black = TreemapRGB(0x000000)
    static let minimumContrast = 4.5

    static let lightHues: [TreemapRGB] = [
        TreemapRGB(0x5CC59C), // 薄荷
        TreemapRGB(0x7FB2EC), // 天蓝
        TreemapRGB(0xEBBC5E), // 琥珀
        TreemapRGB(0xEE9580), // 珊瑚
        TreemapRGB(0xA997EE), // 紫
        TreemapRGB(0x5DC0CF), // 青
        TreemapRGB(0xEC97B9), // 粉
        TreemapRGB(0xB2CC6C), // 青柠
    ]
    static let darkHues: [TreemapRGB] = [
        TreemapRGB(0x1C7656), // 薄荷
        TreemapRGB(0x2D5F9E), // 天蓝
        TreemapRGB(0x86621A), // 琥珀
        TreemapRGB(0x9B4636), // 珊瑚
        TreemapRGB(0x5A4BAA), // 紫
        TreemapRGB(0x1B6B7C), // 青
        TreemapRGB(0x913A62), // 粉
        TreemapRGB(0x566A22), // 青柠
    ]
    static let lightNeutral = TreemapRGB(0xC3C9D3)
    static let darkNeutral = TreemapRGB(0x434B5A)
    /// 暂存篮中的格子先褪色到接近页面底色，再染一点品牌绿。
    static let lightWash = TreemapRGB(0xF4F6F8)
    static let darkWash = TreemapRGB(0x1B1F25)
    static let lightAccent = TreemapRGB(0x0EA372)
    static let darkAccent = TreemapRGB(0x3DDC97)

    static func fill(for tile: StorageTreemapTile, isDark: Bool, inBasket: Bool = false) -> TreemapRGB {
        fill(group: tile.isAggregate || tile.item.isVirtual ? nil : tile.group,
             depth: tile.depth, shade: tile.shade, isFile: !tile.item.isDirectory,
             isDark: isDark, inBasket: inBasket)
    }

    /// group 为 nil 时是中性灰（「其他」）。保证与所选文字颜色的对比度 ≥ 4.5。
    static func fill(group: Int?, depth: Int, shade: Int, isFile: Bool, isDark: Bool, inBasket: Bool) -> TreemapRGB {
        let hues = isDark ? darkHues : lightHues
        var color = group.map { hues[$0 % hues.count] } ?? (isDark ? darkNeutral : lightNeutral)
        if depth > 0 {
            // 嵌套格子：整体提亮一档，再按序号在两三档深浅之间交替，相邻格子能分开
            let steps: [Double] = [0.16, 0.26, 0.08, 0.21, 0.12]
            color = color.mixed(with: white, steps[shade % steps.count] * (isDark ? 0.55 : 1))
        }
        if isFile {
            // 文件更平：略微去饱和
            let gray = (color.red + color.green + color.blue) / 3
            color = color.mixed(with: TreemapRGB(red: gray, green: gray, blue: gray), 0.18)
        }
        if inBasket {
            color = color.mixed(with: isDark ? darkWash : lightWash, 0.62)
                .mixed(with: isDark ? darkAccent : lightAccent, 0.14)
        }
        return ensuringContrast(color)
    }

    /// 白字或深字里对比度更高的一个。
    static func label(on fill: TreemapRGB) -> TreemapRGB {
        fill.contrast(with: white) >= fill.contrast(with: ink) ? white : ink
    }

    /// 两种文字都不到 4.5 时（亮度落在中间带），把底色往更合适的一侧推。
    static func ensuringContrast(_ color: TreemapRGB) -> TreemapRGB {
        var color = color
        for _ in 0..<20 {
            let text = label(on: color)
            if color.contrast(with: text) >= minimumContrast { break }
            color = color.mixed(with: text == white ? black : white, 0.06)
        }
        return color
    }
}
