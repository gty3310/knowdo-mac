import Foundation

// MARK: - 计时状态跨设备同步

/// 监听 TimerEngine 状态变化，把 timer_state 推送到 Supabase user_state 表；
/// 同时在收到 Realtime 通知时，拉取远端 timer_state 并应用到 TimerEngine。
/// 只在 SupabaseAuth.shared.isLoggedIn 时工作。
@MainActor
final class TimerSync {
    static let shared = TimerSync()
    private init() {}

    private var observer: NSObjectProtocol?
    private var lastPushedAt: Int64 = 0
    private let debounceMs: Int64 = 2000   // 2 秒防抖，避免快速操作刷爆接口

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: .knowdoTimerStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pushIfNeeded()
            }
        }
        SupabaseRealtime.shared.onRemoteChange = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.pullAndApply()
            }
        }
    }

    func stop() {
        if let obs = observer { NotificationCenter.default.removeObserver(obs) }
        observer = nil
    }

    // MARK: - 推送本地状态

    private func pushIfNeeded() async {
        guard SupabaseAuth.shared.isLoggedIn,
              let uid = SupabaseAuth.shared.userId else { return }
        let now = nowMs()
        guard now - lastPushedAt >= debounceMs else { return }
        lastPushedAt = now
        let state = TimerEngine.shared.currentTimerState()
        guard let body = try? JSONSerialization.data(withJSONObject: ["timer_state": state]) else { return }
        _ = try? await SupabaseHTTP.shared.restPatch(
            path: "/rest/v1/user_state?id=eq.\(uid)", body: body)
    }

    // MARK: - 拉取并应用远端状态

    func pullAndApply() async {
        guard SupabaseAuth.shared.isLoggedIn,
              let uid = SupabaseAuth.shared.userId else { return }
        guard let data = try? await SupabaseHTTP.shared.restGet(
            path: "/rest/v1/user_state?id=eq.\(uid)&select=timer_state") else { return }
        guard let arr = try? JSONDecoder().decode([[String: JSONValue]].self, from: data),
              let row = arr.first,
              let timerStateValue = row["timer_state"] else { return }
        // JSONValue → [String: Any] 转换
        guard case .object(let stateObj) = timerStateValue else { return }
        var dict: [String: Any] = [:]
        for (k, v) in stateObj {
            switch v {
            case .string(let s): dict[k] = s
            case .number(let n):
                // updated_at / started_at 是毫秒级大整数，需要 Int64
                dict[k] = Int64(n)
            case .bool(let b): dict[k] = b
            case .null: break
            default: break
            }
        }
        // accumulated_seconds / duration_seconds 是 Int
        if let acc = dict["accumulated_seconds"] as? Int64 { dict["accumulated_seconds"] = Int(acc) }
        if let dur = dict["duration_seconds"] as? Int64 { dict["duration_seconds"] = Int(dur) }
        TimerEngine.shared.applyRemoteTimerState(dict)
    }
}
