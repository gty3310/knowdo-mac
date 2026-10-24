import SwiftUI

/// 任务编辑 sheet：覆盖全部字段——标题、情景多选、截止日期+完成时间+开始时间、
/// 每日重复、计划/实际分钟、优先级、备注（右上角带复制按钮）、专注描述/模式/名单/主应用。
struct TaskEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sync = SyncManager.shared

    @State private var draft: TaskItem
    @State private var hasDeadline: Bool
    @State private var deadlineDate: Date
    @State private var hasDeadlineTime: Bool
    @State private var deadlineTimeDate: Date
    @State private var hasNextStart: Bool
    @State private var nextStartDate: Date
    @State private var customScenario: String = ""
    @State private var copied: Bool = false
    private let isExisting: Bool

    static let presetScenarios = [
        "晨读", "上课", "自习", "作业", "家务", "工作",
        "运动", "休息", "出行", "社交", "购物", "开会",
    ]

    init(task: TaskItem) {
        _draft = State(initialValue: task)
        isExisting = SyncManager.shared.task(id: task.id) != nil

        let parsedDeadline = task.deadline.flatMap { dateFormatter.date(from: $0) }
        _hasDeadline = State(initialValue: parsedDeadline != nil)
        _deadlineDate = State(initialValue: parsedDeadline ?? Date())

        let parsedTime = task.deadlineTime.flatMap { timeFormatter.date(from: $0) }
        _hasDeadlineTime = State(initialValue: parsedTime != nil)
        _deadlineTimeDate = State(initialValue: parsedTime
            ?? Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date())
            ?? Date())

        let parsedNext = task.nextStartDate()
        _hasNextStart = State(initialValue: parsedNext != nil)
        _nextStartDate = State(initialValue: parsedNext ?? Date().addingTimeInterval(3600))
    }

    private var allScenarios: [String] {
        TaskEditView.presetScenarios
            + draft.scenarios.filter { !TaskEditView.presetScenarios.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                basicSection
                timeSection
                durationSection
                prioritySection
                noteSection
                focusSection
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 540, height: 660)
    }

    // MARK: - Sections

    private var basicSection: some View {
        Section("任务") {
            TextField("标题", text: $draft.title)
            VStack(alignment: .leading, spacing: 6) {
                Text("情景")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)],
                          alignment: .leading, spacing: 7) {
                    ForEach(allScenarios, id: \.self) { s in
                        Toggle(s, isOn: scenarioBinding(s))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                    }
                }
                HStack(spacing: 6) {
                    TextField("自定义情景", text: $customScenario)
                        .frame(width: 150)
                    Button("添加") {
                        let s = customScenario.trimmingCharacters(in: .whitespaces)
                        if !s.isEmpty && !draft.scenarios.contains(s) {
                            draft.scenarios.append(s)
                        }
                        customScenario = ""
                    }
                    .disabled(customScenario.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var timeSection: some View {
        Section("时间") {
            Picker("重复", selection: $draft.repeatMode) {
                Text("不重复").tag("none")
                Text("每日重复").tag("daily")
            }
            .pickerStyle(.segmented)

            Toggle("截止日期", isOn: $hasDeadline)
            if hasDeadline {
                DatePicker("日期", selection: $deadlineDate, displayedComponents: [.date])
                Toggle("完成时间（当天几点前）", isOn: $hasDeadlineTime)
                if hasDeadlineTime {
                    DatePicker("时间", selection: $deadlineTimeDate,
                               displayedComponents: [.hourAndMinute])
                }
            }
            Toggle("开始时间提醒（到点全屏提醒开始）", isOn: $hasNextStart)
            if hasNextStart {
                DatePicker("开始时间", selection: $nextStartDate,
                           displayedComponents: [.date, .hourAndMinute])
            }
        }
    }

    private var durationSection: some View {
        Section("时长") {
            HStack(spacing: 8) {
                Text("计划时长（分钟）")
                Spacer()
                TextField("", value: $draft.durationMinutes, format: .number)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: $draft.durationMinutes, in: 1...1440, step: 5)
                    .labelsHidden()
            }
            HStack(spacing: 8) {
                Text("实际用时（分钟，0 = 未填）")
                Spacer()
                TextField("", value: $draft.actualMinutes, format: .number)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: $draft.actualMinutes, in: 0...1440, step: 5)
                    .labelsHidden()
            }
        }
    }

    private var prioritySection: some View {
        Section("优先级") {
            Picker("优先级", selection: priorityBinding) {
                Text("必要").tag("must")
                Text("次要").tag("secondary")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var noteSection: some View {
        Section {
            TextEditor(text: $draft.note)
                .frame(height: 84)
        } header: {
            HStack {
                Text("笔记")
                Spacer()
                Button(copied ? "已复制 ✓" : "复制全部信息") {
                    copyToPasteboard(buildTaskInfo(draft))
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                }
                .font(.system(size: 11))
                .help("复制这个任务的全部信息（与安卓「复制」同款排版）")
            }
        }
    }

    private var focusSection: some View {
        Section("专注（v0.1 只同步与编辑，拦截执行在后续版本）") {
            TextField("专注描述（自然语言，如：别刷短视频和购物）", text: $draft.focusRule)
            Picker("模式", selection: $draft.focusMode) {
                Text("关闭").tag("off")
                Text("黑名单").tag("block")
                Text("白名单").tag("allow")
            }
            .pickerStyle(.segmented)
            TextField("主应用 bundle id（如 com.ti.songdu）", text: primaryAppBinding)
            TextField("不许用的应用（bundle id，逗号分隔）", text: blockedBinding)
            TextField("只许用的应用（bundle id，逗号分隔）", text: allowedBinding)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isExisting {
                Button("删除任务", role: .destructive) {
                    sync.mutate(id: draft.id) { $0.deleted = true }
                    dismiss()
                }
            }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("保存") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }

    // MARK: - Bindings

    private var priorityBinding: Binding<String> {
        Binding(get: { draft.priority ?? "secondary" },
                set: { draft.priority = $0 })
    }

    private var primaryAppBinding: Binding<String> {
        Binding(get: { draft.primaryApp ?? "" },
                set: { draft.primaryApp = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 })
    }

    private var blockedBinding: Binding<String> {
        appsBinding(get: { draft.blockedApps }, set: { draft.blockedApps = $0 })
    }

    private var allowedBinding: Binding<String> {
        appsBinding(get: { draft.allowedApps }, set: { draft.allowedApps = $0 })
    }

    private func appsBinding(get: @escaping () -> [String],
                             set: @escaping ([String]) -> Void) -> Binding<String> {
        Binding(
            get: { get().joined(separator: ", ") },
            set: { newText in
                let parts = newText
                    .components(separatedBy: CharacterSet(charactersIn: ",，、 "))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                set(parts)
            })
    }

    private func scenarioBinding(_ s: String) -> Binding<Bool> {
        Binding(
            get: { draft.scenarios.contains(s) },
            set: { on in
                if on {
                    if !draft.scenarios.contains(s) { draft.scenarios.append(s) }
                } else {
                    draft.scenarios.removeAll { $0 == s }
                }
            })
    }

    // MARK: - 保存

    private func save() {
        var t = draft
        t.deadline = hasDeadline ? dateFormatter.string(from: deadlineDate) : nil
        t.deadlineTime = (hasDeadline && hasDeadlineTime)
            ? timeFormatter.string(from: deadlineTimeDate) : nil
        t.nextStartAt = hasNextStart ? nextStartFormatter.string(from: nextStartDate) : nil
        if t.durationMinutes < 1 { t.durationMinutes = 1 }
        if t.actualMinutes < 0 { t.actualMinutes = 0 }
        t.touch()
        sync.upsert(t)
        dismiss()
    }
}
