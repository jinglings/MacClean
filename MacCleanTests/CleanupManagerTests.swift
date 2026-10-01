//
//  CleanupManagerTests.swift
//  MacCleanTests
//
//  CleanupManager 单元测试
//

import Foundation
import Testing
@testable import MacClean

struct CleanupManagerTests {

    private final class TestDir {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("CleanupManagerTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test func allocatedSizeForSingleFileMatchesActualData() {
        let dir = TestDir()
        let fileURL = dir.url.appendingPathComponent("file.bin")
        let data = Data(repeating: 0x41, count: 100_000)
        try? data.write(to: fileURL)

        let size = CleanupManager.allocatedSize(atPath: fileURL.path)
        // 磁盘分配的块大小是 512 的整数倍，且至少要能容纳写入的数据
        #expect(size >= Int64(data.count))
        #expect(size % 512 == 0)
    }

    @Test func allocatedSizeRecursesIntoSubdirectories() {
        let dir = TestDir()
        let sub = dir.url.appendingPathComponent("sub", isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let fileA = dir.url.appendingPathComponent("a.bin")
        let fileB = sub.appendingPathComponent("b.bin")
        try? Data(repeating: 0x41, count: 50_000).write(to: fileA)
        try? Data(repeating: 0x42, count: 70_000).write(to: fileB)

        let totalSize = CleanupManager.allocatedSize(atPath: dir.url.path)
        let sizeA = CleanupManager.allocatedSize(atPath: fileA.path)
        let sizeB = CleanupManager.allocatedSize(atPath: fileB.path)

        // 目录总大小至少要覆盖两个子文件各自的占用（外加目录节点自身占用）
        #expect(totalSize >= sizeA + sizeB)
    }

    @Test func allocatedSizeForEmptyDirectoryIsNonNegative() {
        let dir = TestDir()
        let size = CleanupManager.allocatedSize(atPath: dir.url.path)
        #expect(size >= 0)
    }

    @Test func allocatedSizeForMissingPathIsZero() {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)").path
        #expect(CleanupManager.allocatedSize(atPath: missingPath) == 0)
    }
}
