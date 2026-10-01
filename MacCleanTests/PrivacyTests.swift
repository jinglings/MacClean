//
//  PrivacyTests.swift
//  MacCleanTests
//
//  隐私清理路径发现：在临时「假 home」下搭建浏览器目录结构验证。
//

import Foundation
import Testing
@testable import MacClean

struct PrivacyTests {

    private final class FakeHome {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("PrivacyTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit {
            try? FileManager.default.removeItem(at: url)
        }

        func file(_ relative: String, bytes: Int = 10) {
            let fileURL = url.appendingPathComponent(relative)
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: fileURL.path, contents: Data(repeating: 1, count: bytes))
        }

        func dir(_ relative: String) {
            try? FileManager.default.createDirectory(at: url.appendingPathComponent(relative), withIntermediateDirectories: true)
        }

        func path(_ relative: String) -> String {
            url.appendingPathComponent(relative).path
        }
    }

    private func entry(_ entries: [PrivacyEntry], _ browser: PrivacyBrowser, _ kind: PrivacyKind, profile: String? = nil) -> PrivacyEntry? {
        entries.first { $0.browser == browser && $0.kind == kind && $0.profileDirectory == profile }
    }

    // MARK: - Safari

    @Test func safariHistoryIncludesSidecarsAndCookiesBothLocations() {
        let home = FakeHome()
        home.file("Library/Safari/History.db", bytes: 100)
        home.file("Library/Safari/History.db-wal", bytes: 20)
        home.file("Library/Safari/Downloads.plist")
        home.file("Library/Safari/LastSession.plist")
        home.file("Library/Safari/Bookmarks.plist")
        home.file("Library/Cookies/Cookies.binarycookies")
        home.file("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")

        let result = PrivacyScanner.safariEntries(home: home.url)
        #expect(result.hasData)
        #expect(!result.needsFullDiskAccess)

        let history = entry(result.entries, .safari, .history)
        #expect(history?.paths == [home.path("Library/Safari/History.db"), home.path("Library/Safari/History.db-wal")])
        #expect(history?.size == 120)
        #expect(entry(result.entries, .safari, .downloads) != nil)
        #expect(entry(result.entries, .safari, .sessions) != nil)
        #expect(entry(result.entries, .safari, .cookies)?.paths.count == 2)

        // 书签绝不出现在任何条目中
        let allPaths = result.entries.flatMap(\.paths)
        #expect(!allPaths.contains { $0.hasSuffix("Bookmarks.plist") })
    }

    @Test func safariUnreadableDirectoryReportsFullDiskAccess() throws {
        let home = FakeHome()
        home.file("Library/Safari/History.db")
        let safariDir = home.path("Library/Safari")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: safariDir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: safariDir) }

        let result = PrivacyScanner.safariEntries(home: home.url)
        #expect(result.needsFullDiskAccess)
        #expect(entry(result.entries, .safari, .history) == nil)
    }

    @Test func noSafariDirectoryMeansNoData() {
        let home = FakeHome()
        let result = PrivacyScanner.safariEntries(home: home.url)
        #expect(!result.hasData)
        #expect(result.entries.isEmpty)
    }

    // MARK: - Chromium

    @Test func chromiumProfilesAreDefaultAndNumberedOnly() {
        let home = FakeHome()
        let root = "Library/Application Support/Google/Chrome"
        home.dir(root + "/Default")
        home.dir(root + "/Profile 10")
        home.dir(root + "/Profile 2")
        home.dir(root + "/System Profile")
        home.dir(root + "/Crashpad")
        home.file(root + "/Profile 3") // 同名文件不算

        let profiles = PrivacyScanner.chromiumProfiles(root: home.url.appendingPathComponent(root))
        #expect(profiles.map(\.lastPathComponent) == ["Default", "Profile 2", "Profile 10"])
    }

    @Test func chromiumEntriesSkipPasswordsAndBookmarks() {
        let home = FakeHome()
        let root = "Library/Application Support/Microsoft Edge"
        home.file(root + "/Default/History")
        home.file(root + "/Default/History-journal")
        home.file(root + "/Default/Network/Cookies")
        home.file(root + "/Default/Web Data")
        home.file(root + "/Default/Sessions/Session_1")
        home.file(root + "/Default/Login Data")
        home.file(root + "/Default/Bookmarks")
        home.file(root + "/Profile 1/Cookies")
        home.file(root + "/Local State")
        let localState = #"{"profile":{"info_cache":{"Profile 1":{"name":"工作"}}}}"#
        try? Data(localState.utf8).write(to: home.url.appendingPathComponent(root + "/Local State"))

        let result = PrivacyScanner.chromiumEntries(browser: .edge, home: home.url)
        #expect(result.hasData)

        #expect(entry(result.entries, .edge, .history, profile: "Default")?.paths.count == 2)
        #expect(entry(result.entries, .edge, .cookies, profile: "Default")?.paths == [home.path(root + "/Default/Network/Cookies")])
        #expect(entry(result.entries, .edge, .autofill, profile: "Default") != nil)
        #expect(entry(result.entries, .edge, .sessions, profile: "Default")?.paths == [home.path(root + "/Default/Sessions")])
        #expect(entry(result.entries, .edge, .cookies, profile: "Profile 1")?.profileName == "工作")
        #expect(entry(result.entries, .edge, .history, profile: "Profile 1") == nil)

        let allPaths = result.entries.flatMap(\.paths)
        #expect(!allPaths.contains { $0.hasSuffix("Login Data") || $0.hasSuffix("Bookmarks") })
    }

    @Test func missingChromiumBrowserHasNoData() {
        let home = FakeHome()
        #expect(!PrivacyScanner.chromiumEntries(browser: .brave, home: home.url).hasData)
    }

    // MARK: - Firefox

    @Test func firefoxNeverOffersPlacesDatabase() {
        let home = FakeHome()
        let profile = "Library/Application Support/Firefox/Profiles/ab12cd.default-release"
        home.file(profile + "/places.sqlite")
        home.file(profile + "/cookies.sqlite")
        home.file(profile + "/cookies.sqlite-wal")
        home.file(profile + "/formhistory.sqlite")
        home.file(profile + "/sessionstore-backups/recovery.jsonlz4")
        home.file(profile + "/logins.json")

        let result = PrivacyScanner.firefoxEntries(home: home.url)
        #expect(result.hasData)
        #expect(Set(result.entries.map(\.kind)) == [.cookies, .formHistory, .sessions])
        #expect(result.entries.first?.profileName == "default-release")
        #expect(entry(result.entries, .firefox, .cookies, profile: "ab12cd.default-release")?.paths.count == 2)

        let allPaths = result.entries.flatMap(\.paths)
        #expect(!allPaths.contains { $0.contains("places.sqlite") || $0.hasSuffix("logins.json") })
    }

    // MARK: - 最近使用的项目

    @Test func recentItemsSkipFinderFavorites() {
        let home = FakeHome()
        let root = "Library/Application Support/com.apple.sharedfilelist"
        home.file(root + "/com.apple.LSSharedFileList.RecentDocuments.sfl4")
        home.file(root + "/com.apple.LSSharedFileList.RecentApplications.sfl3")
        home.file(root + "/com.apple.LSSharedFileList.FavoriteItems.sfl4")
        home.file(root + "/com.apple.LSSharedFileList.FavoriteVolumes.sfl2")
        home.file(root + "/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.apple.TextEdit.sfl3")
        home.file(root + "/com.apple.LSSharedFileList.ApplicationRecentDocuments/notes.txt")

        let entries = PrivacyScanner.recentItemsEntries(home: home.url)
        #expect(entries.count == 1)
        let names = Set(entries[0].paths.map { ($0 as NSString).lastPathComponent })
        #expect(names == [
            "com.apple.LSSharedFileList.RecentDocuments.sfl4",
            "com.apple.LSSharedFileList.RecentApplications.sfl3",
            "com.apple.TextEdit.sfl3",
        ])
    }

    @Test func sflExtensionMatching() {
        #expect(PrivacyScanner.isSFLFile("a.sfl"))
        #expect(PrivacyScanner.isSFLFile("a.sfl4"))
        #expect(!PrivacyScanner.isSFLFile("a.sflx"))
        #expect(!PrivacyScanner.isSFLFile("a.plist"))
    }

    // MARK: - 与清理管线对接

    @Test func cleanableItemsPassPathGuard() throws {
        let home = FakeHome()
        home.file("Library/Safari/History.db")
        home.file("Library/Application Support/Google/Chrome/Default/Cookies")
        home.file("Library/Application Support/Google/Chrome/Default/Sessions/Tabs_1")
        home.file("Library/Application Support/Firefox/Profiles/x.default/formhistory.sqlite")
        home.file("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentServers.sfl4")

        let result = PrivacyScanner.scan(home: home.url)
        #expect(result.browsersWithData.isSuperset(of: [.safari, .chrome, .firefox, .system]))
        let items = PrivacyScanner.cleanableItems(for: result.entries)
        #expect(items.count == 5)
        for item in items {
            #expect(item.category == .privacyData)
            #expect(item.removesContainer)
            try PathGuard.validate(path: item.path, category: .privacyData, removesContainer: true, homeDirectory: home.url)
        }
    }

    @Test func entryIDsAreStableAcrossScans() {
        let home = FakeHome()
        home.file("Library/Application Support/Google/Chrome/Default/History")
        let first = PrivacyScanner.scan(home: home.url).entries.map(\.id)
        let second = PrivacyScanner.scan(home: home.url).entries.map(\.id)
        #expect(first == second)
        #expect(first == ["chrome|Default|history"])
    }
}
