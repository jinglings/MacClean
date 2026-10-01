//
//  FileRecoveryTests.swift
//  MacCleanTests
//
//  找回文件：tmutil / mount / diskutil 输出解析、挂载脚本的引号转义、来源中主目录定位、
//  「已删除文件」比对、按名称查找、恢复命名与实际复制（不覆盖、保留修改日期）。
//  不会触发管理员授权：脚本只在去掉「with administrator privileges」后以普通用户身份运行。
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MacClean

struct FileRecoveryTests {

    // MARK: - 临时目录

    private final class TempDir {
        let url: URL
        var path: String { url.path }

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("FileRecoveryTests-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        @discardableResult
        func file(_ relative: String, _ contents: String = "x", modified: Date? = nil) throws -> URL {
            let target = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: target)
            if let modified {
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
            }
            return target
        }

        func dir(_ relative: String) throws {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(relative), withIntermediateDirectories: true)
        }
    }

    // MARK: - tmutil listlocalsnapshots

    @Test func parsesLocalSnapshotsIgnoringHeaderAndOSUpdate() {
        let output = """
        Snapshots for disk /System/Volumes/Data:
        com.apple.TimeMachine.2026-10-01-120000.local
        com.apple.TimeMachine.2026-09-30-230512.local
        com.apple.os.update-2D5A6C8E9F0B1A2C3D4E5F60718293A4B5C6D7E8F90A1B2C3D4E5F6071829
        com.apple.TimeMachine.2026-10-01-120000.local
        """
        let names = RecoveryParsing.parseLocalSnapshots(output)
        #expect(names == [
            "com.apple.TimeMachine.2026-10-01-120000.local",
            "com.apple.TimeMachine.2026-09-30-230512.local",
        ])
    }

    @Test func parsesNoLocalSnapshots() {
        #expect(RecoveryParsing.parseLocalSnapshots("Snapshots for disk /System/Volumes/Data:\nNo snapshots for disk3s5").isEmpty)
        #expect(RecoveryParsing.parseLocalSnapshots("Snapshots for disk /System/Volumes/Data:\n").isEmpty)
        #expect(RecoveryParsing.parseLocalSnapshots("Snapshots for disk /:\ncom.apple.os.update-ABCDEF\n").isEmpty)
        #expect(RecoveryParsing.parseLocalSnapshots("").isEmpty)
    }

    @Test func parsesSnapshotDateInLocalTime() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let date = try #require(RecoveryParsing.parseDate(in: "com.apple.TimeMachine.2026-10-01-120000.local", timeZone: zone))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(parts.year == 2026 && parts.month == 10 && parts.day == 1)
        #expect(parts.hour == 12 && parts.minute == 0 && parts.second == 0)

        #expect(RecoveryParsing.parseDate(in: "2026-09-30-101500.backup") != nil)
        #expect(RecoveryParsing.parseDate(in: "com.apple.TimeMachine.2026-13-01-120000.local") == nil)
        #expect(RecoveryParsing.parseDate(in: "no date here") == nil)
    }

    // MARK: - tmutil listbackups / destinationinfo

    @Test func parsesBackupListBothPathStyles() {
        let stdout = """
        /Volumes/.timemachine/8E7A1F5C-1234-4D6B-9C0E-ABCDEF012345/2026-09-30-101500.backup/2026-09-30-101500.backup
        /Volumes/Backup Disk/Backups.backupdb/王的 MacBook/2026-09-29-081500
        """
        let listing = RecoveryParsing.parseBackupList(stdout: stdout)
        #expect(listing.paths.count == 2)
        #expect(listing.paths[1] == "/Volumes/Backup Disk/Backups.backupdb/王的 MacBook/2026-09-29-081500")
        #expect(!listing.needsFullDiskAccess)
        #expect(RecoveryParsing.parseDate(in: (listing.paths[0] as NSString).lastPathComponent) != nil)
        #expect(RecoveryParsing.parseDate(in: (listing.paths[1] as NSString).lastPathComponent) != nil)
    }

    @Test func backupErrorsMeanNoBackups() {
        #expect(RecoveryParsing.parseBackupList(stdout: "", stderr: "No machine directory found for host.") == BackupListing())
        #expect(RecoveryParsing.parseBackupList(stdout: "", stderr: "tmutil: No destinations configured.") == BackupListing())

        let denied = RecoveryParsing.parseBackupList(
            stdout: "",
            stderr: "No machine directory found for host.\nPOSIXError(_nsError: Error Domain=NSPOSIXErrorDomain Code=1 \"Operation not permitted\")"
        )
        #expect(denied.paths.isEmpty)
        #expect(denied.needsFullDiskAccess)
    }

    @Test func detectsTimeMachineDestination() {
        #expect(!RecoveryParsing.hasTimeMachineDestination("tmutil: No destinations configured."))
        #expect(RecoveryParsing.hasTimeMachineDestination("""
        ====================================================
        Name          : Backup Disk
        Kind          : Local
        Mount Point   : /Volumes/Backup Disk
        ID            : 8E7A1F5C-1234-4D6B-9C0E-ABCDEF012345
        """))
    }

    // MARK: - mount / diskutil

    @Test func parsesRecoveryMountsFromMountOutput() {
        let output = """
        /dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
        /dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled, nobrowse, protect, root data)
        com.apple.TimeMachine.2026-10-01-120000.local@/dev/disk3s5 on /private/tmp/macclean-recovery/com.apple.TimeMachine.2026-10-01-120000.local (apfs, local, read-only, journaled, nobrowse)
        weird name (1)@/dev/disk3s5 on /tmp/macclean-recovery/weird name (1) (apfs, local, read-only, nobrowse)
        /dev/disk5s1 on /Volumes/Tencent Lemon (hfs, local, nodev, nosuid, read-only, noowners, quarantine, mounted by wangwei)
        /dev/disk6s1 on /private/tmp/macclean-recovery-other/x (apfs, local)
        """
        let mounts = RecoveryParsing.parseRecoveryMounts(output)
        #expect(mounts.count == 2)
        #expect(mounts["com.apple.TimeMachine.2026-10-01-120000.local"] == "/private/tmp/macclean-recovery/com.apple.TimeMachine.2026-10-01-120000.local")
        #expect(mounts["weird name (1)"] == "/private/tmp/macclean-recovery/weird name (1)")
        #expect(RecoveryParsing.parseRecoveryMounts("/dev/disk3s5 on /System/Volumes/Data (apfs)").isEmpty)
    }

    @Test func parsesDeviceNodeFromDiskutilPlist() throws {
        let plist: [String: Any] = ["DeviceNode": "/dev/disk3s5", "VolumeName": "Data", "MountPoint": "/System/Volumes/Data"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(RecoveryParsing.parseDeviceNode(plist: data) == "/dev/disk3s5")
        #expect(RecoveryParsing.parseDeviceNode(plist: Data("garbage".utf8)) == nil)
    }

    // MARK: - 管理员脚本

    private static let trickyNames = [
        "com.apple.TimeMachine.2026-10-01-120000.local",
        "snap with spaces",
        "it's \"quoted\"",
        "$HOME and $(whoami)",
        "back`tick`",
        "back\\slash",
        "快照 2026",
    ]

    @Test func mountCommandsQuoteEveryArgument() {
        let commands = RecoveryAdminScript.mountCommands(snapshots: Self.trickyNames, deviceNode: "/dev/disk3s5", root: "/private/tmp/macclean-recovery")
        #expect(commands.count == Self.trickyNames.count)
        #expect(commands[0].id == "m0")
        #expect(commands[0].command == "/bin/mkdir -p '/private/tmp/macclean-recovery/com.apple.TimeMachine.2026-10-01-120000.local' && /sbin/mount_apfs -o rdonly,nobrowse -s 'com.apple.TimeMachine.2026-10-01-120000.local' '/dev/disk3s5' '/private/tmp/macclean-recovery/com.apple.TimeMachine.2026-10-01-120000.local'")
        #expect(commands[2].command.contains(#"'it'\''s "quoted"'"#))
    }

    @Test func mountScriptRejectsUnsafeInput() {
        #expect(RecoveryAdminScript.mountCommands(snapshots: ["ok"], deviceNode: "/dev/disk3s5; rm -rf /").isEmpty)
        #expect(RecoveryAdminScript.mountCommands(snapshots: ["ok"], deviceNode: "/Volumes/x").isEmpty)
        let commands = RecoveryAdminScript.mountCommands(snapshots: ["../etc", "a/b", "..", "", "line\nbreak", "fine"], deviceNode: "/dev/disk3s5")
        #expect(commands.map(\.id) == ["m5"])

        let unmount = RecoveryAdminScript.unmountCommands(mountPoints: [
            "/private/tmp/macclean-recovery/snap",
            "/System/Volumes/Data",
            "/private/tmp/macclean-recovery/../../etc",
            "/private/tmp/macclean-recovery",
        ])
        #expect(unmount.count == 1)
        #expect(unmount[0].command == "/sbin/umount '/private/tmp/macclean-recovery/snap' ; /bin/rmdir '/private/tmp/macclean-recovery/snap'")
    }

    /// 端到端验证引号：把 mkdir / mount_apfs 换成 printf 打印参数，再经 AppleScript（去掉管理员授权）与 /bin/sh 实际执行，
    /// 每个参数都必须原样到达命令，不能被 shell 展开、截断或注入。
    @Test func scriptArgumentsSurviveAppleScriptAndShell() throws {
        let commands = RecoveryAdminScript.mountCommands(snapshots: Self.trickyNames, deviceNode: "/dev/disk3s5", root: "/private/tmp/macclean-recovery")
            .map { (id: $0.id, command: $0.command
                .replacingOccurrences(of: "/bin/mkdir -p ", with: "printf '<%s>' ")
                .replacingOccurrences(of: " && /sbin/mount_apfs -o rdonly,nobrowse -s ", with: " ; printf '[%s]' ") + " ; echo") }
        var source = RecoveryAdminScript.appleScript(for: commands)
        #expect(source.contains(" with administrator privileges"))
        source = source.replacingOccurrences(of: " with administrator privileges", with: "")
        #expect(!source.contains("administrator"))

        let result = MaintenanceRunner.runProcess("/usr/bin/osascript", ["-e", source])
        #expect(result.status == 0, "\(result.stderr)")
        let parsed = MaintenanceCommands.parseBatchOutput(result.stdout)
        for (index, name) in Self.trickyNames.enumerated() {
            let mountPoint = "/private/tmp/macclean-recovery/" + name
            let entry = try #require(parsed["m\(index)"], "\(name): \(result.stdout)")
            #expect(entry.status == 0)
            #expect(entry.output == "<\(mountPoint)>[\(name)][/dev/disk3s5][\(mountPoint)]")
        }
    }

    // MARK: - 来源中的主目录

    @Test func resolvesHomeInsideBackupLayouts() throws {
        let temp = try TempDir()
        let relativeHome = "Users/tester"

        // macOS 11+ APFS 备份：<备份>/Data/Users/<name>
        try temp.dir("apfs/Data/Users/tester/Desktop")
        #expect(RecoveryPaths.homeInSource(root: temp.path + "/apfs", kind: .timeMachine, relativeHome: relativeHome) == temp.path + "/apfs/Data/Users/tester")

        // 旧格式：<备份>/Macintosh HD - Data/Users/<name>
        try temp.dir("legacy/Macintosh HD - Data/Users/tester")
        try temp.dir("legacy/Macintosh HD/Users/someone-else")
        #expect(RecoveryPaths.homeInSource(root: temp.path + "/legacy", kind: .timeMachine, relativeHome: relativeHome) == temp.path + "/legacy/Macintosh HD - Data/Users/tester")

        // 自定义卷名：<备份>/<卷名>/Users/<name>
        try temp.dir("custom/我的硬盘/Users/tester")
        #expect(RecoveryPaths.homeInSource(root: temp.path + "/custom", kind: .timeMachine, relativeHome: relativeHome) == temp.path + "/custom/我的硬盘/Users/tester")

        // 本地快照挂载点：<挂载点>/Users/<name>
        try temp.dir("snap/Users/tester")
        #expect(RecoveryPaths.homeInSource(root: temp.path + "/snap", kind: .localSnapshot, relativeHome: relativeHome) == temp.path + "/snap/Users/tester")

        // 找不到；指向来源之外的符号链接不算
        #expect(RecoveryPaths.homeInSource(root: temp.path + "/apfs", kind: .timeMachine, relativeHome: "Users/nobody") == nil)
        try temp.dir("outside/tester")
        try temp.dir("linked/Users")
        try FileManager.default.createSymbolicLink(atPath: temp.path + "/linked/Users/tester", withDestinationPath: temp.path + "/outside/tester")
        #expect(RecoveryPaths.homeInSource(root: temp.path + "/linked", kind: .localSnapshot, relativeHome: relativeHome) == nil)

        #expect(RecoveryPaths.relativeHome(URL(fileURLWithPath: "/Users/tester")) == "Users/tester")
        #expect(RecoveryPaths.relativeHome(URL(fileURLWithPath: "/System/Volumes/Data/Users/tester/")) == "Users/tester")
    }

    // MARK: - 已删除文件比对

    @Test func findsMissingFilesAndCollapsesDeletedFolders() throws {
        let temp = try TempDir()
        // 来源（快照里的主目录）
        try temp.file("source/Desktop/deleted.txt", "gone")
        try temp.file("source/Desktop/kept.txt")
        try temp.file("source/Desktop/Old Project/a.txt")
        try temp.file("source/Desktop/Old Project/sub/b.txt")
        try temp.file("source/Desktop/.secret")
        try temp.file("source/Desktop/Nested/inner-deleted.md")
        try temp.file("source/Desktop/Nested/inner-kept.md")
        try temp.file("source/Library/Caches/cache.db")
        try temp.file("source/.Trash/trashed.txt")
        try temp.file("source/Documents/报告.pdf")
        try temp.dir("outside")
        try temp.file("outside/should-not-appear.txt")
        try FileManager.default.createSymbolicLink(atPath: temp.path + "/source/Desktop/link-out", withDestinationPath: temp.path + "/outside")
        // 当前主目录
        try temp.file("current/Desktop/kept.txt")
        try temp.file("current/Desktop/Nested/inner-kept.md")
        try temp.dir("current/Documents")

        var options = RecoveryScanner.Options()
        let outcome = RecoveryScanner.scan(sourceID: "s", sourceHome: temp.path + "/source", currentHome: temp.path + "/current", options: options)
        let paths = Set(outcome.items.map(\.relativePath))
        #expect(paths == ["Desktop/deleted.txt", "Desktop/Old Project", "Desktop/Nested/inner-deleted.md", "Desktop/link-out", "Documents/报告.pdf"])
        #expect(!outcome.truncated)

        let folder = try #require(outcome.items.first { $0.relativePath == "Desktop/Old Project" })
        #expect(folder.isDirectory && folder.size == nil && !folder.existsNow)
        let file = try #require(outcome.items.first { $0.relativePath == "Desktop/deleted.txt" })
        #expect(!file.isDirectory && (file.size ?? 0) > 0)
        #expect(file.sourcePath == temp.path + "/source/Desktop/deleted.txt")

        // 包含隐藏文件；Library 与 .Trash 仍然跳过
        options.includeHidden = true
        let withHidden = RecoveryScanner.scan(sourceID: "s", sourceHome: temp.path + "/source", currentHome: temp.path + "/current", options: options)
        #expect(Set(withHidden.items.map(\.relativePath)) == paths.union(["Desktop/.secret"]))

        // 只查某个文件夹
        options.includeHidden = false
        options.relativeFolder = "Documents"
        let documents = RecoveryScanner.scan(sourceID: "s", sourceHome: temp.path + "/source", currentHome: temp.path + "/current", options: options)
        #expect(documents.items.map(\.relativePath) == ["Documents/报告.pdf"])
    }

    @Test func capsResultsPerSource() throws {
        let temp = try TempDir()
        for index in 0..<30 { try temp.file("source/Desktop/f\(index).txt") }
        try temp.dir("current/Desktop")
        var options = RecoveryScanner.Options()
        options.limit = 10
        let outcome = RecoveryScanner.scan(sourceID: "s", sourceHome: temp.path + "/source", currentHome: temp.path + "/current", options: options)
        #expect(outcome.items.count == 10)
        #expect(outcome.truncated)
    }

    // MARK: - 按名称查找

    @Test func searchesByNameWithWildcardsCaseAndDiacritics() throws {
        let temp = try TempDir()
        try temp.file("source/Documents/报告.PDF")
        try temp.file("source/Documents/Report-Final.docx")
        try temp.file("source/Documents/Café menu.txt")
        try temp.file("source/Documents/notes.txt")
        try temp.file("source/Desktop/deep/er/REPORT.key")
        try temp.file("current/Documents/Report-Final.docx")

        func search(_ term: String) -> [RecoveryItem] {
            var options = RecoveryScanner.Options()
            options.mode = .name
            options.term = term
            return RecoveryScanner.scan(sourceID: "s", sourceHome: temp.path + "/source", currentHome: temp.path + "/current", options: options).items
        }

        #expect(Set(search("report").map(\.name)) == ["Report-Final.docx", "REPORT.key"])
        #expect(search("*.pdf").map(\.name) == ["报告.PDF"])
        #expect(search("报告").map(\.name) == ["报告.PDF"])
        #expect(search("cafe").map(\.name) == ["Café menu.txt"])
        #expect(search("CAFÉ*").map(\.name) == ["Café menu.txt"])
        #expect(search("*.txt").count == 2)

        let existing = try #require(search("report-final").first)
        #expect(existing.existsNow)
        #expect(search("REPORT.key").first?.existsNow == false)
    }

    @Test func mergesIdenticalVersionsAcrossSources() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func item(_ source: String, _ path: String, size: Int64, modified: Date) -> RecoveryItem {
            RecoveryItem(sourceID: source, sourcePath: "/" + source + "/" + path, relativePath: path, isDirectory: false, isPackage: false, size: size, modified: modified, existsNow: false)
        }
        let merged = RecoveryScanner.mergeDuplicates([
            [item("new", "a.txt", size: 10, modified: date), item("new", "b.txt", size: 10, modified: date)],
            [item("old", "a.txt", size: 10, modified: date), item("old", "b.txt", size: 20, modified: date.addingTimeInterval(-60))],
        ])
        #expect(merged.count == 3)
        #expect(merged[0].sourceID == "new" && merged[0].duplicateCount == 1)
        #expect(merged.filter { $0.relativePath == "b.txt" }.count == 2)
    }

    @Test func computesDirectorySize() throws {
        let temp = try TempDir()
        try temp.file("d/a.bin", String(repeating: "a", count: 10_000))
        try temp.file("d/sub/b.bin", String(repeating: "b", count: 10_000))
        #expect(RecoveryScanner.directorySize(temp.path + "/d") >= 20_000)
    }

    // MARK: - 恢复命名

    /// 「（恢复）」后缀随界面语言本地化；两种语言下都要符合约定。
    private var isEnglish: Bool { String(localized: "（恢复）") != "（恢复）" }

    private func expected(_ base: String, _ attempt: Int, _ ext: String?) -> String {
        let suffix: String
        if isEnglish {
            suffix = attempt == 1 ? " (Recovered)" : " (Recovered \(attempt))"
        } else {
            suffix = attempt == 1 ? "（恢复）" : "（恢复 \(attempt)）"
        }
        return base + suffix + (ext.map { "." + $0 } ?? "")
    }

    @Test func restoredNames() {
        #expect(RecoveryRestorer.restoredName(for: "报告.pdf", attempt: 1) == expected("报告", 1, "pdf"))
        #expect(RecoveryRestorer.restoredName(for: "报告.pdf", attempt: 2) == expected("报告", 2, "pdf"))
        #expect(RecoveryRestorer.restoredName(for: "README", attempt: 1) == expected("README", 1, nil))
        #expect(RecoveryRestorer.restoredName(for: ".zshrc", attempt: 1) == expected(".zshrc", 1, nil))
        #expect(RecoveryRestorer.restoredName(for: "archive.tar.gz", attempt: 3) == expected("archive.tar", 3, "gz"))
        #expect(RecoveryRestorer.restoredName(for: "Project v1.2", attempt: 1, splitExtension: false) == expected("Project v1.2", 1, nil))

        if !isEnglish {
            #expect(RecoveryRestorer.restoredName(for: "报告.pdf", attempt: 1) == "报告（恢复）.pdf")
            #expect(RecoveryRestorer.restoredName(for: "报告.pdf", attempt: 2) == "报告（恢复 2）.pdf")
        }
    }

    @Test func availableDestinationNeverReusesExistingPath() {
        let original = URL(fileURLWithPath: "/Users/tester/Desktop/报告.pdf")
        var taken: Set<String> = [original.path]
        #expect(RecoveryRestorer.availableDestination(for: original, exists: { taken.contains($0) })?.lastPathComponent == expected("报告", 1, "pdf"))
        taken.insert("/Users/tester/Desktop/" + expected("报告", 1, "pdf"))
        #expect(RecoveryRestorer.availableDestination(for: original, exists: { taken.contains($0) })?.lastPathComponent == expected("报告", 2, "pdf"))
        #expect(RecoveryRestorer.availableDestination(for: original, exists: { _ in false }) == original)
    }

    @Test func removesItemsNestedInSelectedFolders() {
        func item(_ source: String, _ path: String, dir: Bool) -> RecoveryItem {
            RecoveryItem(sourceID: source, sourcePath: "/x/" + path, relativePath: path, isDirectory: dir, isPackage: false, size: nil, modified: nil, existsNow: false)
        }
        let kept = RecoveryRestorer.removingNested([
            item("a", "Desktop/Folder", dir: true),
            item("a", "Desktop/Folder/sub/file.txt", dir: false),
            item("b", "Desktop/Folder/sub/file.txt", dir: false),
            item("a", "Desktop/Folder2.txt", dir: false),
        ])
        #expect(kept.map { $0.sourceID + ":" + $0.relativePath } == ["a:Desktop/Folder", "b:Desktop/Folder/sub/file.txt", "a:Desktop/Folder2.txt"])
    }

    // MARK: - 实际复制

    @Test func restoreCopiesBackPreservingDatesAndNeverOverwrites() throws {
        let temp = try TempDir()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try temp.file("source/Desktop/报告.pdf", "snapshot version", modified: old)
        try temp.file("source/Desktop/Gone/inner.txt", "inner", modified: old)
        let home = temp.url.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Desktop"), withIntermediateDirectories: true)

        var outcome = RecoveryScanner.scan(sourceID: "s", sourceHome: temp.path + "/source", currentHome: home.path, options: .init())
        #expect(outcome.items.count == 2)

        // 第一次：原位置空着，原样复制回去（含缺失的上级文件夹）
        var report = RecoveryRestorer.restore(outcome.items, home: home)
        #expect(report.restored.count == 2 && report.failed.isEmpty)
        let restoredFile = home.appendingPathComponent("Desktop/报告.pdf")
        #expect(try String(contentsOf: restoredFile, encoding: .utf8) == "snapshot version")
        let attributes = try FileManager.default.attributesOfItem(atPath: restoredFile.path)
        #expect((attributes[.modificationDate] as? Date).map { abs($0.timeIntervalSince(old)) < 1 } == true)
        #expect(try String(contentsOf: home.appendingPathComponent("Desktop/Gone/inner.txt"), encoding: .utf8) == "inner")

        // 原位置被新内容占用：再次恢复必须另存为副本，不能覆盖
        try Data("newer work".utf8).write(to: restoredFile)
        var options = RecoveryScanner.Options()
        options.mode = .name
        options.term = "报告*"
        outcome = RecoveryScanner.scan(sourceID: "s", sourceHome: temp.path + "/source", currentHome: home.path, options: options)
        let item = try #require(outcome.items.first)
        #expect(item.existsNow)
        report = RecoveryRestorer.restore([item], home: home)
        #expect(try String(contentsOf: restoredFile, encoding: .utf8) == "newer work")
        let copy = home.appendingPathComponent("Desktop/" + expected("报告", 1, "pdf"))
        #expect(report.restored.first?.destination == copy.path)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "snapshot version")

        // 第三次 →「（恢复 2）」
        report = RecoveryRestorer.restore([item], home: home)
        #expect(report.restored.first?.destination == home.appendingPathComponent("Desktop/" + expected("报告", 2, "pdf")).path)
    }

    @Test func restoreRefusesPathsOutsideHome() throws {
        let temp = try TempDir()
        try temp.file("source/x.txt")
        let home = temp.url.appendingPathComponent("home")
        let item = RecoveryItem(sourceID: "s", sourcePath: temp.path + "/source/x.txt", relativePath: "../escaped.txt", isDirectory: false, isPackage: false, size: 1, modified: nil, existsNow: false)
        let report = RecoveryRestorer.restore([item], home: home)
        #expect(report.restored.isEmpty && report.failed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: temp.path + "/escaped.txt"))
    }
}

// MARK: - 界面截图（仅在设置 MACCLEAN_SNAPSHOT_DIR 时运行，不做像素断言）

@MainActor
struct FileRecoveryUISnapshots {
    @Test func renderRecoveryStates() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MACCLEAN_SNAPSHOT_DIR"] else { return }
        let outDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // 1. 引导页
        let intro = FileRecoveryViewModel(observesTermination: false)
        // 2. 本机真实情况（只读命令）：通常没有快照也没有备份
        let empty = FileRecoveryViewModel(observesTermination: false)
        let discovery = await Task.detached { RecoveryRunner.discover() }.value
        empty.applyDiscovery(discovery)
        // 3. 假的快照挂载点 + 假的时间机器备份，跑一次真实查找
        let fixture = try Fixture()
        let populated = FileRecoveryViewModel(home: fixture.home, observesTermination: false)
        populated.applyDiscovery(fixture.discovery)
        populated.startSearch()
        for _ in 0..<100 where !populated.hasSearched {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(300)) // 文件夹大小
        populated.selectAll(true)
        if let first = populated.sortedResults.last { populated.toggle(first) }

        for (mode, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            for (name, model) in [("intro", intro), ("empty", empty), ("results", populated)] {
                let view = ZStack {
                    AppBackdrop()
                    FileRecoveryView(viewModel: model)
                }
                .environment(\.currentAppTab, .recovery)
                .frame(width: 944, height: name == "empty" ? 820 : 900)
                try await snapshot(view, size: CGSize(width: 944, height: name == "empty" ? 820 : 900), appearance: appearance, to: outDir.appendingPathComponent("recovery-\(mode)-\(name).png"))
            }
        }
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let discovery: RecoveryDiscovery

        init() throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("FileRecoverySnap-\(UUID().uuidString)").resolvingSymlinksInPath()
            home = root.appendingPathComponent("home/tester")
            let relativeHome = RecoveryPaths.relativeHome(home)
            let snapshotRoot = root.appendingPathComponent("mnt")
            let backupRoot = root.appendingPathComponent("tm/2026-09-30-101500.backup")
            let snapHome = snapshotRoot.appendingPathComponent(relativeHome)
            let backupHome = backupRoot.appendingPathComponent("Data").appendingPathComponent(relativeHome)

            func write(_ base: URL, _ path: String, bytes: Int, daysAgo: Double) throws {
                let url = base.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(count: bytes).write(to: url)
                try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
            }
            for base in [snapHome, backupHome] {
                try write(base, "Desktop/季度报告 Q3.pdf", bytes: 2_400_000, daysAgo: 0.3)
                try write(base, "Desktop/截屏 2026-09-30 下午3.12.png", bytes: 820_000, daysAgo: 1.2)
                try write(base, "Documents/合同/租房合同-扫描件.pdf", bytes: 5_600_000, daysAgo: 12)
                try write(base, "Documents/毕业论文 终稿/第一章.docx", bytes: 310_000, daysAgo: 30)
                try write(base, "Documents/毕业论文 终稿/参考文献.bib", bytes: 42_000, daysAgo: 31)
                try write(base, "Downloads/Keynote 模板.key", bytes: 18_000_000, daysAgo: 4)
            }
            try write(backupHome, "Pictures/旅行 2026/IMG_2041.HEIC", bytes: 3_100_000, daysAgo: 20)
            try write(snapHome, "Desktop/读书笔记.md", bytes: 12_000, daysAgo: 0.1)
            // 当前主目录：文件夹都在，只是上面这些文件没了
            for folder in ["Desktop", "Documents", "Downloads", "Pictures"] {
                try fm.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
            }

            let mounted = "com.apple.TimeMachine.2026-10-01-090012.local"
            let unmounted = "com.apple.TimeMachine.2026-09-30-153004.local"
            var discovery = RecoveryDiscovery()
            discovery.sources = [
                RecoverySource(kind: .localSnapshot, name: mounted, date: RecoveryParsing.parseDate(in: mounted)),
                RecoverySource(kind: .localSnapshot, name: unmounted, date: RecoveryParsing.parseDate(in: unmounted)),
                RecoverySource(kind: .timeMachine, name: backupRoot.path, date: RecoveryParsing.parseDate(in: backupRoot.lastPathComponent)),
            ]
            discovery.mountedSnapshots = [mounted: snapshotRoot.path]
            discovery.timeMachineConfigured = true
            discovery.dataDeviceNode = "/dev/disk3s5"
            self.discovery = discovery
        }
    }

    private func snapshot<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL) async throws {
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
