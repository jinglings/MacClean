//
//  StorageTreemapTests.swift
//  MacCleanTests
//
//  目录地图「树状图」：squarify 面积 / 长宽比 / 不重叠、小项聚合、两层嵌套与标题条、命中测试、
//  暂存篮标记、配色对比度。截图只用合成目录树，绝不扫描真实磁盘。
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MacClean

@MainActor
struct StorageTreemapTests {
    private static let gb: Int64 = 1_000_000_000
    private static let home = URL(fileURLWithPath: "/Users/demo")

    private static func node(_ path: String, size: Int64, isDirectory: Bool = true, children: [SpaceLensItem] = [], isVirtual: Bool = false) -> SpaceLensItem {
        SpaceLensItem(
            name: isVirtual ? String(localized: "其他") : URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            size: size,
            isDirectory: isDirectory,
            children: children,
            itemCount: children.reduce(0) { $0 + 1 + $1.itemCount },
            isReadable: !isVirtual,
            isVirtual: isVirtual,
            lastModified: nil
        )
    }

    private static func area(_ rect: CGRect) -> Double { Double(rect.width * rect.height) }

    private static func overlapArea(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : area(intersection)
    }

    // MARK: - squarify

    @Test(arguments: [
        [6.0, 6, 4, 3, 2, 2, 1],
        [500.0, 120, 80, 40, 33, 12, 9, 7, 3, 1, 1, 0.5],
        (1...60).map { Double($0 * $0) },
        [1.0],
    ])
    func squarifyPreservesAreaAndStaysInBounds(sizes: [Double]) {
        let container = CGRect(x: 10, y: 20, width: 600, height: 400)
        let rects = StorageTreemapLayout.squarify(sizes: sizes, in: container)
        #expect(rects.count == sizes.count)

        let total = sizes.reduce(0, +)
        let covered = rects.reduce(0) { $0 + Self.area($1) }
        #expect(abs(covered - Self.area(container)) < 0.5)

        for (index, rect) in rects.enumerated() {
            // 面积与 size 成正比
            let expected = sizes[index] / total * Self.area(container)
            #expect(abs(Self.area(rect) - expected) < max(0.5, expected * 0.001))
            #expect(rect.minX >= container.minX - 0.001 && rect.minY >= container.minY - 0.001)
            #expect(rect.maxX <= container.maxX + 0.001 && rect.maxY <= container.maxY + 0.001)
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                #expect(Self.overlapArea(rects[i], rects[j]) < 0.01)
            }
        }
    }

    @Test func squarifyKeepsAspectRatiosReasonable() {
        let sizes = (1...80).map { _ in Double.random(in: 1...1000) }
        let rects = StorageTreemapLayout.squarify(sizes: sizes, in: CGRect(x: 0, y: 0, width: 800, height: 500))
        let ratios = rects.map { max($0.width / $0.height, $0.height / $0.width) }.sorted()
        #expect(ratios[ratios.count / 2] < 3)
    }

    @Test func squarifyHandlesZeroAndEmpty() {
        #expect(StorageTreemapLayout.squarify(sizes: [], in: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)

        let rects = StorageTreemapLayout.squarify(sizes: [0, 5, -1, .nan, 5], in: CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(rects.count == 5)
        #expect(Self.area(rects[0]) == 0 && Self.area(rects[2]) == 0 && Self.area(rects[3]) == 0)
        #expect(abs(Self.area(rects[1]) - 2500) < 0.01)
        #expect(abs(Self.area(rects[4]) - 2500) < 0.01)

        let allZero = StorageTreemapLayout.squarify(sizes: [0, 0], in: CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(allZero.allSatisfy { Self.area($0) == 0 })
        let noSpace = StorageTreemapLayout.squarify(sizes: [1, 2], in: .zero)
        #expect(noSpace.allSatisfy { Self.area($0) == 0 })
    }

    // MARK: - 聚合

    @Test func tinyItemsAreAggregatedIntoOther() {
        let big = (0..<6).map { Self.node("/Users/demo/big\($0)", size: Int64(10 - $0) * Self.gb) }
        let tiny = (0..<40).map { Self.node("/Users/demo/tiny\($0)", size: 20_000_000, isDirectory: false) }
        let folder = Self.node("/Users/demo", size: 45 * Self.gb + 40 * 20_000_000, children: big + tiny)
        let layout = StorageTreemapLayout.make(for: folder, size: CGSize(width: 600, height: 400))

        let top = layout.topLevel.map { layout.tiles[$0] }
        let other = top.filter(\.isAggregate)
        #expect(other.count == 1)
        #expect(other.first?.aggregatedCount == 40)
        #expect(other.first?.item.isVirtual == true)
        let expectedSize: Int64 = 40 * 20_000_000
        #expect(other.first?.item.size == expectedSize)
        #expect(StorageTreemapView.displayName(other[0]) == String(localized: "其他 \(40) 项"))
        // 留下的格子都不小于 18pt
        for tile in top where !tile.isAggregate {
            #expect(min(tile.rect.width, tile.rect.height) >= StorageTreemapLayout.minTileSide)
        }
        // 总面积仍铺满
        let covered = top.reduce(0) { $0 + Self.area($1.rect) }
        #expect(abs(covered - 600 * 400) < 1)
    }

    @Test func smallContainerAggregatesTilesUnder18Points() {
        // 每项占比都超过 0.5%，但 60×60 的容器里画不下 30 个 ≥18pt 的格子
        let children = (0..<30).map { Self.node("/Users/demo/x/\($0)", size: Self.gb) }
        let folder = Self.node("/Users/demo/x", size: 30 * Self.gb, children: children)
        let layout = StorageTreemapLayout.make(for: folder, size: CGSize(width: 60, height: 60))
        for tile in layout.tiles where !tile.isAggregate {
            #expect(min(tile.rect.width, tile.rect.height) >= StorageTreemapLayout.minTileSide)
        }
        #expect(layout.tiles.contains { $0.isAggregate })
    }

    @Test func unmodeledSpaceFoldsIntoOther() {
        // 父目录 10 GB，子项只建模了 6 GB：剩下 4 GB 也要占面积
        let folder = Self.node("/Users/demo", size: 10 * Self.gb, children: [
            Self.node("/Users/demo/a", size: 6 * Self.gb),
        ])
        let layout = StorageTreemapLayout.make(for: folder, size: CGSize(width: 500, height: 200))
        let other = layout.tiles.first(where: \.isAggregate)
        #expect(other?.item.size == 4 * Self.gb)
        #expect(other.map { StorageTreemapView.displayName($0) } == String(localized: "其他"))
        let a = layout.tiles.first { $0.item.name == "a" }!
        #expect(abs(Self.area(a.rect) - 0.6 * 500 * 200) < 1)
    }

    // MARK: - 嵌套与标题条

    @Test func nestedLayoutWithHeaderStrips() {
        let library = Self.node("/Users/demo/Library", size: 60 * Self.gb, children: [
            Self.node("/Users/demo/Library/Caches", size: 30 * Self.gb),
            Self.node("/Users/demo/Library/Developer", size: 20 * Self.gb),
            Self.node("/Users/demo/Library/Mail", size: 10 * Self.gb),
        ])
        let tinyFolder = Self.node("/Users/demo/tiny", size: Self.gb / 2, children: [
            Self.node("/Users/demo/tiny/a", size: Self.gb / 2),
        ])
        let file = Self.node("/Users/demo/disk.img", size: 30 * Self.gb, isDirectory: false)
        let folder = Self.node("/Users/demo", size: 90 * Self.gb + Self.gb / 2, children: [library, file, tinyFolder])
        let layout = StorageTreemapLayout.make(for: folder, size: CGSize(width: 700, height: 420))

        let libraryIndex = layout.index(of: library.id)!
        let libraryTile = layout.tiles[libraryIndex]
        let header = try! #require(libraryTile.headerRect)
        #expect(header.height == StorageTreemapLayout.headerHeight)
        #expect(header.minY == libraryTile.rect.minY && header.width == libraryTile.rect.width)

        let range = try! #require(libraryTile.childRange)
        let nested = layout.tiles[range]
        #expect(nested.count == 3)
        for tile in nested {
            #expect(tile.depth == 1)
            #expect(tile.parentIndex == libraryIndex)
            #expect(tile.group == libraryTile.group)
            #expect(libraryTile.rect.contains(tile.rect))
            #expect(tile.rect.minY >= header.maxY - 0.001)
        }
        // 嵌套格子面积按比例分标题条下方的区域
        let innerArea = nested.reduce(0) { $0 + Self.area($1.rect) }
        let caches = nested.first { $0.item.name == "Caches" }!
        #expect(abs(Self.area(caches.rect) / innerArea - 0.5) < 0.001)

        // 文件和小文件夹不展开
        #expect(layout.tiles[layout.index(of: file.id)!].childRange == nil)
        if let tinyIndex = layout.index(of: tinyFolder.id) {
            #expect(layout.tiles[tinyIndex].headerRect == nil)
        }
        // 父格子总在子格子之前
        for (index, tile) in layout.tiles.enumerated() {
            if let parent = tile.parentIndex { #expect(parent < index) }
        }
    }

    // MARK: - 命中测试

    @Test func hitTestingFindsDeepestTile() {
        let caches = Self.node("/Users/demo/Library/Caches", size: 30 * Self.gb)
        let library = Self.node("/Users/demo/Library", size: 40 * Self.gb, children: [
            caches,
            Self.node("/Users/demo/Library/Mail", size: 10 * Self.gb),
        ])
        let movies = Self.node("/Users/demo/movie.mov", size: 40 * Self.gb, isDirectory: false)
        let folder = Self.node("/Users/demo", size: 80 * Self.gb, children: [library, movies])
        let layout = StorageTreemapLayout.make(for: folder, size: CGSize(width: 800, height: 400))

        let cachesRect = layout.tiles[layout.index(of: caches.id)!].rect
        #expect(layout.tile(at: CGPoint(x: cachesRect.midX, y: cachesRect.midY))?.id == caches.id)
        let libraryTile = layout.tiles[layout.index(of: library.id)!]
        let headerPoint = CGPoint(x: libraryTile.headerRect!.midX, y: libraryTile.headerRect!.midY)
        #expect(layout.tile(at: headerPoint)?.id == library.id)
        let movieRect = layout.tiles[layout.index(of: movies.id)!].rect
        #expect(layout.tile(at: CGPoint(x: movieRect.midX, y: movieRect.midY))?.id == movies.id)
        #expect(layout.tile(at: CGPoint(x: -5, y: 10)) == nil)
        #expect(layout.tile(at: CGPoint(x: 900, y: 10)) == nil)

        // 嵌套格子的顶层格子就是列表里的那一行
        #expect(layout.topLevelTile(for: layout.index(of: caches.id)!).id == library.id)
    }

    // MARK: - 暂存篮

    @Test func basketBadgesPropagateToTiles() {
        let modules = Self.node("/Users/demo/Projects/app/node_modules", size: 3 * Self.gb)
        let app = Self.node("/Users/demo/Projects/app", size: 5 * Self.gb, children: [modules])
        let site = Self.node("/Users/demo/Projects/site", size: 4 * Self.gb)
        let projects = Self.node("/Users/demo/Projects", size: 9 * Self.gb, children: [app, site])
        let caches = Self.node("/Users/demo/Caches", size: 8 * Self.gb, children: [
            Self.node("/Users/demo/Caches/a", size: 5 * Self.gb),
            Self.node("/Users/demo/Caches/b", size: 3 * Self.gb),
        ])
        let folder = Self.node("/Users/demo", size: 17 * Self.gb, children: [projects, caches])
        let layout = StorageTreemapLayout.make(for: folder, size: CGSize(width: 700, height: 420))

        var basket = StorageBasket()
        basket.add(modules, homeDirectory: Self.home)  // 第三层：不在图上，但让 Projects 与 app 显示角标
        basket.add(caches, homeDirectory: Self.home)   // 顶层格子本身在篮中：嵌套格子随之染色
        let states = layout.basketStates(in: basket)
        func state(_ item: SpaceLensItem) -> BasketMembership { states[layout.index(of: item.id)!] }

        #expect(state(projects) == .hasDescendants(1))
        #expect(state(app) == .hasDescendants(1))
        #expect(state(site) == .none)
        #expect(state(caches) == .entry)
        let cacheChildren = layout.tiles[layout.tiles[layout.index(of: caches.id)!].childRange!]
        #expect(cacheChildren.allSatisfy { BasketMembership(item: $0.item, basket: basket) == .coveredBy("Caches") })
        // 聚合格子永远不算在篮中
        #expect(zip(layout.tiles, states).allSatisfy { !$0.isAggregate || $1 == .none })
    }

    @Test func nestedFocusAndEnterReachGrandchildren() {
        let modules = Self.node("/Users/demo/Projects/app/node_modules", size: 3 * Self.gb)
        let app = Self.node("/Users/demo/Projects/app", size: 5 * Self.gb, children: [modules])
        let projects = Self.node("/Users/demo/Projects", size: 9 * Self.gb, children: [app])
        let demo = Self.node("/Users/demo", size: 9 * Self.gb, children: [projects])
        let model = SpaceLensViewModel()
        model.homeDirectory = Self.home
        model.rootItem = Self.node("/", size: 9 * Self.gb, children: [demo])
        model.currentPath = [demo.id]

        // 树状图悬停嵌套格子：B 与空格作用于它
        model.focusedID = app.id
        #expect(model.focusedItem?.id == app.id)
        model.addKeyboardTargetToBasket()
        #expect(model.basket.contains(id: app.id))

        // 双击嵌套文件夹：一次进两层
        model.enter(app)
        #expect(model.currentPath == [demo.id, projects.id, app.id])
        #expect(model.currentItem?.id == app.id)
    }

    // MARK: - 配色

    @Test func tileColorsKeepTextContrast() {
        for isDark in [false, true] {
            for group in [nil] + (0..<8).map(Optional.some) {
                for depth in 0...1 {
                    for shade in 0..<5 {
                        for isFile in [false, true] {
                            for inBasket in [false, true] {
                                let fill = StorageTreemapPalette.fill(group: group, depth: depth, shade: shade, isFile: isFile, isDark: isDark, inBasket: inBasket)
                                let text = StorageTreemapPalette.label(on: fill)
                                #expect(fill.contrast(with: text) >= 4.5, "group \(String(describing: group)) depth \(depth) shade \(shade) dark \(isDark)")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 截图（仅设置 MACCLEAN_TREEMAP_SHOTS_DIR 时运行）

    @Test func renderTreemapScreens() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MACCLEAN_TREEMAP_SHOTS_DIR"] else { return }
        let outDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let suite = "StorageTreemapShots"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(StorageMapMode.folderMap.rawValue, forKey: StorageMapMode.storageKey)
        defaults.set(FolderMapStyle.treemap.rawValue, forKey: FolderMapStyle.storageKey)
        defer {
            UserDefaults().removePersistentDomain(forName: suite)
            StorageTreemapView.snapshotHoverPoint = nil
        }

        let model = PageModelStore.shared.spaceLens
        let language = Locale.current.language.languageCode?.identifier ?? "xx"
        let hover = ProcessInfo.processInfo.environment["MACCLEAN_TREEMAP_HOVER"].map { NSPointFromString($0) } ?? CGPoint(x: 150, y: 320)
        StorageTreemapView.snapshotHoverPoint = hover
        for (mode, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            Self.populate(model)
            AppState.shared.currentTab = .diskAnalysis
            try await snapshot(
                ContentView().environmentObject(AppState.shared).defaultAppStorage(defaults).frame(width: 1180, height: 760),
                size: CGSize(width: 1180, height: 760), appearance: appearance,
                to: outDir.appendingPathComponent("\(mode)-\(language)-treemap.png"),
                prepare: {
                    AppState.shared.diskInfo = model.diskInfo
                    model.basketPulse = nil
                    model.basketToast = nil
                }
            )
        }
    }

    /// 合成的 /Users/demo：大大小小的文件夹和文件，含若干零碎小项（触发「其他 N 项」），暂存篮里放一项。
    private static func populate(_ model: SpaceLensViewModel) {
        let p = "/Users/demo"
        func files(_ base: String, _ specs: [(String, Int64)]) -> [SpaceLensItem] {
            specs.map { node("\(base)/\($0.0)", size: $0.1, isDirectory: false) }
        }
        let prototype = node("\(p)/Projects/old-prototype", size: 6_900_000_000, children: [
            node("\(p)/Projects/old-prototype/node_modules", size: 5_200_000_000),
            node("\(p)/Projects/old-prototype/build", size: 1_700_000_000),
        ])
        let library = node("\(p)/Library", size: 78_400_000_000, children: [
            node("\(p)/Library/Developer", size: 31_200_000_000),
            node("\(p)/Library/Containers", size: 14_600_000_000),
            node("\(p)/Library/Application Support", size: 12_900_000_000),
            node("\(p)/Library/Caches", size: 9_800_000_000),
            node("\(p)/Library/Mail", size: 4_300_000_000),
            node("\(p)/Library/Group Containers", size: 3_100_000_000),
            node("\(p)/Library/Messages", size: 1_600_000_000),
        ] + (0..<14).map { node("\(p)/Library/Misc\($0)", size: 60_000_000) })
        let vms = node("\(p)/Virtual Machines", size: 41_000_000_000, children: files("\(p)/Virtual Machines", [
            ("Windows 11.vmwarevm", 28_400_000_000), ("Ubuntu 24.04.utm", 12_600_000_000),
        ]))
        let movies = node("\(p)/Movies", size: 29_700_000_000, children: [
            node("\(p)/Movies/Final Cut Library.fcpbundle", size: 17_300_000_000),
            node("\(p)/Movies/Exports", size: 8_200_000_000),
        ] + files("\(p)/Movies", [("trip-4k.mov", 4_200_000_000)]))
        let projects = node("\(p)/Projects", size: 22_600_000_000, children: [
            prototype,
            node("\(p)/Projects/web-app", size: 5_800_000_000),
            node("\(p)/Projects/ios-client", size: 4_700_000_000),
            node("\(p)/Projects/data-pipeline", size: 2_900_000_000),
            node("\(p)/Projects/design-system", size: 1_400_000_000),
            node("\(p)/Projects/notes", size: 900_000_000),
        ])
        let downloads = node("\(p)/Downloads", size: 17_900_000_000, children: files("\(p)/Downloads", [
            ("Xcode_26.xip", 8_100_000_000), ("macOS-installer.dmg", 5_400_000_000),
            ("dataset.zip", 2_600_000_000), ("Figma-1.2.dmg", 1_100_000_000), ("slides.key", 700_000_000),
        ]))
        let pictures = node("\(p)/Pictures", size: 14_800_000_000, children: [
            node("\(p)/Pictures/Photos Library.photoslibrary", size: 13_900_000_000),
        ] + files("\(p)/Pictures", [("wallpapers.zip", 900_000_000)]))
        let small = (0..<24).map { node("\(p)/.config-\($0)", size: Int64(30_000_000 + $0 * 4_000_000)) }
        let demo = node(p, size: 222_000_000_000, children: [
            library, vms, movies, projects, downloads, pictures,
            node("\(p)/Documents", size: 6_300_000_000),
            node("\(p)/.docker", size: 4_100_000_000),
            node("\(p)/Music", size: 2_400_000_000),
            node("\(p)/backup-2025.sparsebundle", size: 1_900_000_000, isDirectory: false),
        ] + small)
        let users = node("/Users", size: 222_500_000_000, children: [demo])
        let root = node("/", size: 402_000_000_000, children: [
            users,
            node("/Applications", size: 61_000_000_000),
            node("/System", size: 18_000_000_000),
            node("/Library", size: 14_000_000_000),
        ])

        model.homeDirectory = home
        model.rootItem = root
        model.diskInfo = DiskInfo(volumeName: "Macintosh HD", totalSpace: 994_000_000_000, freeSpace: 571_000_000_000)
        model.purgeableSpace = 6_800_000_000
        model.unreadableCount = 0
        model.errorMessage = nil
        model.lastRestoreResult = nil
        model.currentPath = [users.id, demo.id]
        model.selectedIDs = []
        model.focusedID = nil
        model.clearBasket()
        model.addToBasket(prototype)
        model.basketToast = nil
        model.basketPulse = nil
        model.phase = .results
    }

    private func snapshot<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL, prepare: () -> Void = {}) async throws {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<6 {
            prepare()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
        }
        prepare()
        host.wantsLayer = true
        host.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let layer = host.layer else { return }
        ctx.scaleBy(x: scale, y: scale)
        if host.isFlipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        guard let image = ctx.makeImage() else { return }
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
