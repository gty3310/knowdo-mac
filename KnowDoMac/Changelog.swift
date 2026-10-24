import AppKit
import SwiftUI

// MARK: - 版本信息（版本号来自 Info.plist；构建提交短号由构建脚本自动注入，不手写）

enum BuildInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
    /// 构建时由 Run Script 写进 App 资源目录的 build-commit.txt；带 + 表示构建时工作区有未提交改动。
    static var commit: String {
        guard let url = Bundle.main.url(forResource: "build-commit", withExtension: "txt"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "dev" }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "dev" : t
    }
    static var display: String { "v\(version) (\(commit))" }

    /// "0.10.1" 之类按数字逐段比较，a > b 返回 true。
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

// MARK: - 更新日志内容（每版随该版开发内容写死在这里；用户视角的话）

struct ChangelogEntry: Identifiable {
    let version: String
    let date: String
    let changes: [String]      // 改了什么
    let why: String            // 为什么改
    let tryIt: [String]        // 想试要按哪些按钮
    var id: String { version }
}

enum Changelog {
    /// 新版 append 在最上方。
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(
            version: "0.5.0", date: "2026-10-24",
            changes: [
                "任务衔接守卫：没有任务在计时、也不在带时长的暂停中时，全屏问你「接下来干什么？」，填名字和时长就开始，或直接点今日未完成的一条。",
                "暂停必须带时长和目的：点 ⏸ 先选去干什么（上厕所、喝水、吃饭……）和歇多久，不再有无限期暂停。",
                "暂停到点叫回：全屏叫你回来（继续 / 再歇 5 分钟 / 换下一个任务）；60 秒没理会会响起渐强闹铃。选「静音」则只发系统通知，每 5 分钟提醒一次。",
                "暂停时菜单栏、悬浮窗会显示「暂停『任务名』」和目的、还剩多久，并与手机版互相显示。",
                "空档催促：空档满几分钟后全屏页加声音一轮一轮催，直到你开始任务；强度分温和 / 标准 / 严格 / 自定义，设置存云端，和手机版共用。",
                "悬浮窗右上角 ✕ 现在会问你多久后回来（等任务结束 / 10 分钟 / 15 分钟 / 30 分钟 / 1 小时 / 自定义 / 不再出现）。",
                "新增更新日志：每个新版本首次打开会弹出，之后随时可从设置或菜单栏打开。",
            ],
            why: "两件事之间的空档最容易滑走——下一件还没定，手就先摸向了别处。让 App 永远不留「没状态的空档」：要么在计时，要么在带时长的暂停里，要么正在填下一个任务。",
            tryIt: [
                "试守卫：把正在计时的任务完成或重置，等几秒，会弹出「接下来干什么？」。",
                "试暂停：任务行 ▶/⏸、悬浮窗、菜单栏的「暂停…」→ 选目的和时长 → 开始暂停。",
                "试叫回：暂停选 1 分钟，等到点；想试静音就打开暂停卡里的「🔕 静音」。",
                "试催促：设置 → 空档催促，选强度和分钟数。",
                "试悬浮窗：把鼠标移到悬浮窗上展开，点右上角 ✕。找回：菜单栏 →「显示悬浮小窗」。",
            ]),
        ChangelogEntry(
            version: "0.4.0", date: "2026-10-24",
            changes: [
                "主列表和手机版一致：未完成在前、必要任务（带 ★）置顶、Deadline 近的靠前，并显示手机版的列（任务 / 开始时间 / 剩余 / 时长 / Deadline / 优先 / 情景）。",
                "任务存一份在本机缓存：断网也能打开 App 查看、修改任务，恢复网络后自动合并同步。",
                "不再支持 Google Drive 桥文件同步，只用账号云同步。",
            ],
            why: "手机和电脑已经共用同一个账号云同步，桥文件多余；断网时也应该看得到今天要做什么。",
            tryIt: [
                "先登录：设置 → 账号。",
                "试离线：关掉 Wi-Fi 后重新打开知行，任务仍在，状态栏显示「离线，显示本地缓存」。",
            ]),
        ChangelogEntry(
            version: "0.3.0", date: "2026-10-24",
            changes: [
                "接入线上账号同步：登录后任务与手机版实时同步。",
                "计时跨设备同步：手机上开始的倒计时，Mac 上同步显示，反之亦然。",
                "修复若干同步问题：任务时间格式、新增列缺失、登录令牌过期后实时推送中断等。",
            ],
            why: "用户希望手机与电脑看到同一份任务、同一个计时。",
            tryIt: ["设置 → 账号登录；手机上改个任务，几秒内 Mac 列表会更新；设置里可「立即同步一次」。"]),
        ChangelogEntry(
            version: "0.2.0", date: "2026-10-24",
            changes: [
                "桌面悬浮小窗：平时是一个小胶囊（任务名 + 已用/计划），鼠标移上去展开成完整面板。",
                "修复日历「现在」红线位置错位。",
                "修复「打开知行」不能把主窗口带到前台。",
            ],
            why: "悬浮窗不该一直占地方，也不该点不开、展不开；日历红线要准。",
            tryIt: ["把鼠标移到桌面右上角的小胶囊上；菜单栏 →「打开日历」看红线。"]),
        ChangelogEntry(
            version: "0.1.0", date: "2026-10-24",
            changes: [
                "知行 Mac 版第一版：任务表、计时、过半检查与结束页、开始提醒页、日历、菜单栏、悬浮小窗。",
            ],
            why: "把手机版知行的核心体验搬到 Mac 上。",
            tryIt: ["点任务行的 ▶ 开始计时。"]),
    ]
}

// MARK: - 窗口

struct ChangelogView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("更新日志").font(.system(size: 18, weight: .bold))
                Spacer()
                Text(BuildInfo.display).font(.system(size: 11)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Changelog.entries) { e in entryView(e) }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("知道了") { onClose() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 600)
    }

    private func entryView(_ e: ChangelogEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("v\(e.version)").font(.system(size: 15, weight: .bold))
                Text(e.date).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Text("改了什么").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            ForEach(e.changes, id: \.self) { c in
                Text("• " + c).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            }
            Text("为什么改").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary).padding(.top, 2)
            Text(e.why).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            Text("怎么试").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary).padding(.top, 2)
            ForEach(e.tryIt, id: \.self) { t in
                Text("▸ " + t).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

@MainActor
final class ChangelogController: NSObject, NSWindowDelegate {
    static let shared = ChangelogController()
    private var window: NSWindow?
    private let shownKey = "changelog.highestShownVersion"

    /// 新版本首次启动弹一次；关掉后不再弹（按「已展示过的最高版本」记）。
    func showIfNewVersion() {
        let shown = UserDefaults.standard.string(forKey: shownKey) ?? "0"
        guard BuildInfo.isNewer(BuildInfo.version, than: shown) else { return }
        UserDefaults.standard.set(BuildInfo.version, forKey: shownKey)
        show()
    }

    /// 设置 / 菜单栏里随时打开。
    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "更新日志"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentViewController = NSHostingController(rootView: ChangelogView(onClose: { [weak self] in
            self?.window?.close()
        }))
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}
