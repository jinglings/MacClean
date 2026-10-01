//
//  MaintenanceTasks.swift
//  MacClean
//
//  系统维护任务：命令构造（纯函数，可测试）+ 后台执行。
//  需要管理员权限的任务合并成一个脚本，通过 osascript「with administrator privileges」执行，
//  用户只需输入一次密码；整个过程在后台线程进行，不阻塞界面。
//

import Foundation

// MARK: - 任务定义

enum MaintenanceTask: String, CaseIterable, Identifiable, Sendable {
    case flushDNS
    case rebuildSpotlight
    case rebuildLaunchServices
    case deleteLocalSnapshots
    case periodicScripts
    case purgeMemory
    case restartDock
    case restartFinder

    nonisolated var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .flushDNS: return String(localized: "刷新 DNS 缓存")
        case .rebuildSpotlight: return String(localized: "重建 Spotlight 索引")
        case .rebuildLaunchServices: return String(localized: "重建「打开方式」数据库")
        case .deleteLocalSnapshots: return String(localized: "清理 Time Machine 本地快照")
        case .periodicScripts: return String(localized: "运行系统维护脚本")
        case .purgeMemory: return String(localized: "释放内存")
        case .restartDock: return String(localized: "重置 Dock")
        case .restartFinder: return String(localized: "重启访达")
        }
    }

    nonisolated var summary: String {
        switch self {
        case .flushDNS:
            return String(localized: "网站打不开或域名刚更换解析时，清除本机缓存的 DNS 结果。")
        case .rebuildSpotlight:
            return String(localized: "Spotlight 搜不到文件或结果明显不对时，删除并重新建立启动磁盘的索引。")
        case .rebuildLaunchServices:
            return String(localized: "「打开方式」菜单出现重复或已删除的应用时，重新登记已安装的应用。")
        case .deleteLocalSnapshots:
            return String(localized: "删除启动磁盘上 Time Machine 的本地快照，立即释放「可清除」空间；不影响备份磁盘上的备份。")
        case .periodicScripts:
            return String(localized: "手动运行每日/每周/每月维护脚本（轮转日志等）。现代 macOS 会自动运行，通常不需要手动执行。")
        case .purgeMemory:
            return String(localized: "让系统丢弃磁盘缓存，通常只在测试时有用，系统会自动管理内存。")
        case .restartDock:
            return String(localized: "Dock 无响应、图标错乱或动画异常时重新启动它。")
        case .restartFinder:
            return String(localized: "访达无响应或窗口显示异常时重新启动它，已打开的访达窗口会关闭。")
        }
    }

    /// 运行前需要用户知晓的副作用。
    nonisolated var warning: String? {
        switch self {
        case .rebuildSpotlight: return String(localized: "重建需要较长时间（可能数小时），期间搜索结果不完整。")
        case .deleteLocalSnapshots: return String(localized: "删除后无法再用这些本地快照恢复文件。")
        default: return nil
        }
    }

    nonisolated var icon: String {
        switch self {
        case .flushDNS: return "network"
        case .rebuildSpotlight: return "magnifyingglass"
        case .rebuildLaunchServices: return "square.stack.3d.up.fill"
        case .deleteLocalSnapshots: return "clock.arrow.circlepath"
        case .periodicScripts: return "calendar.badge.clock"
        case .purgeMemory: return "memorychip"
        case .restartDock: return "dock.rectangle"
        case .restartFinder: return "folder.fill"
        }
    }

    nonisolated var requiresAdmin: Bool {
        switch self {
        case .rebuildLaunchServices, .restartDock, .restartFinder: return false
        default: return true
        }
    }

    /// 本系统是否提供该任务所需的命令（例如 periodic 已从新版 macOS 移除）。
    nonisolated var executablePath: String {
        switch self {
        case .flushDNS: return "/usr/bin/dscacheutil"
        case .rebuildSpotlight: return "/usr/bin/mdutil"
        case .rebuildLaunchServices: return MaintenanceCommands.lsregisterPath
        case .deleteLocalSnapshots: return "/usr/bin/tmutil"
        case .periodicScripts: return "/usr/sbin/periodic"
        case .purgeMemory: return "/usr/sbin/purge"
        case .restartDock, .restartFinder: return "/usr/bin/killall"
        }
    }

    nonisolated var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }
}

// MARK: - 运行结果

enum MaintenanceOutcome: Equatable, Sendable {
    case success(String?)
    case failure(String)
    case cancelled
}

// MARK: - 命令构造（纯函数）

enum MaintenanceCommands {
    nonisolated static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// 管理员任务的 shell 命令；本地快照需先给出快照日期列表。
    nonisolated static func adminShellCommand(for task: MaintenanceTask, snapshotDates: [String] = []) -> String? {
        switch task {
        case .flushDNS:
            return "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder"
        case .rebuildSpotlight:
            return "/usr/bin/mdutil -E /"
        case .deleteLocalSnapshots:
            guard !snapshotDates.isEmpty else { return nil }
            return snapshotDates
                .map { "/usr/bin/tmutil deletelocalsnapshots \(shellQuote($0))" }
                .joined(separator: " && ")
        case .periodicScripts:
            return "/usr/sbin/periodic daily weekly monthly"
        case .purgeMemory:
            return "/usr/sbin/purge"
        case .rebuildLaunchServices, .restartDock, .restartFinder:
            return nil
        }
    }

    /// 无需管理员权限的任务：可执行文件 + 参数，直接用 Process 运行。
    nonisolated static func userCommand(for task: MaintenanceTask) -> (executable: String, arguments: [String])? {
        switch task {
        case .rebuildLaunchServices:
            return (lsregisterPath, ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"])
        case .restartDock:
            return ("/usr/bin/killall", ["Dock"])
        case .restartFinder:
            return ("/usr/bin/killall", ["Finder"])
        default:
            return nil
        }
    }

    nonisolated static let beginMarker = "@@MACCLEAN_BEGIN"
    nonisolated static let endMarker = "@@MACCLEAN_END"

    /// 把多个管理员命令合成一个脚本：每个任务的输出夹在标记之间，并记录各自的退出码；
    /// 脚本本身总是以 0 退出，单个任务失败不影响后续任务，也不会让 AppleScript 整体报错。
    nonisolated static func batchedAdminScript(_ commands: [(id: String, command: String)]) -> String {
        var lines: [String] = []
        for (id, command) in commands {
            lines.append("echo '\(beginMarker) \(id)'")
            lines.append("{ \(command) ; } 2>&1")
            lines.append("echo \"\(endMarker) \(id) $?\"")
        }
        lines.append("exit 0")
        return lines.joined(separator: "\n")
    }

    /// 包装成 AppleScript 源码；只需转义反斜杠和双引号。
    nonisolated static func appleScriptSource(shellScript: String) -> String {
        let escaped = shellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges without altering line endings"
    }

    /// 解析合并脚本的输出 → 各任务（id）的退出码与输出。没有结束标记的任务不在结果中。
    nonisolated static func parseBatchOutput(_ output: String) -> [String: (status: Int32, output: String)] {
        var results: [String: (status: Int32, output: String)] = [:]
        var currentID: String?
        var buffer: [String] = []

        let lines = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        for line in lines {
            if line.hasPrefix(beginMarker + " ") {
                currentID = String(line.dropFirst(beginMarker.count + 1))
                buffer = []
            } else if line.hasPrefix(endMarker + " ") {
                let parts = line.dropFirst(endMarker.count + 1).split(separator: " ")
                if let id = currentID, parts.count >= 2, String(parts[0]) == id, let status = Int32(parts[1]) {
                    results[id] = (status, buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
                }
                currentID = nil
                buffer = []
            } else if currentID != nil {
                buffer.append(line)
            }
        }
        return results
    }

    /// 解析 `tmutil listlocalsnapshots /` 输出，取出 Time Machine 快照日期（deletelocalsnapshots 的参数）。
    /// 行形如「com.apple.TimeMachine.2024-01-15-123456.local」；其他快照（系统更新等）忽略。
    nonisolated static func parseLocalSnapshotDates(_ output: String) -> [String] {
        let prefix = "com.apple.TimeMachine."
        var dates: [String] = []
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix) else { continue }
            var rest = String(line.dropFirst(prefix.count))
            if rest.hasSuffix(".local") { rest = String(rest.dropLast(".local".count)) }
            guard isSnapshotDate(rest), !dates.contains(rest) else { continue }
            dates.append(rest)
        }
        return dates
    }

    /// yyyy-MM-dd-HHmmss
    nonisolated static func isSnapshotDate(_ string: String) -> Bool {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let expected = [4, 2, 2, 6]
        return zip(parts, expected).allSatisfy { part, length in
            part.count == length && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber)
        }
    }

    /// osascript 用户取消密码框时的错误码。
    nonisolated static func isUserCancelled(_ stderr: String) -> Bool {
        stderr.contains("(-128)")
    }

    nonisolated static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - 执行（全部在后台线程调用）

enum MaintenanceRunner {

    struct ProcessOutput: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    nonisolated static func runProcess(_ executable: String, _ arguments: [String]) -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return ProcessOutput(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        // 先读完管道再等待退出，避免输出过多时管道写满导致死锁
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessOutput(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// 本地 Time Machine 快照日期（不需要管理员权限）。
    nonisolated static func localSnapshotDates() -> [String] {
        let result = runProcess("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        return MaintenanceCommands.parseLocalSnapshotDates(result.stdout)
    }

    /// 运行一组任务：管理员任务合并为一次授权，其余逐个用 Process 执行。
    nonisolated static func run(_ tasks: [MaintenanceTask]) -> [MaintenanceTask: MaintenanceOutcome] {
        var outcomes: [MaintenanceTask: MaintenanceOutcome] = [:]

        // 1. 管理员任务
        var adminCommands: [(id: String, command: String)] = []
        for task in tasks where task.requiresAdmin {
            guard task.isAvailable else {
                outcomes[task] = .failure(String(localized: "此 macOS 版本不提供该功能"))
                continue
            }
            if task == .deleteLocalSnapshots {
                let dates = localSnapshotDates()
                guard let command = MaintenanceCommands.adminShellCommand(for: task, snapshotDates: dates) else {
                    outcomes[task] = .success(String(localized: "没有本地快照"))
                    continue
                }
                adminCommands.append((task.rawValue, command))
            } else if let command = MaintenanceCommands.adminShellCommand(for: task) {
                adminCommands.append((task.rawValue, command))
            }
        }

        if !adminCommands.isEmpty {
            let script = MaintenanceCommands.batchedAdminScript(adminCommands)
            let source = MaintenanceCommands.appleScriptSource(shellScript: script)
            let result = runProcess("/usr/bin/osascript", ["-e", source])
            let adminTasks = adminCommands.compactMap { MaintenanceTask(rawValue: $0.id) }

            if result.status != 0 {
                let outcome: MaintenanceOutcome = MaintenanceCommands.isUserCancelled(result.stderr)
                    ? .cancelled
                    : .failure(cleanedMessage(result.stderr, fallback: String(localized: "授权失败")))
                for task in adminTasks { outcomes[task] = outcome }
            } else {
                let parsed = MaintenanceCommands.parseBatchOutput(result.stdout)
                for task in adminTasks {
                    guard let entry = parsed[task.rawValue] else {
                        outcomes[task] = .failure(String(localized: "没有返回结果"))
                        continue
                    }
                    outcomes[task] = entry.status == 0
                        ? .success(entry.output.isEmpty ? nil : entry.output)
                        : .failure(cleanedMessage(entry.output, fallback: String(localized: "退出码 \(entry.status)")))
                }
            }
        }

        // 2. 普通任务
        for task in tasks where !task.requiresAdmin {
            guard let command = MaintenanceCommands.userCommand(for: task) else { continue }
            let result = runProcess(command.executable, command.arguments)
            if result.status == 0 {
                outcomes[task] = .success(nil)
            } else {
                outcomes[task] = .failure(cleanedMessage(result.stderr + result.stdout, fallback: String(localized: "退出码 \(result.status)")))
            }
        }

        return outcomes
    }

    /// 取最后一行非空输出作为错误说明，去掉 osascript 的「execution error:」前缀。
    nonisolated static func cleanedMessage(_ text: String, fallback: String) -> String {
        let line = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        guard !line.isEmpty else { return fallback }
        if let range = line.range(of: "execution error: ") {
            return String(line[range.upperBound...])
        }
        return line
    }
}
