//
//  MacCleanApp.swift
//  MacClean
//
//  Mac 清理工具主应用入口
//

import SwiftUI

@main
struct MacCleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    @AppStorage("showInMenuBar") private var showInMenuBar = true

    var body: some Scene {
        // 主窗口（菜单栏面板通过 id 重新打开已关闭的主窗口）
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 600)
                .modifier(AppShellActions())
        }
        .defaultSize(width: 1180, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            MacCleanCommands(appState: appState)
        }

        // 关于窗口
        Window("关于 MacClean", id: "about") {
            AboutView()
                .frame(width: 360)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // 菜单栏应用（设置里可隐藏）
        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarView()
                .environmentObject(appState)
                .modifier(AppShellActions())
        } label: {
            MenuBarStatusLabel()
        }
        .menuBarExtraStyle(.window)

        // 设置窗口
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

// MARK: - 菜单命令

struct MacCleanCommands: Commands {
    @ObservedObject var appState: AppState
    @ObservedObject private var updater = AppUpdater.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 MacClean") {
                openWindow(id: "about")
                NSApp.activate()
            }
            Button("检查更新…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }

        CommandGroup(replacing: .newItem) { }

        CommandMenu(Text("clean_menu", tableName: nil)) {
            Button("一键体检") {
                appState.startSmartCareScan()
            }
            .keyboardShortcut("K", modifiers: [.command, .shift])

            Button("存储地图") {
                appState.openMainWindow(tab: .diskAnalysis)
            }

            Divider()

            Button("搜索文件") {
                appState.openMainWindow(tab: .fileSearch)
            }
            .keyboardShortcut("F", modifiers: [.command])
        }
    }
}

// MARK: - 场景级动作注入

/// 把 openWindow / openSettings 交给 AppState，并把 `showSettingsWindow` 路由到真正的「设置」场景。
/// 主窗口与菜单栏面板都挂一份：任一存活即可响应。
struct AppShellActions: ViewModifier {
    @ObservedObject private var appState = AppState.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content
            .onAppear {
                appState.openWindowAction = openWindow
            }
            .onChange(of: appState.showSettingsWindow) { _, show in
                guard show else { return }
                appState.showSettingsWindow = false
                NSApp.activate()
                openSettings()
            }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearance.current.apply()
        LicenseManager.shared.start()
        AppUpdater.shared.start()
        DiskAlertScheduler.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
