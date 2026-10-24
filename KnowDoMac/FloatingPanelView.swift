import AppKit
import SwiftUI

/// 悬浮小窗内容（照统一设计语言：深色半透明圆角卡片）。
/// 布局：任务名 + 状态 / 左侧剩余时间大字、右侧小字「已用 / 共计划」 /
/// 按钮一排（开始暂停、完成、打开知行）/ 笔记快速编辑（右上角带复制按钮，停笔自动存）。
struct FloatingPanelView: View {
    @ObservedObject private var sync = SyncManager.shared
    @ObservedObject private var timer = TimerEngine.shared
    @ObservedObject private var sessions = SessionStore.shared

    @State private var noteDraft: String = ""
    @State private var saveWork: DispatchWorkItem? = nil
    @State private var copied: Bool = false
    @ObservedObject private var hover = PanelHoverState.shared

    private var task: TaskItem? { timer.topTask }

    var body: some View {
        let expanded = hover.expanded
        ZStack {
            RoundedRectangle(cornerRadius: expanded ? 18 : 15, style: .continuous)
                .fill(Color.black.opacity(expanded ? 0.45 : 0.80))
            RoundedRectangle(cornerRadius: expanded ? 18 : 15, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            if expanded {
                if let task = task {
                    content(for: task)
                } else {
                    emptyState
                }
            } else {
                compactBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 有任务时

    private func content(for task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题行
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(subtitle(for: task))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer()
                Button("✕") { collapse() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .help("收成小胶囊（鼠标再移上来会重新展开）")
            }

            if let bar = pauseBarText(for: task) {
                Text(bar)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(red: 1.0, green: 0.78, blue: 0.3))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.18)))
            }

            // 时间行：左剩余大字，右「已用 / 共计划」
            HStack(alignment: .bottom, spacing: 8) {
                Text(clockText(remaining(for: task)))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("已用 \(clockText(usedSeconds(for: task)))")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.75))
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 86, height: 1)
                    Text("共 \(clockText(task.durationMinutes * 60))")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.75))
                }
            }

            // 按钮行
            HStack(spacing: 8) {
                if timer.isPaused(task.id), timer.running == nil, timer.paused?.pauseReason != nil {
                    Button("继续") { timer.resumePaused() }
                    Button("+5 分钟") { timer.delayResume(minutes: 5) }
                    Button("换目的") { PauseCardController.shared.show(taskId: task.id) }
                    Button("完成") { complete(task) }
                } else {
                    Button(startPauseLabel(for: task)) { timer.toggle(taskId: task.id) }
                    Button("完成") { complete(task) }
                    Button("打开知行") { showMainWindow() }
                }
                Spacer()
            }
            .buttonStyle(PanelButtonStyle())

            // 笔记（右上角复制按钮；停笔自动同步）
            HStack(spacing: 6) {
                Text("笔记")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
                if copied {
                    Text("已复制 ✓")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }
                Button("复制") {
                    copyToPasteboard(buildTaskInfo(task))
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .help("复制这个任务的全部信息")
            }
            TextEditor(text: $noteDraft)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.08)))
                .frame(height: 58)
                .onChange(of: noteDraft) { _, _ in scheduleNoteSave(for: task) }
        }
        .padding(14)
        .onAppear { noteDraft = task.note }
        .onChange(of: task.id) { _, _ in noteDraft = task.note }
    }

    /// 默认形态：任务名 +「已用 / 共计划」，计时中左侧一个绿点。
    private var compactBar: some View {
        HStack(spacing: 6) {
            if let task = task {
                Circle()
                    .fill(timer.isRunning(task.id) ? Color.green : Color.white.opacity(0.35))
                    .frame(width: 6, height: 6)
                Text(compactTitle(for: task))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let tail = pauseCompactTail(for: task) {
                    Text(tail)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(Color(red: 1.0, green: 0.78, blue: 0.3))
                } else {
                Text(clockText(usedSeconds(for: task)))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)
                Text("/")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                Text(clockText(task.durationMinutes * 60))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.7))
                }
            } else {
                Text("暂无任务")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("暂无待办任务")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Text(!SupabaseAuth.shared.isLoggedIn ? "先在主窗口设置里登录账号" : "今天的任务都完成了，去主窗口加新的吧")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))
            Button("打开知行") { showMainWindow() }
                .buttonStyle(PanelButtonStyle())
        }
        .padding(14)
    }

    // MARK: - 计算与动作

    /// 暂停带目的时才有：暂停条文案「⏸ 暂停中 · 🚻上厕所 · 还剩 mm:ss」。
    private func pauseBarText(for task: TaskItem) -> String? {
        guard timer.running == nil, timer.isPaused(task.id), let p = timer.paused,
              let reason = p.pauseReason else { return nil }
        var s = "⏸ 暂停中 · \(p.pauseEmoji ?? "")\(reason)"
        if let r = timer.pauseRemainingSeconds() { s += " · 还剩 \(clockText(r))" }
        if p.pauseSilent == true { s += " · 🔕" }
        return s
    }

    /// 小胶囊第一行：暂停带目的时报「暂停『任务名』」，否则就是任务名。
    private func compactTitle(for task: TaskItem) -> String {
        if timer.running == nil, timer.isPaused(task.id), timer.paused?.pauseReason != nil {
            return "⏸ 暂停「\(task.title)」"
        }
        return task.title
    }

    /// 小胶囊右侧：暂停带目的时换成「目的 emoji＋目的名＋还剩」。
    private func pauseCompactTail(for task: TaskItem) -> String? {
        guard timer.running == nil, timer.isPaused(task.id), let p = timer.paused,
              let reason = p.pauseReason else { return nil }
        var s = "\(p.pauseEmoji ?? "")\(reason)"
        if let r = timer.pauseRemainingSeconds() { s += " \(clockText(r))" }
        return s
    }

    private func subtitle(for task: TaskItem) -> String {
        if timer.isRunning(task.id) { return "计时中" }
        if timer.isPaused(task.id) { return "已暂停" }
        if !task.scenarios.isEmpty { return task.scenarios.joined(separator: "、") }
        if task.repeatMode == "daily" { return "每日重复" }
        if let d = task.deadline { return "截止 \(d)" }
        return "待开始"
    }

    private func remaining(for task: TaskItem) -> Int {
        if timer.slot(for: task.id) != nil { return timer.remainingSeconds }
        return max(0, task.durationMinutes * 60)
    }

    /// 已用 = 今天全部计时段累计（SessionLog 口径，与安卓 v1.6.1 一致）：
    /// 已关闭段 + 正在进行的那段。
    private func usedSeconds(for task: TaskItem) -> Int {
        var s = sessions.closedSecondsToday(taskId: task.id)
        if sessions.openTaskId == task.id, sessions.openStartMs > 0 {
            s += max(0, Int((nowMs() - sessions.openStartMs) / 1000))
        }
        return s
    }

    private func startPauseLabel(for task: TaskItem) -> String {
        if timer.isRunning(task.id) { return "暂停" }
        if timer.isPaused(task.id) { return "继续" }
        return "开始"
    }

    private func complete(_ task: TaskItem) {
        if timer.slot(for: task.id) != nil {
            timer.completeTask(taskId: task.id)
        } else {
            sync.mutate(id: task.id) { $0.markDone() }
        }
    }

    private func scheduleNoteSave(for task: TaskItem) {
        saveWork?.cancel()
        let draft = noteDraft
        let work = DispatchWorkItem {
            if let current = SyncManager.shared.task(id: task.id), current.note != draft {
                SyncManager.shared.mutate(id: task.id) { $0.note = draft }
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// 只收回小胶囊，不隐藏悬浮窗（隐藏改动设置页的开关，免得点一下就找不回来）。
    private func collapse() {
        hover.expanded = false
    }

    private func showMainWindow() {
        (NSApp.delegate as? AppDelegate)?.showMainWindow()
    }
}

/// 面板上的小按钮：半透明白底圆角。
struct PanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.28 : 0.16)))
            .foregroundColor(.white)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
