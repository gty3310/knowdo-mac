import AppKit
import Foundation
import UniformTypeIdentifiers

/// 桥文件同步：与安卓 v1.5.3 同一套语义——
/// 1）按 id 对齐合并，updatedAtMs 新者胜，deleted 墓碑防复活；
/// 2）**没变化绝不回写**（按 id→updatedAtMs 签名做语义比较）；
/// 3）写之前重新读一遍最新文件再合并；
/// 4）写完回读校验任务 id 集合，不一致就并集补写一次。
/// 全部在主线程跑：桥文件只有几十 KB，主线程读写可忽略，
/// 换来的是彻底没有并发竞态（这正是安卓端踩过坑后定下的口径）。
final class SyncManager: ObservableObject {
    static let shared = SyncManager()

    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var bridgeURL: URL? = nil
    @Published private(set) var bridgeName: String = "未选择桥文件"
    @Published private(set) var lastStatus: String = "尚未选择桥文件"
    /// 桥顶层 schedule 的原始 JSON（只读，Mac 永不生成/改动它）
    @Published private(set) var scheduleRaw: JSONValue? = nil

    private let bookmarkKey = "bridgeBookmarkData"
    private var accessingURL: URL? = nil
    private var pollTimer: Timer? = nil
    private var started = false

    private init() {}

    // MARK: - 启动与轮询

    func start() {
        guard !started else { return }
        started = true
        restoreBookmark()
        synchronize()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.synchronize()
        }
    }

    // MARK: - 桥文件选择（security-scoped bookmark 持久化）

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            if url.startAccessingSecurityScopedResource() {
                accessingURL = url
            }
            bridgeURL = url
            bridgeName = url.lastPathComponent
            if stale { saveBookmark(for: url) }
        } catch {
            lastStatus = "桥文件书签已失效，请在设置里重新选择"
        }
    }

    private func saveBookmark(for url: URL) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }

    /// 弹系统文件选择框选桥文件（设置页与主窗口空态共用）。
    func chooseBridgeFile() {
        let panel = NSOpenPanel()
        panel.title = "选择知行桥文件 tasks.json"
        panel.message = "请选择与手机版共用的同一个 tasks.json（需在已同步到本机的 Google Drive 文件夹里）"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.nameFieldStringValue = "tasks.json"
        if let cur = bridgeURL {
            panel.directoryURL = cur.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let old = accessingURL {
            old.stopAccessingSecurityScopedResource()
            accessingURL = nil
        }
        saveBookmark(for: url)
        if url.startAccessingSecurityScopedResource() {
            accessingURL = url
        }
        bridgeURL = url
        bridgeName = url.lastPathComponent
        synchronize()
    }

    // MARK: - 查询与修改（所有修改都走这里，随后立刻同步）

    func task(id: String) -> TaskItem? {
        tasks.first { $0.id == id }
    }

    func upsert(_ task: TaskItem) {
        if let i = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[i] = task
        } else {
            tasks.append(task)
        }
        synchronize()
    }

    func mutate(id: String, _ change: (inout TaskItem) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[i])
        tasks[i].touch()
        synchronize()
    }

    // MARK: - 同步核心

    /// id → updatedAtMs 签名，用来判断「有没有变化」。
    private func signature(of list: [TaskItem]) -> [String: Int64] {
        var sig: [String: Int64] = [:]
        for t in list { sig[t.id] = t.updatedAtMs }
        return sig
    }

    /// 按 id 合并：updatedAtMs 新者胜；平局取远端（保证多端收敛）；
    /// 顺序以远端为准，本地独有的追加在后。deleted 墓碑就是普通任务参与比较，
    /// 旧的未删版本 updatedAtMs 更小，自然压不过墓碑，不会复活。
    static func merge(local: [TaskItem], remote: [TaskItem]) -> [TaskItem] {
        var byId: [String: TaskItem] = [:]
        var order: [String] = []
        for t in remote {
            if byId[t.id] == nil { order.append(t.id) }
            byId[t.id] = t
        }
        for t in local {
            if let r = byId[t.id] {
                if t.updatedAtMs > r.updatedAtMs { byId[t.id] = t }
            } else {
                byId[t.id] = t
                order.append(t.id)
            }
        }
        return order.compactMap { byId[$0] }
    }

    func synchronize() {
        guard let url = bridgeURL else {
            lastStatus = "尚未选择桥文件"
            return
        }
        // 1）读最新远端（读失败绝不覆盖，保住本地）
        let remote: BridgeFile
        do {
            let data = try Data(contentsOf: url)
            remote = try BridgeFile.decode(data)
        } catch {
            lastStatus = "读取桥文件失败：\(error.localizedDescription)"
            return
        }
        scheduleRaw = remote.meta["schedule"]

        // 2）合并远端 → 本地
        let merged = SyncManager.merge(local: tasks, remote: remote.tasks)
        if merged != tasks { tasks = merged }

        // 3）合并结果与远端签名一致就不回写（没变化绝不回写）
        if signature(of: merged) != signature(of: remote.tasks) {
            writeAndVerify(mergedTasks: merged, meta: remote.meta, url: url)
        }
        let visible = tasks.filter { !$0.deleted }.count
        lastStatus = "已同步 · 共 \(visible) 个任务 · \(timeFormatter.string(from: Date()))"

        // 4）同步后的自动动作检查（推迟到下一轮 runloop，避免在 synchronize 里嵌套再同步）
        DispatchQueue.main.async { [weak self] in
            self?.postSyncChecks()
        }
    }

    /// 写文件 + 回读校验 id 集合；不一致就并集再补写一次（照安卓 v1.5.3）。
    private func writeAndVerify(mergedTasks: [TaskItem], meta: [String: JSONValue], url: URL) {
        do {
            let bridge = BridgeFile(tasks: mergedTasks, meta: meta)
            let data = try bridge.encodeForWrite(tasks: mergedTasks)
            // 直接覆写（不用 .atomic：security-scoped 单文件书签下，
            // 原子写要在同目录建临时文件，可能没有目录权限）
            try data.write(to: url, options: [])
            // 回读校验
            let backData = try Data(contentsOf: url)
            let back = try BridgeFile.decode(backData)
            let expected = Set(mergedTasks.map { $0.id })
            let got = Set(back.tasks.map { $0.id })
            if got != expected {
                let union = SyncManager.merge(local: back.tasks, remote: mergedTasks)
                let bridge2 = BridgeFile(tasks: union, meta: back.meta)
                try bridge2.encodeForWrite(tasks: union).write(to: url, options: [])
                if union != tasks { tasks = union }
            }
        } catch {
            lastStatus = "写入桥文件失败：\(error.localizedDescription)"
        }
    }

    /// autoStart 检查：桥端置了 autoStart 的任务，没在计时就自动开始，并回写 false。
    private func postSyncChecks() {
        for t in tasks where t.autoStart && !t.deleted && !t.isDoneToday() {
            TimerEngine.shared.tryAutoStart(taskId: t.id)
        }
    }
}
