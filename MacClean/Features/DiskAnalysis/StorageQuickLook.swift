//
//  StorageQuickLook.swift
//  MacClean
//
//  存储地图的「快速查看」：空格预览当前行，再按一次关闭；上下键移动时跟着刷新。
//  直接驱动 QLPreviewPanel（App 未沙盒），文件夹由系统显示图标与大小摘要，与 Finder 一致。
//

import AppKit
import Quartz

final class StorageQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = StorageQuickLook()
    private var url: URL?

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// 空格键：已打开则关闭，否则预览 path。
    func toggle(_ path: String) {
        if isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        } else {
            show(path)
        }
    }

    func show(_ path: String) {
        url = URL(fileURLWithPath: path)
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return
        }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if panel.isVisible {
            panel.refreshCurrentPreviewItem()
        } else {
            // 不抢键盘焦点：主窗口继续接收空格 / 上下键，像 Finder 一样边移动边预览。
            panel.orderFront(nil)
        }
    }

    /// 焦点行变化时，面板开着就跟着换内容。
    func followIfVisible(_ path: String) {
        guard isVisible else { return }
        show(path)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }

    /// 面板成为前台时按下空格也能关闭。
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, event.charactersIgnoringModifiers == " " else { return false }
        MainActor.assumeIsolated { panel.orderOut(nil) }
        return true
    }
}
