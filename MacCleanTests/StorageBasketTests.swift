//
//  StorageBasketTests.swift
//  MacCleanTests
//
//  存储地图「暂存篮」：去重、累计、PathGuard 拒绝、部分失败、拖放载荷、可清除空间。
//  截图只用合成的目录树，绝不扫描真实磁盘。
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MacClean

@MainActor
struct StorageBasketTests {
    private static let home = URL(fileURLWithPath: "/Users/demo")
    private static let gb: Int64 = 1_000_000_000

    private static func item(_ path: String, size: Int64, children: [SpaceLensItem] = [], isVirtual: Bool = false) -> SpaceLensItem {
        SpaceLensItem(
            name: isVirtual ? String(localized: "其他") : URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            size: size,
            isDirectory: true,
            children: children,
            itemCount: children.reduce(0) { $0 + 1 + $1.itemCount },
            isReadable: !isVirtual,
            isVirtual: isVirtual,
            lastModified: nil
        )
    }

    // MARK: - 加入 / 移出 / 合计

    @Test func addRemoveAndTotal() {
        var basket = StorageBasket()
        let a = Self.item("/Users/demo/Projects/app/node_modules", size: 3 * Self.gb)
        let b = Self.item("/Users/demo/Library/Caches/com.example", size: 2 * Self.gb)

        #expect(basket.add(a, homeDirectory: Self.home) == .added(absorbed: 0))
        #expect(basket.add(b, homeDirectory: Self.home) == .added(absorbed: 0))
        #expect(basket.count == 2)
        #expect(basket.totalSize == 5 * Self.gb)

        #expect(basket.add(a, homeDirectory: Self.home) == .duplicate)
        #expect(basket.totalSize == 5 * Self.gb)

        basket.remove(id: a.id)
        #expect(basket.count == 1)
        #expect(basket.totalSize == 2 * Self.gb)

        basket.removeAll()
        #expect(basket.isEmpty)
        #expect(basket.totalSize == 0)
    }

    @Test func ancestorAbsorbsDescendants() {
        var basket = StorageBasket()
        let modules = Self.item("/Users/demo/Projects/app/node_modules", size: 3 * Self.gb)
        let build = Self.item("/Users/demo/Projects/app/build", size: 1 * Self.gb)
        let sibling = Self.item("/Users/demo/Projects/application", size: 4 * Self.gb) // 前缀相同但不是子项
        basket.add(modules, homeDirectory: Self.home)
        basket.add(build, homeDirectory: Self.home)
        basket.add(sibling, homeDirectory: Self.home)

        let app = Self.item("/Users/demo/Projects/app", size: 5 * Self.gb)
        #expect(basket.add(app, homeDirectory: Self.home) == .added(absorbed: 2))
        #expect(basket.count == 2)
        #expect(basket.contains(id: sibling.id))
        #expect(!basket.contains(id: modules.id))
        #expect(basket.entries.first { $0.id == app.id }?.absorbedCount == 2)
        // 合计只算顶层条目，不重复计入被吸收的子项
        #expect(basket.totalSize == 9 * Self.gb)
    }

    @Test func descendantOfExistingEntryIsNoOp() {
        var basket = StorageBasket()
        let projects = Self.item("/Users/demo/Projects", size: 10 * Self.gb)
        basket.add(projects, homeDirectory: Self.home)

        let inner = Self.item("/Users/demo/Projects/app/node_modules", size: 3 * Self.gb)
        #expect(basket.add(inner, homeDirectory: Self.home) == .coveredBy(name: "Projects"))
        #expect(basket.count == 1)
        #expect(basket.totalSize == 10 * Self.gb)
        #expect(basket.entry(covering: inner.path)?.id == projects.id)
        #expect(basket.entry(covering: "/Users/demo/Projects2") == nil)
    }

    @Test func dataVolumePrefixIsTheSameLocation() {
        var basket = StorageBasket()
        basket.add(Self.item("/System/Volumes/Data/Users/demo/Projects", size: Self.gb), homeDirectory: Self.home)
        let inner = Self.item("/Users/demo/Projects/app", size: Self.gb / 2)
        #expect(basket.add(inner, homeDirectory: Self.home) == .coveredBy(name: "Projects"))
    }

    // MARK: - PathGuard

    @Test(arguments: [
        ("/Users/demo/Documents", "受保护：主目录顶层文件夹"),
        ("/Users/demo/Library", "受保护：主目录与资源库"),
        ("/Users/demo", "受保护：主目录与资源库"),
        ("/Users/someone", "受保护：磁盘顶层目录"),
        ("/Library/Caches/com.apple.something", "受保护：系统文件夹"),
        ("/System/Library/Frameworks", "受保护：系统文件夹"),
        ("/Users/demo/Library/Mobile Documents/com~apple~CloudDocs/Notes", "受保护：iCloud 云盘"),
    ])
    func pathGuardRejectsProtectedPaths(path: String, reason: String) {
        var basket = StorageBasket()
        let result = basket.add(Self.item(path, size: Self.gb), homeDirectory: Self.home)
        #expect(result == .rejected(reason: String(localized: String.LocalizationValue(reason))))
        #expect(basket.isEmpty)
    }

    @Test func virtualOtherNodeIsRefused() {
        var basket = StorageBasket()
        let other = Self.item("/Users/demo/Projects/.space-lens-other", size: Self.gb, isVirtual: true)
        guard case .rejected = basket.add(other, homeDirectory: Self.home) else {
            Issue.record("virtual node should be rejected")
            return
        }
        #expect(basket.isEmpty)
    }

    // MARK: - 清理结果

    @Test func partialFailureKeepsFailedEntries() {
        var basket = StorageBasket()
        let ok = Self.item("/Users/demo/Projects/a", size: Self.gb)
        let locked = Self.item("/Users/demo/Projects/b", size: 2 * Self.gb)
        let vanished = Self.item("/Users/demo/Projects/c", size: 3 * Self.gb)
        [ok, locked, vanished].forEach { basket.add($0, homeDirectory: Self.home) }
        let attempted = basket.entries

        let removed = basket.applyCleanOutcome(
            attempted: attempted,
            stillExists: { $0 == locked.path || $0 == vanished.path },
            failureMessages: [locked.path: "Operation not permitted"]
        )

        #expect(Set(removed.map(\.id)) == [ok.id])
        #expect(basket.count == 2)
        #expect(basket.entries.first { $0.id == locked.id }?.failureReason == "Operation not permitted")
        // 没有错误信息但仍在原处：给通用原因
        #expect(basket.entries.first { $0.id == vanished.id }?.failureReason == String(localized: "未能移到废纸篓"))
        #expect(basket.failedEntries.count == 2)
        #expect(basket.totalSize == 5 * Self.gb)
    }

    @Test func allSucceededEmptiesBasket() {
        var basket = StorageBasket()
        basket.add(Self.item("/Users/demo/Projects/a", size: Self.gb), homeDirectory: Self.home)
        basket.applyCleanOutcome(attempted: basket.entries, stillExists: { _ in false }, failureMessages: [:])
        #expect(basket.isEmpty)
    }

    @Test func confirmationWarnings() {
        var basket = StorageBasket()
        basket.add(Self.item("/Users/demo/Movies/Exports", size: 12 * Self.gb), homeDirectory: Self.home)
        basket.add(Self.item("/Users/demo/Projects/a", size: Self.gb), homeDirectory: Self.home)
        #expect(basket.personalEntries(homeDirectory: Self.home).map(\.name) == ["Exports"])
        #expect(basket.largeEntries.map(\.name) == ["Exports"])
    }

    // MARK: - 拖放载荷

    @Test func dropPayloadRoundTrip() {
        let id = UUID()
        let payload = StorageBasketDropPayload.encode(id)
        #expect(StorageBasketDropPayload.decode(payload) == id)
        #expect(StorageBasketDropPayload.decode(" \(payload)\n") == id)
        #expect(StorageBasketDropPayload.decode(id.uuidString) == nil)
        #expect(StorageBasketDropPayload.decode("/Users/demo/Projects") == nil)
        #expect(StorageBasketDropPayload.decode(StorageBasketDropPayload.prefix + "not-a-uuid") == nil)
    }

    @Test func dropOnViewModelFindsNestedItem() {
        let deep = Self.item("/Users/demo/Projects/app/node_modules", size: 3 * Self.gb)
        let tree = Self.item("/", size: 50 * Self.gb, children: [
            Self.item("/Users", size: 40 * Self.gb, children: [
                Self.item("/Users/demo", size: 40 * Self.gb, children: [
                    Self.item("/Users/demo/Projects", size: 8 * Self.gb, children: [
                        Self.item("/Users/demo/Projects/app", size: 5 * Self.gb, children: [deep])
                    ])
                ])
            ])
        ])
        let model = SpaceLensViewModel()
        model.homeDirectory = Self.home
        model.rootItem = tree

        #expect(model.handleBasketDrop([StorageBasketDropPayload.encode(deep.id), "random text"]))
        #expect(model.basket.contains(id: deep.id))
        #expect(model.basketPulse?.bytes == 3 * Self.gb)
        #expect(!model.handleBasketDrop(["random text"]))
        #expect(model.basket.count == 1)
    }

    // MARK: - 其他

    @Test func purgeableComputation() {
        #expect(DiskAnalyzer.purgeableBytes(available: 10 * Self.gb, availableForImportantUsage: 25 * Self.gb) == 15 * Self.gb)
        #expect(DiskAnalyzer.purgeableBytes(available: 30 * Self.gb, availableForImportantUsage: 25 * Self.gb) == 0)
    }

    @Test func displayPathUsesTilde() {
        #expect(StorageBasket.displayPath("/Users/demo/Projects/app", homeDirectory: Self.home) == "~/Projects/app")
        #expect(StorageBasket.displayPath("/System/Volumes/Data/Users/demo/x", homeDirectory: Self.home) == "~/x")
        #expect(StorageBasket.displayPath("/Users/demo2/x", homeDirectory: Self.home) == "/Users/demo2/x")
    }

    @Test func membership() {
        var basket = StorageBasket()
        let app = Self.item("/Users/demo/Projects/app", size: Self.gb)
        basket.add(app, homeDirectory: Self.home)
        #expect(BasketMembership(item: app, basket: basket) == .entry)
        #expect(BasketMembership(item: Self.item("/Users/demo/Projects/app/src", size: 1), basket: basket) == .coveredBy("app"))
        #expect(BasketMembership(item: Self.item("/Users/demo/Projects", size: 1), basket: basket) == .hasDescendants(1))
        #expect(BasketMembership(item: Self.item("/Users/demo/Movies", size: 1), basket: basket) == .none)
    }

    // MARK: - 截图（仅设置 MACCLEAN_SNAPSHOT_DIR 时运行）

    @Test func renderBasketStates() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MACCLEAN_SNAPSHOT_DIR"] else { return }
        let outDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let suite = "StorageBasketSnapshotTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(StorageMapMode.folderMap.rawValue, forKey: StorageMapMode.storageKey)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let model = PageModelStore.shared.spaceLens
        let language = Locale.current.language.languageCode?.identifier ?? "xx"
        for (mode, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            Self.populate(model)
            AppState.shared.currentTab = .diskAnalysis
            try await snapshot(
                ContentView().environmentObject(AppState.shared).defaultAppStorage(defaults).frame(width: 1180, height: 760),
                size: CGSize(width: 1180, height: 760), appearance: appearance,
                to: outDir.appendingPathComponent("\(language)-\(mode)-storage-basket.png")
            )
            try await snapshot(
                StorageBasketListView(viewModel: model).frame(width: 480),
                size: CGSize(width: 480, height: 470), appearance: appearance,
                to: outDir.appendingPathComponent("\(language)-\(mode)-storage-basket-list.png")
            )
            // 空暂存篮：底栏显示拖放提示
            model.clearBasket()
            model.basketToast = nil
            try await snapshot(
                ContentView().environmentObject(AppState.shared).defaultAppStorage(defaults).frame(width: 1180, height: 760),
                size: CGSize(width: 1180, height: 760), appearance: appearance,
                to: outDir.appendingPathComponent("\(language)-\(mode)-storage-basket-empty.png")
            )
        }
    }

    /// 官网用的整窗截图（含侧栏）。仅设置 MACCLEAN_WEBSITE_SHOTS_DIR 时运行；侧栏磁盘卡也换成合成数据。
    @Test func renderWebsiteScreens() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MACCLEAN_WEBSITE_SHOTS_DIR"] else { return }
        let outDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let suite = "StorageBasketWebsiteShots"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(StorageMapMode.folderMap.rawValue, forKey: StorageMapMode.storageKey)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let model = PageModelStore.shared.spaceLens
        let language = Locale.current.language.languageCode?.identifier ?? "xx"
        for (mode, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            Self.populate(model, withFailure: false)
            model.basketPulse = nil
            model.basketToast = nil
            AppState.shared.currentTab = .diskAnalysis
            try await snapshot(
                ContentView().environmentObject(AppState.shared).defaultAppStorage(defaults).frame(width: 1180, height: 760),
                size: CGSize(width: 1180, height: 760), appearance: appearance,
                to: outDir.appendingPathComponent("\(mode)-\(language)-storage_basket.png"),
                prepare: {
                    // 侧栏会异步读取真实磁盘容量，每轮都盖回合成值
                    AppState.shared.diskInfo = model.diskInfo
                    model.basketPulse = nil
                    model.basketToast = nil
                }
            )
        }
    }

    /// 合成的整盘树，停在 /Users/demo 这一层，篮中放几项（含一项清理失败）。
    private static func populate(_ model: SpaceLensViewModel, withFailure: Bool = true) {
        let modules = item("/Users/demo/Projects/web-app/node_modules", size: 4_800_000_000)
        let derived = item("/Users/demo/Library/Developer/Xcode/DerivedData", size: 21_400_000_000)
        let vms = item("/Users/demo/Virtual Machines", size: 38_600_000_000)
        let exports = item("/Users/demo/Movies/Exports", size: 12_200_000_000)
        let demo = item("/Users/demo", size: 214_000_000_000, children: [
            item("/Users/demo/Library", size: 72_500_000_000, children: [
                item("/Users/demo/Library/Developer", size: 30_000_000_000, children: [
                    item("/Users/demo/Library/Developer/Xcode", size: 28_000_000_000, children: [derived])
                ])
            ]),
            vms,
            item("/Users/demo/Movies", size: 31_900_000_000, children: [exports]),
            item("/Users/demo/Projects", size: 24_300_000_000, children: [
                item("/Users/demo/Projects/web-app", size: 9_100_000_000, children: [modules])
            ]),
            item("/Users/demo/Downloads", size: 18_700_000_000),
            item("/Users/demo/Pictures", size: 15_200_000_000),
            item("/Users/demo/Documents", size: 6_400_000_000),
            item("/Users/demo/.docker", size: 4_100_000_000),
            item("/Users/demo/.space-lens-other", size: 2_300_000_000, isVirtual: true),
        ])
        let users = item("/Users", size: 214_500_000_000, children: [demo])
        let root = item("/", size: 402_000_000_000, children: [
            users,
            item("/Applications", size: 61_000_000_000),
            item("/System", size: 18_000_000_000),
            item("/Library", size: 14_000_000_000),
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
        model.addToBasket([derived, modules, exports])
        model.addToBasket(vms)
        if withFailure {
        model.basket.applyCleanOutcome(
            attempted: model.basket.entries.filter { $0.id == exports.id },
            stillExists: { _ in true },
            failureMessages: [exports.path: String(localized: "未能移到废纸篓")]
        )
        }
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
