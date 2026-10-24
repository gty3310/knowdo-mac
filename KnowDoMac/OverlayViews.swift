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
                    OverlayManager.shared.dismiss()
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
