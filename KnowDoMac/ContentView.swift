import SwiftUI

/// 主窗口：任务表（列与安卓一致）+ 顶部动作（新任务 / 日历 / 设置）+ 底部同步状态。
struct ContentView: View {
    @ObservedObject private var sync = SyncManager.shared
    @ObservedObject private var timer = TimerEngine.shared
    @Environment(\.openWindow) private var openWindow
    @State private var editing: TaskItem? = nil
    @State private var showSettings: Bool = false

    private var visibleTasks: [TaskItem] { sync.tasks.filter { !$0.deleted } }
    /// 未完成在前（桥内顺序），今日已完成的灰显排后（与安卓主列表口径一致）
    private var orderedTasks: [TaskItem] {
        visibleTasks.filter { !$0.isDoneToday() } + visibleTasks.filter { $0.isDoneToday() }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if sync.bridgeURL == nil {
                chooseBridgePrompt
            } else if orderedTasks.isEmpty {
                emptyState
            } else {
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

    private var chooseBridgePrompt: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("先选一下桥文件")
                .font(.system(size: 18, weight: .semibold))
            Text("知行靠 Google Drive 里同一个 tasks.json 和手机版同步数据。\n请选择那个文件（需在已同步到本机的 Drive 文件夹里）。")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("选择桥文件 tasks.json…") { sync.chooseBridgeFile() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("暂无任务")
                .font(.system(size: 16, weight: .semibold))
            Text("点右上角「＋ 新任务」添加，或在手机上添加——会通过桥文件自动同步过来。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Text(sync.bridgeName)
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

    private var rowRemaining: Int? {
        guard let slot = timer.slot(for: task.id) else { return nil }
        if timer.isRunning(task.id) { return timer.remainingSeconds }
        return max(0, slot.plannedSeconds - slot.accumulatedSeconds)
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: doneBinding)
                .toggleStyle(.checkbox)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .strikethrough(task.isDoneToday())
                    .foregroundColor(task.isDoneToday() ? .secondary : .primary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if !task.scenarios.isEmpty {
                        Text(task.scenarios.joined(separator: "、"))
                    }
                    if let dl = deadlineLabel {
                        Text(dl)
                    }
                    if let ns = nextStartLabel {
                        Text(ns).foregroundColor(.green)
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if task.focusMode != "off" {
                Text("专注")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.18)))
                    .foregroundColor(.orange)
            }

            if let remain = rowRemaining {
                Text(clockText(remain))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            } else {
                HStack(spacing: 4) {
                    Text("\(task.durationMinutes) 分钟")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    if task.actualMinutes > 0 {
                        Text("实\(task.actualMinutes)分")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }

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
