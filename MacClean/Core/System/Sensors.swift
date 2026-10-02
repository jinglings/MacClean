//
//  Sensors.swift
//  MacClean
//
//  温度与风扇的只读采样。MacClean 从不写 SMC、不调节风扇。
//
//  数据来源：
//  - Apple 芯片温度：IOHIDEventSystemClient（私有 API，经 dlsym 取得，缺失时整体降级为「不可用」）。
//    每个 HID 传感器读一次约 1 ms（内核里串行），所以默认只读 CPU / 电池 / 固态硬盘几类，
//    「全部传感器」展开时才读其余的。
//  - 风扇、Apple 芯片 GPU、Intel 全部温度：AppleSMC（IOConnectCallStructMethod，只用读取命令）。
//  全部 nonisolated：工程默认 MainActor 隔离，采样必须在后台线程做。
//

import Foundation
import IOKit

// MARK: - 模型

nonisolated enum SensorCategory: String, CaseIterable, Sendable {
    case cpu, gpu, battery, ssd, other

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .battery: return String(localized: "电池")
        case .ssd: return String(localized: "固态硬盘")
        case .other: return String(localized: "其他")
        }
    }
}

nonisolated struct SensorReading: Sendable, Equatable {
    let name: String
    let celsius: Double
    let category: SensorCategory
}

/// 同名传感器合并后的一行（Apple 芯片常有两个 PMU 报告同名传感器）。
nonisolated struct SensorGroup: Sendable, Equatable, Identifiable {
    let name: String
    let category: SensorCategory
    let celsius: Double
    let count: Int
    var id: String { name }
}

nonisolated struct FanReading: Sendable, Equatable, Identifiable {
    let index: Int
    let actual: Double
    let minimum: Double?
    let maximum: Double?
    var id: Int { index }

    /// 低于 50 rpm 视为停转（部分机型停转时会报个位数噪声）。
    var isIdle: Bool { actual < 50 }

    /// 当前转速在 0…最高转速 之间的比例，用于进度条。
    var fraction: Double {
        guard let maximum, maximum > 0 else { return 0 }
        return min(max(actual / maximum, 0), 1)
    }
}

nonisolated struct ThermalSample: Sendable, Equatable {
    let date: Date
    /// 已过滤掉无效读数。
    let sensors: [SensorReading]
    let fans: [FanReading]
    /// 是否包含「其他」类传感器（只在「全部传感器」展开时读取）。
    let includesAllSensors: Bool

    var cpuAverage: Double? { SensorMath.average(values(.cpu)) }
    var cpuMax: Double? { values(.cpu).max() }
    var gpu: Double? { SensorMath.average(values(.gpu)) }
    var battery: Double? { SensorMath.average(values(.battery)) }
    var ssd: Double? { values(.ssd).max() }

    /// 风扇转速：取所有风扇中最快的一个。
    var fanRPM: Double? { fans.map(\.actual).max() }
    var hasFans: Bool { !fans.isEmpty }
    /// 什么都没读到：机型暂不支持。
    var isUnavailable: Bool { sensors.isEmpty && fans.isEmpty }

    var groups: [SensorGroup] { SensorMath.group(sensors) }

    func values(_ category: SensorCategory) -> [Double] {
        sensors.filter { $0.category == category }.map(\.celsius)
    }
}

// MARK: - 纯逻辑

nonisolated enum SensorMath {
    /// 0 °C、超过 130 °C、NaN / 无穷都当作无效读数（传感器未就绪或解码错误）。
    static func isValid(_ celsius: Double) -> Bool {
        celsius.isFinite && celsius > 0 && celsius <= 130
    }

    static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// 按名称合并，取最高值；按 CPU → GPU → 电池 → 固态硬盘 → 其他、再按名称排序。
    static func group(_ readings: [SensorReading]) -> [SensorGroup] {
        var order: [String] = []
        var merged: [String: SensorGroup] = [:]
        for reading in readings {
            if let existing = merged[reading.name] {
                merged[reading.name] = SensorGroup(
                    name: reading.name, category: existing.category,
                    celsius: max(existing.celsius, reading.celsius), count: existing.count + 1
                )
            } else {
                order.append(reading.name)
                merged[reading.name] = SensorGroup(name: reading.name, category: reading.category, celsius: reading.celsius, count: 1)
            }
        }
        let categories = SensorCategory.allCases
        return order.compactMap { merged[$0] }.sorted {
            let a = categories.firstIndex(of: $0.category) ?? 0
            let b = categories.firstIndex(of: $1.category) ?? 0
            return a != b ? a < b : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// 温度着色：< 70 °C 正常，70–90 偏高，> 90 过高。
nonisolated enum TemperatureLevel: Sendable, Equatable {
    case normal, warm, hot

    static func of(_ celsius: Double) -> TemperatureLevel {
        if celsius > 90 { return .hot }
        if celsius >= 70 { return .warm }
        return .normal
    }
}

nonisolated enum SensorFormat {
    static func celsius(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))°C"
    }

    static func rpm(_ value: Double) -> String {
        "\(Int(value.rounded()).formatted()) rpm"
    }
}

/// 按传感器名称归类。HID 名称来自 IOHIDServiceClient 的 "Product" 属性，SMC 键名是 4 字符代码。
nonisolated enum SensorClassifier {
    static func category(hidName: String) -> SensorCategory {
        let name = hidName.lowercased()
        if name.contains("battery") || name.contains("gas gauge") { return .battery }
        if name.hasPrefix("nand") || name.contains("ssd") { return .ssd }
        if name.contains("gpu") { return .gpu }
        if name.hasPrefix("pmu tdie") || name.hasPrefix("pacc") || name.hasPrefix("eacc")
            || name.contains("cpu") { return .cpu }
        return .other
    }

    static func category(smcKey key: String, chip: ChipFamily) -> SensorCategory {
        if chip == .intel {
            if key.hasPrefix("TC") { return .cpu }
            if key.hasPrefix("TG") { return .gpu }
            if key.hasPrefix("TB") { return .battery }
            if key.hasPrefix("TH") { return .ssd }
            return .other
        }
        if SMCKeys.gpu(for: chip).contains(key) { return .gpu }
        if SMCKeys.cpu(for: chip).contains(key) { return .cpu }
        return .other
    }
}

// MARK: - 芯片

nonisolated enum ChipFamily: Sendable, Equatable {
    /// generation：M1 = 1、M2 = 2 …
    case appleSilicon(generation: Int)
    case intel
    case unknown

    /// 解析 machdep.cpu.brand_string，例如 "Apple M1 Max"、"Intel(R) Core(TM) i7-9750H"。
    static func parse(brand: String) -> ChipFamily {
        if brand.localizedCaseInsensitiveContains("intel") { return .intel }
        guard brand.hasPrefix("Apple") else { return .unknown }
        let digits = brand.split(separator: " ").first { $0.hasPrefix("M") && $0.count > 1 }?.dropFirst()
        guard let digits, let generation = Int(digits) else { return .appleSilicon(generation: 0) }
        return .appleSilicon(generation: generation)
    }

    static var current: ChipFamily {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return .unknown }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return .unknown }
        return parse(brand: String(cString: buffer))
    }
}

/// 已知的 SMC 温度键（来自开源监控工具的公开整理，各代芯片不同）。
/// Apple 芯片的 CPU 首选 HID，SMC 键只在 HID 一个 CPU 传感器都读不到时兜底。
nonisolated enum SMCKeys {
    static let intelTemperatures = [
        "TC0P", "TC0D", "TC0E", "TC0F", "TC0H", "TC1C", "TC2C", "TC3C", "TC4C", "TC5C", "TC6C", "TC7C", "TC8C",
        "TG0P", "TG0D", "TG0E", "TG0F",
        "TB0T", "TB1T", "TB2T",
        "TH0A", "TH0B", "TH0a", "TH0b", "TH0P",
        "TA0P", "Tm0P", "TW0P",
    ]

    static func gpu(for chip: ChipFamily) -> [String] {
        guard case .appleSilicon(let generation) = chip else { return [] }
        switch generation {
        case 1: return ["Tg05", "Tg0D", "Tg0L", "Tg0T"]
        case 2: return ["Tg0f", "Tg0j"]
        case 3: return ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
        case 4: return ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"]
        default: return []
        }
    }

    static func cpu(for chip: ChipFamily) -> [String] {
        guard case .appleSilicon(let generation) = chip else { return [] }
        switch generation {
        case 1: return ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
        case 2: return ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
        case 3: return ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                        "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
        case 4: return ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        default: return []
        }
    }
}

/// SMC 原始字节 → 数值。类型是 4 字符代码（含尾随空格）。
nonisolated enum SMCDecoder {
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        func bigEndian(_ count: Int) -> UInt64? {
            guard bytes.count >= count else { return nil }
            return bytes.prefix(count).reduce(0) { $0 << 8 | UInt64($1) }
        }
        switch type {
        case "flt ":
            // Apple 芯片上为小端 Float32
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "fpe2":
            return bigEndian(2).map { Double($0) / 4 }
        case "fp88":
            return bigEndian(2).map { Double($0) / 256 }
        case "sp78":
            return bigEndian(2).map { Double(Int16(bitPattern: UInt16($0))) / 256 }
        case "ui8 ":
            return bigEndian(1).map { Double($0) }
        case "ui16":
            return bigEndian(2).map { Double($0) }
        case "ui32":
            return bigEndian(4).map { Double($0) }
        default:
            return nil
        }
    }

    static func fourCC(_ string: String) -> UInt32 {
        string.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func string(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - 历史

/// 固定容量的环形缓冲，满了覆盖最旧的元素。
nonisolated struct RingBuffer<Element> {
    let capacity: Int
    private var storage: [Element] = []
    private var head = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    var count: Int { storage.count }

    mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// 从旧到新。
    var elements: [Element] {
        Array(storage[head...] + storage[..<head])
    }
}

nonisolated struct ThermalPoint: Sendable, Equatable {
    let date: Date
    let cpuMax: Double?
    let fanRPM: Double?
}

/// 最近 10 分钟的 CPU 最高温度与风扇转速。2 秒采样时 300 个点刚好 10 分钟。
nonisolated struct ThermalHistory {
    static let window: TimeInterval = 10 * 60
    private var buffer = RingBuffer<ThermalPoint>(capacity: 300)

    mutating func append(_ point: ThermalPoint) {
        buffer.append(point)
    }

    func points(now: Date = Date()) -> [ThermalPoint] {
        buffer.elements.filter { now.timeIntervalSince($0.date) <= Self.window }
    }
}

// MARK: - 过热提醒（纯逻辑）

nonisolated struct OverheatAlertState: Equatable, Sendable {
    /// 连续 ≥ 阈值开始的时间
    var hotSince: Date?
    var lastSampleAt: Date?
    var lastAlertAt: Date?
}

nonisolated enum OverheatAlertPolicy {
    static let threshold: Double = 95
    static let sustained: TimeInterval = 2 * 60
    static let cooldown: TimeInterval = 30 * 60
    /// 两次采样间隔超过它（面板关了一段时间），「持续」计时重新开始。
    static let maxGap: TimeInterval = 90

    static func evaluate(cpuMax: Double?, now: Date, state: OverheatAlertState) -> (notify: Bool, state: OverheatAlertState) {
        var next = state
        let gap = state.lastSampleAt.map { now.timeIntervalSince($0) } ?? .infinity
        next.lastSampleAt = now
        guard let cpuMax, cpuMax >= threshold else {
            next.hotSince = nil
            return (false, next)
        }
        if next.hotSince == nil || gap > maxGap {
            next.hotSince = now
        }
        guard let since = next.hotSince, now.timeIntervalSince(since) >= sustained else { return (false, next) }
        if let last = state.lastAlertAt, now.timeIntervalSince(last) < cooldown { return (false, next) }
        next.lastAlertAt = now
        return (true, next)
    }

    /// `ps -Aceo pcpu=,comm= -r` 的输出取第一行进程名（已按 CPU 降序）。
    static func topProcessName(fromPS output: String) -> String? {
        for line in output.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, Double(parts[0]) != nil else { continue }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, name != "ps" { return name }
        }
        return nil
    }

    static func topProcessName() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pcpu=,comm=", "-r"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return topProcessName(fromPS: String(decoding: data, as: UTF8.self))
    }
}

// MARK: - 读取器

/// 缓存 HID 客户端与 SMC 连接；任何一步失败都只是少了那部分读数，不会崩溃。
nonisolated final class SensorReader: @unchecked Sendable {
    private let lock = NSLock()
    private let chip = ChipFamily.current
    private var hid: HIDThermalSource?
    private var smc: SMCConnection?
    private var didSetUp = false
    /// SMC 上实际存在的温度键（首次采样时探测一次）。
    private var smcTemperatureKeys: [(key: String, category: SensorCategory)] = []
    private var fanCount = 0

    init() {}

    func sample(includeAll: Bool) -> ThermalSample {
        lock.lock()
        defer { lock.unlock() }
        setUpIfNeeded()

        var sensors = hid?.read(includeOther: includeAll) ?? []
        let hidHasCPU = sensors.contains { $0.category == .cpu }
        for entry in smcTemperatureKeys {
            // Apple 芯片的 CPU 以 HID 为准，SMC 的 CPU 键只在 HID 读不到时使用
            if entry.category == .cpu, hidHasCPU, chip != .intel { continue }
            if entry.category == .other, !includeAll { continue }
            guard let value = smc?.read(entry.key) else { continue }
            sensors.append(SensorReading(name: entry.key, celsius: value, category: entry.category))
        }
        sensors = sensors.filter { SensorMath.isValid($0.celsius) }

        var fans: [FanReading] = []
        if let smc {
            for index in 0..<fanCount {
                guard let actual = smc.read("F\(index)Ac"), actual.isFinite, actual >= 0 else { continue }
                fans.append(FanReading(
                    index: index,
                    actual: actual,
                    minimum: smc.read("F\(index)Mn").flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                    maximum: smc.read("F\(index)Mx").flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                ))
            }
        }
        return ThermalSample(date: Date(), sensors: sensors, fans: fans, includesAllSensors: includeAll)
    }

    private func setUpIfNeeded() {
        guard !didSetUp else { return }
        didSetUp = true
        hid = HIDThermalSource()
        smc = SMCConnection()
        guard let smc else { return }
        fanCount = min(Int(smc.read("FNum") ?? 0), 8)

        var candidates: [String]
        switch chip {
        case .intel: candidates = SMCKeys.intelTemperatures
        case .appleSilicon: candidates = SMCKeys.gpu(for: chip) + SMCKeys.cpu(for: chip)
        case .unknown: candidates = []
        }
        // 去重并只保留真实存在的键
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0).inserted }
        smcTemperatureKeys = candidates.compactMap { key in
            smc.hasKey(key) ? (key, SensorClassifier.category(smcKey: key, chip: chip)) : nil
        }
    }
}

// MARK: - HID（Apple 芯片）

/// IOHIDEventSystemClient 系列函数不在公开头文件里，通过 dlsym 取，取不到就整体放弃。
nonisolated private final class HIDThermalSource {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double

    private static let temperatureEvent: Int64 = 15  // kIOHIDEventTypeTemperature
    private static let temperatureField = Int32(15 << 16)

    private let client: AnyObject
    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    private let services: [(service: AnyObject, name: String, category: SensorCategory)]

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
        func load<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let create = load("IOHIDEventSystemClientCreate", as: CreateFn.self),
              let setMatching = load("IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self),
              let copyServices = load("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self),
              let copyProperty = load("IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self),
              let copyEvent = load("IOHIDServiceClientCopyEvent", as: CopyEventFn.self),
              let getFloat = load("IOHIDEventGetFloatValue", as: GetFloatFn.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }

        // PrimaryUsagePage 0xff00 / PrimaryUsage 5：Apple 厂商页的温度传感器
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let list = copyServices(client)?.takeRetainedValue() as? [AnyObject], !list.isEmpty else { return nil }

        self.client = client
        self.copyEvent = copyEvent
        self.getFloat = getFloat
        self.services = list.compactMap { service in
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  !name.isEmpty else { return nil }
            return (service, name, SensorClassifier.category(hidName: name))
        }
    }

    func read(includeOther: Bool) -> [SensorReading] {
        services.compactMap { entry in
            guard includeOther || entry.category != .other,
                  let event = copyEvent(entry.service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            return SensorReading(name: entry.name, celsius: getFloat(event, Self.temperatureField), category: entry.category)
        }
    }
}

// MARK: - SMC

/// 与 AppleSMC 内核扩展通信的标准结构（与 C 版 SMCKeyData_t 内存布局一致，80 字节）。
nonisolated private struct SMCKeyData {
    struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    struct PowerLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }
    struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0 }

    var key: UInt32 = 0
    var version = Version()
    var powerLimit = PowerLimit()
    var keyInfo = KeyInfo()
    /// C 结构体里 keyInfo 按 12 字节对齐，Swift 会把下一个字段塞进尾部空隙，这里手动补齐。
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
        = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

nonisolated private final class SMCConnection {
    private static let kernelIndex: UInt32 = 2   // kSMCHandleYPCEvent
    private static let readKey: UInt8 = 5
    private static let readKeyInfo: UInt8 = 9

    private var connection: io_connect_t = 0
    /// 键 → (长度, 类型)；nil 表示探测过但不存在。
    private var infoCache: [UInt32: (size: UInt32, type: String)?] = [:]

    init?() {
        guard MemoryLayout<SMCKeyData>.stride == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func hasKey(_ key: String) -> Bool {
        info(SMCDecoder.fourCC(key)) != nil
    }

    func read(_ key: String) -> Double? {
        let code = SMCDecoder.fourCC(key)
        guard let info = info(code), info.size > 0, info.size <= 32 else { return nil }
        var input = SMCKeyData()
        input.key = code
        input.keyInfo.dataSize = info.size
        input.command = Self.readKey
        guard let output = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.size))) }
        return SMCDecoder.decode(type: info.type, bytes: bytes)
    }

    private func info(_ code: UInt32) -> (size: UInt32, type: String)? {
        if let cached = infoCache[code] { return cached }
        var input = SMCKeyData()
        input.key = code
        input.command = Self.readKeyInfo
        let value = call(&input).map { (size: $0.keyInfo.dataSize, type: SMCDecoder.string($0.keyInfo.dataType)) }
        infoCache[code] = .some(value)
        return value
    }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(
            connection, Self.kernelIndex, &input, MemoryLayout<SMCKeyData>.stride, &output, &outputSize
        )
        return result == kIOReturnSuccess && output.result == 0 ? output : nil
    }
}
