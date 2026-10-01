//
//  MaintenanceTests.swift
//  MacCleanTests
//
//  系统维护：命令构造、合并管理员脚本、输出解析。
//

import Foundation
import Testing
@testable import MacClean

struct MaintenanceTests {

    // MARK: - 合并脚本

    @Test func batchedScriptWrapsEachCommandWithMarkers() {
        let script = MaintenanceCommands.batchedAdminScript([
            ("flushDNS", "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder"),
            ("purgeMemory", "/usr/sbin/purge"),
        ])
        let lines = script.components(separatedBy: "\n")
        #expect(lines == [
            "echo '@@MACCLEAN_BEGIN flushDNS'",
            "{ /usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder ; } 2>&1",
            "echo \"@@MACCLEAN_END flushDNS $?\"",
            "echo '@@MACCLEAN_BEGIN purgeMemory'",
            "{ /usr/sbin/purge ; } 2>&1",
            "echo \"@@MACCLEAN_END purgeMemory $?\"",
            "exit 0",
        ])
    }

    @Test func batchedScriptActuallyRunsAndParses() {
        // 用普通 shell 跑一遍合并脚本，验证标记、退出码与输出能正确往返
        let script = MaintenanceCommands.batchedAdminScript([
            ("ok", "echo hello"),
            ("bad", "echo boom >&2; false"),
            ("quiet", "true"),
        ])
        let result = MaintenanceRunner.runProcess("/bin/sh", ["-c", script])
        #expect(result.status == 0)

        let parsed = MaintenanceCommands.parseBatchOutput(result.stdout)
        #expect(parsed["ok"]?.status == 0)
        #expect(parsed["ok"]?.output == "hello")
        #expect(parsed["bad"]?.status == 1)
        #expect(parsed["bad"]?.output == "boom")
        #expect(parsed["quiet"]?.status == 0)
        #expect(parsed["quiet"]?.output == "")
    }

    @Test func parseHandlesCarriageReturnsAndMissingEnd() {
        let output = "@@MACCLEAN_BEGIN a\rline1\rline2\r@@MACCLEAN_END a 0\r@@MACCLEAN_BEGIN b\rhalf"
        let parsed = MaintenanceCommands.parseBatchOutput(output)
        #expect(parsed["a"]?.output == "line1\nline2")
        #expect(parsed["b"] == nil)
    }

    @Test func appleScriptSourceEscapesQuotesAndBackslashes() {
        let source = MaintenanceCommands.appleScriptSource(shellScript: #"echo "a\b" $?"#)
        #expect(source == #"do shell script "echo \"a\\b\" $?" with administrator privileges without altering line endings"#)
    }

    // MARK: - 命令

    @Test func everyTaskHasExactlyOneKindOfCommand() {
        for task in MaintenanceTask.allCases {
            let admin = MaintenanceCommands.adminShellCommand(for: task, snapshotDates: ["2024-01-01-000000"])
            let user = MaintenanceCommands.userCommand(for: task)
            if task.requiresAdmin {
                #expect(admin != nil, "\(task)")
                #expect(user == nil, "\(task)")
            } else {
                #expect(admin == nil, "\(task)")
                #expect(user != nil, "\(task)")
            }
        }
    }

    @Test func specificCommands() {
        #expect(MaintenanceCommands.adminShellCommand(for: .flushDNS) == "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder")
        #expect(MaintenanceCommands.adminShellCommand(for: .rebuildSpotlight) == "/usr/bin/mdutil -E /")
        #expect(MaintenanceCommands.userCommand(for: .restartDock)?.arguments == ["Dock"])
        let ls = MaintenanceCommands.userCommand(for: .rebuildLaunchServices)
        #expect(ls?.executable.hasSuffix("/lsregister") == true)
        #expect(ls?.arguments == ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"])
    }

    @Test func snapshotCommandNeedsDates() {
        #expect(MaintenanceCommands.adminShellCommand(for: .deleteLocalSnapshots, snapshotDates: []) == nil)
        #expect(
            MaintenanceCommands.adminShellCommand(for: .deleteLocalSnapshots, snapshotDates: ["2024-01-15-123456", "2024-01-16-000001"])
            == "/usr/bin/tmutil deletelocalsnapshots '2024-01-15-123456' && /usr/bin/tmutil deletelocalsnapshots '2024-01-16-000001'"
        )
    }

    // MARK: - tmutil 输出

    @Test func parseLocalSnapshots() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2024-01-15-123456.local
        com.apple.TimeMachine.2024-01-16-000001.local
        com.apple.os.update-ABCDEF
        com.apple.TimeMachine.2024-01-15-123456.local
        com.apple.TimeMachine.bogus.local
        """
        #expect(MaintenanceCommands.parseLocalSnapshotDates(output) == ["2024-01-15-123456", "2024-01-16-000001"])
        #expect(MaintenanceCommands.parseLocalSnapshotDates("Snapshots for disk /:\n").isEmpty)
    }

    // MARK: - 错误信息

    @Test func cancelAndErrorMessages() {
        #expect(MaintenanceCommands.isUserCancelled("0:121: execution error: User canceled. (-128)"))
        #expect(!MaintenanceCommands.isUserCancelled("execution error: something (1)"))
        #expect(MaintenanceRunner.cleanedMessage("0:50: execution error: 不允许 (1)\n", fallback: "x") == "不允许 (1)")
        #expect(MaintenanceRunner.cleanedMessage("   \n", fallback: "x") == "x")
    }

    @Test func lastRunKeyIsStable() {
        #expect(MaintenanceViewModel.lastRunKey(.flushDNS) == "maintenance.lastRun.flushDNS")
    }
}
