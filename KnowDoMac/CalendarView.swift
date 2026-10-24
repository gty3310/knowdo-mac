import SwiftUI

/// 日历窗口：今日纵向时间轴。
/// 左列计划块（桥 schedule，只读）、右列实际块（本地 SessionLog 计时段，绿色）、
/// 当前时间红线、顶部概览、「问 AI」复制文案——口径全部与安卓日历页一致。
struct CalendarView: View {
    @ObservedObject private var sync = SyncManager.shared
    @ObservedObject private var sessions = SessionStore.shared
    @ObservedObject private var timer = TimerEngine.shared
    @State private var copied: Bool = false

    private let hourHeight: CGFloat = 46
    private let sleepMin = 22 * 60 + 30   // 22:30

    private struct PlanDisp {
        var block: PlanBlock
        var title: String
        var task: TaskItem?
        var done: Bool
        var running: Bool
    }

    private struct ActDisp {
        var taskId: String
        var title: String
        var startMin: Int
        var endMin: Int
        var running: Bool
    }

    // MARK: - 数据（口径对应安卓 CalendarActivity）

    private var todayTasks: [TaskItem] { sync.tasks.filter { $0.isTodayTask } }
    private var doneList: [TaskItem] { todayTasks.filter { $0.isDoneToday() } }
    private var todoList: [TaskItem] { todayTasks.filter { !$0.isDoneToday() } }

    private var planDisp: [PlanDisp]? {
        guard let blocks = parseSchedule(sync.scheduleRaw, date: todayString()) else { return nil }
        var out: [PlanDisp] = []
        for b in blocks {
            let t = sync.task(id: b.taskId)
            if let t = t, t.deleted { continue }
            out.append(PlanDisp(block: b,
                                title: t?.title ?? "（未知任务）",
                                task: t,
                                done: t?.isDoneToday() ?? false,
                                running: timer.isRunning(b.taskId)))
        }
        return out
    }

    private var actualDisp: [ActDisp] {
        let dayStart = dayStartMs(todayString())
        var out: [ActDisp] = []
        for seg in sessions.segmentsForDay(todayString()) {
            let t = sync.task(id: seg.taskId)
            let startMin = Int((seg.startMs - dayStart) / 60000)
            let endMin = max(startMin + 1, Int((seg.endMs - dayStart) / 60000))
            out.append(ActDisp(taskId: seg.taskId,
                               title: t?.title ?? (seg.title.isEmpty ? "（已删除的任务）" : seg.title),
                               startMin: startMin, endMin: endMin, running: false))
        }
        // 正在计时的那一段：从打开段的开始画到现在
        if let runningId = timer.running?.taskId,
           sessions.openTaskId == runningId, sessions.openStartMs > 0 {
            let startMin = minuteOfDay(ms: sessions.openStartMs)
            let endMin = max(startMin + 1, minuteOfDay(ms: nowMs()))
            out.append(ActDisp(taskId: runningId,
                               title: sync.task(id: runningId)?.title ?? "计时中",
                               startMin: startMin, endMin: endMin, running: true))
        }
        out.sort { $0.startMin != $1.startMin ? $0.startMin < $1.startMin : $0.endMin < $1.endMin }
        return out
    }

    /// 从现在到 22:30 之间、没被计划块占用的分钟数（合并重叠区间的算法与安卓一致）。
    private func freeMinutes(plan: [PlanDisp]?) -> Int {
        let nowMin = minuteOfDay(ms: nowMs())
        let from = max(nowMin, 0)
        let to = sleepMin
        guard let plan = plan, from < to else { return max(0, to - from) }
        var spans: [(Int, Int)] = []
        for b in plan {
            let s = max(b.block.startMin, from)
            let e = min(b.block.endMin, to)
            if e > s { spans.append((s, e)) }
        }
        spans.sort { $0.0 < $1.0 }
        var used = 0
        var curS = -1
        var curE = -1
        for sp in spans {
            if curS < 0 {
                curS = sp.0; curE = sp.1
            } else if sp.0 <= curE {
                curE = max(curE, sp.1)
            } else {
                used += curE - curS; curS = sp.0; curE = sp.1
            }
        }
        if curS >= 0 { used += curE - curS }
        return max(0, (to - from) - used)
    }

    private var unscheduled: [TaskItem] {
        let ids = Set((planDisp ?? []).map { $0.block.taskId })
        return todoList.filter { !ids.contains($0.id) }
    }

    private var startHour: Int {
        var m = 5 * 60
        for b in planDisp ?? [] { m = min(m, b.block.startMin) }
        for a in actualDisp { m = min(m, a.startMin) }
        return max(0, m / 60)
    }

    private var endHour: Int {
        var m = 23 * 60
        for b in planDisp ?? [] { m = max(m, b.block.endMin) }
        for a in actualDisp { m = max(m, a.endMin) }
        return min(24, max(23, (m + 59) / 60))
    }

    // MARK: - 界面

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            columnHeaders
            timeline
            if !unscheduled.isEmpty {
                Divider()
                unscheduledList
            }
        }
        .frame(minWidth: 540, minHeight: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text("今日日历 · \(todayString())")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button("同步") { sync.synchronize() }
                Button(copied ? "已复制 ✓" : "问 AI") {
                    copyToPasteboard(buildAskAiText())
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copied = false }
                }
                .buttonStyle(.borderedProminent)
                .help("把今日日程摘要复制到剪贴板，去 Muse 里粘贴即可让它重排")
            }
            Text("今日已完成 \(doneList.count) 件 · 未完成 \(todoList.count) 件 · 还可自由安排 \(freeMinutes(plan: planDisp)) 分钟（到 22:30）")
                .font(.system(size: 12.5))
            if !doneList.isEmpty {
                Text(doneList.map { $0.title }.joined(separator: "、"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            if planDisp == nil {
                Text("今天还没有排日程：在对话里告诉 Muse 你今天的任务，或点上方「问 AI」，Muse 排好后这里会自动显示。")
                    .font(.system(size: 11.5))
                    .foregroundColor(.red.opacity(0.85))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var columnHeaders: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 48)
            Text("计划")
                .frame(maxWidth: .infinity)
            Text("实际")
                .frame(maxWidth: .infinity)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private var timeline: some View {
        let totalHeight = CGFloat(endHour - startHour) * hourHeight
        let nowMin = minuteOfDay(ms: nowMs())
        return ScrollView {
            ZStack(alignment: .topLeading) {
                // 小时网格
                VStack(spacing: 0) {
                    ForEach(startHour..<endHour, id: \.self) { h in
                        HStack(alignment: .top, spacing: 8) {
                            Text(hhmmText(h * 60))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .frame(width: 40, alignment: .trailing)
                            Rectangle()
                                .fill(Color.secondary.opacity(0.16))
                                .frame(height: 1)
                        }
                        .frame(height: hourHeight, alignment: .top)
                    }
                }
                // 双列块
                HStack(alignment: .top, spacing: 8) {
                    Color.clear.frame(width: 48)
                    planColumn(totalHeight: totalHeight)
                    actualColumn(totalHeight: totalHeight)
                }
                // 当前时间红线
                if nowMin >= startHour * 60 && nowMin <= endHour * 60 {
                    HStack(spacing: 4) {
                        Color.clear.frame(width: 48)
                        Rectangle().fill(Color.red).frame(height: 1.5)
                        Text("现在 \(hhmmText(nowMin))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.red)
                    }
                    .offset(y: CGFloat(nowMin - startHour * 60) / 60 * hourHeight - 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func yPos(_ startMin: Int) -> CGFloat {
        CGFloat(startMin - startHour * 60) / 60 * hourHeight
    }

    private func blockHeight(_ startMin: Int, _ endMin: Int) -> CGFloat {
        max(17, CGFloat(endMin - startMin) / 60 * hourHeight - 2)
    }

    private func planColumn(totalHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array((planDisp ?? []).enumerated()), id: \.offset) { _, b in
                VStack(spacing: 0) {
                    Color.clear.frame(height: yPos(b.block.startMin))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.title + (b.running ? " ▶" : ""))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(2)
                        Text("\(hhmmText(b.block.startMin))–\(hhmmText(b.block.endMin))")
                            .font(.system(size: 9.5))
                            .opacity(0.75)
                    }
                    .foregroundColor(b.done ? .secondary : .primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: blockHeight(b.block.startMin, b.block.endMin), alignment: .top)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(b.done ? Color.gray.opacity(0.14) : Color.blue.opacity(0.16)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(b.running ? Color.green : Color.blue.opacity(0.55),
                                          lineWidth: b.running ? 1.6 : 1))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: totalHeight, alignment: .top)
    }

    private func actualColumn(totalHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(actualDisp.enumerated()), id: \.offset) { _, a in
                VStack(spacing: 0) {
                    Color.clear.frame(height: yPos(a.startMin))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.title + (a.running ? " ▶" : ""))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(2)
                        Text("\(hhmmText(a.startMin))–\(hhmmText(a.endMin))")
                            .font(.system(size: 9.5))
                            .opacity(0.8)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: blockHeight(a.startMin, a.endMin), alignment: .top)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.green.opacity(a.running ? 0.9 : 0.68)))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: totalHeight, alignment: .top)
    }

    private var unscheduledList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("未排入日程（\(unscheduled.count)）")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            ForEach(unscheduled) { t in
                HStack(spacing: 8) {
                    Text(t.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    if t.priority == "must" {
                        Text("必做")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.18)))
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    Text("\(t.durationMinutes) 分钟")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 问 AI 文案（与安卓 CalendarActivity.buildAskAiText 逐项一致）

    private func buildAskAiText() -> String {
        let today = todayString()
        let plan = planDisp
        let actual = actualDisp
        var sb = ""
        sb += "\(today)，现在 \(timeFormatter.string(from: Date()))\n"
        sb += "已完成（\(doneList.count)）：\(doneList.isEmpty ? "无" : doneList.map { $0.title }.joined(separator: "、"))\n"
        sb += "未完成（\(todoList.count)）：\(todoList.isEmpty ? "无" : todoList.map { $0.title }.joined(separator: "、"))\n"
        if let plan = plan {
            sb += "当前计划安排（桥文件 schedule）：\n"
            for b in plan {
                sb += "\(hhmmText(b.block.startMin))–\(hhmmText(b.block.endMin)) \(b.title)"
                sb += b.done ? "（已完成）" : (b.running ? "（正在计时）" : "（未完成）")
                if let t = b.task {
                    sb += "［id:\(t.id)］"
                }
                sb += "\n"
            }
        } else {
            sb += "当前计划安排：今天还没有排日程。\n"
        }
        let un = unscheduled.map { t in
            "\(t.title)（计划 \(t.durationMinutes) 分钟\(t.priority == "must" ? "，必做" : "")）［id:\(t.id)］"
        }
        sb += "未排入日程的任务：\(un.isEmpty ? "无" : un.joined(separator: "、"))\n"
        if !actual.isEmpty {
            let parts = actual.map { a in
                "\(hhmmText(a.startMin))–\(hhmmText(a.endMin)) \(a.title)\(a.running ? "（正在计时）" : "")"
            }
            sb += "今天实际计时记录：\(parts.joined(separator: "；"))\n"
        }
        sb += "我 22:30 睡觉；从现在到 22:30 还可自由安排 \(freeMinutes(plan: plan)) 分钟。\n"
        sb += "请按这个规则帮我更新今天剩下的安排，并写回桥文件 tasks.json 的顶层 schedule 字段：\n"
        sb += "1）必做任务（priority=must 或截止在今天）必须排入；次要任务按重要程度穿插进空档；\n"
        sb += "2）每件任务按计划时长 ×1.5 占时段（留 50% 缓冲）；\n"
        sb += "3）已经过去的时段和已完成任务的时段不要动，未完成的从现在往后排，不要排到 22:30 之后；排不下请直接告诉我。\n"
        sb += "schedule 格式：{\"date\":\"\(today)\",\"blocks\":[{\"taskId\":\"任务id\",\"start\":\"HH:mm\",\"end\":\"HH:mm\"}],\"updatedAtMs\":毫秒时间戳,\"updatedBy\":\"Muse\"}。\n"
        sb += "写好后我这边日历页会自动刷新显示新版。"
        return sb
    }
}
