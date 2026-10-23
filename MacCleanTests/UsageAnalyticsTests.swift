import Foundation
import Testing
@testable import MacClean

private actor UsageTransport {
    var requests: [URLRequest] = []
    var status = 200

    func send(_ request: URLRequest) -> Int {
        requests.append(request)
        return status
    }

    func setStatus(_ value: Int) { status = value }
}

private actor HeldUsageTransport {
    var requests: [URLRequest] = []
    private var reply: CheckedContinuation<Int, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func send(_ request: URLRequest) async -> Int {
        requests.append(request)
        guard requests.count == 1 else { return 200 }
        started?.resume()
        started = nil
        return await withCheckedContinuation { reply = $0 }
    }

    func waitUntilStarted() async {
        if requests.isEmpty { await withCheckedContinuation { started = $0 } }
    }

    func release() { reply?.resume(returning: 200); reply = nil }
}

@MainActor
struct UsageAnalyticsTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "UsageAnalyticsTests.\(UUID().uuidString)")!
    }

    private func decodeBody(_ data: Data?) throws -> [String: Any] {
        let data = try #require(data)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @Test func defaultOffDoesNotQueueOrSend() async {
        let defaults = defaults()
        let recorder = UsageTransport()
        let usage = UsageAnalytics(defaults: defaults, transport: { await recorder.send($0) })
        usage.start()
        usage.recordActive()
        usage.recordScanCompleted()
        await usage.waitForUpload()
        #expect(!usage.isEnabled)
        #expect(await recorder.requests.isEmpty)
        #expect(defaults.data(forKey: "usageStatisticsState.v1") == nil)
    }

    @Test func sendsOnlyAllowedFieldsAndDeduplicatesAcrossRelaunches() async throws {
        let defaults = defaults()
        let recorder = UsageTransport()
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = UsageAnalytics(defaults: defaults, now: { time }, transport: { await recorder.send($0) })
        usage.start()
        usage.setEnabled(true)
        usage.recordScanCompleted()
        await usage.waitForUpload()
        usage.recordActive()
        usage.recordScanCompleted()
        await usage.waitForUpload()
        let requests = await recorder.requests
        let bodies = try requests.map { try decodeBody($0.httpBody) }
        let events = bodies.flatMap { $0["events"] as? [[String: Any]] ?? [] }
        #expect(events.map { $0["name"] as? String }.sorted { ($0 ?? "") < ($1 ?? "") } == ["daily_active", "first_open", "first_scan"])
        for body in bodies {
            #expect(Set(body.keys) == ["installationId", "events"])
            #expect(UUID(uuidString: try #require(body["installationId"] as? String)) != nil)
        }
        for event in events { #expect(Set(event.keys) == ["name", "occurredAt", "appVersion", "osVersion"]) }
        let relaunched = UsageAnalytics(defaults: defaults, now: { time }, transport: { await recorder.send($0) })
        relaunched.start()
        relaunched.recordScanCompleted()
        await relaunched.waitForUpload()
        #expect(await recorder.requests.count == requests.count)
        usage.setEnabled(false)
        relaunched.setEnabled(false)
    }

    @Test func dailyActiveChangesAtShanghaiMidnightWithoutRepeatingFirstOpen() async throws {
        let defaults = defaults()
        let recorder = UsageTransport()
        var time = ISO8601DateFormatter().date(from: "2026-10-22T15:59:59Z")!
        let usage = UsageAnalytics(defaults: defaults, now: { time }, transport: { await recorder.send($0) })
        usage.start()
        usage.setEnabled(true)
        await usage.waitForUpload()
        time = time.addingTimeInterval(2)
        usage.recordActive()
        await usage.waitForUpload()
        let requests = await recorder.requests
        #expect(requests.count == 2)
        let last = try decodeBody(requests.last?.httpBody)
        let events = try #require(last["events"] as? [[String: Any]])
        #expect(events.count == 1)
        #expect(events.first?["name"] as? String == "daily_active")
        usage.setEnabled(false)
    }

    @Test func offlineEventsSurviveRelaunchAndRetryWithSameID() async throws {
        let defaults = defaults()
        let recorder = UsageTransport()
        await recorder.setStatus(503)
        var usage: UsageAnalytics? = UsageAnalytics(defaults: defaults, transport: { await recorder.send($0) })
        usage?.start()
        usage?.setEnabled(true)
        usage?.recordScanCompleted()
        await usage?.waitForUpload()
        usage = nil
        await recorder.setStatus(200)
        let relaunched = UsageAnalytics(defaults: defaults, transport: { await recorder.send($0) })
        relaunched.start()
        await relaunched.waitForUpload()
        let requests = await recorder.requests
        let first = try decodeBody(requests.first?.httpBody)
        let last = try decodeBody(requests.last?.httpBody)
        #expect(first["installationId"] as? String == last["installationId"] as? String)
        #expect((last["events"] as? [[String: Any]])?.count == 3)
        let count = requests.count
        relaunched.recordActive()
        relaunched.recordScanCompleted()
        await relaunched.waitForUpload()
        #expect(await recorder.requests.count == count)
        relaunched.setEnabled(false)
    }

    @Test func disablingDropsUnsentEventsAndDoesNotCollectWhileOff() async throws {
        let defaults = defaults()
        let recorder = UsageTransport()
        await recorder.setStatus(503)
        let usage = UsageAnalytics(defaults: defaults, transport: { await recorder.send($0) })
        usage.start()
        usage.setEnabled(true)
        usage.recordScanCompleted()
        await usage.waitForUpload()
        usage.setEnabled(false)
        let count = await recorder.requests.count
        usage.recordActive()
        usage.recordScanCompleted()
        await usage.waitForUpload()
        #expect(await recorder.requests.count == count)
        await recorder.setStatus(200)
        usage.setEnabled(true)
        await usage.waitForUpload()
        let request = try #require(await recorder.requests.last)
        let body = try decodeBody(request.httpBody)
        let events = try #require(body["events"] as? [[String: Any]])
        #expect(!events.contains { $0["name"] as? String == "first_scan" })
        usage.setEnabled(false)
    }

    @Test func disabledInFlightResponseCannotAcknowledgeEventsAfterConsentChanges() async throws {
        let recorder = HeldUsageTransport()
        let usage = UsageAnalytics(defaults: defaults(), transport: { await recorder.send($0) })
        usage.start()
        usage.setEnabled(true)
        usage.recordScanCompleted()
        await recorder.waitUntilStarted()
        usage.setEnabled(false)
        await recorder.release()
        usage.setEnabled(true)
        await usage.waitForUpload()
        let requests = await recorder.requests
        #expect(requests.count == 2)
        let body = try decodeBody(requests.last?.httpBody)
        let events = try #require(body["events"] as? [[String: Any]])
        #expect(Set(events.compactMap { $0["name"] as? String }) == ["first_open", "daily_active"])
        usage.setEnabled(false)
    }

    @Test func expiredOfflineEventsAreDiscardedRatherThanReportedAsCurrentActivity() async throws {
        let recorder = UsageTransport()
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        await recorder.setStatus(503)
        let usage = UsageAnalytics(defaults: defaults(), now: { time }, transport: { await recorder.send($0) })
        usage.start()
        usage.setEnabled(true)
        usage.recordScanCompleted()
        await usage.waitForUpload()
        time = time.addingTimeInterval(31 * 86400)
        await recorder.setStatus(200)
        usage.recordActive()
        await usage.waitForUpload()
        let request = try #require(await recorder.requests.last)
        let body = try decodeBody(request.httpBody)
        let events = try #require(body["events"] as? [[String: Any]])
        #expect(events.count == 2)
        #expect(!events.contains { $0["name"] as? String == "first_scan" })
        usage.setEnabled(false)
    }
}
