import Foundation
import SwiftUI

// MARK: - 空档催促设置（云端 user_state.idle_nag，双端共用同一份）

/// 强度档位（行为分档）：
/// gentle 不催；standard 催但有上限且不出声；strict 按间隔不停催（默认，可选出声）；custom 重复策略与数字自调。
struct IdleNagSettings: Equatable {
    var enabled = true
    var profile = "strict"
    var idleMinutes = 5          // 空档持续几分钟起催
    var ringSeconds = 60         // 每轮响多久
    var secondGapMinutes = 1     // first_repeat_minutes：第一轮结束后隔多久来第二轮
    var laterGapMinutes = 5      // repeat_minutes：之后每轮间隔
    var sound = true
    var maxRounds = 3            // standard / custom 的轮数上限：-1＝无限、0＝不催（strict 恒无限，不看存值）

    /// 实际生效的行为（由档位推出）。
    var nagActive: Bool { enabled && profile != "gentle" }
    var effectiveSound: Bool { profile == "strict" || profile == "custom" ? sound : false }
    /// 对齐安卓 effectiveMaxRounds：gentle→0（不催）、strict→无限、standard/custom→存值（-1 无限、0 不催）。
    var effectiveMaxRounds: Int? {       // nil＝不限
        switch profile {
        case "gentle": return 0
        case "standard", "custom": return maxRounds < 0 ? nil : maxRounds
        default: return nil
        }
    }

    /// 温和档连即时守卫页一起压（安卓 IdleNag.suppressIdlePage）。云端没读到时按默认 strict，不会误压。
    var suppressIdlePage: Bool { profile == "gentle" }

    init() {}

    init(json o: [String: JSONValue]) {
        if let v = o["enabled"]?.boolValue { enabled = v }
        if let v = o["profile"]?.stringValue, ["gentle", "standard", "strict", "custom"].contains(v) { profile = v }
        if let v = o["idle_minutes"]?.intValue, v > 0 { idleMinutes = v }
        if let v = o["ring_seconds"]?.intValue, v > 0 { ringSeconds = v }
        if let v = o["first_repeat_minutes"]?.intValue, v >= 0 { secondGapMinutes = v }
        if let v = o["repeat_minutes"]?.intValue, v > 0 { laterGapMinutes = v }
        if let v = o["sound"]?.boolValue { sound = v }
        if let v = o["max_rounds"]?.intValue, v >= -1 { maxRounds = v }
    }

    /// 写回时叠加到云端原对象上（不认识的键原样保留）。
    func apply(to o: inout [String: JSONValue]) {
        o["enabled"] = .bool(enabled)
        o["profile"] = .string(profile)
        o["idle_minutes"] = .number(Double(idleMinutes))
        o["ring_seconds"] = .number(Double(ringSeconds))
        o["first_repeat_minutes"] = .number(Double(secondGapMinutes))
        o["repeat_minutes"] = .number(Double(laterGapMinutes))
        o["sound"] = .bool(sound)
        o["max_rounds"] = .number(Double(maxRounds))
        // Mac 早期版本误写的旧键名，安卓不读，写回时顺手清掉
        o["second_gap_minutes"] = nil
        o["later_gap_minutes"] = nil
    }
}

/// 读写 user_state.idle_nag。云端没有这一列时 available=false：按默认值运行，设置页只读（不在本地另存一套）。
@MainActor
final class IdleNagStore: ObservableObject {
    static let shared = IdleNagStore()
    private init() {}

    @Published private(set) var settings = IdleNagSettings()
    @Published private(set) var available = false
    @Published private(set) var note = "登录后读取云端设置"
    @Published private(set) var saveError: String?
    private var raw: [String: JSONValue] = [:]
    /// 刚保存后的一小段时间内不用 Realtime/轮询触发的 load() 覆盖本地值（避免旧值盖回刚改的值）
    private var skipLoadUntil = Date.distantPast
    private var pendingSaves = 0

    func load() async {
        if pendingSaves > 0 || Date() < skipLoadUntil { return }
        guard SupabaseAuth.shared.isLoggedIn, let uid = SupabaseAuth.shared.userId else {
            available = false
            note = "登录后读取云端设置"
            return
        }
        do {
            let data = try await SupabaseHTTP.shared.restGet(
                path: "/rest/v1/user_state?user_id=eq.\(uid)&select=idle_nag")
            let arr = try JSONDecoder().decode([[String: JSONValue]].self, from: data)
            available = true
            note = ""
            if case .object(let o)? = arr.first?["idle_nag"] {
                raw = o
                settings = IdleNagSettings(json: o)
            }
        } catch {
            // 列不存在（云端还没建 idle_nag）或网络失败：保持当前值，设置页只读
            available = false
            note = "云端暂时读不到 idle_nag（列未建或离线），按默认档运行，设置暂不可改"
        }
    }

    func save(_ new: IdleNagSettings) {
        guard available, let uid = SupabaseAuth.shared.userId else { return }
        settings = new
        var o = raw
        new.apply(to: &o)
        raw = o
        pendingSaves += 1
        saveError = nil
        Task {
            let row: [String: JSONValue] = ["user_id": .string(uid), "idle_nag": .object(o)]
            do {
                let body = try JSONValue.array([.object(row)]).jsonData()
                _ = try await SupabaseHTTP.shared.restUpsert(
                    path: "/rest/v1/user_state?on_conflict=user_id", body: body)
            } catch {
                saveError = "保存到云端失败：\(error.localizedDescription)（稍后会重新读取云端值）"
            }
            pendingSaves -= 1
            skipLoadUntil = Date().addingTimeInterval(pendingSaves > 0 ? 0 : 4)
            if saveError != nil {
                skipLoadUntil = .distantPast
                await load()   // 写失败：以云端为准，不让界面显示一个没存上的值
            }
        }
    }
}

// MARK: - 催促执行

/// 空档持续满 N 分钟起，按轮弹「接下来干什么？」页＋渐强声音，直到有任务开始计时。
/// 轮次：第一轮 → 隔 second_gap → 第二轮 → 隔 later_gap → 之后每 later_gap 一轮。
@MainActor
final class IdleNagRunner {
    static let shared = IdleNagRunner()
    private init() {}

    private var timer: Timer?
    private var idleSince: Date?
    private var round = 0
    private var nextAt: Date?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func reset() {
        idleSince = nil; round = 0; nextAt = nil
    }

    private func tick() {
        let s = IdleNagStore.shared.settings
        guard s.nagActive, IdleGuard.shared.isIdle() else { reset(); return }
        let now = Date()
        if idleSince == nil {
            idleSince = now
            round = 0
            nextAt = now.addingTimeInterval(Double(s.idleMinutes) * 60)
        }
        guard let due = nextAt, now >= due else { return }
        if let cap = s.effectiveMaxRounds, round >= cap { nextAt = nil; return }
        // 别的全屏页（过半/结束/叫回）在显时让它先处理
        if OverlayManager.shared.isShowing && !OverlayManager.shared.isNextTaskShowing {
            nextAt = now.addingTimeInterval(10)
            return
        }
        round += 1
        if !OverlayManager.shared.isNextTaskShowing { OverlayManager.shared.showNextTask() }
        let ring = Double(s.ringSeconds)
        if s.effectiveSound { AlarmRing.shared.start(duration: ring) }
        let gap = Double(round == 1 ? s.secondGapMinutes : s.laterGapMinutes) * 60
        nextAt = now.addingTimeInterval(ring + gap)
    }
}

// MARK: - 设置页分区

struct IdleNagSection: View {
    @ObservedObject private var store = IdleNagStore.shared
    @ObservedObject private var auth = SupabaseAuth.shared

    private var s: IdleNagSettings { store.settings }
    private var editable: Bool { store.available && auth.isLoggedIn }

    private func edit(_ change: (inout IdleNagSettings) -> Void) {
        var n = store.settings
        change(&n)
        store.save(n)
    }

    var body: some View {
        Section("空档催促") {
            Toggle("空档时催我", isOn: Binding(get: { s.enabled }, set: { v in edit { $0.enabled = v } }))
                .disabled(!editable)
            Picker("强度", selection: Binding(get: { s.profile }, set: { v in edit { $0.profile = v } })) {
                Text("温和 · 不催").tag("gentle")
                Text("标准 · 有上限、不出声").tag("standard")
                Text("严格 · 不停催").tag("strict")
                Text("自定义").tag("custom")
            }
            .disabled(!editable || !s.enabled)
            if s.nagActive {
                Stepper("空档满 \(s.idleMinutes) 分钟起催",
                        value: Binding(get: { s.idleMinutes }, set: { v in edit { $0.idleMinutes = v } }), in: 1...120)
                    .disabled(!editable)
                Stepper("每轮持续 \(s.ringSeconds) 秒",
                        value: Binding(get: { s.ringSeconds }, set: { v in edit { $0.ringSeconds = v } }), in: 10...300, step: 10)
                    .disabled(!editable)
                Stepper("第一轮后隔 \(s.secondGapMinutes) 分钟再来",
                        value: Binding(get: { s.secondGapMinutes }, set: { v in edit { $0.secondGapMinutes = v } }), in: 0...60)
                    .disabled(!editable)
                Stepper("之后每隔 \(s.laterGapMinutes) 分钟一轮",
                        value: Binding(get: { s.laterGapMinutes }, set: { v in edit { $0.laterGapMinutes = v } }), in: 1...60)
                    .disabled(!editable)
                if s.profile == "standard" || s.profile == "custom" {
                    Stepper(s.maxRounds < 0 ? "轮数不限" : s.maxRounds == 0 ? "不催" : "最多催 \(s.maxRounds) 轮",
                            value: Binding(get: { s.maxRounds }, set: { v in edit { $0.maxRounds = v } }),
                            in: s.profile == "custom" ? -1...20 : 1...20)
                        .disabled(!editable)
                }
                if s.profile == "strict" || s.profile == "custom" {
                    Toggle("出声（渐强，操作即停；Mac 另受「允许 Mac 出声」总闸）", isOn: Binding(get: { s.sound }, set: { v in edit { $0.sound = v } }))
                        .disabled(!editable)
                }
            }
            if let e = store.saveError {
                Text(e).font(.system(size: 11)).foregroundColor(.red)
            }
            Text(store.note.isEmpty
                 ? "没有任务在计时、也不在带时长的暂停中，持续满设定时间，就全屏叫你并响铃，直到你开始一个任务。这份设置存在云端，和手机版共用。"
                 : store.note)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}
