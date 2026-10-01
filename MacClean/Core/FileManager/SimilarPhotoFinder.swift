//
//  SimilarPhotoFinder.swift
//  MacClean
//
//  相似照片：用 Vision 特征向量衡量画面相似度，找出连拍、重复导出、轻微裁剪/压缩等「几乎一样」的照片组。
//  全部为 nonisolated 静态方法，可在后台线程调用（工程默认 MainActor 隔离）。
//

import Foundation
import Vision
import ImageIO
import Accelerate

struct PhotoRecord: Identifiable, Hashable, Sendable {
    let path: String
    let size: Int64
    let pixelWidth: Int
    let pixelHeight: Int
    let modified: Date

    nonisolated var id: String { path }
    nonisolated var name: String { (path as NSString).lastPathComponent }
    nonisolated var pixelCount: Int { pixelWidth * pixelHeight }
}

struct SimilarPhotoGroup: Identifiable, Hashable, Sendable {
    /// 按「最值得保留」排序，第一张为推荐保留项。
    let photos: [PhotoRecord]

    nonisolated var id: String { photos.first?.path ?? "" }
    nonisolated var best: PhotoRecord { photos[0] }
    nonisolated var totalSize: Int64 { photos.reduce(0) { $0 + $1.size } }
    /// 只保留推荐项时可释放的空间。
    nonisolated var reclaimableSize: Int64 { photos.dropFirst().reduce(0) { $0 + $1.size } }
}

enum SimilarPhotoFinder {

    nonisolated static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "bmp"]

    nonisolated private static let skippedDirectoryNames: Set<String> = ["node_modules", "Pods", "Library"]
    nonisolated private static let bundleExtensions: Set<String> = [
        "app", "bundle", "framework", "photoslibrary", "aplibrary", "migratedphotolibrary", "xcassets", "iconset", "xcarchive",
    ]

    /// 相似度档位：归一化特征向量欧氏距离的上限。实测（Vision 特征向量 768 维）：
    /// 同图重新压缩/缩放 < 0.1，裁掉 15% ≈ 0.24，同场景连拍 ≈ 0.38，同构图换配色 ≈ 0.26，
    /// 同一台相机拍的不相干照片 ≥ 0.59。
    enum Sensitivity: String, CaseIterable, Identifiable, Sendable {
        case strict, standard, loose

        nonisolated var id: String { rawValue }
        nonisolated var maxDistance: Float {
            switch self {
            case .strict: return 0.25
            case .standard: return 0.40
            case .loose: return 0.50
            }
        }
        var title: String {
            switch self {
            case .strict: return String(localized: "严格")
            case .standard: return String(localized: "标准")
            case .loose: return String(localized: "宽松")
            }
        }
        var detail: String {
            switch self {
            case .strict: return String(localized: "只找同一张图的缩放、压缩、轻微裁剪版本")
            case .standard: return String(localized: "再加上连拍与构图几乎一致的照片")
            case .loose: return String(localized: "把同一场景的多次拍摄也归为一组")
            }
        }
    }

    nonisolated static let defaultMaxDistance: Float = Sensitivity.standard.maxDistance

    // MARK: - 入口

    /// progress(已处理, 总数)
    nonisolated static func find(
        in directories: [URL],
        maxDistance: Float = defaultMaxDistance,
        minFileSize: Int64 = 30 * 1024,
        limit: Int = 20_000,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> [SimilarPhotoGroup] {
        let urls = collectImages(in: directories, minFileSize: minFileSize, limit: limit)
        progress?(0, urls.count)
        guard urls.count >= 2 else { return [] }

        // 并发提取元数据与特征向量；分块执行以便检查取消与上报进度。
        var records = [PhotoRecord?](repeating: nil, count: urls.count)
        var vectors = [[Float]?](repeating: nil, count: urls.count)
        let chunkSize = 64
        var start = 0
        while start < urls.count {
            try Task.checkCancellation()
            let end = min(start + chunkSize, urls.count)
            let chunk = Array(urls[start..<end])
            var chunkRecords = [PhotoRecord?](repeating: nil, count: chunk.count)
            var chunkVectors = [[Float]?](repeating: nil, count: chunk.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: chunk.count) { index in
                let url = chunk[index]
                guard let (record, thumbnail) = loadImage(url) else { return }
                let vector = featureVector(of: thumbnail)
                lock.lock()
                chunkRecords[index] = record
                chunkVectors[index] = vector
                lock.unlock()
            }
            records.replaceSubrange(start..<end, with: chunkRecords)
            vectors.replaceSubrange(start..<end, with: chunkVectors)
            start = end
            progress?(start, urls.count)
        }

        var validRecords: [PhotoRecord] = []
        var validVectors: [[Float]] = []
        for (record, vector) in zip(records, vectors) {
            guard let record, let vector else { continue }
            validRecords.append(record)
            validVectors.append(vector)
        }
        // 维度必须一致（不同 Vision 版本可能不同，理论上同次运行一致）
        if let dimension = validVectors.first?.count {
            let keep = validVectors.indices.filter { validVectors[$0].count == dimension }
            validRecords = keep.map { validRecords[$0] }
            validVectors = keep.map { validVectors[$0] }
        }

        // 按时间排序后再聚类：种子优先是更早的照片，组内顺序更符合直觉。
        let order = validRecords.indices.sorted { validRecords[$0].modified < validRecords[$1].modified }
        let sortedRecords = order.map { validRecords[$0] }
        let sortedVectors = order.map { validVectors[$0] }

        try Task.checkCancellation()
        let clusters = cluster(vectors: sortedVectors, maxDistance: maxDistance)
        return clusters
            .map { SimilarPhotoGroup(photos: rankForKeeping($0.map { sortedRecords[$0] })) }
            .sorted { $0.reclaimableSize > $1.reclaimableSize }
    }

    // MARK: - 收集图片

    nonisolated static func collectImages(in directories: [URL], minFileSize: Int64, limit: Int) -> [URL] {
        var result: [URL] = []
        var seen: Set<String> = []
        let fileManager = FileManager.default

        for directory in directories {
            var stack = [directory.standardizedFileURL.path]
            while let dirPath = stack.popLast() {
                guard let names = try? fileManager.contentsOfDirectory(atPath: dirPath) else { continue }
                for name in names where !name.hasPrefix(".") {
                    let path = dirPath + "/" + name
                    var info = stat()
                    guard lstat(path, &info) == 0 else { continue }
                    let ext = (name as NSString).pathExtension.lowercased()
                    switch info.st_mode & S_IFMT {
                    case S_IFDIR:
                        if skippedDirectoryNames.contains(name) { continue }
                        if !ext.isEmpty, bundleExtensions.contains(ext) { continue }
                        stack.append(path)
                    case S_IFREG:
                        guard imageExtensions.contains(ext), Int64(info.st_size) >= minFileSize else { continue }
                        guard seen.insert(path).inserted else { continue }
                        result.append(URL(fileURLWithPath: path))
                        if result.count >= limit { return result }
                    default:
                        continue
                    }
                }
            }
        }
        return result
    }

    // MARK: - 图像与特征

    /// 读取尺寸等元数据，并生成 512px 缩略图（已应用 EXIF 方向）用于特征提取，避免整张解码大图。
    nonisolated static func loadImage(_ url: URL) -> (PhotoRecord, CGImage)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }

        let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        // 太小的图多为图标/表情，不参与比较
        guard min(width, height) >= 256 else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let allocated = Int64(info.st_blocks) * 512
        let record = PhotoRecord(
            path: url.path,
            size: allocated > 0 ? allocated : Int64(info.st_size),
            pixelWidth: width,
            pixelHeight: height,
            modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        )
        return (record, thumbnail)
    }

    /// Vision 特征向量，L2 归一化后返回。
    nonisolated static func featureVector(of image: CGImage) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNFeaturePrintObservation else { return nil }

        let count = observation.elementCount
        var vector = [Float](repeating: 0, count: count)
        observation.data.withUnsafeBytes { raw in
            switch observation.elementType {
            case .float:
                let floats = raw.bindMemory(to: Float.self)
                for i in 0..<min(count, floats.count) { vector[i] = floats[i] }
            case .double:
                let doubles = raw.bindMemory(to: Double.self)
                for i in 0..<min(count, doubles.count) { vector[i] = Float(doubles[i]) }
            default:
                break
            }
        }

        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(count))
        norm = sqrt(norm)
        guard norm > 0 else { return nil }
        var scale = 1 / norm
        vDSP_vsmul(vector, 1, &scale, &vector, 1, vDSP_Length(count))
        return vector
    }

    // MARK: - 聚类

    /// 种子式聚类：按顺序取未归组的照片作种子，把与它距离 ≤ maxDistance 的未归组照片并入。
    /// 与连通分量相比不会出现 A≈B≈C 链式把不相干画面串到一起的问题。
    /// 相似度用分块矩阵乘法（归一化向量的点积）一次算一整行块，n=2 万时也只需数秒。
    nonisolated static func cluster(vectors: [[Float]], maxDistance: Float) -> [[Int]] {
        let n = vectors.count
        guard n >= 2, let d = vectors.first?.count, d > 0 else { return [] }

        // ‖a−b‖² = 2 − 2·a·b（单位向量）
        let minDot = 1 - (maxDistance * maxDistance) / 2

        var matrix = [Float](repeating: 0, count: n * d)       // n×d 行主序
        for (i, vector) in vectors.enumerated() {
            matrix.replaceSubrange(i * d..<(i + 1) * d, with: vector)
        }
        var transposed = [Float](repeating: 0, count: d * n)   // d×n
        vDSP_mtrans(matrix, 1, &transposed, 1, vDSP_Length(d), vDSP_Length(n))

        var assigned = [Bool](repeating: false, count: n)
        var groups: [[Int]] = []
        let blockRows = 256
        var dots = [Float](repeating: 0, count: blockRows * n)

        var blockStart = 0
        while blockStart < n {
            let rows = min(blockRows, n - blockStart)
            matrix.withUnsafeBufferPointer { a in
                vDSP_mmul(a.baseAddress! + blockStart * d, 1, transposed, 1, &dots, 1,
                          vDSP_Length(rows), vDSP_Length(n), vDSP_Length(d))
            }
            for r in 0..<rows {
                let i = blockStart + r
                guard !assigned[i] else { continue }
                var members = [i]
                let rowOffset = r * n
                for j in (i + 1)..<n where !assigned[j] && dots[rowOffset + j] >= minDot {
                    members.append(j)
                }
                guard members.count >= 2 else { continue }
                for member in members { assigned[member] = true }
                groups.append(members)
            }
            blockStart += rows
        }
        return groups
    }

    // MARK: - 推荐保留

    /// 分辨率最高 → 文件最大 → 文件名不像副本 → 更早（更可能是原件）。
    nonisolated static func rankForKeeping(_ photos: [PhotoRecord]) -> [PhotoRecord] {
        photos.sorted { lhs, rhs in
            if lhs.pixelCount != rhs.pixelCount { return lhs.pixelCount > rhs.pixelCount }
            if lhs.size != rhs.size { return lhs.size > rhs.size }
            let lhsCopy = looksLikeCopy(lhs.name), rhsCopy = looksLikeCopy(rhs.name)
            if lhsCopy != rhsCopy { return !lhsCopy }
            return lhs.modified < rhs.modified
        }
    }

    nonisolated static func looksLikeCopy(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension.lowercased()
        return stem.hasSuffix(" copy") || stem.contains("副本")
            || stem.range(of: #"[ _-]\(?\d{1,2}\)?$"#, options: .regularExpression) != nil
    }
}
