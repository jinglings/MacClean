//
//  SystemMonitor.swift
//  MacClean
//
//  菜单栏面板的数据源。只在面板可见时每 2 秒采样一次，关闭后停止，不常驻消耗资源。
//

import AppKit
import Combine

struct SystemSnapshot: Sendable {
    let date: Date
    let disk: DiskStats?
    let memory: MemoryStats
    let ticks: CPUTicks?
    let thermal: ThermalLevel
    let battery: BatteryStats?
    let counters: NetworkCounters
    let network: NetworkInfo
    let volumes: [ExternalVolume]
    let registryBatteries: [String: Int]

    nonisolated static func capture() -> SystemSnapshot {
        SystemSnapshot(
            date: Date(),
            disk: SystemStats.disk(),
            memory: SystemStats.memory(),
            ticks: SystemStats.cpuTicks(),
            thermal: SystemStats.thermal(),
            battery: SystemStats.battery(),
            counters: SystemStats.networkCounters(),
            network: SystemStats.networkInfo(),
            volumes: SystemStats.externalVolumes(),
            registryBatteries: BluetoothBatteryReader.registryBatteries()
        )
    }
}

@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var disk: DiskStats?
    @Published private(set) var memory: MemoryStats?
    /// 需要两次采样才能得出，首次为 nil。
    @Published private(set) var cpuLoad: Int?
    @Published private(set) var thermal: ThermalLevel = .nominal
    @Published private(set) var battery: BatteryStats?
    @Published private(set) var network = NetworkInfo(kind: .none, ssid: nil)
    @Published private(set) var downloadRate: Int64?
    @Published private(set) var uploadRate: Int64?
    @Published private(set) var volumes: [ExternalVolume] = []
    @Published private(set) var bluetoothDevices: [BluetoothDeviceInfo] = []
    @Published private(set) var health = HealthAssessment(level: .good, issues: [])
    let modelName = SystemStats.modelName()

    private var timer: Timer?
    private var activeViewers = 0
    private var previous: SystemSnapshot?
    private var isSampling = false
    /// system_profiler 补充的电量（AirPods 左右耳/充电盒等），按地址索引，最多 60 秒刷新一次。
    private var profilerBatteries: [String: BluetoothBattery] = [:]
    private var profilerFetchedAt: Date?
    private var isFetchingProfiler = false

    private init() {}

    func start() {
        activeViewers += 1
        PermissionCenter.shared.refresh()
        guard timer == nil else { return }
        refresh()
        let ref = WeakRef(self)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in ref.object?.refresh() }
        }
    }

    func stop() {
        activeViewers = max(0, activeViewers - 1)
        guard activeViewers == 0 else { return }
        timer?.invalidate()
        timer = nil
        previous = nil
    }

    func refresh() {
        guard !isSampling else { return }
        isSampling = true
        Task.detached(priority: .utility) { [weak self] in
            let snapshot = SystemSnapshot.capture()
            await self?.apply(snapshot)
        }
    }

    private func apply(_ snapshot: SystemSnapshot) {
        isSampling = false
        disk = snapshot.disk
        memory = snapshot.memory
        thermal = snapshot.thermal
        battery = snapshot.battery
        network = snapshot.network
        volumes = snapshot.volumes
        updateBluetooth(registry: snapshot.registryBatteries)

        if let previous {
            if let before = previous.ticks, let after = snapshot.ticks {
                cpuLoad = SystemStats.cpuLoad(from: before, to: after)
            }
            let seconds = snapshot.date.timeIntervalSince(previous.date)
            downloadRate = SystemStats.rate(from: previous.counters.received, to: snapshot.counters.received, seconds: seconds)
            uploadRate = SystemStats.rate(from: previous.counters.sent, to: snapshot.counters.sent, seconds: seconds)
        }
        previous = snapshot

        health = HealthAssessment.evaluate(disk: disk, memory: memory, battery: battery, thermal: thermal)
    }

    // MARK: 蓝牙

    private var lastRegistryBatteries: [String: Int] = [:]

    private func updateBluetooth(registry: [String: Int]) {
        lastRegistryBatteries = registry
        let devices = BluetoothAccess.connectedDevices()
        bluetoothDevices = Self.merge(devices: devices, registry: registry, profiler: profilerBatteries)

        let missingBattery = bluetoothDevices.contains { $0.battery == nil }
        let stale = profilerFetchedAt.map { Date().timeIntervalSince($0) > 60 } ?? true
        guard missingBattery, stale, !isFetchingProfiler else { return }

        isFetchingProfiler = true
        Task.detached(priority: .utility) { [weak self] in
            let batteries = BluetoothBatteryReader.profilerBatteries()
            await self?.applyProfiler(batteries)
        }
    }

    private func applyProfiler(_ batteries: [String: BluetoothBattery]) {
        isFetchingProfiler = false
        profilerFetchedAt = Date()
        profilerBatteries = batteries
        bluetoothDevices = Self.merge(devices: bluetoothDevices, registry: lastRegistryBatteries, profiler: batteries)
    }

    nonisolated static func merge(
        devices: [BluetoothDeviceInfo],
        registry: [String: Int],
        profiler: [String: BluetoothBattery]
    ) -> [BluetoothDeviceInfo] {
        devices.map { device in
            var device = device
            if let percent = registry[device.address] {
                device.battery = BluetoothBattery(main: percent)
            } else if let battery = profiler[device.address] {
                device.battery = battery
            } else {
                device.battery = nil
            }
            return device
        }
    }

    /// 断开后立即刷新列表。
    func disconnect(_ device: BluetoothDeviceInfo) -> Bool {
        let ok = BluetoothAccess.disconnect(address: device.address)
        refresh()
        return ok
    }
}

// MARK: - 磁盘快速释放

@MainActor
final class QuickReleaseModel: ObservableObject {
    @Published private(set) var junkItems: [CleanableItem] = []
    @Published private(set) var trashItems: [CleanableItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var message: String?
    /// 清空废纸篓需要在面板里再点一次确认。
    @Published var isConfirmingEmptyTrash = false
    /// 点「清空」后展示的废纸篓内容摘要（读不到时为 nil）
    @Published var trashPreview: TrashPreview?

    var junkSize: Int64 { junkItems.reduce(0) { $0 + $1.size } }
    var trashSize: Int64 { trashItems.reduce(0) { $0 + $1.size } }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        Task.detached(priority: .userInitiated) { [weak self] in
            // 只纳入删了会自动重建的低风险项目，与「一键体检」口径一致。
            let junk = [JunkGroupID.appCaches, .browserCaches, .logs]
                .flatMap { JunkScanner.scan($0, home: home) }
                .filter(\.isSelected)
            let filtered = IgnoreList.filter(junk)
            let trash = JunkScanner.scanTrash(home: home)
            await self?.finishScan(junk: filtered, trash: trash)
        }
    }

    private func finishScan(junk: [CleanableItem], trash: [CleanableItem]) {
        junkItems = junk
        trashItems = trash
        isScanning = false
    }

    func cleanJunk() async {
        guard !isCleaning, !junkItems.isEmpty else { return }
        isCleaning = true
        let result = try? await CleanupManager.shared.clean(items: junkItems)
        isCleaning = false
        let moved = ByteCountFormatter.string(fromByteCount: result?.freedSpace ?? 0, countStyle: .file)
        message = String(localized: "已将 \(moved) 移入废纸篓，可在 MacClean「清理记录」中恢复；清空废纸篓后才会真正释放。")
        scan()
    }

    func emptyTrash() async {
        guard !isCleaning, !trashItems.isEmpty else { return }
        isConfirmingEmptyTrash = false
        isCleaning = true
        let result = try? await CleanupManager.shared.clean(items: trashItems)
        isCleaning = false
        let freed = ByteCountFormatter.string(fromByteCount: result?.permanentlyFreed ?? 0, countStyle: .file)
        let failed = result?.errors.count ?? 0
        message = failed > 0
            ? String(localized: "已永久释放 \(freed)，\(failed) 项因权限未能删除（可在「系统设置 › 隐私与安全性」为 MacClean 开启完全磁盘访问权限）")
            : String(localized: "已永久释放 \(freed)")
        scan()
        SystemMonitor.shared.refresh()
    }
}
