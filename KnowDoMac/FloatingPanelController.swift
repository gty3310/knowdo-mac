import AppKit
import SwiftUI

/// 桌面悬浮小窗：NSPanel 置顶、可拖、位置记忆。
/// 对应安卓的常驻悬浮窗——永远显示当前第一要务；收起时只剩菜单栏。
final class FloatingPanelController: NSObject {
    private var panel: NSPanel? = nil
    private let originKey = "floatingPanelOrigin"

    func setup() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 252),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: FloatingPanelView())

        if let saved = UserDefaults.standard.array(forKey: originKey) as? [Double],
           saved.count == 2 {
            p.setFrameOrigin(NSPoint(x: saved[0], y: saved[1]))
        } else if let vf = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vf.maxX - 336, y: vf.maxY - 268))
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidMove(_:)),
            name: NSWindow.didMoveNotification, object: p)
        NotificationCenter.default.addObserver(
            self, selector: #selector(visibilityChanged(_:)),
            name: .knowdoPanelVisibilityChanged, object: nil)
        panel = p
        applyVisibility()
    }

    @objc private func windowDidMove(_ note: Notification) {
        guard let f = panel?.frame else { return }
        UserDefaults.standard.set([Double(f.origin.x), Double(f.origin.y)], forKey: originKey)
    }

    @objc private func visibilityChanged(_ note: Notification) {
        applyVisibility()
    }

    func applyVisibility() {
        let show = UserDefaults.standard.object(forKey: "showFloatingPanel") as? Bool ?? true
        if show {
            panel?.orderFront(nil)
        } else {
            panel?.orderOut(nil)
        }
    }
}
