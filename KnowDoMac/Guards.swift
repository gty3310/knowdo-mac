import AppKit
import Foundation
import UserNotifications

// MARK: - 系统通知（静音叫回 / 空档提醒共用）

final class GuardNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = GuardNotifier()
    private var asked = false

    func setup() {
        UNUserNotificationCenter.current().delegate = self
    }

    func post(id: String, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let send = {
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
        }
        if asked { send(); return }
        asked = true
        center.requestAuthorization(options: [.alert]) { granted, _ in
            if granted { send() }
        }
    }

    func remove(id: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    // App 在前台时也要出横幅
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    // 点开静音叫回通知 → 弹叫回页处理
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == "knowdo.resume" {
            DispatchQueue.main.async { TimerEngine.shared.showResumeCallNow() }
        }
        completionHandler()
    }
}

// MARK: - 渐强闹铃（叫回页 60 秒无反馈 / 空档催促）

/// 用系统自带音循环播放，音量在 duration 内由小渐大；操作即停、满时长自动停。
/// 安卓用大自然鸟鸣素材（ogg），Mac 的 NSSound 不播 ogg，先用系统音代替。
final class AlarmRing {
    static let shared = AlarmRing()
    private var sound: NSSound?
    private var armTimer: Timer?
    private var rampTimer: Timer?
    private var startedAt = Date()
    private var duration: TimeInterval = 60
    private var onFinish: (() -> Void)?
    private(set) var isRinging = false

    /// after 秒后开始响；期间 cancel() 可撤销。
    func arm(after: TimeInterval, duration: TimeInterval = 60) {
        cancel()
        armTimer = Timer.scheduledTimer(withTimeInterval: after, repeats: false) { [weak self] _ in
            self?.start(duration: duration)
        }
    }

    func start(duration: TimeInterval = 60, onFinish: (() -> Void)? = nil) {
        stop()
        self.duration = max(5, duration)
        self.onFinish = onFinish
        startedAt = Date()
        let s = NSSound(named: "Glass") ?? NSSound(named: "Ping")
        s?.loops = true
        s?.volume = 0.05
        s?.play()
        sound = s
        isRinging = true
        rampTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = Date().timeIntervalSince(self.startedAt)
            if t >= self.duration {
                let cb = self.onFinish
                self.stop()
                cb?()
                return
            }
            self.sound?.volume = Float(max(0.05, min(1, t / self.duration)))
        }
    }

    /// 停响并撤销尚未开始的预约。
    func cancel() {
        armTimer?.invalidate()
        armTimer = nil
        stop()
    }

    private func stop() {
        rampTimer?.invalidate()
        rampTimer = nil
        sound?.stop()
        sound = nil
        onFinish = nil
        isRinging = false
    }
}

// MARK: - 任务衔接守卫（IdleGuard）

/// 空档 = 没在计时，也没有生效中的定时暂停。空档时全屏弹「接下来干什么？」。
/// 计时状态以 TimerEngine 为准（已含 Supabase timer_state 跨设备镜像：安卓在跑也算 running）。
@MainActor
final class IdleGuard {
    static let shared = IdleGuard()
    private init() {}

    static let enabledKey = "idleGuardEnabled"
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private var timer: Timer?
    private let launchedAt = Date()
    private var lastFiredAt = Date.distantPast
    private var snoozeUntil = Date.distantPast
    private let dismissSnooze: TimeInterval = 3 * 60

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAndFire() }
        }
    }

    /// 本地有效计时状态既非 running、又没有生效中的定时暂停。
    func isIdle() -> Bool {
        let e = TimerEngine.shared
        if e.running != nil { return false }
        return !timedPauseActive()
    }

    /// 暂停槽里有任务，且：远端镜像的暂停（叫回归发起端管）；或叫回时间在未来；
    /// 或叫回已发出且是静音模式 / 叫回页正在显示。没设叫回时间的本地暂停（过半页、重启遗留）算空档。
    private func timedPauseActive() -> Bool {
        guard let p = TimerEngine.shared.paused else { return false }
        if p.remote == true { return true }
        guard let ra = p.resumeAtMs, ra > 0 else { return false }
        if ra > nowMs() { return true }
        return p.pauseSilent == true || OverlayManager.shared.isShowing
    }

    private var blocked: Bool {
        OverlayManager.shared.isShowing || PauseCardController.shared.isShowing
    }

    /// 自动档（30 秒巡检）：用户正在我们自己的窗口里操作时不打扰；守卫页返回退出后静默 3 分钟。
    func checkAndFire() {
        guard Self.enabled, isIdle(), !blocked else { return }
        let now = Date()
        guard now.timeIntervalSince(launchedAt) > 20 else { return }     // 刚启动，云端计时还没对账
        guard now >= snoozeUntil else { return }
        guard now.timeIntervalSince(lastFiredAt) > 10 else { return }
        guard !NSApp.isActive else { return }
        fire()
    }

    /// 事件档（完成任务后）：不受静默期约束，3 秒防抖。
    func fireSoon(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, Self.enabled, self.isIdle(), !self.blocked else { return }
            guard Date().timeIntervalSince(self.lastFiredAt) > 3 else { return }
            self.fire()
        }
    }

    /// 守卫页被用户按返回/Esc 退出：自动档静默一段时间，让用户能临时翻任务、改设置。
    func snoozeOnDismiss() {
        snoozeUntil = Date().addingTimeInterval(dismissSnooze)
    }

    private func fire() {
        lastFiredAt = Date()
        OverlayManager.shared.showNextTask()
    }
}
