//
//  DiskAlertTests.swift
//  MacCleanTests
//
//  磁盘空间不足提醒 / 定期清理提醒 的判定逻辑
//

import Foundation
import Testing
@testable import MacClean

struct DiskAlertTests {
    private let gb: Int64 = 1_000_000_000
    private let total: Int64 = 500_000_000_000
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    // MARK: - 阈值

    @Test func thresholds() {
        #expect(DiskAlertPolicy.isLow(available: 9 * gb, total: total, threshold: .gb10))
        #expect(!DiskAlertPolicy.isLow(available: 10 * gb, total: total, threshold: .gb10))
        #expect(DiskAlertPolicy.isLow(available: 15 * gb, total: total, threshold: .gb20))
        #expect(DiskAlertPolicy.isLow(available: 49 * gb, total: total, threshold: .percent10))
        #expect(!DiskAlertPolicy.isLow(available: 50 * gb, total: total, threshold: .percent10))
        #expect(!DiskAlertPolicy.isLow(available: 0, total: 0, threshold: .percent10))
    }

    // MARK: - 低空间提醒

    @Test func notifiesWhenLowAndArmed() {
        let result = DiskAlertPolicy.evaluateLowDisk(available: 5 * gb, total: total, threshold: .gb10, state: LowDiskAlertState(), now: now)
        #expect(result.notify)
        #expect(result.state.armed == false)
        #expect(result.state.lastAlertAt == now)
    }

    @Test func doesNotRepeatWhileStillLow() {
        let state = LowDiskAlertState(armed: false, lastAlertAt: now.addingTimeInterval(-3 * day))
        let result = DiskAlertPolicy.evaluateLowDisk(available: 5 * gb, total: total, threshold: .gb10, state: state, now: now)
        #expect(!result.notify)
        #expect(result.state == state)
    }

    @Test func recoveringRearms() {
        let state = LowDiskAlertState(armed: false, lastAlertAt: now.addingTimeInterval(-day / 2))
        let result = DiskAlertPolicy.evaluateLowDisk(available: 30 * gb, total: total, threshold: .gb10, state: state, now: now)
        #expect(!result.notify)
        #expect(result.state.armed)
        #expect(result.state.lastAlertAt == state.lastAlertAt)
    }

    @Test func rearmedButWithin24HoursStaysQuiet() {
        let state = LowDiskAlertState(armed: true, lastAlertAt: now.addingTimeInterval(-day / 2))
        let result = DiskAlertPolicy.evaluateLowDisk(available: 5 * gb, total: total, threshold: .gb10, state: state, now: now)
        #expect(!result.notify)
        #expect(result.state.armed)
    }

    @Test func rearmedAfter24HoursNotifiesAgain() {
        let state = LowDiskAlertState(armed: true, lastAlertAt: now.addingTimeInterval(-day - 1))
        let result = DiskAlertPolicy.evaluateLowDisk(available: 5 * gb, total: total, threshold: .gb10, state: state, now: now)
        #expect(result.notify)
    }

    // MARK: - 定期清理提醒

    @Test func reminderOffNeverFires() {
        #expect(!DiskAlertPolicy.isCleanupReminderDue(interval: .off, lastCleanup: nil, lastReminder: nil, firstLaunch: now.addingTimeInterval(-365 * day), now: now))
    }

    @Test func reminderUsesMostRecentReference() {
        let firstLaunch = now.addingTimeInterval(-100 * day)
        // 上次清理 8 天前 → 每周到期，每两周未到期
        let lastCleanup = now.addingTimeInterval(-8 * day)
        #expect(DiskAlertPolicy.isCleanupReminderDue(interval: .weekly, lastCleanup: lastCleanup, lastReminder: nil, firstLaunch: firstLaunch, now: now))
        #expect(!DiskAlertPolicy.isCleanupReminderDue(interval: .biweekly, lastCleanup: lastCleanup, lastReminder: nil, firstLaunch: firstLaunch, now: now))
        // 3 天前刚提醒过 → 不再提醒
        #expect(!DiskAlertPolicy.isCleanupReminderDue(interval: .weekly, lastCleanup: lastCleanup, lastReminder: now.addingTimeInterval(-3 * day), firstLaunch: firstLaunch, now: now))
    }

    @Test func reminderFallsBackToFirstLaunch() {
        #expect(!DiskAlertPolicy.isCleanupReminderDue(interval: .monthly, lastCleanup: nil, lastReminder: nil, firstLaunch: now.addingTimeInterval(-29 * day), now: now))
        #expect(DiskAlertPolicy.isCleanupReminderDue(interval: .monthly, lastCleanup: nil, lastReminder: nil, firstLaunch: now.addingTimeInterval(-30 * day), now: now))
    }

    @Test func reminderBody() {
        #expect(DiskAlertPolicy.cleanupReminderBody(lastCleanup: now.addingTimeInterval(-9.5 * day), now: now) == String(localized: "上次清理是 \(9) 天前，看看能释放多少空间？"))
        #expect(DiskAlertPolicy.cleanupReminderBody(lastCleanup: nil, now: now) == String(localized: "还没有清理过，看看能释放多少空间？"))
    }
}
