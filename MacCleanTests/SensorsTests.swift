//
//  SensorsTests.swift
//  MacCleanTests
//
//  温度与风扇：传感器分类、无效读数过滤、SMC 解码、CPU 平均/最高、着色阈值、环形缓冲、过热提醒判定；
//  外加一次真机读取（打印读数与耗时）和菜单栏面板截图（设置 MACCLEAN_THERMAL_SNAPSHOT_DIR 时）。
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MacClean

struct SensorsTests {

    private func reading(_ name: String, _ celsius: Double) -> SensorReading {
        SensorReading(name: name, celsius: celsius, category: SensorClassifier.category(hidName: name))
    }

    // MARK: - 分类

    @Test func classifiesM1ProMaxHIDNames() {
        #expect(SensorClassifier.category(hidName: "PMU tdie1") == .cpu)
        #expect(SensorClassifier.category(hidName: "PMU tdie10") == .cpu)
        #expect(SensorClassifier.category(hidName: "gas gauge battery") == .battery)
        #expect(SensorClassifier.category(hidName: "NAND CH0 temp") == .ssd)
        #expect(SensorClassifier.category(hidName: "PMU tdev3") == .other)
        #expect(SensorClassifier.category(hidName: "PMU tcal") == .other)
        #expect(SensorClassifier.category(hidName: "PMU TP1g") == .other)
    }

    @Test func classifiesM1M2M3StyleMTRNames() {
        #expect(SensorClassifier.category(hidName: "pACC MTR Temp Sensor0") == .cpu)
        #expect(SensorClassifier.category(hidName: "eACC MTR Temp Sensor3") == .cpu)
        #expect(SensorClassifier.category(hidName: "GPU MTR Temp Sensor1") == .gpu)
        #expect(SensorClassifier.category(hidName: "SOC MTR Temp Sensor0") == .other)
        #expect(SensorClassifier.category(hidName: "ANE MTR Temp Sensor1") == .other)
        #expect(SensorClassifier.category(hidName: "PMGR SOC Die Temp Sensor0") == .other)
        #expect(SensorClassifier.category(hidName: "Battery") == .battery)
        #expect(SensorClassifier.category(hidName: "something new") == .other)
    }

    @Test func classifiesIntelSMCKeys() {
        #expect(SensorClassifier.category(smcKey: "TC0P", chip: .intel) == .cpu)
        #expect(SensorClassifier.category(smcKey: "TC3C", chip: .intel) == .cpu)
        #expect(SensorClassifier.category(smcKey: "TG0D", chip: .intel) == .gpu)
        #expect(SensorClassifier.category(smcKey: "TB0T", chip: .intel) == .battery)
        #expect(SensorClassifier.category(smcKey: "TH0a", chip: .intel) == .ssd)
        #expect(SensorClassifier.category(smcKey: "TA0P", chip: .intel) == .other)
    }

    @Test func classifiesAppleSiliconSMCKeysPerGeneration() {
        #expect(SensorClassifier.category(smcKey: "Tg05", chip: .appleSilicon(generation: 1)) == .gpu)
        #expect(SensorClassifier.category(smcKey: "Tp01", chip: .appleSilicon(generation: 1)) == .cpu)
        #expect(SensorClassifier.category(smcKey: "Tf14", chip: .appleSilicon(generation: 3)) == .gpu)
        #expect(SensorClassifier.category(smcKey: "Te05", chip: .appleSilicon(generation: 3)) == .cpu)
        // 未知新芯片：不猜，归「其他」
        #expect(SensorClassifier.category(smcKey: "Tg05", chip: .appleSilicon(generation: 9)) == .other)
        #expect(SMCKeys.gpu(for: .appleSilicon(generation: 9)).isEmpty)
    }

    @Test func parsesChipFamily() {
        #expect(ChipFamily.parse(brand: "Apple M1 Max") == .appleSilicon(generation: 1))
        #expect(ChipFamily.parse(brand: "Apple M3") == .appleSilicon(generation: 3))
        #expect(ChipFamily.parse(brand: "Apple M4 Pro") == .appleSilicon(generation: 4))
        #expect(ChipFamily.parse(brand: "Apple processor") == .appleSilicon(generation: 0))
        #expect(ChipFamily.parse(brand: "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz") == .intel)
        #expect(ChipFamily.parse(brand: "") == .unknown)
    }

    // MARK: - 过滤与汇总

    @Test func filtersJunkReadings() {
        #expect(SensorMath.isValid(45.2))
        #expect(SensorMath.isValid(130))
        #expect(!SensorMath.isValid(0))
        #expect(!SensorMath.isValid(-3))
        #expect(!SensorMath.isValid(130.5))
        #expect(!SensorMath.isValid(.nan))
        #expect(!SensorMath.isValid(.infinity))
    }

    @Test func cpuAverageAndMax() {
        let sample = ThermalSample(
            date: Date(),
            sensors: [reading("PMU tdie1", 40), reading("PMU tdie2", 50), reading("PMU tdie1", 60),
                      reading("gas gauge battery", 31), reading("gas gauge battery", 33), reading("NAND CH0 temp", 35)],
            fans: [],
            includesAllSensors: false
        )
        #expect(sample.cpuAverage == 50)
        #expect(sample.cpuMax == 60)
        #expect(sample.battery == 32)
        #expect(sample.ssd == 35)
        #expect(sample.gpu == nil)
        #expect(!sample.hasFans)
        #expect(!sample.isUnavailable)
    }

    @Test func emptySampleIsUnavailable() {
        let sample = ThermalSample(date: Date(), sensors: [], fans: [], includesAllSensors: true)
        #expect(sample.isUnavailable)
        #expect(sample.cpuMax == nil)
        #expect(sample.cpuAverage == nil)
    }

    @Test func groupsDuplicateNamesByMaxAndSortsByCategory() {
        let groups = SensorMath.group([
            reading("PMU tdev1", 44), reading("PMU tdie2", 45), reading("gas gauge battery", 32),
            reading("PMU tdie10", 47), reading("PMU tdie2", 46),
        ])
        #expect(groups.map(\.name) == ["PMU tdie2", "PMU tdie10", "gas gauge battery", "PMU tdev1"])
        #expect(groups[0].celsius == 46)
        #expect(groups[0].count == 2)
    }

    @Test func fanIdleAndFraction() {
        let idle = FanReading(index: 0, actual: 0, minimum: 1200, maximum: 6000)
        let spinning = FanReading(index: 1, actual: 3000, minimum: 1200, maximum: 6000)
        #expect(idle.isIdle)
        #expect(!spinning.isIdle)
        #expect(spinning.fraction == 0.5)
        #expect(FanReading(index: 0, actual: 2000, minimum: nil, maximum: nil).fraction == 0)
    }

    // MARK: - SMC 解码

    @Test func decodesFloatLittleEndian() {
        // 实机 F0Mn = 1499.0
        #expect(SMCDecoder.decode(type: "flt ", bytes: [0, 96, 187, 68]) == 1499)
        #expect(SMCDecoder.decode(type: "flt ", bytes: [0, 96]) == nil)
    }

    @Test func decodesFpe2() {
        // 0x1770 = 6000 → /4 = 1500 rpm
        #expect(SMCDecoder.decode(type: "fpe2", bytes: [0x17, 0x70]) == 1500)
    }

    @Test func decodesSp78() {
        // 0x3E80 = 16000 → /256 = 62.5 °C
        #expect(SMCDecoder.decode(type: "sp78", bytes: [0x3E, 0x80]) == 62.5)
        // 负数
        #expect(SMCDecoder.decode(type: "sp78", bytes: [0xFF, 0x00]) == -1)
    }

    @Test func decodesIntegersAndRejectsUnknownTypes() {
        #expect(SMCDecoder.decode(type: "ui8 ", bytes: [2]) == 2)
        #expect(SMCDecoder.decode(type: "ui16", bytes: [0x01, 0x00]) == 256)
        #expect(SMCDecoder.decode(type: "ui32", bytes: [0, 0, 0x08, 0x4B]) == 2123)
        #expect(SMCDecoder.decode(type: "{fds", bytes: [1, 2, 3, 4]) == nil)
        #expect(SMCDecoder.decode(type: "fpe2", bytes: []) == nil)
    }

    @Test func fourCCRoundTrip() {
        #expect(SMCDecoder.fourCC("FNum") == 0x464E_756D)
        #expect(SMCDecoder.string(SMCDecoder.fourCC("TC0P")) == "TC0P")
    }

    // MARK: - 着色

    @Test func temperatureColorThresholds() {
        #expect(TemperatureLevel.of(45) == .normal)
        #expect(TemperatureLevel.of(69.9) == .normal)
        #expect(TemperatureLevel.of(70) == .warm)
        #expect(TemperatureLevel.of(90) == .warm)
        #expect(TemperatureLevel.of(90.1) == .hot)
    }

    @Test func formatsTemperatureAndRPM() {
        #expect(SensorFormat.celsius(61.6) == "62°C")
        #expect(SensorFormat.celsius(nil) == "—")
        #expect(SensorFormat.rpm(1499.66).hasSuffix(" rpm"))
    }

    // MARK: - 环形缓冲与历史

    @Test func ringBufferKeepsNewestInOrder() {
        var buffer = RingBuffer<Int>(capacity: 3)
        #expect(buffer.elements.isEmpty)
        buffer.append(1)
        buffer.append(2)
        #expect(buffer.elements == [1, 2])
        buffer.append(3)
        buffer.append(4)
        buffer.append(5)
        #expect(buffer.elements == [3, 4, 5])
        #expect(buffer.count == 3)
    }

    @Test func historyDropsPointsOlderThanTenMinutes() {
        var history = ThermalHistory()
        let now = Date()
        history.append(ThermalPoint(date: now.addingTimeInterval(-700), cpuMax: 50, fanRPM: nil))
        history.append(ThermalPoint(date: now.addingTimeInterval(-300), cpuMax: 55, fanRPM: 1500))
        history.append(ThermalPoint(date: now, cpuMax: 60, fanRPM: 1600))
        #expect(history.points(now: now).map(\.cpuMax) == [55, 60])
    }

    @Test func historyCapsAtThreeHundredPoints() {
        var history = ThermalHistory()
        let now = Date()
        for index in 0..<400 {
            history.append(ThermalPoint(date: now.addingTimeInterval(Double(index - 400)), cpuMax: Double(index), fanRPM: nil))
        }
        let points = history.points(now: now)
        #expect(points.count == 300)
        #expect(points.first?.cpuMax == 100)
        #expect(points.last?.cpuMax == 399)
    }

    // MARK: - 过热提醒

    @Test func overheatNeedsTwoSustainedMinutes() {
        let start = Date()
        var state = OverheatAlertState()
        var notified = false
        for second in stride(from: 0, through: 118, by: 2) {
            let result = OverheatAlertPolicy.evaluate(cpuMax: 96, now: start.addingTimeInterval(Double(second)), state: state)
            state = result.state
            notified = notified || result.notify
        }
        #expect(!notified)
        let result = OverheatAlertPolicy.evaluate(cpuMax: 97, now: start.addingTimeInterval(120), state: state)
        #expect(result.notify)
        #expect(result.state.lastAlertAt == start.addingTimeInterval(120))
    }

    @Test func overheatResetsWhenTemperatureDrops() {
        let start = Date()
        var state = OverheatAlertPolicy.evaluate(cpuMax: 96, now: start, state: OverheatAlertState()).state
        state = OverheatAlertPolicy.evaluate(cpuMax: 80, now: start.addingTimeInterval(60), state: state).state
        #expect(state.hotSince == nil)
        state = OverheatAlertPolicy.evaluate(cpuMax: 96, now: start.addingTimeInterval(62), state: state).state
        let result = OverheatAlertPolicy.evaluate(cpuMax: 96, now: start.addingTimeInterval(150), state: state)
        // 从 62 秒重新计时，到 150 秒只持续了 88 秒
        #expect(!result.notify)
    }

    @Test func overheatRestartsAfterSamplingGap() {
        let start = Date()
        var state = OverheatAlertPolicy.evaluate(cpuMax: 99, now: start, state: OverheatAlertState()).state
        // 面板关了 5 分钟后再打开：不能把中间没采样的时间算作「持续」
        let result = OverheatAlertPolicy.evaluate(cpuMax: 99, now: start.addingTimeInterval(300), state: state)
        #expect(!result.notify)
        state = result.state
        #expect(state.hotSince == start.addingTimeInterval(300))
    }

    @Test func overheatWorksWithMinuteSamples() {
        // 菜单栏图标显示温度时 60 秒采一次
        let start = Date()
        var state = OverheatAlertState()
        var results: [Bool] = []
        for minute in 0...2 {
            let result = OverheatAlertPolicy.evaluate(cpuMax: 98, now: start.addingTimeInterval(Double(minute) * 60), state: state)
            state = result.state
            results.append(result.notify)
        }
        #expect(results == [false, false, true])
    }

    @Test func overheatCooldownIsThirtyMinutes() {
        let start = Date()
        var state = OverheatAlertState()
        var times: [TimeInterval] = []
        for second in stride(from: 0, through: 3700, by: 10) {
            let now = start.addingTimeInterval(Double(second))
            let result = OverheatAlertPolicy.evaluate(cpuMax: 100, now: now, state: state)
            state = result.state
            if result.notify { times.append(Double(second)) }
        }
        #expect(times == [120, 1920])
    }

    @Test func overheatIgnoresMissingReadings() {
        let result = OverheatAlertPolicy.evaluate(cpuMax: nil, now: Date(), state: OverheatAlertState(hotSince: Date()))
        #expect(!result.notify)
        #expect(result.state.hotSince == nil)
    }

    @Test func parsesTopProcessFromPS() {
        let output = """
         88.5 kernel_task
         42.0 Google Chrome Helper (Renderer)
          0.0 ps
        """
        #expect(OverheatAlertPolicy.topProcessName(fromPS: output) == "kernel_task")
        #expect(OverheatAlertPolicy.topProcessName(fromPS: "  0.1 ps\n  0.0 launchd\n") == "launchd")
        #expect(OverheatAlertPolicy.topProcessName(fromPS: "") == nil)
    }

    // MARK: - 真机读取

    /// 读本机传感器并打印读数（不对数值做断言：CI / 虚拟机上可能什么都读不到，那时应得到空样本而不是崩溃）。
    @Test func readsSensorsOnThisMac() {
        let reader = SensorReader()
        _ = reader.sample(includeAll: false)  // 首次会打开连接、探测 SMC 键
        var fastTimes: [Double] = []
        var sample = reader.sample(includeAll: false)
        for _ in 0..<5 {
            let start = Date()
            sample = reader.sample(includeAll: false)
            fastTimes.append(Date().timeIntervalSince(start) * 1000)
        }
        let fullStart = Date()
        let full = reader.sample(includeAll: true)
        let fullTime = Date().timeIntervalSince(fullStart) * 1000

        func c(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "nil" }
        print("[sensors] chip=\(ChipFamily.current) default-sample sensors=\(sample.sensors.count) full-sample sensors=\(full.sensors.count) groups=\(full.groups.count)")
        print("[sensors] CPU avg=\(c(sample.cpuAverage)) max=\(c(sample.cpuMax)) GPU=\(c(sample.gpu)) battery=\(c(sample.battery)) SSD=\(c(sample.ssd))")
        print("[sensors] fans=" + sample.fans.map { "#\($0.index) \(c($0.actual)) (min \(c($0.minimum)) max \(c($0.maximum)))" }.joined(separator: ", "))
        print("[sensors] default sample ms=" + fastTimes.map { String(format: "%.1f", $0) }.joined(separator: ",") + String(format: " full sample ms=%.1f", fullTime))
        print("[sensors] all: " + full.groups.map { "\($0.name)=\(c($0.celsius))\($0.count > 1 ? "x\($0.count)" : "")[\($0.category.rawValue)]" }.joined(separator: " "))

        #expect(sample.sensors.allSatisfy { SensorMath.isValid($0.celsius) })
        #expect(full.sensors.count >= sample.sensors.count)
    }
}

// MARK: - 截图

@MainActor
struct ThermalSnapshotTests {
    @Test func renderMenuBarAndThermalPanel() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MACCLEAN_THERMAL_SNAPSHOT_DIR"] else { return }
        let outDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? "zh" : "en"

        let monitor = SystemMonitor.shared
        monitor.redactsPersonalInfo = true
        // 先跑一阵真实采样，让走势图有数据
        monitor.start()
        try await Task.sleep(for: .seconds(14))

        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await snapshot(
                MenuBarView().environmentObject(AppState.shared),
                size: CGSize(width: 400, height: 700), appearance: appearance,
                to: outDir.appendingPathComponent("\(mode)-\(language)-menubar.png")
            )
            try await snapshot(
                MenuBarView(initialPanel: .thermal).environmentObject(AppState.shared),
                size: CGSize(width: 400, height: 860), appearance: appearance,
                to: outDir.appendingPathComponent("\(mode)-\(language)-thermal.png")
            )
        }
        monitor.stop()
    }

    private func snapshot<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL) async throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .top))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<8 {
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
