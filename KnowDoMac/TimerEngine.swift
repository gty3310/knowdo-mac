import Foundation

/// 一个计时槽：plannedSeconds 是本轮计划总秒数，
/// accumulatedSeconds 是本轮已关闭的段累计（正在跑的那段不含，靠 segmentStart 现算）。
struct TimerSlot: Codable, Equatable {
    var taskId: String
    var plannedSeconds: Int
    var accumulatedSeconds: Int
    var halfFired: Bool
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
        running = p
        segmentStart = Date()
        let title = SyncManager.shared.task(id: p.taskId)?.title ?? ""
        SessionStore.shared.open(taskId: p.taskId, title: title)
        refreshNumbers()
        persist()
    }

    /// 行内 ▶/⏸ 与悬浮窗、菜单栏共用的开关。
    func toggle(taskId: String) {
        if running?.taskId == taskId {
            pause()
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
        if let task = SyncManager.shared.task(id: r.taskId), !OverlayManager.shared.isShowing {
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

    func persist() {
        let p = Persisted(
            running: running,
            paused: paused,
            segmentStartMs: segmentStart.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0)
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: slotsKey)
        }
        NotificationCenter.default.post(name: .knowdoTimerStateChanged, object: nil)
    }

    // MARK: - Supabase timer_state 钩子

    /// 当前计时状态快照，供 TimerSync 推送到 Supabase user_state.timer_state。
    func currentTimerState() -> [String: Any] {
        let phase: String
        let taskId: String
        let accumulated: Int
        let duration: Int
        var startedAt: Int64 = 0

        if let r = running {
            phase = "running"
            taskId = r.taskId
            accumulated = liveElapsed(of: r)
            duration = r.plannedSeconds
            startedAt = segmentStart.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        } else if let p = paused {
            phase = "paused"
            taskId = p.taskId
            accumulated = p.accumulatedSeconds
            duration = p.plannedSeconds
        } else {
            phase = "idle"
            taskId = ""
            accumulated = 0
            duration = 0
        }
        return [
            "task_id": taskId,
            "phase": phase,
            "started_at": startedAt,
            "accumulated_seconds": accumulated,
            "duration_seconds": duration,
            "updated_by": myDeviceId(),
            "updated_at": nowMs()
        ]
    }

    /// 收到远端 timer_state 后，如果比本地新且来自不同设备，则应用它。
    func applyRemoteTimerState(_ state: [String: Any]) {
        guard let remoteAt = state["updated_at"] as? Int64,
              let updatedBy = state["updated_by"] as? String,
              updatedBy != myDeviceId() else { return }
        // 本地有更新的状态则忽略远端
        let localAt = (currentTimerState()["updated_at"] as? Int64) ?? 0
        guard remoteAt > localAt else { return }

        guard let phase = state["phase"] as? String,
              let taskId = state["task_id"] as? String else { return }

        switch phase {
        case "running":
            let accumulated = state["accumulated_seconds"] as? Int ?? 0
            let duration = state["duration_seconds"] as? Int ?? 0
            let startedAt = state["started_at"] as? Int64 ?? 0
            // 不打断本机正在运行的计时；只在 idle 时接管
            if running == nil && paused == nil {
                let elapsed = startedAt > 0
                    ? Int((nowMs() - startedAt) / 1000) + accumulated
                    : accumulated
                let slot = TimerSlot(taskId: taskId,
                                     plannedSeconds: duration,
                                     accumulatedSeconds: elapsed,
                                     halfFired: false)
                paused = slot   // 恢复为暂停态（本机不自动 resume 别人的计时）
                persist()
            }
        case "paused":
            let accumulated = state["accumulated_seconds"] as? Int ?? 0
            let duration = state["duration_seconds"] as? Int ?? 0
            if running == nil && paused == nil {
                paused = TimerSlot(taskId: taskId,
                                   plannedSeconds: duration,
                                   accumulatedSeconds: accumulated,
                                   halfFired: false)
                persist()
            }
        case "idle":
            break
        default:
            break
        }
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
