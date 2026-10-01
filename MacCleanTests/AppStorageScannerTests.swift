//
//  AppStorageScannerTests.swift
//  MacCleanTests
//
//  应用占用：通配符展开、微信/QQ 规则、版本保留、共享组容器、Docker 输出解析、PathGuard 的单元测试
//

import Foundation
import Testing
@testable import MacClean

struct AppStorageScannerTests {

    private final class TestHome {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("AppStorageScannerTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        func path(_ components: String) -> String { url.appendingPathComponent(components).path }

        func makeFile(_ components: String, bytes: Int = 2_000_000) {
            let fileURL = url.appendingPathComponent(components)
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(repeating: 0x42, count: bytes).write(to: fileURL)
        }
    }

    private let wechatData = "Library/Containers/com.tencent.xinWeChat/Data"
    private let qqSupport = "Library/Containers/com.tencent.qq/Data/Library/Application Support/QQ"

    private func app(_ bundleID: String, name: String, home: TestHome, groups: [String] = [], version: String? = nil) -> AppStorageScanner.InstalledApp {
        home.makeFile("Applications/\(name).app/Contents/MacOS/\(name)", bytes: 3_000_000)
        return AppStorageScanner.InstalledApp(bundleID: bundleID, name: name, path: home.path("Applications/\(name).app"), groups: groups, version: version)
    }

    // MARK: - 通配符

    @Test func expandMatchesWildcardComponentsAndSkipsMissing() {
        let home = TestHome()
        home.makeFile("base/xwechat_files/wxid_a/msg/file/a.bin", bytes: 10)
        home.makeFile("base/xwechat_files/wxid_b/msg/file/b.bin", bytes: 10)
        home.makeFile("base/xwechat_files/wxid_c/other/c.bin", bytes: 10)

        let matches = AppStorageScanner.expand(pattern: "xwechat_files/*/msg/file", under: home.path("base"))
        #expect(matches.map { $0.replacingOccurrences(of: home.path("base") + "/", with: "") } == [
            "xwechat_files/wxid_a/msg/file", "xwechat_files/wxid_b/msg/file",
        ])
    }

    @Test func keepsHighestVersionAndInstalledVersion() {
        let paths = ["/q/versions/6.9.91-46928", "/q/versions/7.0.1-52892", "/q/versions/6.9.10-100"]
        #expect(AppStorageScanner.versionsToKeep(paths, installedVersion: nil) == ["/q/versions/7.0.1-52892"])
        #expect(AppStorageScanner.versionsToKeep(paths, installedVersion: "6.9.91") == ["/q/versions/7.0.1-52892", "/q/versions/6.9.91-46928"])
    }

    // MARK: - 微信

    @Test func wechatChatMediaIsListedButNotPreselected() {
        let home = TestHome()
        home.makeFile("\(wechatData)/Documents/xwechat_files/wxid_x/msg/file/doc.pdf")
        home.makeFile("\(wechatData)/Documents/xwechat_files/wxid_x/msg/attach/img.dat")
        home.makeFile("\(wechatData)/Documents/xwechat_files/wxid_x/msg/video/v.mp4")
        home.makeFile("\(wechatData)/Documents/xwechat_files/wxid_x/cache/2026-09/c.bin")
        home.makeFile("\(wechatData)/Documents/xwechat_files/wxid_x/db_storage/message/m.db")
        home.makeFile("\(wechatData)/Library/Caches/profiles/p.bin")

        let wechat = app(AppStorageScanner.wechat, name: "WeChat", home: home)
        let info = AppStorageScanner.analyze(wechat, home: home.url, groupClaims: [:])
        let byTitle = Dictionary(grouping: info.candidates, by: \.title)

        #expect(byTitle[String(localized: "聊天缓存")]?.first?.isSelected == true)
        #expect(byTitle[String(localized: "应用缓存")]?.first?.isSelected == true)
        for title in [String(localized: "聊天中收到的文件"), String(localized: "聊天图片与附件"), String(localized: "聊天视频")] {
            #expect(byTitle[title]?.first?.risk == .userData)
            #expect(byTitle[title]?.first?.isSelected == false)
            #expect(byTitle[title]?.first?.removesContainer == false)
        }
        // 聊天数据库绝不能出现在可清理项里
        #expect(!info.candidates.contains { $0.path.contains("db_storage") })
        // 容器整体计入「用户数据」
        #expect(info.size(of: .data) >= 12_000_000)
    }

    // MARK: - QQ

    @Test func qqOldVersionsAreSafeWhileCurrentVersionIsKept() {
        let home = TestHome()
        home.makeFile("\(qqSupport)/versions/6.9.91-46928/QQUpdate.app/big.bin")
        home.makeFile("\(qqSupport)/versions/7.0.1-52892/QQUpdate.app/big.bin")
        home.makeFile("\(qqSupport)/packages/full/update.bin")
        home.makeFile("\(qqSupport)/nt_qq_abc/nt_data/Pic/p.jpg")

        let qq = app(AppStorageScanner.qq, name: "QQ", home: home, version: "7.0.1")
        let info = AppStorageScanner.analyze(qq, home: home.url, groupClaims: [:])

        let versions = info.candidates.filter { $0.title.hasPrefix(String(localized: "旧版本 QQ")) }
        #expect(versions.count == 1)
        #expect(versions.first?.path.hasSuffix("6.9.91-46928") == true)
        #expect(versions.first?.removesContainer == true)
        #expect(versions.first?.isSelected == true)
        #expect(info.candidates.first { $0.title == String(localized: "更新安装包") }?.isSelected == true)
        #expect(info.candidates.first { $0.title == String(localized: "聊天图片") }?.isSelected == false)
    }

    // MARK: - 容器归属

    @Test func extensionContainersCountAndSharedGroupsDoNot() {
        let home = TestHome()
        home.makeFile("Library/Containers/com.example.chat/Data/a.bin")
        home.makeFile("Library/Containers/com.example.chat.ShareExt/Data/b.bin")
        home.makeFile("Library/Containers/com.example.chatter/Data/unrelated.bin")
        home.makeFile("Library/Group Containers/TEAM.com.example/shared.bin")

        let chat = app("com.example.chat", name: "Chat", home: home, groups: ["TEAM.com.example"])
        let info = AppStorageScanner.analyze(chat, home: home.url, groupClaims: ["TEAM.com.example": 2])

        let labels = info.locations.map(\.label)
        #expect(labels.contains(String(localized: "沙盒容器")))
        #expect(labels.contains(String(localized: "扩展容器 \("ShareExt")")))
        #expect(!info.locations.contains { $0.path.contains("com.example.chatter") })

        let group = info.locations.first { $0.label == String(localized: "组容器") }
        #expect(group?.isShared == true)
        #expect(info.totalSize == info.locations.filter { !$0.isShared }.reduce(0) { $0 + $1.size })
        #expect(info.totalSize < info.locations.reduce(0) { $0 + $1.size })
    }

    // MARK: - 通用规则

    @Test func displayNameSkipsEmptyValues() {
        #expect(AppStorageScanner.displayName(plist: ["CFBundleDisplayName": " ", "CFBundleName": "Foo"], path: "/A/Bar.app") == "Foo")
        #expect(AppStorageScanner.displayName(plist: ["CFBundleDisplayName": ""], path: "/A/Bar.app") == "Bar")
        #expect(AppStorageScanner.displayName(plist: ["CFBundleDisplayName": "微信"], path: "/A/WeChat.app") == "微信")
    }

    @Test func emptyNameNeverResolvesToLibraryRoots() {
        let home = TestHome()
        home.makeFile("Library/Application Support/OtherApp/big.bin")
        home.makeFile("Library/Logs/OtherApp/big.log")
        let nameless = AppStorageScanner.InstalledApp(bundleID: "com.example.nameless", name: "", path: home.path("Applications/X.app"), groups: [])
        home.makeFile("Applications/X.app/Contents/MacOS/X", bytes: 100)

        let info = AppStorageScanner.analyze(nameless, home: home.url, groupClaims: [:])
        #expect(!info.locations.contains { $0.path.hasSuffix("/Application Support/") || $0.path.hasSuffix("/Application Support") })
        #expect(!info.candidates.contains { $0.path.hasSuffix("/Logs/") || $0.path.hasSuffix("/Logs") })
        #expect(info.totalSize < 1_000_000)
    }

    @Test func electronCachesAreSafeButUserFoldersAreNot() {
        let home = TestHome()
        home.makeFile("Library/Application Support/Editor/Cache/Cache_Data/f_1")
        home.makeFile("Library/Application Support/Editor/Code Cache/js/a")
        home.makeFile("Library/Application Support/Editor/User/workspaceStorage/state.vscdb")

        let editor = app("com.example.editor", name: "Editor", home: home)
        let info = AppStorageScanner.analyze(editor, home: home.url, groupClaims: [:])

        #expect(Set(info.candidates.map(\.title)) == [String(localized: "网页缓存"), String(localized: "脚本编译缓存")])
        #expect(info.candidates.allSatisfy { $0.risk == .safe && $0.isSelected && !$0.removesContainer })
        #expect(!info.candidates.contains { $0.path.contains("/User") })
    }

    // MARK: - Docker

    @Test func parsesDockerSystemDF() {
        let output = """
        {"Active":"2","Reclaimable":"1.23GB (45%)","Size":"2.7GB","TotalCount":"5","Type":"Images"}
        {"Active":"1","Reclaimable":"0B (0%)","Size":"12MB","TotalCount":"3","Type":"Containers"}
        {"Active":"1","Reclaimable":"500MB (50%)","Size":"1GB","TotalCount":"2","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"3.4GB","Size":"3.4GB","TotalCount":"40","Type":"Build Cache"}
        """
        let rows = DockerTool.parseSystemDF(Data(output.utf8))
        #expect(rows.map(\.title) == [String(localized: "镜像"), String(localized: "容器"), String(localized: "数据卷"), String(localized: "构建缓存")])
        #expect(rows.first?.totalCount == 5)
        #expect(rows.first?.active == 2)
        #expect(rows.last?.reclaimable == "3.4GB")
    }

    @Test func dockerPruneNeverTouchesVolumes() {
        for level in DockerPruneLevel.allCases {
            #expect(!level.arguments.contains("--volumes"))
            #expect(!level.arguments.contains("volume"))
        }
    }

    // MARK: - PathGuard

    @Test func appDataAllowsAppFoldersButNotLibraryRoots() throws {
        let home = TestHome()
        home.makeFile("\(wechatData)/Library/Caches/x.bin", bytes: 10)
        home.makeFile("Library/Application Support/Some App/data.bin", bytes: 10)
        try PathGuard.validate(path: home.path("\(wechatData)/Library/Caches"), category: .appData, homeDirectory: home.url)
        try PathGuard.validate(path: home.path("Library/Application Support/Some App"), category: .appData, removesContainer: true, homeDirectory: home.url)
        #expect(throws: PathGuardError.self) {
            try PathGuard.validate(path: home.path("Library/Containers"), category: .appData, homeDirectory: home.url)
        }
        #expect(throws: PathGuardError.self) {
            try PathGuard.validate(path: home.path("Documents/chat"), category: .appData, homeDirectory: home.url)
        }
    }
}
