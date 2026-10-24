import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    let panelController = FloatingPanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        SyncManager.shared.start()
        panelController.setup()
        registerLoginItemByDefault()
    }

    /// 关掉主窗口不退出 App（菜单栏和悬浮窗继续工作）。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        TimerEngine.shared.prepareForTermination()
    }

    /// 把主窗口带到前台（悬浮窗/菜单栏的「打开知行」用）。
    /// 若主窗口已被关闭销毁，这里只能激活 App——用程序坞图标点开即可重建窗口。
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let win = NSApp.windows.first {
            $0.styleMask.contains(.titled) && !($0 is NSPanel) && $0.canBecomeMain
        }
        win?.makeKeyAndOrderFront(nil)
    }

    /// 首次启动默认注册登录项（用户明确要求开机自动启动必带）。
    /// 从 DerivedData 等非「应用程序」目录运行时系统可能拒绝，静默跳过，
    /// 设置页里可看到实际状态并手动开启。
    private func registerLoginItemByDefault() {
        let key = "loginItemDefaultRegistered.v1"
        if UserDefaults.standard.bool(forKey: key) { return }
        UserDefaults.standard.set(true, forKey: key)
        do {
            try SMAppService.mainApp.register()
        } catch {
            // 预期内会失败的场景（如 Xcode Run），不打扰用户
        }
    }
}
