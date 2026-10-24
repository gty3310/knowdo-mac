import Foundation

/// 一段已关闭的计时段（与安卓 SessionLog.Seg 同构）。
struct SessionSeg: Codable, Equatable, Identifiable {
    var taskId: String
    var title: String
    var startMs: Int64
    var endMs: Int64
    var id: String { "\(taskId)-\(startMs)" }
}

private struct OpenSeg: Codable {
    var taskId: String
    var title: String
    var startMs: Int64
}

/// 本地计时段记录：只存本机（Application Support/KnowDoMac/），不进桥文件。
/// 计时开始/继续时 open，暂停/停止时 close 成一段；供日历页画「实际块」、
/// 悬浮窗算「已用」。上限 500 段，与安卓一致。
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var segments: [SessionSeg] = []
    @Published private(set) var openTaskId: String? = nil
    @Published private(set) var openStartMs: Int64 = 0
    private var openTitle: String = ""

    private let maxSegs = 500
    private var dirURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("KnowDoMac", isDirectory: true)
    }
    private var segsURL: URL { dirURL.appendingPathComponent("sessions.json") }
    private var openURL: URL { dirURL.appendingPathComponent("open-session.json") }

    private init() {
        load()
    }

    // MARK: - 开 / 关段（语义与安卓 SessionLog 一致）

    /// 计时开始/继续时调用。若已有没关的段（异常路径），先以当前时刻关闭它。
    func open(taskId: String, title: String) {
        close()
        openTaskId = taskId
        openTitle = title
        openStartMs = nowMs()
        saveOpen()
    }

    /// 计时暂停/停止时调用：把打开的段关闭存档。没有打开的段就什么都不做。
    func close() {
        close(atMs: nowMs())
    }

    /// 以指定时刻关闭打开的段（崩溃恢复时用来给残留段封顶，避免把关机时长算成投入）。
    func close(atMs endMs: Int64) {
        guard let tid = openTaskId, openStartMs > 0 else { return }
        let seg = SessionSeg(taskId: tid, title: openTitle,
                             startMs: openStartMs, endMs: max(endMs, openStartMs))
        segments.append(seg)
        while segments.count > maxSegs { segments.removeFirst() }
        openTaskId = nil
        openTitle = ""
        openStartMs = 0
        saveSegments()
        saveOpen()
    }

    // MARK: - 查询

    /// 取与某一天（YYYY-MM-DD，本地时区）有重叠的已关闭段，
    /// 起止裁剪到当天范围内，按开始时间排序（与安卓 segmentsForDay 一致）。
    func segmentsForDay(_ date: String) -> [SessionSeg] {
        let dayStart = dayStartMs(date)
        let dayEnd = dayStart + 24 * 3600 * 1000
        var out: [SessionSeg] = []
        for s in segments {
            if s.endMs <= dayStart || s.startMs >= dayEnd { continue }
            var clipped = s
            clipped.startMs = max(s.startMs, dayStart)
            clipped.endMs = min(s.endMs, dayEnd)
            out.append(clipped)
        }
        out.sort { $0.startMs < $1.startMs }
        return out
    }

    /// 某任务今天已关闭段的累计秒数（正在进行的那段由调用方按 openStartMs 另加）。
    func closedSecondsToday(taskId: String) -> Int {
        let segs = segmentsForDay(todayString()).filter { $0.taskId == taskId }
        return segs.reduce(0) { $0 + Int(($1.endMs - $1.startMs) / 1000) }
    }

    // MARK: - 落盘

    private func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: segsURL),
           let list = try? JSONDecoder().decode([SessionSeg].self, from: data) {
            segments = list.filter { $0.startMs > 0 && $0.endMs >= $0.startMs }
        }
        if let data = try? Data(contentsOf: openURL),
           let open = try? JSONDecoder().decode(OpenSeg.self, from: data) {
            openTaskId = open.taskId
            openTitle = open.title
            openStartMs = open.startMs
        }
    }

    private func saveSegments() {
        if let data = try? JSONEncoder().encode(segments) {
            try? data.write(to: segsURL, options: [])
        }
    }

    private func saveOpen() {
        if let tid = openTaskId {
            let open = OpenSeg(taskId: tid, title: openTitle, startMs: openStartMs)
            if let data = try? JSONEncoder().encode(open) {
                try? data.write(to: openURL, options: [])
            }
        } else {
            try? FileManager.default.removeItem(at: openURL)
        }
    }
}
