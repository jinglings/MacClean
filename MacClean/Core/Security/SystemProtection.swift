//
//  SystemProtection.swift
//  MacClean
//
//  安全中心 · 系统防护体检：只读检查 macOS 自带的防护是否开启。
//  全部命令都不需要管理员权限；输出解析是 nonisolated 纯函数，便于单元测试。
//  不打分、不夸大：每项只给出「正常 / 值得留意 / 无法检测」与原因。
//

import Foundation

// MARK: - 模型

nonisolated enum ProtectionHealth: Equatable, Sendable {
    /// 防护处于推荐状态
    case good
    /// 值得留意（附原因与建议）
    case attention
    /// 命令失败或输出无法识别
    case unknown
}

nonisolated struct ProtectionCheck: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case fileVault, firewall, sip, gatekeeper, xprotect, autoUpdates, screenLock, remoteAccess
    }

    let kind: Kind
    let health: ProtectionHealth
    /// 状态短语：已开启 / 已关闭 / 无法检测 / 每 15 分钟…
    let state: String
    /// 补充信息（版本号、具体哪几项关闭等）
    var detail: String?
    /// 需要处理时的建议
    var advice: String?

    var id: String { kind.rawValue }
}

extension ProtectionCheck.Kind {
    nonisolated var title: String {
        switch self {
        case .fileVault: return String(localized: "FileVault 磁盘加密")
        case .firewall: return String(localized: "防火墙")
        case .sip: return String(localized: "系统完整性保护（SIP）")
        case .gatekeeper: return String(localized: "Gatekeeper 应用来源检查")
        case .xprotect: return String(localized: "XProtect 安全数据")
        case .autoUpdates: return String(localized: "自动安装安全更新")
        case .screenLock: return String(localized: "离开后自动锁屏")
        case .remoteAccess: return String(localized: "远程访问")
        }
    }

    /// 一句话说明为什么重要
    nonisolated var why: String {
        switch self {
        case .fileVault:
            return String(localized: "Mac 丢失或被盗时，没有登录密码就读不出磁盘里的数据。")
        case .firewall:
            return String(localized: "阻止外部网络主动连接本机上的服务；在公共 Wi-Fi 下尤其有用。")
        case .sip:
            return String(localized: "防止任何程序（包括拿到管理员密码的）改动系统文件。")
        case .gatekeeper:
            return String(localized: "打开从网上下载的应用前，检查它是否由已登记的开发者签名并经过 Apple 公证。")
        case .xprotect:
            return String(localized: "macOS 内置的已知恶意软件特征库，由 Apple 在后台静默更新。")
        case .autoUpdates:
            return String(localized: "安全响应与系统数据文件（含 XProtect）需要自动安装才能及时生效。")
        case .screenLock:
            return String(localized: "走开时别人无法直接使用你已登录的 Mac。")
        case .remoteAccess:
            return String(localized: "远程登录、屏幕共享、文件共享等服务开启后，同一网络里的设备可以尝试连接这台 Mac。")
        }
    }

    nonisolated var icon: String {
        switch self {
        case .fileVault: return "lock.fill"
        case .firewall: return "flame.fill"
        case .sip: return "shield.lefthalf.filled"
        case .gatekeeper: return "checkmark.seal.fill"
        case .xprotect: return "shield.checkered"
        case .autoUpdates: return "arrow.triangle.2.circlepath"
        case .screenLock: return "lock.display"
        case .remoteAccess: return "network"
        }
    }

    /// 可在系统设置中修改的项给出深链接（按顺序尝试）；SIP / Gatekeeper 无法在设置里改，返回空。
    nonisolated var settingsURLs: [String] {
        switch self {
        case .fileVault:
            return ["x-apple.systempreferences:com.apple.preference.security?FileVault"]
        case .firewall:
            return ["x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall",
                    "x-apple.systempreferences:com.apple.preference.security?Firewall"]
        case .autoUpdates, .xprotect:
            return ["x-apple.systempreferences:com.apple.Software-Update-Settings.extension"]
        case .screenLock:
            return ["x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension"]
        case .remoteAccess:
            return ["x-apple.systempreferences:com.apple.Sharing-Settings.extension"]
        case .sip, .gatekeeper:
            return []
        }
    }
}

// MARK: - 解析（纯函数）

nonisolated enum FileVaultState: Equatable, Sendable { case on, off, encrypting, decrypting, unknown }
nonisolated enum FirewallState: Equatable, Sendable { case off, on, blockAll, unknown }
nonisolated enum SIPState: Equatable, Sendable { case enabled, disabled, custom, unknown }
nonisolated enum GatekeeperState: Equatable, Sendable { case enabled, disabled, unknown }
nonisolated enum ScreenLockState: Equatable, Sendable { case off, immediate, delay(Int), unknown }

nonisolated struct SoftwareUpdateSettings: Equatable, Sendable {
    /// 自动检查更新（键缺失时系统默认开启）
    var automaticCheck = true
    var automaticDownload = true
    /// 安全响应与系统文件
    var criticalUpdateInstall = true
    /// 系统数据文件（XProtect 等配置数据）
    var configDataInstall = true
    var automaticallyInstallMacOS = false
}

/// 一个远程访问服务及其端口
nonisolated struct RemoteService: Equatable, Hashable, Sendable {
    let port: Int
    let name: String

    static let all: [RemoteService] = [
        RemoteService(port: 22, name: String(localized: "远程登录（SSH）")),
        RemoteService(port: 5900, name: String(localized: "屏幕共享")),
        RemoteService(port: 3283, name: String(localized: "远程管理（ARD）")),
        RemoteService(port: 445, name: String(localized: "文件共享（SMB）")),
        RemoteService(port: 548, name: String(localized: "文件共享（AFP）")),
    ]
}

enum ProtectionParsers {

    /// `fdesetup status`
    nonisolated static func fileVault(_ output: String) -> FileVaultState {
        let text = output.lowercased()
        if text.contains("encryption in progress") { return .encrypting }
        if text.contains("decryption in progress") { return .decrypting }
        if text.contains("filevault is on") { return .on }
        if text.contains("filevault is off") { return .off }
        return .unknown
    }

    /// `socketfilterfw --getglobalstate`：State = 0 关闭 / 1 开启 / 2 阻止所有传入连接
    nonisolated static func firewall(_ output: String) -> FirewallState {
        if let range = output.range(of: "State = ") {
            switch output[range.upperBound...].first {
            case "0": return .off
            case "1": return .on
            case "2": return .blockAll
            default: break
            }
        }
        let text = output.lowercased()
        if text.contains("firewall is disabled") { return .off }
        if text.contains("blocking all") || text.contains("block all") { return .blockAll }
        if text.contains("firewall is enabled") { return .on }
        return .unknown
    }

    /// `socketfilterfw --getstealthmode` → "Firewall stealth mode is on/off"（新系统也可能是 "Stealth mode enabled"）
    nonisolated static func stealthMode(_ output: String) -> Bool? {
        let text = output.lowercased()
        guard text.contains("stealth") else { return nil }
        if text.contains("mode is on") || text.contains("mode enabled") || text.contains("mode is enabled") { return true }
        if text.contains("mode is off") || text.contains("mode disabled") || text.contains("mode is disabled") { return false }
        return nil
    }

    /// `csrutil status`
    nonisolated static func sip(_ output: String) -> SIPState {
        let text = output.lowercased()
        guard let range = text.range(of: "status:") else { return .unknown }
        let value = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        if text.contains("custom configuration") { return .custom }
        if value.hasPrefix("enabled") { return .enabled }
        if value.hasPrefix("disabled") { return .disabled }
        return .unknown
    }

    /// `spctl --status`
    nonisolated static func gatekeeper(_ output: String) -> GatekeeperState {
        let text = output.lowercased()
        if text.contains("assessments enabled") { return .enabled }
        if text.contains("assessments disabled") { return .disabled }
        return .unknown
    }

    /// `sysadminctl -screenLock status`（输出在 stderr，带时间戳前缀）
    nonisolated static func screenLock(_ output: String) -> ScreenLockState {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.lowercased().contains("screenlock") }) else {
            return .unknown
        }
        let text = line.lowercased()
        if text.contains("screenlock is off") { return .off }
        if text.contains("immediate") { return .immediate }
        if let range = text.range(of: "delay is ") {
            let digits = text[range.upperBound...].prefix { $0.isNumber }
            if let seconds = Int(digits) { return seconds == 0 ? .immediate : .delay(seconds) }
        }
        return .unknown
    }

    /// 锁屏延迟超过 1 小时或关闭时值得留意
    nonisolated static func screenLockNeedsAttention(_ state: ScreenLockState) -> Bool {
        switch state {
        case .off: return true
        case .delay(let seconds): return seconds > 3600
        case .immediate, .unknown: return false
        }
    }

    /// `defaults read /Library/Preferences/com.apple.SoftwareUpdate` 的输出（旧式 plist 文本）。
    /// 旧式 plist 中的 1/0 解析出来是字符串，这里一并兼容。读不出来返回 nil。
    nonisolated static func softwareUpdate(_ output: String) -> SoftwareUpdateSettings? {
        // 从未改过更新设置时偏好文件不存在，全部按系统默认值
        if output.contains("does not exist") { return SoftwareUpdateSettings() }
        guard let data = output.data(using: .utf8),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        func flag(_ key: String, default value: Bool) -> Bool {
            switch dict[key] {
            case let bool as Bool: return bool
            case let number as NSNumber: return number.intValue != 0
            case let string as String:
                switch string.lowercased() {
                case "1", "true", "yes": return true
                case "0", "false", "no": return false
                default: return value
                }
            default: return value
            }
        }
        return SoftwareUpdateSettings(
            automaticCheck: flag("AutomaticCheckEnabled", default: true),
            automaticDownload: flag("AutomaticDownload", default: true),
            criticalUpdateInstall: flag("CriticalUpdateInstall", default: true),
            configDataInstall: flag("ConfigDataInstall", default: true),
            automaticallyInstallMacOS: flag("AutomaticallyInstallMacOSUpdates", default: false)
        )
    }

    /// `netstat -anv -p tcp` → 处于 LISTEN、且不只监听回环地址的端口。
    /// 本地地址形如 `*.22`、`192.168.1.2.5900`、`::1.22`、`127.0.0.1.445`。
    nonisolated static func listeningPorts(_ output: String) -> Set<Int> {
        var ports: Set<Int> = []
        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 6, columns[0].hasPrefix("tcp"), columns.contains("LISTEN") else { continue }
            let local = columns[3]
            guard let dot = local.lastIndex(of: "."), let port = Int(local[local.index(after: dot)...]) else { continue }
            let address = local[..<dot]
            if address.hasPrefix("127.") || address == "::1" || address.hasPrefix("fe80::1%lo") { continue }
            ports.insert(port)
        }
        return ports
    }

    nonisolated static func remoteServices(listening ports: Set<Int>) -> [RemoteService] {
        RemoteService.all.filter { ports.contains($0.port) }
    }

    /// XProtect 超过 60 天未更新才提示
    nonisolated static func xprotectIsStale(updated: Date, now: Date, maxDays: Int = 60) -> Bool {
        now.timeIntervalSince(updated) > Double(maxDays) * 86_400
    }
}

// MARK: - XProtect

nonisolated struct XProtectInfo: Equatable, Sendable {
    let version: String
    let updated: Date
    let path: String
}

enum XProtectLocator {
    nonisolated static let bundlePaths = [
        "/Library/Apple/System/Library/CoreServices/XProtect.bundle",
        "/var/protected/xprotect/XProtect.bundle",
    ]

    /// 读取各位置的 XProtect.bundle，取更新时间最新的一份。
    nonisolated static func newest(paths: [String] = bundlePaths) -> XProtectInfo? {
        let fileManager = FileManager.default
        var found: [XProtectInfo] = []
        for bundle in paths {
            let plist = bundle + "/Contents/Info.plist"
            guard let data = fileManager.contents(atPath: plist),
                  let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let version = (dict["CFBundleShortVersionString"] as? String) ?? (dict["CFBundleVersion"] as? String) else { continue }
            let dates = [plist, bundle, bundle + "/Contents"].compactMap {
                (try? fileManager.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
            }
            guard let updated = dates.max() else { continue }
            found.append(XProtectInfo(version: version, updated: updated, path: bundle))
        }
        return pickNewest(found)
    }

    /// 版本号更大的优先，相同时取修改时间更晚的
    nonisolated static func pickNewest(_ infos: [XProtectInfo]) -> XProtectInfo? {
        infos.max { lhs, rhs in
            let order = lhs.version.compare(rhs.version, options: .numeric)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.updated < rhs.updated
        }
    }
}

// MARK: - 汇总成检查项

enum ProtectionEvaluator {

    nonisolated static func fileVault(_ state: FileVaultState) -> ProtectionCheck {
        switch state {
        case .on:
            return ProtectionCheck(kind: .fileVault, health: .good, state: String(localized: "已开启"))
        case .encrypting:
            return ProtectionCheck(kind: .fileVault, health: .good, state: String(localized: "正在加密"),
                                   detail: String(localized: "加密在后台进行，完成前可以正常使用。"))
        case .off:
            return ProtectionCheck(kind: .fileVault, health: .attention, state: String(localized: "已关闭"),
                                   advice: String(localized: "建议在「隐私与安全性」中开启 FileVault，请务必妥善保存恢复密钥。"))
        case .decrypting:
            return ProtectionCheck(kind: .fileVault, health: .attention, state: String(localized: "正在解密"),
                                   advice: String(localized: "FileVault 正在被关闭。如果不是你操作的，请到「隐私与安全性」中查看。"))
        case .unknown:
            return ProtectionCheck(kind: .fileVault, health: .unknown, state: String(localized: "无法检测"))
        }
    }

    nonisolated static func firewall(_ state: FirewallState, stealth: Bool?) -> ProtectionCheck {
        let stealthText: String? = stealth.map {
            $0 ? String(localized: "隐身模式已开启") : String(localized: "隐身模式未开启")
        }
        switch state {
        case .on:
            return ProtectionCheck(kind: .firewall, health: .good, state: String(localized: "已开启"), detail: stealthText)
        case .blockAll:
            return ProtectionCheck(kind: .firewall, health: .good, state: String(localized: "已开启"),
                                   detail: String(localized: "阻止所有传入连接"))
        case .off:
            return ProtectionCheck(kind: .firewall, health: .attention, state: String(localized: "已关闭"),
                                   advice: String(localized: "家里的网络有路由器挡着，影响不大；常连公共 Wi-Fi 的话建议开启。"))
        case .unknown:
            return ProtectionCheck(kind: .firewall, health: .unknown, state: String(localized: "无法检测"))
        }
    }

    nonisolated static func sip(_ state: SIPState) -> ProtectionCheck {
        switch state {
        case .enabled:
            return ProtectionCheck(kind: .sip, health: .good, state: String(localized: "已开启"))
        case .disabled, .custom:
            return ProtectionCheck(
                kind: .sip, health: .attention,
                state: state == .custom ? String(localized: "部分关闭") : String(localized: "已关闭"),
                advice: String(localized: "SIP 只能在恢复模式下修改：重启进入恢复模式，打开「终端」运行 csrutil enable，然后重启。如果是你为开发或调试特意关闭的，可以忽略。")
            )
        case .unknown:
            return ProtectionCheck(kind: .sip, health: .unknown, state: String(localized: "无法检测"))
        }
    }

    nonisolated static func gatekeeper(_ state: GatekeeperState) -> ProtectionCheck {
        switch state {
        case .enabled:
            return ProtectionCheck(kind: .gatekeeper, health: .good, state: String(localized: "已开启"))
        case .disabled:
            return ProtectionCheck(
                kind: .gatekeeper, health: .attention, state: String(localized: "已关闭"),
                advice: String(localized: "新系统的设置里没有这个开关。在「终端」中运行 sudo spctl --master-enable 即可重新开启。")
            )
        case .unknown:
            return ProtectionCheck(kind: .gatekeeper, health: .unknown, state: String(localized: "无法检测"))
        }
    }

    nonisolated static func xprotect(_ info: XProtectInfo?, now: Date) -> ProtectionCheck {
        guard let info else {
            return ProtectionCheck(kind: .xprotect, health: .unknown, state: String(localized: "无法检测"))
        }
        let date = info.updated.formatted(date: .abbreviated, time: .omitted)
        let detail = String(localized: "版本 \(info.version) · \(date) 更新")
        if ProtectionParsers.xprotectIsStale(updated: info.updated, now: now) {
            return ProtectionCheck(kind: .xprotect, health: .attention, state: String(localized: "较久未更新"), detail: detail,
                                   advice: String(localized: "安全数据可能没有及时更新，请检查是否关闭了自动更新。"))
        }
        return ProtectionCheck(kind: .xprotect, health: .good, state: String(localized: "最近已更新"), detail: detail)
    }

    nonisolated static func autoUpdates(_ settings: SoftwareUpdateSettings?) -> ProtectionCheck {
        guard let settings else {
            return ProtectionCheck(kind: .autoUpdates, health: .unknown, state: String(localized: "无法检测"))
        }
        var off: [String] = []
        if !settings.automaticCheck { off.append(String(localized: "自动检查更新")) }
        if !settings.criticalUpdateInstall { off.append(String(localized: "安全响应与系统文件")) }
        if !settings.configDataInstall { off.append(String(localized: "系统数据文件")) }
        guard off.isEmpty else {
            return ProtectionCheck(
                kind: .autoUpdates, health: .attention, state: String(localized: "部分关闭"),
                detail: String(localized: "已关闭：\(off.joined(separator: "、"))"),
                advice: String(localized: "建议在「软件更新 → 自动更新」中打开「安装安全响应与系统文件」。")
            )
        }
        let detail = settings.automaticallyInstallMacOS
            ? String(localized: "macOS 更新也会自动安装")
            : String(localized: "macOS 大版本更新需手动安装")
        return ProtectionCheck(kind: .autoUpdates, health: .good, state: String(localized: "已开启"), detail: detail)
    }

    nonisolated static func screenLock(_ state: ScreenLockState) -> ProtectionCheck {
        switch state {
        case .immediate:
            return ProtectionCheck(kind: .screenLock, health: .good, state: String(localized: "立即要求密码"))
        case .delay(let seconds):
            let text = delayText(seconds)
            if ProtectionParsers.screenLockNeedsAttention(state) {
                return ProtectionCheck(kind: .screenLock, health: .attention, state: text,
                                       advice: String(localized: "离开超过 1 小时才要求密码，建议在「锁定屏幕」中缩短。"))
            }
            return ProtectionCheck(kind: .screenLock, health: .good, state: text)
        case .off:
            return ProtectionCheck(kind: .screenLock, health: .attention, state: String(localized: "已关闭"),
                                   advice: String(localized: "唤醒或停止屏保后不需要密码。建议在「锁定屏幕」中开启。"))
        case .unknown:
            return ProtectionCheck(kind: .screenLock, health: .unknown, state: String(localized: "无法检测"))
        }
    }

    nonisolated static func delayText(_ seconds: Int) -> String {
        if seconds < 60 { return String(localized: "\(seconds) 秒后要求密码") }
        if seconds < 3600 { return String(localized: "\(seconds / 60) 分钟后要求密码") }
        return String(localized: "\(seconds / 3600) 小时后要求密码")
    }

    nonisolated static func remoteAccess(_ services: [RemoteService]?) -> ProtectionCheck {
        guard let services else {
            return ProtectionCheck(kind: .remoteAccess, health: .unknown, state: String(localized: "无法检测"))
        }
        guard !services.isEmpty else {
            return ProtectionCheck(kind: .remoteAccess, health: .good, state: String(localized: "未开启"))
        }
        return ProtectionCheck(
            kind: .remoteAccess, health: .attention, state: String(localized: "已开启"),
            detail: services.map(\.name).joined(separator: "、"),
            advice: String(localized: "如果不是你开启的，建议在「共享」设置中关闭。")
        )
    }
}

// MARK: - 运行（后台线程）

enum SystemProtectionScanner {

    /// 运行只读命令，返回 stdout + stderr；超过 15 秒强制结束。
    /// 用最小的干净环境：从 Xcode 启动时继承的 OS_ACTIVITY_DT_MODE 会让 sysadminctl 的 NSLog 输出不进 stderr。
    nonisolated static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15) -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": NSUserName(),
            "LANG": "en_US.UTF-8",
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // 先读完管道再 wait，避免输出塞满管道缓冲导致互相等待
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return String(decoding: out, as: UTF8.self) + "\n" + String(decoding: err, as: UTF8.self)
    }

    nonisolated static func scan(now: Date = Date()) -> [ProtectionCheck] {
        let firewallTool = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        let netstat = run("/usr/sbin/netstat", ["-anv", "-p", "tcp"])
        let ports: Set<Int>? = netstat.contains("Proto") || netstat.contains("tcp") ? ProtectionParsers.listeningPorts(netstat) : nil
        return [
            ProtectionEvaluator.fileVault(ProtectionParsers.fileVault(run("/usr/bin/fdesetup", ["status"]))),
            ProtectionEvaluator.firewall(
                ProtectionParsers.firewall(run(firewallTool, ["--getglobalstate"])),
                stealth: ProtectionParsers.stealthMode(run(firewallTool, ["--getstealthmode"]))
            ),
            ProtectionEvaluator.sip(ProtectionParsers.sip(run("/usr/bin/csrutil", ["status"]))),
            ProtectionEvaluator.gatekeeper(ProtectionParsers.gatekeeper(run("/usr/sbin/spctl", ["--status"]))),
            ProtectionEvaluator.xprotect(XProtectLocator.newest(), now: now),
            ProtectionEvaluator.autoUpdates(ProtectionParsers.softwareUpdate(
                run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.SoftwareUpdate"])
            )),
            ProtectionEvaluator.screenLock(ProtectionParsers.screenLock(run("/usr/sbin/sysadminctl", ["-screenLock", "status"]))),
            ProtectionEvaluator.remoteAccess(ports.map(ProtectionParsers.remoteServices(listening:))),
        ]
    }
}
