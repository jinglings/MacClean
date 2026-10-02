//
//  DuplicateFinderTests.swift
//  MacCleanTests
//
//  「重复与相似 → 完全相同的文件」：DuplicateFinder 扫描规则、保留规则与 DuplicatesViewModel 的选择不变量。
//  全部在临时目录树上进行，不读取真实主目录。
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MacClean

struct DuplicateFinderTests {

    // MARK: - 测试环境

    /// 临时「主目录」。路径经 realpath 解析（/var → /private/var），与扫描结果中的路径一致。
    private final class TempHome {
        let url: URL
        init() {
            let raw = FileManager.default.temporaryDirectory
                .appendingPathComponent("DuplicateFinderTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            let resolved = realpath(raw.path, nil).map { pointer -> String in
                defer { free(pointer) }
                return String(cString: pointer)
            } ?? raw.path
            url = URL(fileURLWithPath: resolved, isDirectory: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        @discardableResult
        func file(_ relative: String, _ contents: Data, modified: Date? = nil) -> URL {
            let fileURL = url.appendingPathComponent(relative)
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? contents.write(to: fileURL)
            if let modified {
                try? FileManager.default.setAttributes([.modificationDate: modified, .creationDate: modified], ofItemAtPath: fileURL.path)
            }
            return fileURL
        }

        func path(_ relative: String) -> String { url.appendingPathComponent(relative).path }

        func options(minSize: Int64 = 1, types: Set<DuplicateTypeFilter> = []) -> DuplicateScanOptions {
            DuplicateScanOptions(
                minSize: minSize,
                types: types,
                home: url,
                preferredLocations: ["Documents", "Desktop", "Downloads"].map { url.appendingPathComponent($0) }
            )
        }

        func scan(_ roots: [String]? = nil, minSize: Int64 = 1, types: Set<DuplicateTypeFilter> = []) throws -> DuplicateScanResult {
            let rootURLs = roots?.map { url.appendingPathComponent($0) } ?? [url]
            return try DuplicateFinder.scan(roots: rootURLs, options: options(minSize: minSize, types: types))
        }
    }

    private static func bytes(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    // MARK: - 分组

    @Test func groupsIdenticalContentAcrossFolders() throws {
        let home = TempHome()
        let content = Self.bytes(4096, seed: 1)
        home.file("Downloads/sub/report.pdf", content)
        home.file("Documents/report.pdf", content)
        home.file("Projects/report copy.pdf", content)
        // 同样大小但内容不同：不应归组
        home.file("Desktop/other.pdf", Self.bytes(4096, seed: 2))

        let result = try home.scan()
        #expect(result.groups.count == 1)
        let group = try #require(result.groups.first)
        #expect(group.files.count == 3)
        #expect(group.size == 4096)
        #expect(group.suggestedKeeper.path == home.path("Documents/report.pdf"))
        #expect(!group.files.contains { $0.name == "other.pdf" })
        #expect(result.filesChecked == 4)
    }

    @Test func partialFingerprintCollisionIsResolvedByFullHash() throws {
        let home = TempHome()
        let size = 400 * 1024
        let base = Self.bytes(size, seed: 7)
        var middleChanged = base
        middleChanged[size / 2] ^= 0xFF

        let a = home.file("Docs/a.bin", base)
        let b = home.file("Docs/b.bin", middleChanged)
        home.file("Docs/a-again.bin", base)

        // 首尾 64KB 相同 → 粗筛指纹撞车，必须靠全量哈希区分
        let fa = try DuplicateFinder.partialFingerprint(ofPath: a.path, size: Int64(size))
        let fb = try DuplicateFinder.partialFingerprint(ofPath: b.path, size: Int64(size))
        #expect(fa == fb)

        let result = try home.scan()
        #expect(result.groups.count == 1)
        #expect(Set(result.groups[0].files.map(\.name)) == ["a.bin", "a-again.bin"])
        // 全量哈希读了三个文件的全部内容
        #expect(result.bytesHashed >= Int64(size) * 3)
    }

    @Test func smallFilesBetweenOneAndTwoSamplesAreComparedInFull() throws {
        let home = TempHome()
        let size = 100 * 1024   // 64KB < size ≤ 128KB：指纹覆盖全部内容
        let base = Self.bytes(size, seed: 3)
        var changed = base
        changed[size - 70_000] ^= 0x01
        home.file("Docs/x.bin", base)
        home.file("Docs/y.bin", changed)
        #expect(try home.scan().groups.isEmpty)
    }

    @Test func skipsHiddenLibraryTrashAndPackages() throws {
        let home = TempHome()
        let content = Self.bytes(2048, seed: 9)
        home.file("Documents/keep.txt", content)
        home.file(".secret/keep.txt", content)
        home.file("Documents/.keep.txt", content)
        home.file("Library/Caches/keep.txt", content)
        home.file(".Trash/keep.txt", content)
        home.file("Things.app/Contents/Resources/keep.txt", content)
        home.file("Code/node_modules/pkg/keep.txt", content)

        #expect(try home.scan().groups.isEmpty)

        home.file("Desktop/keep.txt", content)
        let result = try home.scan()
        #expect(result.groups.count == 1)
        #expect(Set(result.groups[0].files.map(\.path)) == [home.path("Documents/keep.txt"), home.path("Desktop/keep.txt")])
    }

    @Test func libraryIsScannedOnlyWhenAddedExplicitlyButICloudStaysOut() throws {
        let home = TempHome()
        let content = Self.bytes(2048, seed: 4)
        home.file("Library/A/one.bin", content)
        home.file("Library/B/two.bin", content)
        home.file("Library/Mobile Documents/com~apple~CloudDocs/three.bin", content)

        #expect(try home.scan().groups.isEmpty)

        let library = try home.scan(["Library"])
        #expect(library.groups.count == 1)
        #expect(library.groups[0].files.count == 2)

        // 用户显式添加 iCloud 云盘时才进入（测试文件不是 ubiquitous item，视为已在本机）
        let explicit = try home.scan(["Library/A", "Library/Mobile Documents"])
        #expect(explicit.groups.first?.files.count == 2)
    }

    @Test func doesNotFollowSymlinksOrCountHardLinks() throws {
        let home = TempHome()
        let original = home.file("Docs/a.bin", Self.bytes(8192, seed: 5))
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: home.path("Docs/a-symlink.bin"), withDestinationPath: original.path)
        try fm.createSymbolicLink(atPath: home.path("LinkedDocs"), withDestinationPath: home.path("Docs"))
        try fm.linkItem(at: original, to: home.url.appendingPathComponent("Docs/a-hardlink.bin"))

        #expect(try home.scan().groups.isEmpty)
    }

    @Test func overlappingRootsAreNotCountedTwice() throws {
        let home = TempHome()
        let content = Self.bytes(3000, seed: 6)
        home.file("Documents/a.bin", content)
        home.file("Downloads/a.bin", content)

        let result = try DuplicateFinder.scan(
            roots: [home.url, home.url.appendingPathComponent("Documents"), home.url],
            options: home.options()
        )
        #expect(result.groups.count == 1)
        #expect(result.groups[0].files.count == 2)
        #expect(result.filesChecked == 2)
    }

    @Test func zeroByteFilesAreNeverDuplicates() throws {
        let home = TempHome()
        home.file("a/empty1", Data())
        home.file("b/empty2", Data())
        #expect(try home.scan(minSize: 0).groups.isEmpty)
    }

    // MARK: - 条件

    @Test func minSizeFilter() throws {
        let home = TempHome()
        let small = Self.bytes(50 * 1024, seed: 1)
        let large = Self.bytes(200 * 1024, seed: 2)
        home.file("a/small.bin", small)
        home.file("b/small.bin", small)
        home.file("a/large.bin", large)
        home.file("b/large.bin", large)

        #expect(try home.scan(minSize: DuplicateSizeFloor.any.rawValue).groups.count == 2)
        let filtered = try home.scan(minSize: DuplicateSizeFloor.kb100.rawValue)
        #expect(filtered.groups.map(\.size) == [Int64(200 * 1024)])
        #expect(try home.scan(minSize: DuplicateSizeFloor.mb1.rawValue).groups.isEmpty)
    }

    @Test func typeFilter() throws {
        let home = TempHome()
        for (name, seed) in [("photo.JPG", 1), ("clip.mov", 2), ("song.mp3", 3), ("paper.pdf", 4), ("setup.dmg", 5), ("bundle.zip", 6), ("notes.xyz", 7)] {
            let data = Self.bytes(1000 + Int(seed), seed: UInt8(seed))
            home.file("a/\(name)", data)
            home.file("b/\(name)", data)
        }

        func names(_ types: Set<DuplicateTypeFilter>) throws -> Set<String> {
            Set(try home.scan(types: types).groups.map(\.suggestedKeeper.name))
        }
        #expect(try names([]).count == 7)
        #expect(try names([.images]) == ["photo.JPG"])
        #expect(try names([.videos, .audio]) == ["clip.mov", "song.mp3"])
        #expect(try names([.documents]) == ["paper.pdf"])
        #expect(try names([.archives]) == ["setup.dmg", "bundle.zip"])
    }

    // MARK: - 保留规则

    private func keeper(_ files: [DuplicateFile], preferred: [String] = ["/h/Documents", "/h/Desktop", "/h/Downloads"]) -> String {
        files.map { DuplicateFinder.KeeperCandidate(file: $0, preferredLocations: preferred) }
            .sorted(by: DuplicateFinder.keeperOrder)
            .first!.file.path
    }

    private func file(_ path: String, _ date: Date = Date(timeIntervalSince1970: 1_000)) -> DuplicateFile {
        DuplicateFile(path: path, size: 10, modified: date, created: date)
    }

    @Test func keeperPrefersDocumentsThenDesktopThenDownloads() {
        let early = Date(timeIntervalSince1970: 0)
        #expect(keeper([file("/h/Downloads/a.pdf", early), file("/h/Desktop/a.pdf"), file("/h/Documents/a.pdf")]) == "/h/Documents/a.pdf")
        #expect(keeper([file("/h/Downloads/a.pdf", early), file("/h/Desktop/a.pdf")]) == "/h/Desktop/a.pdf")
        #expect(keeper([file("/h/Projects/a.pdf", early), file("/h/Downloads/a.pdf")]) == "/h/Downloads/a.pdf")
        // 前缀相同但不是子目录的不算
        #expect(keeper([file("/h/DocumentsOld/a.pdf", early), file("/h/Downloads/a.pdf")]) == "/h/Downloads/a.pdf")
    }

    @Test func keeperPrefersOriginalNameThenEarliestThenShortestPath() {
        let early = Date(timeIntervalSince1970: 0)
        #expect(keeper([file("/h/x/a (1).pdf", early), file("/h/x/a copy.pdf", early), file("/h/x/a 副本.pdf", early), file("/h/x/a.pdf")]) == "/h/x/a.pdf")
        #expect(keeper([file("/h/x/new.pdf"), file("/h/y/old.pdf", early)]) == "/h/y/old.pdf")
        #expect(keeper([file("/h/deeper/folder/a.pdf"), file("/h/x/a.pdf")]) == "/h/x/a.pdf")
    }

    @Test func checkupWrapperStillReturnsCopiesOnly() async throws {
        let home = TempHome()
        let content = Self.bytes(2048, seed: 8)
        home.file("Documents/r.pdf", content)
        home.file("Downloads/r.pdf", content, modified: Date(timeIntervalSince1970: 0))
        let items = try await DuplicateFinder.findDuplicates(
            in: [home.url.appendingPathComponent("Documents"), home.url.appendingPathComponent("Downloads")],
            minSize: 1024
        )
        #expect(items.map(\.path) == [home.path("Downloads/r.pdf")])
        #expect(items.allSatisfy { $0.category == .duplicates && $0.isSelected })
    }

    // MARK: - 取消

    @Test func scanStopsWhenCancelled() async throws {
        let home = TempHome()
        for index in 0..<50 { home.file("d\(index % 5)/f\(index).bin", Self.bytes(512, seed: UInt8(index % 3))) }
        let options = home.options()
        let root = home.url

        let task = Task.detached { () throws -> DuplicateScanResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try DuplicateFinder.scan(roots: [root], options: options)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @MainActor
    @Test func cancellingFromViewModelKeepsPreviousState() async throws {
        let home = TempHome()
        let model = DuplicatesViewModel(home: home.url, defaults: Self.scratchDefaults())
        model.scan()
        #expect(model.isScanning)
        model.cancelScan()
        #expect(!model.isScanning)
        #expect(model.wasCancelled)
        #expect(!model.hasScanned)
        // 已取消的扫描任务结束时不应写入结果
        try await Task.sleep(for: .milliseconds(300))
        #expect(!model.hasScanned)
        #expect(model.groups.isEmpty)
    }

    // MARK: - 选择不变量

    private static func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "DuplicateFinderTests-\(UUID().uuidString)")!
    }

    private static func sampleResult() -> DuplicateScanResult {
        let date = Date(timeIntervalSince1970: 0)
        func group(_ id: String, size: Int64, _ paths: [String]) -> DuplicateGroup {
            DuplicateGroup(id: id, size: size, files: paths.map { DuplicateFile(path: $0, size: size, modified: date, created: date) })
        }
        return DuplicateScanResult(
            groups: [
                group("g1", size: 1_000, ["/h/Documents/a", "/h/Downloads/a", "/h/x/a copy"]),
                group("g2", size: 500, ["/h/Documents/b", "/h/Desktop/b"]),
            ],
            filesChecked: 10,
            bytesHashed: 0,
            deniedFolders: []
        )
    }

    @MainActor
    @Test func preselectsEveryCopyExceptTheKeeper() {
        let model = DuplicatesViewModel(home: URL(fileURLWithPath: "/h"), defaults: Self.scratchDefaults())
        model.apply(Self.sampleResult())
        #expect(model.selected == ["/h/Downloads/a", "/h/x/a copy", "/h/Desktop/b"])
        #expect(model.fullySelectedGroupCount == 0)
        #expect(model.reclaimableSize == 1_000 * 2 + 500)
        #expect(model.selectedSize == 2_500)
        #expect(model.copyCount == 3)
    }

    @MainActor
    @Test func keeperCanNeverBeSelected() {
        let model = DuplicatesViewModel(home: URL(fileURLWithPath: "/h"), defaults: Self.scratchDefaults())
        model.apply(Self.sampleResult())
        let g1 = model.groups[0], g2 = model.groups[1]

        model.toggle(g1.files[0], in: g1)
        model.toggle(g2.files[0], in: g2)
        #expect(!model.isSelected(g1.files[0]))
        #expect(!model.isSelected(g2.files[0]))

        model.selectAllCopies()
        #expect(model.fullySelectedGroupCount == 0)

        // 「保留这个」：换保留项后，新保留项取消勾选，原保留项变为待删副本
        model.keep(g1.files[2], in: g1)
        #expect(model.keeperPath(of: g1) == "/h/x/a copy")
        #expect(!model.isSelected(g1.files[2]))
        #expect(model.isSelected(g1.files[0]))
        model.toggle(g1.files[2], in: g1)
        #expect(!model.isSelected(g1.files[2]))
        #expect(model.fullySelectedGroupCount == 0)

        model.keep(g2.files[1], in: g2)
        model.toggle(g2.files[0], in: g2)
        model.toggle(g2.files[0], in: g2)
        #expect(model.fullySelectedGroupCount == 0)

        let targets = model.cleanupTargets(fileExists: { _ in true })
        #expect(!targets.contains { $0.path == "/h/x/a copy" || $0.path == "/h/Desktop/b" })
        #expect(targets.allSatisfy { $0.category == .duplicates && $0.removesContainer })
        for group in model.groups {
            #expect(group.files.contains { file in !targets.contains { $0.path == file.path } })
        }
    }

    @MainActor
    @Test func groupsWhoseKeeperVanishedAreSkipped() {
        let model = DuplicatesViewModel(home: URL(fileURLWithPath: "/h"), defaults: Self.scratchDefaults())
        model.apply(Self.sampleResult())
        let targets = model.cleanupTargets(fileExists: { $0 != "/h/Documents/a" })
        #expect(targets.map(\.path) == ["/h/Desktop/b"])
    }

    @MainActor
    @Test func ignoringFilesKeepsInvariantAndDropsSingletons() {
        let defaults = Self.scratchDefaults()
        let model = DuplicatesViewModel(home: URL(fileURLWithPath: "/h"), defaults: defaults)
        model.apply(Self.sampleResult())
        model.keep(model.groups[1].files[1], in: model.groups[1])
        // 忽略会写入全局忽略列表；用不会真实存在的路径并在结束后移除
        model.ignore(model.groups[1].files[0])
        defer { IgnoreList.remove("/h/Documents/b") }
        #expect(model.groups.count == 1)
        #expect(!model.selected.contains("/h/Documents/b"))
        #expect(!model.selected.contains("/h/Desktop/b"))
        #expect(model.fullySelectedGroupCount == 0)
    }

    @MainActor
    @Test func remembersLastMode() {
        let defaults = Self.scratchDefaults()
        #expect(DuplicatesViewModel(home: URL(fileURLWithPath: "/h"), defaults: defaults).mode == .exact)
        DuplicatesViewModel(home: URL(fileURLWithPath: "/h"), defaults: defaults).mode = .similar
        #expect(DuplicatesViewModel(home: URL(fileURLWithPath: "/h"), defaults: defaults).mode == .similar)
    }

    @MainActor
    @Test func displayPathIsRelativeToHome() {
        let model = DuplicatesViewModel(home: URL(fileURLWithPath: "/nonexistent-home"), defaults: Self.scratchDefaults())
        #expect(model.displayPath("/nonexistent-home/Documents/a.pdf") == "~/Documents/a.pdf")
        #expect(model.displayPath("/Volumes/X/a.pdf") == "/Volumes/X/a.pdf")
    }

    @MainActor
    @Test func endToEndScanThroughViewModel() async throws {
        let home = TempHome()
        let content = Self.bytes(5000, seed: 11)
        home.file("Downloads/a.bin", content)
        home.file("Documents/a.bin", content)
        let model = DuplicatesViewModel(home: home.url, defaults: Self.scratchDefaults())
        model.minSize = .any
        model.scan()
        for _ in 0..<100 where model.isScanning { try await Task.sleep(for: .milliseconds(50)) }
        #expect(model.hasScanned)
        #expect(model.groups.count == 1)
        #expect(model.selected == [home.path("Downloads/a.bin")])
        #expect(!model.settingsChangedSinceScan)
        model.minSize = .mb10
        #expect(model.settingsChangedSinceScan)
    }
}

// MARK: - 结果页截图（仅在设置 MACCLEAN_SNAPSHOT_DIR 时运行，内容全部来自临时目录）

@MainActor
struct DuplicatesSnapshotTests {
    @Test func renderResults() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["MACCLEAN_SNAPSHOT_DIR"] else { return }
        if let tabs = env["MACCLEAN_SNAPSHOT_TABS"], !tabs.isEmpty, !tabs.contains(AppTab.similarPhotos.rawValue) { return }
        let outDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("DupSnapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: raw) }
        let fixtures: [(String, Int, UInt8, TimeInterval)] = [
            ("Documents/Trip/IMG_2041.HEIC", 3_400_000, 1, -90),
            ("Downloads/IMG_2041.HEIC", 3_400_000, 1, -10),
            ("Desktop/IMG_2041 (1).HEIC", 3_400_000, 1, -5),
            ("Documents/Contracts/Lease 2026.pdf", 1_800_000, 2, -200),
            ("Downloads/Lease 2026 copy.pdf", 1_800_000, 2, -20),
            ("Downloads/Installers/Figma.dmg", 4_200_000, 3, -40),
            ("Desktop/Old stuff/Figma.dmg", 4_200_000, 3, -60),
            ("Music/Demo/track01.m4a", 1_200_000, 4, -300),
            ("Documents/Archive/track01.m4a", 1_200_000, 4, -100),
        ]
        for (path, size, seed, days) in fixtures {
            let url = raw.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) }).write(to: url)
            let date = Date().addingTimeInterval(days * 86_400)
            try FileManager.default.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
        }

        let original = PageModelStore.shared.duplicates
        defer { PageModelStore.shared.duplicates = original }
        let defaults = UserDefaults(suiteName: "DupSnapshot-\(UUID().uuidString)")!
        let model = DuplicatesViewModel(home: raw, defaults: defaults)
        model.mode = .exact
        model.scan()
        for _ in 0..<200 where model.isScanning { try await Task.sleep(for: .milliseconds(50)) }
        PageModelStore.shared.duplicates = model
        AppState.shared.currentTab = .similarPhotos

        for (mode, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let root = ContentView()
                .environmentObject(AppState.shared)
                .frame(width: 1180, height: 760)
            try await snapshot(root, size: CGSize(width: 1180, height: 760), appearance: appearance,
                               to: outDir.appendingPathComponent("\(mode)-duplicates-results.png"))
        }
        // 相似照片模式（未扫描状态），确认切换后原有界面不变
        model.mode = .similar
        for (mode, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let root = ContentView()
                .environmentObject(AppState.shared)
                .frame(width: 1180, height: 760)
            try await snapshot(root, size: CGSize(width: 1180, height: 760), appearance: appearance,
                               to: outDir.appendingPathComponent("\(mode)-duplicates-similar-mode.png"))
        }
    }

    private func snapshot<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL) async throws {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
        }
        host.wantsLayer = true
        host.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        guard let ctx = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
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
