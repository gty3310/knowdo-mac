import AppKit
import Combine
import SwiftUI

/// 悬浮窗的展开状态；由 AppKit 层的鼠标追踪驱动，SwiftUI 只负责按它渲染。
final class PanelHoverState: ObservableObject {
    static let shared = PanelHoverState()
    @Published var expanded = false
}

/// 用 NSTrackingArea（activeAlways）自己接管 hover：非激活面板里 SwiftUI 的 onHover 不可靠。
private final class TrackingHostingView<Content: View>: NSHostingView<Content> {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

/// 文本框要能打字，面板必须能成为 key（仍是 nonactivating，不抢前台 App 焦点）。
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 桌面悬浮小窗：默认一个小胶囊（已用 / 共计划），鼠标移入立刻展开成完整面板并变更透明。
/// 位置以右上角为锚点记忆，展开/收起时右上角不动。
final class FloatingPanelController: NSObject {
    static let compactSize = NSSize(width: 240, height: 30)
    static let expandedSize = NSSize(width: 320, height: 252)

    private var panel: NSPanel? = nil
    private let anchorKey = "floatingPanelAnchor.v2"
    private var resizing = false
    private var collapseAfterEditing = false
    private var expandedSink: AnyCancellable?
    private var snoozeTimer: Timer?
    static let snoozeUntilKey = "floatingPanelSnoozeUntilMs"
    static let snoozeTaskKey = "floatingPanelSnoozeTaskId"

    /// 暂时收起悬浮窗：minutes 分钟后自动再现；截止时刻写进 UserDefaults，重启照算。
    static func snooze(minutes: Int) {
        UserDefaults.standard.set(Double(nowMs()) + Double(minutes) * 60_000, forKey: snoozeUntilKey)
        UserDefaults.standard.removeObject(forKey: snoozeTaskKey)
        NotificationCenter.default.post(name: .knowdoPanelVisibilityChanged, object: nil)
    }

    /// 等当前任务结束（不再是计时/暂停槽里的任务）再回来。
    static func snoozeUntilTaskEnds(taskId: String) {
        UserDefaults.standard.set(taskId, forKey: snoozeTaskKey)
        UserDefaults.standard.removeObject(forKey: snoozeUntilKey)
        NotificationCenter.default.post(name: .knowdoPanelVisibilityChanged, object: nil)
    }

    /// 不再出现（设置里的开关可重新打开）。
    static func hideForGood() {
        UserDefaults.standard.set(false, forKey: "showFloatingPanel")
        clearSnooze()
    }

    /// 立刻把悬浮窗找回来（清 snooze、打开开关）。
    static func reveal() {
        UserDefaults.standard.set(true, forKey: "showFloatingPanel")
        clearSnooze()
    }

    private static func clearSnooze() {
        UserDefaults.standard.removeObject(forKey: snoozeUntilKey)
        UserDefaults.standard.removeObject(forKey: snoozeTaskKey)
        NotificationCenter.default.post(name: .knowdoPanelVisibilityChanged, object: nil)
    }

    private var snoozed: Bool {
        let d = UserDefaults.standard
        let until = d.double(forKey: Self.snoozeUntilKey)
        if until > 0 {
            if Double(nowMs()) < until { return true }
            d.removeObject(forKey: Self.snoozeUntilKey)
        }
        if let id = d.string(forKey: Self.snoozeTaskKey) {
            let current = MainActor.assumeIsolated { TimerEngine.shared.currentSlot?.taskId }
            if current == id { return true }
            d.removeObject(forKey: Self.snoozeTaskKey)
        }
        return false
    }

    func setup() {
        let p = FloatingPanel(contentRect: NSRect(origin: .zero, size: Self.compactSize),
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

        let host = TrackingHostingView(rootView: FloatingPanelView())
        host.sizingOptions = []
        host.onEnter = { [weak self] in self?.setExpanded(true) }
        host.onExit = { [weak self] in self?.mouseLeft() }
        p.contentView = host

        if let saved = UserDefaults.standard.array(forKey: anchorKey) as? [Double], saved.count == 2 {
            place(p, topRight: NSPoint(x: saved[0], y: saved[1]), size: Self.compactSize)
        } else if let vf = NSScreen.main?.visibleFrame {
            place(p, topRight: NSPoint(x: vf.maxX - 16, y: vf.maxY - 16), size: Self.compactSize)
        }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(windowDidMove(_:)),
                       name: NSWindow.didMoveNotification, object: p)
        nc.addObserver(self, selector: #selector(windowDidResignKey(_:)),
                       name: NSWindow.didResignKeyNotification, object: p)
        nc.addObserver(self, selector: #selector(visibilityChanged(_:)),
                       name: .knowdoPanelVisibilityChanged, object: nil)
        // 展开状态只有一个来源（PanelHoverState）：鼠标进出和面板上的「✕」都改它，尺寸跟着它走
        expandedSink = PanelHoverState.shared.$expanded
            .removeDuplicates()
            .sink { [weak self] expanded in self?.resize(expanded: expanded) }
        panel = p
        applyVisibility()
        // 到点 / 任务结束后自动再现
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.applyVisibility()
        }
    }

    // MARK: - 展开 / 收起

    private func mouseLeft() {
        // 正在笔记框里打字时先不收，等失焦后再收
        if let p = panel, p.isKeyWindow, p.firstResponder is NSTextView {
            collapseAfterEditing = true
            return
        }
        setExpanded(false)
    }

    @objc private func windowDidResignKey(_ note: Notification) {
        guard collapseAfterEditing, let p = panel else { return }
        collapseAfterEditing = false
        let inside = p.frame.contains(NSEvent.mouseLocation)
        if !inside { setExpanded(false) }
    }

    private func setExpanded(_ expanded: Bool) {
        collapseAfterEditing = false
        PanelHoverState.shared.expanded = expanded
    }

    private func resize(expanded: Bool) {
        guard let p = panel else { return }
        let size = expanded ? Self.expandedSize : Self.compactSize
        let topRight = NSPoint(x: p.frame.maxX, y: p.frame.maxY)
        resizing = true
        p.setFrame(NSRect(x: topRight.x - size.width, y: topRight.y - size.height,
                          width: size.width, height: size.height),
                   display: true, animate: false)
        resizing = false
    }

    private func place(_ p: NSPanel, topRight: NSPoint, size: NSSize) {
        p.setFrame(NSRect(x: topRight.x - size.width, y: topRight.y - size.height,
                          width: size.width, height: size.height), display: false)
    }

    // MARK: - 位置记忆 / 显隐

    @objc private func windowDidMove(_ note: Notification) {
        guard !resizing, let f = panel?.frame else { return }
        UserDefaults.standard.set([Double(f.maxX), Double(f.maxY)], forKey: anchorKey)
    }

    @objc private func visibilityChanged(_ note: Notification) {
        applyVisibility()
    }

    func applyVisibility() {
        let enabled = UserDefaults.standard.object(forKey: "showFloatingPanel") as? Bool ?? true
        if enabled && !snoozed {
            if panel?.isVisible != true {
                PanelHoverState.shared.expanded = false
                panel?.orderFront(nil)
            }
        } else if panel?.isVisible == true {
            PanelHoverState.shared.expanded = false
            panel?.orderOut(nil)
        }
    }
}
