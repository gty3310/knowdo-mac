import Foundation

// MARK: - Supabase 后端实现

final class SupabaseBackend: SyncBackend {
    // isConfigured/displayName 是同步属性；doSync() 在 @MainActor 上调用，assumeIsolated 安全。
    var isConfigured: Bool {
        MainActor.assumeIsolated { SupabaseAuth.shared.isLoggedIn }
    }
    var displayName: String {
        MainActor.assumeIsolated { SupabaseAuth.shared.userEmail ?? "Supabase" }
    }
    var sourceURL: URL? { nil }

    /// 服务端 tasks 表是否有 deadline_time / actual_minutes 两列（首次用到时探测，同安卓 hasExtraCols）。
    private var hasExtraCols: Bool?

    // MARK: - SyncBackend 协议

    func fetchLatest() async throws -> BackendData {
        let uid = await MainActor.run { SupabaseAuth.shared.userId }
        guard let uid else { throw AuthError.notLoggedIn }
        let local = await MainActor.run { SyncManager.shared.tasks }
        async let tasksFetch = fetchTasks(userId: uid, local: local)
        async let stateFetch = fetchUserState(userId: uid)
        let (tasks, meta) = try await (tasksFetch, stateFetch)
        return BackendData(tasks: tasks, meta: meta)
    }

    func write(_ data: BackendData) async throws {
        let uid = await MainActor.run { SupabaseAuth.shared.userId }
        guard let uid else { throw AuthError.notLoggedIn }
        let extra = await extraColsAvailable()
        let rows = data.tasks.map { SupabaseTaskRow(from: $0, userId: uid, withExtraCols: extra) }
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

    private func extraColsAvailable() async -> Bool {
        if let known = hasExtraCols { return known }
        let ok = (try? await SupabaseHTTP.shared.restGet(
            path: "/rest/v1/tasks?select=deadline_time,actual_minutes&limit=1")) != nil
        hasExtraCols = ok
        return ok
    }

    /// local：本地同 id 任务，行里没有的字段（无额外列时的 deadlineTime/actualMinutes，
    /// 以及桥里的未知 extras）从它保全，避免「远端较新」的整条覆盖把它们冲掉。
    private func fetchTasks(userId: String, local: [TaskItem]) async throws -> [TaskItem] {
        let data = try await SupabaseHTTP.shared.restGet(
            path: "/rest/v1/tasks?user_id=eq.\(userId)&select=*")
        let rows = try decode([SupabaseTaskRow].self, from: data)
        let byId = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return rows.map { $0.toTaskItem(preserveFrom: byId[$0.id]) }
    }

    private func fetchUserState(userId: String) async throws -> [String: JSONValue] {
        let data = try await SupabaseHTTP.shared.restGet(
            path: "/rest/v1/user_state?user_id=eq.\(userId)&select=schedule,guard_events")
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

// MARK: - 时间列互转（口径同安卓 SbMapper：本地时间字符串 ↔ 带时区 ISO）

enum SbTime {
    private static func fmt(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f
    }

    /// PostgREST 的 timestamptz 形如 2026-10-24T05:00:00.123456+00:00：小数位先截/补到 3 位再解析。
    static func parseIsoMs(_ raw: String) -> Int64 {
        var v = raw.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return 0 }
        if let dot = v.firstIndex(of: ".") {
            var end = v.index(after: dot)
            while end < v.endIndex, v[end].isNumber { end = v.index(after: end) }
            var frac = String(v[v.index(after: dot)..<end].prefix(3))
            while frac.count < 3 { frac += "0" }
            v = String(v[..<dot]) + "." + frac + String(v[end...])
        }
        for p in ["yyyy-MM-dd'T'HH:mm:ss.SSSXXX", "yyyy-MM-dd'T'HH:mm:ssXXX",
                  "yyyy-MM-dd HH:mm:ss.SSSXXX", "yyyy-MM-dd HH:mm:ssXXX"] {
            if let d = fmt(p).date(from: v) { return Int64(d.timeIntervalSince1970 * 1000) }
        }
        return 0
    }

    static func isoFromMs(_ ms: Int64) -> String {
        fmt("yyyy-MM-dd'T'HH:mm:ss.SSSXXX").string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// deadline "YYYY-MM-DD"（本地日期）→ 本地零点的 timestamptz
    static func dateToTs(_ date: String?) -> String? {
        guard let date = date, !date.isEmpty, let d = fmt("yyyy-MM-dd").date(from: date) else { return nil }
        return isoFromMs(Int64(d.timeIntervalSince1970 * 1000))
    }

    /// timestamptz → 本地日历日期（按本机时区取，不被 UTC 偏移带偏一天）
    static func tsToDate(_ ts: String?) -> String? {
        guard let ts = ts else { return nil }
        let ms = parseIsoMs(ts)
        return ms == 0 ? nil : fmt("yyyy-MM-dd").string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// nextStartAt "YYYY-MM-DDTHH:mm"（本地）→ timestamptz
    static func nextStartToTs(_ s: String?) -> String? {
        guard let s = s, !s.isEmpty, let d = fmt("yyyy-MM-dd'T'HH:mm").date(from: s) else { return nil }
        return isoFromMs(Int64(d.timeIntervalSince1970 * 1000))
    }

    /// timestamptz → "YYYY-MM-DDTHH:mm"（本地）
    static func tsToNextStart(_ ts: String?) -> String? {
        guard let ts = ts else { return nil }
        let ms = parseIsoMs(ts)
        return ms == 0 ? nil : fmt("yyyy-MM-dd'T'HH:mm").string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

// MARK: - Supabase tasks 表行（snake_case ↔ TaskItem camelCase）

struct SupabaseTaskRow: Codable {
    var id: String
    var user_id: String
    var title: String
    var note: String
    var scenarios: [String]
    var deadline: String?           // timestamptz（桥里是本地日期，经 SbTime 互转）
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
    var next_start_at: String?      // timestamptz（桥里是本地 YYYY-MM-DDTHH:mm）
    var created_at: String?
    var updated_at: String?         // 只读：写入时不带，交给服务端
    var deadline_time: String?      // 额外列，服务端没有时不带
    var actual_minutes: Int?
    private var withExtraCols = false

    private enum CodingKeys: String, CodingKey {
        case id, user_id, title, note, scenarios, deadline, `repeat`, duration_minutes, priority,
             status, auto_start, focus_rule, focus_mode, blocked_apps, allowed_apps, primary_app,
             done_dates, deleted, next_start_at, created_at, updated_at, deadline_time, actual_minutes
    }

    init(from item: TaskItem, userId: String, withExtraCols: Bool) {
        id = item.id
        user_id = userId
        title = item.title
        note = item.note
        scenarios = item.scenarios
        deadline = SbTime.dateToTs(item.deadline)
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
        next_start_at = SbTime.nextStartToTs(item.nextStartAt)
        created_at = item.createdAtMs > 0 ? SbTime.isoFromMs(item.createdAtMs) : nil
        updated_at = nil
        deadline_time = item.deadlineTime
        actual_minutes = item.actualMinutes
        self.withExtraCols = withExtraCols
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        user_id = try c.decodeIfPresent(String.self, forKey: .user_id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        scenarios = try c.decodeIfPresent([String].self, forKey: .scenarios) ?? []
        deadline = try c.decodeIfPresent(String.self, forKey: .deadline)
        `repeat` = try c.decodeIfPresent(String.self, forKey: .repeat) ?? "none"
        duration_minutes = try c.decodeIfPresent(Int.self, forKey: .duration_minutes) ?? 30
        priority = try c.decodeIfPresent(String.self, forKey: .priority)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "todo"
        auto_start = try c.decodeIfPresent(Bool.self, forKey: .auto_start) ?? false
        focus_rule = try c.decodeIfPresent(String.self, forKey: .focus_rule) ?? ""
        focus_mode = try c.decodeIfPresent(String.self, forKey: .focus_mode) ?? "off"
        blocked_apps = try c.decodeIfPresent([String].self, forKey: .blocked_apps) ?? []
        allowed_apps = try c.decodeIfPresent([String].self, forKey: .allowed_apps) ?? []
        primary_app = try c.decodeIfPresent(String.self, forKey: .primary_app)
        done_dates = try c.decodeIfPresent([String].self, forKey: .done_dates) ?? []
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        next_start_at = try c.decodeIfPresent(String.self, forKey: .next_start_at)
        created_at = try c.decodeIfPresent(String.self, forKey: .created_at)
        updated_at = try c.decodeIfPresent(String.self, forKey: .updated_at)
        deadline_time = try c.decodeIfPresent(String.self, forKey: .deadline_time)
        actual_minutes = try c.decodeIfPresent(Int.self, forKey: .actual_minutes)
        hasExtraKeys = c.contains(.deadline_time)
    }

    /// 解码时该行是否带了额外列（没带就从本地保全）
    private var hasExtraKeys = false

    /// 显式写出 null：upsert 要靠 null 把云端的 deadline / next_start_at 等清掉。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(user_id, forKey: .user_id)
        try c.encode(title, forKey: .title)
        try c.encode(note, forKey: .note)
        try c.encode(scenarios, forKey: .scenarios)
        try c.encode(deadline, forKey: .deadline)
        try c.encode(`repeat`, forKey: .repeat)
        try c.encode(duration_minutes, forKey: .duration_minutes)
        try c.encode(priority, forKey: .priority)
        try c.encode(status, forKey: .status)
        try c.encode(auto_start, forKey: .auto_start)
        try c.encode(focus_rule, forKey: .focus_rule)
        try c.encode(focus_mode, forKey: .focus_mode)
        try c.encode(blocked_apps, forKey: .blocked_apps)
        try c.encode(allowed_apps, forKey: .allowed_apps)
        try c.encode(primary_app, forKey: .primary_app)
        try c.encode(done_dates, forKey: .done_dates)
        try c.encode(deleted, forKey: .deleted)
        try c.encode(next_start_at, forKey: .next_start_at)
        if let created_at { try c.encode(created_at, forKey: .created_at) }
        if withExtraCols {
            try c.encode(deadline_time, forKey: .deadline_time)
            try c.encode(actual_minutes ?? 0, forKey: .actual_minutes)
        }
    }

    func toTaskItem(preserveFrom local: TaskItem?) -> TaskItem {
        var t = TaskItem()
        t.id = id
        t.title = title
        t.note = note
        t.scenarios = scenarios
        t.deadline = SbTime.tsToDate(deadline)
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
        t.nextStartAt = SbTime.tsToNextStart(next_start_at)
        t.createdAtMs = SbTime.parseIsoMs(created_at ?? "")
        t.updatedAtMs = SbTime.parseIsoMs(updated_at ?? "")
        t.createdAtISO = t.createdAtMs > 0 ? isoString(ms: t.createdAtMs) : ""
        t.updatedAtISO = t.updatedAtMs > 0 ? isoString(ms: t.updatedAtMs) : ""
        if hasExtraKeys {
            t.deadlineTime = deadline_time
            t.actualMinutes = actual_minutes ?? 0
        } else if let local {
            t.deadlineTime = local.deadlineTime
            t.actualMinutes = local.actualMinutes
        }
        // 桥里的未知字段云端放不下，沿用本地的，日后切回 Drive 写桥时不丢
        if let local { t.extras = local.extras }
        return t
    }
}
