import AppKit
import SwiftUI

/// 暂停目的预设（显示名与安卓 v1.11.0 同口径，写进 timer_state.pause_reason）。
struct PausePurpose: Identifiable, Equatable {
    let emoji: String
    let name: String
    var id: String { name }
    var isCustom: Bool { name == "自定义" }

    static let all: [PausePurpose] = [
        .init(emoji: "🚻", name: "上厕所"), .init(emoji: "💧", name: "喝水"),
        .init(emoji: "🥗", name: "吃饭"), .init(emoji: "📞", name: "回电话"),
        .init(emoji: "🙋", name: "喊去帮忙"), .init(emoji: "😴", name: "睡午觉"),
        .init(emoji: "🏃", name: "换换脑子"), .init(emoji: "🏫", name: "去上课"),
        .init(emoji: "✏️", name: "自定义"),
    ]
}

/// 暂停卡窗口：所有暂停入口（行内 ⏸、悬浮窗、菜单栏、过半页「暂停休息」）共用同一张。
@MainActor
final class PauseCardController: NSObject, NSWindowDelegate {
    static let shared = PauseCardController()
    private var panel: NSPanel?
    var isShowing: Bool { panel?.isVisible == true }

    func show(taskId: String) {
        close()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
                        styleMask: [.titled, .closable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = "暂停"
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.contentViewController = NSHostingController(
            rootView: PauseCardView(taskId: taskId, onClose: { [weak self] in self?.close() }))
        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }

    func close() {
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) { panel = nil }
}

struct PauseCardView: View {
    let taskId: String
    let onClose: () -> Void

    @ObservedObject private var sync = SyncManager.shared
    @State private var purpose: PausePurpose? = nil
    @State private var customName = ""
    @State private var quickMinutes: Int? = nil
    @State private var useCustomDuration = false
    @State private var customH = 0
    @State private var customM = 10
    @State private var silent = false

    private let quick: [(label: String, minutes: Int)] = [
        ("1 分钟", 1), ("3 分钟", 3), ("5 分钟", 5), ("10 分钟", 10), ("15 分钟", 15),
        ("20 分钟", 20), ("30 分钟", 30), ("60 分钟", 60), ("2 小时", 120),
    ]

    private var minutes: Int {
        useCustomDuration ? customH * 60 + customM : (quickMinutes ?? 0)
    }
    private var purposeName: String? {
        guard let p = purpose else { return nil }
        if p.isCustom {
            let n = customName.trimmingCharacters(in: .whitespaces)
            return n.isEmpty ? nil : n
        }
        return p.name
    }
    private var canStart: Bool { purposeName != nil && minutes > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("暂停「\(sync.task(id: taskId)?.title ?? "")」")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)

            Text("去干什么？").font(.system(size: 12)).foregroundColor(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(PausePurpose.all) { p in
                    Button {
                        purpose = p
                        if p.name == "去上课" { silent = true }      // 联动：上课默认静音，可手动再关
                    } label: {
                        VStack(spacing: 2) {
                            Text(p.emoji).font(.system(size: 24))
                            Text(p.name).font(.system(size: 12))
                        }
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(purpose == p ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(purpose == p ? Color.accentColor : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            if purpose?.isCustom == true {
                TextField("输入名字", text: $customName)
                    .textFieldStyle(.roundedBorder)
            }

            Text("歇多久？到点会叫你回来").font(.system(size: 12)).foregroundColor(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(quick, id: \.minutes) { q in
                    chip(q.label, on: !useCustomDuration && quickMinutes == q.minutes) {
                        useCustomDuration = false
                        quickMinutes = q.minutes
                    }
                }
                chip("自定义", on: useCustomDuration) { useCustomDuration = true }
            }
            if useCustomDuration {
                HStack(spacing: 6) {
                    Stepper("\(customH) 小时", value: $customH, in: 0...100)
                    Stepper("\(customM) 分钟", value: $customM, in: 0...59)
                }
                .font(.system(size: 12))
            }

            Toggle("🔕 静音（到点只发通知，不响不弹）", isOn: $silent)
                .font(.system(size: 12))

            Divider()
            Text(previewText)
                .font(.system(size: 12))
                .foregroundColor(canStart ? .primary : .secondary)
            HStack {
                Spacer()
                Button("取消") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("开始暂停") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { preload() }
    }

    private func chip(_ text: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 12))
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(on ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(on ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private var previewText: String {
        guard let name = purposeName, minutes > 0 else { return "选好去干什么、歇多久，才能开始暂停" }
        let end = Date().addingTimeInterval(Double(minutes) * 60)
        let dur = minutes >= 60 && minutes % 60 == 0 ? "\(minutes / 60) 小时"
            : (minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分钟" : "\(minutes) 分钟")
        return "\(purpose?.emoji ?? "") \(name) · \(dur) · \(timeFormatter.string(from: end)) 叫你回来" + (silent ? " · 🔕" : "")
    }

    /// 「换个目的」：已在暂停中时，带出当前目的与静音设置。
    private func preload() {
        guard let p = TimerEngine.shared.paused, p.taskId == taskId else { return }
        silent = p.pauseSilent ?? false
        if let r = p.pauseReason {
            if let hit = PausePurpose.all.first(where: { $0.name == r && !$0.isCustom }) {
                purpose = hit
            } else {
                purpose = PausePurpose.all.last
                customName = r
            }
        }
    }

    private func confirm() {
        guard let name = purposeName, let p = purpose, minutes > 0 else { return }
        TimerEngine.shared.pauseWithPurpose(
            taskId: taskId, minutes: minutes, reason: name,
            emoji: p.isCustom ? "✏️" : p.emoji, silent: silent)
        onClose()
    }
}
