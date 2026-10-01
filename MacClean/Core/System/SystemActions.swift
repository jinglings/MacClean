//
//  SystemActions.swift
//  MacClean
//
//  菜单栏面板里的「释放」动作：按内存占用列出应用、清除非活跃内存、网络测速、推出外接设备。
//

import AppKit
import Darwin

// MARK: - 应用内存占用

struct AppMemoryUsage: Identifiable, Sendable, Equatable {
    let pid: pid_t
    let name: String
    let bundlePath: String
    /// 主进程 + 其 .app 包内所有辅助进程（如浏览器渲染进程）的物理内存占用之和。
    let footprint: UInt64
    let processCount: Int
    nonisolated var id: pid_t { pid }
}

enum MemoryActions {

    /// 按内存占用排序的前台应用。辅助进程按可执行文件所在的 .app 包路径归属到应用。
    nonisolated static func topApps(apps: [(pid: pid_t, name: String, bundlePath: String)], limit: Int = 6) -> [AppMemoryUsage] {
        let processes = allProcessFootprints()
        return aggregate(apps: apps, processes: processes)
            .sorted { $0.footprint > $1.footprint }
            .prefix(limit)
            .map { $0 }
    }

    /// 纯函数，便于测试：把进程（路径 + 占用）归属到包路径是其前缀的应用。
    nonisolated static func aggregate(
        apps: [(pid: pid_t, name: String, bundlePath: String)],
        processes: [(path: String, footprint: UInt64)]
    ) -> [AppMemoryUsage] {
        apps.map { app in
            let prefix = app.bundlePath.hasSuffix("/") ? app.bundlePath : app.bundlePath + "/"
            let owned = processes.filter { $0.path.hasPrefix(prefix) }
            return AppMemoryUsage(
                pid: app.pid,
                name: app.name,
                bundlePath: app.bundlePath,
                footprint: owned.reduce(0) { $0 + $1.footprint },
                processCount: owned.count
            )
        }
    }

    nonisolated static func allProcessFootprints() -> [(path: String, footprint: UInt64)] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))

        var result: [(String, UInt64)] = []
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard status == 0 else { continue }
            result.append((String(cString: pathBuffer), usage.ri_phys_footprint))
        }
        return result
    }

    /// 调用系统自带的 purge 清除非活跃内存与磁盘缓存。需要管理员密码（系统弹窗）。
    /// 通过 osascript 子进程执行，等待授权框期间不阻塞主线程。
    /// 返回 nil 表示成功；否则为错误说明（含用户取消）。
    nonisolated static func purgeInactiveMemory() async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return String(localized: "执行失败")
            }
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            if process.terminationStatus == 0 { return nil }
            if stderr.contains("-128") { return String(localized: "已取消") }
            return String(localized: "执行失败")
        }.value
    }
}

// MARK: - 网络测速

struct SpeedTestResult: Sendable, Equatable {
    /// bit/s
    let download: Double
    let upload: Double
    /// 每分钟往返次数（RPM），越高越灵敏。
    let responsiveness: Int?
}

enum NetworkSpeedTest {

    /// 调用 macOS 自带的 networkQuality（与「系统设置」同源），约 15–20 秒。
    nonisolated static func run() async throws -> SpeedTestResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        process.arguments = ["-c"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        return try await withTaskCancellationHandler {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try Task.checkCancellation()
            guard let result = parse(data) else { throw SpeedTestError.unreadableOutput }
            return result
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    nonisolated static func parse(_ data: Data) -> SpeedTestResult? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let download = (json["dl_throughput"] as? NSNumber)?.doubleValue,
              let upload = (json["ul_throughput"] as? NSNumber)?.doubleValue else { return nil }
        let rpm = (json["responsiveness"] as? NSNumber)?.intValue ?? (json["dl_responsiveness"] as? NSNumber)?.intValue
        return SpeedTestResult(download: download, upload: upload, responsiveness: rpm)
    }

    nonisolated static func format(bitsPerSecond: Double) -> String {
        let mbps = bitsPerSecond / 1_000_000
        return mbps >= 100 ? String(format: "%.0f Mbps", mbps) : String(format: "%.1f Mbps", mbps)
    }
}

enum SpeedTestError: LocalizedError {
    case unreadableOutput
    var errorDescription: String? { String(localized: "无法读取测速结果") }
}
