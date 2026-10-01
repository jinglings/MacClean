//
//  AppManagerTests.swift
//  MacCleanTests
//
//  应用管家：版本比较、Sparkle appcast 解析、关联文件与残留检测的单元测试
//

import Foundation
import Testing
@testable import MacClean

struct AppManagerTests {

    private final class TestHome {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("AppManagerTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        var path: String { url.standardizedFileURL.path }

        @discardableResult
        func makeFile(_ components: String, bytes: Int = 4096, modified: Date? = Date(timeIntervalSinceNow: -60 * 24 * 3600)) -> String {
            let fileURL = url.appendingPathComponent(components)
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(repeating: 0x42, count: bytes).write(to: fileURL)
            if let modified {
                try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: fileURL.path)
                // 目录本身的修改时间也调旧，模拟「很久没动过」
                try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: fileURL.deletingLastPathComponent().path)
            }
            return fileURL.path
        }
    }

    private func index(_ apps: [(String, String)] = [], groups: Set<String> = [], launchServices: Set<String> = []) -> InstalledAppIndex {
        var index = InstalledAppIndex()
        index.ownBundleID = "com.example.macclean"
        index.lookup = { launchServices.contains($0) }
        for (bundleID, name) in apps { index.insert(bundleID: bundleID, name: name) }
        index.groups = groups
        return index
    }

    // MARK: - 版本比较

    @Test func compareVersionsNumerically() {
        #expect(AppUpdateChecker.compareVersions("1.10", "1.9") == .orderedDescending)
        #expect(AppUpdateChecker.compareVersions("1.2", "1.2.0") == .orderedSame)
        #expect(AppUpdateChecker.compareVersions("2.0", "10.0") == .orderedAscending)
        #expect(AppUpdateChecker.compareVersions("v3.1", "3.0.9") == .orderedDescending)
        #expect(AppUpdateChecker.compareVersions("1.2b3", "1.2") == .orderedSame)
        #expect(AppUpdateChecker.compareVersions("500", "499") == .orderedDescending)
    }

    @Test func isNewerPrefersShortVersion() {
        // 构建号与展示版本号混用时，以展示版本号为准，避免误报
        let item = AppcastItem(shortVersion: "2.1", version: "2.1")
        #expect(!AppUpdateChecker.isNewer(item, thanShortVersion: "2.1", build: "4120"))
        #expect(AppUpdateChecker.isNewer(item, thanShortVersion: "2.0.5", build: "4100"))

        let buildOnly = AppcastItem(version: "4200")
        #expect(AppUpdateChecker.isNewer(buildOnly, thanShortVersion: nil, build: "4100"))
        #expect(!AppUpdateChecker.isNewer(buildOnly, thanShortVersion: nil, build: nil))
    }

    // MARK: - appcast 解析

    private let sampleAppcast = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <title>Example</title>
        <item>
          <title>Version 2.0.1</title>
          <sparkle:releaseNotesLink>https://example.com/notes/2.0.1.html</sparkle:releaseNotesLink>
          <sparkle:minimumSystemVersion>11.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/Example-2.0.1.zip" sparkle:version="201" sparkle:shortVersionString="2.0.1" length="1" type="application/octet-stream"/>
          <sparkle:deltas>
            <enclosure url="https://example.com/delta.zip" sparkle:version="999" sparkle:shortVersionString="9.9.9" sparkle:deltaFrom="100"/>
          </sparkle:deltas>
        </item>
        <item>
          <title>Version 2.1 beta</title>
          <sparkle:channel>beta</sparkle:channel>
          <sparkle:version>210</sparkle:version>
          <sparkle:shortVersionString>2.1</sparkle:shortVersionString>
          <enclosure url="https://example.com/Example-2.1.zip"/>
        </item>
        <item>
          <title>Version 1.9</title>
          <sparkle:version>190</sparkle:version>
          <sparkle:shortVersionString>1.9</sparkle:shortVersionString>
          <link>https://example.com/1.9</link>
          <enclosure url="https://example.com/Example-1.9.zip"/>
        </item>
        <item>
          <title>Version 3.0 (needs future macOS)</title>
          <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/Example-3.0.zip" sparkle:version="300" sparkle:shortVersionString="3.0"/>
        </item>
      </channel>
    </rss>
    """

    @Test func parseAppcastReadsAttributesAndElements() {
        let items = AppUpdateChecker.parseAppcast(Data(sampleAppcast.utf8))
        #expect(items.count == 4)
        #expect(items[0].shortVersion == "2.0.1")
        #expect(items[0].version == "201") // 增量包里的 999 不能覆盖
        #expect(items[0].releaseNotesURL?.absoluteString == "https://example.com/notes/2.0.1.html")
        #expect(items[0].downloadURL?.absoluteString == "https://example.com/Example-2.0.1.zip")
        #expect(items[1].channel == "beta")
        #expect(items[2].shortVersion == "1.9")
        #expect(items[2].link?.absoluteString == "https://example.com/1.9")
    }

    @Test func newestItemSkipsBetaAndUnsupportedSystems() {
        let items = AppUpdateChecker.parseAppcast(Data(sampleAppcast.utf8))
        let newest = AppUpdateChecker.newestItem(in: items, systemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        #expect(newest?.shortVersion == "2.0.1")
        #expect(newest?.infoURL?.absoluteString == "https://example.com/notes/2.0.1.html")
    }

    @Test func parseGarbageReturnsNoItems() {
        #expect(AppUpdateChecker.parseAppcast(Data("<html><body>404</body></html>".utf8)).isEmpty)
        #expect(AppUpdateChecker.parseAppcast(Data()).isEmpty)
    }

    // MARK: - 名称规则

    @Test func bundleIDHeuristics() {
        #expect(AppLeftovers.looksLikeBundleID("com.example.App"))
        #expect(AppLeftovers.looksLikeBundleID("org.videolan.vlc"))
        #expect(!AppLeftovers.looksLikeBundleID("com.example"))
        #expect(!AppLeftovers.looksLikeBundleID("Google"))
        #expect(!AppLeftovers.looksLikeBundleID("homebrew.mxcl.postgresql"))
        #expect(!AppLeftovers.looksLikeBundleID("com.example.My App"))

        #expect(AppLeftovers.isProtected("com.apple.Safari"))
        #expect(AppLeftovers.isProtected("group.com.apple.notes"))
        #expect(AppLeftovers.isProtected("is.workflow.my.app"))
        #expect(AppLeftovers.isProtected("com.example.macclean.helper", ownBundleID: "com.example.macclean"))
        #expect(AppLeftovers.isProtected("ai.example.shared"))
        #expect(AppLeftovers.isProtected("org.cups.PrintingPrefs"))
        #expect(AppLeftovers.isProtected("com.crashlytics.data"))
        #expect(!AppLeftovers.isProtected("org.videolan.vlc"))

        #expect(AppLeftovers.groupContainerBundleID("ABCDE12345.com.example.shared") == "com.example.shared")
        #expect(AppLeftovers.groupContainerBundleID("group.com.example.shared") == "com.example.shared")
    }

    @Test func claimRules() {
        var index = index([("com.google.Chrome", "Google Chrome"), ("com.tinyspeck.slackmacgap", "Slack")], launchServices: ["net.elsewhere.Tool"])
        index.toolNames = ["mytool"]
        #expect(index.isClaimed("com.google.Chrome"))
        #expect(index.isClaimed("com.google.Chrome.helper"))       // 前缀
        #expect(index.isClaimed("com.google.Keystone.Agent"))      // 同开发商
        #expect(index.isClaimed("com.slack.desktop.helper"))       // 名称片段
        #expect(index.isClaimed("net.elsewhere.Tool.sub"))         // LaunchServices 登记
        #expect(index.isClaimed("org.example.mytool"))           // 命令行工具
        #expect(!index.isClaimed("org.videolan.vlc"))
    }

    // MARK: - 关联文件

    @Test func associatedFilesByBundleIDAndName() {
        let home = TestHome()
        let bid = "com.example.Widget"
        home.makeFile("Library/Preferences/\(bid).plist")
        home.makeFile("Library/Preferences/ByHost/\(bid).0000-1111.plist")
        home.makeFile("Library/Caches/\(bid)/cache.db")
        home.makeFile("Library/Containers/\(bid)/Data/file")
        home.makeFile("Library/Containers/\(bid).ShareExtension/Data/file")
        home.makeFile("Library/Containers/\(bid).Pro/Data/file")            // 另一个已安装应用
        home.makeFile("Library/Application Support/Widget/data.sqlite")       // 按应用名
        home.makeFile("Library/Application Support/Google/shared")            // 共享目录不能算
        home.makeFile("Library/Group Containers/ABCDE12345.com.example.group/file")
        home.makeFile("Library/Saved Application State/\(bid).savedState/window")

        let index = index([(bid, "Widget"), ("\(bid).Pro", "Widget Pro")])
        let files = AppLeftovers.associatedFiles(
            bundleID: bid, appName: "Widget", appGroups: ["ABCDE12345.com.example.group"], home: home.path, index: index
        )
        let relative = Set(files.map { String($0.path.dropFirst(home.path.count + 1)) })
        #expect(relative == [
            "Library/Preferences/\(bid).plist",
            "Library/Preferences/ByHost/\(bid).0000-1111.plist",
            "Library/Caches/\(bid)",
            "Library/Containers/\(bid)",
            "Library/Containers/\(bid).ShareExtension",
            "Library/Application Support/Widget",
            "Library/Group Containers/ABCDE12345.com.example.group",
            "Library/Saved Application State/\(bid).savedState",
        ])
        #expect(files.allSatisfy { $0.size > 0 })
        // 每个路径都必须能通过卸载时的 PathGuard 校验
        for file in files {
            #expect(throws: Never.self) {
                try PathGuard.validate(path: file.path, category: .appLeftovers, removesContainer: true, homeDirectory: home.url)
            }
        }
    }

    @Test func associatedFilesSkipAppleApps() {
        let home = TestHome()
        home.makeFile("Library/Containers/com.apple.Safari/Data/file")
        let files = AppLeftovers.associatedFiles(bundleID: "com.apple.Safari", appName: "Safari", appGroups: [], home: home.path, index: index())
        #expect(files.isEmpty)
    }

    // MARK: - 孤立残留

    @Test func orphanedFilesAreConservative() {
        let home = TestHome()
        let orphan = home.makeFile("Library/Application Support/org.videolan.vlc/data")
        home.makeFile("Library/Preferences/org.videolan.vlc.plist")
        home.makeFile("Library/Caches/com.installed.App/data")                 // 已安装
        home.makeFile("Library/Caches/com.installed.Other/data")               // 同开发商
        home.makeFile("Library/Caches/com.apple.Safari/data")                  // Apple
        home.makeFile("Library/Application Support/CrashReporter/x")          // 不像 bundle id
        home.makeFile("Library/Application Support/net.recent.Thing/data", modified: Date()) // 最近还在变
        home.makeFile("Library/Group Containers/ABCDE12345.org.gone.App/data")
        home.makeFile("Library/Group Containers/group.com.claimed.shared/data")

        let index = index([("com.installed.App", "Installed")], groups: ["group.com.claimed.shared"])
        let files = AppLeftovers.orphanedFiles(home: home.path, index: index)
        let relative = Set(files.map { String($0.path.dropFirst(home.path.count + 1)) })
        #expect(relative == [
            "Library/Application Support/org.videolan.vlc",
            "Library/Preferences/org.videolan.vlc.plist",
            "Library/Group Containers/ABCDE12345.org.gone.App",
        ])
        #expect(files.allSatisfy { !$0.isSelected })
        #expect(files.first { $0.path.hasSuffix("org.videolan.vlc") }?.owner == "org.videolan.vlc")
        #expect(FileManager.default.fileExists(atPath: orphan))
        for file in files {
            #expect(throws: Never.self) {
                try PathGuard.validate(path: file.path, category: .appLeftovers, removesContainer: true, homeDirectory: home.url)
            }
        }
    }

    @Test func brokenLaunchAgentDetected() throws {
        let home = TestHome()
        let agents = home.url.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let broken: NSDictionary = ["Label": "com.gone.agent", "ProgramArguments": ["/Applications/Gone.app/Contents/MacOS/agent"]]
        let healthy: NSDictionary = ["Label": "com.ok.agent", "Program": "/bin/ls"]
        broken.write(to: agents.appendingPathComponent("com.gone.agent.plist"), atomically: true)
        healthy.write(to: agents.appendingPathComponent("com.ok.agent.plist"), atomically: true)

        let files = AppLeftovers.brokenLaunchAgents(library: home.path + "/Library", index: index())
        #expect(files.map(\.name) == ["com.gone.agent.plist"])
    }

    // MARK: - 结果汇总

    @Test func unusedAppsRequireKnownLastUsedDate() {
        let now = Date()
        func app(_ name: String, lastUsed: Date?, bundleID: String? = nil) -> AppInfo {
            AppInfo(name: name, bundleIdentifier: bundleID ?? "com.test.\(name)", path: "/Applications/\(name).app", version: "1.0",
                    buildVersion: "1", size: 100, lastUsedDate: lastUsed, isFromAppStore: false, feedURL: nil)
        }
        let result = AppScanResult(apps: [
            app("Old", lastUsed: now.addingTimeInterval(-90 * 86400)),
            app("Recent", lastUsed: now.addingTimeInterval(-2 * 86400)),
            app("Never", lastUsed: nil),
            app("Safari", lastUsed: now.addingTimeInterval(-90 * 86400), bundleID: "com.apple.Safari"),
        ], leftoverFiles: [], installers: [], scannedAt: now)
        #expect(result.unusedApps.map(\.name) == ["Old"])
        #expect(result.unknownUsageApps.map(\.name) == ["Never"])
    }

    @Test func installersOnlyMatchInstallerExtensions() {
        let home = TestHome()
        home.makeFile("Downloads/Thing.dmg")
        home.makeFile("Downloads/Tool.pkg")
        home.makeFile("Downloads/photos.zip")
        home.makeFile("Downloads/notes.txt")
        let names = Set(AppManager.scanInstallers(in: home.path + "/Downloads").map(\.name))
        #expect(names == ["Thing.dmg", "Tool.pkg"])
    }
}
