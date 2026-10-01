//
//  LoginItemsTests.swift
//  MacCleanTests
//
//  启动项：plist 解析、失效判定、launchctl 输出解析、所属应用推断、BTM 归档解析的单元测试
//

import Foundation
import Testing
@testable import MacClean

struct LoginItemsTests {

    private final class TempDir {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("LoginItemsTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        func path(_ name: String) -> String { url.appendingPathComponent(name).path }

        func touch(_ name: String) {
            let fileURL = url.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        }
    }

    private func plistData(_ dict: [String: Any]) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    // MARK: - plist

    @Test func parsesProgramArgumentsAndFlags() {
        let info = LoginItemsParser.parseLaunchPlist(plistData([
            "Label": "com.example.agent",
            "ProgramArguments": ["/Applications/Example.app/Contents/MacOS/agent", "--background"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "AssociatedBundleIdentifiers": "com.example.app",
        ]))
        #expect(info?.label == "com.example.agent")
        #expect(info?.program == "/Applications/Example.app/Contents/MacOS/agent")
        #expect(info?.runAtLoad == true)
        #expect(info?.keepAlive == true)
        #expect(info?.disabledKey == false)
        #expect(info?.associatedBundleIDs == ["com.example.app"])
    }

    @Test func programKeyWinsAndDisabledKeyRead() {
        let info = LoginItemsParser.parseLaunchPlist(plistData([
            "Label": "x.y.z",
            "Program": "/usr/local/bin/tool",
            "ProgramArguments": ["/other"],
            "KeepAlive": false,
            "Disabled": true,
        ]))
        #expect(info?.program == "/usr/local/bin/tool")
        #expect(info?.keepAlive == false)
        #expect(info?.runAtLoad == false)
        #expect(info?.disabledKey == true)
    }

    @Test func rejectsPlistWithoutLabelOrGarbage() {
        #expect(LoginItemsParser.parseLaunchPlist(plistData(["Program": "/bin/ls"])) == nil)
        #expect(LoginItemsParser.parseLaunchPlist(Data("not a plist".utf8)) == nil)
    }

    // MARK: - 失效判定

    @Test func brokenDetectionUsesFileSystem() {
        let dir = TempDir()
        dir.touch("bin/present")
        let exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        #expect(LoginItemsParser.isBroken(executable: dir.path("bin/present"), fileExists: exists) == false)
        #expect(LoginItemsParser.isBroken(executable: dir.path("bin/missing"), fileExists: exists) == true)
        // 无法判断的（相对命令 / 缺失）保守视为正常
        #expect(LoginItemsParser.isBroken(executable: nil, fileExists: exists) == false)
    }

    @Test func executableExpansion() {
        #expect(LoginItemsParser.absoluteExecutable("~/bin/tool", home: "/Users/me") == "/Users/me/bin/tool")
        #expect(LoginItemsParser.absoluteExecutable("/opt/x", home: "/Users/me") == "/opt/x")
        #expect(LoginItemsParser.absoluteExecutable("node", home: "/Users/me") == nil)
        #expect(LoginItemsParser.absoluteExecutable(nil, home: "/Users/me") == nil)
    }

    @Test func endToEndPlistInTempDir() throws {
        let dir = TempDir()
        dir.touch("App.app/Contents/MacOS/helper")
        let goodPlist = dir.path("good.plist")
        let badPlist = dir.path("bad.plist")
        try plistData(["Label": "a.b.good", "Program": dir.path("App.app/Contents/MacOS/helper")]).write(to: URL(fileURLWithPath: goodPlist))
        try plistData(["Label": "a.b.bad", "ProgramArguments": [dir.path("Gone.app/Contents/MacOS/gone")]]).write(to: URL(fileURLWithPath: badPlist))

        let exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        for (path, expectBroken) in [(goodPlist, false), (badPlist, true)] {
            let info = try #require(LoginItemsParser.parseLaunchPlist(try Data(contentsOf: URL(fileURLWithPath: path))))
            let exe = LoginItemsParser.absoluteExecutable(info.program, home: dir.url.path)
            #expect(LoginItemsParser.isBroken(executable: exe, fileExists: exists) == expectBroken)
        }
    }

    // MARK: - launchctl 输出

    @Test func parsesPrintDisabledModernAndLegacy() {
        let output = """
        \tdisabled services = {
        \t\t"com.google.keystone.user.xpcservice" => enabled
        \t\t"com.apple.ManagedClientAgent.enrollagent" => disabled
        \t\t"legacy.on" => false
        \t\t"legacy.off" => true
        \t}
        \tlogin item associations = {
        \t\t"com.foo" => weird
        \t}
        """
        let map = LoginItemsParser.parsePrintDisabled(output)
        #expect(map["com.google.keystone.user.xpcservice"] == false)
        #expect(map["com.apple.ManagedClientAgent.enrollagent"] == true)
        #expect(map["legacy.on"] == false)
        #expect(map["legacy.off"] == true)
        #expect(map["com.foo"] == nil)
        #expect(map.count == 4)
    }

    @Test func parsesRunningLabels() {
        let output = "PID\tStatus\tLabel\n-\t0\tcom.apple.idle\n3090\t0\tcom.apple.progressd\n412\t-9\thomebrew.mxcl.redis\n"
        #expect(LoginItemsParser.parseRunningLabels(output) == ["com.apple.progressd", "homebrew.mxcl.redis"])
    }

    // MARK: - 所属应用

    @Test func owningAppIsOutermostBundle() {
        #expect(LoginItemsParser.owningAppPath(forExecutable: "/Applications/Sunlogin.app/Contents/Helpers/Desktop.app/Contents/MacOS/Desktop") == "/Applications/Sunlogin.app")
        #expect(LoginItemsParser.owningAppPath(forExecutable: "/opt/homebrew/bin/redis-server") == nil)
        #expect(LoginItemsParser.owningAppPath(forExecutable: nil) == nil)
    }

    @Test func bundleIDCandidatesKeepThreeComponents() {
        #expect(LoginItemsParser.bundleIDCandidates(forLabel: "com.macpaw.CleanMyMac5.Updater") == ["com.macpaw.CleanMyMac5.Updater", "com.macpaw.CleanMyMac5"])
        #expect(LoginItemsParser.bundleIDCandidates(forLabel: "local.xray") == [])
    }

    // MARK: - BTM

    @Test func parsesGeneratedUID() {
        #expect(LoginItemsParser.parseGeneratedUID("GeneratedUID: 04b41ec7-0081-476c-8e2b-aed284f26779\n") == "04B41EC7-0081-476C-8E2B-AED284F26779")
        #expect(LoginItemsParser.parseGeneratedUID("No such key: GeneratedUID") == nil)
    }

    @Test func picksLatestBTMVersion() {
        #expect(LoginItemsParser.latestBTMFile(in: ["BackgroundItems-v9.btm", "BackgroundItems-v16.btm", "BackgroundItems-v13.btm", "other"]) == "BackgroundItems-v16.btm")
        #expect(LoginItemsParser.latestBTMFile(in: ["x.plist"]) == nil)
    }

    @Test func decodesBTMArchive() throws {
        let user = "04B41EC7-0081-476C-8E2B-AED284F26779"
        let parent = FakeItemRecord(type: 0x2, disposition: 0x2, identifier: "2.com.example.app", name: "Example", url: URL(fileURLWithPath: "/Applications/Example.app"), bundleIdentifier: "com.example.app")
        let helper = FakeItemRecord(type: 0x4, disposition: 0xb, identifier: "4.com.example.helper", name: "Helper", url: URL(string: "Contents/Library/LoginItems/Helper.app", relativeTo: URL(string: "file:///")), bundleIdentifier: "com.example.helper", container: "2.com.example.app")
        let openAtLogin = FakeItemRecord(type: 0x2, disposition: 0xb, identifier: "2.com.quark", name: "Quark", url: URL(fileURLWithPath: "/Applications/Quark.app"), bundleIdentifier: "com.quark")
        let legacy = FakeItemRecord(type: 0x10008, disposition: 0x1, identifier: "16.x", name: "ToDesk", url: URL(fileURLWithPath: "/Library/LaunchAgents/com.youqu.todesk.session.plist"))
        let storage = FakeStorage(items: [user: [parent, helper, openAtLogin, legacy], "OTHER": [parent]])

        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("Storage", for: FakeStorage.self)
        archiver.setClassName("ItemRecord", for: FakeItemRecord.self)
        archiver.encode(storage, forKey: "store")
        archiver.finishEncoding()

        let records = LoginItemsParser.parseBTM(archiver.encodedData, userKey: user)
        #expect(records.count == 4)

        let decodedHelper = try #require(records.first { $0.identifier == "4.com.example.helper" })
        #expect(decodedHelper.isAppService)
        #expect(decodedHelper.isEnabled && decodedHelper.isAllowed)
        #expect(LoginItemsParser.resolvedPath(of: decodedHelper, in: records) == "/Applications/Example.app/Contents/Library/LoginItems/Helper.app")

        #expect(records.first { $0.identifier == "2.com.quark" }?.isOpenAtLoginApp == true)
        #expect(records.first { $0.identifier == "2.com.example.app" }?.isOpenAtLoginApp == false)

        let decodedLegacy = try #require(records.first { $0.identifier == "16.x" })
        #expect(decodedLegacy.isLegacyPlist)
        #expect(!decodedLegacy.isAppService)
        #expect(!decodedLegacy.isAllowed)

        #expect(LoginItemsParser.parseBTM(Data("garbage".utf8), userKey: user).isEmpty)
    }
}

// MARK: - 模拟 BTM 归档中的类

@objc(LoginItemsTestsFakeStorage)
private final class FakeStorage: NSObject, NSCoding {
    let items: [String: [FakeItemRecord]]
    init(items: [String: [FakeItemRecord]]) { self.items = items }
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {
        coder.encode(items as NSDictionary, forKey: "itemsByUserIdentifier")
        coder.encode([:] as NSDictionary, forKey: "userSettingsByUserIdentifier")
    }
}

@objc(LoginItemsTestsFakeItemRecord)
private final class FakeItemRecord: NSObject, NSCoding {
    let type: Int
    let disposition: Int
    let identifier: String
    let name: String
    let url: URL?
    let bundleIdentifier: String?
    let container: String?

    init(type: Int, disposition: Int, identifier: String, name: String, url: URL?, bundleIdentifier: String? = nil, container: String? = nil) {
        self.type = type
        self.disposition = disposition
        self.identifier = identifier
        self.name = name
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.container = container
    }

    required init?(coder: NSCoder) { nil }

    func encode(with coder: NSCoder) {
        coder.encode(type, forKey: "type")
        coder.encode(disposition, forKey: "disposition")
        coder.encode(identifier, forKey: "identifier")
        coder.encode(name, forKey: "name")
        coder.encode(url, forKey: "url")
        coder.encode(bundleIdentifier, forKey: "bundleIdentifier")
        coder.encode(container, forKey: "container")
        coder.encode(name, forKey: "developerName")
    }
}
