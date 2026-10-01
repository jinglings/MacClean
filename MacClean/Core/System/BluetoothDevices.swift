//
//  BluetoothDevices.swift
//  MacClean
//
//  已连接的蓝牙设备与电量，以及菜单栏面板需要的两项隐私权限（蓝牙、定位）。
//
//  数据来源：
//  - 设备列表：IOBluetooth 已配对且已连接的设备（需蓝牙权限）。
//  - 电量：优先读 IORegistry（Apple 妙控系列等 HID 外设，毫秒级）；
//    缺电量的设备（如 AirPods 的左右耳/充电盒）再用 system_profiler 补齐，结果缓存 60 秒。
//

import Foundation
import IOKit
import IOBluetooth
import CoreBluetooth
import CoreLocation
import AppKit
import Combine

// MARK: - 模型

struct BluetoothBattery: Sendable, Equatable {
    var main: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?

    nonisolated var isEmpty: Bool { main == nil && left == nil && right == nil && caseLevel == nil }

    /// 用于排序与低电量提示的代表值（取最低的一项）。
    nonisolated var lowest: Int? { [main, left, right, caseLevel].compactMap { $0 }.min() }

    nonisolated var summary: String? {
        if let main { return "\(main)%" }
        var parts: [String] = []
        if let left { parts.append(String(localized: "左 \(left)%")) }
        if let right { parts.append(String(localized: "右 \(right)%")) }
        if let caseLevel { parts.append(String(localized: "盒 \(caseLevel)%")) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

struct BluetoothDeviceInfo: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case keyboard, mouse, trackpad, headphones, speaker, gamepad, phone, computer, other

        var icon: String {
            switch self {
            case .keyboard: return "keyboard"
            case .mouse: return "computermouse"
            case .trackpad: return "rectangle.and.hand.point.up.left"
            case .headphones: return "headphones"
            case .speaker: return "hifispeaker"
            case .gamepad: return "gamecontroller"
            case .phone: return "iphone"
            case .computer: return "laptopcomputer"
            case .other: return "dot.radiowaves.left.and.right"
            }
        }
    }

    /// 统一为小写冒号分隔，如 "a8:be:27:e0:7a:82"。
    let address: String
    let name: String
    let kind: Kind
    var battery: BluetoothBattery?

    nonisolated var id: String { address }
}

// MARK: - 纯函数（可测试）

enum BluetoothParsing {

    /// "A8-BE-27-E0-7A-82" / "A8:BE:27:E0:7A:82" → "a8:be:27:e0:7a:82"
    nonisolated static func normalizeAddress(_ raw: String) -> String {
        raw.lowercased().replacingOccurrences(of: "-", with: ":")
    }

    /// 由蓝牙设备类别（Class of Device）与名称推断设备种类。
    nonisolated static func kind(major: UInt32, minor: UInt32, name: String) -> BluetoothDeviceInfo.Kind {
        let lower = name.lowercased()
        if lower.contains("trackpad") || lower.contains("触控板") { return .trackpad }
        if lower.contains("airpods") || lower.contains("beats") { return .headphones }

        switch major {
        case 0x01: return .computer
        case 0x02: return .phone
        case 0x04: // 音频/视频
            switch minor {
            case 0x05, 0x0A: return .speaker          // 扬声器、HiFi 音箱
            default: return .headphones                // 耳机、头戴式、免提等
            }
        case 0x05: // 外设：minor 的高 2 位表示键盘/指点设备，低 4 位表示手柄等
            if minor & 0x10 != 0 { return .keyboard }
            if minor & 0x20 != 0 {
                return lower.contains("keyboard") ? .keyboard : .mouse
            }
            if (minor & 0x0F) == 0x01 || (minor & 0x0F) == 0x02 { return .gamepad }
            return .other
        default:
            if lower.contains("keyboard") || lower.contains("键盘") { return .keyboard }
            if lower.contains("mouse") || lower.contains("鼠标") { return .mouse }
            return .other
        }
    }

    /// 解析 `system_profiler SPBluetoothDataType -json` 中已连接设备的电量。
    nonisolated static func profilerBatteries(from data: Data) -> [String: BluetoothBattery] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }

        var result: [String: BluetoothBattery] = [:]
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for case let info as [String: Any] in entry.values {
                    guard let address = info["device_address"] as? String else { continue }
                    let battery = BluetoothBattery(
                        main: percent(info["device_batteryLevelMain"]),
                        left: percent(info["device_batteryLevelLeft"]),
                        right: percent(info["device_batteryLevelRight"]),
                        caseLevel: percent(info["device_batteryLevelCase"])
                    )
                    if !battery.isEmpty { result[normalizeAddress(address)] = battery }
                }
            }
        }
        return result
    }

    nonisolated private static func percent(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        guard let text = value as? String else { return nil }
        return Int(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - 电量读取（后台线程）

enum BluetoothBatteryReader {

    /// IORegistry 中 HID 外设上报的电量，按设备地址索引。
    nonisolated static func registryBatteries() -> [String: Int] {
        var result: [String: Int] = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let address = IORegistryEntryCreateCFProperty(service, "DeviceAddress" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  let percent = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Int else { continue }
            result[BluetoothParsing.normalizeAddress(address)] = percent
        }
        return result
    }

    /// system_profiler 较慢（约 1 秒），只在有设备缺少电量时调用。
    nonisolated static func profilerBatteries() -> [String: BluetoothBattery] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return BluetoothParsing.profilerBatteries(from: data)
    }
}

// MARK: - 设备列表与操作（主线程）

@MainActor
enum BluetoothAccess {

    /// 已配对且当前已连接的设备。调用前必须已获得蓝牙权限，否则系统会弹出授权框。
    static func connectedDevices() -> [BluetoothDeviceInfo] {
        guard PermissionCenter.shared.bluetooth == .granted else { return [] }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired
            .filter { $0.isConnected() }
            .compactMap { device in
                guard let rawAddress = device.addressString else { return nil }
                let name = device.name ?? device.nameOrAddress ?? rawAddress
                return BluetoothDeviceInfo(
                    address: BluetoothParsing.normalizeAddress(rawAddress),
                    name: name,
                    kind: BluetoothParsing.kind(major: device.deviceClassMajor, minor: device.deviceClassMinor, name: name),
                    battery: nil
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 断开连接（设备保持配对，可随时重新连接）。
    static func disconnect(address: String) -> Bool {
        guard let device = IOBluetoothDevice(addressString: address) else { return false }
        return device.closeConnection() == kIOReturnSuccess
    }
}

// MARK: - 权限

enum PermissionState: Equatable {
    case notDetermined, granted, denied
    /// 系统级开关已关闭（如「定位服务」总开关）。
    case disabled
}

/// 集中管理菜单栏面板需要的蓝牙与定位权限。只在用户点击时发起请求，不在打开面板时自动弹窗。
@MainActor
final class PermissionCenter: NSObject, ObservableObject {
    static let shared = PermissionCenter()

    @Published private(set) var bluetooth: PermissionState = .notDetermined
    @Published private(set) var location: PermissionState = .notDetermined

    private let locationManager = CLLocationManager()
    private var bluetoothManager: CBCentralManager?

    private override init() {
        super.init()
        locationManager.delegate = self
        refresh()
    }

    func refresh() {
        switch CBManager.authorization {
        case .allowedAlways: bluetooth = .granted
        case .notDetermined: bluetooth = .notDetermined
        case .denied, .restricted: bluetooth = .denied
        @unknown default: bluetooth = .denied
        }

        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorized: location = .granted
        case .notDetermined: location = CLLocationManager.locationServicesEnabled() ? .notDetermined : .disabled
        case .denied, .restricted: location = CLLocationManager.locationServicesEnabled() ? .denied : .disabled
        @unknown default: location = .denied
        }
    }

    /// 首次调用时系统弹出蓝牙授权框；已拒绝时打开系统设置。
    func requestBluetooth() {
        switch bluetooth {
        case .notDetermined:
            // 创建 CBCentralManager 即触发授权框，结果在 centralManagerDidUpdateState 回调。
            bluetoothManager = CBCentralManager(delegate: self, queue: nil)
        case .denied, .disabled:
            openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
        case .granted:
            break
        }
    }

    func requestLocation() {
        switch location {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied:
            openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        case .disabled:
            openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        case .granted:
            break
        }
    }

    private func openSettings(_ url: String) {
        guard let url = URL(string: url) else { return }
        NSWorkspace.shared.open(url)
    }

    fileprivate func authorizationChanged() {
        refresh()
        SystemMonitor.shared.refresh()
    }
}

extension PermissionCenter: CLLocationManagerDelegate, CBCentralManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in PermissionCenter.shared.authorizationChanged() }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in PermissionCenter.shared.authorizationChanged() }
    }
}
