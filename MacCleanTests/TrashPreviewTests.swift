//
//  TrashPreviewTests.swift
//  MacCleanTests
//
//  清空废纸篓前的内容预览。
//

import Foundation
import Testing
@testable import MacClean

struct TrashPreviewTests {
    private func makeTrash(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (index, name) in names.enumerated() {
            let url = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            // 越靠后的越新
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000 + Double(index))], ofItemAtPath: url.path)
        }
        return dir
    }

    @Test func listsCountAndNewestNames() throws {
        let dir = try makeTrash(["a.txt", "b.txt", "c.txt", "d.txt", ".DS_Store"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let preview = try #require(TrashPreview.load(trashURL: dir, limit: 3))
        #expect(preview.count == 4)
        #expect(preview.recentNames.count == 3)
        #expect(!preview.recentNames.contains(".DS_Store"))
        #expect(preview.summary.contains("d.txt"))
    }

    @Test func emptyAndUnreadableTrash() throws {
        let dir = try makeTrash([])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(TrashPreview.load(trashURL: dir)?.count == 0)
        #expect(TrashPreview.load(trashURL: dir.appendingPathComponent("missing")) == nil)
    }
}
