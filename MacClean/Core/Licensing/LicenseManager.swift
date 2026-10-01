//
//  LicenseManager.swift
//  MacClean
//
//  许可证管理器：7 天试用 → 激活许可证（LemonSqueezy 等可插拔后端）→ 定期联网校验 + 离线宽限。
//  试用起始日与许可证信息存钥匙串，UserDefaults 只留一份提示用的镜像。
//

import Foundation
import Combine
import SystemConfiguration

// MARK: - 状态

nonisolated enum LicenseState: String, Sendable {
    case trial
    case licensed
    case expired
}

/// 持久化到钥匙串的许可证信息。
nonisolated struct StoredLicense: Codable, Equatable, Sendable {
    var key: String
    var instanceID: String
    var planName: String?
    var activatedAt: Date
    /// 上次联网校验成功的时间。
    var lastValidated: Date
}

// MARK: - 纯逻辑（便于单元测试）

nonisolated enum LicensePolicy {
    static let day: TimeInterval = 86_400

    /// 试用剩余天数（向下取整的已用整天数）。时钟被回拨到试用开始之前时按完整试用期算。
    static func trialDaysRemaining(trialStart: Date, now: Date, trialDays: Int = LicenseConfig.trialDays) -> Int {
        let elapsed = now.timeIntervalSince(trialStart)
        guard elapsed > 0 else { return trialDays }
        return max(0, trialDays - Int(elapsed / day))
    }

    static func trialEndDate(trialStart: Date, trialDays: Int = LicenseConfig.trialDays) -> Date {
        trialStart.addingTimeInterval(TimeInterval(trialDays) * day)
    }

    /// 启动时是否需要重新联网校验：距上次成功校验满 7 天，或时钟异常（上次校验在未来）。
    static func needsRevalidation(lastValidated: Date, now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(lastValidated)
        return elapsed < 0 || elapsed >= TimeInterval(LicenseConfig.revalidateIntervalDays) * day
    }

    /// 联网失败时，距上次成功校验 30 天内仍视为已授权。
    static func isWithinOfflineGrace(lastValidated: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastValidated) <= TimeInterval(LicenseConfig.offlineGraceDays) * day
    }

    static func resolveState(trialStart: Date, license: StoredLicense?, now: Date) -> LicenseState {
        if let license, isWithinOfflineGrace(lastValidated: license.lastValidated, now: now) {
            return .licensed
        }
        return trialDaysRemaining(trialStart: trialStart, now: now) > 0 ? .trial : .expired
    }

    /// 「38b1460a-5104-…-77b872934d51」→「38B1••••••••4D51」
    static func maskedKey(_ key: String) -> String {
        let compact = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard compact.count > 4 else { return String(repeating: "•", count: max(compact.count, 4)) }
        guard compact.count > 8 else { return "••••" + compact.suffix(4) }
        return compact.prefix(4) + "••••••••" + compact.suffix(4)
    }
}

// MARK: - 管理器

@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager(syncsAppState: true)

    @Published private(set) var status: LicenseState = .trial
    @Published private(set) var trialDaysRemaining: Int = LicenseConfig.trialDays
    @Published private(set) var trialEndDate: Date?
    @Published private(set) var maskedKey: String?
    @Published private(set) var planName: String?
    @Published private(set) var activatedAt: Date?
    @Published private(set) var lastValidated: Date?
    /// 正在激活 / 校验 / 停用。
    @Published private(set) var isLoading = false
    /// 后台校验发现许可证失效时给用户看的说明。
    @Published private(set) var notice: String?

    /// 是否允许执行付费动作（已授权或仍在试用期内）。
    var allowsProActions: Bool {
        if !started { start() }
        let state = currentState()
        if state != status {
            Task { self.recompute() }
        }
        return state != .expired
    }

    /// 本机存有许可证，但超过离线宽限期未能联网校验。
    var needsOnlineValidation: Bool { license != nil && status != .licensed }

    private enum Account {
        static let trialStart = "trial-start"
        static let license = "license"
    }

    private enum Hint {
        static let trialStart = "LicenseHint.trialStart"
        static let state = "LicenseHint.state"
    }

    private let backend: LicenseBackend
    private let storage: LicenseStorage
    private let defaults: UserDefaults
    private let now: () -> Date
    private let syncsAppState: Bool

    private var trialStart: Date?
    private var license: StoredLicense?
    private var started = false
    private var forcedState: LicenseState?
    private var dayObserver: NSObjectProtocol?

    init(
        backend: LicenseBackend = LemonSqueezyLicenseBackend(),
        storage: LicenseStorage = KeychainLicenseStorage(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        syncsAppState: Bool = false
    ) {
        self.backend = backend
        self.storage = storage
        self.defaults = defaults
        self.now = now
        self.syncsAppState = syncsAppState
    }

    // MARK: 启动

    /// App 启动时调用一次：初始化试用期、读取许可证、按需在后台联网校验。
    func start() {
        guard !started else { return }
        started = true

        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["MACCLEAN_FORCE_LICENSE_STATE"] {
            forcedState = LicenseState(rawValue: raw.lowercased())
        }
        #endif

        loadPersistedState()
        recompute()

        dayObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recompute()
                self?.revalidateIfNeeded()
            }
        }
        revalidateIfNeeded()
    }

    private func loadPersistedState() {
        // 钥匙串和偏好设置里取更早的那个，单独删掉任意一处都不能重置试用。
        let stored = storage.data(for: Account.trialStart).flatMap(Self.decodeDate)
        let hinted = defaults.object(forKey: Hint.trialStart) as? Date
        let start = [stored, hinted].compactMap { $0 }.min() ?? now()
        if stored != start { storage.set(Self.encodeDate(start), for: Account.trialStart) }
        if hinted != start { defaults.set(start, forKey: Hint.trialStart) }
        trialStart = start

        license = storage.data(for: Account.license).flatMap { try? JSONDecoder().decode(StoredLicense.self, from: $0) }
    }

    // MARK: 激活 / 停用 / 校验

    func activate(key rawKey: String) async throws {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LicenseError.emptyKey }
        if !started { start() }
        isLoading = true
        defer { isLoading = false }

        let activation = try await backend.activate(key: key, instanceName: Self.instanceName())
        let time = now()
        saveLicense(StoredLicense(
            key: key,
            instanceID: activation.instanceID,
            planName: activation.planName,
            activatedAt: time,
            lastValidated: time
        ))
        notice = nil
        recompute()
    }

    /// 在此 Mac 上停用，释放一个激活名额。联网失败时抛错并保留本地授权。
    func deactivate() async throws {
        guard let current = license else { throw LicenseError.notActivated }
        isLoading = true
        defer { isLoading = false }

        try await backend.deactivate(key: current.key, instanceID: current.instanceID)
        saveLicense(nil)
        recompute()
    }

    /// 立即联网校验。网络失败时保留授权（离线宽限），服务端明确拒绝时撤销本地许可证。
    func revalidate() async {
        guard let current = license, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            switch try await backend.validate(key: current.key, instanceID: current.instanceID) {
            case .active(let plan):
                guard license?.key == current.key else { return }
                var updated = current
                updated.lastValidated = now()
                if let plan { updated.planName = plan }
                saveLicense(updated)
                notice = nil
            case .revoked(let reason):
                revoke(reason: reason)
            }
        } catch let error as LicenseError where error.isDefinitiveRejection {
            revoke(reason: error.localizedDescription)
        } catch {
            // 网络问题：保留授权，由离线宽限期兜底。
        }
        recompute()
    }

    private func revalidateIfNeeded() {
        guard forcedState == nil, let license,
              LicensePolicy.needsRevalidation(lastValidated: license.lastValidated, now: now()) else { return }
        Task { await revalidate() }
    }

    private func revoke(reason: String) {
        guard license != nil else { return }
        saveLicense(nil)
        notice = String(localized: "许可证已失效（\(reason)），如有疑问请联系客服")
    }

    private func saveLicense(_ newValue: StoredLicense?) {
        license = newValue
        storage.set(newValue.flatMap { try? JSONEncoder().encode($0) }, for: Account.license)
    }

    // MARK: 状态计算

    private func currentState() -> LicenseState {
        forcedState ?? LicensePolicy.resolveState(trialStart: trialStart ?? now(), license: license, now: now())
    }

    private func recompute() {
        let start = trialStart ?? now()
        var days = LicensePolicy.trialDaysRemaining(trialStart: start, now: now())
        var key = license.map { LicensePolicy.maskedKey($0.key) }
        var plan = license?.planName
        let state = currentState()
        if forcedState == .expired { days = 0 }
        if forcedState == .licensed, license == nil {
            key = "DEBU••••••••MODE"
            plan = "Debug"
        }

        if status != state { status = state }
        if trialDaysRemaining != days { trialDaysRemaining = days }
        trialEndDate = LicensePolicy.trialEndDate(trialStart: start)
        if maskedKey != key { maskedKey = key }
        if planName != plan { planName = plan }
        if activatedAt != license?.activatedAt { activatedAt = license?.activatedAt }
        if lastValidated != license?.lastValidated { lastValidated = license?.lastValidated }
        defaults.set(state.rawValue, forKey: Hint.state)
        syncAppState()
    }

    /// 侧栏等旧 UI 还读 AppState 上的副本，这里同步过去。
    private func syncAppState() {
        guard syncsAppState else { return }
        let app = AppState.shared
        let licensed = status == .licensed
        if app.isLicensed != licensed { app.isLicensed = licensed }
        if app.trialDaysRemaining != trialDaysRemaining { app.trialDaysRemaining = trialDaysRemaining }
        if app.licenseType != licenseType { app.licenseType = licenseType }
    }

    var licenseType: LicenseType {
        guard status == .licensed else { return .trial }
        let plan = (planName ?? "").lowercased()
        let subscription = ["年", "订阅", "annual", "year", "subscription"].contains { plan.contains($0) }
        return subscription ? .annual : .lifetime
    }

    // MARK: 工具

    /// 激活实例名：「Mac14,2 · 小王的 MacBook Air」，方便用户在 LemonSqueezy 后台辨认设备。
    static func instanceName() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        let model = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let host = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
        return model.isEmpty ? host : "\(model) · \(host)"
    }

    private static func encodeDate(_ date: Date) -> Data {
        Data(String(date.timeIntervalSince1970).utf8)
    }

    private static func decodeDate(_ data: Data) -> Date? {
        String(data: data, encoding: .utf8).flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
    }
}
