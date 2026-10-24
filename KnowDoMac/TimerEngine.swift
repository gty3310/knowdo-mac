import Foundation

/// 一个计时槽：plannedSeconds 是本轮计划总秒数，
/// accumulatedSeconds 是本轮已关闭的段累计（正在跑的那段不含，靠 segmentStart 现算）。
struct TimerSlot: Codable, Equatable {
    var taskId: String
    var plannedSeconds: Int
    var accumulatedSeconds: Int
    var halfFired: Bool
    // ---- 暂停槽元数据（任务四：暂停带目的与到点叫回；旧数据缺省为 nil）----
    var resumeAtMs: Int64? = nil      // 到点叫回的时刻；nil＝没设（远端镜像暂停、过半/到时/重启遗留）
    var pauseReason: String? = nil    // 目的显示名（与安卓同口径）
    var pauseEmoji: String? = nil
    var pauseSilent: Bool? = nil      // 静音：到点只发系统通知
    var resumeFired: Bool? = nil      // 到点叫回已发出
    var remote: Bool? = nil           // 暂停态由另一台设备镜像而来

    mutating func clearPauseMeta() {
        resumeAtMs = nil; pauseReason = nil; pauseEmoji = nil
        pauseSilent = nil; resumeFired = nil; remote = nil
    }
}

/// 远端 user_state.timer_state 的解析结果。
struct RemoteTimerState {
    var taskId: String
    var phase: String          // running / paused / idle
    var startedAt: Int64       // epoch 毫秒
    var accumulated: Int       // 秒
    var duration: Int          // 秒
    var updatedBy: String
    var updatedAt: Int64
    var pauseReason: String? = nil
    var pauseEmoji: String? = nil
    var pauseSilent: Bool = false
}

/// 计时引擎：全局最多一个计时中 + 一个暂停槽（与安卓 TimerState 语义一致）。
/// 每秒 tick 一次：刷新剩余/已用、查过半、查结束、扫 nextStartAt 开始提醒。
/// 槽位持久化到 UserDefaults：App 退出/崩溃后，计时中的任务恢复为「暂停」态，不丢进度。
@MainActor
final class TimerEngine: ObservableObject {
    static let shared = TimerEngine()

    @Published private(set) var running: TimerSlot? = nil
    @Published private(set) var paused: TimerSlot? = nil
    @Published private(set) var remainingSeconds: Int = 0
    @Published private(set) var elapsedSeconds: Int = 0

    private var segmentStart: Date? = nil
    private var ticker: Timer? = nil
    private var remindedStarts: Set<String> = []
    private let slotsKey = "timerSlots.v1"
    private var silentNextNudgeMs: Int64 = 0
    private var nudgePosted = false

    var currentSlot: TimerSlot? { running ?? paused }
    var currentTask: TaskItem? {
        currentSlot.flatMap { SyncManager.shared.task(id: $0.taskId) }
    }
    /// 当前第一要务：计时中 ＞ 刚暂停 ＞ 列表第一未完成（与安卓悬浮窗同口径）。
    var topTask: TaskItem? {
        if let t = currentTask { return t }
        return SyncManager.shared.tasks.first { !$0.deleted && !$0.isDoneToday() }
    }

    private init() {
        restoreSlots()
        refreshNumbers()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    // MARK: - 基本动作

    func isRunning(_ taskId: String) -> Bool { running?.taskId == taskId }
    func isPaused(_ taskId: String) -> Bool { paused?.taskId == taskId }
    func slot(for taskId: String) -> TimerSlot? {
        if running?.taskId == taskId { return running }
        if paused?.taskId == taskId { return paused }
        return nil
    }

    func start(taskId: String) {
        guard let task = SyncManager.shared.task(id: taskId), !task.deleted else { return }
        if running?.taskId == taskId { return }
        if paused?.taskId == taskId { resumePaused(); return }
        // 正在跑别的任务：先把它压进暂停槽（更早的暂停槽计时状态让位丢弃，已计时段都在 SessionLog 里）
        if var r = running {
            r.accumulatedSeconds = liveElapsed(of: r)
            SessionStore.shared.close()
            paused = r
            running = nil
            segmentStart = nil
        }
        running = TimerSlot(taskId: taskId,
                             plannedSeconds: max(1, task.durationMinutes) * 60,
                             accumulatedSeconds: 0,
                             halfFired: false)
        segmentStart = Date()
        SessionStore.shared.open(taskId: taskId, title: task.title)
        refreshNumbers()
        persist()
    }

    func pause() {
        guard var r = running else { return }
        r.accumulatedSeconds = liveElapsed(of: r)
        SessionStore.shared.close()
        paused = r
        running = nil
        segmentStart = nil
        refreshNumbers()
        persist()
    }

    func resumePaused() {
        guard let p = paused else { return }
        if var r = running {
            r.accumulatedSeconds = liveElapsed(of: r)
            SessionStore.shared.close()
            paused = r
        } else {
            paused = nil
        }
        var q = p
        q.clearPauseMeta()
        running = q
        segmentStart = Date()
        let title = SyncManager.shared.task(id: p.taskId)?.title ?? ""
        SessionStore.shared.open(taskId: p.taskId, title: title)
        refreshNumbers()
        persist()
    }

    /// 带目的与时长的暂停（暂停卡确认后调用）：任务在跑就先暂停；已在暂停槽（过半页/换目的）则只改元数据。
    func pauseWithPurpose(taskId: String, minutes: Int, reason: String, emoji: String, silent: Bool) {
        if running?.taskId == taskId { pause() }
        guard var p = paused, p.taskId == taskId, minutes > 0 else { return }
        p.resumeAtMs = nowMs() + Int64(minutes) * 60_000
        p.pauseReason = reason
        p.pauseEmoji = emoji
        p.pauseSilent = silent
        p.resumeFired = false
        p.remote = false
        paused = p
        silentNextNudgeMs = 0
        refreshNumbers()
        persist()
    }

    /// 暂停中再歇一会儿：按新时长重设叫回，目的不变。
    func delayResume(minutes: Int) {
        guard var p = paused, minutes > 0 else { return }
        p.resumeAtMs = nowMs() + Int64(minutes) * 60_000
        p.resumeFired = false
        p.remote = false
        paused = p
        silentNextNudgeMs = 0
        persist()
    }

    /// 暂停剩余秒数（距叫回）；没设叫回时间返回 nil。
    func pauseRemainingSeconds(now: Int64 = nowMs()) -> Int? {
        guard let ra = paused?.resumeAtMs, ra > 0 else { return nil }
        return max(0, Int((ra - now + 999) / 1000))
    }

    /// 行内 ▶/⏸ 与悬浮窗、菜单栏共用的开关。
    func toggle(taskId: String) {
        if running?.taskId == taskId {
            // 暂停必带时长与目的：统一弹暂停卡，不再有无限期暂停
            PauseCardController.shared.show(taskId: taskId)
        } else if paused?.taskId == taskId {
            resumePaused()
        } else {
            start(taskId: taskId)
        }
    }

    /// 重置某任务的计时（槽清掉；已计时段保留在 SessionLog）。
    func reset(taskId: String) {
        if running?.taskId == taskId {
            SessionStore.shared.close()
            running = nil
            segmentStart = nil
        } else if paused?.taskId == taskId {
            paused = nil
        } else {
            return
        }
        refreshNumbers()
        persist()
    }

    /// 完成某任务：清槽 + 写回 doneDates/status 经桥同步（markDone 语义与安卓一致）。
    func completeTask(taskId: String) {
        if running?.taskId == taskId {
            SessionStore.shared.close()
            running = nil
            segmentStart = nil
        } else if paused?.taskId == taskId {
            paused = nil
        }
        SyncManager.shared.mutate(id: taskId) { $0.markDone() }
        refreshNumbers()
        persist()
        IdleGuard.shared.fireSoon(after: 1.0)
    }

    func completeCurrent() {
        guard let slot = currentSlot else { return }
        completeTask(taskId: slot.taskId)
    }

    /// 加时：暂停槽（含到时停住的）加完直接继续跑，与安卓结束页行为一致。
    func extend(minutes: Int) {
        guard minutes > 0 else { return }
        if var r = running {
            r.plannedSeconds += minutes * 60
            running = r
        } else if var p = paused {
            p.plannedSeconds += minutes * 60
            p.clearPauseMeta()
            paused = nil
            running = p
            segmentStart = Date()
            let title = SyncManager.shared.task(id: p.taskId)?.title ?? ""
            SessionStore.shared.open(taskId: p.taskId, title: title)
        } else {
            return
        }
        refreshNumbers()
        persist()
    }

    /// autoStart 入口：没在计时才开始；成功后把桥上的 autoStart 清掉写回。
    /// 有计时在跑则不动（autoStart 留在桥上，下一轮轮询再试，等于排队）。
    func tryAutoStart(taskId: String) {
        guard running == nil else { return }
        guard let t = SyncManager.shared.task(id: taskId),
              t.autoStart, !t.deleted, !t.isDoneToday() else { return }
        start(taskId: taskId)
        if running?.taskId == taskId {
            SyncManager.shared.mutate(id: taskId) { $0.autoStart = false }
        }
    }

    // MARK: - 每秒 tick

    private func tick() {
        refreshNumbers()
        checkHalf()
        checkEnd()
        checkStartReminders()
        checkResumeCall()
    }

    /// 暂停到点叫回：普通模式弹全屏叫回页（一声提示＋60 秒无反馈起渐强闹铃）；
    /// 静音模式只发系统通知，无反馈每 5 分钟再发一次，直到用户处理。
    private func checkResumeCall() {
        guard var p = paused, let ra = p.resumeAtMs, ra > 0 else {
            clearNudgeIfNeeded()
            return
        }
        let now = nowMs()
        let silent = p.pauseSilent == true
        if p.resumeFired != true {
            guard now >= ra else { return }
            if !silent, OverlayManager.shared.isShowing { return }   // 别的全屏页在显，等它处理完
            p.resumeFired = true
            paused = p
            persist(notify: false)
            if silent {
                postSilentNudge(p)
                silentNextNudgeMs = now + 300_000
            } else if let task = SyncManager.shared.task(id: p.taskId) {
                OverlayManager.shared.showResumeCall(task: task, slot: p)
            }
        } else if silent {
            if silentNextNudgeMs == 0 {
                silentNextNudgeMs = now + 300_000      // 重启后接着循环
            } else if now >= silentNextNudgeMs {
                postSilentNudge(p)
                silentNextNudgeMs = now + 300_000
            }
        }
    }

    private func postSilentNudge(_ p: TimerSlot) {
        let title = SyncManager.shared.task(id: p.taskId)?.title ?? ""
        GuardNotifier.shared.post(
            id: "knowdo.resume",
            title: "\(p.pauseEmoji ?? "⏸") 暂停时间到了",
            body: "回来继续「\(title)」，或换下一个任务")
        nudgePosted = true
    }

    private func clearNudgeIfNeeded() {
        silentNextNudgeMs = 0
        if nudgePosted {
            GuardNotifier.shared.remove(id: "knowdo.resume")
            nudgePosted = false
        }
    }

    /// 点开静音通知后：把叫回页弹出来处理。
    func showResumeCallNow() {
        guard let p = paused, let task = SyncManager.shared.task(id: p.taskId) else { return }
        OverlayManager.shared.showResumeCall(task: task, slot: p)
    }

    private func liveElapsed(of slot: TimerSlot) -> Int {
        var e = slot.accumulatedSeconds
        if running?.taskId == slot.taskId, let start = segmentStart {
            e += max(0, Int(Date().timeIntervalSince(start)))
        }
        return e
    }

    private func refreshNumbers() {
        if let r = running {
            elapsedSeconds = liveElapsed(of: r)
            remainingSeconds = max(0, r.plannedSeconds - elapsedSeconds)
        } else if let p = paused {
            elapsedSeconds = p.accumulatedSeconds
            remainingSeconds = max(0, p.plannedSeconds - p.accumulatedSeconds)
        } else {
            elapsedSeconds = 0
            remainingSeconds = 0
        }
    }

    private func checkHalf() {
        guard var r = running, !r.halfFired, r.plannedSeconds > 0 else { return }
        let elapsed = liveElapsed(of: r)
        guard elapsed * 2 >= r.plannedSeconds, elapsed < r.plannedSeconds else { return }
        // 过半：先落段转暂停，再弹全屏检查页（继续/完成/暂停三键，与安卓一致）
        r.halfFired = true
        r.accumulatedSeconds = elapsed
        SessionStore.shared.close()
        paused = r
        running = nil
        segmentStart = nil
        refreshNumbers()
        persist()
        if let task = SyncManager.shared.task(id: r.taskId), !OverlayManager.shared.isShowing {
            OverlayManager.shared.showHalfCheck(task: task)
        }
    }

    private func checkEnd() {
        guard var r = running, r.plannedSeconds > 0 else { return }
        let elapsed = liveElapsed(of: r)
        guard elapsed >= r.plannedSeconds else { return }
        // 到时：落段、停在暂停槽（剩余 0），弹 Time's up 全屏页等用户加时或确认完成
        r.accumulatedSeconds = r.plannedSeconds
        SessionStore.shared.close()
        paused = r
        running = nil
        segmentStart = nil
        refreshNumbers()
        persist()
        if let task = SyncManager.shared.task(id: r.taskId) {
            OverlayManager.shared.showTimeUp(task: task)
        }
    }

    /// 扫 nextStartAt 到点的任务，弹全屏开始提醒（跳过规则与安卓 StartReceiver 一致：
    /// 已删 / 今日已完成 / 正在计时这个任务，都不弹；已被改到未来则自然不再命中）。
    private func checkStartReminders() {
        let now = Date()
        for t in SyncManager.shared.tasks where !t.deleted && !t.isDoneToday() {
            guard let d = t.nextStartDate() else { continue }
            guard d <= now, d >= now.addingTimeInterval(-600) else { continue }
            let key = t.id + "|" + (t.nextStartAt ?? "")
            if remindedStarts.contains(key) { continue }
            if currentSlot?.taskId == t.id { continue }
            remindedStarts.insert(key)
            if !OverlayManager.shared.isShowing {
                OverlayManager.shared.showStartRemind(task: t)
            }
        }
    }

    // MARK: - 持久化（退出恢复）

    private struct Persisted: Codable {
        var running: TimerSlot?
        var paused: TimerSlot?
        var segmentStartMs: Int64
    }

    /// notify=false：应用远端状态时不要再通知 TimerSync 推回云端（防回声）。
    func persist(notify: Bool = true) {
        let p = Persisted(
            running: running,
            paused: paused,
            segmentStartMs: segmentStart.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0)
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: slotsKey)
        }
        if notify {
            NotificationCenter.default.post(name: .knowdoTimerStateChanged, object: nil)
        }
    }

    // MARK: - Supabase timer_state 钩子（状态口径对齐安卓 SbTimerSync）

    /// 当前计时状态快照，供 TimerSync 推送到 user_state.timer_state。
    /// running 时 accumulated 恒为 0，started_at 为「虚拟起点」（本段起点往前推已累计秒数），
    /// 接收端用 started_at + duration 即得结束时刻。
    func currentTimerState() -> [String: Any] {
        var o: [String: Any] = [
            "task_id": "", "task_title": "", "phase": "idle",
            "started_at": Int64(0), "accumulated_seconds": 0, "duration_seconds": 0,
        ]
        if let r = running {
            let seg = segmentStart.map { Int64($0.timeIntervalSince1970 * 1000) } ?? nowMs()
            o["task_id"] = r.taskId
            o["task_title"] = SyncManager.shared.task(id: r.taskId)?.title ?? ""
            o["phase"] = "running"
            o["started_at"] = seg - Int64(r.accumulatedSeconds) * 1000
            o["duration_seconds"] = r.plannedSeconds
        } else if let p = paused {
            o["task_id"] = p.taskId
            o["task_title"] = SyncManager.shared.task(id: p.taskId)?.title ?? ""
            o["phase"] = "paused"
            o["accumulated_seconds"] = p.accumulatedSeconds
            o["duration_seconds"] = p.plannedSeconds
            // 暂停目的三件套（安卓 v1.11.0 口径，老端忽略未知字段）
            if let r = p.pauseReason { o["pause_reason"] = r }
            if let e = p.pauseEmoji, !e.isEmpty { o["pause_emoji"] = e }
            if p.pauseSilent == true { o["pause_silent"] = true }
        }
        o["updated_by"] = myDeviceId()
        o["updated_at"] = nowMs()
        return o
    }

    private let lastRemoteAppliedKey = "timerSync.lastRemoteApplied"

    /// 应用一份远端 timer_state（Realtime 推送或对账拉取都走这里）。返回 true 表示本机镜像确实变了。
    /// 防回声：updated_by 是本机，或 updated_at 不比「上次已应用的远端状态」更新，一律忽略。
    @discardableResult
    func applyRemoteTimerState(_ st: RemoteTimerState) -> Bool {
        if st.updatedBy == myDeviceId() { return false }
        let last = (UserDefaults.standard.object(forKey: lastRemoteAppliedKey) as? NSNumber)?.int64Value ?? 0
        if st.updatedAt <= last { return false }
        UserDefaults.standard.set(NSNumber(value: st.updatedAt), forKey: lastRemoteAppliedKey)

        let previousTaskId = currentSlot?.taskId
        var changed = false

        switch st.phase {
        case "running" where st.duration > 0:
            let nowSec = nowMs() / 1000
            let elapsed = max(0, Int(nowSec - st.startedAt / 1000)) + st.accumulated
            let lateSec = elapsed - st.duration
            if lateSec > 600 {
                // 远端早就过了结束点（那台设备关了/没处理），别在这里突然响铃：落成「到时的暂停」
                changed = mirrorPaused(st, accumulated: st.duration)
            } else {
                let el = min(elapsed, st.duration)
                if let r = running, r.taskId == st.taskId, r.plannedSeconds == st.duration,
                   abs(liveElapsed(of: r) - el) < 2 {
                    break   // 已经是同一个倒计时
                }
                if running != nil { SessionStore.shared.close() }
                if paused?.taskId == st.taskId { paused = nil }
                running = TimerSlot(taskId: st.taskId, plannedSeconds: st.duration,
                                    accumulatedSeconds: el, halfFired: el * 2 >= st.duration)
                segmentStart = Date()
                changed = true
            }
        case "paused" where st.duration > 0:
            changed = mirrorPaused(st, accumulated: st.accumulated)
        default:    // idle
            if running != nil || paused != nil {
                if running != nil { SessionStore.shared.close() }
                running = nil
                paused = nil
                segmentStart = nil
                changed = true
            }
        }

        if changed {
            refreshNumbers()
            persist(notify: false)
            // 另一端已处理过半/结束页（继续、加时、完成……）：本机还开着的全屏页跟着消停
            if OverlayManager.shared.isShowing, st.phase == "idle" || previousTaskId == st.taskId {
                OverlayManager.shared.dismiss()
            }
        }
        return changed
    }

    private func mirrorPaused(_ st: RemoteTimerState, accumulated: Int) -> Bool {
        if running == nil, let p = paused, p.taskId == st.taskId,
           p.plannedSeconds == st.duration, abs(p.accumulatedSeconds - accumulated) < 2,
           p.pauseReason == st.pauseReason, (p.pauseSilent ?? false) == st.pauseSilent {
            return false
        }
        if running != nil { SessionStore.shared.close() }
        running = nil
        segmentStart = nil
        var slot = TimerSlot(taskId: st.taskId, plannedSeconds: st.duration,
                             accumulatedSeconds: accumulated, halfFired: accumulated * 2 >= st.duration)
        slot.pauseReason = st.pauseReason
        slot.pauseEmoji = st.pauseEmoji
        slot.pauseSilent = st.pauseSilent ? true : nil
        slot.remote = true      // 叫回由发起暂停的那台设备负责，本机只显示
        paused = slot
        return true
    }

    /// App 正常退出时调用（AppDelegate.applicationWillTerminate）：
    /// 把计时中的任务落成暂停态，并关闭当前计时段。
    func prepareForTermination() {
        if var r = running {
            r.accumulatedSeconds = liveElapsed(of: r)
            SessionStore.shared.close()
            if paused == nil { paused = r }
            running = nil
            segmentStart = nil
        }
        persist()
    }

    private func restoreSlots() {
        guard let data = UserDefaults.standard.data(forKey: slotsKey),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        paused = p.paused
        if var q = paused, q.pauseSilent != true, q.resumeAtMs != nil {
            q.resumeFired = false       // 重启前没处理完的叫回页，到点（或已过点）再弹一次
            paused = q
        }
        if var r = p.running {
            // 退出期间不计时：流逝时间计入 accumulated（封顶到计划时长），恢复为暂停
            if p.segmentStartMs > 0 {
                let el = Int((nowMs() - p.segmentStartMs) / 1000)
                r.accumulatedSeconds = min(r.plannedSeconds, r.accumulatedSeconds + max(0, el))
            }
            if paused == nil { paused = r }
            running = nil
        }
        // 崩溃残留的未关闭计时段：按该任务计划时长封顶补关，避免把关机时长算成实际投入
        if let openId = SessionStore.shared.openTaskId {
            let start = SessionStore.shared.openStartMs
            let planned = (paused?.taskId == openId ? paused?.plannedSeconds : nil)
                ?? (SyncManager.shared.task(id: openId)?.durationMinutes ?? 0) * 60
            let capEnd = planned > 0 ? start + Int64(planned) * 1000 : start
            SessionStore.shared.close(atMs: min(nowMs(), capEnd))
        }
    }
}
