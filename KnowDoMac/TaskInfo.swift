import AppKit
import Foundation

/// 把一个任务的全部信息整理成一段文字——字段、顺序、措辞与安卓
/// AiLaunchActivity.buildInfo 逐项一致，悬浮窗/编辑框的「复制」按钮共用。
func buildTaskInfo(_ t: TaskItem) -> String {
    var sb = "\n"
    sb += "任务：\(t.title)\n"
    if !t.scenarios.isEmpty {
        sb += "情景：\(t.scenarios.joined(separator: "、"))\n"
    }
    if t.repeatMode == "daily" {
        sb += "截止：每日重复\n"
    } else if let d = t.deadline {
        sb += "截止：\(d)"
        if let dt = t.deadlineTime { sb += " \(dt) 前" }
        sb += "\n"
    }
    sb += "计划时长：\(t.durationMinutes) 分钟\n"
    if t.actualMinutes > 0 {
        sb += "实际用时：\(t.actualMinutes) 分钟\n"
    }
    sb += "优先级：\(t.priority == "must" ? "必要" : "次要")\n"
    if !t.focusRule.isEmpty {
        sb += "专注规则：\(t.focusRule)\n"
    }
    let timer = TimerEngine.shared
    if timer.isRunning(t.id) {
        let r = timer.remainingSeconds
        sb += "状态：正在计时，剩余 \(r / 60) 分 \(r % 60) 秒\n"
    } else if timer.isPaused(t.id), let slot = timer.slot(for: t.id) {
        let r = max(0, slot.plannedSeconds - slot.accumulatedSeconds)
        sb += "状态：已暂停，剩余 \(r / 60) 分 \(r % 60) 秒\n"
    } else {
        sb += "状态：未开始\n"
    }
    sb += "今日：\(t.isDoneToday() ? "已完成" : "未完成")\n"
    if !t.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        sb += "笔记：\n\(t.note)\n"
    }
    return sb
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}
