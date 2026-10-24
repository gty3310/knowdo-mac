import Foundation

// MARK: - 计时状态跨设备同步

/// 监听 TimerEngine 状态变化，把 timer_state 推送到 Supabase user_state 表；
/// 收到 Realtime 通知 / 启动对账时，拉取远端 timer_state 并应用到 TimerEngine。
/// 只在 SupabaseAuth.shared.isLoggedIn 时工作。Realtime 回调由 SyncManager 统一分发。
@MainActor
final class TimerSync {
    static let shared = TimerSync()
    private init() {}

    private var observer: NSObjectProtocol?
    private var pushTask: Task<Void, Never>?
    private let coalesceNs: UInt64 = 400_000_000   // 合并一瞬间连发的多次变化，但绝不丢最后一次

    func start() {
        guard observer == nil else { return }       // 防重复注册
        observer = NotificationCenter.default.addObserver(
            forName: .knowdoTimerStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.schedulePush() }
        }
        // 启动/登录时先对账一次，拿到别的设备已在跑的计时
        Task { await pullAndApply() }
    }

    func stop() {
        if let obs = observer { NotificationCenter.default.removeObserver(obs) }
        observer = nil
        pushTask?.cancel()
        pushTask = nil
    }

    // MARK: - 推送本地状态

    /// 尾部合并：每次变化重置计时，安静 0.4 秒后推「当时最新」的状态。
    private func schedulePush() {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.coalesceNs)
            if Task.isCancelled { return }
            await self.push()
        }
    }

    private func push() async {
        guard SupabaseAuth.shared.isLoggedIn,
              let uid = SupabaseAuth.shared.userId else { return }
        let state = TimerEngine.shared.currentTimerState()
        // 带 user_id 的 upsert：行不存在时 PATCH 会静默无操作，且 merge-duplicates 只改 timer_state 这一列
        let row: [String: Any] = ["user_id": uid, "timer_state": state]
        guard let body = try? JSONSerialization.data(withJSONObject: [row]) else { return }
        _ = try? await SupabaseHTTP.shared.restUpsert(
            path: "/rest/v1/user_state?on_conflict=user_id", body: body)
    }

    // MARK: - 拉取并应用远端状态

    func pullAndApply() async {
        guard SupabaseAuth.shared.isLoggedIn,
              let uid = SupabaseAuth.shared.userId else { return }
        guard let data = try? await SupabaseHTTP.shared.restGet(
            path: "/rest/v1/user_state?user_id=eq.\(uid)&select=timer_state"),
              let arr = try? JSONDecoder().decode([[String: JSONValue]].self, from: data),
              let row = arr.first,
              case .object(let o)? = row["timer_state"] else { return }

        func int64(_ k: String) -> Int64 {
            if case .number(let n)? = o[k] { return Int64(n) }
            return 0
        }
        let st = RemoteTimerState(
            taskId: o["task_id"]?.stringValue ?? "",
            phase: o["phase"]?.stringValue ?? "idle",
            startedAt: int64("started_at"),
            accumulated: Int(int64("accumulated_seconds")),
            duration: Int(int64("duration_seconds")),
            updatedBy: o["updated_by"]?.stringValue ?? "",
            updatedAt: int64("updated_at"),
            pauseReason: o["pause_reason"]?.stringValue,
            pauseEmoji: o["pause_emoji"]?.stringValue,
            pauseSilent: { if case .bool(let b)? = o["pause_silent"] { return b }; return false }())
        TimerEngine.shared.applyRemoteTimerState(st)
    }
}
