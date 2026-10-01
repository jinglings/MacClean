//
//  SystemStats.swift
//  MacClean
//
//  菜单栏状态面板用到的系统指标采样：磁盘、内存、CPU、电池、网络、外接设备、热状态。
//  全部为 nonisolated 静态方法（工程默认 MainActor 隔离），调用开销均为毫秒级系统调用。
//

import Foundation
import IOKit
import IOKit.ps
import CoreWLAN

// MARK: - 模型

struct DiskStats: Sendable, Equatable {
    let volumeName: String
    let total: Int64
    /// Finder 口径的可用空间（含系统可自动清除的部分）。
    let available: Int64
    nonisolated var freeRatio: Double { total > 0 ? Double(available) / Double(total) : 0 }
}

struct MemoryStats: Sendable, Equatable {
    let total: UInt64
    /// 活动监视器口径的「已使用内存」：App 内存 + 联动内存 + 被压缩内存。
    let used: UInt64
    let compressed: UInt64
    let swapUsed: UInt64
    /// 内存压力 0–100，对应活动监视器的压力图。
    let pressure: Int
}

struct CPUTicks: Sendable, Equatable {
    let user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
    nonisolated var busy: UInt64 { user + system + nice }
    nonisolated var total: UInt64 { busy + idle }
}

struct BatteryStats: Sendable, Equatable {
    let percent: Int
    let isCharging: Bool
    let isOnAC: Bool
    /// 剩余可用分钟数（放电时）；nil 表示系统仍在估算。
    let minutesToEmpty: Int?
    /// 充满所需分钟数（充电时）。
    let minutesToFull: Int?
    let cycleCount: Int?
    /// 当前最大容量 / 设计容量。
    let healthPercent: Int?
}

struct NetworkCounters: Sendable, Equatable {
    let received: UInt64
    let sent: UInt64
}

struct NetworkInfo: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case wifi, wired, none }
    let kind: Kind
    /// Wi-Fi 名称（未授予定位权限时系统不提供，返回 nil）。
    let ssid: String?
}

struct ExternalVolume: Identifiable, Sendable, Equatable {
    let url: URL
    let name: String
    let total: Int64
    let available: Int64
    nonisolated var id: URL { url }
}

enum ThermalLevel: Sendable, Equatable {
    case nominal, fair, serious, critical

    var title: String {
        switch self {
        case .nominal: return String(localized: "正常")
        case .fair: return String(localized: "偏热")
        case .serious: return String(localized: "过热")
        case .critical: return String(localized: "严重过热")
        }
    }
}

// MARK: - 采样

enum SystemStats {

    // MARK: 磁盘

    nonisolated static func disk(path: String = "/") -> DiskStats? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]) else { return nil }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        return DiskStats(volumeName: values.volumeName ?? "Macintosh HD", total: total, available: available)
    }

    // MARK: 内存

    nonisolated static func memory() -> MemoryStats {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        var used: UInt64 = 0
        var compressed: UInt64 = 0
        if result == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let appMemory = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
            compressed = UInt64(stats.compressor_page_count) * page
            used = (appMemory + UInt64(stats.wire_count)) * page + compressed
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapUsed: UInt64 = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? swap.xsu_used : 0

        return MemoryStats(total: total, used: min(used, total), compressed: compressed, swapUsed: swapUsed, pressure: memoryPressure())
    }

    /// kern.memorystatus_level 是「可用内存水位」百分比，压力 = 100 − 水位。
    nonisolated static func memoryPressure() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else { return 0 }
        return pressure(fromAvailableLevel: Int(level))
    }

    nonisolated static func pressure(fromAvailableLevel level: Int) -> Int {
        max(0, min(100, 100 - level))
    }

    // MARK: CPU

    nonisolated static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    /// 两次采样之间的 CPU 占用百分比。
    nonisolated static func cpuLoad(from previous: CPUTicks, to current: CPUTicks) -> Int {
        let total = current.total &- previous.total
        guard total > 0 else { return 0 }
        let busy = current.busy &- previous.busy
        return Int((Double(busy) / Double(total) * 100).rounded())
    }

    nonisolated static func thermal() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    // MARK: 电池

    nonisolated static func battery() -> BatteryStats? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let toEmpty = description[kIOPSTimeToEmptyKey] as? Int
            let toFull = description[kIOPSTimeToFullChargeKey] as? Int
            let registry = smartBatteryProperties()

            var health: Int?
            if let design = registry["DesignCapacity"] as? Int, design > 0,
               let raw = (registry["AppleRawMaxCapacity"] as? Int) ?? (registry["NominalChargeCapacity"] as? Int) {
                health = Swift.min(100, Int((Double(raw) / Double(design) * 100).rounded()))
            }

            return BatteryStats(
                percent: max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isOnAC: (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                minutesToEmpty: (toEmpty ?? -1) > 0 ? toEmpty : nil,
                minutesToFull: (toFull ?? -1) > 0 ? toFull : nil,
                cycleCount: registry["CycleCount"] as? Int,
                healthPercent: health
            )
        }
        return nil
    }

    nonisolated private static func smartBatteryProperties() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return [:] }
        return (properties?.takeRetainedValue() as? [String: Any]) ?? [:]
    }

    // MARK: 网络

    /// 所有 en* 物理接口的累计收发字节数。
    nonisolated static func networkCounters() -> NetworkCounters {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return NetworkCounters(received: 0, sent: 0) }
        defer { freeifaddrs(addresses) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: entry.pointee.ifa_name).hasPrefix("en"),
                  let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            received += UInt64(data.pointee.ifi_ibytes)
            sent += UInt64(data.pointee.ifi_obytes)
        }
        return NetworkCounters(received: received, sent: sent)
    }

    /// 两次采样之间的每秒速率。if_data 计数器是 32 位、多接口求和后无法可靠还原回绕，
    /// 出现回绕（或接口重置）时丢弃这一次采样，返回 0，避免显示一个虚假的尖峰。
    nonisolated static func rate(from previous: UInt64, to current: UInt64, seconds: Double) -> Int64 {
        guard seconds > 0, current >= previous else { return 0 }
        return Int64(Double(current - previous) / seconds)
    }

    nonisolated static func networkInfo() -> NetworkInfo {
        let wifiInterface = CWWiFiClient.shared().interface()
        let wifiName = wifiInterface?.interfaceName
        let active = interfacesWithIPv4()

        if let wifiName, active.contains(wifiName) {
            return NetworkInfo(kind: .wifi, ssid: wifiInterface?.ssid())
        }
        if active.contains(where: { $0.hasPrefix("en") && $0 != wifiName }) {
            return NetworkInfo(kind: .wired, ssid: nil)
        }
        return NetworkInfo(kind: .none, ssid: nil)
    }

    nonisolated private static func interfacesWithIPv4() -> Set<String> {
        var names: Set<String> = []
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return [] }
        defer { freeifaddrs(addresses) }
        var cursor = addresses
        while let entry = cursor {
            if let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               (entry.pointee.ifa_flags & UInt32(IFF_UP)) != 0 {
                names.insert(String(cString: entry.pointee.ifa_name))
            }
            cursor = entry.pointee.ifa_next
        }
        return names
    }

    // MARK: 外接设备

    nonisolated static func externalVolumes() -> [ExternalVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsRootFileSystemKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRootFileSystem != true else { return nil }
            let isExternal = values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsInternal == false
            guard isExternal else { return nil }
            return ExternalVolume(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                total: Int64(values.volumeTotalCapacity ?? 0),
                available: Int64(values.volumeAvailableCapacity ?? 0)
            )
        }
    }

    // MARK: 机型

    /// 例如 "MacBook Pro"。Apple 芯片机型从设备树读取 product-name，读不到时退回 hw.model。
    nonisolated static func modelName() -> String {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        if entry != 0 {
            defer { IOObjectRelease(entry) }
            if let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data {
                let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
                if !name.isEmpty { return name }
            }
        }
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}

// MARK: - 综合状态

struct HealthAssessment: Sendable, Equatable {
    enum Level: Sendable, Equatable { case good, attention }
    let level: Level
    /// 需要注意的具体原因，面板上直接展示。
    let issues: [String]

    nonisolated static func evaluate(
        disk: DiskStats?,
        memory: MemoryStats?,
        battery: BatteryStats?,
        thermal: ThermalLevel
    ) -> HealthAssessment {
        var issues: [String] = []
        if let disk, disk.total > 0, disk.freeRatio < 0.10 || disk.available < 15_000_000_000 {
            issues.append(String(localized: "磁盘剩余空间不足"))
        }
        if let memory, memory.pressure >= 70 {
            issues.append(String(localized: "内存压力较高"))
        }
        switch thermal {
        case .serious, .critical: issues.append(String(localized: "机器温度过高"))
        case .nominal, .fair: break
        }
        if let health = battery?.healthPercent, health < 80 {
            issues.append(String(localized: "电池最大容量低于 80%"))
        }
        return HealthAssessment(level: issues.isEmpty ? .good : .attention, issues: issues)
    }
}
