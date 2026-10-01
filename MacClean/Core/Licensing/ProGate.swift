//
//  ProGate.swift
//  MacClean
//
//  付费功能的统一入口。所有「真正动手」的操作（清理、卸载、禁用启动项、执行维护任务等）
//  在用户点击按钮、弹确认框之前调用 `ProGate.allowAction()`：
//  返回 true 继续；返回 false 时已自动弹出购买/激活页，调用方直接 return。
//  扫描、浏览、搜索永远免费，不要在这些地方调用。
//  策略：试用期（7 天）内全部放行；试用结束且未激活时，所有付费动作都弹购买页。
//

import AppKit

@MainActor
enum ProGate {
    /// 本次操作是否允许执行；不允许时负责弹出购买页。
    static func allowAction() -> Bool {
        if LicenseManager.shared.allowsProActions { return true }
        // 从菜单栏面板触发时主窗口可能在后台或已关闭：先打开主窗口，购买页挂在它上面。
        AppState.shared.openMainWindow()
        AppState.shared.showLicenseActivation = true
        return false
    }
}
