//
//  AppUpdater.swift
//  MacClean
//
//  应用自动更新的统一入口，由 Sparkle 2 实现。
//  Info.plist（MacClean-Info.plist）里的 SUPublicEDKey 仍是占位值时，更新功能自动停用，
//  避免开发版启动时弹出 Sparkle 的配置错误。
//

import Combine
import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// 是否自动检查更新（设置页绑定这个值）
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard let controller, automaticallyChecksForUpdates != controller.updater.automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// 当前是否可以手动检查（检查进行中、或更新未配置时为 false）
    @Published private(set) var canCheckForUpdates = false

    /// 发布配置是否完整（公钥已填写）
    let isConfigured: Bool

    #if canImport(Sparkle)
    private let controller: SPUStandardUpdaterController?
    #else
    private let controller: NoUpdaterController? = nil
    #endif
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = !key.isEmpty && !key.hasPrefix("REPLACE_")

        #if canImport(Sparkle)
        if isConfigured {
            let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            self.controller = controller
            automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
            controller.updater.publisher(for: \.canCheckForUpdates)
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.canCheckForUpdates = $0 }
                .store(in: &cancellables)
        } else {
            controller = nil
            automaticallyChecksForUpdates = false
        }
        #else
        automaticallyChecksForUpdates = false
        #endif
    }

    /// 启动时调用一次，让 Sparkle 按计划在后台检查（初始化本身即启动）。
    func start() {}

    /// 手动检查更新（菜单「检查更新…」与设置页按钮调用）
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

#if !canImport(Sparkle)
/// Sparkle 未链接时的空实现，保持 AppUpdater 接口可编译。
final class NoUpdaterController {
    final class Updater { var automaticallyChecksForUpdates = false }
    let updater = Updater()
    func checkForUpdates(_ sender: Any?) {}
}
#endif
