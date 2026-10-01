//
//  AppUpdateChecker.swift
//  MacClean
//
//  通过 Sparkle 更新源（Info.plist 的 SUFeedURL）检查应用是否有新版本。
//  只读取 appcast，不下载、不安装：「更新」= 打开应用让它自己的 Sparkle 更新器接手，或打开发布页。
//  App Store 应用不检查（交给 App Store）。全部为 nonisolated，网络请求并发但有上限，失败的应用直接跳过。
//

import Foundation

// MARK: - 模型

nonisolated struct AppcastItem: Equatable, Sendable {
    var title: String?
    /// sparkle:shortVersionString（展示用版本号）
    var shortVersion: String?
    /// sparkle:version（构建号，对应 CFBundleVersion）
    var version: String?
    var minimumSystemVersion: String?
    var releaseNotesURL: URL?
    var link: URL?
    var downloadURL: URL?
    /// 非默认频道（beta 等）的条目不参与比较。
    var channel: String?

    var displayVersion: String? { shortVersion ?? version }
    /// 打开给用户看的页面：发布说明 > 主页链接 > 下载地址。
    var infoURL: URL? { releaseNotesURL ?? link ?? downloadURL }
}

nonisolated struct UpdateCandidate: Sendable, Hashable {
    let name: String
    let path: String
    let bundleIdentifier: String
    let shortVersion: String?
    let buildVersion: String?
    let feedURL: URL
}

nonisolated struct UpdatableApp: Identifiable, Sendable, Hashable {
    let name: String
    let path: String
    let bundleIdentifier: String
    let currentVersion: String
    let latestVersion: String
    let infoURL: URL?

    var id: String { path }
}

// MARK: - 检查器

enum AppUpdateChecker {

    // MARK: 版本比较

    /// 按点分段做数值比较：每段取开头的数字（"3b2" → 3），缺失的段按 0 处理，
    /// 所以 "1.2" == "1.2.0"、"1.10" > "1.9"。
    nonisolated static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = numericSegments(lhs)
        let right = numericSegments(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    nonisolated static func numericSegments(_ version: String) -> [Int] {
        let trimmed = version.trimmingCharacters(in: .whitespaces)
        let body = trimmed.first == "v" || trimmed.first == "V" ? String(trimmed.dropFirst()) : trimmed
        return body.split(separator: ".").map { segment in
            Int(segment.prefix { $0.isASCII && $0.isNumber }) ?? 0
        }
    }

    /// appcast 条目是否比已安装版本新。两边都有展示版本号时以它为准（避免构建号与版本号混用造成误报），
    /// 否则退回比较构建号；信息不全时一律当作「不需要更新」。
    nonisolated static func isNewer(_ item: AppcastItem, thanShortVersion installedShort: String?, build installedBuild: String?) -> Bool {
        if let itemShort = item.shortVersion, let installedShort, !numericSegments(itemShort).isEmpty, !numericSegments(installedShort).isEmpty {
            return compareVersions(itemShort, installedShort) == .orderedDescending
        }
        if let itemBuild = item.version, let installedBuild {
            return compareVersions(itemBuild, installedBuild) == .orderedDescending
        }
        return false
    }

    // MARK: appcast 解析

    nonisolated static func parseAppcast(_ data: Data) -> [AppcastItem] {
        let delegate = AppcastParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    /// 默认频道、且当前系统满足最低版本要求的条目中版本最高的一个。
    nonisolated static func newestItem(
        in items: [AppcastItem],
        systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> AppcastItem? {
        let system = "\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)"
        let eligible = items.filter { item in
            guard item.channel == nil, item.displayVersion != nil else { return false }
            if let minimum = item.minimumSystemVersion, compareVersions(system, minimum) == .orderedAscending { return false }
            return true
        }
        return eligible.max { a, b in
            let byShort = compareVersions(a.shortVersion ?? a.version ?? "", b.shortVersion ?? b.version ?? "")
            if byShort != .orderedSame { return byShort == .orderedAscending }
            return compareVersions(a.version ?? "", b.version ?? "") == .orderedAscending
        }
    }

    // MARK: 网络检查

    nonisolated static func candidate(for app: AppInfo) -> UpdateCandidate? {
        guard !app.isFromAppStore, let feed = app.feedURL, let url = URL(string: feed),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return UpdateCandidate(
            name: app.name, path: app.path, bundleIdentifier: app.bundleIdentifier,
            shortVersion: app.version == String(localized: "未知") ? nil : app.version, buildVersion: app.buildVersion, feedURL: url
        )
    }

    /// 并发（最多 maxConcurrent 个）拉取各应用的 appcast，返回有新版本的应用。
    nonisolated static func check(
        _ candidates: [UpdateCandidate],
        maxConcurrent: Int = 6,
        timeout: TimeInterval = 10,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [UpdatableApp] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var found: [UpdatableApp] = []
        await withTaskGroup(of: UpdatableApp?.self) { group in
            var iterator = candidates.makeIterator()
            var running = 0
            var done = 0
            while running < maxConcurrent, let next = iterator.next() {
                group.addTask { await checkOne(next, session: session) }
                running += 1
            }
            while let result = await group.next() {
                done += 1
                progress?(done, candidates.count)
                if let result { found.append(result) }
                if Task.isCancelled { group.cancelAll(); break }
                if let next = iterator.next() {
                    group.addTask { await checkOne(next, session: session) }
                }
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated static func checkOne(_ candidate: UpdateCandidate, session: URLSession) async -> UpdatableApp? {
        var request = URLRequest(url: candidate.feedURL)
        request.setValue("MacClean/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") Sparkle", forHTTPHeaderField: "User-Agent")
        guard let fetched = try? await session.data(for: request),
              (fetched.1 as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let newest = newestItem(in: parseAppcast(fetched.0)),
              isNewer(newest, thanShortVersion: candidate.shortVersion, build: candidate.buildVersion),
              let latest = newest.displayVersion else {
            return nil
        }
        return UpdatableApp(
            name: candidate.name,
            path: candidate.path,
            bundleIdentifier: candidate.bundleIdentifier,
            currentVersion: candidate.shortVersion ?? candidate.buildVersion ?? String(localized: "未知"),
            latestVersion: latest,
            infoURL: newest.infoURL
        )
    }
}

// MARK: - XML 解析

/// Sparkle appcast 解析：版本号既可能写在 <enclosure> 属性上，也可能是 <item> 的子元素；
/// <sparkle:deltas> 里的增量包 enclosure 忽略。
nonisolated private final class AppcastParserDelegate: NSObject, XMLParserDelegate {
    private(set) var items: [AppcastItem] = []
    private var current: AppcastItem?
    private var text = ""
    private var deltaDepth = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "item":
            current = AppcastItem()
        case "sparkle:deltas":
            deltaDepth += 1
        case "enclosure" where current != nil && deltaDepth == 0:
            if let value = attributes["sparkle:shortVersionString"], current?.shortVersion == nil { current?.shortVersion = value }
            if let value = attributes["sparkle:version"], current?.version == nil { current?.version = value }
            if let value = attributes["url"], let url = URL(string: value) { current?.downloadURL = url }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        guard current != nil else { return }
        switch elementName {
        case "item":
            if let item = current { items.append(item) }
            current = nil
        case "sparkle:deltas":
            deltaDepth = max(0, deltaDepth - 1)
        case "title" where deltaDepth == 0:
            current?.title = value
        case "sparkle:shortVersionString" where !value.isEmpty:
            current?.shortVersion = value
        case "sparkle:version" where !value.isEmpty:
            current?.version = value
        case "sparkle:minimumSystemVersion" where !value.isEmpty:
            current?.minimumSystemVersion = value
        case "sparkle:channel" where !value.isEmpty:
            current?.channel = value
        case "sparkle:releaseNotesLink" where !value.isEmpty:
            current?.releaseNotesURL = URL(string: value)
        case "link" where !value.isEmpty:
            current?.link = URL(string: value)
        default:
            break
        }
    }
}
