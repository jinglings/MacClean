//
//  SystemDataAnalyzer.swift
//  MacClean
//
//  系统数据：把 macOS「存储空间」里笼统的「系统数据」拆开，逐项测量占用、判断是否正常，
//  并给出安全的处理方式。全程只读，不删除任何东西。
//
//  结构：
//  - SystemDataCatalog：每个类别的路径清单与阈值（纯数据，可传入假 home / 假根目录测试）；
//  - SystemDataPlanner：把各类别的路径展开成测量任务，嵌套路径从父路径中扣除，避免重复计算；
//  - SystemDataRules：状态判定、可清除空间、剩余「其他」、命令输出解析等纯函数；
//  - SystemDataAnalyzer.analyze：在后台并发执行测量，逐类别回报进度。
//

import Darwin
import Foundation

// MARK: - 类别

nonisolated enum SystemDataCategoryID: String, CaseIterable, Sendable, Hashable {
    case snapshots
    case timeMachine
    case macOS
    case systemAssets
    case spotlight
    case mediaAnalysis
    case iosBackups
    case xcode
    case virtualMachines
    case aiModels
    case appCaches
    case logs
    case appData
    case mailMessages
    case virtualMemory
    case installers
    case trash
    case commandLineTools
    case tempFiles
    // 以下三项不属于系统数据，只用来对照，让「其他未分类」名副其实
    case applications
    case personalFiles
    case otherUsers
    case other

    /// 「不属于系统数据（供对照）」分组
    var isComparison: Bool {
        self == .applications || self == .personalFiles || self == .otherUsers
    }
}

nonisolated enum SystemDataStatus: Int, Sendable, Comparable {
    case normal
    case large
    case abnormal

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 超过 large 为「偏大」，超过 abnormal 为「异常」；nil 表示该级别不适用。
nonisolated struct SystemDataThresholds: Sendable, Equatable {
    var large: Int64?
    var abnormal: Int64?

    static let none = SystemDataThresholds(large: nil, abnormal: nil)
}

/// 跳转目标：在视图层映射到 AppTab。
nonisolated enum SystemDataDestination: String, Sendable {
    case reclaim
    case devCaches
    case appStorage
    case maintenance
    case recovery
    case appManager
}

nonisolated enum SystemDataAction: Sendable, Hashable {
    case openTab(SystemDataDestination)
    case revealInFinder(String)
    case openSystemSettings(String)
    /// 系统会自动管理，无需处理
    case automatic
    /// 系统管理，无法手动删除
    case systemManaged
    /// 切到「目录地图」自己看
    case showFolderMap
}

nonisolated enum SystemDataUnmeasurableReason: Sendable, Equatable {
    case fullDiskAccess
    case admin
}

nonisolated struct SystemDataUnmeasured: Sendable, Equatable, Hashable {
    let path: String
    let reason: SystemDataUnmeasurableReason
}

nonisolated struct SystemDataEntry: Sendable, Equatable, Hashable, Identifiable {
    let name: String
    let path: String
    let size: Int64
    var id: String { path + "|" + name }
}

nonisolated struct SystemDataCategoryResult: Sendable, Identifiable, Equatable {
    let id: SystemDataCategoryID
    /// nil：完全无法测量，或只是一条说明（如 Time Machine 未设置）
    var size: Int64?
    var status: SystemDataStatus = .normal
    var thresholds: SystemDataThresholds = .none
    /// 占用最大的子文件夹 / 应用（按大小降序）
    var entries: [SystemDataEntry] = []
    var unmeasured: [SystemDataUnmeasured] = []
    /// 遍历途中无法读取的子目录数
    var unreadableDirectories = 0
    var actions: [SystemDataAction] = []
    /// 本地快照名（只用于 snapshots）
    var snapshotNames: [String] = []
    /// Time Machine 是否已设置（只用于 timeMachine；nil = 无法判断）
    var timeMachineConfigured: Bool?
    /// 系统资源中 UAF（Apple 智能 / Siri 模型）部分的大小
    var intelligenceSize: Int64?
}

nonisolated struct SystemDataVolume: Sendable, Equatable {
    var name: String
    var total: Int64
    /// volumeAvailableCapacity：真正空闲的块
    var available: Int64
    /// volumeAvailableCapacityForImportantUsage：空闲 + 系统可自动清除的部分
    var availableForImportantUsage: Int64

    var purgeable: Int64 { SystemDataRules.purgeable(available: available, availableForImportantUsage: availableForImportantUsage) }
    /// 与访达 / 系统设置一致的「已用」（可清除空间算作可用）
    var used: Int64 { max(0, total - max(available, availableForImportantUsage)) }
    /// 磁盘上实际被占用的块（含可清除空间）
    var usedOnDisk: Int64 { max(0, total - available) }
}

nonisolated struct APFSVolumeUsage: Sendable, Equatable {
    var name: String
    var roles: [String]
    var used: Int64
}

nonisolated struct SystemDataReport: Sendable {
    var volume: SystemDataVolume
    /// 已排序：有大小的按大小降序，无大小的在后，「其他」固定最后
    var categories: [SystemDataCategoryResult]
    var duration: TimeInterval
    /// 第一阶段（系统数据）用时
    var systemDataDuration: TimeInterval = 0
    /// 第一阶段的报告：对照项与「其他未分类」还在测量，categories 里没有它们
    var comparisonPending = false

    /// 系统数据中已归类解释的空间（不含对照项与「其他」）
    var explained: Int64 {
        categories.filter { $0.id != .other && !$0.id.isComparison }.reduce(0) { $0 + ($1.size ?? 0) }
    }

    /// 对照项合计：应用程序、个人文件、其他用户
    var comparisonTotal: Int64 {
        categories.filter { $0.id.isComparison }.reduce(0) { $0 + ($1.size ?? 0) }
    }
}

// MARK: - 路径清单

nonisolated struct SystemDataCategorySpec: Sendable {
    let id: SystemDataCategoryID
    /// 绝对路径；最后一段可以含 * 通配符
    let paths: [String]
    let thresholds: SystemDataThresholds
}

nonisolated enum SystemDataCatalog {
    static let gb: Int64 = 1_000_000_000

    /// - Parameters:
    ///   - home: 用户主目录
    ///   - root: 系统绝对路径的前缀（测试时指向假根目录，正式运行为空）
    ///   - physicalMemory: 内存大小，用于虚拟内存的阈值
    static func specs(home: String, root: String = "", physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> [SystemDataCategorySpec] {
        func h(_ relative: String) -> String { home + "/" + relative }
        func s(_ absolute: String) -> String { root + absolute }
        let memory = Int64(clamping: physicalMemory)

        return [
            SystemDataCategorySpec(id: .spotlight, paths: [
                h("Library/Metadata/CoreSpotlight"),
                s("/System/Volumes/Data/.Spotlight-V100"),
            ], thresholds: SystemDataThresholds(large: 5 * gb, abnormal: 10 * gb)),

            SystemDataCategorySpec(id: .mediaAnalysis, paths: [
                h("Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches"),
                h("Library/Containers/com.apple.photoanalysisd/Data/Library/Caches"),
            ], thresholds: SystemDataThresholds(large: 2 * gb, abnormal: 5 * gb)),

            SystemDataCategorySpec(id: .iosBackups, paths: [
                h("Library/Application Support/MobileSync/Backup"),
            ], thresholds: SystemDataThresholds(large: 20 * gb, abnormal: nil)),

            SystemDataCategorySpec(id: .xcode, paths: [
                h("Library/Developer/Xcode/DerivedData"),
                h("Library/Developer/Xcode/iOS DeviceSupport"),
                h("Library/Developer/Xcode/watchOS DeviceSupport"),
                h("Library/Developer/Xcode/macOS DeviceSupport"),
                h("Library/Developer/Xcode/Archives"),
                h("Library/Developer/CoreSimulator/Devices"),
                h("Library/Developer/CoreSimulator/Caches"),
                s("/Library/Developer/CoreSimulator/Images"),
                s("/Library/Developer/CoreSimulator/Cryptex"),
                s("/Library/Developer/CoreSimulator/Volumes"),
                s("/System/Library/AssetsV2/com_apple_MobileAsset_*SimulatorRuntime"),
            ], thresholds: SystemDataThresholds(large: 30 * gb, abnormal: nil)),

            SystemDataCategorySpec(id: .virtualMachines, paths: [
                h("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"),
                h("Library/Containers/com.docker.docker"),
                h("Library/Group Containers/group.com.docker"),
                h("Library/Group Containers/HUAQ24HBR6.dev.orbstack"),
                h(".orbstack"),
                h("Library/Containers/com.utmapp.UTM"),
                h("Parallels"),
                h("Virtual Machines.localized"),
            ], thresholds: SystemDataThresholds(large: 60 * gb, abnormal: nil)),

            SystemDataCategorySpec(id: .aiModels, paths: [
                h(".ollama/models"),
                h(".cache/huggingface"),
                h(".cache/lm-studio"),
                h(".lmstudio"),
                h("jan"),
                h("Library/Application Support/Jan"),
                h("Library/Application Support/LM Studio"),
                h("Library/Application Support/DiffusionBee"),
                h(".diffusionbee"),
            ], thresholds: SystemDataThresholds(large: 30 * gb, abnormal: nil)),

            SystemDataCategorySpec(id: .systemAssets, paths: [
                s("/System/Library/AssetsV2"),
                s("/private/var/MobileAsset"),
            ], thresholds: SystemDataThresholds(large: 40 * gb, abnormal: nil)),

            SystemDataCategorySpec(id: .appCaches, paths: [
                h("Library/Caches"),
                s("/Library/Caches"),
            ], thresholds: SystemDataThresholds(large: 10 * gb, abnormal: nil)),

            SystemDataCategorySpec(id: .logs, paths: [
                h("Library/Logs"),
                s("/Library/Logs"),
                s("/private/var/log"),
                s("/private/var/db/diagnostics"),
                s("/private/var/db/uuidtext"),
            ], thresholds: SystemDataThresholds(large: 5 * gb, abnormal: 15 * gb)),

            SystemDataCategorySpec(id: .appData, paths: [
                h("Library/Containers"),
                h("Library/Group Containers"),
                h("Library/Application Support"),
            ], thresholds: SystemDataThresholds(large: 100 * gb, abnormal: nil)),

            SystemDataCategorySpec(id: .mailMessages, paths: [
                h("Library/Mail"),
                h("Library/Messages/Attachments"),
            ], thresholds: SystemDataThresholds(large: 20 * gb, abnormal: nil)),

            SystemDataCategorySpec(id: .virtualMemory, paths: [
                s("/private/var/vm"),
            ], thresholds: SystemDataThresholds(large: memory * 2 + 4 * gb, abnormal: nil)),

            SystemDataCategorySpec(id: .installers, paths: [
                s("/Applications/Install macOS*.app"),
                s("/macOS Install Data"),
                s("/Library/Updates"),
                s("/System/Library/AssetsV2/com_apple_MobileAsset_MacSoftwareUpdate"),
                s("/System/Library/AssetsV2/com_apple_MobileAsset_MacSplatSoftwareUpdate"),
            ], thresholds: SystemDataThresholds(large: 15 * gb, abnormal: nil)),

            SystemDataCategorySpec(id: .trash, paths: [
                h(".Trash"),
            ], thresholds: SystemDataThresholds(large: 5 * gb, abnormal: nil)),

            SystemDataCategorySpec(id: .commandLineTools, paths: [
                s("/opt"),
                s("/usr/local"),
            ], thresholds: SystemDataThresholds(large: 30 * gb, abnormal: nil)),

            SystemDataCategorySpec(id: .tempFiles, paths: [
                s("/private/var/folders"),
            ], thresholds: SystemDataThresholds(large: 20 * gb, abnormal: nil)),

            // 对照项放在最后：嵌套在其中、已被上面各类认领的路径（~/.ollama/models、Install macOS*.app 等）会被扣除
            SystemDataCategorySpec(id: .applications, paths: [
                s("/Applications"),
                h("Applications"),
            ], thresholds: .none),

            SystemDataCategorySpec(id: .personalFiles, paths: [
                home,
                // iCloud 云盘的本地副本在 ~/Library 下，但它是你的文件，归入这里
                h(iCloudDriveFolder),
            ], thresholds: .none),

            // 当前用户的主目录已由 personalFiles 先认领，同一路径不会再测
            SystemDataCategorySpec(id: .otherUsers, paths: [
                s("/Users/*"),
            ], thresholds: .none),
        ]
    }

    static let iCloudDriveFolder = "Library/Mobile Documents"

    /// 任何类别都不遍历的路径：~/Library 里属于系统数据的部分已逐项认领，其余也不算个人文件。
    static func skippedPaths(home: String) -> [String] {
        [home + "/Library"]
    }

    /// 展开最后一段的 * 通配符；不含通配符的路径原样返回（存在与否由测量决定）。
    static func expand(_ path: String) -> [String] {
        let name = (path as NSString).lastPathComponent
        guard name.contains("*") else { return [path] }
        let parent = (path as NSString).deletingLastPathComponent
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return [] }
        return children
            .filter { fnmatch(name, $0, FNM_PERIOD) == 0 }
            .sorted()
            .map { parent + "/" + $0 }
    }
}

// MARK: - 测量计划（去重）

nonisolated struct SystemDataMeasureTask: Sendable, Equatable {
    let category: SystemDataCategoryID
    let path: String
    /// 嵌套在本路径下、已归入其他任务的路径；遍历时整棵跳过
    let excluding: Set<String>
}

nonisolated enum SystemDataPlanner {
    /// 同一路径只测一次（先出现的类别优先）；一个路径下嵌套的其他已认领路径从它的遍历中扣除，
    /// 这样每个字节只归入一个类别——最具体的那一个。
    /// skipping：不归任何任务、但要从包含它的任务里扣除的路径（如 ~/Library 之于主目录）。
    static func plan(_ claims: [(SystemDataCategoryID, String)], skipping: [String] = []) -> [SystemDataMeasureTask] {
        var seen: Set<String> = []
        var unique: [(SystemDataCategoryID, String)] = []
        for (category, rawPath) in claims {
            let path = normalize(rawPath)
            guard seen.insert(path).inserted else { continue }
            unique.append((category, path))
        }
        let allPaths = unique.map(\.1) + skipping.map(normalize).filter { !seen.contains($0) }
        return unique.map { category, path in
            let prefix = path + "/"
            let nested = allPaths.filter { $0.hasPrefix(prefix) }
            return SystemDataMeasureTask(category: category, path: path, excluding: Set(nested))
        }
    }

    static func normalize(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

// MARK: - 规则（纯函数）

nonisolated enum SystemDataRules {

    static func status(size: Int64, thresholds: SystemDataThresholds) -> SystemDataStatus {
        if let abnormal = thresholds.abnormal, size > abnormal { return .abnormal }
        if let large = thresholds.large, size > large { return .large }
        return .normal
    }

    /// 可清除空间 = 「重要用途可用」− 「真正空闲」；系统需要时会自动释放（主要是本地快照与可清除缓存）。
    static func purgeable(available: Int64, availableForImportantUsage: Int64) -> Int64 {
        max(0, availableForImportantUsage - available)
    }

    /// 本地快照 / 可清除空间：超过总容量的 15% 视为偏大（系统仍会自动释放）。
    static func snapshotThresholds(total: Int64) -> SystemDataThresholds {
        SystemDataThresholds(large: total > 0 ? total * 15 / 100 : nil, abnormal: nil)
    }

    /// 磁盘上实际占用中没有归入任何类别的部分；类别之间可能有少量重叠（如可清除缓存），结果不会为负。
    static func residual(usedOnDisk: Int64, explained: Int64) -> Int64 {
        max(0, usedOnDisk - explained)
    }

    /// `tmutil destinationinfo`：输出含「No destinations configured」为未设置；含「Name」或「ID」为已设置。
    static func timeMachineConfigured(destinationInfoOutput output: String) -> Bool? {
        if output.contains("No destinations configured") { return false }
        if output.range(of: #"(?m)^\s*(Name|ID)\s*:"#, options: .regularExpression) != nil { return true }
        return nil
    }

    /// `diskutil apfs list -plist <container>` → 各卷占用。
    static func parseAPFSVolumes(plist data: Data) -> [APFSVolumeUsage] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = root["Containers"] as? [[String: Any]] else { return [] }
        var result: [APFSVolumeUsage] = []
        for container in containers {
            for volume in container["Volumes"] as? [[String: Any]] ?? [] {
                let used = (volume["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
                result.append(APFSVolumeUsage(
                    name: volume["Name"] as? String ?? "",
                    roles: volume["Roles"] as? [String] ?? [],
                    used: used
                ))
            }
        }
        return result
    }

    /// 只读系统卷与启动/恢复辅助卷（不含 Data 与 VM 卷：Data 卷按目录逐项测量，VM 卷由 /private/var/vm 测量）。
    static func macOSVolumesUsage(_ volumes: [APFSVolumeUsage]) -> [APFSVolumeUsage] {
        let roles: Set<String> = ["System", "Preboot", "Recovery", "Update"]
        return volumes.filter { !roles.isDisjoint(with: $0.roles) }
    }

    /// `diskutil info -plist /` → APFS 容器（如 disk3）。
    static func parseContainerReference(plist data: Data) -> String? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return root["APFSContainerReference"] as? String
    }

    /// 应用数据的子文件夹 → 应用名称的键：容器取其 bundle id，组容器去掉团队前缀 / group. 前缀。
    static func appKey(forFolderName name: String, metadataIdentifier: String?) -> String {
        if let metadataIdentifier, !metadataIdentifier.isEmpty { return metadataIdentifier }
        var key = name
        if key.hasPrefix("group.") { key.removeFirst("group.".count) }
        let parts = key.split(separator: ".", maxSplits: 1)
        if parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isUppercase || $0.isNumber }) {
            key = String(parts[1])
        }
        return key
    }

    /// UAF（Unified Asset Framework）资源：Apple 智能、Siri 与语音模型。
    static func isIntelligenceAsset(_ name: String) -> Bool {
        name.contains("_UAF_") || name.contains("GenerativeModel")
    }

    /// 每个类别的处理方式（与状态和本机情况相关）。
    static func actions(
        for id: SystemDataCategoryID,
        status: SystemDataStatus,
        firstExistingPath: String?,
        hasDocker: Bool = false
    ) -> [SystemDataAction] {
        switch id {
        case .snapshots:
            return [.openTab(.recovery), .openTab(.maintenance)]
        case .timeMachine:
            return [.openSystemSettings("x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")]
        case .macOS:
            return [.systemManaged]
        case .systemAssets:
            return [.systemManaged]
        case .spotlight:
            return status == .normal ? [.automatic] : [.openTab(.maintenance)]
        case .mediaAnalysis:
            if status != .normal, let path = firstExistingPath { return [.revealInFinder(path)] }
            return [.automatic]
        case .iosBackups:
            return [.openTab(.reclaim)]
        case .xcode:
            return [.openTab(.devCaches)]
        case .virtualMachines:
            var actions: [SystemDataAction] = []
            if hasDocker { actions.append(.openTab(.appStorage)) }
            if let path = firstExistingPath { actions.append(.revealInFinder(path)) }
            return actions
        case .aiModels:
            return firstExistingPath.map { [.revealInFinder($0)] } ?? []
        case .appCaches, .logs, .trash:
            return [.openTab(.reclaim)]
        case .appData:
            return [.openTab(.appStorage)]
        case .mailMessages:
            return [.openSystemSettings("x-apple.systempreferences:com.apple.settings.Storage")]
        case .virtualMemory:
            return [.automatic]
        case .installers:
            if let path = firstExistingPath, path.hasSuffix(".app") { return [.revealInFinder(path)] }
            return [.automatic]
        case .commandLineTools:
            return firstExistingPath.map { [.revealInFinder($0)] } ?? []
        case .tempFiles:
            return [.automatic]
        case .applications:
            return [.openTab(.appManager)]
        case .personalFiles:
            return [.showFolderMap]
        case .otherUsers:
            return []
        case .other:
            return [.showFolderMap]
        }
    }
}

// MARK: - 运行环境（可注入，便于测试）

nonisolated struct SystemDataEnvironment: Sendable {
    var home: String
    /// 系统绝对路径的前缀；正式运行为空
    var root: String = ""
    var physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    var volume: @Sendable () -> SystemDataVolume?
    var localSnapshots: @Sendable () -> [String]
    var timeMachineDestinationInfo: @Sendable () -> String
    var apfsVolumes: @Sendable () -> [APFSVolumeUsage]
    /// bundle id → 应用名称
    var appNames: @Sendable () -> [String: String]

    static func live() -> SystemDataEnvironment {
        SystemDataEnvironment(
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            volume: {
                let url = URL(fileURLWithPath: "/")
                guard let values = try? url.resourceValues(forKeys: [
                    .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                ]) else { return nil }
                let available = Int64(values.volumeAvailableCapacity ?? 0)
                return SystemDataVolume(
                    name: values.volumeName ?? "Macintosh HD",
                    total: Int64(values.volumeTotalCapacity ?? 0),
                    available: available,
                    availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage ?? available
                )
            },
            localSnapshots: {
                RecoveryParsing.parseLocalSnapshots(
                    MaintenanceRunner.runProcess("/usr/bin/tmutil", ["listlocalsnapshots", "/System/Volumes/Data"]).stdout
                )
            },
            timeMachineDestinationInfo: {
                let output = MaintenanceRunner.runProcess("/usr/bin/tmutil", ["destinationinfo"])
                return output.stdout + output.stderr
            },
            apfsVolumes: {
                let info = MaintenanceRunner.runProcess("/usr/sbin/diskutil", ["info", "-plist", "/"])
                guard let container = SystemDataRules.parseContainerReference(plist: Data(info.stdout.utf8)) else { return [] }
                let list = MaintenanceRunner.runProcess("/usr/sbin/diskutil", ["apfs", "list", "-plist", container])
                return SystemDataRules.parseAPFSVolumes(plist: Data(list.stdout.utf8))
            },
            appNames: { SystemDataAnalyzer.installedAppNames() }
        )
    }
}

// MARK: - 进度

nonisolated enum SystemDataProgress: Sendable {
    case started(SystemDataCategoryID)
    case finished(SystemDataCategoryID, size: Int64?)
    /// 已统计的总字节（节流后回报）
    case bytes(Int64)
    /// 某个类别已统计的字节（节流后回报，用于第二阶段各项各自的进度）
    case categoryBytes(SystemDataCategoryID, Int64)
}

// MARK: - 分析

nonisolated enum SystemDataAnalyzer {

    /// 两阶段测量：先测系统数据（较快），完成后通过 onSystemData 交出一份不含对照项的报告供界面先显示；
    /// 再测应用程序、个人文件与其他用户（主目录常有上千万个文件，较慢），最后返回完整报告。
    /// 两个阶段共用同一个去重表，取消时两个阶段一起停止。
    static func analyze(
        environment: SystemDataEnvironment = .live(),
        progress: (@Sendable (SystemDataProgress) -> Void)? = nil,
        onSystemData: (@Sendable (SystemDataReport) -> Void)? = nil
    ) async throws -> SystemDataReport {
        let start = Date()
        let specs = SystemDataCatalog.specs(home: environment.home, root: environment.root, physicalMemory: environment.physicalMemory)

        var claims: [(SystemDataCategoryID, String)] = []
        for spec in specs {
            for path in spec.paths {
                for expanded in SystemDataCatalog.expand(path) {
                    claims.append((spec.id, expanded))
                }
            }
        }
        // 一次规划全部路径，嵌套扣除在两个阶段之间也成立
        let tasks = SystemDataPlanner.plan(claims, skipping: SystemDataCatalog.skippedPaths(home: environment.home))
        let deduper = DiskAnalyzer.UsageDeduper()
        let byteCounter = ByteCounter(report: progress)
        let systemSpecs = specs.filter { !$0.id.isComparison }
        let comparisonSpecs = specs.filter { $0.id.isComparison }

        // 第一阶段：系统数据
        for spec in systemSpecs { progress?(.started(spec.id)) }
        var measurements = try await measure(
            tasks.filter { !$0.category.isComparison }, deduper: deduper, byteCounter: byteCounter, progress: progress
        )
        try Task.checkCancellation()

        // 命令行信息（很快，但不放在主线程）
        let volume = environment.volume() ?? SystemDataVolume(name: "Macintosh HD", total: 0, available: 0, availableForImportantUsage: 0)
        progress?(.started(.snapshots))
        let snapshots = environment.localSnapshots()
        progress?(.finished(.snapshots, size: volume.purgeable))
        progress?(.started(.timeMachine))
        let tmConfigured = SystemDataRules.timeMachineConfigured(destinationInfoOutput: environment.timeMachineDestinationInfo())
        progress?(.finished(.timeMachine, size: nil))
        progress?(.started(.macOS))
        let macOSVolumes = SystemDataRules.macOSVolumesUsage(environment.apfsVolumes())
        progress?(.finished(.macOS, size: macOSVolumes.isEmpty ? nil : macOSVolumes.reduce(0) { $0 + $1.used }))
        let appNames = measurements[.appData] == nil ? [:] : environment.appNames()

        var results: [SystemDataCategoryResult] = []

        // 本地快照与可清除空间
        let snapshotThresholds = SystemDataRules.snapshotThresholds(total: volume.total)
        let snapshotStatus = SystemDataRules.status(size: volume.purgeable, thresholds: snapshotThresholds)
        results.append(SystemDataCategoryResult(
            id: .snapshots,
            size: volume.purgeable,
            status: snapshotStatus,
            thresholds: snapshotThresholds,
            actions: SystemDataRules.actions(for: .snapshots, status: snapshotStatus, firstExistingPath: nil),
            snapshotNames: snapshots
        ))

        results.append(SystemDataCategoryResult(
            id: .timeMachine,
            size: nil,
            actions: SystemDataRules.actions(for: .timeMachine, status: .normal, firstExistingPath: nil),
            timeMachineConfigured: tmConfigured
        ))

        if !macOSVolumes.isEmpty {
            results.append(SystemDataCategoryResult(
                id: .macOS,
                size: macOSVolumes.reduce(0) { $0 + $1.used },
                entries: macOSVolumes.map { SystemDataEntry(name: $0.name, path: "", size: $0.used) }.sorted { $0.size > $1.size },
                actions: [.systemManaged]
            ))
        }

        for spec in systemSpecs {
            results.append(categoryResult(spec: spec, parts: measurements[spec.id] ?? [], appNames: appNames))
        }

        let systemDuration = Date().timeIntervalSince(start)
        onSystemData?(SystemDataReport(
            volume: volume, categories: sortCategories(results), duration: systemDuration,
            systemDataDuration: systemDuration, comparisonPending: true
        ))

        // 第二阶段：对照项（应用程序、个人文件、其他用户），之后才能算出「其他未分类」
        for spec in comparisonSpecs { progress?(.started(spec.id)) }
        progress?(.started(.other))
        let comparison = try await measure(
            tasks.filter { $0.category.isComparison }, deduper: deduper, byteCounter: byteCounter, progress: progress
        )
        try Task.checkCancellation()
        measurements.merge(comparison) { $1 }
        for spec in comparisonSpecs {
            results.append(categoryResult(spec: spec, parts: measurements[spec.id] ?? [], appNames: appNames))
        }

        let explained = results.reduce(0) { $0 + ($1.size ?? 0) }
        let residual = SystemDataRules.residual(usedOnDisk: volume.usedOnDisk, explained: explained)
        results.append(SystemDataCategoryResult(id: .other, size: residual, actions: [.showFolderMap]))
        progress?(.finished(.other, size: residual))

        return SystemDataReport(
            volume: volume, categories: sortCategories(results), duration: Date().timeIntervalSince(start),
            systemDataDuration: systemDuration
        )
    }

    private typealias Measurements = [SystemDataCategoryID: [(path: String, result: DiskAnalyzer.UsageMeasurement)]]

    /// 并发执行一批测量任务；某个类别的任务全部完成时回报该类别。
    private static func measure(
        _ tasks: [SystemDataMeasureTask],
        deduper: DiskAnalyzer.UsageDeduper,
        byteCounter: ByteCounter,
        progress: (@Sendable (SystemDataProgress) -> Void)?
    ) async throws -> Measurements {
        var remaining: [SystemDataCategoryID: Int] = [:]
        for task in tasks { remaining[task.category, default: 0] += 1 }

        var measurements: Measurements = [:]
        try await withThrowingTaskGroup(of: (SystemDataMeasureTask, DiskAnalyzer.UsageMeasurement).self) { group in
            for task in tasks {
                group.addTask {
                    let result = try await DiskAnalyzer.measureUsage(
                        atPath: task.path, excluding: task.excluding, deduper: deduper,
                        onBytes: { byteCounter.add($0, to: task.category) }
                    )
                    return (task, result)
                }
            }
            for try await (task, result) in group {
                measurements[task.category, default: []].append((task.path, result))
                remaining[task.category, default: 1] -= 1
                if remaining[task.category] == 0 {
                    let parts = measurements[task.category] ?? []
                    let measured = parts.filter { $0.result.access == .measured }
                    let size: Int64? = measured.isEmpty && parts.contains(where: { isDenied($0.result.access) })
                        ? nil : measured.reduce(0) { $0 + $1.result.size }
                    progress?(.finished(task.category, size: size))
                }
            }
        }
        return measurements
    }

    /// 系统数据在前，对照项随后，「其他」固定最后；每组内有大小的按大小降序，没有大小的排在组末。
    static func sortCategories(_ results: [SystemDataCategoryResult]) -> [SystemDataCategoryResult] {
        func ordered(_ group: [SystemDataCategoryResult]) -> [SystemDataCategoryResult] {
            group.filter { $0.size != nil }.sorted { ($0.size ?? 0) > ($1.size ?? 0) } + group.filter { $0.size == nil }
        }
        let system = results.filter { $0.id != .other && !$0.id.isComparison }
        let comparison = results.filter { $0.id.isComparison }
        return ordered(system) + ordered(comparison) + results.filter { $0.id == .other }
    }

    static func categoryResult(
        spec: SystemDataCategorySpec,
        parts: [(path: String, result: DiskAnalyzer.UsageMeasurement)],
        appNames: [String: String]
    ) -> SystemDataCategoryResult {
        let measured = parts.filter { $0.result.access == .measured }
        let unmeasured = parts.compactMap { part -> SystemDataUnmeasured? in
            switch part.result.access {
            case .deniedByPrivacy: return SystemDataUnmeasured(path: part.path, reason: .fullDiskAccess)
            case .deniedByOwner: return SystemDataUnmeasured(path: part.path, reason: .admin)
            case .measured, .missing: return nil
            }
        }
        let size: Int64? = measured.isEmpty && !unmeasured.isEmpty ? nil : measured.reduce(0) { $0 + $1.result.size }
        let status = size.map { SystemDataRules.status(size: $0, thresholds: spec.thresholds) } ?? .normal

        let entries: [SystemDataEntry]
        if spec.id == .personalFiles {
            entries = personalEntries(measured.map { ($0.path, $0.result) })
        } else if spec.id == .appData {
            entries = topApps(measured.flatMap { part in part.result.children.map { (part.path, $0) } }, appNames: appNames, limit: 5)
        } else if spec.id == .otherUsers || measured.filter({ $0.result.size > 0 }).count > 1 {
            entries = measured
                .filter { $0.result.size > 0 }
                .map { SystemDataEntry(name: displayName(forRoot: $0.path), path: $0.path, size: $0.result.size) }
                .sorted { $0.size > $1.size }
        } else {
            entries = (measured.first?.result.children ?? [])
                .filter { $0.size > 0 }
                .prefix(8)
                .map { SystemDataEntry(name: $0.name, path: $0.path, size: $0.size) }
        }

        let firstExisting = measured.filter { $0.result.size > 0 }.max { $0.result.size < $1.result.size }?.path
        let hasDocker = measured.contains { $0.path.contains("com.docker.docker") && $0.result.size > 0 }

        var result = SystemDataCategoryResult(
            id: spec.id,
            size: size,
            status: status,
            thresholds: spec.thresholds,
            entries: Array(entries.prefix(8)),
            unmeasured: unmeasured,
            unreadableDirectories: measured.reduce(0) { $0 + $1.result.unreadableDirectories },
            actions: SystemDataRules.actions(for: spec.id, status: status, firstExistingPath: firstExisting, hasDocker: hasDocker)
        )
        if spec.id == .systemAssets {
            let intelligence = measured.flatMap(\.result.children).filter { SystemDataRules.isIntelligenceAsset($0.name) }
            result.intelligenceSize = intelligence.reduce(0) { $0 + $1.size }
            result.entries = result.entries.map {
                SystemDataEntry(name: $0.name.replacingOccurrences(of: "com_apple_MobileAsset_", with: ""), path: $0.path, size: $0.size)
            }
        }
        return result
    }

    /// 个人文件按常用文件夹归类；其余归入「其他」，iCloud 云盘本地副本单列。
    static func personalEntries(_ parts: [(path: String, result: DiskAnalyzer.UsageMeasurement)]) -> [SystemDataEntry] {
        let names: [String: String] = [
            "Documents": String(localized: "文稿"),
            "Desktop": String(localized: "桌面"),
            "Downloads": String(localized: "下载"),
            "Pictures": String(localized: "图片"),
            "Movies": String(localized: "影片"),
            "Music": String(localized: "音乐"),
        ]
        var entries: [SystemDataEntry] = []
        for part in parts {
            if part.path.hasSuffix("/" + SystemDataCatalog.iCloudDriveFolder) {
                if part.result.size > 0 {
                    entries.append(SystemDataEntry(name: String(localized: "iCloud 云盘（本地副本）"), path: part.path, size: part.result.size))
                }
                continue
            }
            var rest = part.result.size
            for child in part.result.children {
                guard let name = names[child.name], child.size > 0 else { continue }
                entries.append(SystemDataEntry(name: name, path: child.path, size: child.size))
                rest -= child.size
            }
            if rest > 0 {
                entries.append(SystemDataEntry(name: String(localized: "其他"), path: part.path, size: rest))
            }
        }
        return entries.sorted { $0.size > $1.size }
    }

    /// 应用数据按应用聚合（容器 + 组容器 + Application Support），取前 N。
    static func topApps(_ children: [(root: String, child: DiskAnalyzer.UsageChild)], appNames: [String: String], limit: Int) -> [SystemDataEntry] {
        var totals: [String: (size: Int64, path: String, pathSize: Int64)] = [:]
        for (root, child) in children where child.size > 0 {
            let metadata = root.hasSuffix("/Containers") ? containerIdentifier(atPath: child.path) : nil
            let key = SystemDataRules.appKey(forFolderName: child.name, metadataIdentifier: metadata)
            let name = appNames[key] ?? appNames[key.lowercased()] ?? key
            var entry = totals[name] ?? (0, child.path, 0)
            entry.size += child.size
            if child.size > entry.pathSize {
                entry.path = child.path
                entry.pathSize = child.size
            }
            totals[name] = entry
        }
        return totals
            .map { SystemDataEntry(name: $0.key, path: $0.value.path, size: $0.value.size) }
            .sorted { $0.size > $1.size }
            .prefix(limit)
            .map { $0 }
    }

    /// 沙盒容器文件夹名可能是 UUID，真正的 bundle id 记在容器元数据里。
    static func containerIdentifier(atPath path: String) -> String? {
        let metadata = path + "/.com.apple.containermanagerd.metadata.plist"
        guard let plist = NSDictionary(contentsOfFile: metadata) else { return nil }
        return plist["MCMMetadataIdentifier"] as? String
    }

    static func displayName(forRoot path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".localized") ? String(name.dropLast(".localized".count)) : name
    }

    static func isDenied(_ access: DiskAnalyzer.UsageAccess) -> Bool {
        access == .deniedByOwner || access == .deniedByPrivacy
    }

    /// /Applications、/System/Applications、~/Applications 中应用的 bundle id → 显示名（只读 Info.plist，很快）。
    static func installedAppNames() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var names: [String: String] = [:]
        for directory in ["/Applications", "/System/Applications", "/Applications/Utilities", "/System/Applications/Utilities", home + "/Applications"] {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for item in items where item.hasSuffix(".app") {
                let path = directory + "/" + item
                guard let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any],
                      let bundleID = plist["CFBundleIdentifier"] as? String else { continue }
                let name = AppStorageScanner.displayName(plist: plist, path: path)
                names[bundleID] = name
                names[bundleID.lowercased()] = name
            }
        }
        return names
    }

    /// 多个并发遍历共享的字节计数，节流后回报：总数每 256 MB 一次，单个类别每 128 MB 一次。
    nonisolated final class ByteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var total: Int64 = 0
        private var lastReported: Int64 = 0
        private var perCategory: [SystemDataCategoryID: Int64] = [:]
        private var lastReportedPerCategory: [SystemDataCategoryID: Int64] = [:]
        private let report: (@Sendable (SystemDataProgress) -> Void)?

        init(report: (@Sendable (SystemDataProgress) -> Void)?) {
            self.report = report
        }

        func add(_ bytes: Int64, to category: SystemDataCategoryID) {
            guard bytes > 0 else { return }
            lock.lock()
            total += bytes
            let totalSnapshot = total
            let reportTotal = total - lastReported >= 256 * 1_048_576
            if reportTotal { lastReported = total }
            let categoryTotal = perCategory[category, default: 0] + bytes
            perCategory[category] = categoryTotal
            let reportCategory = categoryTotal - lastReportedPerCategory[category, default: 0] >= 128 * 1_048_576
            if reportCategory { lastReportedPerCategory[category] = categoryTotal }
            lock.unlock()
            if reportTotal { report?(.bytes(totalSnapshot)) }
            if reportCategory { report?(.categoryBytes(category, categoryTotal)) }
        }
    }
}
