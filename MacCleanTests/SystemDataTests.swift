//
//  SystemDataTests.swift
//  MacCleanTests
//
//  系统数据：路径清单、阈值与状态、去重（嵌套 / 硬链接 / 克隆）、无法测量、可清除空间、
//  命令输出解析、「其他」不为负；以及用合成数据渲染结果页截图。
//

import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import MacClean

struct SystemDataTests {

    private final class FakeDisk {
        let url: URL
        var home: String { url.path + "/home" }
        var root: String { url.path + "/root" }

        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("SystemDataTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(atPath: url.path + "/home", withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: url.path + "/root", withIntermediateDirectories: true)
        }

        deinit {
            // 恢复权限后再删除
            chmodRecursively(url.path)
            try? FileManager.default.removeItem(at: url)
        }

        private func chmodRecursively(_ path: String) {
            chmod(path, 0o755)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
            for name in names {
                var info = stat()
                let child = path + "/" + name
                if lstat(child, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR { chmodRecursively(child) }
            }
        }

        @discardableResult
        func file(_ path: String, bytes: Int) -> String {
            let fileURL = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 非零随机内容，避免被文件系统压缩影响分配大小
            var data = Data(count: bytes)
            data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
            try? data.write(to: fileURL)
            return path
        }

        func inHome(_ relative: String, bytes: Int) -> String { file(home + "/" + relative, bytes: bytes) }
        func inRoot(_ absolute: String, bytes: Int) -> String { file(root + absolute, bytes: bytes) }

        func environment(total: Int64 = 1_000_000_000_000, available: Int64 = 400_000_000_000, important: Int64 = 450_000_000_000) -> SystemDataEnvironment {
            SystemDataEnvironment(
                home: home,
                root: root,
                physicalMemory: 16 * 1_073_741_824,
                volume: { SystemDataVolume(name: "Test HD", total: total, available: available, availableForImportantUsage: important) },
                localSnapshots: { ["com.apple.TimeMachine.2026-09-30-101500.local"] },
                timeMachineDestinationInfo: { "tmutil: No destinations configured." },
                apfsVolumes: { [APFSVolumeUsage(name: "Macintosh HD", roles: ["System"], used: 12_000_000_000)] },
                appNames: { ["com.example.chat": "Example Chat"] }
            )
        }
    }

    private static func allocated(_ path: String) -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return Int64(info.st_blocks) * 512
    }

    private static let gb = SystemDataCatalog.gb

    // MARK: - 路径清单

    @Test func specsResolveAgainstFakeHomeAndRoot() {
        let specs = SystemDataCatalog.specs(home: "/fake/home", root: "/fake/root")
        func paths(_ id: SystemDataCategoryID) -> [String] { specs.first { $0.id == id }?.paths ?? [] }

        #expect(paths(.spotlight) == ["/fake/home/Library/Metadata/CoreSpotlight", "/fake/root/System/Volumes/Data/.Spotlight-V100"])
        #expect(paths(.mediaAnalysis).first == "/fake/home/Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches")
        #expect(paths(.iosBackups) == ["/fake/home/Library/Application Support/MobileSync/Backup"])
        #expect(paths(.xcode).contains("/fake/home/Library/Developer/Xcode/DerivedData"))
        #expect(paths(.xcode).contains("/fake/root/Library/Developer/CoreSimulator/Volumes"))
        #expect(paths(.virtualMachines).first == "/fake/home/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        #expect(paths(.aiModels).contains("/fake/home/.ollama/models"))
        #expect(paths(.logs).contains("/fake/root/private/var/log"))
        #expect(paths(.trash) == ["/fake/home/.Trash"])
        #expect(paths(.virtualMemory) == ["/fake/root/private/var/vm"])
        #expect(paths(.commandLineTools) == ["/fake/root/opt", "/fake/root/usr/local"])
        #expect(paths(.tempFiles) == ["/fake/root/private/var/folders"])
        #expect(paths(.applications) == ["/fake/root/Applications", "/fake/home/Applications"])
        #expect(paths(.personalFiles) == ["/fake/home", "/fake/home/Library/Mobile Documents"])
        #expect(paths(.otherUsers) == ["/fake/root/Users/*"])
        #expect(SystemDataCatalog.skippedPaths(home: "/fake/home") == ["/fake/home/Library"])
        // 对照项排在最后，嵌套路径（如 ~/.ollama/models）先被具体类别认领
        #expect(specs.suffix(3).map(\.id) == [.applications, .personalFiles, .otherUsers])
        // 每个可测量的类别都有清单；快照 / Time Machine / macOS / 其他 由命令与容量计算
        let listed = Set(specs.map(\.id))
        #expect(listed == Set(SystemDataCategoryID.allCases).subtracting([.snapshots, .timeMachine, .macOS, .other]))
    }

    @Test func expandsInstallerGlob() {
        let disk = FakeDisk()
        disk.inRoot("/Applications/Install macOS Sequoia.app/Contents/Info.plist", bytes: 100)
        disk.inRoot("/Applications/Install macOS Tahoe.app/Contents/Info.plist", bytes: 100)
        disk.inRoot("/Applications/Safari.app/Contents/Info.plist", bytes: 100)

        let expanded = SystemDataCatalog.expand(disk.root + "/Applications/Install macOS*.app")
        #expect(expanded == [disk.root + "/Applications/Install macOS Sequoia.app", disk.root + "/Applications/Install macOS Tahoe.app"])
        #expect(SystemDataCatalog.expand(disk.root + "/Missing/Install*.app").isEmpty)
        #expect(SystemDataCatalog.expand("/plain/path") == ["/plain/path"])
    }

    // MARK: - 阈值与状态

    @Test func spotlightAndMediaThresholds() {
        let specs = SystemDataCatalog.specs(home: "/h")
        let spotlight = specs.first { $0.id == .spotlight }!.thresholds
        #expect(SystemDataRules.status(size: 12 * Self.gb, thresholds: spotlight) == .abnormal)
        #expect(SystemDataRules.status(size: 3 * Self.gb, thresholds: spotlight) == .normal)
        #expect(SystemDataRules.status(size: 7 * Self.gb, thresholds: spotlight) == .large)
        #expect(SystemDataRules.status(size: 10 * Self.gb, thresholds: spotlight) == .large) // 恰好 10 GB 不算异常

        let media = specs.first { $0.id == .mediaAnalysis }!.thresholds
        #expect(SystemDataRules.status(size: 6 * Self.gb, thresholds: media) == .abnormal)
        #expect(SystemDataRules.status(size: 1 * Self.gb, thresholds: media) == .normal)

        let caches = specs.first { $0.id == .appCaches }!.thresholds
        #expect(SystemDataRules.status(size: 50 * Self.gb, thresholds: caches) == .large) // 只有「偏大」一级
        #expect(SystemDataRules.status(size: 100 * Self.gb, thresholds: .none) == .normal)
    }

    @Test func actionsFollowStatus() {
        #expect(SystemDataRules.actions(for: .spotlight, status: .abnormal, firstExistingPath: nil) == [.openTab(.maintenance)])
        #expect(SystemDataRules.actions(for: .spotlight, status: .normal, firstExistingPath: nil) == [.automatic])
        #expect(SystemDataRules.actions(for: .snapshots, status: .normal, firstExistingPath: nil) == [.openTab(.recovery), .openTab(.maintenance)])
        #expect(SystemDataRules.actions(for: .virtualMachines, status: .normal, firstExistingPath: "/d", hasDocker: true) == [.openTab(.appStorage), .revealInFinder("/d")])
        #expect(SystemDataRules.actions(for: .installers, status: .normal, firstExistingPath: "/Applications/Install macOS X.app") == [.revealInFinder("/Applications/Install macOS X.app")])
        #expect(SystemDataRules.actions(for: .installers, status: .normal, firstExistingPath: "/Library/Updates") == [.automatic])
        #expect(SystemDataRules.actions(for: .systemAssets, status: .large, firstExistingPath: "/x") == [.systemManaged])
    }

    // MARK: - 可清除空间与「其他」

    @Test func purgeableFromCapacities() {
        let volume = SystemDataVolume(name: "HD", total: 1_000, available: 100, availableForImportantUsage: 250)
        #expect(volume.purgeable == 150)
        #expect(volume.used == 750)
        #expect(volume.usedOnDisk == 900)
        #expect(SystemDataRules.purgeable(available: 300, availableForImportantUsage: 200) == 0)
        #expect(SystemDataVolume(name: "HD", total: 1_000, available: 300, availableForImportantUsage: 200).used == 700)
    }

    @Test func residualNeverNegative() {
        #expect(SystemDataRules.residual(usedOnDisk: 100, explained: 40) == 60)
        #expect(SystemDataRules.residual(usedOnDisk: 10, explained: 50) == 0)
        #expect(SystemDataRules.residual(usedOnDisk: 0, explained: 0) == 0)
    }

    // MARK: - 去重

    @Test func plannerExcludesNestedClaims() {
        let tasks = SystemDataPlanner.plan([
            (.virtualMachines, "/h/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"),
            (.virtualMachines, "/h/Library/Containers/com.docker.docker"),
            (.appData, "/h/Library/Containers"),
            (.appData, "/h/Library/Containers/"), // 重复（尾部斜杠）
            (.trash, "/h/.Trash"),
        ])
        #expect(tasks.count == 4)
        let containers = tasks.first { $0.path == "/h/Library/Containers" }!
        #expect(containers.excluding == ["/h/Library/Containers/com.docker.docker", "/h/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"])
        let docker = tasks.first { $0.path == "/h/Library/Containers/com.docker.docker" }!
        #expect(docker.excluding == ["/h/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"])
        #expect(tasks.first { $0.path == "/h/.Trash" }!.excluding.isEmpty)
        // 主目录扣除 ~/Library（不归任何类别）与已认领的路径；~/Library 下单独认领的 iCloud 云盘照常测量
        let home = SystemDataPlanner.plan([
            (.aiModels, "/h/.ollama/models"),
            (.trash, "/h/.Trash"),
            (.personalFiles, "/h"),
            (.personalFiles, "/h/Library/Mobile Documents"),
        ], skipping: ["/h/Library"])
        #expect(home.first { $0.path == "/h" }!.excluding == ["/h/.ollama/models", "/h/.Trash", "/h/Library/Mobile Documents", "/h/Library"])
        #expect(home.contains { $0.path == "/h/Library/Mobile Documents" && $0.category == .personalFiles })
        #expect(!home.contains { $0.path == "/h/Library" })

        // 不把同名前缀的兄弟目录当成嵌套
        let siblings = SystemDataPlanner.plan([(.logs, "/a/Logs"), (.logs, "/a/LogsArchive")])
        #expect(siblings.allSatisfy { $0.excluding.isEmpty })
    }

    @Test func analyzeCountsEachByteOnce() async throws {
        let disk = FakeDisk()
        let docker = disk.inHome("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", bytes: 3_000_000)
        let dockerOther = disk.inHome("Library/Containers/com.docker.docker/Data/log.txt", bytes: 200_000)
        let media = disk.inHome("Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches/blob", bytes: 1_500_000)
        let chat = disk.inHome("Library/Containers/com.example.chat/Data/db.sqlite", bytes: 2_500_000)
        let backup = disk.inHome("Library/Application Support/MobileSync/Backup/0000/Manifest.db", bytes: 1_000_000)
        let support = disk.inHome("Library/Application Support/Example/data.bin", bytes: 400_000)
        let cache = disk.inHome("Library/Caches/com.example/cache.bin", bytes: 700_000)
        let trash = disk.inHome(".Trash/old.zip", bytes: 900_000)
        let systemLog = disk.inRoot("/private/var/log/system.log", bytes: 300_000)

        // 硬链接：同一 inode 出现在缓存与废纸篓里，只计一次
        let linkSource = disk.inHome("Library/Caches/com.example/shared.bin", bytes: 600_000)
        #expect(link(linkSource, disk.home + "/.Trash/shared-link.bin") == 0)

        // APFS 克隆：共享块只计一次
        let cloneSource = disk.inHome("Library/Caches/com.example/big.bin", bytes: 2_000_000)
        let cloned = clonefile(cloneSource, disk.home + "/.Trash/big-clone.bin", 0) == 0

        // 主目录里的个人文件、本地 AI 模型与 iCloud 云盘本地副本
        let document = disk.inHome("Documents/report.pdf", bytes: 1_200_000)
        let download = disk.inHome("Downloads/setup.dmg", bytes: 800_000)
        let model = disk.inHome(".ollama/models/blobs/sha256-abc", bytes: 4_000_000)
        let ollamaKey = disk.inHome(".ollama/id_ed25519", bytes: 100_000)
        let iCloud = disk.inHome("Library/Mobile Documents/com~apple~CloudDocs/notes.txt", bytes: 300_000)
        let app = disk.inRoot("/Applications/Example.app/Contents/MacOS/Example", bytes: 900_000)
        let installer = disk.inRoot("/Applications/Install macOS Tahoe.app/Contents/SharedSupport/SharedSupport.dmg", bytes: 1_100_000)
        let otherUser = disk.inRoot("/Users/alice/Public/shared.txt", bytes: 250_000)
        disk.inRoot("/Users/.localized", bytes: 10)

        let report = try await SystemDataAnalyzer.analyze(environment: disk.environment())
        func size(_ id: SystemDataCategoryID) -> Int64? { report.categories.first { $0.id == id }?.size }

        let a = Self.allocated
        #expect(size(.virtualMachines)! >= a(docker) + a(dockerOther))
        #expect(size(.mediaAnalysis)! >= a(media))
        #expect(size(.iosBackups)! >= a(backup))
        // 应用数据不包含已归入其他类别的 Docker、媒体分析缓存与 iOS 备份
        let appData = size(.appData)!
        #expect(appData >= a(chat) + a(support))
        #expect(appData < a(chat) + a(support) + a(docker) / 2)
        #expect(size(.logs)! >= a(systemLog))

        // 硬链接 + 克隆：缓存与废纸篓合计不超过「各自只算一次」的大小（加上目录本身的少量块）
        let cachePlusTrash = size(.appCaches)! + size(.trash)!
        let uniqueBytes = a(cache) + a(trash) + a(linkSource) + a(cloneSource)
        #expect(cachePlusTrash >= uniqueBytes)
        #expect(cachePlusTrash < uniqueBytes + a(linkSource) / 2)
        if cloned {
            #expect(cachePlusTrash < uniqueBytes + a(cloneSource) / 2)
        }

        // 个人文件：主目录减去 ~/Library、废纸篓与 ~/.ollama/models；iCloud 云盘本地副本计在这里
        let personal = size(.personalFiles)!
        let personalBytes = a(document) + a(download) + a(ollamaKey) + a(iCloud)
        #expect(personal >= personalBytes)
        #expect(personal < personalBytes + a(model) / 2)
        #expect(size(.aiModels)! >= a(model))
        let personalEntries = report.categories.first { $0.id == .personalFiles }!.entries
        #expect(personalEntries.contains { $0.name == String(localized: "iCloud 云盘（本地副本）") && $0.size >= a(iCloud) })
        #expect(personalEntries.contains { $0.name == String(localized: "文稿") && $0.size >= a(document) })
        #expect(appData < a(chat) + a(support) + a(iCloud) / 2 + a(docker) / 2)

        // 应用程序不含已计入「macOS 安装器」的 Install macOS*.app；其他用户只测 /Users 下的目录
        #expect(size(.applications)! >= a(app))
        #expect(size(.applications)! < a(app) + a(installer) / 2)
        #expect(size(.installers)! >= a(installer))
        #expect(size(.otherUsers)! >= a(otherUser))
        #expect(report.categories.first { $0.id == .otherUsers }!.entries.map(\.name) == ["alice"])
        #expect(report.comparisonTotal == size(.applications)! + personal + size(.otherUsers)!)

        // 应用数据的前几名按应用名聚合
        let apps = report.categories.first { $0.id == .appData }!.entries
        #expect(apps.first?.name == "Example Chat")

        // 快照 / Time Machine / macOS 卷来自注入的环境
        let snapshots = report.categories.first { $0.id == .snapshots }!
        #expect(snapshots.size == 50_000_000_000)
        #expect(snapshots.snapshotNames == ["com.apple.TimeMachine.2026-09-30-101500.local"])
        #expect(report.categories.first { $0.id == .timeMachine }?.timeMachineConfigured == false)
        #expect(size(.macOS) == 12_000_000_000)

        // 系统数据在前、对照项随后、「其他」固定最后；「其他」= 实际占用 − 系统数据 − 对照项
        #expect(report.categories.last?.id == .other)
        let firstComparison = report.categories.firstIndex { $0.id.isComparison }!
        #expect(report.categories[..<firstComparison].allSatisfy { !$0.id.isComparison })
        #expect(report.categories[firstComparison..<(report.categories.count - 1)].allSatisfy { $0.id.isComparison })
        #expect(size(.other) == report.volume.usedOnDisk - report.explained - report.comparisonTotal)
        #expect(!report.categories.contains { $0.id == .personalFiles && $0.status != .normal })
    }

    // MARK: - 两阶段

    private final class PartialBox: @unchecked Sendable {
        private let lock = NSLock()
        private var reports: [SystemDataReport] = []
        func append(_ report: SystemDataReport) { lock.lock(); reports.append(report); lock.unlock() }
        var all: [SystemDataReport] { lock.lock(); defer { lock.unlock() }; return reports }
    }

    @Test func systemDataArrivesBeforeComparison() async throws {
        let disk = FakeDisk()
        disk.inHome("Library/Caches/com.example/cache.bin", bytes: 700_000)
        disk.inHome("Documents/report.pdf", bytes: 1_200_000)
        disk.inRoot("/Applications/Example.app/Contents/MacOS/Example", bytes: 900_000)

        let box = PartialBox()
        let report = try await SystemDataAnalyzer.analyze(environment: disk.environment(), onSystemData: { box.append($0) })

        #expect(box.all.count == 1)
        let partial = box.all[0]
        #expect(partial.comparisonPending)
        #expect(!partial.categories.contains { $0.id.isComparison || $0.id == .other })
        #expect(partial.explained == report.explained)
        #expect(partial.comparisonTotal == 0)
        #expect(partial.systemDataDuration <= report.duration)
        #expect(!report.comparisonPending)
        #expect(report.categories.contains { $0.id == .personalFiles } && report.categories.last?.id == .other)
    }

    @Test func cancellingDuringComparisonStopsBothPhases() async throws {
        let disk = FakeDisk()
        disk.inHome("Documents/report.pdf", bytes: 1_200_000)
        let box = PartialBox()
        let task = Task {
            try await SystemDataAnalyzer.analyze(environment: disk.environment(), onSystemData: { partial in
                box.append(partial)
                // 模拟用户在第一阶段结果出现后点「停止」
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(box.all.count == 1)
    }

    @Test func residualClampsInAnalyze() async throws {
        let disk = FakeDisk()
        disk.inHome("Library/Caches/x.bin", bytes: 2_000_000)
        // 容量小于已解释部分（例如测量期间写入了数据）：「其他」为 0 而不是负数
        let report = try await SystemDataAnalyzer.analyze(environment: disk.environment(total: 1_000, available: 900, important: 900))
        #expect(report.categories.first { $0.id == .other }?.size == 0)
    }

    // MARK: - 无法测量

    @Test func unreadablePathIsUnmeasurableNotGuessed() async throws {
        let disk = FakeDisk()
        let locked = disk.home + "/Library/Mail"
        disk.inHome("Library/Mail/V10/mail.emlx", bytes: 500_000)
        chmod(locked, 0)
        defer { chmod(locked, 0o755) }

        let deduper = DiskAnalyzer.UsageDeduper()
        let measurement = try await DiskAnalyzer.measureUsage(atPath: locked, deduper: deduper)
        #expect(measurement.access == .deniedByOwner)
        #expect(measurement.size == 0)
        #expect(try await DiskAnalyzer.measureUsage(atPath: disk.home + "/nope", deduper: deduper).access == .missing)

        let report = try await SystemDataAnalyzer.analyze(environment: disk.environment())
        let mail = report.categories.first { $0.id == .mailMessages }!
        #expect(mail.size == nil)
        #expect(mail.unmeasured == [SystemDataUnmeasured(path: locked, reason: .admin)])
        // 无法测量的类别排在同组有大小的类别之后
        let index = report.categories.firstIndex { $0.id == .mailMessages }!
        #expect(report.categories[..<index].allSatisfy { ($0.size != nil || $0.id == .timeMachine) && !$0.id.isComparison })

        // 类别中只有部分路径不可读：仍给出已测量部分的大小，并列出不可读的路径
        let partial = SystemDataAnalyzer.categoryResult(
            spec: SystemDataCatalog.specs(home: disk.home).first { $0.id == .spotlight }!,
            parts: [
                (path: "/a", result: DiskAnalyzer.UsageMeasurement(access: .measured, size: 3 * Self.gb)),
                (path: "/b", result: DiskAnalyzer.UsageMeasurement(access: .deniedByPrivacy)),
            ],
            appNames: [:]
        )
        #expect(partial.size == 3 * Self.gb)
        #expect(partial.status == .normal)
        #expect(partial.unmeasured == [SystemDataUnmeasured(path: "/b", reason: .fullDiskAccess)])
    }

    // MARK: - 解析

    @Test func parsesTmutilOutputs() {
        let output = """
        Snapshots for disk /System/Volumes/Data:
        com.apple.TimeMachine.2026-09-29-090000.local
        com.apple.TimeMachine.2026-09-30-101500.local
        com.apple.os.update-ABCDEF
        """
        #expect(RecoveryParsing.parseLocalSnapshots(output) == [
            "com.apple.TimeMachine.2026-09-29-090000.local", "com.apple.TimeMachine.2026-09-30-101500.local",
        ])
        #expect(RecoveryParsing.parseLocalSnapshots("Snapshots for disk /System/Volumes/Data:\n").isEmpty)

        #expect(SystemDataRules.timeMachineConfigured(destinationInfoOutput: "tmutil: No destinations configured.") == false)
        #expect(SystemDataRules.timeMachineConfigured(destinationInfoOutput: """
        ====================================================
        Name          : Backup
        Kind          : Local
        ID            : 1234
        """) == true)
        #expect(SystemDataRules.timeMachineConfigured(destinationInfoOutput: "") == nil)
    }

    @Test func parsesDiskutilPlists() throws {
        let list: [String: Any] = ["Containers": [[
            "Volumes": [
                ["Name": "Macintosh HD", "Roles": ["System"], "CapacityInUse": 12_570_345_472],
                ["Name": "Preboot", "Roles": ["Preboot"], "CapacityInUse": 10_807_230_464],
                ["Name": "Data", "Roles": ["Data"], "CapacityInUse": 757_368_475_648],
                ["Name": "VM", "Roles": ["VM"], "CapacityInUse": 1_076_658_176],
            ],
        ]]]
        let data = try PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0)
        let volumes = SystemDataRules.parseAPFSVolumes(plist: data)
        #expect(volumes.count == 4)
        #expect(SystemDataRules.macOSVolumesUsage(volumes).map(\.name) == ["Macintosh HD", "Preboot"])

        let info = try PropertyListSerialization.data(fromPropertyList: ["APFSContainerReference": "disk3"], format: .xml, options: 0)
        #expect(SystemDataRules.parseContainerReference(plist: info) == "disk3")
        #expect(SystemDataRules.parseAPFSVolumes(plist: Data("garbage".utf8)).isEmpty)
    }

    @Test func appKeysStripGroupPrefixes() {
        #expect(SystemDataRules.appKey(forFolderName: "UBF8T346G9.Office", metadataIdentifier: nil) == "Office")
        #expect(SystemDataRules.appKey(forFolderName: "group.com.docker", metadataIdentifier: nil) == "com.docker")
        #expect(SystemDataRules.appKey(forFolderName: "0a3ab1c4-uuid", metadataIdentifier: "com.example.app") == "com.example.app")
        #expect(SystemDataRules.appKey(forFolderName: "Google", metadataIdentifier: nil) == "Google")
        #expect(SystemDataRules.isIntelligenceAsset("com_apple_MobileAsset_UAF_Siri_Understanding"))
        #expect(!SystemDataRules.isIntelligenceAsset("com_apple_MobileAsset_Font8"))
    }

    // MARK: - 真机只读测量（仅在设置环境变量时运行，只打印类别与大小，不打印文件名）

    @Test func liveAnalysisTiming() async throws {
        guard ProcessInfo.processInfo.environment["MACCLEAN_SYSTEMDATA_LIVE"] == "1" else { return }
        let report = try await SystemDataAnalyzer.analyze()
        func gb(_ v: Int64?) -> String { v.map { String(format: "%.1f GB", Double($0) / 1e9) } ?? "unmeasurable" }
        var lines = ["SYSTEMDATA phase1=\(String(format: "%.1f", report.systemDataDuration))s", "SYSTEMDATA duration=\(String(format: "%.1f", report.duration))s total=\(gb(report.volume.total)) usedOnDisk=\(gb(report.volume.usedOnDisk)) purgeable=\(gb(report.volume.purgeable)) explained=\(gb(report.explained))"]
        for category in report.categories {
            lines.append("SYSTEMDATA \(category.id.rawValue) \(gb(category.size)) status=\(category.status) unmeasured=\(category.unmeasured.count) unreadableDirs=\(category.unreadableDirectories)")
        }
        let text = lines.joined(separator: "\n")
        print(text)
        if let out = ProcessInfo.processInfo.environment["MACCLEAN_SYSTEMDATA_OUT"] {
            try text.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - 合成数据截图

@MainActor
struct SystemDataSnapshotTests {
    private static let gb = SystemDataCatalog.gb

    static func syntheticReport() -> SystemDataReport {
        let specs = SystemDataCatalog.specs(home: "/Users/demo", physicalMemory: 16 * 1_073_741_824)
        func thresholds(_ id: SystemDataCategoryID) -> SystemDataThresholds { specs.first { $0.id == id }?.thresholds ?? .none }
        func category(_ id: SystemDataCategoryID, _ gb: Double?, entries: [(String, Double)] = [], status: SystemDataStatus? = nil) -> SystemDataCategoryResult {
            let size = gb.map { Int64($0 * 1e9) }
            let st = status ?? size.map { SystemDataRules.status(size: $0, thresholds: thresholds(id)) } ?? .normal
            return SystemDataCategoryResult(
                id: id, size: size, status: st, thresholds: thresholds(id),
                entries: entries.map { SystemDataEntry(name: $0.0, path: "/Users/demo/\($0.0)", size: Int64($0.1 * 1e9)) },
                actions: SystemDataRules.actions(for: id, status: st, firstExistingPath: "/Users/demo/x", hasDocker: id == .virtualMachines)
            )
        }
        var spotlight = category(.spotlight, 38.4, entries: [("CoreSpotlight", 38.4)])
        spotlight.unmeasured = [SystemDataUnmeasured(path: "/System/Volumes/Data/.Spotlight-V100", reason: .admin)]
        var snapshots = category(.snapshots, 24.6, status: .normal)
        snapshots.snapshotNames = ["com.apple.TimeMachine.2026-09-30-101500.local", "com.apple.TimeMachine.2026-10-01-091200.local"]
        snapshots.thresholds = SystemDataRules.snapshotThresholds(total: 494 * gb)
        snapshots.actions = [.openTab(.recovery), .openTab(.maintenance)]
        var tm = SystemDataCategoryResult(id: .timeMachine, size: nil, actions: SystemDataRules.actions(for: .timeMachine, status: .normal, firstExistingPath: nil))
        tm.timeMachineConfigured = false
        var assets = category(.systemAssets, 9.8, entries: [("UAF_Siri_Understanding", 2.6), ("LinguisticData", 1.2), ("Font8", 1.1)])
        assets.intelligenceSize = Int64(3.1e9)
        var mail = SystemDataCategoryResult(id: .mailMessages, size: nil, actions: SystemDataRules.actions(for: .mailMessages, status: .normal, firstExistingPath: nil))
        mail.unmeasured = [SystemDataUnmeasured(path: "/Users/demo/Library/Mail", reason: .fullDiskAccess)]

        let categories = [
            spotlight,
            category(.appData, 31.2, entries: [("Example Chat", 14.2), ("Photo Editor", 6.1), ("Browser", 4.4), ("Notes App", 2.0), ("Music", 1.3)]),
            snapshots,
            category(.virtualMachines, 22.0, entries: [("Docker.raw", 21.1), ("com.docker.docker", 0.9)]),
            category(.xcode, 18.7, entries: [("DerivedData", 9.2), ("Devices", 6.1), ("iOS DeviceSupport", 3.4)]),
            category(.macOS, 26.0, entries: [("Macintosh HD", 12.6), ("Preboot", 10.8), ("Recovery", 2.6)]),
            category(.aiModels, 12.4, entries: [("models", 8.4), ("huggingface", 4.0)]),
            assets,
            category(.appCaches, 6.3),
            category(.mediaAnalysis, 6.8, entries: [("com.apple.mediaanalysisd", 6.8)]),
            category(.logs, 2.9),
            category(.virtualMemory, 3.2),
            category(.trash, 1.4),
            category(.iosBackups, 0.8),
            category(.installers, 0.4),
            tm,
            mail,
            category(.commandLineTools, 14.6, entries: [("homebrew", 12.9), ("local", 1.7)]),
            category(.tempFiles, 2.1),
            category(.applications, 38.2, entries: [("Xcode", 12.1), ("Final Cut Pro", 6.3), ("Microsoft Word", 2.4)]),
            category(.personalFiles, 96.5, entries: [("文稿", 31.0), ("下载", 22.4), ("图片", 18.9), ("iCloud 云盘（本地副本）", 9.6), ("桌面", 6.1), ("其他", 8.5)]),
            category(.otherUsers, 1.3, entries: [("Shared", 1.3)]),
            category(.other, 16.4),
        ]
        let volume = SystemDataVolume(name: "Macintosh HD", total: 494 * gb, available: 120 * gb, availableForImportantUsage: Int64(144.6e9))
        return SystemDataReport(volume: volume, categories: SystemDataAnalyzer.sortCategories(categories), duration: 18)
    }

    @Test func renderSystemDataStates() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MACCLEAN_SNAPSHOT_DIR"] else { return }
        let outDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // 用独立的 UserDefaults 套件切到「系统数据」，不改动 App 的真实设置
        let suite = "SystemDataSnapshotTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(StorageMapMode.systemData.rawValue, forKey: StorageMapMode.storageKey)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let model = SystemDataViewModel.shared
        let language = Locale.current.language.languageCode?.identifier ?? "xx"
        for (mode, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            // 引导页：完整窗口（含侧栏与模式切换）
            model.report = nil
            model.phase = .intro
            AppState.shared.currentTab = .diskAnalysis
            try await snapshot(
                ContentView().environmentObject(AppState.shared).defaultAppStorage(defaults).frame(width: 1180, height: 760),
                size: CGSize(width: 1180, height: 760), appearance: appearance,
                to: outDir.appendingPathComponent("\(language)-\(mode)-systemdata-intro.png")
            )

            // 结果页：合成数据，展开两项
            model.show(Self.syntheticReport())
            model.expanded = [.spotlight, .snapshots, .personalFiles]
            try await snapshot(
                ContentView().environmentObject(AppState.shared).defaultAppStorage(defaults).frame(width: 1180, height: 760),
                size: CGSize(width: 1180, height: 760), appearance: appearance,
                to: outDir.appendingPathComponent("\(language)-\(mode)-systemdata-results.png")
            )
            // 长截图看完整列表
            try await snapshot(
                SystemDataView(viewModel: model).environment(\.currentAppTab, .diskAnalysis).defaultAppStorage(defaults).frame(width: 944, height: 3700),
                size: CGSize(width: 944, height: 3700), appearance: appearance,
                to: outDir.appendingPathComponent("\(language)-\(mode)-systemdata-full.png")
            )

            // 第二阶段进行中：系统数据已显示，对照项各自显示进度
            var partial = Self.syntheticReport()
            partial.categories.removeAll { $0.id.isComparison || $0.id == .other }
            partial.comparisonPending = true
            model.show(partial)
            model.expanded = []
            model.comparisonStopped = false
            model.scanStates = [.applications: .done(Int64(38.2e9)), .personalFiles: .measuring, .otherUsers: .measuring, .other: .measuring]
            model.categoryBytes = [.applications: Int64(38.2e9), .personalFiles: Int64(41.7e9)]
            try await snapshot(
                ContentView().environmentObject(AppState.shared).defaultAppStorage(defaults).frame(width: 1180, height: 760),
                size: CGSize(width: 1180, height: 760), appearance: appearance,
                to: outDir.appendingPathComponent("\(language)-\(mode)-systemdata-phase2.png")
            )
            try await snapshot(
                SystemDataView(viewModel: model).environment(\.currentAppTab, .diskAnalysis).defaultAppStorage(defaults).frame(width: 944, height: 3000),
                size: CGSize(width: 944, height: 3000), appearance: appearance,
                to: outDir.appendingPathComponent("\(language)-\(mode)-systemdata-phase2-full.png")
            )
            model.isMeasuringComparison = false

            // 扫描中
            model.phase = .scanning
            model.scannedBytes = Int64(86.4e9)
            model.scanStates = Dictionary(uniqueKeysWithValues: SystemDataCategoryID.allCases.filter { $0 != .other }.enumerated().map { index, id in
                (id, index < 7 ? .done(Int64(Double(index + 1) * 2.3e9)) : (index < 10 ? .measuring : .pending))
            })
            try await snapshot(
                SystemDataView(viewModel: model).environment(\.currentAppTab, .diskAnalysis).defaultAppStorage(defaults).frame(width: 944, height: 760),
                size: CGSize(width: 944, height: 760), appearance: appearance,
                to: outDir.appendingPathComponent("\(language)-\(mode)-systemdata-scanning.png")
            )
        }
        model.report = nil
        model.expanded = []
        model.phase = .intro
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
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
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
