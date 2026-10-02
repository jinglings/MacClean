//
//  ChatMediaTests.swift
//  MacCleanTests
//
//  聊天清理：在临时目录里搭建微信 4.x / 3.x、QQ NT、企业微信的假目录树，
//  测试发现、按会话 / 类型 / 月份汇总、快捷筛选、默认勾选、运行中拦截、多账号与 PathGuard。
//  设置 MACCLEAN_SNAPSHOT_DIR 时另外渲染有结果的页面截图（只用假数据和合成缩略图）。
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MacClean

struct ChatMediaTests {

    final class FakeHome {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ChatMediaTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        func path(_ components: String) -> String { url.appendingPathComponent(components).path }

        @discardableResult
        func makeFile(_ components: String, bytes: Int = 8192, data: Data? = nil, modified: Date? = nil) -> String {
            let fileURL = url.appendingPathComponent(components)
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (data ?? Data(repeating: 0x42, count: bytes)).write(to: fileURL)
            if let modified {
                try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: fileURL.path)
            }
            return fileURL.path
        }
    }

    static let wechat4 = "Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files"
    static let wechat3 = "Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat"
    static let qq = "Library/Containers/com.tencent.qq/Data/Library/Application Support/QQ"
    static let wecom = "Library/Containers/com.tencent.WeWorkMac/Data/Documents/Profiles"

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int = 15) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    static let chatA = "aaaa1111bbbb2222cccc3333dddd4444"
    static let chatB = "eeee5555ffff6666aaaa7777bbbb8888"

    /// 微信 4.x：两个会话（A 大、B 小）+ 按月份的视频 / 文件 / 缓存，外加不该被统计的数据库与符号链接。
    static func buildWeChat4(_ home: FakeHome, account: String = "wxid_test01_ab12", scale: Int = 1) {
        let root = "\(wechat4)/\(account)"
        home.makeFile("\(root)/msg/attach/\(chatA)/2024-03/Img/a1.dat", bytes: 40_000 * scale)
        home.makeFile("\(root)/msg/attach/\(chatA)/2024-03/Img/a1_t.dat", bytes: 4_000 * scale)
        home.makeFile("\(root)/msg/attach/\(chatA)/2025-08/Img/a2.dat", bytes: 60_000 * scale)
        home.makeFile("\(root)/msg/attach/\(chatA)/2025-08/Rec/r1/Img/1_t_M", bytes: 8_000 * scale)
        home.makeFile("\(root)/msg/attach/\(chatB)/2025-09/Img/b1.dat", bytes: 12_000 * scale)
        home.makeFile("\(root)/msg/video/2024-05/v1.mp4", bytes: 200_000 * scale)
        home.makeFile("\(root)/msg/video/2024-05/v1_thumb.jpg", bytes: 4_000 * scale)
        home.makeFile("\(root)/msg/video/2025-09/v2.mp4", bytes: 100_000 * scale)
        home.makeFile("\(root)/msg/file/2025-01/report.pdf", bytes: 30_000 * scale)
        home.makeFile("\(root)/cache/2025-09/Message/x/ImageTemp/c1", bytes: 16_000 * scale)
        home.makeFile("\(root)/db_storage/message/message_0.db", bytes: 50_000)
        home.makeFile("\(wechat4)/all_users/login/key.dat", bytes: 4_000)
        // 指向容器外的符号链接不能跟随
        home.makeFile("Outside/huge.bin", bytes: 300_000)
        try? FileManager.default.createSymbolicLink(atPath: home.path("\(root)/msg/attach/\(chatB)/2025-09/Img/link"), withDestinationPath: home.path("Outside"))
    }

    static func buildWeChat3(_ home: FakeHome) {
        let root = "\(wechat3)/2.0b4.0.9/0123456789abcdef0123456789abcdef/Message"
        home.makeFile("\(root)/MessageTemp/\(chatA)/Image/1.jpg", bytes: 20_000, modified: date(2023, 2))
        home.makeFile("\(root)/MessageTemp/\(chatA)/Image/2.jpg", bytes: 20_000, modified: date(2023, 4))
        home.makeFile("\(root)/MessageTemp/\(chatA)/Video/1.mp4", bytes: 50_000, modified: date(2023, 4))
        home.makeFile("\(root)/MessageTemp/\(chatA)/File/doc.docx", bytes: 10_000, modified: date(2023, 4))
        home.makeFile("\(root)/MessageTemp/\(chatA)/Audio/1.silk", bytes: 2_000, modified: date(2023, 4))
        home.makeFile("\(root)/msg_0.db", bytes: 40_000)
    }

    static func buildQQ(_ home: FakeHome) {
        let root = "\(qq)/nt_qq_0123456789abcdef/nt_data"
        home.makeFile("\(root)/Pic/2024-05/Ori/p1.jpg", bytes: 30_000)
        home.makeFile("\(root)/Pic/2024-05/Thumb/p1_0.png", bytes: 3_000)
        home.makeFile("\(root)/Pic/2024-05/OriTemp/p2.tmp", bytes: 1_000)
        home.makeFile("\(root)/Pic/2025-09/Ori/p3.png", bytes: 20_000)
        home.makeFile("\(root)/Video/2025-09/Ori/v.mp4", bytes: 90_000)
        home.makeFile("\(root)/Video/2025-09/Thumb/v.png", bytes: 2_000)
        home.makeFile("\(root)/Ptt/2025-09/Ori/a.amr", bytes: 1_000)
        home.makeFile("\(root)/File/file_assistant/f.zip", bytes: 9_000, modified: date(2025, 9))
        home.makeFile("\(root)/File/Thumb/f.jpg", bytes: 1_000, modified: date(2025, 9))
        home.makeFile("\(root)/Emoji/emoji-recv/e.gif", bytes: 4_000, modified: date(2025, 9))
        home.makeFile("\(root)/Emoji/BaseEmojiSyastems/EmojiSystermResource/0/s.png", bytes: 50_000)
        home.makeFile("\(root)/../nt_db/nt_msg.db", bytes: 50_000)
        home.makeFile("\(qq)/versions/6.9.0/QQ.app.zip", bytes: 50_000)
    }

    static func buildWeCom(_ home: FakeHome) {
        let root = "\(wecom)/A1B2C3D4E5F6/Caches"
        home.makeFile("\(root)/Images/2025-06/i.jpg", bytes: 20_000)
        home.makeFile("\(root)/Videos/v.mp4", bytes: 60_000, modified: date(2024, 1))
        home.makeFile("\(root)/Files/2025-06/a.pdf", bytes: 10_000)
        home.makeFile("\(root)/Emotions/e.gif", bytes: 3_000, modified: date(2025, 6))
        home.makeFile("\(root)/Unknown/state.bin", bytes: 3_000)
        home.makeFile("\(root)/Images/2025-07/index.db", bytes: 2_000)
    }

    static func scan(_ app: ChatApp, _ home: FakeHome) throws -> ChatScanResult {
        try ChatMediaScanner.scan(app: app, home: home.url, calendar: calendar)
    }

    // MARK: - 微信 4.x

    @Test func wechat4GroupsByConversationAndMonth() throws {
        let home = FakeHome()
        Self.buildWeChat4(home)
        let result = try Self.scan(.wechat, home)
        #expect(!result.unreadable)
        #expect(result.accounts.count == 1)
        let account = try #require(result.accounts.first)
        #expect(account.directoryName == "wxid_test01_ab12")
        #expect(account.shortID == "test01_a")
        #expect(!account.isLegacy)

        let conversations = account.groups.filter { $0.conversationHash != nil }
        #expect(conversations.map(\.conversationHash) == [Self.chatA, Self.chatB])
        #expect(account.groups.last?.kind == .shared)

        let a = conversations[0]
        #expect(a.types == [.image, .other])
        #expect(a.buckets(of: .image).map(\.month.id) == ["2025-08", "2024-03"])
        #expect(a.count(of: .image) == 3)
        #expect(a.count(of: .other) == 1)
        // 每个桶对应整月文件夹，清理时整个移走
        #expect(a.buckets(of: .image).last?.targets == [.item(home.path("\(Self.wechat4)/wxid_test01_ab12/msg/attach/\(Self.chatA)/2024-03/Img"))])

        let shared = try #require(account.groups.last)
        #expect(shared.types == [.video, .file, .cache])
        #expect(shared.buckets(of: .video).map(\.month.id) == ["2025-09", "2024-05"])
        // 视频缩略图 jpg 可预览；.dat 加密图片不会出现在缩略图里
        #expect(shared.thumbnails.count == 1)
        #expect(a.thumbnails.isEmpty)

        // 符号链接、数据库、all_users 不计入
        let all = account.buckets.flatMap(\.targets)
        #expect(!all.contains { target in
            if case .item(let path) = target { return path.contains("db_storage") || path.contains("all_users") || path.contains("Outside") }
            return false
        })
        #expect(conversations[1].size < 100_000)
    }

    @Test func wechat3LegacySplitsByModificationMonth() throws {
        let home = FakeHome()
        Self.buildWeChat3(home)
        let result = try Self.scan(.wechat, home)
        let account = try #require(result.accounts.first)
        #expect(account.isLegacy)
        #expect(account.directoryName == "0123456789abcdef0123456789abcdef")
        let chat = try #require(account.groups.first)
        #expect(chat.conversationHash == Self.chatA)
        #expect(chat.types == [.image, .video, .file, .voice])
        #expect(chat.buckets(of: .image).map(\.month.id) == ["2023-04", "2023-02"])
        #expect(chat.thumbnails.count == 2)
        // 数据库不在任何目标里
        let items = ChatMediaScanner.cleanableItems(for: account.buckets.flatMap(\.targets), calendar: Self.calendar)
        #expect(items.count == 5)
        #expect(!items.contains { $0.path.hasSuffix(".db") })
    }

    @Test func multipleAccountsIncludingLegacyAreSeparate() throws {
        let home = FakeHome()
        Self.buildWeChat4(home, account: "wxid_small_0001")
        Self.buildWeChat4(home, account: "wxid_big_0002", scale: 3)
        Self.buildWeChat3(home)
        let result = try Self.scan(.wechat, home)
        #expect(result.accounts.map(\.directoryName) == ["wxid_big_0002", "wxid_small_0001", "0123456789abcdef0123456789abcdef"])
        #expect(result.accounts.map(\.isLegacy) == [false, false, true])
        #expect(Set(result.accounts.map(\.id)).count == 3)
    }

    // MARK: - QQ / 企业微信

    @Test func qqGroupsByMonthWithThumbnailsAsCache() throws {
        let home = FakeHome()
        Self.buildQQ(home)
        let result = try Self.scan(.qq, home)
        let account = try #require(result.accounts.first)
        #expect(account.shortID == "01234567")
        #expect(account.groups.map(\.kind) == [.month(ChatMonth(year: 2025, month: 9)), .month(ChatMonth(year: 2024, month: 5))])

        let may = account.groups[1]
        #expect(may.types == [.image, .cache])
        #expect(may.count(of: .cache) == 2)
        let september = account.groups[0]
        #expect(september.types == [.image, .video, .file, .voice, .sticker, .cache])
        // QQ 自带的表情资源、旧版本、数据库都不在结果里
        let paths = ChatMediaScanner.cleanableItems(for: account.buckets.flatMap(\.targets), calendar: Self.calendar).map(\.path)
        #expect(!paths.contains { $0.contains("BaseEmojiSyastems") || $0.contains("versions") || $0.contains("nt_db") })
        #expect(paths.contains { $0.hasSuffix("emoji-recv/e.gif") })
    }

    @Test func wecomSupportsKnownCacheFoldersOnly() throws {
        let home = FakeHome()
        Self.buildWeCom(home)
        let account = try #require(try Self.scan(.wecom, home).accounts.first)
        let types = Set(account.buckets.map(\.type))
        #expect(types == [.image, .video, .file, .sticker])
        // Images/2025-07 里有数据库：整个目标放弃
        #expect(!account.buckets.contains { $0.month.id == "2025-07" })
        #expect(account.groups.contains { $0.kind == .month(ChatMonth(year: 2024, month: 1)) })
        #expect(ChatMediaScanner.weComType("Unknown") == nil)
        #expect(ChatMediaScanner.weComType("ImageThumbs") == .cache)
    }

    @Test func availabilityAndUnreadableContainer() throws {
        let home = FakeHome()
        #expect(ChatMediaScanner.availability(home: home.url).isEmpty)
        Self.buildQQ(home)
        #expect(ChatMediaScanner.availability(home: home.url) == [.qq])

        let data = ChatApp.qq.containerData(home: home.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: data)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: data) }
        let result = try Self.scan(.qq, home)
        #expect(result.unreadable)
        #expect(result.accounts.isEmpty)
    }

    // MARK: - 筛选与默认勾选

    @Test func quickFiltersUseFixedNow() throws {
        let home = FakeHome()
        Self.buildWeChat4(home)
        let account = try #require(try Self.scan(.wechat, home).accounts.first)
        let now = Self.date(2025, 10, 15)

        let oldVideos = ChatQuickFilter.oldVideos.matchingBuckets(in: account, now: now, calendar: Self.calendar)
        #expect(oldVideos.map(\.month.id) == ["2024-05"])
        // 整月都早于一年前才算：2024-10 月底在 2024-10-15 之后，不算
        let edge = ChatBucket(id: "x", groupID: "g", type: .video, month: ChatMonth(year: 2024, month: 10))
        #expect(!ChatQuickFilter.oldVideos.matches(edge, now: now, calendar: Self.calendar))
        let justOld = ChatBucket(id: "y", groupID: "g", type: .video, month: ChatMonth(year: 2024, month: 9))
        #expect(ChatQuickFilter.oldVideos.matches(justOld, now: now, calendar: Self.calendar))

        let oldImages = ChatQuickFilter.oldImages.matchingBuckets(in: account, now: now, calendar: Self.calendar)
        #expect(oldImages.map(\.month.id) == ["2024-03"])
        #expect(ChatQuickFilter.caches.matchingBuckets(in: account, now: now).allSatisfy { $0.type == .cache })
        #expect(ChatQuickFilter.caches.matchingBuckets(in: account, now: now).count == 1)
    }

    @Test func largeFilesAreListedAndFilterable() throws {
        let home = FakeHome()
        Self.buildWeChat4(home)
        home.makeFile("\(Self.wechat4)/wxid_test01_ab12/msg/file/2025-02/big.zip", bytes: 101 * 1024 * 1024)
        let account = try #require(try Self.scan(.wechat, home).accounts.first)
        #expect(account.largeFiles.map(\.name) == ["big.zip"])
        #expect(account.largeFiles.first?.type == .file)
        #expect(ChatQuickFilter.largeFiles.matchingLargeFiles(in: account).count == 1)
    }

    @MainActor
    @Test func defaultSelectionIsCachesOnlyAndNeverFiles() throws {
        let home = FakeHome()
        Self.buildWeChat4(home)
        Self.buildQQ(home)
        for app in [ChatApp.wechat, .qq] {
            let account = try #require(try Self.scan(app, home).accounts.first)
            let selected = ChatCleanupViewModel.defaultSelection(for: account)
            let buckets = account.buckets.filter { selected.contains($0.id) }
            #expect(!buckets.isEmpty)
            #expect(buckets.allSatisfy { $0.type == .cache })
            #expect(!buckets.contains { $0.type == .file })
        }
    }

    @MainActor
    @Test func viewModelSelectionAndQuickFilters() throws {
        let home = FakeHome()
        Self.buildWeChat4(home)
        home.makeFile("\(Self.wechat4)/wxid_test01_ab12/msg/file/2025-02/big.zip", bytes: 101 * 1024 * 1024)
        let vm = ChatCleanupViewModel(home: home.url, labelStore: ChatLabelStore(defaults: Self.defaults()), observeWorkspace: false)
        vm.now = { Self.date(2025, 10, 15) }
        #expect(vm.app == .wechat)
        vm.apply(try Self.scan(.wechat, home))
        let account = try #require(vm.account)
        #expect(vm.selectedSizeByType.keys.sorted() == [.cache])

        let chat = account.groups[0]
        #expect(vm.state(of: chat.buckets) == false)
        vm.toggle(Array(chat.buckets(of: .image).suffix(1)))
        #expect(vm.state(of: chat.buckets) == nil)
        vm.toggle(chat.buckets)
        #expect(vm.state(of: chat.buckets) == true)
        vm.toggle(chat.buckets)
        #expect(vm.state(of: chat.buckets) == false)

        vm.apply(ChatQuickFilter.largeFiles)
        #expect(vm.isActive(.largeFiles))
        #expect(vm.selectedSizeByType[.file] == account.largeFiles[0].size)
        // 整个桶也选中后，大文件不重复计算
        let bigBucket = account.buckets.first { $0.id == account.largeFiles[0].bucketID }!
        vm.toggle([bigBucket])
        #expect(vm.selectedSizeByType[.file] == bigBucket.size)
        vm.apply(ChatQuickFilter.largeFiles)
        #expect(!vm.isActive(.largeFiles))

        vm.apply(ChatQuickFilter.oldVideos)
        #expect(vm.isActive(.oldVideos))
        #expect(vm.selectedTargets.contains(.item(home.path("\(Self.wechat4)/wxid_test01_ab12/msg/video/2024-05"))))
    }

    @MainActor
    @Test func multiAccountPickerResetsSelection() throws {
        let home = FakeHome()
        Self.buildWeChat4(home, account: "wxid_small_0001")
        Self.buildWeChat4(home, account: "wxid_big_0002", scale: 3)
        let vm = ChatCleanupViewModel(home: home.url, labelStore: ChatLabelStore(defaults: Self.defaults()), observeWorkspace: false)
        vm.apply(try Self.scan(.wechat, home))
        #expect(vm.account?.directoryName == "wxid_big_0002")
        vm.toggle(vm.account!.buckets)
        let second = vm.accounts[1]
        vm.selectAccount(second)
        #expect(vm.account?.id == second.id)
        #expect(vm.selectedBuckets == ChatCleanupViewModel.defaultSelection(for: second))
    }

    @MainActor
    @Test func cleaningIsBlockedWhileAppRuns() async throws {
        let home = FakeHome()
        Self.buildWeChat4(home)
        let vm = ChatCleanupViewModel(home: home.url, labelStore: ChatLabelStore(defaults: Self.defaults()), observeWorkspace: false)
        vm.runningApps = { ["com.tencent.xinWeChat"] }
        vm.apply(try Self.scan(.wechat, home))
        vm.refreshRunning()
        #expect(vm.isAppRunning)
        #expect(ChatApp.wechat.isRunning(among: ["com.tencent.xinWeChat"]))
        #expect(!ChatApp.qq.isRunning(among: ["com.tencent.xinWeChat"]))
        // 运行中：直接拒绝，文件原样保留
        let outcome = await vm.cleanSelected()
        #expect(outcome == .blockedByRunningApp)
        #expect(FileManager.default.fileExists(atPath: home.path("\(Self.wechat4)/wxid_test01_ab12/cache/2025-09")))
    }

    @MainActor
    @Test func conversationLabelsPersistLocally() throws {
        let home = FakeHome()
        Self.buildWeChat4(home)
        let defaults = Self.defaults()
        let vm = ChatCleanupViewModel(home: home.url, labelStore: ChatLabelStore(defaults: defaults), observeWorkspace: false)
        vm.apply(try Self.scan(.wechat, home))
        let account = try #require(vm.account)
        let groups = account.groups
        #expect(vm.label(for: groups[0], in: account) == Self.chatLabel(1))
        #expect(vm.label(for: groups[1], in: account) == Self.chatLabel(2))
        vm.rename(groups[1], in: account, to: "  家人群 ")
        #expect(vm.label(for: groups[1], in: account) == "家人群")

        let reloaded = ChatCleanupViewModel(home: home.url, labelStore: ChatLabelStore(defaults: defaults), observeWorkspace: false)
        reloaded.apply(try Self.scan(.wechat, home))
        #expect(reloaded.label(for: groups[1], in: account) == "家人群")
        reloaded.rename(groups[1], in: account, to: nil)
        #expect(reloaded.label(for: groups[1], in: account) == Self.chatLabel(2))
    }

    /// 与应用内一致，从应用包（测试宿主）取本地化文案。
    static func chatLabel(_ index: Int) -> String {
        String(localized: "会话 \(index)", bundle: .main)
    }

    static func defaults() -> UserDefaults {
        let name = "ChatMediaTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - 清理目标

    @Test func expandFiltersByMonthAndDropsNestedPaths() throws {
        let home = FakeHome()
        let folder = home.path("Library/Containers/x/Data/f")
        home.makeFile("Library/Containers/x/Data/f/a.jpg", modified: Self.date(2024, 1))
        home.makeFile("Library/Containers/x/Data/f/b.jpg", modified: Self.date(2024, 2))
        home.makeFile("Library/Containers/x/Data/f/sub/c.jpg", modified: Self.date(2024, 1))
        home.makeFile("Library/Containers/x/Data/f/d.db", modified: Self.date(2024, 1))

        let deep = ChatMediaScanner.expand([.files(in: folder, month: ChatMonth(year: 2024, month: 1), shallow: false)], calendar: Self.calendar)
        #expect(deep.map(\.path) == [folder + "/a.jpg", folder + "/sub/c.jpg"])
        let shallow = ChatMediaScanner.expand([.files(in: folder, month: nil, shallow: true)], calendar: Self.calendar)
        #expect(shallow.map(\.path) == [folder + "/a.jpg", folder + "/b.jpg"])
        let nested = ChatMediaScanner.expand([.item(folder + "/sub"), .item(folder + "/sub/c.jpg"), .item(folder + "/missing")], calendar: Self.calendar)
        #expect(nested.map(\.path) == [folder + "/sub"])
    }

    @Test func everyCleanableItemPassesPathGuard() throws {
        let home = FakeHome()
        Self.buildWeChat4(home)
        Self.buildWeChat4(home, account: "wxid_second_0002")
        Self.buildWeChat3(home)
        Self.buildQQ(home)
        Self.buildWeCom(home)
        var checked = 0
        for app in ChatApp.allCases {
            for account in try Self.scan(app, home).accounts {
                let items = ChatMediaScanner.cleanableItems(for: account.buckets.flatMap(\.targets), calendar: Self.calendar)
                for item in items {
                    #expect(item.category == .appData)
                    #expect(item.removesContainer)
                    #expect(item.path.hasPrefix(home.path("Library/Containers/") ))
                    try PathGuard.validate(path: item.path, category: .appData, removesContainer: true, homeDirectory: home.url)
                    checked += 1
                }
            }
        }
        #expect(checked > 20)
    }

    // MARK: - 截图（只用假数据）

    @MainActor
    @Test func renderResultsSnapshot() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MACCLEAN_SNAPSHOT_DIR"] else { return }
        let outDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let home = FakeHome()
        Self.buildSnapshotTree(home)
        let defaults = Self.defaults()
        let vm = ChatCleanupViewModel(home: home.url, labelStore: ChatLabelStore(defaults: defaults), observeWorkspace: false)
        vm.runningApps = { [] }
        vm.now = { Self.date(2026, 10, 2) }

        for app in [ChatApp.wechat, .qq] {
            vm.app = app
            vm.apply(try ChatMediaScanner.scan(app: app, home: home.url))
        }

        let shots: [(String, ChatApp, Int)] = [("wechat", .wechat, 0), ("wechat-legacy", .wechat, 1), ("qq", .qq, 0)]
        for (name, app, accountIndex) in shots {
            vm.app = app
            if accountIndex < vm.accounts.count { vm.selectAccount(vm.accounts[accountIndex]) }
            guard let account = vm.account else { continue }
            if app == .wechat, accountIndex == 0 {
                vm.rename(account.groups[1], in: account, to: "家人群")
            }
            for group in account.groups { for path in group.thumbnails { _ = await ChatThumbnailCache.shared.load(path) } }
            vm.expanded = [account.groups[0].id, account.groups[0].id + "|" + ChatMediaType.image.rawValue]
            vm.apply(ChatQuickFilter.oldVideos)

            for (mode, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                let view = ChatCleanupView(viewModel: vm)
                    .environment(\.currentAppTab, .chatCleanup)
                    .background(AppBackdrop())
                    .frame(width: 944, height: 900)
                try await Self.snapshot(view, size: CGSize(width: 944, height: 900), appearance: appearance,
                                        to: outDir.appendingPathComponent("\(mode)-chat_cleanup-results-\(name).png"))
                if name == "wechat" {
                    let detail = ChatCleanupView(viewModel: vm, inspectedGroupID: account.groups[0].id)
                        .environment(\.currentAppTab, .chatCleanup)
                        .background(AppBackdrop())
                        .frame(width: 944, height: 900)
                    try await Self.snapshot(detail, size: CGSize(width: 944, height: 900), appearance: appearance,
                                            to: outDir.appendingPathComponent("\(mode)-chat-inspector.png"))
                }
            }
        }
    }

    /// 官网截图：整个窗口（含侧栏），1180×760pt @2x，微信页、默认勾选（只有缓存）、展开两个会话。
    /// 结果来自临时目录里的假数据，只注入共享 ViewModel 的内存状态，不扫描真实数据、不写 UserDefaults。
    @MainActor
    @Test func renderSiteScreenshot() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MACCLEAN_SITE_SHOT_DIR"] else { return }
        let outDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let lang = (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh") ? "zh" : "en"

        let home = FakeHome()
        Self.buildSnapshotTree(home)
        let vm = ChatCleanupViewModel.shared
        vm.runningApps = { [] }
        vm.refreshRunning()
        vm.cancelScan()
        for app in [ChatApp.qq, .wechat] {
            vm.app = app
            vm.apply(try ChatMediaScanner.scan(app: app, home: home.url))
        }
        vm.app = .wechat
        let account = try #require(vm.account)
        #expect(vm.selectedBuckets == ChatCleanupViewModel.defaultSelection(for: account))
        for group in account.groups { for path in group.thumbnails { _ = await ChatThumbnailCache.shared.load(path) } }
        vm.expanded = [account.groups[0].id, account.groups[0].id + "|" + ChatMediaType.image.rawValue, account.groups[1].id]
        vm.scrollTarget = ChatCleanupView.groupsAnchor

        AppState.shared.currentTab = .chatCleanup
        for (mode, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            vm.scrollTarget = ChatCleanupView.groupsAnchor
            let root = ContentView()
                .environmentObject(AppState.shared)
                .frame(width: 1180, height: 760)
            try await Self.snapshot(root, size: CGSize(width: 1180, height: 760), appearance: appearance,
                                    to: outDir.appendingPathComponent("\(mode)-\(lang)-chat_cleanup.png"))
        }
    }

    /// 截图用的假数据：带合成彩色缩略图，使用当前日期附近的月份。
    static func buildSnapshotTree(_ home: FakeHome) {
        let palette: [NSColor] = [.systemTeal, .systemOrange, .systemPink, .systemIndigo, .systemGreen, .systemYellow, .systemPurple, .systemBlue]
        func png(_ index: Int) -> Data {
            let size = 96
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let a = palette[index % palette.count], b = palette[(index + 3) % palette.count]
            NSGradient(starting: a, ending: b)?.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: CGFloat(index * 40))
            NSColor.white.withAlphaComponent(0.5).setFill()
            NSBezierPath(ovalIn: NSRect(x: 20 + index % 3 * 10, y: 24, width: 40, height: 40)).fill()
            NSGraphicsContext.restoreGraphicsState()
            return rep.representation(using: .png, properties: [:])!
        }
        let mb = 1024 * 1024
        // 微信 4.x 账号（图片为 .dat，无缩略图）
        let w4 = "\(wechat4)/wxid_demo_0001"
        let chats = ["3f9a1c2b7d8e4f60a1b2c3d4e5f60718", "8c7b6a5f4e3d2c1b0a99887766554433", "a0b1c2d3e4f5061728394a5b6c7d8e9f", "11223344556677889900aabbccddeeff"]
        for (i, chat) in chats.enumerated() {
            for (m, month) in ["2024-06", "2025-03", "2026-08"].enumerated() {
                home.makeFile("\(w4)/msg/attach/\(chat)/\(month)/Img/\(m).dat", bytes: (12 - i * 3) * mb / (m + 1))
            }
        }
        home.makeFile("\(w4)/msg/video/2024-09/v.mp4", bytes: 9 * mb)
        home.makeFile("\(w4)/msg/video/2026-09/v.mp4", bytes: 4 * mb)
        for i in 0..<4 { home.makeFile("\(w4)/msg/video/2026-09/v\(i)_thumb.jpg", data: png(i)) }
        home.makeFile("\(w4)/msg/file/2025-11/a.pdf", bytes: 6 * mb)
        home.makeFile("\(w4)/cache/2026-09/Message/x/ImageTemp/c", bytes: 3 * mb)
        // 微信 3.x 旧版账号（jpg / png 图片，有缩略图）
        let w3 = "\(wechat3)/2.0b4.0.9/0123456789abcdef0123456789abcdef/Message/MessageTemp"
        for (i, chat) in chats.prefix(3).enumerated() {
            for j in 0..<(7 - i) {
                home.makeFile("\(w3)/\(chat)/Image/\(j).png", data: png(i * 2 + j), modified: date(2023, 1 + j % 12))
            }
            home.makeFile("\(w3)/\(chat)/Video/v.mp4", bytes: (3 - i) * mb, modified: date(2023, 5))
            home.makeFile("\(w3)/\(chat)/File/f.docx", bytes: mb / 2, modified: date(2023, 6))
        }
        // QQ
        let q = "\(qq)/nt_qq_00aa11bb22cc33dd/nt_data"
        for (i, month) in ["2025-12", "2026-08", "2026-09"].enumerated() {
            for j in 0..<4 { home.makeFile("\(q)/Pic/\(month)/Ori/\(j).png", data: png(i + j)) }
            home.makeFile("\(q)/Pic/\(month)/Ori/big\(i).jpg", bytes: (i + 2) * mb)
            home.makeFile("\(q)/Pic/\(month)/Thumb/t.png", bytes: mb / 4)
            home.makeFile("\(q)/Video/\(month)/Ori/v.mp4", bytes: (5 - i) * mb)
        }
    }

    @MainActor
    static func snapshot<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL) async throws {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
        }
        host.wantsLayer = true
        host.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        guard let ctx = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let layer = host.layer else { return }
        ctx.scaleBy(x: scale, y: scale)
        if host.isFlipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        guard let image = ctx.makeImage() else { return }
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
