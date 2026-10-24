import ServiceManagement
import SwiftUI

/// 设置 sheet：账号（Supabase）、同步、悬浮面板、开机自动启动、关于。
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sync = SyncManager.shared
    @ObservedObject private var auth = SupabaseAuth.shared
    @AppStorage("showFloatingPanel") private var showFloatingPanel: Bool = true
    @State private var loginEnabled: Bool = false
    @State private var loginError: String? = nil
    @State private var emailInput: String = ""
    @State private var passwordInput: String = ""
    @State private var isSignUp = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                accountSection

                Section("同步") {
                    Button("立即同步一次") { sync.synchronize() }
                        .disabled(!auth.isLoggedIn)
                    Text("任务经云端账号与手机版同步；schedule 由 Muse 维护，本 App 只读。")
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
        .frame(width: 480, height: 680)
        .onAppear { refreshLoginStatus() }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("账号（Supabase 云同步）") {
            if auth.isLoggedIn {
                LabeledContent("已登录") {
                    Text(auth.userEmail ?? "")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                }
                LabeledContent("同步状态") {
                    Text(sync.lastStatus)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Button("退出登录") {
                    Task {
                        await auth.signOut()
                        await MainActor.run { SyncManager.shared.handleAuthChange() }
                    }
                }
            } else {
                TextField("邮箱", text: $emailInput)
                    .textContentType(.emailAddress)
                SecureField("密码", text: $passwordInput)
                if let err = auth.authError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
                HStack {
                    Button(isSignUp ? "注册" : "登录") {
                        let e = emailInput.trimmingCharacters(in: .whitespaces)
                        let p = passwordInput
                        Task {
                            if isSignUp {
                                await auth.signUp(email: e, password: p)
                            } else {
                                await auth.signIn(email: e, password: p)
                            }
                            if auth.isLoggedIn {
                                await MainActor.run { SyncManager.shared.handleAuthChange() }
                            }
                        }
                    }
                    .disabled(emailInput.isEmpty || passwordInput.isEmpty || auth.isLoading)
                    Button(isSignUp ? "已有账号？登录" : "没有账号？注册") {
                        isSignUp.toggle()
                        auth.authError = nil
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .font(.system(size: 11.5))
                    if auth.isLoading {
                        ProgressView().scaleEffect(0.6)
                    }
                }
                Text("登录后自动启用云同步；未登录时无法读取任务。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
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
