//
//  AppPermissions.swift
//  MacClean
//
//  安全中心 · 应用权限：只读 TCC 数据库，列出拿到摄像头、麦克风、屏幕录制等敏感权限的应用。
//
//  用户库 ~/Library/Application Support/com.apple.TCC/TCC.db 与系统库 /Library/…/TCC.db
//  都需要完全磁盘访问权限才能打开。以 immutable 只读方式打开，不加锁、不写入；
//  macOS 只允许用户在系统设置中撤销授权，MacClean 不会也无法修改 TCC。
//

import AppKit
import Foundation
import SQLite3

// MARK: - 模型

nonisolated struct TCCRow: Equatable, Sendable {
    var service: String
    var client: String
    /// 0 = bundle id，1 = 绝对路径
    var clientType: Int
    /// 0 拒绝，2 允许，3 受限允许
    var authValue: Int
    var lastModified: Date?
    /// 自动化（AppleEvents）的目标应用
    var indirectObject: String?

    var isAllowed: Bool { authValue == 2 || authValue == 3 }
}

/// 页面上展示的权限分组
nonisolated enum PermissionService: String, CaseIterable, Sendable {
    case camera, microphone, screenCapture, accessibility, fullDiskAccess, inputMonitoring, postEvent
    case contacts, calendar, reminders, photos, automation, filesAndFolders

    /// TCC 中的服务名 → 分组（桌面 / 文稿 / 下载合并成「文件和文件夹」）
    static func from(tccService: String) -> PermissionService? {
        switch tccService {
        case "kTCCServiceCamera": return .camera
        case "kTCCServiceMicrophone": return .microphone
        case "kTCCServiceScreenCapture": return .screenCapture
        case "kTCCServiceAccessibility": return .accessibility
        case "kTCCServiceSystemPolicyAllFiles": return .fullDiskAccess
        case "kTCCServiceListenEvent": return .inputMonitoring
        case "kTCCServicePostEvent": return .postEvent
        case "kTCCServiceAddressBook": return .contacts
        case "kTCCServiceCalendar": return .calendar
        case "kTCCServiceReminders": return .reminders
        case "kTCCServicePhotos": return .photos
        case "kTCCServiceAppleEvents": return .automation
        case "kTCCServiceSystemPolicyDesktopFolder", "kTCCServiceSystemPolicyDocumentsFolder", "kTCCServiceSystemPolicyDownloadsFolder":
            return .filesAndFolders
        default: return nil
        }
    }

    /// 文件夹权限的具体文件夹名
    static func folderName(tccService: String) -> String? {
        switch tccService {
        case "kTCCServiceSystemPolicyDesktopFolder": return String(localized: "桌面")
        case "kTCCServiceSystemPolicyDocumentsFolder": return String(localized: "文稿")
        case "kTCCServiceSystemPolicyDownloadsFolder": return String(localized: "下载")
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .camera: return String(localized: "摄像头")
        case .microphone: return String(localized: "麦克风")
        case .screenCapture: return String(localized: "屏幕录制")
        case .accessibility: return String(localized: "辅助功能")
        case .fullDiskAccess: return String(localized: "完全磁盘访问权限")
        case .inputMonitoring: return String(localized: "输入监控")
        case .postEvent: return String(localized: "控制电脑")
        case .contacts: return String(localized: "通讯录")
        case .calendar: return String(localized: "日历")
        case .reminders: return String(localized: "提醒事项")
        case .photos: return String(localized: "照片")
        case .automation: return String(localized: "自动化")
        case .filesAndFolders: return String(localized: "文件和文件夹")
        }
    }

    var explanation: String {
        switch self {
        case .camera: return String(localized: "可以打开摄像头拍摄画面。")
        case .microphone: return String(localized: "可以通过麦克风录音。")
        case .screenCapture: return String(localized: "可以看到并录制屏幕上显示的所有内容。")
        case .accessibility: return String(localized: "可以读取其他窗口的内容、模拟点击和键盘操作。")
        case .fullDiskAccess: return String(localized: "可以读取邮件、信息、Safari 记录等所有受保护的数据。")
        case .inputMonitoring: return String(localized: "可以读取你在任何应用里的键盘输入。")
        case .postEvent: return String(localized: "可以向其他应用发送键盘和鼠标操作。")
        case .contacts: return String(localized: "可以读取通讯录里的联系人。")
        case .calendar: return String(localized: "可以读取和修改日历日程。")
        case .reminders: return String(localized: "可以读取和修改提醒事项。")
        case .photos: return String(localized: "可以访问照片图库。")
        case .automation: return String(localized: "可以通过 AppleScript 控制其他应用。")
        case .filesAndFolders: return String(localized: "可以访问桌面、文稿或下载文件夹。")
        }
    }

    var icon: String {
        switch self {
        case .camera: return "camera.fill"
        case .microphone: return "mic.fill"
        case .screenCapture: return "rectangle.dashed.badge.record"
        case .accessibility: return "accessibility"
        case .fullDiskAccess: return "internaldrive.fill"
        case .inputMonitoring: return "keyboard.fill"
        case .postEvent: return "cursorarrow.click.2"
        case .contacts: return "person.crop.circle.fill"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .photos: return "photo.fill"
        case .automation: return "gearshape.2.fill"
        case .filesAndFolders: return "folder.fill"
        }
    }

    /// 系统设置「隐私与安全性」中对应面板
    var settingsURL: URL {
        let anchor: String
        switch self {
        case .camera: anchor = "Privacy_Camera"
        case .microphone: anchor = "Privacy_Microphone"
        case .screenCapture: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .fullDiskAccess: anchor = "Privacy_AllFiles"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .postEvent: anchor = "Privacy_Accessibility"
        case .contacts: anchor = "Privacy_Contacts"
        case .calendar: anchor = "Privacy_Calendars"
        case .reminders: anchor = "Privacy_Reminders"
        case .photos: anchor = "Privacy_Photos"
        case .automation: anchor = "Privacy_Automation"
        case .filesAndFolders: anchor = "Privacy_FilesAndFolders"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

/// 客户端（bundle id 或路径）解析结果
nonisolated struct PermissionClientInfo: Equatable, Sendable {
    var displayName: String
    /// 应用或可执行文件路径；找不到时为 nil
    var path: String?
}

nonisolated struct PermissionClient: Identifiable, Equatable, Sendable {
    /// client_type + client
    let id: String
    let client: String
    let isPath: Bool
    var displayName: String
    var path: String?
    /// Apple 自带组件（折叠显示、不做标记）
    var isApple: Bool
    /// bundle id / 路径已找不到：授权已失效
    var isMissing: Bool
    var signature: SignatureInfo?
    /// 自动化的目标应用、文件夹权限的具体文件夹
    var details: [String] = []
    /// 受限允许（auth_value = 3）
    var isLimited = false
    var lastModified: Date?

    /// 签名有问题时的标记
    var signatureProblem: String? {
        guard let signature else { return nil }
        switch signature.validity {
        case .unsigned: return String(localized: "未签名")
        case .invalid, .revoked: return String(localized: "签名无效")
        case .valid, .unreadable: return nil
        }
    }

    /// 签名有问题才算值得留意；应用已不存在只是失效的授权，单独计数
    var needsAttention: Bool { signatureProblem != nil }
}

nonisolated struct PermissionGroup: Identifiable, Equatable, Sendable {
    let service: PermissionService
    /// 第三方应用
    var clients: [PermissionClient]
    /// Apple 自带组件
    var appleClients: [PermissionClient]

    var id: String { service.rawValue }
    var attentionCount: Int { clients.filter(\.needsAttention).count }
    var staleCount: Int { clients.filter(\.isMissing).count }
}

nonisolated struct PermissionsReport: Equatable, Sendable {
    /// 两个数据库都打不开（通常是没有完全磁盘访问权限）
    var needsFullDiskAccess: Bool
    /// 只读到了其中一个
    var isPartial: Bool
    var groups: [PermissionGroup]

    static let empty = PermissionsReport(needsFullDiskAccess: false, isPartial: false, groups: [])

    /// 仍然存在、拿到了至少一项权限的第三方应用数
    var thirdPartyClientCount: Int { Set(groups.flatMap { $0.clients.filter { !$0.isMissing }.map(\.id) }).count }
    /// 应用已不存在的失效授权（按应用去重）
    var staleClientCount: Int { Set(groups.flatMap { $0.clients.filter(\.isMissing).map(\.id) }).count }
    var attentionClients: [PermissionClient] {
        var seen: Set<String> = []
        return groups.flatMap(\.clients).filter { $0.needsAttention && seen.insert($0.id).inserted }
    }
}

// MARK: - SQLite 读取

enum TCCDatabase {
    nonisolated static var userPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/com.apple.TCC/TCC.db"
    }
    nonisolated static let systemPath = "/Library/Application Support/com.apple.TCC/TCC.db"

    /// 读取允许状态的授权行；数据库打不开返回 nil。
    nonisolated static func allowedRows(at path: String) -> [TCCRow]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // immutable=1：不加锁、不读写 -journal，绝不影响 tccd
        var components = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
        guard let uri = components?.url?.absoluteString else { return nil }

        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return nil }

        let full = "SELECT service, client, client_type, auth_value, last_modified, indirect_object_identifier FROM access WHERE auth_value IN (2, 3)"
        // 旧系统没有 indirect_object_identifier 列
        let legacy = "SELECT service, client, client_type, auth_value, last_modified, NULL FROM access WHERE auth_value IN (2, 3)"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        if sqlite3_prepare_v2(db, full, -1, &statement, nil) != SQLITE_OK {
            sqlite3_finalize(statement)
            statement = nil
            guard sqlite3_prepare_v2(db, legacy, -1, &statement, nil) == SQLITE_OK else { return nil }
        }

        func text(_ index: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: pointer)
        }

        var rows: [TCCRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return rows.isEmpty ? nil : rows }
            guard let service = text(0), let client = text(1) else { continue }
            let modified = sqlite3_column_int64(statement, 4)
            let indirect = text(5).flatMap { $0 == "UNUSED" || $0.isEmpty ? nil : $0 }
            rows.append(TCCRow(
                service: service,
                client: client,
                clientType: Int(sqlite3_column_int(statement, 2)),
                authValue: Int(sqlite3_column_int(statement, 3)),
                lastModified: modified > 0 ? Date(timeIntervalSince1970: TimeInterval(modified)) : nil,
                indirectObject: indirect
            ))
        }
        return rows
    }
}

// MARK: - 分组（纯函数，解析与签名检查通过闭包注入，便于测试）

enum PermissionGrouping {

    nonisolated static func isAppleClient(_ client: String, isPath: Bool) -> Bool {
        if isPath {
            return SuspicionRules.isAppleSystemPath(client)
        }
        return client.hasPrefix("com.apple.")
    }

    nonisolated static func group(
        rows: [TCCRow],
        resolve: (_ client: String, _ isPath: Bool) -> PermissionClientInfo,
        signature: (_ path: String) -> SignatureInfo?
    ) -> [PermissionGroup] {
        var resolved: [String: PermissionClientInfo] = [:]
        var signatures: [String: SignatureInfo?] = [:]
        // service → client id → client
        var byService: [PermissionService: [String: PermissionClient]] = [:]
        var order: [PermissionService: [String]] = [:]

        for row in rows where row.isAllowed {
            guard let service = PermissionService.from(tccService: row.service) else { continue }
            let isPath = row.clientType == 1
            let id = "\(row.clientType):\(row.client)"

            var client: PermissionClient
            if let existing = byService[service]?[id] {
                client = existing
            } else {
                let info = resolved[id] ?? resolve(row.client, isPath)
                resolved[id] = info
                let isApple = isAppleClient(row.client, isPath: isPath)
                var signatureInfo: SignatureInfo?
                if !isApple, let path = info.path {
                    if let cached = signatures[path] { signatureInfo = cached } else {
                        signatureInfo = signature(path)
                        signatures[path] = signatureInfo
                    }
                }
                client = PermissionClient(
                    id: id,
                    client: row.client,
                    isPath: isPath,
                    displayName: info.displayName,
                    path: info.path,
                    isApple: isApple,
                    isMissing: !isApple && info.path == nil,
                    signature: signatureInfo
                )
                order[service, default: []].append(id)
            }

            if service == .automation, let target = row.indirectObject {
                let name = resolve(target, target.hasPrefix("/")).displayName
                if !client.details.contains(name) { client.details.append(name) }
            }
            if let folder = PermissionService.folderName(tccService: row.service), !client.details.contains(folder) {
                client.details.append(folder)
            }
            if row.authValue == 3 { client.isLimited = true }
            if let date = row.lastModified, date > (client.lastModified ?? .distantPast) { client.lastModified = date }
            byService[service, default: [:]][id] = client
        }

        return PermissionService.allCases.compactMap { service in
            guard let clients = byService[service], let ids = order[service] else { return nil }
            let all = ids.compactMap { clients[$0] }
            let sorted = all.sorted { lhs, rhs in
                if lhs.needsAttention != rhs.needsAttention { return lhs.needsAttention }
                // 失效的授权排在最后
                if lhs.isMissing != rhs.isMissing { return rhs.isMissing }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
            return PermissionGroup(
                service: service,
                clients: sorted.filter { !$0.isApple },
                appleClients: sorted.filter(\.isApple)
            )
        }
    }

    /// 把 bundle id / 路径解析成应用名与位置。bundle id 找不到对应应用时，
    /// 再按前缀找宿主应用（com.foo.App.Helper → com.foo.App），避免把应用内的辅助程序误判为已删除。
    nonisolated static func resolveOnDisk(_ client: String, isPath: Bool) -> PermissionClientInfo {
        let fileManager = FileManager.default
        if isPath {
            let name = (client as NSString).lastPathComponent
            guard fileManager.fileExists(atPath: client) else { return PermissionClientInfo(displayName: name, path: nil) }
            if let app = LoginItemsParser.owningAppPath(forExecutable: client), fileManager.fileExists(atPath: app) {
                return PermissionClientInfo(displayName: LoginItemsParser.appDisplayName(app), path: client)
            }
            return PermissionClientInfo(displayName: name, path: client)
        }
        let workspace = NSWorkspace.shared
        if let url = workspace.urlForApplication(withBundleIdentifier: client) {
            return PermissionClientInfo(displayName: LoginItemsParser.appDisplayName(url.path), path: url.path)
        }
        for candidate in LoginItemsParser.bundleIDCandidates(forLabel: client).dropFirst() {
            if let url = workspace.urlForApplication(withBundleIdentifier: candidate) {
                return PermissionClientInfo(displayName: LoginItemsParser.appDisplayName(url.path), path: url.path)
            }
        }
        return PermissionClientInfo(displayName: client, path: nil)
    }
}

// MARK: - 扫描（后台线程）

enum AppPermissionsScanner {
    nonisolated static func scan(
        userDB: String = TCCDatabase.userPath,
        systemDB: String = TCCDatabase.systemPath
    ) -> PermissionsReport {
        let user = TCCDatabase.allowedRows(at: userDB)
        let system = TCCDatabase.allowedRows(at: systemDB)
        guard user != nil || system != nil else {
            return PermissionsReport(needsFullDiskAccess: true, isPartial: false, groups: [])
        }
        let groups = PermissionGrouping.group(
            rows: (user ?? []) + (system ?? []),
            resolve: PermissionGrouping.resolveOnDisk,
            signature: { CodeSignatureInspector.inspect(path: $0, validateResources: false) }
        )
        return PermissionsReport(needsFullDiskAccess: false, isPartial: user == nil || system == nil, groups: groups)
    }
}
