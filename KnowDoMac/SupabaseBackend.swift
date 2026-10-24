import Foundation

// MARK: - Supabase 后端实现

final class SupabaseBackend: SyncBackend {
    // isConfigured/displayName は同期プロパティ。doSync() は @MainActor で呼ばれるので assumeIsolated は安全。
    var isConfigured: Bool {
        MainActor.assumeIsolated { SupabaseAuth.shared.isLoggedIn }
    }
    var displayName: String {
        MainActor.assumeIsolated { SupabaseAuth.shared.userEmail ?? "Supabase" }
    }
    var sourceURL: URL? { nil }

    // MARK: - SyncBackend 协议

    func fetchLatest() async throws -> BackendData {
        let uid = await MainActor.run { SupabaseAuth.shared.userId }
        guard let uid else { throw AuthError.notLoggedIn }
        async let tasksFetch = fetchTasks(userId: uid)
        async let stateFetch = fetchUserState(userId: uid)
        let (tasks, meta) = try await (tasksFetch, stateFetch)
        return BackendData(tasks: tasks, meta: meta)
    }

    func write(_ data: BackendData) async throws {
        let uid = await MainActor.run { SupabaseAuth.shared.userId }
        guard let uid else { throw AuthError.notLoggedIn }
        let rows = data.tasks.map { SupabaseTaskRow(from: $0, userId: uid) }
        let body = try JSONEncoder().encode(rows)
        _ = try await SupabaseHTTP.shared.restUpsert(path: "/rest/v1/tasks", body: body)
    }

    func readBack() async throws -> BackendData {
        try await fetchLatest()
    }

    func configure(completion: @escaping (Bool) -> Void) {
        // 登录入口在 SettingsView；此处只回报当前状态
        completion(isConfigured)
    }

    // MARK: - 私有

    private func fetchTasks(userId: String) async throws -> [TaskItem] {
        let data = try await SupabaseHTTP.shared.restGet(
            path: "/rest/v1/tasks?user_id=eq.\(userId)&select=*")
        let rows = try decode([SupabaseTaskRow].self, from: data)
        return rows.map { $0.toTaskItem() }
    }

    private func fetchUserState(userId: String) async throws -> [String: JSONValue] {
        let data = try await SupabaseHTTP.shared.restGet(
            path: "/rest/v1/user_state?id=eq.\(userId)&select=schedule,guard_events")
        // PostgREST 返回数组
        guard let arr = try? JSONDecoder().decode([[String: JSONValue]].self, from: data),
              let row = arr.first else { return [:] }
        var meta: [String: JSONValue] = [:]
        if let sched = row["schedule"] { meta["schedule"] = sched }
        if let ge = row["guard_events"] { meta["guardEvents"] = ge }
        return meta
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SupabaseError.decodeFailed(error.localizedDescription)
        }
    }
}

// MARK: - Supabase tasks 表行（snake_case ↔ TaskItem camelCase）

struct SupabaseTaskRow: Codable {
    var id: String
    var user_id: String
    var title: String
    var note: String
    var scenarios: [String]
    var deadline: String?           // DATE nullable，只写 YYYY-MM-DD
    var `repeat`: String            // column name is "repeat"
    var duration_minutes: Int
    var priority: String?
    var status: String
    var auto_start: Bool
    var focus_rule: String
    var focus_mode: String
    var blocked_apps: [String]
    var allowed_apps: [String]
    var primary_app: String?
    var done_dates: [String]
    var deleted: Bool
    var next_start_at: String?
    var created_at: String          // timestamptz → ISO string
    var updated_at: String

    // Fields NOT in Supabase: deadlineTime, actualMinutes, extras

    init(from item: TaskItem, userId: String) {
        id = item.id
        user_id = userId
        title = item.title
        note = item.note
        scenarios = item.scenarios
        deadline = item.deadline
        `repeat` = item.repeatMode
        duration_minutes = item.durationMinutes
        priority = item.priority
        status = item.status
        auto_start = item.autoStart
        focus_rule = item.focusRule
        focus_mode = item.focusMode
        blocked_apps = item.blockedApps
        allowed_apps = item.allowedApps
        primary_app = item.primaryApp
        done_dates = item.doneDates
        deleted = item.deleted
        next_start_at = item.nextStartAt
        // 优先用 ISO 字段；如果为空则用毫秒换算
        created_at = item.createdAtISO.isEmpty && item.createdAtMs > 0
            ? isoString(ms: item.createdAtMs) : item.createdAtISO
        updated_at = item.updatedAtISO.isEmpty && item.updatedAtMs > 0
            ? isoString(ms: item.updatedAtMs) : item.updatedAtISO
    }

    func toTaskItem() -> TaskItem {
        var t = TaskItem()
        t.id = id
        t.title = title
        t.note = note
        t.scenarios = scenarios
        t.deadline = deadline
        t.repeatMode = `repeat`
        t.durationMinutes = duration_minutes
        t.priority = priority
        t.status = status
        t.autoStart = auto_start
        t.focusRule = focus_rule
        t.focusMode = focus_mode
        t.blockedApps = blocked_apps
        t.allowedApps = allowed_apps
        t.primaryApp = primary_app
        t.doneDates = done_dates
        t.deleted = deleted
        t.nextStartAt = next_start_at
        t.createdAtISO = created_at
        t.updatedAtISO = updated_at
        t.createdAtMs = parseISOToMs(created_at)
        t.updatedAtMs = parseISOToMs(updated_at)
        // actualMinutes, deadlineTime, extras 不在 Supabase，保持零值
        return t
    }
}
