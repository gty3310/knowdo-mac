import Foundation

// MARK: - 日期 / 时间工具（格式与安卓端逐字对齐）

private func makeFormatter(_ pattern: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = pattern
    return f
}

/// 桥文件里 createdAt / updatedAt 的格式，如 2026-10-24T08:39:30+08:00
let isoFormatter = makeFormatter("yyyy-MM-dd'T'HH:mm:ssXXX")
/// YYYY-MM-DD
let dateFormatter = makeFormatter("yyyy-MM-dd")
/// HH:mm
let timeFormatter = makeFormatter("HH:mm")
/// nextStartAt 的格式：YYYY-MM-DDTHH:mm（本地时间）
let nextStartFormatter = makeFormatter("yyyy-MM-dd'T'HH:mm")

func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

func todayString() -> String {
    dateFormatter.string(from: Date())
}

func isoString(ms: Int64) -> String {
    isoFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
}

/// 解析 ISO 时间为毫秒（兼容安卓端写出的几种格式）；解析失败返回 0。
func parseISOToMs(_ s: String) -> Int64 {
    if s.isEmpty { return 0 }
    let patterns = [
        "yyyy-MM-dd'T'HH:mm:ssXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXX",
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
    ]
    for p in patterns {
        if let d = makeFormatter(p).date(from: s) {
            return Int64(d.timeIntervalSince1970 * 1000)
        }
    }
    if let d = ISO8601DateFormatter().date(from: s) {
        return Int64(d.timeIntervalSince1970 * 1000)
    }
    return 0
}

/// 秒 → "MM:SS"（满 1 小时显示 "H:MM:SS"），菜单栏 / 悬浮窗 / 列表共用。
func clockText(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600
    let m = (s % 3600) / 60
    let ss = s % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, ss) }
    return String(format: "%02d:%02d", m, ss)
}

/// 一天内的分钟数 → "HH:mm"
func hhmmText(_ minutes: Int) -> String {
    String(format: "%02d:%02d", minutes / 60, minutes % 60)
}

/// "HH:mm" → 一天内的分钟数；格式坏返回 nil。
func parseHHMM(_ s: String) -> Int? {
    let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
    guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
    return h * 60 + m
}

/// 某一天（YYYY-MM-DD，本地时区）零点的毫秒时间戳。
func dayStartMs(_ dateStr: String) -> Int64 {
    guard let d = dateFormatter.date(from: dateStr) else { return 0 }
    return Int64(Calendar.current.startOfDay(for: d).timeIntervalSince1970 * 1000)
}

/// 某时刻（毫秒）是一天中的第几分钟。
func minuteOfDay(ms: Int64) -> Int {
    let d = Date(timeIntervalSince1970: Double(ms) / 1000)
    let cal = Calendar.current
    return cal.component(.hour, from: d) * 60 + cal.component(.minute, from: d)
}

extension Notification.Name {
    /// 悬浮面板显隐变化（设置开关 / 面板上的收起按钮都会发这个通知）
    static let knowdoPanelVisibilityChanged = Notification.Name("knowdo.panelVisibilityChanged")
    /// 悬浮面板展开/收缩（hover 触发）；userInfo["expanded"]: Bool
    static let knowdoPanelExpansionChanged  = Notification.Name("knowdo.panelExpansionChanged")
    /// 计时状态变化（start/pause/reset/complete）；TimerSync 监听后推送到 Supabase
    static let knowdoTimerStateChanged      = Notification.Name("knowdo.timerStateChanged")
}

/// 设备唯一 ID，存 UserDefaults；跨设备同步 timer_state 时用于标识写入方。
func myDeviceId() -> String {
    let key = "knowdo.deviceId"
    if let id = UserDefaults.standard.string(forKey: key) { return id }
    let id = UUID().uuidString
    UserDefaults.standard.set(id, forKey: key)
    return id
}
