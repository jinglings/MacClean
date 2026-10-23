import Foundation
import Combine

nonisolated struct UsageEvent: Codable, Sendable {
    let name: String
    let occurredAt: Date
    let appVersion: String
    let osVersion: String

    var key: String { name == "daily_active" ? "\(name):\(UsageAnalytics.dayKey(occurredAt))" : name }
}

nonisolated private struct UsageState: Codable {
    var installationID: String?
    var delivered: Set<String> = []
    var pending: [UsageEvent] = []
}

nonisolated private struct UsageBatch: Encodable {
    let installationId: String
    let events: [UsageEvent]
}

/// Opt-in only. Contains no file metadata, scan results, license key or hardware identifier.
@MainActor
final class UsageAnalytics: ObservableObject {
    static let shared = UsageAnalytics()
    static let enabledKey = "usageStatisticsEnabled"
    private static let stateKey = "usageStatisticsState.v1"
    static let privacyURL = URL(string: "https://thulem.com/privacy.html")!

    typealias Transport = @Sendable (URLRequest) async throws -> Int

    @Published private(set) var isEnabled: Bool
    private let defaults: UserDefaults
    private let endpoint: URL
    private let now: () -> Date
    private let transport: Transport
    private var state: UsageState
    private var started = false
    private var generation = 0
    private var uploadTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryDelay: Double = 60

    init(defaults: UserDefaults = .standard,
         endpoint: URL = URL(string: "https://thulem.com/api/usage/events")!,
         now: @escaping () -> Date = Date.init,
         transport: Transport? = nil) {
        self.defaults = defaults
        self.endpoint = endpoint
        self.now = now
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.state = defaults.data(forKey: Self.stateKey)
            .flatMap { try? JSONDecoder().decode(UsageState.self, from: $0) } ?? UsageState()
        if let transport {
            self.transport = transport
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            let session = URLSession(configuration: configuration)
            self.transport = { request in
                let (_, response) = try await session.data(for: request)
                return (response as? HTTPURLResponse)?.statusCode ?? 0
            }
        }
        if !isEnabled { state.pending.removeAll() }
    }

    func start() {
        guard !started else { return }
        started = true
        recordActive()
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        generation += 1
        uploadTask?.cancel()
        uploadTask = nil
        retryTask?.cancel()
        retryTask = nil
        retryDelay = 60
        if enabled {
            recordActive()
        } else {
            // Keep the random ID and delivered keys to avoid recounting after re-enabling.
            // Unsent events are discarded; activity while disabled is never queued.
            state.pending.removeAll()
            persist()
        }
    }

    /// Called after launch and when the app is used in the foreground, including across midnight.
    func recordActive() {
        guard started, isEnabled else { return }
        prune()
        enqueue("first_open")
        enqueue("daily_active")
        scheduleUpload()
    }

    func recordScanCompleted() {
        guard started, isEnabled else { return }
        prune()
        enqueue("first_open")
        enqueue("daily_active")
        enqueue("first_scan")
        scheduleUpload()
    }

    private func enqueue(_ name: String) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let event = UsageEvent(name: name, occurredAt: now(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        guard !state.delivered.contains(event.key), !state.pending.contains(where: { $0.key == event.key }) else { return }
        if state.installationID == nil { state.installationID = UUID().uuidString.lowercased() }
        state.pending.append(event)
        persist()
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-30 * 86400)
        state.pending.removeAll { $0.occurredAt < cutoff || $0.occurredAt > now().addingTimeInterval(300) }
        let day = Self.dayKey(cutoff)
        state.delivered = state.delivered.filter { !$0.hasPrefix("daily_active:") || String($0.suffix(10)) >= day }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.stateKey) }
    }

    private func scheduleUpload() {
        guard isEnabled, started, uploadTask == nil, !state.pending.isEmpty else { return }
        retryTask?.cancel()
        retryTask = nil
        let epoch = generation
        uploadTask = Task { [weak self] in
            guard let self else { return }
            let success = await self.upload(epoch: epoch)
            guard self.generation == epoch else { return }
            self.uploadTask = nil
            guard self.isEnabled, !self.state.pending.isEmpty else { return }
            if success {
                self.scheduleUpload()
            } else {
                let delay = self.retryDelay
                self.retryDelay = min(delay * 2, 900)
                self.retryTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    self?.scheduleUpload()
                }
            }
        }
    }

    private func upload(epoch: Int) async -> Bool {
        guard isEnabled, !Task.isCancelled, let id = state.installationID else { return false }
        prune()
        guard !state.pending.isEmpty else { return true }
        let batch = state.pending
        do {
            var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("MacClean", forHTTPHeaderField: "User-Agent")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(UsageBatch(installationId: id, events: batch))
            let status = try await transport(request)
            guard generation == epoch, isEnabled, !Task.isCancelled, (200..<300).contains(status) else { return false }
            let keys = Set(batch.map(\.key))
            state.delivered.formUnion(keys)
            state.pending.removeAll { keys.contains($0.key) }
            retryDelay = 60
            persist()
            return true
        } catch {
            return false // Never interrupt scanning or licensing because analytics is unavailable.
        }
    }

    /// Used by deterministic transport tests; does not wait for backoff timers.
    func waitForUpload() async {
        while let task = uploadTask { await task.value }
    }

    nonisolated static func dayKey(_ date: Date) -> String {
        // Matches the server's default business timezone; timestamps themselves remain UTC.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
