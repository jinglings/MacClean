//
//  BluetoothDevicesTests.swift
//  MacCleanTests
//
//  蓝牙设备：地址归一化、设备种类推断、system_profiler 电量解析、电量合并优先级 的单元测试
//

import Foundation
import Testing
@testable import MacClean

struct BluetoothDevicesTests {

    @Test func normalizesRegistryAndProfilerAddresses() {
        #expect(BluetoothParsing.normalizeAddress("A8-BE-27-E0-7A-82") == "a8:be:27:e0:7a:82")
        #expect(BluetoothParsing.normalizeAddress("A8:BE:27:E0:7A:82") == "a8:be:27:e0:7a:82")
    }

    @Test func infersKindFromClassOfDeviceAndName() {
        #expect(BluetoothParsing.kind(major: 0x05, minor: 0x10, name: "Keychron K2") == .keyboard)
        #expect(BluetoothParsing.kind(major: 0x05, minor: 0x20, name: "MX Master 3") == .mouse)
        #expect(BluetoothParsing.kind(major: 0x05, minor: 0x20, name: "Magic Trackpad") == .trackpad)
        #expect(BluetoothParsing.kind(major: 0x05, minor: 0x02, name: "Xbox Wireless Controller") == .gamepad)
        #expect(BluetoothParsing.kind(major: 0x04, minor: 0x06, name: "WH-1000XM5") == .headphones)
        #expect(BluetoothParsing.kind(major: 0x04, minor: 0x05, name: "SoundLink") == .speaker)
        #expect(BluetoothParsing.kind(major: 0x04, minor: 0x05, name: "My AirPods Pro") == .headphones)
        #expect(BluetoothParsing.kind(major: 0x02, minor: 0x03, name: "iPhone") == .phone)
        #expect(BluetoothParsing.kind(major: 0x1F, minor: 0, name: "Unknown") == .other)
    }

    @Test func parsesConnectedDeviceBatteriesFromSystemProfiler() throws {
        let json = """
        {"SPBluetoothDataType": [{
          "controller_properties": {},
          "device_connected": [
            {"Magic Mouse": {"device_address": "A8:BE:27:E0:7A:82", "device_batteryLevelMain": "100%", "device_minorType": "Mouse"}},
            {"AirPods Pro": {"device_address": "11:22:33:44:55:66", "device_batteryLevelLeft": "80%", "device_batteryLevelRight": "75%", "device_batteryLevelCase": "40%"}},
            {"No Battery Speaker": {"device_address": "99:88:77:66:55:44"}}
          ],
          "device_not_connected": [
            {"Old Mouse": {"device_address": "00:00:00:00:00:01", "device_batteryLevelMain": "5%"}}
          ]
        }]}
        """
        let batteries = BluetoothParsing.profilerBatteries(from: Data(json.utf8))

        #expect(batteries.count == 2)
        #expect(batteries["a8:be:27:e0:7a:82"] == BluetoothBattery(main: 100))
        let airpods = try #require(batteries["11:22:33:44:55:66"])
        #expect(airpods.summary == [String(localized: "左 \(80)%"), String(localized: "右 \(75)%"), String(localized: "盒 \(40)%")].joined(separator: " "))
        #expect(airpods.lowest == 40)
        // 未连接的设备不纳入
        #expect(batteries["00:00:00:00:00:01"] == nil)
    }

    @Test func profilerParserToleratesGarbage() {
        #expect(BluetoothParsing.profilerBatteries(from: Data("oops".utf8)).isEmpty)
        #expect(BluetoothParsing.profilerBatteries(from: Data(#"{"SPBluetoothDataType": []}"#.utf8)).isEmpty)
    }

    @Test func registryBatteryTakesPriorityOverProfiler() {
        let devices = [
            BluetoothDeviceInfo(address: "a8:be:27:e0:7a:82", name: "Magic Mouse", kind: .mouse, battery: nil),
            BluetoothDeviceInfo(address: "11:22:33:44:55:66", name: "AirPods Pro", kind: .headphones, battery: nil),
            BluetoothDeviceInfo(address: "99:88:77:66:55:44", name: "Speaker", kind: .speaker, battery: nil),
        ]
        let merged = SystemMonitor.merge(
            devices: devices,
            registry: ["a8:be:27:e0:7a:82": 64],
            profiler: [
                "a8:be:27:e0:7a:82": BluetoothBattery(main: 60),
                "11:22:33:44:55:66": BluetoothBattery(left: 80, right: 75),
            ]
        )
        #expect(merged.map { $0.battery?.summary } == ["64%", [String(localized: "左 \(80)%"), String(localized: "右 \(75)%")].joined(separator: " "), nil])
    }

    /// IORegistry 读取不需要蓝牙权限；本机若连接了 Apple 妙控外设应能读到 0–100 的电量。
    @Test func liveRegistryBatteriesAreInRange() {
        let batteries = BluetoothBatteryReader.registryBatteries()
        #expect(batteries.values.allSatisfy { (0...100).contains($0) })
        #expect(batteries.keys.allSatisfy { $0 == $0.lowercased() && !$0.contains("-") })
    }
}
