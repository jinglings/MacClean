//
//  LargeOldAndSimilarPhotoTests.swift
//  MacCleanTests
//
//  大型与陈旧文件扫描/筛选、相似照片聚类与推荐保留 的单元测试
//

import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MacClean

struct LargeOldAndSimilarPhotoTests {

    private final class TestRoot {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("LargeOldAndSimilarPhotoTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        func makeFile(_ components: String, bytes: Int) {
            let fileURL = url.appendingPathComponent(components)
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(repeating: 0x5A, count: bytes).write(to: fileURL)
        }
    }

    private let now = Date()
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func record(_ name: String, size: Int64, modified: Date, opened: Date? = nil) -> LargeFileRecord {
        LargeFileRecord(
            path: "/Users/x/\(name)",
            size: size,
            modified: modified,
            lastOpened: opened,
            kind: FileKind.classify(extension: (name as NSString).pathExtension)
        )
    }

    // MARK: - 类型

    @Test func classifiesCommonExtensions() {
        #expect(FileKind.classify(extension: "MOV") == .video)
        #expect(FileKind.classify(extension: "dmg") == .diskImage)
        #expect(FileKind.classify(extension: "zip") == .archive)
        #expect(FileKind.classify(extension: "heic") == .image)
        #expect(FileKind.classify(extension: "flac") == .audio)
        #expect(FileKind.classify(extension: "pdf") == .document)
        #expect(FileKind.classify(extension: "bin") == .other)
    }

    // MARK: - 扫描

    @Test func scannerSkipsLibraryHiddenDependenciesAndBundles() async throws {
        let root = TestRoot()
        root.makeFile("Movies/trip.mov", bytes: 40_000)
        root.makeFile("Downloads/tool.dmg", bytes: 30_000)
        root.makeFile("Downloads/small.txt", bytes: 100)
        root.makeFile("Library/Caches/huge.bin", bytes: 50_000)
        root.makeFile(".hidden/huge.bin", bytes: 50_000)
        root.makeFile("Code/web/node_modules/pkg/huge.bin", bytes: 50_000)
        root.makeFile("Applications/Big.app/Contents/Resources/huge.bin", bytes: 50_000)

        let records = try await LargeOldFileScanner.scan(under: root.url, minSize: 10_000, resolveLastOpened: false)

        #expect(records.map(\.name) == ["trip.mov", "tool.dmg"])
        #expect(records.map(\.kind) == [.video, .diskImage])
    }

    @Test func parallelWalkFindsEveryFileInWideDeepTree() async throws {
        let root = TestRoot()
        for i in 0..<60 {
            for depth in 0..<4 {
                let dir = (0...depth).map { "d\(i)-\($0)" }.joined(separator: "/")
                root.makeFile("\(dir)/big.bin", bytes: 12_000)
                root.makeFile("\(dir)/tiny.bin", bytes: 10)
            }
        }
        let records = try await LargeOldFileScanner.scan(under: root.url, minSize: 10_000, resolveLastOpened: false)
        #expect(records.count == 240)
        #expect(Set(records.map(\.path)).count == 240)
    }

    // MARK: - 筛选

    @Test func filterBySizeIdleAndKind() {
        let records = [
            record("old.mov", size: 2_000_000_000, modified: daysAgo(400)),
            record("recent.mov", size: 3_000_000_000, modified: daysAgo(10)),
            // 很久前修改、但最近打开过：不算陈旧
            record("opened.zip", size: 2_000_000_000, modified: daysAgo(900), opened: daysAgo(5)),
            record("small.zip", size: 60_000_000, modified: daysAgo(900)),
        ]

        var filter = LargeFileFilter()
        filter.sizeFloor = .gb1
        #expect(filter.apply(to: records, now: now).map(\.name) == ["recent.mov", "old.mov", "opened.zip"])

        filter.idleAge = .year1
        #expect(filter.apply(to: records, now: now).map(\.name) == ["old.mov"])

        filter.idleAge = .any
        filter.kinds = [.archive]
        #expect(filter.apply(to: records, now: now).map(\.name) == ["opened.zip"])

        filter.kinds = []
        filter.sizeFloor = .mb50
        filter.sort = .idle
        #expect(filter.apply(to: records, now: now).first?.name == "small.zip")
    }

    // MARK: - 聚类

    /// 构造指定彼此距离的单位向量：沿 x 轴与 y 轴旋转。
    private func unitVector(angle: Float) -> [Float] { [cos(angle), sin(angle), 0, 0] }
    /// 单位向量夹角 θ 对应欧氏距离 2·sin(θ/2)
    private func angle(forDistance d: Float) -> Float { 2 * asin(d / 2) }

    @Test func clusteringDoesNotChainDissimilarPhotos() {
        // a–b 距离 0.3、b–c 距离 0.3，但 a–c ≈ 0.6：种子式聚类只把 b 并入 a
        let step = angle(forDistance: 0.3)
        let vectors = [unitVector(angle: 0), unitVector(angle: step), unitVector(angle: 2 * step), [0, 0, 1, 0]]
        let groups = SimilarPhotoFinder.cluster(vectors: vectors, maxDistance: 0.35)
        #expect(groups == [[0, 1]])
    }

    @Test func clusteringHandlesMoreRowsThanOneBlock() {
        // 600 个向量跨越多个 256 行的块；每 3 个一组几乎相同
        var vectors: [[Float]] = []
        for group in 0..<200 {
            var base = [Float](repeating: 0, count: 256)
            base[group] = 1
            for jitter in 0..<3 {
                var v = base
                v[(group + 1) % 256] = Float(jitter) * 0.01
                let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
                vectors.append(v.map { $0 / norm })
            }
        }
        let groups = SimilarPhotoFinder.cluster(vectors: vectors, maxDistance: 0.2)
        #expect(groups.count == 200)
        #expect(groups.allSatisfy { $0.count == 3 })
    }

    // MARK: - 推荐保留

    @Test func rankPrefersResolutionThenSizeThenOriginalName() {
        let date = Date()
        let small = PhotoRecord(path: "/p/IMG_0001.jpg", size: 900, pixelWidth: 1000, pixelHeight: 800, modified: date)
        let big = PhotoRecord(path: "/p/IMG_0001 small.jpg", size: 500, pixelWidth: 4000, pixelHeight: 3000, modified: date)
        #expect(SimilarPhotoFinder.rankForKeeping([small, big]).first == big)

        let original = PhotoRecord(path: "/p/IMG_0002.jpg", size: 500, pixelWidth: 100, pixelHeight: 100, modified: date)
        let copy = PhotoRecord(path: "/p/IMG_0002 copy.jpg", size: 500, pixelWidth: 100, pixelHeight: 100, modified: date.addingTimeInterval(-10))
        #expect(SimilarPhotoFinder.rankForKeeping([copy, original]).first == original)
    }

    @Test func copyNameHeuristics() {
        #expect(SimilarPhotoFinder.looksLikeCopy("IMG_1234 copy.jpg"))
        #expect(SimilarPhotoFinder.looksLikeCopy("照片 副本.png"))
        #expect(SimilarPhotoFinder.looksLikeCopy("photo (1).jpg"))
        #expect(SimilarPhotoFinder.looksLikeCopy("photo-2.jpg"))
        #expect(!SimilarPhotoFinder.looksLikeCopy("IMG_1234.jpg"))
    }

    // MARK: - 端到端（真实 Vision 特征）

    private func writeImage(_ url: URL, width: Int, height: Int, type: UTType, draw: (CGContext, CGFloat, CGFloat) -> Void) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        draw(context, CGFloat(width), CGFloat(height))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func drawScene(_ context: CGContext, _ w: CGFloat, _ h: CGFloat) {
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.35))
        context.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: w * 0.65, y: h * 0.6, width: w * 0.18, height: w * 0.18))
        context.setFillColor(CGColor(red: 0.45, green: 0.25, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: w * 0.2, y: h * 0.35, width: w * 0.06, height: h * 0.3))
    }

    private func drawOther(_ context: CGContext, _ w: CGFloat, _ h: CGFloat) {
        for i in 0..<12 {
            context.setFillColor(i.isMultiple(of: 2) ? CGColor(red: 0.9, green: 0.1, blue: 0.3, alpha: 1) : CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1))
            context.fill(CGRect(x: CGFloat(i) * w / 12, y: 0, width: w / 12, height: h))
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: w * 0.3, y: h * 0.3, width: w * 0.4, height: h * 0.4))
    }

    @Test func findsResizedCopyAndKeepsHigherResolution() throws {
        let root = TestRoot()
        let original = root.url.appendingPathComponent("scene.png")
        let smaller = root.url.appendingPathComponent("scene-export.jpg")
        let other = root.url.appendingPathComponent("stripes.png")
        try writeImage(original, width: 1600, height: 1200, type: .png, draw: drawScene)
        try writeImage(smaller, width: 800, height: 600, type: .jpeg, draw: drawScene)
        try writeImage(other, width: 1600, height: 1200, type: .png, draw: drawOther)

        let groups = try SimilarPhotoFinder.find(in: [root.url], minFileSize: 1)

        #expect(groups.count == 1)
        #expect(Set(groups.first?.photos.map(\.name) ?? []) == ["scene.png", "scene-export.jpg"])
        #expect(groups.first?.best.name == "scene.png")
    }
}
