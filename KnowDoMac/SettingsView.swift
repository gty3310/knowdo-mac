import ServiceManagement
import SwiftUI

/// 设置 sheet：桥文件、悬浮面板、开机自动启动、关于。
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sync = SyncManager.shared
    @AppStorage("showFloatingPanel") private var showFloatingPanel: Bool = true
    @State private var loginEnabled: Bool = false
    @State private var loginError: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("桥文件（与手机版共用同一个 tasks.json）") {
                    LabeledContent("当前文件") {
                        Text(sync.bridgeURL?.path ?? "未选择")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("选择 / 重新选择…") { sync.chooseBridgeFile() }
                        Button("立即同步一次") { sync.synchronize() }
                    }
                    Text("文件需在已同步到本机的 Google Drive 文件夹里。Mac 端遵守同一套同步规矩：没变化不回写、写前复读合并、写后校验。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Section("悬浮面板") {
                    Toggle("显示桌面悬浮小窗", isOn: $showFloatingPanel)
                        .onChange(of: showFloatingPanel) { _, _ in
                            NotificationCenter.default.post(
                                name: .knowdoPanelVisibilityChanged, object: nil)
                        }
                    Text("关掉后只剩菜单栏的「任务名 + 剩余时间」。小窗也可以点它右上角的 ✕ 收起。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Section("开机自动启动") {
                    Toggle("登录 Mac 时自动打开知行", isOn: Binding(
                        get: { loginEnabled },
                        set: { setLoginItem($0) }))
                    if let e = loginError {
                        Text(e)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                    Text("通过系统登录项实现。若开关失败，请把「知行 KnowDo」放进「应用程序」文件夹后再试（从 Xcode 直接 Run 时系统可能不允许注册）。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Section("关于") {
                    LabeledContent("版本") {
                        Text("知行 KnowDo for Mac v0.1")
                    }
                    Text("The Unity of Knowledge and Action · 知行合一")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("许可：CC BY-NC-SA 4.0。礼仪约定：任何人可继续开发/编辑知行，但动手前请先知会作者一声；衍生版本必须同样免费。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("与安卓版共用桥文件同步：两边都开着时，改动会在约 10 秒内互相到达；schedule 由 Muse 维护，本 App 只读。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 560)
        .onAppear { refreshLoginStatus() }
    }

    private func refreshLoginStatus() {
        loginEnabled = (SMAppService.mainApp.status == .enabled)
    }

    private func setLoginItem(_ on: Bool) {
        if on {
            do {
                try SMAppService.mainApp.register()
                loginError = nil
            } catch {
                loginError = "开启失败：\(error.localizedDescription)（把 App 放到「应用程序」文件夹后通常即可）"
            }
            refreshLoginStatus()
        } else {
            Task {
                do {
                    try await SMAppService.mainApp.unregister()
                } catch {
                    await MainActor.run {
                        loginError = "关闭失败：\(error.localizedDescription)"
                    }
                }
                await MainActor.run { refreshLoginStatus() }
            }
        }
    }
}
