import AppKit
import SwiftUI

@main
struct KnowDoMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }

        Window("知行 · 今日日历", id: "calendar") {
            CalendarView()
        }
        .defaultSize(width: 560, height: 720)

        MenuBarExtra {
            MenuBarMenuView()
        } label: {
            MenuBarLabelView()
        }
        .menuBarExtraStyle(.menu)
    }
}

/// 菜单栏常驻项：咖啡杯小图标 + 当前任务名 + 剩余时间（如「plan podcast 14:33」）。
struct MenuBarLabelView: View {
    @ObservedObject private var timer = TimerEngine.shared
    @ObservedObject private var sync = SyncManager.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cup.and.saucer.fill")
            if let t = timer.topTask {
                if timer.running == nil, timer.isPaused(t.id), let p = timer.paused, let r = p.pauseReason {
                    Text("⏸ \(p.pauseEmoji ?? "")\(r) \(clockText(timer.pauseRemainingSeconds() ?? 0))")
                        .lineLimit(1)
                } else {
                    Text("\(t.title) \(clockText(displaySeconds(for: t)))")
                        .lineLimit(1)
                }
            } else {
                Text("知行")
            }
        }
    }

    private func displaySeconds(for task: TaskItem) -> Int {
        if timer.slot(for: task.id) != nil { return timer.remainingSeconds }
        return max(0, task.durationMinutes * 60)
    }
}

/// 菜单栏点开的小菜单：开始/暂停当前、打开主窗口、打开日历、退出。
struct MenuBarMenuView: View {
    @ObservedObject private var timer = TimerEngine.shared
    @ObservedObject private var sync = SyncManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let t = timer.topTask {
            if timer.running == nil, timer.isPaused(t.id), let p = timer.paused, let r = p.pauseReason {
                Text("暂停「\(t.title)」")
                Text("\(p.pauseEmoji ?? "")\(r) · 还剩 \(clockText(timer.pauseRemainingSeconds() ?? 0))")
                Button("继续") { timer.resumePaused() }
                Button("再加 5 分钟") { timer.delayResume(minutes: 5) }
                Button("换个目的…") { PauseCardController.shared.show(taskId: t.id) }
            } else {
                Text("\(t.title) · 剩 \(clockText(displaySeconds(for: t)))")
                Button(timer.isRunning(t.id) ? "暂停…" : (timer.isPaused(t.id) ? "继续" : "开始")) {
                    timer.toggle(taskId: t.id)
                }
            }
            Divider()
        }
        Button("打开主窗口") {
            (NSApp.delegate as? AppDelegate)?.showMainWindow()
        }
        Button("更新日志") { ChangelogController.shared.show() }
        Button("显示悬浮小窗") { FloatingPanelController.reveal() }
        Button("打开日历") {
            openWindow(id: "calendar")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("退出知行") {
            NSApp.terminate(nil)
        }
    }

    private func displaySeconds(for task: TaskItem) -> Int {
        if timer.slot(for: task.id) != nil { return timer.remainingSeconds }
        return max(0, task.durationMinutes * 60)
    }
}
