//
//  UISnapshotTests.swift
//  MacCleanTests
//
//  离屏渲染各页面为 PNG，供界面走查（不做像素断言）。
//  仅在设置环境变量 MACCLEAN_SNAPSHOT_DIR 时运行。
//

import AppKit
import SwiftUI
import Testing
@testable import MacClean

@MainActor
struct UISnapshotTests {
    @Test func renderAllTabs() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MACCLEAN_SNAPSHOT_DIR"] else { return }
        let outDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        if ProcessInfo.processInfo.environment["MACCLEAN_SNAPSHOT_SCAN"] == "1" {
            // 真实只读扫描，用来查看有结果时的界面
            PageModelStore.shared.reclaim.scanAll()
            PageModelStore.shared.smartCare.scanAll()
            PageModelStore.shared.appUninstaller.startScan()
            PageModelStore.shared.spaceLens.startScan()
            LoginItemsViewModel.shared.scan()
            for _ in 0..<480 {
                try await Task.sleep(for: .milliseconds(500))
                if PageModelStore.shared.reclaim.hasScanned && !PageModelStore.shared.reclaim.isScanning
                    && !PageModelStore.shared.smartCare.isScanningAny
                    && PageModelStore.shared.appUninstaller.state == .results
                    && PageModelStore.shared.spaceLens.phase == .results
                    && LoginItemsViewModel.shared.hasScanned { break }
            }
        }

        let tabs = ProcessInfo.processInfo.environment["MACCLEAN_SNAPSHOT_TABS"].flatMap { $0.isEmpty ? nil : $0 }.map { $0.split(separator: ",").map(String.init) }
        for (mode, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            for tab in AppTab.allCases where tabs?.contains(tab.rawValue) ?? true {
                AppState.shared.currentTab = tab
                let root = ContentView()
                    .environmentObject(AppState.shared)
                    .frame(width: 1180, height: 760)
                try await snapshot(root, size: CGSize(width: 1180, height: 760), appearance: appearance, to: outDir.appendingPathComponent("\(mode)-\(tab.rawValue).png"))
            }
            if tabs == nil || tabs!.contains("menubar") {
                try await snapshot(
                    MenuBarView().environmentObject(AppState.shared),
                    size: CGSize(width: 380, height: 640),
                    appearance: appearance,
                    to: outDir.appendingPathComponent("\(mode)-menubar.png")
                )
            }
            if tabs == nil || tabs!.contains("onboarding") {
                try await snapshot(
                    OnboardingView().environmentObject(AppState.shared),
                    size: CGSize(width: 640, height: 560),
                    appearance: appearance,
                    to: outDir.appendingPathComponent("\(mode)-onboarding.png")
                )
            }
        }
    }

    private func snapshot<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL) async throws {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderBack(nil)
        // 给 onAppear / task 一点时间完成首轮状态更新
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
        }
        // 走 layer 渲染到 sRGB 位图：cacheDisplay 会把颜色洗淡，layer.render 颜色准确。
        host.wantsLayer = true
        host.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let layer = host.layer else { return }
        ctx.scaleBy(x: scale, y: scale)
        // CALayer 坐标系 y 轴向下（NSHostingView 是 flipped），翻转到 CG 坐标
        if host.isFlipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        guard let image = ctx.makeImage() else { return }
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}

