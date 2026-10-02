//
//  ChatMediaScanner.swift
//  MacClean
//
//  聊天清理：枚举微信 / QQ / 企业微信保存在本机的聊天媒体文件，按会话、类型、月份汇总大小。
//
//  隐私边界：只看文件的路径、大小和日期，绝不打开或解密聊天数据库，也不读取消息内容。
//  因此拿不到会话名称——微信按「会话目录」（一串不透明的哈希）存放图片，这里就按目录分组；
//  QQ、企业微信只按月份存放，就按月份分组。
//
//  目录结构（2026-10 在真机上核对过微信 4.x、微信 3.x 残留、QQ NT 版；企业微信按公开资料实现）：
//  - 微信 4.x  Documents/xwechat_files/<账号>/msg/attach/<会话>/<YYYY-MM>/{Img,Rec,Ann}
//                                       msg/video/<YYYY-MM>/、msg/file/<YYYY-MM>/、cache/<YYYY-MM>/
//  - 微信 3.x  Library/Application Support/com.tencent.xinWeChat/<版本>/<账号>/Message/MessageTemp/<会话>/{Image,Video,File,Audio,OpenData}
//  - QQ NT    Library/Application Support/QQ/nt_qq_<账号>/nt_data/{Pic,Video,Ptt}/<YYYY-MM>/{Ori,OriTemp,Thumb,ThumbTemp}、File/、Emoji/emoji-recv
//  - 企业微信  Documents/Profiles/<账号>/Caches/{Images,Videos,Files,Emotions,…}
//
//  遍历不跟随符号链接（容器里的 Downloads/Pictures 等是指向用户主目录的链接），
//  只按「桶」（会话 × 类型 × 月份）汇总，不在内存里保存每个文件；清理时再按桶的目标重新展开。
//  全部为 nonisolated（工程默认 MainActor 隔离），由 Task.detached 调用。
//

import Foundation

// MARK: - 应用

nonisolated enum ChatApp: String, CaseIterable, Identifiable, Sendable {
    case wechat, qq, wecom

    var id: String { rawValue }

    var bundleID: String {
        switch self {
        case .wechat: return "com.tencent.xinWeChat"
        case .qq: return "com.tencent.qq"
        case .wecom: return "com.tencent.WeWorkMac"
        }
    }

    var title: String {
        switch self {
        case .wechat: return String(localized: "微信")
        case .qq: return String(localized: "QQ")
        case .wecom: return String(localized: "企业微信")
        }
    }

    /// 微信按会话目录存放图片；QQ、企业微信只按月份存放。
    var groupsByConversation: Bool { self == .wechat }

    func containerData(home: URL) -> String {
        home.path + "/Library/Containers/" + bundleID + "/Data"
    }

    /// 应用正在运行时禁止清理（它可能正在读写这些文件）。
    func isRunning(among runningBundleIDs: Set<String>) -> Bool {
        runningBundleIDs.contains(bundleID)
    }
}

// MARK: - 媒体类型

nonisolated enum ChatMediaType: String, CaseIterable, Identifiable, Sendable, Comparable {
    case image, video, file, voice, sticker, other, cache

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return String(localized: "图片")
        case .video: return String(localized: "视频")
        case .file: return String(localized: "文件")
        case .voice: return String(localized: "语音")
        case .sticker: return String(localized: "表情")
        case .other: return String(localized: "其他附件")
        case .cache: return String(localized: "缓存与缩略图")
        }
    }

    var icon: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .file: return "doc"
        case .voice: return "waveform"
        case .sticker: return "face.smiling"
        case .other: return "paperclip"
        case .cache: return "internaldrive"
        }
    }

    /// 应用会自动重建的缓存与缩略图：唯一默认勾选的类型。
    var isRegenerable: Bool { self == .cache }

    static func < (lhs: ChatMediaType, rhs: ChatMediaType) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

// MARK: - 月份

nonisolated struct ChatMonth: Hashable, Comparable, Sendable {
    let year: Int
    let month: Int

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    /// 解析 "2024-05" 形式的目录名。
    init?(name: String) {
        let parts = name.split(separator: "-")
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]),
              (1990...2100).contains(year), (1...12).contains(month) else { return nil }
        self.init(year: year, month: month)
    }

    init(date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1)
    }

    var id: String { String(format: "%04d-%02d", year, month) }

    func start(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? .distantPast
    }

    /// 下个月第一天（不含），整月都早于某个时间点时用它比较。
    func end(calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .month, value: 1, to: start(calendar: calendar)) ?? .distantPast
    }

    static func < (lhs: ChatMonth, rhs: ChatMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}

// MARK: - 清理目标

nonisolated enum ChatCleanTarget: Hashable, Sendable {
    /// 整个文件夹（或单个文件）移入废纸篓。
    case item(String)
    /// 文件夹里的文件：month 非 nil 时只取修改时间落在该月的（目录不按月份分开存放时使用）；
    /// shallow 只看直接子文件（子目录另有归属时）。
    case files(in: String, month: ChatMonth?, shallow: Bool)
}

// MARK: - 汇总结果

/// 一个「桶」：某个分组（会话或月份）里某种类型、某个月份的全部媒体。
nonisolated struct ChatBucket: Identifiable, Hashable, Sendable {
    let id: String
    let groupID: String
    let type: ChatMediaType
    let month: ChatMonth
    var size: Int64 = 0
    var count: Int = 0
    var oldest: Date?
    var newest: Date?
    var targets: [ChatCleanTarget] = []
}

nonisolated struct ChatLargeFile: Identifiable, Hashable, Sendable {
    let path: String
    let size: Int64
    let type: ChatMediaType
    let modified: Date
    let bucketID: String
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

nonisolated struct ChatGroup: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// 微信的一个会话目录（哈希）。
        case conversation(String)
        /// 不按会话存放的部分（微信 4.x 的视频、收到的文件、缓存）。
        case shared
        /// QQ / 企业微信按月份分组。
        case month(ChatMonth)
    }

    let id: String
    let kind: Kind
    var buckets: [ChatBucket]
    /// 最近的几张可本地预览的图片路径（最多 6 个），用于让用户凭画面认出会话。
    var thumbnails: [String]

    var size: Int64 { buckets.reduce(0) { $0 + $1.size } }
    var count: Int { buckets.reduce(0) { $0 + $1.count } }
    var oldest: Date? { buckets.compactMap(\.oldest).min() }
    var newest: Date? { buckets.compactMap(\.newest).max() }
    var types: [ChatMediaType] { Array(Set(buckets.map(\.type))).sorted() }
    /// 按存放月份算的时间范围（月份目录比文件修改时间更接近收到的时间）。
    var monthRange: ClosedRange<ChatMonth>? {
        guard let first = buckets.map(\.month).min(), let last = buckets.map(\.month).max() else { return nil }
        return first...last
    }

    func size(of type: ChatMediaType) -> Int64 { buckets.filter { $0.type == type }.reduce(0) { $0 + $1.size } }
    func count(of type: ChatMediaType) -> Int { buckets.filter { $0.type == type }.reduce(0) { $0 + $1.count } }
    func buckets(of type: ChatMediaType) -> [ChatBucket] { buckets.filter { $0.type == type }.sorted { $0.month > $1.month } }

    /// 会话目录哈希（月份分组为 nil）。
    var conversationHash: String? {
        if case .conversation(let hash) = kind { return hash }
        return nil
    }
}

nonisolated struct ChatAccount: Identifiable, Hashable, Sendable {
    /// 相对于容器 Data 目录的账号目录（如 Documents/xwechat_files/wxid_xxx），在同一应用内唯一。
    let id: String
    /// 账号目录名（不透明的哈希 / ID）。
    let directoryName: String
    /// 微信 3.x 留下的旧版数据。
    let isLegacy: Bool
    var groups: [ChatGroup]
    var largeFiles: [ChatLargeFile]

    var size: Int64 { groups.reduce(0) { $0 + $1.size } }
    var buckets: [ChatBucket] { groups.flatMap(\.buckets) }

    func size(of type: ChatMediaType) -> Int64 { groups.reduce(0) { $0 + $1.size(of: type) } }

    /// 界面上显示的短 ID：去掉 wxid_ / nt_qq_ 前缀后的前 8 位。
    var shortID: String { ChatMediaScanner.shortHash(directoryName) }
}

nonisolated struct ChatScanResult: Sendable {
    let app: ChatApp
    var accounts: [ChatAccount]
    /// 容器存在但读不了（未授予完全磁盘访问权限 / 「访问其他应用的数据」被拒绝）。
    var unreadable: Bool
    var scannedFiles: Int

    var size: Int64 { accounts.reduce(0) { $0 + $1.size } }
}

// MARK: - 快捷筛选

nonisolated enum ChatQuickFilter: String, CaseIterable, Identifiable, Sendable {
    case oldVideos, oldImages, caches, largeFiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oldVideos: return String(localized: "一年前的视频")
        case .oldImages: return String(localized: "半年前的图片")
        case .caches: return String(localized: "全部缓存与缩略图")
        case .largeFiles: return String(localized: "超过 100 MB 的文件")
        }
    }

    var icon: String {
        switch self {
        case .oldVideos: return "film"
        case .oldImages: return "photo"
        case .caches: return "internaldrive"
        case .largeFiles: return "externaldrive.badge.exclamationmark"
        }
    }

    /// 按桶筛选；largeFiles 按单个文件筛选，见 matchingLargeFiles。
    func matches(_ bucket: ChatBucket, now: Date, calendar: Calendar = .current) -> Bool {
        switch self {
        case .oldVideos:
            guard bucket.type == .video, let cutoff = calendar.date(byAdding: .year, value: -1, to: now) else { return false }
            return bucket.month.end(calendar: calendar) <= cutoff
        case .oldImages:
            guard bucket.type == .image, let cutoff = calendar.date(byAdding: .month, value: -6, to: now) else { return false }
            return bucket.month.end(calendar: calendar) <= cutoff
        case .caches:
            return bucket.type.isRegenerable
        case .largeFiles:
            return false
        }
    }

    func matchingBuckets(in account: ChatAccount, now: Date, calendar: Calendar = .current) -> [ChatBucket] {
        account.buckets.filter { matches($0, now: now, calendar: calendar) }
    }

    func matchingLargeFiles(in account: ChatAccount) -> [ChatLargeFile] {
        self == .largeFiles ? account.largeFiles : []
    }
}

// MARK: - 扫描器

nonisolated enum ChatMediaScanner {

    static let largeFileThreshold: Int64 = 100 * 1024 * 1024
    static let thumbnailLimit = 6
    /// 用来生成缩略图的静态图片格式（视频另有 _thumb.jpg 等封面图，不必再解码视频）；微信 4.x 的 .dat 是加密格式，不在其中（也绝不尝试解码）。
    static let previewableExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "webp", "bmp", "tif", "tiff"]
    /// 聊天数据库及其日志文件：出现在某个目标里就整体放弃该目标，绝不删除。
    static let protectedExtensions: Set<String> = ["db", "sqlite", "sqlite3", "db-wal", "db-shm", "sqlite-wal", "sqlite-shm", "wal", "shm"]

    /// 规划阶段的扫描单元：一个目录及其归属（会话、类型、月份）。
    struct Unit: Sendable, Hashable {
        let conversation: String?
        let type: ChatMediaType
        /// nil 表示目录不按月份存放，按文件修改时间归月。
        let month: ChatMonth?
        let path: String
        /// 只统计直接子文件（目录里同时有子目录被单独规划时）。
        var shallow = false
    }

    struct AccountPlan: Sendable {
        let id: String
        let directoryName: String
        let isLegacy: Bool
        var units: [Unit]
    }

    // MARK: 可用性

    /// 各应用在本机是否有数据（容器目录存在）。
    static func availability(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Set<ChatApp> {
        Set(ChatApp.allCases.filter { isDirectory($0.containerData(home: home)) })
    }

    // MARK: 规划

    /// 列出账号与扫描单元（只列目录，不遍历文件）。unreadable 表示容器存在但读不了。
    static func plan(for app: ChatApp, home: URL) -> (accounts: [AccountPlan], unreadable: Bool) {
        let data = app.containerData(home: home)
        guard isDirectory(data) else { return ([], false) }
        var unreadable = false
        func list(_ path: String) -> [String] {
            do {
                return try FileManager.default.contentsOfDirectory(atPath: path).filter { !$0.hasPrefix(".") }.sorted()
            } catch {
                if isDirectory(path) { unreadable = true }
                return []
            }
        }
        // 容器根目录本身读不了：几乎一定是权限问题
        if (try? FileManager.default.contentsOfDirectory(atPath: data)) == nil { return ([], true) }

        var accounts: [AccountPlan] = []
        switch app {
        case .wechat:
            accounts += planWeChat4(data: data, list: list)
            accounts += planWeChat3(data: data, list: list)
        case .qq:
            accounts += planQQ(data: data, list: list)
        case .wecom:
            accounts += planWeCom(data: data, list: list)
        }
        return (accounts.filter { !$0.units.isEmpty }, unreadable)
    }

    private static func planWeChat4(data: String, list: (String) -> [String]) -> [AccountPlan] {
        let root = data + "/Documents/xwechat_files"
        var plans: [AccountPlan] = []
        for name in list(root) where !["all_users", "Backup"].contains(name) {
            let account = root + "/" + name
            guard isDirectory(account + "/msg") || isDirectory(account + "/cache") else { continue }
            var units: [Unit] = []

            let attach = account + "/msg/attach"
            for chat in list(attach) where isDirectory(attach + "/" + chat) {
                let chatPath = attach + "/" + chat
                for monthName in list(chatPath) {
                    let monthPath = chatPath + "/" + monthName
                    guard isDirectory(monthPath) else { continue }
                    if let month = ChatMonth(name: monthName) {
                        for sub in list(monthPath) {
                            let subPath = monthPath + "/" + sub
                            if isDirectory(subPath) {
                                units.append(Unit(conversation: chat, type: sub == "Img" ? .image : .other, month: month, path: subPath))
                            }
                        }
                        if hasLooseFiles(monthPath, list: list) {
                            units.append(Unit(conversation: chat, type: .other, month: month, path: monthPath, shallow: true))
                        }
                    } else {
                        units.append(Unit(conversation: chat, type: .other, month: nil, path: monthPath))
                    }
                }
            }
            units += monthly(account + "/msg/video", type: .video, conversation: nil, list: list)
            units += monthly(account + "/msg/file", type: .file, conversation: nil, list: list)
            units += monthly(account + "/cache", type: .cache, conversation: nil, list: list)
            plans.append(AccountPlan(id: "Documents/xwechat_files/" + name, directoryName: name, isLegacy: false, units: units))
        }
        return plans
    }

    private static func planWeChat3(data: String, list: (String) -> [String]) -> [AccountPlan] {
        let support = data + "/Library/Application Support/com.tencent.xinWeChat"
        var plans: [AccountPlan] = []
        for version in list(support) where isDirectory(support + "/" + version) {
            for name in list(support + "/" + version) {
                let account = support + "/" + version + "/" + name
                let temp = account + "/Message/MessageTemp"
                guard isDirectory(temp) else { continue }
                var units: [Unit] = []
                for chat in list(temp) where isDirectory(temp + "/" + chat) {
                    let chatPath = temp + "/" + chat
                    for sub in list(chatPath) where isDirectory(chatPath + "/" + sub) {
                        units.append(Unit(conversation: chat, type: legacyType(sub), month: nil, path: chatPath + "/" + sub))
                    }
                    if hasLooseFiles(chatPath, list: list) {
                        units.append(Unit(conversation: chat, type: .other, month: nil, path: chatPath, shallow: true))
                    }
                }
                if isDirectory(account + "/Stickers") {
                    units.append(Unit(conversation: nil, type: .sticker, month: nil, path: account + "/Stickers"))
                }
                plans.append(AccountPlan(
                    id: "Library/Application Support/com.tencent.xinWeChat/\(version)/\(name)",
                    directoryName: name, isLegacy: true, units: units
                ))
            }
        }
        return plans
    }

    private static func legacyType(_ name: String) -> ChatMediaType {
        switch name {
        case "Image": return .image
        case "Video": return .video
        case "File": return .file
        case "Audio": return .voice
        default: return .other
        }
    }

    private static func planQQ(data: String, list: (String) -> [String]) -> [AccountPlan] {
        let root = data + "/Library/Application Support/QQ"
        var plans: [AccountPlan] = []
        for name in list(root) where name.hasPrefix("nt_qq_") {
            let ntData = root + "/" + name + "/nt_data"
            guard isDirectory(ntData) else { continue }
            var units: [Unit] = []
            for (folder, type) in [("Pic", ChatMediaType.image), ("Video", .video), ("Ptt", .voice)] {
                let base = ntData + "/" + folder
                for child in list(base) {
                    let childPath = base + "/" + child
                    guard isDirectory(childPath) else { continue }
                    let month = ChatMonth(name: child)
                    if month == nil {
                        units.append(Unit(conversation: nil, type: qqSubType(child, main: type), month: nil, path: childPath))
                        continue
                    }
                    for sub in list(childPath) where isDirectory(childPath + "/" + sub) {
                        units.append(Unit(conversation: nil, type: qqSubType(sub, main: type), month: month, path: childPath + "/" + sub))
                    }
                    if hasLooseFiles(childPath, list: list) {
                        units.append(Unit(conversation: nil, type: type, month: month, path: childPath, shallow: true))
                    }
                }
            }
            let file = ntData + "/File"
            for child in list(file) {
                let childPath = file + "/" + child
                guard isDirectory(childPath) else { continue }
                units.append(Unit(conversation: nil, type: qqSubType(child, main: .file), month: ChatMonth(name: child), path: childPath))
            }
            if hasLooseFiles(file, list: list) {
                units.append(Unit(conversation: nil, type: .file, month: nil, path: file, shallow: true))
            }
            // 只取收到的表情；BaseEmojiSyastems 等是 QQ 自带的表情资源，不碰。
            if isDirectory(ntData + "/Emoji/emoji-recv") {
                units.append(Unit(conversation: nil, type: .sticker, month: nil, path: ntData + "/Emoji/emoji-recv"))
            }
            plans.append(AccountPlan(id: "Library/Application Support/QQ/" + name, directoryName: name, isLegacy: false, units: units))
        }
        return plans
    }

    /// QQ 的 Ori 是原图/原视频；Thumb、ThumbTemp、OriTemp 是缩略图与下载中的临时文件，会自动重建。
    private static func qqSubType(_ name: String, main: ChatMediaType) -> ChatMediaType {
        let lower = name.lowercased()
        if lower.hasPrefix("thumb") || lower.hasSuffix("temp") { return .cache }
        return main
    }

    private static func planWeCom(data: String, list: (String) -> [String]) -> [AccountPlan] {
        let root = data + "/Documents/Profiles"
        var plans: [AccountPlan] = []
        for name in list(root) {
            let caches = root + "/" + name + "/Caches"
            guard isDirectory(caches) else { continue }
            var units: [Unit] = []
            // 只认已知名称的媒体目录，其余（可能含数据库或配置）一律不碰。
            for child in list(caches) {
                guard let type = weComType(child), isDirectory(caches + "/" + child) else { continue }
                units += monthly(caches + "/" + child, type: type, conversation: nil, list: list)
            }
            plans.append(AccountPlan(id: "Documents/Profiles/" + name, directoryName: name, isLegacy: false, units: units))
        }
        return plans
    }

    static func weComType(_ name: String) -> ChatMediaType? {
        let lower = name.lowercased()
        if lower.contains("thumb") || lower.contains("temp") { return .cache }
        if lower.hasPrefix("image") || lower.hasPrefix("img") || lower.hasPrefix("pic") { return .image }
        if lower.hasPrefix("video") { return .video }
        if lower.hasPrefix("file") { return .file }
        if lower.hasPrefix("voice") || lower.hasPrefix("audio") { return .voice }
        if lower.hasPrefix("emotion") || lower.hasPrefix("emoji") || lower.hasPrefix("sticker") { return .sticker }
        return nil
    }

    /// 按月份子目录拆分；不是月份名的子目录与散落文件按修改时间归月。
    private static func monthly(_ base: String, type: ChatMediaType, conversation: String?, list: (String) -> [String]) -> [Unit] {
        guard isDirectory(base) else { return [] }
        var units: [Unit] = []
        for child in list(base) {
            let childPath = base + "/" + child
            guard isDirectory(childPath) else { continue }
            units.append(Unit(conversation: conversation, type: type, month: ChatMonth(name: child), path: childPath))
        }
        if hasLooseFiles(base, list: list) {
            units.append(Unit(conversation: conversation, type: type, month: nil, path: base, shallow: true))
        }
        return units
    }

    // MARK: 扫描

    /// 遍历一个应用的全部账号。progress(已检查文件数)；取消时抛出 CancellationError。
    static func scan(
        app: ChatApp,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        calendar: Calendar = .current,
        progress: (@Sendable (Int) -> Void)? = nil
    ) throws -> ChatScanResult {
        let (plans, unreadable) = plan(for: app, home: home)
        var scanned = 0
        var accounts: [ChatAccount] = []
        for plan in plans {
            let aggregator = Aggregator(app: app, accountID: plan.id, calendar: calendar)
            for unit in plan.units {
                try aggregator.walk(unit) {
                    scanned += 1
                    if scanned % 500 == 0 {
                        try Task.checkCancellation()
                        progress?(scanned)
                    }
                }
            }
            let account = aggregator.makeAccount(plan: plan)
            if account.size > 0 { accounts.append(account) }
        }
        progress?(scanned)
        return ChatScanResult(app: app, accounts: accounts.sorted { $0.size > $1.size }, unreadable: unreadable, scannedFiles: scanned)
    }

    /// 单个账号的汇总器；只保留每个桶的大小、数量、日期，以及少量缩略图候选与大文件。
    final class Aggregator {
        let app: ChatApp
        let accountID: String
        let calendar: Calendar
        private(set) var buckets: [String: ChatBucket] = [:]
        private var previews: [String: [(path: String, date: Date)]] = [:]
        private(set) var largeFiles: [ChatLargeFile] = []

        init(app: ChatApp, accountID: String, calendar: Calendar) {
            self.app = app
            self.accountID = accountID
            self.calendar = calendar
        }

        func groupID(conversation: String?, month: ChatMonth) -> String {
            if app.groupsByConversation {
                return accountID + "|" + (conversation.map { "c:" + $0 } ?? "shared")
            }
            return accountID + "|m:" + month.id
        }

        func walk(_ unit: Unit, onFile: () throws -> Void) throws {
            // 先在局部汇总，确认目标里没有数据库文件后再并入结果
            var local: [String: ChatBucket] = [:]
            var localPreviews: [String: [(path: String, date: Date)]] = [:]
            var localLarge: [ChatLargeFile] = []
            var hitProtected = false

            try ChatMediaScanner.enumerateFiles(at: unit.path, shallow: unit.shallow) { path, size, modified in
                try onFile()
                let ext = (path as NSString).pathExtension.lowercased()
                if ChatMediaScanner.protectedExtensions.contains(ext) {
                    hitProtected = true
                    return false
                }
                let month = unit.month ?? ChatMonth(date: modified, calendar: calendar)
                let group = groupID(conversation: unit.conversation, month: month)
                let id = group + "|" + unit.type.rawValue + "|" + month.id
                var bucket = local[id] ?? ChatBucket(id: id, groupID: group, type: unit.type, month: month)
                bucket.size += size
                bucket.count += 1
                bucket.oldest = min(bucket.oldest ?? modified, modified)
                bucket.newest = max(bucket.newest ?? modified, modified)
                let target: ChatCleanTarget
                if unit.month == nil {
                    target = .files(in: unit.path, month: month, shallow: unit.shallow)
                } else {
                    target = unit.shallow ? .files(in: unit.path, month: nil, shallow: true) : .item(unit.path)
                }
                if !bucket.targets.contains(target) { bucket.targets.append(target) }
                local[id] = bucket

                if size >= ChatMediaScanner.largeFileThreshold {
                    localLarge.append(ChatLargeFile(path: path, size: size, type: unit.type, modified: modified, bucketID: id))
                }
                if [.image, .video, .cache].contains(unit.type), ChatMediaScanner.previewableExtensions.contains(ext) {
                    ChatMediaScanner.insertPreview((path, modified), into: &localPreviews[group, default: []])
                }
                return true
            }
            guard !hitProtected else { return }

            for (id, part) in local {
                var merged = buckets[id] ?? ChatBucket(id: id, groupID: part.groupID, type: part.type, month: part.month)
                merged.size += part.size
                merged.count += part.count
                merged.oldest = [merged.oldest, part.oldest].compactMap { $0 }.min()
                merged.newest = [merged.newest, part.newest].compactMap { $0 }.max()
                for target in part.targets where !merged.targets.contains(target) { merged.targets.append(target) }
                buckets[id] = merged
            }
            for (group, items) in localPreviews {
                for item in items { ChatMediaScanner.insertPreview(item, into: &previews[group, default: []]) }
            }
            largeFiles += localLarge
        }

        func makeAccount(plan: AccountPlan) -> ChatAccount {
            var grouped: [String: [ChatBucket]] = [:]
            for bucket in buckets.values where bucket.count > 0 { grouped[bucket.groupID, default: []].append(bucket) }
            let groups = grouped.map { id, buckets -> ChatGroup in
                let suffix = String(id.dropFirst(accountID.count + 1))
                let kind: ChatGroup.Kind
                if suffix.hasPrefix("c:") {
                    kind = .conversation(String(suffix.dropFirst(2)))
                } else if suffix.hasPrefix("m:"), let month = ChatMonth(name: String(suffix.dropFirst(2))) {
                    kind = .month(month)
                } else {
                    kind = .shared
                }
                return ChatGroup(
                    id: id, kind: kind,
                    buckets: buckets.sorted { ($0.type, $1.month) < ($1.type, $0.month) },
                    thumbnails: (previews[id] ?? []).map(\.path)
                )
            }
            return ChatAccount(
                id: plan.id, directoryName: plan.directoryName, isLegacy: plan.isLegacy,
                groups: ChatMediaScanner.sortGroups(groups),
                largeFiles: largeFiles.sorted { $0.size > $1.size }
            )
        }
    }

    /// 会话按大小降序；月份分组按时间倒序；「不按会话存放」的部分排在最后。
    static func sortGroups(_ groups: [ChatGroup]) -> [ChatGroup] {
        groups.sorted { lhs, rhs in
            switch (lhs.kind, rhs.kind) {
            case (.month(let a), .month(let b)): return a > b
            case (.shared, _): return false
            case (_, .shared): return true
            default: return lhs.size > rhs.size
            }
        }
    }

    static func insertPreview(_ item: (path: String, date: Date), into list: inout [(path: String, date: Date)]) {
        if list.count >= thumbnailLimit, let last = list.last, last.date >= item.date { return }
        let index = list.firstIndex { $0.date < item.date } ?? list.count
        list.insert(item, at: index)
        if list.count > thumbnailLimit { list.removeLast() }
    }

    // MARK: 清理

    /// 把选中的目标展开成具体路径（文件夹或文件），去掉已被上级目录包含的路径。
    static func expand(_ targets: [ChatCleanTarget], calendar: Calendar = .current) -> [(path: String, size: Int64, modified: Date?)] {
        var result: [String: (size: Int64, modified: Date?)] = [:]
        for target in targets {
            switch target {
            case .item(let path):
                guard FileManager.default.fileExists(atPath: path) else { continue }
                result[path] = (CleanupManager.allocatedSize(atPath: path), nil)
            case .files(let folder, let month, let shallow):
                try? enumerateFiles(at: folder, shallow: shallow) { path, size, modified in
                    if month == nil || ChatMonth(date: modified, calendar: calendar) == month,
                       !protectedExtensions.contains((path as NSString).pathExtension.lowercased()) {
                        result[path] = (size, modified)
                    }
                    return true
                }
            }
        }
        let paths = result.keys.sorted()
        var kept: [(path: String, size: Int64, modified: Date?)] = []
        var lastFolder: String?
        for path in paths {
            if let folder = lastFolder, path.hasPrefix(folder + "/") { continue }
            kept.append((path, result[path]!.size, result[path]!.modified))
            lastFolder = path
        }
        return kept
    }

    static func cleanableItems(for targets: [ChatCleanTarget], calendar: Calendar = .current) -> [CleanableItem] {
        expand(targets, calendar: calendar).map { entry in
            var item = CleanableItem(
                name: (entry.path as NSString).lastPathComponent,
                path: entry.path,
                size: entry.size,
                category: .appData,
                isSelected: true,
                description: nil,
                lastModified: entry.modified
            )
            item.removesContainer = true
            return item
        }
    }

    // MARK: 工具

    static func shortHash(_ name: String) -> String {
        var trimmed = name
        for prefix in ["wxid_", "nt_qq_"] where trimmed.hasPrefix(prefix) { trimmed.removeFirst(prefix.count) }
        return String(trimmed.prefix(8))
    }

    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func hasLooseFiles(_ path: String, list: (String) -> [String]) -> Bool {
        list(path).contains { name in
            var info = stat()
            return lstat(path + "/" + name, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
        }
    }

    /// fts 遍历普通文件（不跟随符号链接）。visit 返回 false 时提前结束。
    static func enumerateFiles(at root: String, shallow: Bool, visit: (String, Int64, Date) throws -> Bool) throws {
        guard let rootCopy = strdup(root) else { return }
        defer { free(rootCopy) }
        var paths: [UnsafeMutablePointer<CChar>?] = [rootCopy, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return }
        defer { fts_close(fts) }
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            if shallow, info == FTS_D, entry.pointee.fts_level > 0 {
                fts_set(fts, entry, FTS_SKIP)
                continue
            }
            guard info == FTS_F, let st = entry.pointee.fts_statp else { continue }
            let path = String(cString: entry.pointee.fts_path)
            let allocated = Int64(st.pointee.st_blocks) * 512
            let size = allocated > 0 ? allocated : Int64(st.pointee.st_size)
            let modified = Date(timeIntervalSince1970: TimeInterval(st.pointee.st_mtimespec.tv_sec))
            if try !visit(path, size, modified) { return }
        }
    }
}
