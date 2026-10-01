//
//  FileRecovery.swift
//  MacClean
//
//  找回文件：可用来源（APFS 本地快照 / 时间机器备份）的发现、命令输出解析、挂载脚本构造。
//  全部是纯函数（nonisolated），可单元测试；真正执行命令的部分在 FileRecoveryScanner.swift。
//
//  能力边界（必须对用户如实说明）：
//  - 只能从「删除之前就存在」的本地快照或时间机器备份里拷贝回来；
//  - 没有快照或备份时，清空废纸篓后的文件在 SSD 上已被 TRIM，任何软件都无法找回。
//

import Foundation

// MARK: - 来源

nonisolated struct RecoverySource: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case localSnapshot
        case timeMachine
    }

    let kind: Kind
    /// 本地快照：快照名（com.apple.TimeMachine.2026-10-01-120000.local）；时间机器：备份目录的完整路径。
    let name: String
    let date: Date?

    var id: String { kind.rawValue + ":" + name }

    /// 本地快照的挂载点。
    var mountPoint: String? {
        kind == .localSnapshot ? RecoveryPaths.mountPoint(forSnapshot: name) : nil
    }
}

nonisolated enum RecoveryPaths {
    /// 所有快照挂载在这里，便于启动时识别「上次挂载、尚未卸载」的快照。
    static let mountRoot = "/private/tmp/macclean-recovery"

    static func mountPoint(forSnapshot name: String) -> String {
        mountRoot + "/" + name
    }

    /// 当前用户主目录相对于数据卷根目录的路径，例如 "Users/wangwei"。
    static func relativeHome(_ home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        var path = home.standardizedFileURL.path
        if path.hasPrefix("/System/Volumes/Data/") { path = String(path.dropFirst("/System/Volumes/Data".count)) }
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// 来源里与当前主目录对应的目录；不存在（或不是真实目录）时返回 nil。
    /// - 本地快照：`<挂载点>/Users/<name>`
    /// - 时间机器：`<备份>/Data/Users/<name>`（macOS 11+ 的 APFS 备份）、
    ///   `<备份>/Macintosh HD - Data/Users/<name>` 或 `<备份>/<卷名>/Users/<name>`（旧格式）
    static func homeInSource(root: String, kind: RecoverySource.Kind, relativeHome: String) -> String? {
        let fileManager = FileManager.default
        var candidates: [String] = []
        switch kind {
        case .localSnapshot:
            candidates = [root + "/" + relativeHome]
        case .timeMachine:
            candidates = [root + "/Data/" + relativeHome, root + "/Macintosh HD - Data/" + relativeHome]
            let volumes = ((try? fileManager.contentsOfDirectory(atPath: root)) ?? [])
                .filter { !$0.hasPrefix(".") && $0 != "Data" && $0 != "Macintosh HD - Data" }
                .sorted()
            // 名字带「Data」的卷优先（「XXX - Data」是 Catalina 起的数据卷）
            let ordered = volumes.filter { $0.hasSuffix("Data") } + volumes.filter { !$0.hasSuffix("Data") }
            candidates += ordered.map { root + "/" + $0 + "/" + relativeHome }
            // 极旧的备份直接是卷根
            candidates.append(root + "/" + relativeHome)
        }
        return candidates.first { isRealDirectory($0) }
    }

    /// 是目录且不是符号链接（避免顺着链接跑出来源之外）。
    static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }
}

// MARK: - 命令输出解析

nonisolated struct BackupListing: Equatable, Sendable {
    var paths: [String] = []
    /// 输出里出现「Operation not permitted」：没有完全磁盘访问权限，无法判断是否有备份。
    var needsFullDiskAccess = false
}

nonisolated enum RecoveryParsing {

    static let osUpdatePrefix = "com.apple.os.update-"

    /// `tmutil listlocalsnapshots <卷>` → 快照名（保持原顺序、去重）。
    /// 表头「Snapshots for disk …:」与「No snapshots for …」忽略；系统更新快照（com.apple.os.update-*）在系统卷上，不含用户数据，也忽略。
    static func parseLocalSnapshots(_ output: String) -> [String] {
        var names: [String] = []
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  !line.hasPrefix("Snapshots for"),
                  !line.hasPrefix("No snapshots"),
                  !line.hasPrefix("Snapshot dates for"),
                  !line.hasPrefix(osUpdatePrefix),
                  !line.contains(" "),
                  !line.contains("/"),
                  !line.hasSuffix(":"),
                  !names.contains(line)
            else { continue }
            names.append(line)
        }
        return names
    }

    /// 在字符串中找到第一个「yyyy-MM-dd-HHmmss」并按本地时间解析。
    static func parseDate(in string: String, timeZone: TimeZone = .current) -> Date? {
        let chars = Array(string.utf8)
        let shape = "dddd-dd-dd-dddddd".utf8.map { $0 }
        guard chars.count >= shape.count else { return nil }
        for start in 0...(chars.count - shape.count) {
            var matched = true
            for (offset, expected) in shape.enumerated() {
                let c = chars[start + offset]
                if expected == UInt8(ascii: "d") ? !(c >= 48 && c <= 57) : c != expected {
                    matched = false
                    break
                }
            }
            guard matched else { continue }
            // 前后不能紧挨着数字（避免从更长的数字串里截取）
            if start > 0, chars[start - 1] >= 48, chars[start - 1] <= 57 { continue }
            let end = start + shape.count
            if end < chars.count, chars[end] >= 48, chars[end] <= 57 { continue }

            func number(_ from: Int, _ length: Int) -> Int {
                chars[(start + from)..<(start + from + length)].reduce(0) { $0 * 10 + Int($1 - 48) }
            }
            var components = DateComponents()
            components.year = number(0, 4)
            components.month = number(5, 2)
            components.day = number(8, 2)
            components.hour = number(11, 2)
            components.minute = number(13, 2)
            components.second = number(15, 2)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            guard let month = components.month, (1...12).contains(month),
                  let day = components.day, (1...31).contains(day),
                  let hour = components.hour, hour < 24,
                  let minute = components.minute, minute < 60,
                  let second = components.second, second < 61,
                  let date = calendar.date(from: components)
            else { continue }
            return date
        }
        return nil
    }

    /// `tmutil listbackups` 的标准输出 + 标准错误。
    /// 「No machine directory found for host.」「No destinations configured.」等都只意味着没有备份。
    static func parseBackupList(stdout: String, stderr: String = "") -> BackupListing {
        var listing = BackupListing()
        for raw in (stdout + "\n" + stderr).components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.localizedCaseInsensitiveContains("Operation not permitted") {
                listing.needsFullDiskAccess = true
                continue
            }
            guard line.hasPrefix("/"), !listing.paths.contains(line) else { continue }
            listing.paths.append(line)
        }
        return listing
    }

    /// `tmutil destinationinfo`：是否配置了时间机器备份磁盘。
    static func hasTimeMachineDestination(_ output: String) -> Bool {
        if output.localizedCaseInsensitiveContains("No destinations configured") { return false }
        return output.components(separatedBy: .newlines).contains {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("Name") || line.hasPrefix("ID") || line.hasPrefix("Mount Point")
        }
    }

    /// `mount` 输出中挂载在 root 下的条目 → [快照名: 挂载点]。
    /// 行形如「com.apple.TimeMachine.….local@/dev/disk3s5 on /private/tmp/macclean-recovery/<名> (apfs, local, read-only, …)」。
    static func parseRecoveryMounts(_ output: String, root: String = RecoveryPaths.mountRoot) -> [String: String] {
        var mounts: [String: String] = [:]
        let roots = [root + "/"] + (root.hasPrefix("/private/") ? [String(root.dropFirst("/private".count)) + "/"] : [])
        for raw in output.components(separatedBy: .newlines) {
            guard let onRange = raw.range(of: " on ") else { continue }
            var rest = raw[onRange.upperBound...]
            if let optionsRange = rest.range(of: " (", options: .backwards) {
                rest = rest[..<optionsRange.lowerBound]
            }
            let mountPoint = String(rest)
            guard let prefix = roots.first(where: { mountPoint.hasPrefix($0) }) else { continue }
            let name = String(mountPoint.dropFirst(prefix.count))
            guard !name.isEmpty, !name.contains("/") else { continue }
            mounts[name] = RecoveryPaths.mountPoint(forSnapshot: name)
        }
        return mounts
    }

    /// `diskutil info -plist <卷>` → 设备节点（/dev/disk3s5）。
    static func parseDeviceNode(plist data: Data) -> String? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any],
              let node = dict["DeviceNode"] as? String,
              node.hasPrefix("/dev/")
        else { return nil }
        return node
    }
}

// MARK: - 管理员脚本（挂载 / 卸载）

nonisolated enum RecoveryAdminScript {

    /// 快照名只能作为单个路径分量使用（它会拼进挂载点）。
    static func isSafeSnapshotName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
            && !name.contains("\n") && !name.contains("\r")
    }

    static func isSafeDeviceNode(_ node: String) -> Bool {
        node.hasPrefix("/dev/disk") && node.dropFirst("/dev/disk".count).allSatisfy { $0.isASCII && ($0.isNumber || $0 == "s") }
    }

    /// 一次授权挂载全部所选快照（只读、不在访达中显示）。每个快照一段，id 为 m0、m1…，
    /// 用 MaintenanceCommands.batchedAdminScript 包起来，单个失败不影响其他。
    static func mountCommands(snapshots: [String], deviceNode: String, root: String = RecoveryPaths.mountRoot) -> [(id: String, command: String)] {
        guard isSafeDeviceNode(deviceNode) else { return [] }
        let q = MaintenanceCommands.shellQuote
        return snapshots.enumerated().compactMap { index, name in
            guard isSafeSnapshotName(name) else { return nil }
            let mountPoint = root + "/" + name
            return (
                "m\(index)",
                "/bin/mkdir -p \(q(mountPoint)) && /sbin/mount_apfs -o rdonly,nobrowse -s \(q(name)) \(q(deviceNode)) \(q(mountPoint))"
            )
        }
    }

    static func unmountCommands(mountPoints: [String], root: String = RecoveryPaths.mountRoot) -> [(id: String, command: String)] {
        let q = MaintenanceCommands.shellQuote
        return mountPoints.enumerated().compactMap { index, mountPoint in
            // 只处理我们自己的挂载点，绝不对其他路径执行 umount / rmdir
            let name = String(mountPoint.dropFirst(root.count + 1))
            guard mountPoint.hasPrefix(root + "/"), isSafeSnapshotName(name) else { return nil }
            return ("u\(index)", "/sbin/umount \(q(mountPoint)) ; /bin/rmdir \(q(mountPoint))")
        }
    }

    /// 完整的 AppleScript 源码（osascript -e 的参数）。
    static func appleScript(for commands: [(id: String, command: String)]) -> String {
        MaintenanceCommands.appleScriptSource(shellScript: MaintenanceCommands.batchedAdminScript(commands))
    }
}
