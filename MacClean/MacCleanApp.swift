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
    
    var body: some Scene {
        // 主窗口
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MacClean") {
                    appState.showAboutWindow = true
                }
            }
            
            CommandGroup(replacing: .newItem) { }
            
            CommandMenu("Clean") {
                Button("Quick Clean") {
                    appState.startQuickClean()
                }
                .keyboardShortcut("K", modifiers: [.command, .shift])
                
                Divider()
                
                Button("Scan Disk") {
                    appState.startDiskScan()
                }
                .keyboardShortcut("S", modifiers: [.command])
            }
        }
        
        // 菜单栏应用
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Label("MacClean", systemImage: "externaldrive.badge.checkmark")
        }
        .menuBarExtraStyle(.window)
        
        // 设置窗口
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("MacClean 启动完成")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        print("MacClean 正在退出")
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
