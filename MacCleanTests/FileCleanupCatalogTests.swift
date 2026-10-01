//
//  FileCleanupCatalogTests.swift
//  MacCleanTests
//
//  释放空间 / 开发缓存 扫描规则、PathGuard 新分类、清理记录恢复、重复文件去重 的单元测试
//

import Foundation
import Testing
@testable import MacClean

struct FileCleanupCatalogTests {

    private final class TestHome {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("FileCleanupCatalogTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        func path(_ components: String) -> String { url.appendingPathComponent(components).path }

        func makeDirectory(_ components: String) {
            try? FileManager.default.createDirectory(at: url.appendingPathComponent(components), withIntermediateDirectories: true)
        }

        @discardableResult
        func makeFile(_ components: String, bytes: Int = 16, modified: Date? = nil) -> URL {
            let fileURL = url.appendingPathComponent(components)
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data((0..<bytes).map { UInt8($0 % 251) }).write(to: fileURL)
            if let modified { setModified(components, modified) }
            return fileURL
        }

        func setModified(_ components: String, _ date: Date) {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path(components))
        }
    }

    private let now = Date()
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    // MARK: - PathGuard 新分类

    @Test func trashRootCanBeEmptiedButNotRemoved() throws {
        let home = TestHome()
        home.makeDirectory(".Trash")
        try PathGuard.validate(path: home.path(".Trash"), category: .trash, homeDirectory: home.url)
        #expect(throws: PathGuardError.self) {
            try PathGuard.validate(path: home.path(".Trash"), category: .trash, removesContainer: true, homeDirectory: home.url)
        }
    }

    @Test func devRuleRootIsClearableButGenericHomeFolderIsNot() throws {
        let home = TestHome()
        home.makeDirectory(".gradle/caches")
        home.makeDirectory(".gradle/other")
        try PathGuard.validate(path: home.path(".gradle/caches"), category: .developerTools, homeDirectory: home.url)
        #expect(throws: PathGuardError.self) {
            try PathGuard.validate(path: home.path(".gradle/other"), category: .developerTools, homeDirectory: home.url)
        }
    }

    @Test func savedApplicationStateCanBeClearedButCachesRootCannot() throws {
        let home = TestHome()
        home.makeDirectory("Library/Saved Application State")
        home.makeDirectory("Library/Caches")
        try PathGuard.validate(path: home.path("Library/Saved Application State"), category: .userCache, homeDirectory: home.url)
        #expect(throws: PathGuardError.self) {
            try PathGuard.validate(path: home.path("Library/Caches"), category: .userCache, homeDirectory: home.url)
        }
    }

    @Test func installersMustLiveInDownloadsOrDesktop() throws {
        let home = TestHome()
        home.makeFile("Downloads/app.dmg")
        home.makeFile("Documents/app.dmg")
        try PathGuard.validate(path: home.path("Downloads/app.dmg"), category: .installers, removesContainer: true, homeDirectory: home.url)
        #expect(throws: PathGuardError.self) {
            try PathGuard.validate(path: home.path("Documents/app.dmg"), category: .installers, removesContainer: true, homeDirectory: home.url)
        }
    }

    @Test func iosBackupChildAllowedButBackupRootIsNot() throws {
        let home = TestHome()
        let root = "Library/Application Support/MobileSync/Backup"
        home.makeDirectory(root + "/00008030-ABC")
        try PathGuard.validate(path: home.path(root + "/00008030-ABC"), category: .iosBackups, removesContainer: true, homeDirectory: home.url)
        #expect(throws: PathGuardError.self) {
            try PathGuard.validate(path: home.path(root), category: .iosBackups, removesContainer: true, homeDirectory: home.url)
        }
    }

    // MARK: - JunkScanner

    @Test func installersAreFoundAndOldOnesPreselected() {
        let home = TestHome()
        home.makeFile("Downloads/old.dmg", modified: daysAgo(60))
        home.makeFile("Downloads/new.pkg", modified: daysAgo(2))
        home.makeFile("Downloads/notes.txt", modified: daysAgo(60))
        home.makeFile("Downloads/2025/image.iso", modified: daysAgo(400))

        let items = JunkScanner.scanInstallers(home: home.url, now: now)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })

        #expect(Set(byName.keys) == ["old.dmg", "new.pkg", "image.iso"])
        #expect(byName["old.dmg"]?.isSelected == true)
        #expect(byName["new.pkg"]?.isSelected == false)
        #expect(byName["image.iso"]?.removesContainer == false)
        #expect(items.allSatisfy { $0.category == .installers })
    }

    @Test func logsOnlyCountFilesOlderThanRetention() {
        let home = TestHome()
        home.makeFile("Library/Logs/App/old.log", bytes: 600_000, modified: daysAgo(30))
        home.makeFile("Library/Logs/App/new.log", bytes: 600_000, modified: daysAgo(1))
        home.makeFile("Library/Logs/Fresh/new.log", bytes: 600_000, modified: daysAgo(1))

        let items = JunkScanner.scanLogs(home: home.url, now: now)
        #expect(items.map(\.name) == ["App"])
        let size = items.first?.size ?? 0
        #expect(size >= 600_000 && size < 1_200_000)
    }

    @Test func trashIsReportedUnselected() {
        let home = TestHome()
        home.makeDirectory(".Trash")
        #expect(JunkScanner.scanTrash(home: home.url).isEmpty)

        home.makeFile(".Trash/deleted.bin", bytes: 4096)
        let items = JunkScanner.scanTrash(home: home.url)
        #expect(items.count == 1)
        #expect(items.first?.isSelected == false)
        #expect(items.first?.category.isRecoverable == false)
    }

    @Test func appCachesExcludeBrowserAndDeveloperCaches() {
        let home = TestHome()
        home.makeFile("Library/Caches/com.example.app/blob", bytes: 2_000_000)
        home.makeFile("Library/Caches/com.apple.Safari/blob", bytes: 2_000_000)
        home.makeFile("Library/Caches/Homebrew/blob", bytes: 2_000_000)

        let names = JunkScanner.scanAppCaches(home: home.url).map(\.name)
        #expect(names == ["com.example.app"])
        #expect(JunkScanner.scanBrowserCaches(home: home.url).map(\.name) == ["Safari"])
    }

    // MARK: - 开发缓存

    @Test func perChildKeepNewestLeavesMostRecentUnselected() {
        let home = TestHome()
        let root = "Library/Developer/Xcode/iOS DeviceSupport"
        home.makeFile(root + "/16.0/Symbols/a", bytes: 2_000_000)
        home.makeFile(root + "/17.0/Symbols/a", bytes: 2_000_000)
        home.setModified(root + "/16.0", daysAgo(300))
        home.setModified(root + "/17.0", daysAgo(3))

        let rule = DevCacheCatalog.rules.first { $0.relativePath == root }!
        let items = DevCacheCatalog.scan(rule: rule, home: home.url)
        let selectedByName = Dictionary(uniqueKeysWithValues: items.map { ($0.path.components(separatedBy: "/").last!, $0.isSelected) })

        #expect(selectedByName == ["16.0": true, "17.0": false])
        #expect(items.allSatisfy { $0.removesContainer })
    }

    @Test func projectArtifactsRequireMarkerAndStaleness() {
        let home = TestHome()
        // 闲置 120 天的 JS 项目
        home.makeFile("Code/old-web/node_modules/lib/index.js", bytes: 2048)
        home.makeFile("Code/old-web/package.json", modified: daysAgo(120))
        // 近期活跃的项目
        home.makeFile("Code/active/node_modules/lib/index.js", bytes: 2048)
        home.makeFile("Code/active/package.json", modified: daysAgo(1))
        // 没有 package.json 的 node_modules 不认
        home.makeFile("Code/loose/node_modules/lib/index.js", bytes: 2048)
        home.makeFile("Code/loose/readme.md", modified: daysAgo(200))
        // 闲置 45 天的 Rust 项目：列出但不默认勾选
        home.makeFile("Code/rusty/target/debug/app", bytes: 2048)
        home.makeFile("Code/rusty/Cargo.toml", modified: daysAgo(45))
        home.setModified("Code/rusty/target", daysAgo(45))
        home.setModified("Code/old-web/node_modules", daysAgo(120))

        let items = ProjectArtifactFinder.find(home: home.url, now: now, minSize: 0)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })

        #expect(Set(byName.keys) == ["old-web / node_modules", "rusty / target"])
        #expect(byName["old-web / node_modules"]?.isSelected == true)
        #expect(byName["rusty / target"]?.isSelected == false)
        #expect(items.allSatisfy { $0.category == .projectArtifacts && $0.removesContainer })
    }

    // MARK: - 清理记录

    @Test func historyRestoresMovedItemsToOriginalLocation() throws {
        let home = TestHome()
        let original = home.makeFile("Downloads/report.pdf", bytes: 1024)
        let trashed = home.url.appendingPathComponent("FakeTrash/report.pdf")
        try FileManager.default.createDirectory(at: trashed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: trashed)

        let store = CleanupHistoryStore(fileURL: home.url.appendingPathComponent("history.json"))
        let id = try #require(store.record(entries: [
            CleanupHistoryEntry(originalPath: original.path, trashedPath: trashed.path, size: 1024),
        ]))
        #expect(store.session(id: id)?.restorableEntries.count == 1)

        let result = store.restore(sessionID: id)
        #expect(result.restoredCount == 1)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: trashed.path))
        #expect(store.session(id: id)?.restorableEntries.isEmpty == true)
        #expect(store.session(id: id)?.restoredAt != nil)
    }

    @Test func historyDoesNotOverwriteRecreatedOriginal() throws {
        let home = TestHome()
        let trashed = home.makeFile("FakeTrash/a.txt")
        let original = home.makeFile("Downloads/a.txt") // 原位置已有同名新文件

        let store = CleanupHistoryStore(fileURL: home.url.appendingPathComponent("history.json"))
        let id = try #require(store.record(entries: [
            CleanupHistoryEntry(originalPath: original.path, trashedPath: trashed.path, size: 16),
        ]))
        #expect(store.restore(sessionID: id).restoredCount == 0)
        #expect(FileManager.default.fileExists(atPath: trashed.path))
    }

    @Test func emptyHistoryIsNotRecorded() {
        let home = TestHome()
        let store = CleanupHistoryStore(fileURL: home.url.appendingPathComponent("history.json"))
        #expect(store.record(entries: []) == nil)
        #expect(store.sessions().isEmpty)
    }

    // MARK: - 始终忽略

    @Test func ignoreListFiltersPathAndDescendants() {
        let suite = "FileCleanupCatalogTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        IgnoreList.add("/Users/x/Library/Caches/keep", defaults: defaults)
        let items = ["/Users/x/Library/Caches/keep", "/Users/x/Library/Caches/keep/sub", "/Users/x/Library/Caches/keeper"].map {
            CleanableItem(name: $0, path: $0, size: 1, category: .userCache, isSelected: true)
        }
        #expect(IgnoreList.filter(items, defaults: defaults).map(\.path) == ["/Users/x/Library/Caches/keeper"])
    }

    // MARK: - 重复文件

    @Test func hardLinksAreNotReportedAsDuplicates() async throws {
        let home = TestHome()
        let original = home.makeFile("Docs/a.bin", bytes: 200_000)
        try FileManager.default.linkItem(at: original, to: home.url.appendingPathComponent("Docs/a-link.bin"))

        let items = try await DuplicateFinder.findDuplicates(in: [home.url.appendingPathComponent("Docs")], minSize: 1)
        #expect(items.isEmpty)
    }

    @Test func realCopiesAreReportedOnce() async throws {
        let home = TestHome()
        let original = home.makeFile("Docs/a.bin", bytes: 200_000)
        try FileManager.default.copyItem(at: original, to: home.url.appendingPathComponent("Docs/a-copy.bin"))
        // 同大小但尾部不同，粗筛阶段就应被排除
        var different = try Data(contentsOf: original)
        different[different.count - 1] ^= 0xFF
        try different.write(to: home.url.appendingPathComponent("Docs/b.bin"))

        let items = try await DuplicateFinder.findDuplicates(in: [home.url.appendingPathComponent("Docs")], minSize: 1)
        #expect(items.count == 1)
        #expect(items.first.map { ["a.bin", "a-copy.bin"].contains($0.name) } == true)
    }
}
