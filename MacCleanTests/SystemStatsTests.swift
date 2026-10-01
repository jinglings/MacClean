//
//  SystemStatsTests.swift
//  MacCleanTests
//
//  菜单栏状态面板：指标计算、综合状态判定、测速结果解析、应用内存归属 的单元测试
//

import Foundation
import Testing
@testable import MacClean

struct SystemStatsTests {

    // MARK: - 计算

    @Test func pressureIsInverseOfAvailableLevel() {
        #expect(SystemStats.pressure(fromAvailableLevel: 80) == 20)
        #expect(SystemStats.pressure(fromAvailableLevel: 0) == 100)
        #expect(SystemStats.pressure(fromAvailableLevel: 120) == 0)
    }

    @Test func cpuLoadFromTickDeltas() {
        let before = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let after = CPUTicks(user: 160, system: 90, idle: 950, nice: 0)
        // 忙 100 / 总 200
        #expect(SystemStats.cpuLoad(from: before, to: after) == 50)
        #expect(SystemStats.cpuLoad(from: after, to: after) == 0)
    }

    @Test func networkRateDropsWrappedSamples() {
        #expect(SystemStats.rate(from: 1_000, to: 5_000, seconds: 2) == 2_000)
        #expect(SystemStats.rate(from: 5_000, to: 1_000, seconds: 2) == 0)
        #expect(SystemStats.rate(from: 0, to: 1_000, seconds: 0) == 0)
    }

    // MARK: - 综合状态

    @Test func healthyMacIsGood() {
        let result = HealthAssessment.evaluate(
            disk: DiskStats(volumeName: "HD", total: 1_000_000_000_000, available: 300_000_000_000),
            memory: MemoryStats(total: 16, used: 8, compressed: 0, swapUsed: 0, pressure: 20),
            battery: BatteryStats(percent: 90, isCharging: false, isOnAC: false, minutesToEmpty: 200, minutesToFull: nil, cycleCount: 100, healthPercent: 95),
            thermal: .nominal
        )
        #expect(result.level == .good)
        #expect(result.issues.isEmpty)
    }

    @Test func attentionListsEveryReason() {
        let result = HealthAssessment.evaluate(
            disk: DiskStats(volumeName: "HD", total: 500_000_000_000, available: 10_000_000_000),
            memory: MemoryStats(total: 16, used: 15, compressed: 4, swapUsed: 2, pressure: 85),
            battery: BatteryStats(percent: 50, isCharging: false, isOnAC: false, minutesToEmpty: nil, minutesToFull: nil, cycleCount: 900, healthPercent: 72),
            thermal: .serious
        )
        #expect(result.level == .attention)
        #expect(result.issues == [String(localized: "磁盘剩余空间不足"), String(localized: "内存压力较高"), String(localized: "机器温度过高"), String(localized: "电池最大容量低于 80%")])
    }

    @Test func desktopWithoutBatteryIsNotPenalized() {
        let result = HealthAssessment.evaluate(
            disk: DiskStats(volumeName: "HD", total: 1_000_000_000_000, available: 500_000_000_000),
            memory: nil, battery: nil, thermal: .fair
        )
        #expect(result.level == .good)
    }

    // MARK: - 测速解析

    @Test func parsesNetworkQualityOutput() throws {
        let json = #"{"dl_throughput": 90752640, "ul_throughput": 15973044, "responsiveness": 228.49, "interface_name": "en0"}"#
        let result = try #require(NetworkSpeedTest.parse(Data(json.utf8)))
        #expect(result.download == 90_752_640)
        #expect(result.upload == 15_973_044)
        #expect(result.responsiveness == 228)
        #expect(NetworkSpeedTest.format(bitsPerSecond: result.download) == "90.8 Mbps")
        #expect(NetworkSpeedTest.format(bitsPerSecond: 250_000_000) == "250 Mbps")
    }

    @Test func rejectsIncompleteSpeedTestOutput() {
        #expect(NetworkSpeedTest.parse(Data(#"{"dl_throughput": 1}"#.utf8)) == nil)
        #expect(NetworkSpeedTest.parse(Data("not json".utf8)) == nil)
    }

    // MARK: - 应用内存归属

    @Test func helperProcessesCountTowardsTheirApp() {
        let apps: [(pid: pid_t, name: String, bundlePath: String)] = [
            (1, "Chrome", "/Applications/Google Chrome.app"),
            (2, "Chrome Beta", "/Applications/Google Chrome Beta.app"),
        ]
        let processes: [(path: String, footprint: UInt64)] = [
            ("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", 500),
            ("/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper (Renderer)", 300),
            ("/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta", 100),
            ("/usr/libexec/unrelated", 999),
        ]
        let result = MemoryActions.aggregate(apps: apps, processes: processes)
        #expect(result.map(\.footprint) == [800, 100])
        #expect(result.map(\.processCount) == [2, 1])
    }

    // MARK: - 真实采样冒烟

    @Test func liveSamplersReturnPlausibleValues() {
        let memory = SystemStats.memory()
        #expect(memory.total > 0)
        #expect(memory.used > 0 && memory.used <= memory.total)
        #expect((0...100).contains(memory.pressure))

        let disk = SystemStats.disk()
        #expect(disk != nil)
        #expect((disk?.available ?? 0) > 0 && (disk?.available ?? 0) <= (disk?.total ?? 0))

        #expect(SystemStats.cpuTicks() != nil)
        #expect(!SystemStats.modelName().isEmpty)

        if let battery = SystemStats.battery() {
            #expect((0...100).contains(battery.percent))
        }
    }
}
