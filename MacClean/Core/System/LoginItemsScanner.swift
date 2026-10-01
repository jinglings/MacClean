//
//  LoginItemsScanner.swift
//  MacClean
//
//  启动项：枚举 LaunchAgents / LaunchDaemons plist 与系统「登录项与扩展」数据库（BTM），
//  并通过 launchctl 启用 / 停用当前用户的启动代理。
//
//  `sfltool dumpbtm` 在新系统上需要管理员授权（不带 sudo 会一直等待），所以不用它；
//  改为直接读取全局可读的 /private/var/db/com.apple.backgroundtaskmanagement/BackgroundItems-v*.btm。
//  该文件是 NSKeyedArchiver 归档，格式未公开，读不到或解不开时静默跳过，只显示 plist。
//
//  解析逻辑都是 nonisolated 纯函数，便于单元测试，也保证在后台线程执行。
//

import Foundation
import AppKit

// MARK: - 模型

nonisolated struct LaunchItem: Identifiable, Hashable, Sendable {
    enum Kind: Int, Sendable {
        /// ~/Library/LaunchAgents：可停用、可移除
        case userAgent
        /// /Library/LaunchAgents：只读
        case globalAgent
        /// /Library/LaunchDaemons：只读
        case globalDaemon
        /// 「登录时打开」的应用（系统设置 → 登录项）
        case loginApp
        /// 应用内嵌的登录项 / 后台服务（SMAppService 注册）
        case appService
    }

    /// plist 路径；BTM 条目用 "btm:" + 标识
    let id: String
    let kind: Kind
    let label: String
    let plistPath: String?
    /// 可执行文件路径（已展开 ~）；相对路径或缺失时为 nil
    let executablePath: String?
    let runAtLoad: Bool
    let keepAlive: Bool
    /// 指向的程序已不存在
    let isBroken: Bool
    /// 被 launchctl disable / plist Disabled 停用；BTM 条目表示系统设置里已关闭
    let isDisabled: Bool
    /// 在「系统设置 → 登录项与扩展」里被关闭了后台运行（BTM disposition 未 allowed）
    let isBlockedInSettings: Bool
    let isRunning: Bool
    /// 所属应用（.app 路径）
    let appPath: String?
    let appName: String?
    let developer: String?

    var isEditable: Bool { kind == .userAgent }
    var displayName: String { appName ?? label }
    /// 行内展示的路径：优先 plist，其次可执行文件 / 应用
    var detailPath: String? { plistPath ?? executablePath ?? appPath }
    /// 「在访达中显示」的目标
    var revealPath: String? {
        let fileManager = FileManager.default
        return [plistPath, executablePath, appPath].compactMap { $0 }.first { fileManager.fileExists(atPath: $0) }
    }
}

/// plist 中与启动相关的字段
nonisolated struct LaunchPlistInfo: Equatable, Sendable {
    var label: String
    var program: String?
    var runAtLoad: Bool
    var keepAlive: Bool
    var disabledKey: Bool
    var associatedBundleIDs: [String]
}

/// BTM 数据库中的一条记录
nonisolated struct BTMRecord: Equatable, Sendable {
    var type: Int
    var disposition: Int
    var identifier: String?
    var name: String?
    var url: URL?
    var bundleIdentifier: String?
    var executablePath: String?
    var developerName: String?
    var container: String?

    // sfltool dumpbtm 打印的类型 / 状态位
    static let typeApp = 0x2
    static let typeLoginItem = 0x4
    static let typeAgent = 0x8
    static let typeDaemon = 0x10
    static let typeLegacy = 0x10000

    static let dispositionEnabled = 0x1
    static let dispositionAllowed = 0x2

    var isEnabled: Bool { disposition & Self.dispositionEnabled != 0 }
    var isAllowed: Bool { disposition & Self.dispositionAllowed != 0 }
    var isLegacyPlist: Bool { type & Self.typeLegacy != 0 }
    /// 「登录时打开」的应用：app 记录且 enabled 位置位
    var isOpenAtLoginApp: Bool { type & Self.typeApp != 0 && isEnabled }
    /// 应用通过 SMAppService 注册的登录项 / 代理 / 守护进程
    var isAppService: Bool {
        !isLegacyPlist && type & (Self.typeLoginItem | Self.typeAgent | Self.typeDaemon) != 0
    }
}

// MARK: - 纯解析函数

enum LoginItemsParser {

    /// 解析 launchd plist；缺少 Label 视为无效。
    nonisolated static func parseLaunchPlist(_ data: Data) -> LaunchPlistInfo? {
        guard let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let label = dict["Label"] as? String, !label.isEmpty else { return nil }
        let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
        // KeepAlive 可以是布尔，也可以是条件字典（存在即表示按条件常驻）
        let keepAlive: Bool
        switch dict["KeepAlive"] {
        case let flag as Bool: keepAlive = flag
        case let conditions as [String: Any]: keepAlive = !conditions.isEmpty
        default: keepAlive = false
        }
        return LaunchPlistInfo(
            label: label,
            program: program.flatMap { $0.isEmpty ? nil : $0 },
            runAtLoad: dict["RunAtLoad"] as? Bool ?? false,
            keepAlive: keepAlive,
            disabledKey: dict["Disabled"] as? Bool ?? false,
            associatedBundleIDs: dict["AssociatedBundleIdentifiers"] as? [String]
                ?? (dict["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
        )
    }

    /// 展开 ~ 后的绝对路径；依赖 PATH 查找的相对命令（如 "node"）返回 nil，无法判断是否失效。
    nonisolated static func absoluteExecutable(_ program: String?, home: String) -> String? {
        guard let program, !program.isEmpty else { return nil }
        let expanded = program.hasPrefix("~") ? home + program.dropFirst() : program
        return expanded.hasPrefix("/") ? expanded : nil
    }

    /// 程序路径是绝对路径且文件不存在才判为失效；无法判断的一律保守视为正常。
    nonisolated static func isBroken(executable: String?, fileExists: (String) -> Bool) -> Bool {
        guard let executable else { return false }
        return !fileExists(executable)
    }

    /// `launchctl print-disabled <domain>` → [label: 是否停用]。
    /// 新系统输出 `"label" => disabled/enabled`，旧系统为 `=> true/false`。
    nonisolated static func parsePrintDisabled(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard key.count >= 2, key.hasPrefix("\""), key.hasSuffix("\"") else { continue }
            let label = String(key.dropFirst().dropLast())
            switch parts[1].trimmingCharacters(in: .whitespaces).lowercased() {
            case "disabled", "true": result[label] = true
            case "enabled", "false": result[label] = false
            default: continue
            }
        }
        return result
    }

    /// `launchctl list` → 正在运行（有 PID）的 label 集合。
    nonisolated static func parseRunningLabels(_ output: String) -> Set<String> {
        var result: Set<String> = []
        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t", maxSplits: 2)
            guard columns.count == 3, Int(columns[0]) != nil else { continue }
            result.insert(String(columns[2]))
        }
        return result
    }

    /// 可执行文件所在的最外层 .app 包（嵌套的 Helper.app 归到宿主应用）。
    nonisolated static func owningAppPath(forExecutable path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            if component.lowercased().hasSuffix(".app") { return current }
        }
        return nil
    }

    /// 从 label 推测所属应用的 bundle id：com.macpaw.CleanMyMac5.Updater → [自身, com.macpaw.CleanMyMac5]，
    /// 至少保留 3 段，避免 com.google 这种过于宽泛的前缀误配。
    nonisolated static func bundleIDCandidates(forLabel label: String) -> [String] {
        let parts = label.split(separator: ".")
        guard parts.count >= 3 else { return [] }
        return (3...parts.count).reversed().map { parts.prefix($0).joined(separator: ".") }
    }

    /// 应用显示名（去掉 .app）
    nonisolated static func appDisplayName(_ appPath: String) -> String {
        let name = FileManager.default.displayName(atPath: appPath)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// 从 BTM 归档中取出指定用户的记录；`userKey` 为用户 GeneratedUID。
    nonisolated static func parseBTM(_ data: Data, userKey: String) -> [BTMRecord] {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return [] }
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(BTMArchivedStorage.self, forClassName: "Storage")
        unarchiver.setClass(BTMArchivedItem.self, forClassName: "ItemRecord")
        defer { unarchiver.finishDecoding() }
        guard let storage = unarchiver.decodeObject(forKey: "store") as? BTMArchivedStorage else { return [] }
        let items = storage.itemsByUser[userKey] ?? storage.itemsByUser[userKey.uppercased()] ?? []
        return items.map(\.record)
    }

    /// `dscl . -read /Users/<name> GeneratedUID` → "04B41EC7-…"
    nonisolated static func parseGeneratedUID(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("GeneratedUID:") }) else { return nil }
        let value = line.dropFirst("GeneratedUID:".count).trimmingCharacters(in: .whitespaces)
        return UUID(uuidString: value)?.uuidString
    }

    /// 同目录里版本号最高的 BackgroundItems-vN.btm
    nonisolated static func latestBTMFile(in names: [String]) -> String? {
        names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("BackgroundItems-v"), name.hasSuffix(".btm"),
                  let version = Int(name.dropFirst("BackgroundItems-v".count).dropLast(4)) else { return nil }
            return (version, name)
        }
        .max { $0.0 < $1.0 }?.1
    }

    /// BTM 记录的 url 可能是相对父应用的（Contents/Library/LoginItems/X.app），借 container 指向的父记录拼成绝对路径。
    nonisolated static func resolvedPath(of record: BTMRecord, in records: [BTMRecord]) -> String? {
        guard let url = record.url else { return nil }
        // 相对 URL 解档后会挂上 file:/// 作 base，看 relativeString 才能分辨
        let relative = url.relativeString
        if relative.hasPrefix("file://") || relative.hasPrefix("/") { return url.standardizedFileURL.path }
        guard let container = record.container,
              let parent = records.first(where: { $0.identifier == container }),
              let parentURL = parent.url, parentURL.isFileURL else { return nil }
        return parentURL.appendingPathComponent(relative.removingPercentEncoding ?? relative).standardizedFileURL.path
    }
}

// MARK: - BTM 归档类（仅解码需要的字段，其余键不会被触发解码）

nonisolated final class BTMArchivedStorage: NSObject, NSCoding {
    let itemsByUser: [String: [BTMArchivedItem]]

    init?(coder: NSCoder) {
        var result: [String: [BTMArchivedItem]] = [:]
        if let dict = coder.decodeObject(forKey: "itemsByUserIdentifier") as? NSDictionary {
            for (key, value) in dict {
                guard let key = key as? String else { continue }
                result[key] = (value as? [Any])?.compactMap { $0 as? BTMArchivedItem } ?? []
            }
        }
        itemsByUser = result
    }

    func encode(with coder: NSCoder) {}
}

nonisolated final class BTMArchivedItem: NSObject, NSCoding {
    let record: BTMRecord

    init?(coder: NSCoder) {
        func string(_ key: String) -> String? { coder.decodeObject(forKey: key) as? String }
        record = BTMRecord(
            type: coder.decodeInteger(forKey: "type"),
            disposition: coder.decodeInteger(forKey: "disposition"),
            identifier: string("identifier"),
            name: string("name"),
            url: coder.decodeObject(forKey: "url") as? URL,
            bundleIdentifier: string("bundleIdentifier"),
            executablePath: string("executablePath"),
            developerName: string("developerName"),
            container: string("container")
        )
    }

    func encode(with coder: NSCoder) {}
}

// MARK: - 扫描

enum LoginItemsScanner {

    nonisolated static let btmDirectory = "/private/var/db/com.apple.backgroundtaskmanagement"

    nonisolated static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [LaunchItem] {
        let fileManager = FileManager.default
        let uid = getuid()
        let disabledMap = LoginItemsParser.parsePrintDisabled(LaunchCtl.run(["print-disabled", "gui/\(uid)"]).output)
        let systemDisabled = LoginItemsParser.parsePrintDisabled(LaunchCtl.run(["print-disabled", "system"]).output)
        let running = LoginItemsParser.parseRunningLabels(LaunchCtl.run(["list"]).output)
        let btm = currentUserBTMRecords()
        let btmByPlist = Dictionary(
            btm.filter(\.isLegacyPlist).compactMap { record in record.url.map { ($0.standardizedFileURL.path, record) } },
            uniquingKeysWith: { first, _ in first }
        )

        var bundleCache: [String: String?] = [:]
        func appPath(forBundleID id: String) -> String? {
            if let cached = bundleCache[id] { return cached }
            let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path
            bundleCache[id] = path
            return path
        }

        var items: [LaunchItem] = []
        let directories: [(String, LaunchItem.Kind)] = [
            (home.appendingPathComponent("Library/LaunchAgents").path, .userAgent),
            ("/Library/LaunchAgents", .globalAgent),
            ("/Library/LaunchDaemons", .globalDaemon),
        ]

        for (directory, kind) in directories {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for name in names.sorted() where name.hasSuffix(".plist") {
                let plistPath = directory + "/" + name
                guard let data = fileManager.contents(atPath: plistPath),
                      let info = LoginItemsParser.parseLaunchPlist(data) else { continue }

                let executable = LoginItemsParser.absoluteExecutable(info.program, home: home.path)
                let broken = LoginItemsParser.isBroken(executable: executable) { fileManager.fileExists(atPath: $0) }
                let btmRecord = btmByPlist[plistPath]

                var owner = LoginItemsParser.owningAppPath(forExecutable: executable).flatMap { fileManager.fileExists(atPath: $0) ? $0 : nil }
                if owner == nil {
                    let candidates = info.associatedBundleIDs + LoginItemsParser.bundleIDCandidates(forLabel: info.label)
                    owner = candidates.lazy.compactMap { appPath(forBundleID: $0) }.first
                }

                let overrides = kind == .globalDaemon ? systemDisabled : disabledMap
                items.append(LaunchItem(
                    id: plistPath,
                    kind: kind,
                    label: info.label,
                    plistPath: plistPath,
                    executablePath: executable ?? info.program,
                    runAtLoad: info.runAtLoad,
                    keepAlive: info.keepAlive,
                    isBroken: broken,
                    isDisabled: overrides[info.label] ?? info.disabledKey,
                    isBlockedInSettings: btmRecord.map { !$0.isAllowed } ?? false,
                    isRunning: running.contains(info.label),
                    appPath: owner,
                    appName: owner.map(LoginItemsParser.appDisplayName),
                    developer: btmRecord?.developerName
                ))
            }
        }

        items.append(contentsOf: btmItems(btm))
        return items
    }

    /// 「登录时打开的应用」与应用内嵌的后台服务（只读）
    nonisolated static func btmItems(_ records: [BTMRecord]) -> [LaunchItem] {
        let fileManager = FileManager.default
        var seen: Set<String> = []
        var items: [LaunchItem] = []
        for record in records where record.isOpenAtLoginApp || record.isAppService {
            guard let path = LoginItemsParser.resolvedPath(of: record, in: records),
                  fileManager.fileExists(atPath: path) else { continue }
            let id = "btm:" + (record.identifier ?? path)
            guard seen.insert(id).inserted else { continue }

            let isApp = record.isOpenAtLoginApp && !record.isAppService
            let owner = LoginItemsParser.owningAppPath(forExecutable: path)
            items.append(LaunchItem(
                id: id,
                kind: isApp ? .loginApp : .appService,
                label: record.bundleIdentifier ?? record.name ?? (path as NSString).lastPathComponent,
                plistPath: nil,
                executablePath: path,
                runAtLoad: true,
                keepAlive: false,
                isBroken: false,
                isDisabled: !(record.isEnabled && record.isAllowed),
                isBlockedInSettings: !record.isAllowed,
                isRunning: false,
                appPath: owner,
                appName: owner.map(LoginItemsParser.appDisplayName) ?? record.name,
                developer: record.developerName
            ))
        }
        return items
    }

    nonisolated static func currentUserBTMRecords() -> [BTMRecord] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: btmDirectory),
              let file = LoginItemsParser.latestBTMFile(in: names),
              let data = FileManager.default.contents(atPath: btmDirectory + "/" + file),
              let userKey = currentUserUUID() else { return [] }
        return LoginItemsParser.parseBTM(data, userKey: userKey)
    }

    /// 用户的 GeneratedUID，BTM 数据库按它分组
    nonisolated static func currentUserUUID() -> String? {
        // membership.h 的 mbr_uid_to_uuid 未导出到 Swift，改用 dscl 查询
        let result = LaunchCtl.run(
            [".", "-read", "/Users/\(NSUserName())", "GeneratedUID"],
            executable: "/usr/bin/dscl"
        )
        return LoginItemsParser.parseGeneratedUID(result.output)
    }
}

// MARK: - launchctl

enum LaunchCtl {

    nonisolated struct Result: Sendable {
        var status: Int32
        var output: String
        var error: String
        var succeeded: Bool { status == 0 }
    }

    /// 同步运行 launchctl，超时 10 秒强制结束。只在后台线程调用。
    nonisolated static func run(_ arguments: [String], executable: String = "/bin/launchctl", timeout: TimeInterval = 10) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "", error: error.localizedDescription)
        }
        let deadline = DispatchTime.now() + timeout
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: watchdog)
        // 先读完管道再 wait，避免输出塞满管道缓冲导致互相等待
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return Result(
            status: process.terminationStatus,
            output: String(decoding: out, as: UTF8.self),
            error: String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// 停用当前用户的启动代理：先卸载（未加载时的报错忽略），再写入 disabled 覆盖。
    nonisolated static func disableUserAgent(label: String, plistPath: String) -> String? {
        let domain = "gui/\(getuid())"
        _ = run(["bootout", domain, plistPath])
        let result = run(["disable", "\(domain)/\(label)"])
        return result.succeeded ? nil : String(localized: "停用失败：\(detail(of: result))")
    }

    /// 启用：清除 disabled 覆盖并加载；已加载导致的 bootstrap 报错不算失败。
    nonisolated static func enableUserAgent(label: String, plistPath: String) -> String? {
        let domain = "gui/\(getuid())"
        let enable = run(["enable", "\(domain)/\(label)"])
        guard enable.succeeded else { return String(localized: "启用失败：\(detail(of: enable))") }
        let bootstrap = run(["bootstrap", domain, plistPath])
        if bootstrap.succeeded || run(["print", "\(domain)/\(label)"]).succeeded { return nil }
        return String(localized: "已启用，下次登录时生效（立即加载失败：\(detail(of: bootstrap))）")
    }

    /// 移除前卸载，避免已加载的失效项残留在 launchd 里
    nonisolated static func bootoutUserAgent(plistPath: String) {
        _ = run(["bootout", "gui/\(getuid())", plistPath])
    }

    private nonisolated static func detail(of result: Result) -> String {
        result.error.isEmpty ? String(localized: "状态码 \(result.status)") : result.error
    }
}
