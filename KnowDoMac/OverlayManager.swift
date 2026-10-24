import AppKit
import SwiftUI

/// borderless 窗口默认不能成为 key window，键盘快捷键和输入框就都不工作，
/// 所以全屏页必须用这个子类（这是全屏页键盘流能成立的关键）。
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 全屏页呈现器：一个盖满主屏的 borderless NSWindow + SwiftUI 内容。
/// 三种页面：过半检查、Time's up 结束页、开始时间提醒页（见 OverlayViews）。
final class OverlayManager {
    static let shared = OverlayManager()

    private var windows: [OverlayWindow] = []
    private var alarmTimer: Timer? = nil
    var isShowing: Bool { !windows.isEmpty }

    private init() {}

    func showHalfCheck(task: TaskItem) {
        present(HalfCheckView(task: task))
    }

    /// 时间到：必须弹出（会顶掉正在显示的其它页），盖满所有屏幕，并循环响铃直到处理。
    func showTimeUp(task: TaskItem) {
        present(TimeUpView(task: task), alarm: true)
    }

    func showStartRemind(task: TaskItem) {
        present(StartRemindView(task: task))
    }

    /// 暂停到点叫回页：一声提示；60 秒内用户没任何反馈 → 起 60 秒渐强闹铃，任何按钮立即停铃。
    func showResumeCall(task: TaskItem, slot: TimerSlot) {
        present(ResumeCallView(task: task, emoji: slot.pauseEmoji ?? "⏸", reason: slot.pauseReason))
        if let s = NSSound(named: "Glass") { s.stop(); s.play() }
        AlarmRing.shared.arm(after: 60, duration: 60)
    }

    /// 任务衔接守卫页「接下来干什么？」。
    func showNextTask() {
        present(NextTaskView())
    }

    func dismiss() {
        AlarmRing.shared.cancel()
        alarmTimer?.invalidate()
        alarmTimer = nil
        for w in windows {
            w.orderOut(nil)
            w.close()
        }
        windows = []
    }

    private func present<V: View>(_ view: V, alarm: Bool = false) {
        dismiss()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let main = NSScreen.main ?? screens[0]
        for screen in screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)
            w.isOpaque = true
            w.hasShadow = false
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentViewController = NSHostingController(rootView: view)
            w.setFrame(screen.frame, display: true)
            if screen == main {
                w.makeKeyAndOrderFront(nil)
            } else {
                w.orderFrontRegardless()
            }
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        if alarm { startAlarm() }
    }

    private func startAlarm() {
        playAlarmSound()
        alarmTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard self?.isShowing == true else { return }
            self?.playAlarmSound()
        }
    }

    private func playAlarmSound() {
        if let s = NSSound(named: "Sosumi") ?? NSSound(named: "Glass") {
            s.stop()
            s.play()
        } else {
            NSSound.beep()
        }
    }
}

// MARK: - 全屏页共用样式（照 Smart Countdown Timer 的极简全屏页）

/// 整屏深色、一切居中。
struct OverlayScaffold<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.09)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                content()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 浅色圆角按钮（深底上的浅按钮，与参考图一致）。
struct OverlayButtonStyle: ButtonStyle {
    var primary: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: primary ? 17 : 15, weight: .semibold))
            .padding(.horizontal, 24)
            .padding(.vertical, primary ? 14 : 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.6 : 0.88)))
            .foregroundColor(Color(white: 0.12))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
