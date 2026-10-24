import SwiftUI

/// 主窗口：任务表（列与安卓一致）+ 顶部动作（新任务 / 日历 / 设置）+ 底部同步状态。
struct ContentView: View {
    @ObservedObject private var sync = SyncManager.shared
    @ObservedObject private var auth = SupabaseAuth.shared
    @ObservedObject private var timer = TimerEngine.shared
    @Environment(\.openWindow) private var openWindow
    @State private var editing: TaskItem? = nil
    @State private var showSettings: Bool = false

    private var visibleTasks: [TaskItem] { sync.tasks.filter { !$0.deleted } }
    /// 与安卓 TaskStore.visibleSorted 同口径：未完成在前、必要在前、deadline 近在前
    /// （每日重复按今天算，没日期的排后），最后按创建时间。
    private var orderedTasks: [TaskItem] { visibleSorted(visibleTasks) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !auth.isLoggedIn {
                loginPrompt
            } else if orderedTasks.isEmpty {
                emptyState
            } else {
                TaskColumnHeader()
                Divider()
                List(orderedTasks) { task in
                    TaskRowView(task: task, onEdit: { editing = task })
                }
                .listStyle(.inset)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 680, minHeight: 440)
        .sheet(item: $editing) { task in
            TaskEditView(task: task)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("知行 KnowDo")
                    .font(.system(size: 17, weight: .bold))
                Text(todayString())
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("日历") { openWindow(id: "calendar") }
            Button("设置") { showSettings = true }
            Button("＋ 新任务") { editing = TaskItem.createNew() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var loginPrompt: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("先登录账号")
                .font(.system(size: 18, weight: .semibold))
            Text("知行通过云端账号和手机版同步任务。\n请点右上角设置，在「账号」里登录或注册。")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("暂无任务")
                .font(.system(size: 16, weight: .semibold))
            Text("点右上角「＋ 新任务」添加，或在手机上添加——会通过云端自动同步过来。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Text(sync.accountName)
                .font(.system(size: 11, weight: .medium))
            Text("· \(sync.lastStatus)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            if let ct = timer.currentTask {
                Text("● \(ct.title) · 剩 \(clockText(timer.remainingSeconds))")
                    .font(.system(size: 11))
                    .foregroundColor(.green)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

/// 任务表的一行：勾选框 / 标题+情景+截止+▶开始时间 / 专注标记 / 时长或剩余 / ▶⏸ / ⋯菜单。
/// 点行任意处打开编辑（行内按钮优先响应自己的点击）。
struct TaskRowView: View {
    let task: TaskItem
    var onEdit: () -> Void

    @ObservedObject private var sync = SyncManager.shared
    @ObservedObject private var timer = TimerEngine.shared
    @State private var copied: Bool = false

    private var doneBinding: Binding<Bool> {
        Binding(
            get: { task.isDoneToday() },
            set: { newValue in
                if newValue && timer.slot(for: task.id) != nil {
                    timer.completeTask(taskId: task.id)
                } else {
                    sync.mutate(id: task.id) { newValue ? $0.markDone() : $0.markUndone() }
                }
            })
    }

    private var deadlineLabel: String? {
        if task.repeatMode == "daily" { return "每日重复" }
        guard let d = task.deadline else { return nil }
        var s = "截止 \(d)"
        if let dt = task.deadlineTime { s += " \(dt) 前" }
        return s
    }

    private var nextStartLabel: String? {
        guard let ns = task.nextStartAt, ns.count >= 16 else { return nil }
        let datePart = String(ns.prefix(10))
        let timePart = String(ns.suffix(5))
        if datePart == todayString() { return "▶ \(timePart)" }
        return "▶ \(String(ns.dropFirst(5).prefix(5))) \(timePart)"
    }

    private func cell(_ text: String, _ width: CGFloat, color: Color, bold: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 12, weight: bold ? .bold : .regular))
            .monospacedDigit()
            .foregroundColor(color)
            .lineLimit(2)
            .frame(width: width, alignment: .leading)
    }

    private var rowRemaining: Int? {
        guard let slot = timer.slot(for: task.id) else { return nil }
        if timer.isRunning(task.id) { return timer.remainingSeconds }
        return max(0, slot.plannedSeconds - slot.accumulatedSeconds)
    }

    private var usedTodaySeconds: Int {
        var u = SessionStore.shared.closedSecondsToday(taskId: task.id)
        if SessionStore.shared.openTaskId == task.id, SessionStore.shared.openStartMs > 0 {
            u += max(0, Int((nowMs() - SessionStore.shared.openStartMs) / 1000))
        }
        return u
    }

    private var startText: String {
        guard let ns = task.nextStartAt, ns.count >= 16 else { return "—" }
        return String(ns.prefix(10)) == todayString() ? String(ns.suffix(5))
            : "\(String(ns.dropFirst(5).prefix(5))) \(String(ns.suffix(5)))"
    }

    private var leftText: String {
        if let remain = rowRemaining { return String(format: "%d:%02d", remain / 60, remain % 60) }
        if task.isDoneToday() { return "—" }
        return "\(max(0, task.durationMinutes - usedTodaySeconds / 60)) 分"
    }

    private var durText: String {
        let m = task.durationMinutes
        let d = m >= 60 ? "\(m / 60) 小时 \(m % 60) 分" : "\(m) 分"
        return task.actualMinutes > 0 ? d + "\n实\(task.actualMinutes)" : d
    }

    private var dlText: String {
        if task.isDaily { return "每日" }
        guard let d = task.deadline else { return "＋日期" }
        return String(d.dropFirst(5)) + (task.deadlineTime.map { "\n\($0)" } ?? "")
    }

    var body: some View {
        let done = task.isDoneToday()
        let active = timer.slot(for: task.id) != nil
        HStack(spacing: 0) {
            Toggle("", isOn: doneBinding)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: TaskColumns.check, alignment: .leading)

            Text((task.priority == "must" ? "★ " : "") + task.title + (timer.isPaused(task.id) ? "（已暂停）" : "") + (done ? " ✓" : ""))
                .font(.system(size: 13.5, weight: timer.isRunning(task.id) ? .bold : .medium))
                .strikethrough(done)
                .foregroundColor(done ? .secondary : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            cell(startText, TaskColumns.start, color: task.nextStartAt == nil ? .secondary : .green)
            cell(leftText, TaskColumns.left, color: active ? .accentColor : .primary, bold: timer.isRunning(task.id))
            cell(durText, TaskColumns.dur, color: .accentColor)
            cell(dlText, TaskColumns.dl, color: (task.deadline == nil && !task.isDaily) ? .secondary : .accentColor)
            cell(task.priority == "must" ? "必要" : (task.priority == "secondary" ? "次要" : "—"),
                 TaskColumns.pri, color: task.priority == "must" ? .red : .secondary)
            cell(task.scenarios.isEmpty ? "＋情景" : task.scenarios.joined(separator: "、"),
                 TaskColumns.sc, color: task.scenarios.isEmpty ? .secondary : .accentColor)

            Button {
                timer.toggle(taskId: task.id)
            } label: {
                Image(systemName: timer.isRunning(task.id) ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help(timer.isRunning(task.id) ? "暂停" : (timer.isPaused(task.id) ? "继续" : "开始计时"))

            Menu {
                Button("编辑") { onEdit() }
                Button(copied ? "已复制 ✓" : "复制信息") {
                    copyToPasteboard(buildTaskInfo(task))
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                }
                Button(task.isDoneToday() ? "取消完成" : "完成") {
                    doneBinding.wrappedValue = !task.isDoneToday()
                }
                if timer.slot(for: task.id) != nil {
                    Button("重置计时") { timer.reset(taskId: task.id) }
                }
                Divider()
                Button("删除", role: .destructive) {
                    sync.mutate(id: task.id) { $0.deleted = true }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 26)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
    }
}


/// 任务表列宽（列与安卓默认可见列一致：开始时间/剩余/时长/Deadline/优先/情景；「已用」安卓默认隐藏）。
enum TaskColumns {
    static let check: CGFloat = 26
    static let start: CGFloat = 78
    static let left: CGFloat = 60
    static let dur: CGFloat = 78
    static let dl: CGFloat = 64
    static let pri: CGFloat = 46
    static let sc: CGFloat = 96
    /// 行尾 ▶ 和 ⋯ 菜单占的宽度
    static let tail: CGFloat = 56
}

struct TaskColumnHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: TaskColumns.check)
            h("任务").frame(maxWidth: .infinity, alignment: .leading)
            h("开始时间").frame(width: TaskColumns.start, alignment: .leading)
            h("剩余").frame(width: TaskColumns.left, alignment: .leading)
            h("时长").frame(width: TaskColumns.dur, alignment: .leading)
            h("Deadline").frame(width: TaskColumns.dl, alignment: .leading)
            h("优先").frame(width: TaskColumns.pri, alignment: .leading)
            h("情景").frame(width: TaskColumns.sc, alignment: .leading)
            Spacer().frame(width: TaskColumns.tail)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 6)
    }

    private func h(_ t: String) -> some View {
        Text(t).font(.system(size: 11.5)).foregroundColor(.secondary)
    }
}
