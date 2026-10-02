//
//  SuspiciousItems.swift
//  MacClean
//
//  安全中心 · 值得留意：检查后台启动项、已安装应用、描述文件中来路不明或签名有问题的项目。
//  这不是杀毒：不比对特征库，只指出「签名缺失 / 位置反常 / 冒充系统组件」等客观事实，
//  每条结论都附原因与建议，由用户自己判断。
//
//  启动项枚举复用 LoginItemsScanner；所有检查都在后台线程运行。
//

import Foundation

// MARK: - 模型

nonisolated enum FindingSeverity: Int, Comparable, Sendable {
    /// 提示：多数情况下没问题，只是让你知道
    case info = 0
    /// 值得留意：建议确认来源
    case attention = 1

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated enum FindingReason: Equatable, Hashable, Sendable {
    case unsigned
    case invalidSignature
    case revoked
    case adhoc
    /// 位于 Homebrew 等包管理器目录的临时签名程序（通常是正常的开源工具）
    case adhocPackageManager
    /// 临时签名的应用：很多独立开发者和开源应用都这样分发
    case adhocApp
    case notNotarized
    /// 启动的是脚本文件（脚本没有签名机制）
    case scriptFile
    case hiddenDirectory
    case tempLocation
    case randomName
    case fakeAppleLabel
    case inlineScript(String)
    case configurationProfile

    var severity: FindingSeverity {
        switch self {
        case .adhocPackageManager, .adhocApp, .notNotarized, .scriptFile: return .info
        default: return .attention
        }
    }

    var title: String {
        switch self {
        case .unsigned: return String(localized: "未签名")
        case .invalidSignature: return String(localized: "签名无效")
        case .revoked: return String(localized: "证书已被吊销")
        case .adhoc, .adhocPackageManager, .adhocApp: return String(localized: "临时签名")
        case .notNotarized: return String(localized: "未经 Apple 公证")
        case .scriptFile: return String(localized: "脚本文件")
        case .hiddenDirectory: return String(localized: "藏在隐藏文件夹里")
        case .tempLocation: return String(localized: "位于临时或共享目录")
        case .randomName: return String(localized: "名字像随机生成的")
        case .fakeAppleLabel: return String(localized: "名称像 Apple 组件")
        case .inlineScript: return String(localized: "直接运行脚本命令")
        case .configurationProfile: return String(localized: "已安装描述文件")
        }
    }

    var explanation: String {
        switch self {
        case .unsigned:
            return String(localized: "程序没有任何签名，无法确认是谁做的、有没有被改动过。")
        case .invalidSignature:
            return String(localized: "签名校验没有通过，程序可能在签名后被修改过。")
        case .revoked:
            return String(localized: "Apple 已吊销这个开发者证书或公证，通常是因为发现了问题。")
        case .adhoc:
            return String(localized: "只有临时签名，没有登记的开发者身份，无法确认来源。")
        case .adhocPackageManager:
            return String(localized: "Homebrew 等包管理器安装的开源工具大多如此，是你自己安装的就没问题。")
        case .adhocApp:
            return String(localized: "很多独立开发者和开源应用都只做临时签名；是你自己从可信的地方下载的就没问题。")
        case .notNotarized:
            return String(localized: "有开发者签名，但没有经过 Apple 公证；较老的软件常见这种情况。")
        case .scriptFile:
            return String(localized: "启动的是一个脚本。脚本没有签名，无法确认来源，请确认它属于你认识的软件。")
        case .hiddenDirectory:
            return String(localized: "正常软件很少把后台程序放在以「.」开头的隐藏文件夹里。")
        case .tempLocation:
            return String(localized: "临时目录和「共享」目录任何程序都能写入，正常软件不会从这里常驻运行。")
        case .randomName:
            return String(localized: "文件或文件夹名像一串随机字符，广告软件常用这种方式躲避识别。")
        case .fakeAppleLabel:
            return String(localized: "标识以 com.apple. 开头，程序却不在系统目录、也不是 Apple 签名的。")
        case .inlineScript(let interpreter):
            return String(localized: "启动时用 \(interpreter) 直接执行一段命令，而不是运行一个应用程序。")
        case .configurationProfile:
            return String(localized: "描述文件可以更改代理、DNS、证书和浏览器设置。如果是公司或学校安装的，可以忽略；否则建议在系统设置中移除。")
        }
    }
}

nonisolated struct PersistenceFinding: Identifiable, Equatable, Sendable {
    let item: LaunchItem
    /// 被检查的可执行文件
    let executable: String?
    let reasons: [FindingReason]
    let severity: FindingSeverity

    var id: String { item.id }
}

nonisolated struct AppFinding: Identifiable, Equatable, Sendable {
    let path: String
    let name: String
    let reasons: [FindingReason]

    var id: String { path }
    var severity: FindingSeverity { reasons.map(\.severity).max() ?? .info }
}

nonisolated struct ConfigurationProfile: Identifiable, Equatable, Sendable {
    let identifier: String
    /// 用户级或电脑级
    let isComputerLevel: Bool
    var id: String { (isComputerLevel ? "computer:" : "user:") + identifier }
}

nonisolated struct ProfilesResult: Equatable, Sendable {
    var profiles: [ConfigurationProfile]
    /// `profiles` 命令不可用或输出无法识别
    var couldNotCheck: Bool
}

// MARK: - 启发式规则（纯函数）

enum SuspicionRules {

    nonisolated static let tempPrefixes = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/Users/Shared/"]
    nonisolated static let packageManagerPrefixes = ["/opt/homebrew/", "/usr/local/", "/opt/local/", "/nix/"]
    nonisolated static let appleSystemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]

    /// 系统自带目录（/usr/local 属于用户自己安装的软件，不算）
    nonisolated static func isAppleSystemPath(_ path: String) -> Bool {
        guard !path.hasPrefix("/usr/local/") else { return false }
        return appleSystemPrefixes.contains { path.hasPrefix($0) }
    }
    nonisolated static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish",
        "python", "python2", "python3", "perl", "ruby", "node", "osascript", "curl", "wget",
    ]

    /// 路径中任一组成部分以「.」开头
    nonisolated static func isInHiddenDirectory(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") && $0 != "." && $0 != ".." }
    }

    nonisolated static func isInTempLocation(_ path: String) -> Bool {
        tempPrefixes.contains { path.hasPrefix($0) }
    }

    nonisolated static func isInPackageManager(_ path: String) -> Bool {
        packageManagerPrefixes.contains { path.hasPrefix($0) }
    }

    /// 名字是否像随机字符串：UUID、长十六进制串、字母数字混杂且数字比例高、或长串几乎没有元音。
    nonisolated static func looksRandom(_ rawName: String) -> Bool {
        let name = (rawName as NSString).deletingPathExtension
        guard name.count >= 8 else { return false }
        if UUID(uuidString: name) != nil { return true }
        guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        let digits = name.filter(\.isNumber).count
        let letters = name.count - digits
        if name.count >= 12, name.allSatisfy(\.isHexDigit), digits > 0 { return true }
        // 字母和数字反复交错（aB3x9Kq2）才算；Office365 这种只在末尾带数字的不算
        let transitions = zip(name, name.dropFirst()).filter { $0.isNumber != $1.isNumber }.count
        if digits > 0, letters > 0, Double(digits) / Double(name.count) >= 0.25, transitions >= 4 { return true }
        if letters == name.count, name.count >= 10 {
            let vowels = name.lowercased().filter { "aeiouy".contains($0) }.count
            return Double(vowels) / Double(name.count) < 0.15
        }
        return false
    }

    /// ~/Library/Application Support 下名字像随机生成的文件夹或文件
    nonisolated static func hasRandomNameInApplicationSupport(_ path: String, home: String) -> Bool {
        let base = home + "/Library/Application Support/"
        guard path.hasPrefix(base) else { return false }
        return path.dropFirst(base.count).split(separator: "/").contains { looksRandom(String($0)) }
    }

    /// 标识冒充 Apple：com.apple.* 却不在系统目录，且不是 Apple 签名
    nonisolated static func imitatesApple(label: String, executable: String?, isAppleSigned: Bool) -> Bool {
        guard label.lowercased().hasPrefix("com.apple."), let executable, executable.hasPrefix("/") else { return false }
        if isAppleSystemPath(executable) { return false }
        return !isAppleSigned
    }

    /// ProgramArguments 以 shell / 脚本解释器直接执行内联命令时，返回解释器名。
    nonisolated static func inlineInterpreter(_ arguments: [String]) -> String? {
        guard let first = arguments.first else { return nil }
        var index = 0
        var name = (first as NSString).lastPathComponent
        // /usr/bin/env python3 -c …
        if name == "env", arguments.count > 1 {
            index = 1
            name = (arguments[1] as NSString).lastPathComponent
        }
        let base = name.lowercased().replacingOccurrences(of: #"[0-9.]+$"#, with: "", options: .regularExpression)
        guard interpreters.contains(name.lowercased()) || interpreters.contains(base) else { return nil }
        let rest = arguments.dropFirst(index + 1)
        // curl / wget 作为启动项本身就是在下载东西
        if base == "curl" || base == "wget" { return name }
        let inlineFlags: Set<String> = ["-c", "-e", "-lc", "-ic", "--eval", "-E"]
        if rest.contains(where: { inlineFlags.contains($0) }) { return name }
        // 把多段命令写在一个参数里（管道、分号、curl 下载）
        if rest.contains(where: { $0.contains("|") || $0.contains("curl ") || $0.contains("base64") }) { return name }
        return nil
    }

    /// 读取 plist 的完整 ProgramArguments（LoginItemsParser 只保留了第一个）
    nonisolated static func programArguments(plistData: Data) -> [String] {
        guard let dict = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else { return [] }
        if let arguments = dict["ProgramArguments"] as? [String], !arguments.isEmpty {
            if let program = dict["Program"] as? String, program != arguments.first { return [program] + arguments.dropFirst() }
            return arguments
        }
        return (dict["Program"] as? String).map { [$0] } ?? []
    }

    /// 签名相关的理由。`checkNotarization` 为 false（/Applications、系统目录等位置）时不追究公证；
    /// `isApp` 为 true 时临时签名只算提示。
    nonisolated static func signatureReasons(_ info: SignatureInfo, path: String, checkNotarization: Bool, isApp: Bool = false) -> [FindingReason] {
        switch info.validity {
        case .unreadable: return []
        case .unsigned: return [.unsigned]
        case .revoked: return [.revoked]
        case .invalid: return [.invalidSignature]
        case .valid:
            if info.isAdhoc { return [isApp ? .adhocApp : (isInPackageManager(path) ? .adhocPackageManager : .adhoc)] }
            if checkNotarization, !info.isApple, !info.isNotarized { return [.notNotarized] }
            return []
        }
    }

    /// 是否在免公证检查的可信位置（/Applications、系统目录）
    nonisolated static func isTrustedLocation(_ path: String) -> Bool {
        path.hasPrefix("/Applications/") || isAppleSystemPath(path)
    }

    /// 位置类理由（隐藏目录、随机名字）在程序已由开发者签名并经过公证时降为提示：
    /// 很多开发工具就装在 ~/.xxx 下，身份可查的程序不必紧张。
    nonisolated static func severity(of reasons: [FindingReason], signature: SignatureInfo?) -> FindingSeverity {
        let vouched = signature.map { $0.isApple || ($0.hasDeveloperIdentity && $0.isNotarized) } ?? false
        let locationOnly: Set<FindingReason> = [.hiddenDirectory, .randomName]
        return reasons.map { reason in
            vouched && locationOnly.contains(reason) ? .info : reason.severity
        }.max() ?? .info
    }

    /// 文件以「#!」开头即为脚本
    nonisolated static func isScript(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 2)) == Data("#!".utf8)
    }

    /// 针对一个启动项给出全部理由
    nonisolated static func reasons(
        label: String,
        executable: String?,
        arguments: [String],
        signature: SignatureInfo?,
        isScript: Bool = false,
        home: String
    ) -> [FindingReason] {
        var reasons: [FindingReason] = []
        if let executable {
            if isScript {
                reasons.append(.scriptFile)
            } else if let signature {
                reasons += signatureReasons(signature, path: executable, checkNotarization: !isTrustedLocation(executable))
            }
            if isInHiddenDirectory(executable) { reasons.append(.hiddenDirectory) }
            if isInTempLocation(executable) { reasons.append(.tempLocation) }
            if hasRandomNameInApplicationSupport(executable, home: home) { reasons.append(.randomName) }
            if imitatesApple(label: label, executable: executable, isAppleSigned: signature?.isApple ?? false) {
                reasons.append(.fakeAppleLabel)
            }
        }
        if let interpreter = inlineInterpreter(arguments) {
            reasons.append(.inlineScript(interpreter))
            // 解释器本身是 Apple 签名的系统程序，签名理由不适用；真正可疑的是它执行的命令
        }
        return reasons
    }
}

// MARK: - 描述文件 / Safari 扩展输出解析

enum ProfilesParser {
    /// `profiles list` 的输出。没有描述文件时为
    /// "There are no configuration profiles installed for user 'x'"；
    /// 有时每行形如 "_computerlevel[1] attribute: profileIdentifier: com.example.profile"。
    nonisolated static func parse(_ output: String) -> ProfilesResult {
        var profiles: [ConfigurationProfile] = []
        var recognized = false
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if text.contains("There are no configuration profiles") || text.contains("configuration profiles installed") {
                recognized = true
                continue
            }
            guard let range = text.range(of: "profileIdentifier:") else { continue }
            recognized = true
            let identifier = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !identifier.isEmpty else { continue }
            let profile = ConfigurationProfile(identifier: identifier, isComputerLevel: text.hasPrefix("_computerlevel"))
            if !profiles.contains(profile) { profiles.append(profile) }
        }
        return ProfilesResult(profiles: profiles, couldNotCheck: !recognized)
    }
}

// MARK: - 扫描（后台线程）

nonisolated struct SuspiciousScanResult: Equatable, Sendable {
    var persistence: [PersistenceFinding]
    var launchItemCount: Int
    var apps: [AppFinding]
    var appCount: Int
    /// 有开发者签名、需要联网做吊销检查的应用
    var revocationCandidates: [String]
    var profiles: ProfilesResult
}

enum SuspiciousItemsScanner {

    nonisolated static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SuspiciousScanResult {
        let launchItems = LoginItemsScanner.scan(home: home)
        let persistence = checkLaunchItems(launchItems, home: home.path)
        let (apps, appCount, candidates) = checkApplications(home: home.path)
        let profiles = ProfilesParser.parse(SystemProtectionScanner.run("/usr/bin/profiles", ["list"]))
        return SuspiciousScanResult(
            persistence: persistence,
            launchItemCount: launchItems.count,
            apps: apps,
            appCount: appCount,
            revocationCandidates: candidates,
            profiles: profiles
        )
    }

    nonisolated static func checkLaunchItems(_ items: [LaunchItem], home: String) -> [PersistenceFinding] {
        let fileManager = FileManager.default
        var cache: [String: SignatureInfo] = [:]
        var findings: [PersistenceFinding] = []
        for item in items where !item.isBroken {
            let arguments = item.plistPath.flatMap { fileManager.contents(atPath: $0) }.map(SuspicionRules.programArguments(plistData:)) ?? []
            let executable = item.executablePath.flatMap { $0.hasPrefix("/") ? $0 : nil }
            // 应用注册的登录项 / 后台服务按所属应用检查；BTM 里有时记录的是包内 plist，不是程序
            let signatureTarget: String? = {
                if item.kind == .loginApp || item.kind == .appService, let app = item.appPath { return app }
                guard let executable, !executable.hasSuffix(".plist") else { return nil }
                return executable
            }()
            let isScript = signatureTarget.map(SuspicionRules.isScript(atPath:)) ?? false
            var signature: SignatureInfo?
            // 执行的是解释器（/bin/sh -c …）时检查解释器签名没有意义
            if let target = signatureTarget, !isScript, SuspicionRules.inlineInterpreter(arguments) == nil {
                if let cached = cache[target] { signature = cached } else {
                    let info = CodeSignatureInspector.inspect(path: target, validateResources: false)
                    cache[target] = info
                    signature = info
                }
            }
            let reasons = SuspicionRules.reasons(
                label: item.label,
                executable: signatureTarget ?? executable,
                arguments: arguments,
                signature: signature,
                isScript: isScript,
                home: home
            )
            guard !reasons.isEmpty else { continue }
            findings.append(PersistenceFinding(
                item: item,
                executable: executable,
                reasons: reasons,
                severity: SuspicionRules.severity(of: reasons, signature: signature)
            ))
        }
        return findings.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.item.displayName.localizedStandardCompare(rhs.item.displayName) == .orderedAscending
        }
    }

    /// /Applications 与 ~/Applications 顶层的 .app
    nonisolated static func applicationPaths(home: String) -> [String] {
        let fileManager = FileManager.default
        var paths: [String] = []
        for directory in ["/Applications", home + "/Applications"] {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for name in names.sorted() where name.hasSuffix(".app") {
                let path = directory + "/" + name
                // 跳过指向别处的替身
                if let type = try? fileManager.attributesOfItem(atPath: path)[.type] as? FileAttributeType, type == .typeSymbolicLink { continue }
                paths.append(path)
            }
        }
        return paths
    }

    nonisolated static func checkApplications(home: String) -> ([AppFinding], Int, [String]) {
        let paths = applicationPaths(home: home)
        let lock = NSLock()
        var findings: [AppFinding] = []
        var candidates: [String] = []
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            let path = paths[index]
            let info = CodeSignatureInspector.inspect(path: path, validateResources: false)
            // 应用都在 /Applications，不追究公证（Gatekeeper 首次打开时已经检查过）
            let reasons = SuspicionRules.signatureReasons(info, path: path, checkNotarization: false, isApp: true)
            lock.lock()
            defer { lock.unlock() }
            if !reasons.isEmpty {
                findings.append(AppFinding(path: path, name: LoginItemsParser.appDisplayName(path), reasons: reasons))
            } else if info.hasDeveloperIdentity, !info.isApple {
                candidates.append(path)
            }
        }
        let sorted = findings.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return (sorted, paths.count, candidates.sorted())
    }

    /// 吊销检查结果合并进应用列表
    nonisolated static func applyingRevocations(_ revoked: [String], to findings: [AppFinding]) -> [AppFinding] {
        var result = findings
        for path in revoked where !result.contains(where: { $0.path == path }) {
            result.insert(AppFinding(path: path, name: LoginItemsParser.appDisplayName(path), reasons: [.revoked]), at: 0)
        }
        return result
    }
}
