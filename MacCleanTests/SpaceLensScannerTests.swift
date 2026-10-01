//
//  SpaceLensScannerTests.swift
//  MacCleanTests
//
//  空间透镜树构建器单元测试
//

import Foundation
import Testing
@testable import MacClean

struct SpaceLensScannerTests {

    // MARK: - 测试环境搭建

    /// 隔离的临时目录树，测试结束后自动清理。
    private final class TestTree {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("SpaceLensScannerTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit {
            try? FileManager.default.removeItem(at: url)
        }

        func path(_ components: String) -> String {
            url.appendingPathComponent(components).path
        }

        @discardableResult
        func makeDirectory(_ components: String) -> String {
            let dirURL = url.appendingPathComponent(components)
            try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            return dirURL.path
        }

        @discardableResult
        func makeFile(_ components: String, sizeBytes: Int) -> String {
            let fileURL = url.appendingPathComponent(components)
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = Data(repeating: 0x41, count: sizeBytes)
            try? data.write(to: fileURL)
            return fileURL.path
        }

        func makeSymlink(_ components: String, pointingTo target: String) {
            let linkURL = url.appendingPathComponent(components)
            try? FileManager.default.createDirectory(
                at: linkURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: target)
        }
    }

    private func freshProgressState() -> DiskAnalyzer.SpaceLensProgressState {
        DiskAnalyzer.SpaceLensProgressState(diskUsedSpace: 1, progress: nil)
    }

    // MARK: - 目录大小聚合

    @Test func aggregatesDirectorySizeAcrossFilesAndSubdirectories() throws {
        let tree = TestTree()
        tree.makeFile("a.txt", sizeBytes: 1000)
        tree.makeFile("sub/b.txt", sizeBytes: 2000)
        tree.makeFile("sub/nested/c.txt", sizeBytes: 3000)

        let item = try DiskAnalyzer.buildSpaceLensTree(
            at: tree.url.path, visibleFolderLimit: 10, progressState: freshProgressState()
        )

        // 分配大小（st_blocks）通常 >= 文件逻辑大小，用逻辑大小之和作为下界断言。
        #expect(item.size >= 6000)
        #expect(item.isDirectory)
    }

    // MARK: - 剪枝

    @Test func prunesToVisibleFolderLimitPlusOtherNode() throws {
        let tree = TestTree()
        let limit = 3
        // 造 limit + 2 个大小递减的子目录
        for index in 0..<(limit + 2) {
            tree.makeFile("dir\(index)/payload.bin", sizeBytes: (limit + 2 - index) * 10_000)
        }
        tree.makeFile("direct.txt", sizeBytes: 500)

        let item = try DiskAnalyzer.buildSpaceLensTree(
            at: tree.url.path, visibleFolderLimit: limit, progressState: freshProgressState()
        )

        // limit 个真实目录 + 1 个"其他"虚拟节点
        #expect(item.children.count == limit + 1)
        let realDirs = item.children.filter { !$0.isVirtual }
        let otherNodes = item.children.filter { $0.isVirtual }
        #expect(realDirs.count == limit)
        #expect(otherNodes.count == 1)

        guard let other = otherNodes.first else {
            Issue.record("missing '其他' node")
            return
        }
        // "其他".size 应等于被剪掉的两个目录 + 直属文件之和
        let prunedDirsSize = (0..<2).reduce(Int64(0)) { sum, i in
            // 被剪掉的是 size 最小的两个：index 3、4（对应大小 10_000、20_000）
            sum + Int64((i + 1) * 10_000)
        }
        #expect(other.size >= prunedDirsSize + 500)
    }

    // MARK: - 排序

    @Test func sortsChildrenBySizeDescending() throws {
        let tree = TestTree()
        tree.makeFile("small/f.bin", sizeBytes: 1_000)
        tree.makeFile("medium/f.bin", sizeBytes: 5_000)
        tree.makeFile("large/f.bin", sizeBytes: 20_000)

        let item = try DiskAnalyzer.buildSpaceLensTree(
            at: tree.url.path, visibleFolderLimit: 10, progressState: freshProgressState()
        )

        let sizes = item.children.map(\.size)
        #expect(sizes == sizes.sorted(by: >))
    }

    // MARK: - 符号链接不跟随

    @Test func doesNotFollowSymlinks() throws {
        let tree = TestTree()
        let realBigDir = tree.makeDirectory("real-big")
        tree.makeFile("real-big/huge.bin", sizeBytes: 500_000)
        tree.makeSymlink("link-to-big", pointingTo: realBigDir)

        let item = try DiskAnalyzer.buildSpaceLensTree(
            at: tree.url.path, visibleFolderLimit: 10, progressState: freshProgressState()
        )

        // 除去真实目录 real-big 之外，符号链接本身不应作为大小 > 0 的目录节点出现，
        // 也不应把 huge.bin 的大小重复计入总大小。
        let linkNode = item.children.first { $0.name == "link-to-big" }
        #expect(linkNode == nil || linkNode?.size == 0)
        // 总大小应接近 real-big 单独的贡献，而不是双倍（real-big + 被跟随的 link）。
        let realBigNode = item.children.first { $0.name == "real-big" }
        if let realBigNode {
            #expect(item.size < realBigNode.size * 2)
        }
    }

    // MARK: - 隐藏文件计入大小

    @Test func countsHiddenFilesTowardSize() throws {
        let tree = TestTree()
        tree.makeFile(".hidden-file", sizeBytes: 4_096)

        let item = try DiskAnalyzer.buildSpaceLensTree(
            at: tree.url.path, visibleFolderLimit: 10, progressState: freshProgressState()
        )

        #expect(item.size >= 4_096)
    }
}
