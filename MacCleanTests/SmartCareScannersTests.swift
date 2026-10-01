//
//  SmartCareScannersTests.swift
//  MacCleanTests
//
//  智能呵护扫描器单元测试
//

import Foundation
import Testing
@testable import MacClean

struct SmartCareScannersTests {

    // MARK: - 测试环境搭建

    private final class TestRoot {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("SmartCareScannersTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit {
            try? FileManager.default.removeItem(at: url)
        }

        @discardableResult
        func makeFile(_ components: String, contents: Data, modified: Date? = nil) -> URL {
            let fileURL = url.appendingPathComponent(components)
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? contents.write(to: fileURL)
            if let modified {
                try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: fileURL.path)
            }
            return fileURL
        }
    }

    // MARK: - DuplicateFinder

    @Test func findsDuplicatesAndKeepsOldestOnly() async throws {
        let root = TestRoot()
        let content = Data(repeating: 0x41, count: 2048)
        let differentContentSameSize = Data(repeating: 0x42, count: 2048)

        let now = Date()
        root.makeFile("dup1.bin", contents: content, modified: now.addingTimeInterval(-300)) // 最早，应被保留
        root.makeFile("dup2.bin", contents: content, modified: now.addingTimeInterval(-200))
        root.makeFile("dup3.bin", contents: content, modified: now)

        // 大小相同但内容不同，不应被误报为重复
        root.makeFile("lookalike.bin", contents: differentContentSameSize, modified: now.addingTimeInterval(-100))

        // 独立文件
        root.makeFile("unique.bin", contents: Data(repeating: 0x43, count: 4096), modified: now)

        let items = try await DuplicateFinder.findDuplicates(in: [root.url], minSize: 1024)

        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.isSelected })
        let names = Set(items.map { $0.name })
        #expect(names == ["dup2.bin", "dup3.bin"])
        #expect(!names.contains("dup1.bin"))
        #expect(!names.contains("lookalike.bin"))
        #expect(!names.contains("unique.bin"))
    }

    @Test func keepsCopyInMoreCanonicalDirectory() async throws {
        let root = TestRoot()
        let content = Data(repeating: 0x51, count: 2048)
        let now = Date()
        // 下载里的更早，但文稿排在前面，应保留文稿里的那份
        root.makeFile("Downloads/report.pdf", contents: content, modified: now.addingTimeInterval(-500))
        root.makeFile("Documents/report.pdf", contents: content, modified: now)

        let items = try await DuplicateFinder.findDuplicates(
            in: [root.url.appendingPathComponent("Documents"), root.url.appendingPathComponent("Downloads")],
            minSize: 1024
        )

        #expect(items.count == 1)
        #expect(items.first?.path.contains("/Downloads/") == true)
    }

    @Test func prefersOriginalNameOverCopySuffix() async throws {
        let root = TestRoot()
        let content = Data(repeating: 0x61, count: 2048)
        let now = Date()
        root.makeFile("photo (1).jpg", contents: content, modified: now.addingTimeInterval(-500))
        root.makeFile("photo copy.jpg", contents: content, modified: now.addingTimeInterval(-400))
        root.makeFile("photo.jpg", contents: content, modified: now)

        let items = try await DuplicateFinder.findDuplicates(in: [root.url], minSize: 1024)

        #expect(Set(items.map(\.name)) == ["photo (1).jpg", "photo copy.jpg"])
    }

    @Test func detectsCopySuffixes() {
        #expect(DuplicateFinder.looksLikeCopy("报告 (2)"))
        #expect(DuplicateFinder.looksLikeCopy("报告 copy"))
        #expect(DuplicateFinder.looksLikeCopy("报告 Copy 3"))
        #expect(DuplicateFinder.looksLikeCopy("报告 副本"))
        #expect(!DuplicateFinder.looksLikeCopy("报告"))
        #expect(!DuplicateFinder.looksLikeCopy("v2-final"))
        #expect(!DuplicateFinder.looksLikeCopy("photocopy"))
    }

    // MARK: - LargeFileFinder

    @Test func findsLargeFilesSortedDescendingAndSkipsHidden() async throws {
        let root = TestRoot()
        root.makeFile("small.bin", contents: Data(repeating: 0, count: 100))
        root.makeFile("medium.bin", contents: Data(repeating: 0, count: 4096))
        root.makeFile("large.bin", contents: Data(repeating: 0, count: 8192))
        root.makeFile(".hidden-large.bin", contents: Data(repeating: 0, count: 16384))

        let items = try await LargeFileFinder.findLargeFiles(under: root.url, minSize: 1024, limit: 10)

        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.isSelected == false })
        #expect(items.first?.name == "large.bin")
        #expect(items.contains { $0.name == "medium.bin" })
        #expect(!items.contains { $0.name == ".hidden-large.bin" })

        // 按大小降序
        let sizes = items.map { $0.size }
        #expect(sizes == sizes.sorted(by: >))
    }

    // MARK: - BrokenLoginItemFinder

    @Test func findsOnlyBrokenLoginItems() {
        let root = TestRoot()

        let brokenPlist: [String: Any] = ["Program": "/nonexistent/path/to/tool"]
        let brokenData = try! PropertyListSerialization.data(fromPropertyList: brokenPlist, format: .xml, options: 0)
        root.makeFile("Library/LaunchAgents/broken.plist", contents: brokenData)

        let okPlist: [String: Any] = ["Program": "/bin/ls"]
        let okData = try! PropertyListSerialization.data(fromPropertyList: okPlist, format: .xml, options: 0)
        root.makeFile("Library/LaunchAgents/ok.plist", contents: okData)

        // 格式损坏的 plist，应被保守跳过，不判定为损坏
        root.makeFile("Library/LaunchAgents/malformed.plist", contents: Data("not a plist".utf8))

        let items = BrokenLoginItemFinder.findBrokenLoginItems(home: root.url)

        #expect(items.count == 1)
        #expect(items.first?.name == "broken.plist")
        #expect(items.first?.isSelected == true)
    }
}
