import SwiftUI

/// 过半检查页：还在做吗——继续计时 / 就此完成 / 暂停休息（与安卓 CheckActivity 过半页一致）。
/// 弹页时计时已落段转入暂停槽：「继续」= 恢复计时，「暂停休息」= 直接关页。
struct HalfCheckView: View {
    let task: TaskItem

    var body: some View {
        OverlayScaffold {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 44))
                .foregroundColor(.white.opacity(0.9))
            Text("还在做吗？")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.white)
            Text(task.title)
                .font(.system(size: 17))
                .foregroundColor(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Text("已经过半啦")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.5))
                .padding(.bottom, 10)
            HStack(spacing: 14) {
                Button("暂停休息") {
                    // 暂停必带目的与时长：关页后弹暂停卡（任务已在暂停槽，确认后补上叫回）
                    OverlayManager.shared.dismiss()
                    PauseCardController.shared.show(taskId: task.id)
                }
                .buttonStyle(OverlayButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])

                Button("就此完成") {
                    TimerEngine.shared.completeCurrent()
                    OverlayManager.shared.dismiss()
                }
                .buttonStyle(OverlayButtonStyle())

                Button("继续计时") {
                    TimerEngine.shared.resumePaused()
                    OverlayManager.shared.dismiss()
                }
                .buttonStyle(OverlayButtonStyle(primary: true))
                .keyboardShortcut(.return, modifiers: [])
            }
        }
    }
}

/// 结束页：照参考图——🏆、Time's up、任务名、加时按钮带 Q/W/E、Mark Complete 回车确认。
struct TimeUpView: View {
    let task: TaskItem
    @State private var customMinutes: String = ""

    var body: some View {
        OverlayScaffold {
            Text("🏆")
                .font(.system(size: 44))
            Text("Time's up")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(.white)
            Text(task.title)
                .font(.system(size: 17))
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            Text("Need more time?")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.55))
                .padding(.top, 8)
            HStack(spacing: 12) {
                extendButton(minutes: 5, key: "Q", keyEquivalent: "q")
                extendButton(minutes: 15, key: "W", keyEquivalent: "w")
                extendButton(minutes: 25, key: "E", keyEquivalent: "e")
            }
            HStack(spacing: 10) {
                TextField("自定义分钟", text: $customMinutes)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                Button("加时") {
                    if let m = Int(customMinutes.trimmingCharacters(in: .whitespaces)), m > 0 {
                        TimerEngine.shared.extend(minutes: m)
                        OverlayManager.shared.dismiss()
                    }
                }
                .buttonStyle(OverlayButtonStyle())
            }
            Button("Mark Complete") {
                TimerEngine.shared.completeCurrent()
                OverlayManager.shared.dismiss()
            }
            .buttonStyle(OverlayButtonStyle(primary: true))
            .keyboardShortcut(.return, modifiers: [])
            .padding(.top, 10)
            Text("Enter to complete")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.45))
        }
    }

    private func extendButton(minutes: Int, key: String, keyEquivalent: KeyEquivalent) -> some View {
        Button {
            TimerEngine.shared.extend(minutes: minutes)
            OverlayManager.shared.dismiss()
        } label: {
            VStack(spacing: 1) {
                Text("+\(minutes) min")
                Text(key)
                    .font(.system(size: 10))
                    .opacity(0.55)
            }
        }
        .buttonStyle(OverlayButtonStyle())
        .keyboardShortcut(keyEquivalent, modifiers: [])
    }
}

/// 开始时间提醒页（nextStartAt 到点）：与安卓 StartRemindActivity 一致的三键。
/// 点「开始计时」后清掉该次 nextStartAt 写回桥。
struct StartRemindView: View {
    let task: TaskItem

    var body: some View {
        OverlayScaffold {
            Text("⏰")
                .font(.system(size: 44))
            Text("到时间了")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.white)
            Text("开始「\(task.title)」吧")
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            Text("计划时长 \(task.durationMinutes) 分钟")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.55))
                .padding(.bottom, 10)
            HStack(spacing: 14) {
                Button("忽略") {
                    OverlayManager.shared.dismiss()
                }
                .buttonStyle(OverlayButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])

                Button("延后 10 分钟") {
                    let newValue = nextStartFormatter.string(
                        from: Date().addingTimeInterval(600))
                    SyncManager.shared.mutate(id: task.id) { $0.nextStartAt = newValue }
                    OverlayManager.shared.dismiss()
                }
                .buttonStyle(OverlayButtonStyle())

                Button("开始计时") {
                    SyncManager.shared.mutate(id: task.id) { $0.nextStartAt = nil }
                    TimerEngine.shared.start(taskId: task.id)
                    OverlayManager.shared.dismiss()
                }
                .buttonStyle(OverlayButtonStyle(primary: true))
                .keyboardShortcut(.return, modifiers: [])
            }
        }
    }
}

/// 暂停到点叫回页：继续 / 再歇 5 分钟 / 换下一个任务（暂停槽保留，原任务随时可继续）。
struct ResumeCallView: View {
    let task: TaskItem
    let emoji: String
    let reason: String?

    var body: some View {
        OverlayScaffold {
            Text(emoji)
                .font(.system(size: 52))
            Text("该回来啦")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.white)
            if let r = reason {
                Text("「\(r)」的时间到了")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.65))
            }
            Text("继续「\(task.title)」吧")
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
                .padding(.bottom, 10)
            HStack(spacing: 14) {
                Button("换下一个任务") {
                    OverlayManager.shared.dismiss()
                    OverlayManager.shared.showNextTask()
                }
                .buttonStyle(OverlayButtonStyle())

                Button("再歇 5 分钟") {
                    TimerEngine.shared.delayResume(minutes: 5)
                    OverlayManager.shared.dismiss()
                }
                .buttonStyle(OverlayButtonStyle())

                Button("继续任务") {
                    TimerEngine.shared.resumePaused()
                    OverlayManager.shared.dismiss()
                }
                .buttonStyle(OverlayButtonStyle(primary: true))
                .keyboardShortcut(.return, modifiers: [])
            }
        }
    }
}

/// 任务衔接守卫页：永远不留「没状态的空档」。填下一个任务（或「休息」）并开始，或直接开今天未完成的一条。
struct NextTaskView: View {
    @ObservedObject private var sync = SyncManager.shared
    @State private var name = ""
    @State private var days = 0
    @State private var hours = 0
    @State private var mins = 0
    @FocusState private var nameFocused: Bool

    private let quick = [2, 3, 5, 10, 15, 20, 30]
    private var total: Int { days * 1440 + hours * 60 + mins }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canStart: Bool { !trimmed.isEmpty && total > 0 }

    private var todayTasks: [TaskItem] {
        Array(visibleSorted(sync.tasks.filter { !$0.deleted && !$0.isDoneToday() && $0.isTodayTask }).prefix(10))
    }

    var body: some View {
        OverlayScaffold {
            Text("接下来干什么？")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.white)

            HStack(spacing: 10) {
                TextField("任务名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 16))
                    .frame(width: 320)
                    .focused($nameFocused)
                    .onSubmit { if canStart { start() } }
                Button("休息") { name = "休息" }
                    .buttonStyle(OverlayButtonStyle())
            }

            HStack(spacing: 8) {
                ForEach(quick, id: \.self) { m in
                    Button("\(m)") { setMinutes(m) }
                        .buttonStyle(ChipStyle(on: total == m))
                }
                Text("分钟").font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
            }

            HStack(spacing: 18) {
                stepper("天", $days)
                stepper("小时", $hours)
                stepper("分钟", $mins)
            }

            Text(summary)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.6))

            Button("开始") { start() }
                .buttonStyle(OverlayButtonStyle(primary: true))
                .disabled(!canStart)
                .opacity(canStart ? 1 : 0.4)

            if !todayTasks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("今日未完成")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                    ForEach(todayTasks) { t in
                        Button {
                            TimerEngine.shared.start(taskId: t.id)
                            OverlayManager.shared.dismiss()
                        } label: {
                            HStack {
                                Text((t.priority == "must" ? "★ " : "") + t.title)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(t.durationMinutes) 分钟")
                                    .foregroundColor(.white.opacity(0.55))
                            }
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.09)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 420)
                .padding(.top, 6)
            }

            Button("稍后再说") {
                IdleGuard.shared.snoozeOnDismiss()
                OverlayManager.shared.dismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.4))
            .keyboardShortcut(.escape, modifiers: [])
        }
        .onAppear { nameFocused = true }
    }

    private func stepper(_ label: String, _ value: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            Text("\(value.wrappedValue)")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.white)
                .frame(minWidth: 28, alignment: .trailing)
            Text(label).font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
            Stepper("", value: value, in: 0...100).labelsHidden()
        }
    }

    private func setMinutes(_ m: Int) {
        days = 0; hours = m / 60; mins = m % 60
    }

    private var summary: String {
        guard total > 0 else { return "选个时长" }
        let end = Date().addingTimeInterval(Double(total) * 60)
        let cal = Calendar.current
        let endText: String
        if cal.isDateInToday(end) {
            endText = timeFormatter.string(from: end)
        } else {
            let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"
            endText = f.string(from: end)
        }
        return "合计 \(total) 分钟 · 到 \(endText) 结束"
    }

    /// 新建普通任务（priority 留空）并立即开始计时。
    private func start() {
        guard canStart else { return }
        var t = TaskItem.createNew(title: trimmed)
        t.durationMinutes = total
        SyncManager.shared.upsert(t)
        TimerEngine.shared.start(taskId: t.id)
        OverlayManager.shared.dismiss()
    }
}

struct ChipStyle: ButtonStyle {
    var on: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(minWidth: 30)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(on ? 0.85 : (configuration.isPressed ? 0.3 : 0.14))))
            .foregroundColor(on ? Color(white: 0.12) : .white)
    }
}
