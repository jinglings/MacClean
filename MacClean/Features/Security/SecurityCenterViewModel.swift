//
//  SecurityCenterViewModel.swift
//  MacClean
//
//  安全中心的状态：三部分检查并行在后台运行，证书吊销检查（需联网）最后单独进行。
//  查看与扫描免费；停用 / 移到废纸篓之前过 ProGate。
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class SecurityCenterViewModel: ObservableObject {
    /// 页面视图会随侧栏切换销毁重建，结果常驻在这里
    static let shared = SecurityCenterViewModel()

    enum Section: String, CaseIterable, Identifiable {
        case protection, permissions, attention
        var id: String { rawValue }
    }

    enum RevocationState: Equatable {
        case idle
        case checking(Int)
        /// 已检查数量、被吊销数量
        case done(checked: Int, revoked: Int)
        /// 离线或超时，没有得出全部结论
        case incomplete(checked: Int)
    }

    struct Banner: Equatable {
        enum Style { case error, success }
        let style: Style
        let message: String
        var undoSessionID: UUID? = nil
    }

    @Published private(set) var protection: [ProtectionCheck] = []
    @Published private(set) var permissions = PermissionsReport.empty
    @Published private(set) var suspicious: SuspiciousScanResult?
    @Published private(set) var extensions: [BrowserExtension] = []
    @Published private(set) var revocation: RevocationState = .idle

    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var lastScannedAt: Date?
    @Published private(set) var busyIDs: Set<String> = []
    @Published var section: Section = .protection
    @Published var banner: Banner?

    private var scanTask: Task<Void, Never>?

    // MARK: - 汇总

    var protectionGoodCount: Int { protection.filter { $0.health == .good }.count }
    var protectionAttentionCount: Int { protection.filter { $0.health == .attention }.count }
    var protectionUnknownCount: Int { protection.filter { $0.health == .unknown }.count }

    var persistenceAttention: [PersistenceFinding] { suspicious?.persistence.filter { $0.severity == .attention } ?? [] }
    var persistenceInfo: [PersistenceFinding] { suspicious?.persistence.filter { $0.severity == .info } ?? [] }
    var appsAttention: [AppFinding] { suspicious?.apps.filter { $0.severity == .attention } ?? [] }
    var appsInfo: [AppFinding] { suspicious?.apps.filter { $0.severity == .info } ?? [] }
    var profiles: [ConfigurationProfile] { suspicious?.profiles.profiles ?? [] }
    var broadExtensions: [BrowserExtension] { extensions.filter(\.hasBroadPermissions) }

    /// 「值得留意」页的数量：启动项 + 应用 + 描述文件
    var attentionCount: Int { persistenceAttention.count + appsAttention.count + profiles.count }
    /// 提示数量：启动项 + 应用 + 权限较大的扩展
    var infoCount: Int { persistenceInfo.count + appsInfo.count + broadExtensions.count }

    // MARK: - 扫描

    func scan() {
        scanTask?.cancel()
        isScanning = true
        banner = nil
        revocation = .idle
        scanTask = Task { [weak self] in
            async let protection = Task.detached(priority: .userInitiated) { SystemProtectionScanner.scan() }.value
            async let permissions = Task.detached(priority: .userInitiated) { AppPermissionsScanner.scan() }.value
            async let suspicious = Task.detached(priority: .userInitiated) { SuspiciousItemsScanner.scan() }.value
            async let extensions = Task.detached(priority: .userInitiated) { BrowserExtensionScanner.scan() }.value
            let results = await (protection, permissions, suspicious, extensions)
            guard !Task.isCancelled, let self else { return }
            self.protection = results.0
            self.permissions = results.1
            self.suspicious = results.2
            self.extensions = results.3
            self.isScanning = false
            self.hasScanned = true
            self.lastScannedAt = Date()
            await self.checkRevocation(results.2.revocationCandidates)
        }
    }

    /// 联网检查应用证书 / 公证是否被吊销；放在最后、有时限，离线时跳过。
    private func checkRevocation(_ paths: [String]) async {
        guard !paths.isEmpty else {
            revocation = .done(checked: 0, revoked: 0)
            return
        }
        revocation = .checking(paths.count)
        let outcome = await Task.detached(priority: .utility) {
            CodeSignatureInspector.revocationStatuses(paths: paths)
        }.value
        guard !Task.isCancelled else { return }
        let revoked = outcome.results.filter(\.value).map(\.key).sorted()
        if !revoked.isEmpty, var current = suspicious {
            current.apps = SuspiciousItemsScanner.applyingRevocations(revoked, to: current.apps)
            suspicious = current
        }
        revocation = outcome.completed && outcome.results.count == paths.count
            ? .done(checked: paths.count, revoked: revoked.count)
            : .incomplete(checked: outcome.results.count)
    }

    /// 修改启动项后只重扫可疑项
    private func refreshSuspicious() async {
        let result = await Task.detached(priority: .userInitiated) { SuspiciousItemsScanner.scan() }.value
        // 保留已得出的吊销结论
        let revokedPaths = suspicious?.apps.filter { $0.reasons.contains(.revoked) }.map(\.path) ?? []
        var updated = result
        updated.apps = SuspiciousItemsScanner.applyingRevocations(revokedPaths, to: result.apps)
        suspicious = updated
    }

    // MARK: - 启动项操作（仅当前用户的启动代理）

    func disable(_ finding: PersistenceFinding) {
        let item = finding.item
        guard item.isEditable, !item.isDisabled, let plistPath = item.plistPath, !busyIDs.contains(item.id) else { return }
        guard ProGate.allowAction() else { return }
        busyIDs.insert(item.id)
        banner = nil
        let label = item.label
        Task {
            let failure = await Task.detached(priority: .userInitiated) {
                LaunchCtl.disableUserAgent(label: label, plistPath: plistPath)
            }.value
            banner = failure.map { Banner(style: .error, message: $0) }
                ?? Banner(style: .success, message: String(localized: "已停用「\(item.displayName)」，它不会再自动运行；可在「启动项」中重新开启"))
            await refreshSuspicious()
            busyIDs.remove(item.id)
        }
    }

    /// 调用方在弹确认框之前已经过 ProGate
    func moveToTrash(_ finding: PersistenceFinding) async {
        let item = finding.item
        guard item.isEditable, let plistPath = item.plistPath else { return }
        busyIDs.insert(item.id)
        banner = nil

        await Task.detached(priority: .userInitiated) {
            LaunchCtl.bootoutUserAgent(plistPath: plistPath)
        }.value

        var cleanable = CleanableItem(
            name: (plistPath as NSString).lastPathComponent,
            path: plistPath,
            size: 0,
            category: .brokenLoginItems,
            isSelected: true,
            description: finding.executable.map { String(localized: "启动程序: \($0)") },
            lastModified: nil
        )
        cleanable.removesContainer = true

        do {
            let result = try await CleanupManager.shared.clean(items: [cleanable])
            if result.errors.isEmpty {
                banner = Banner(style: .success, message: String(localized: "已将「\(item.displayName)」的配置移入废纸篓"), undoSessionID: result.historySessionID)
            } else {
                let detail = result.errors.first?.message ?? ""
                banner = Banner(style: .error, message: String(localized: "未能移除：\(detail)"), undoSessionID: result.historySessionID)
            }
        } catch {
            banner = Banner(style: .error, message: String(localized: "移除失败：\(error.localizedDescription)"))
        }
        await refreshSuspicious()
        busyIDs.remove(item.id)
    }

    func undo(sessionID: UUID) async {
        let result = await CleanupManager.shared.restore(sessionID: sessionID)
        banner = result.failedPaths.isEmpty
            ? Banner(style: .success, message: String(localized: "已恢复 \(result.restoredCount) 个启动项，下次登录时生效"))
            : Banner(style: .error, message: String(localized: "有 \(result.failedPaths.count) 个项目未能恢复，可能已从废纸篓清空"))
        await refreshSuspicious()
    }

    // MARK: - 跳转

    func openSettings(_ urls: [String]) {
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    func openAppManager() {
        AppState.shared.currentTab = .appUninstaller
    }
}
