//
//  FileSearchTests.swift
//  MacCleanTests
//
//  文件搜索：Spotlight 谓词构建、名称匹配、时间筛选、磁盘直接查找 的单元测试
//

import Foundation
import Testing
@testable import MacClean

struct FileSearchTests {

    private final class TestRoot {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("FileSearchTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        func makeFile(_ components: String, bytes: Int = 10, modified: Date? = nil) {
            let fileURL = url.appendingPathComponent(components)
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(repeating: 0x41, count: bytes).write(to: fileURL)
            if let modified {
                try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: fileURL.path)
            }
        }
    }

    // MARK: - 谓词

    @Test func emptyQueryBuildsNoPredicate() {
        #expect(SpotlightPredicate.build(for: FileSearchQuery()) == nil)
        var blank = FileSearchQuery()
        blank.term = "   "
        #expect(SpotlightPredicate.build(for: blank) == nil)
    }

    @Test func nameTermUsesContainsOrLike() {
        var query = FileSearchQuery()
        query.term = "报告"
        #expect(SpotlightPredicate.build(for: query)?.predicateFormat == #"kMDItemFSName CONTAINS[cd] "报告""#)

        query.term = "*.dmg"
        #expect(SpotlightPredicate.build(for: query)?.predicateFormat == #"kMDItemFSName LIKE[cd] "*.dmg""#)
    }

    @Test func contentSearchOrsNameAndText() {
        var query = FileSearchQuery()
        query.term = "invoice"
        query.matchContents = true
        let format = SpotlightPredicate.build(for: query)?.predicateFormat ?? ""
        #expect(format.contains("kMDItemFSName CONTAINS[cd] \"invoice\""))
        #expect(format.contains("kMDItemTextContent CONTAINS[cd] \"invoice\""))
        #expect(format.contains(" OR "))
    }

    @Test func filtersAreAndedTogether() {
        var query = FileSearchQuery()
        query.term = "a"
        query.kinds = [.video]
        query.size = .gb1
        query.date = .week
        let format = SpotlightPredicate.build(for: query)?.predicateFormat ?? ""
        #expect(format.contains("kMDItemContentTypeTree == \"public.movie\""))
        #expect(format.contains("kMDItemFSSize >= 1073741824"))
        #expect(format.contains("kMDItemFSContentChangeDate >="))
        #expect(format.components(separatedBy: " AND ").count == 4)
    }

    @Test func filterOnlyQueryIsAllowed() {
        var query = FileSearchQuery()
        query.size = .gb1
        #expect(!query.isEmpty)
        #expect(SpotlightPredicate.build(for: query)?.predicateFormat == "kMDItemFSSize >= 1073741824")
    }

    // MARK: - 匹配与时间

    @Test func nameMatchingIsCaseInsensitiveAndSupportsWildcards() {
        #expect(NameMatcher.matches("Quarterly Report.PDF", term: "report"))
        #expect(NameMatcher.matches("setup-2.1.dmg", term: "*.dmg"))
        #expect(!NameMatcher.matches("setup.dmg.part", term: "*.dmg"))
        #expect(NameMatcher.matches("IMG_0001.HEIC", term: "img_000?.heic"))
        #expect(NameMatcher.matches("anything", term: ""))
    }

    @Test func todayCutoffIsStartOfDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = ISO8601DateFormatter().date(from: "2026-09-30T08:30:00Z")!
        let cutoff = SearchDateFilter.today.cutoff(now: now, calendar: calendar)!
        #expect(calendar.dateComponents([.hour, .minute], from: cutoff) == DateComponents(hour: 0, minute: 0))
        #expect(SearchDateFilter.any.cutoff(now: now) == nil)
    }

    @Test func kindMatchingByExtension() {
        #expect(SearchKindFilter.video.matches(extension: "MOV", isDirectory: false))
        #expect(!SearchKindFilter.video.matches(extension: "mov", isDirectory: true))
        #expect(SearchKindFilter.folder.matches(extension: "", isDirectory: true))
        #expect(SearchKindFilter.document.matches(extension: "md", isDirectory: false))
    }

    @Test func globAndContainsEdgeCases() {
        #expect(NameMatcher.matches("报告-2025.docx", term: "报告"))
        #expect(NameMatcher.matches("README", term: "*"))
        #expect(NameMatcher.matches("a.tar.gz", term: "*.gz"))
        #expect(NameMatcher.matches("abc", term: "a*c"))
        #expect(!NameMatcher.matches("ab", term: "a?c"))
        #expect(!NameMatcher.matches("short", term: "much-longer-term"))
    }

    @Test func longestLiteralForWildcardPrefilter() {
        #expect(NameMatcher.longestLiteral(in: Array("*.dmg".utf8)) == Array(".dmg".utf8))
        #expect(NameMatcher.longestLiteral(in: Array("img_????_final*.heic".utf8)) == Array("_final".utf8))
        #expect(NameMatcher.longestLiteral(in: Array("*".utf8)).isEmpty)
    }

    @Test func indexPreservesOriginalCaseAndDoesNotMatchAcrossNames() async throws {
        let root = TestRoot()
        root.makeFile("ABc.TXT")
        root.makeFile("xyzab")      // "ab" 后紧接下一个名字的 "c"，不能拼接成 "abc"
        root.makeFile("cdef")
        let index = try #require(await FileNameIndex.build(roots: [root.url.path]))
        var query = FileSearchQuery()
        query.term = "abc"
        #expect(index.search(query).results.map(\.name) == ["ABc.TXT"])
        query.term = "*.txt"
        #expect(index.search(query).results.map(\.name) == ["ABc.TXT"])
    }

    @Test func homeFolderMapsToDataVolume() {
        #expect(SpotlightStatus.volumePath(for: FileManager.default.homeDirectoryForCurrentUser.path) == "/System/Volumes/Data")
    }

    @Test func parsesMdutilOutput() {
        #expect(!SpotlightStatus.parseEnabled("/Users/x:\n\tError: unknown indexing state."))
        #expect(!SpotlightStatus.parseEnabled("/:\n\tIndexing disabled."))
        #expect(SpotlightStatus.parseEnabled("/System/Volumes/Data:\n\tIndexing enabled. "))
        #expect(!SpotlightStatus.parseEnabled("/Volumes/X:\n\tIndexing and searching disabled."))
    }

    // MARK: - 自建索引

    @Test func indexFindsHiddenFilesRestoresPathsAndAppliesFilters() async throws {
        let root = TestRoot()
        root.makeFile("a/Report-final.pdf", bytes: 2_000_000)
        root.makeFile("a/b/.hidden-report.txt")
        root.makeFile("a/b/c/old-report.pdf", bytes: 2_000_000, modified: Date(timeIntervalSinceNow: -400 * 86_400))
        root.makeFile("a/node_modules/report.js")
        root.makeFile("a/unrelated.txt")
        root.makeFile("Excluded/report-inside.txt")

        let index = try #require(await FileNameIndex.build(roots: [root.url.path], excludedPaths: [root.url.path + "/Excluded"]))

        var query = FileSearchQuery()
        query.term = "REPORT"
        let all = index.search(query).results
        // node_modules 目录本身会被收录（可按名搜索），但不进入其内部；排除目录同理
        #expect(Set(all.map(\.name)) == ["Report-final.pdf", ".hidden-report.txt", "old-report.pdf"])
        #expect(Set(all.map(\.path)).contains(root.url.path + "/a/b/c/old-report.pdf"))

        query.size = .mb1
        query.date = .year
        #expect(index.search(query).results.map(\.name) == ["Report-final.pdf"])

        var folders = FileSearchQuery()
        folders.term = "node_modules"
        folders.kinds = [.folder]
        #expect(index.search(folders).results.map(\.name) == ["node_modules"])
    }

    @Test func indexWildcardAndLimit() async throws {
        let root = TestRoot()
        for i in 0..<50 { root.makeFile("d\(i % 5)/match-\(i).txt") }
        root.makeFile("d0/match-final.pdf")
        let index = try #require(await FileNameIndex.build(roots: [root.url.path]))

        var query = FileSearchQuery()
        query.term = "match-*.pdf"
        #expect(index.search(query).results.map(\.name) == ["match-final.pdf"])

        query.term = "match"
        let limited = index.search(query, limit: 10)
        #expect(limited.results.count == 10)
        #expect(limited.totalMatches == 51)
    }

    @Test func deletedFilesDropOutOfIndexResults() async throws {
        let root = TestRoot()
        root.makeFile("gone.txt")
        root.makeFile("kept.txt")
        let index = try #require(await FileNameIndex.build(roots: [root.url.path]))
        try FileManager.default.removeItem(at: root.url.appendingPathComponent("gone.txt"))

        var query = FileSearchQuery()
        query.term = ".txt"
        #expect(index.search(query).results.map(\.name) == ["kept.txt"])
    }
}
