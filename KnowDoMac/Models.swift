import Foundation

/// 任务模型，字段与 Drive 桥 tasks.json（schema v1）完全对齐，逐项对应安卓 TaskItem。
/// 桥里出现的不认识的字段会收进 extras，写回时原样带出，绝不丢字段。
struct TaskItem: Identifiable, Equatable {
    var id: String = UUID().uuidString
    var title: String = ""
    var scenarios: [String] = []
    var deadline: String? = nil        // YYYY-MM-DD
    var deadlineTime: String? = nil    // HH:mm（当天几点前做完）
    var nextStartAt: String? = nil     // YYYY-MM-DDTHH:mm（下一次开始时间，到点全屏提醒）
    var repeatMode: String = "none"    // 桥字段 repeat：none / daily
    var durationMinutes: Int = 30
    var actualMinutes: Int = 0         // 手动记录的实际用时（分钟），0 = 未填
    var priority: String? = nil        // must / secondary / null
    var status: String = "todo"        // todo / done（daily 任务用 doneDates 记每日完成）
    var autoStart: Bool = false        // 桥端置 true：App 发现后自动开始计时，随即回写 false
    var note: String = ""
    // ---- 专注守卫（v0.1 只同步与编辑，不执行拦截）----
    var focusRule: String = ""
    var focusMode: String = "off"      // off / block / allow
    var blockedApps: [String] = []
    var allowedApps: [String] = []
    var primaryApp: String? = nil      // 主软件包名（Mac 上填 bundle id）
    var doneDates: [String] = []
    var deleted: Bool = false
    var createdAtMs: Int64 = 0
    var updatedAtMs: Int64 = 0
    var createdAtISO: String = ""      // 桥字段 createdAt（与 createdAtMs 双写，与安卓一致）
    var updatedAtISO: String = ""      // 桥字段 updatedAt
    /// 桥里不认识的字段，原样保留
    var extras: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = [
        "id", "title", "scenarios", "deadline", "deadlineTime", "nextStartAt",
        "repeat", "durationMinutes", "actualMinutes", "priority", "status",
        "autoStart", "note", "focusRule", "focusMode", "blockedApps",
        "allowedApps", "primaryApp", "doneDates", "deleted",
        "createdAt", "updatedAt", "createdAtMs", "updatedAtMs",
    ]

    static func createNew(title: String = "") -> TaskItem {
        var t = TaskItem()
        t.id = UUID().uuidString
        let now = nowMs()
        t.createdAtMs = now
        t.updatedAtMs = now
        t.createdAtISO = isoString(ms: now)
        t.updatedAtISO = t.createdAtISO
        t.title = title
        return t
    }

    mutating func touch() {
        updatedAtMs = nowMs()
        updatedAtISO = isoString(ms: updatedAtMs)
    }

    var isDaily: Bool { repeatMode == "daily" }

    func isDoneToday() -> Bool {
        if isDaily { return doneDates.contains(todayString()) }
        return status == "done"
    }

    mutating func markDone() {
        if isDaily {
            let d = todayString()
            if !doneDates.contains(d) { doneDates.append(d) }
        } else {
            status = "done"
        }
        touch()
    }

    mutating func markUndone() {
        if isDaily {
            doneDates.removeAll { $0 == todayString() }
        } else {
            status = "todo"
        }
        touch()
    }

    /// 是否算「今天的任务」（口径与安卓日历页 isTodayTask 一致）。
    var isTodayTask: Bool {
        if deleted { return false }
        if isDaily { return true }
        guard let d = deadline, !d.isEmpty else { return true }
        return d <= todayString()
    }

    func nextStartDate() -> Date? {
        guard let s = nextStartAt, !s.isEmpty else { return nil }
        return nextStartFormatter.date(from: s)
    }
}

// MARK: - 与桥 JSON 互转（经 JSONValue 手工组装，保证未知字段与 null 的写法与安卓一致）

extension TaskItem {
    init(jsonObject o: [String: JSONValue]) {
        func str(_ key: String, _ def: String = "") -> String {
            o[key]?.stringValue ?? def
        }
        func optStr(_ key: String) -> String? {
            guard let v = o[key], case .string(let s) = v, !s.isEmpty else { return nil }
            return s
        }
        func intVal(_ key: String, _ def: Int) -> Int {
            o[key]?.intValue ?? def
        }
        func int64Val(_ key: String) -> Int64 {
            if let v = o[key], case .number(let n) = v { return Int64(n) }
            return 0
        }
        func strArray(_ key: String) -> [String] {
            o[key]?.arrayValue?.compactMap { $0.stringValue } ?? []
        }

        id = str("id", UUID().uuidString)
        title = str("title")
        scenarios = strArray("scenarios")
        deadline = optStr("deadline")
        deadlineTime = optStr("deadlineTime")
        nextStartAt = optStr("nextStartAt")
        repeatMode = str("repeat", "none")
        durationMinutes = intVal("durationMinutes", 30)
        actualMinutes = intVal("actualMinutes", 0)
        priority = optStr("priority")
        status = str("status", "todo")
        autoStart = o["autoStart"]?.boolValue ?? false
        note = str("note")
        focusRule = str("focusRule")
        focusMode = str("focusMode", "off")
        blockedApps = strArray("blockedApps")
        allowedApps = strArray("allowedApps")
        primaryApp = optStr("primaryApp")
        doneDates = strArray("doneDates")
        deleted = o["deleted"]?.boolValue ?? false
        createdAtMs = int64Val("createdAtMs")
        updatedAtMs = int64Val("updatedAtMs")
        createdAtISO = str("createdAt")
        updatedAtISO = str("updatedAt")
        // 兼容只有 ISO 时间、没有毫秒字段的文件（与安卓 fromJson 同口径）
        if updatedAtMs == 0 { updatedAtMs = parseISOToMs(updatedAtISO) }
        if createdAtMs == 0 { createdAtMs = parseISOToMs(createdAtISO) }
        extras = o.filter { !TaskItem.knownKeys.contains($0.key) }
    }

    var jsonObject: [String: JSONValue] {
        var o = extras
        o["id"] = .string(id)
        o["title"] = .string(title)
        o["scenarios"] = .array(scenarios.map { .string($0) })
        o["deadline"] = deadline.map { .string($0) } ?? .null
        o["deadlineTime"] = deadlineTime.map { .string($0) } ?? .null
        o["nextStartAt"] = nextStartAt.map { .string($0) } ?? .null
        o["repeat"] = .string(repeatMode)
        o["durationMinutes"] = .number(Double(durationMinutes))
        o["actualMinutes"] = .number(Double(actualMinutes))
        o["priority"] = priority.map { .string($0) } ?? .null
        o["status"] = .string(status)
        o["autoStart"] = .bool(autoStart)
        o["note"] = .string(note)
        o["focusRule"] = .string(focusRule)
        o["focusMode"] = .string(focusMode)
        o["blockedApps"] = .array(blockedApps.map { .string($0) })
        o["allowedApps"] = .array(allowedApps.map { .string($0) })
        o["primaryApp"] = primaryApp.map { .string($0) } ?? .null
        o["doneDates"] = .array(doneDates.map { .string($0) })
        o["deleted"] = .bool(deleted)
        o["createdAtMs"] = .number(Double(createdAtMs))
        o["updatedAtMs"] = .number(Double(updatedAtMs))
        o["createdAt"] = .string(createdAtISO.isEmpty && createdAtMs > 0 ? isoString(ms: createdAtMs) : createdAtISO)
        o["updatedAt"] = .string(updatedAtISO.isEmpty && updatedAtMs > 0 ? isoString(ms: updatedAtMs) : updatedAtISO)
        return o
    }
}

extension TaskItem: Codable {
    init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case .object(let o) = value else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "TaskItem must be a JSON object"))
        }
        self.init(jsonObject: o)
    }

    func encode(to encoder: Encoder) throws {
        try JSONValue.object(jsonObject).encode(to: encoder)
    }
}

// MARK: - 桥文件

/// 桥文件整体：tasks 单独解析；其余顶层字段（app / schemaVersion / guardEvents /
/// schedule 等）全部收进 meta，写回时原样带出——schedule 只读、guardEvents 只保留不删。
struct BridgeFile {
    var tasks: [TaskItem] = []
    var meta: [String: JSONValue] = [:]

    var scheduleRaw: JSONValue? { meta["schedule"] }

    static func decode(_ data: Data) throws -> BridgeFile {
        let root = try JSONValue.parse(data)
        guard case .object(var o) = root else {
            throw NSError(domain: "KnowDoMac", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "桥文件顶层不是 JSON 对象"])
        }
        var file = BridgeFile()
        if let arr = o["tasks"]?.arrayValue {
            file.tasks = arr.compactMap { v -> TaskItem? in
                guard case .object(let to) = v else { return nil }
                return TaskItem(jsonObject: to)
            }
        }
        o.removeValue(forKey: "tasks")
        file.meta = o
        return file
    }

    /// 组装要写回的完整桥 JSON：meta 原样保留，只替换 tasks / updatedAt / updatedBy。
    func encodeForWrite(tasks newTasks: [TaskItem]) throws -> Data {
        var root = meta
        if root["app"] == nil { root["app"] = .string("KnowDo") }
        if root["schemaVersion"] == nil { root["schemaVersion"] = .number(1) }
        if root["guardEvents"] == nil { root["guardEvents"] = .array([]) }
        root["tasks"] = .array(newTasks.map { .object($0.jsonObject) })
        root["updatedAt"] = .string(isoString(ms: nowMs()))
        root["updatedBy"] = .string("knowdo-mac")
        return try JSONValue.object(root).jsonData(pretty: true)
    }
}

/// 日程里的一块（来自桥 schedule.blocks，只读展示用）
struct PlanBlock {
    var taskId: String
    var startMin: Int
    var endMin: Int
}

/// 解析桥 schedule；date 不是指定日期或结构缺失返回 nil（与安卓 planBlocks 口径一致，
/// 另在调用处过滤已删除任务、补标题与完成状态）。
func parseSchedule(_ raw: JSONValue?, date: String) -> [PlanBlock]? {
    guard let raw = raw, case .object(let o) = raw else { return nil }
    guard o["date"]?.stringValue == date else { return nil }
    guard let arr = o["blocks"]?.arrayValue else { return nil }
    var out: [PlanBlock] = []
    for item in arr {
        guard case .object(let b) = item,
              let tid = b["taskId"]?.stringValue,
              let s = parseHHMM(b["start"]?.stringValue ?? ""),
              let e = parseHHMM(b["end"]?.stringValue ?? ""),
              e > s
        else { continue }
        out.append(PlanBlock(taskId: tid, startMin: s, endMin: e))
    }
    out.sort { $0.startMin != $1.startMin ? $0.startMin < $1.startMin : $0.endMin < $1.endMin }
    return out
}
