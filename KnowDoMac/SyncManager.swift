import Foundation

/// 同步管理器：负责同步编排（四铁律）、合并逻辑、任务状态缓存与发布。
/// 具体的 I/O（Drive 桥文件读写 / Supabase REST+Realtime）由 SyncBackend
/// 实现承接；切换后端只需替换 `backend` 属性，此类无需改动。
///
/// 同步四铁律（与安卓 v1.5.3 口径一致）：
/// 1）没变化绝不回写（按 id→updatedAtMs 签名做语义比较）；
/// 2）写之前重新读一遍最新文件再合并；
/// 3）合并按 id 对齐，updatedAtMs 新者胜，deleted 墓碑不许复活；
/// 4）写后回读校验任务 id 集合，丢了就并集补写一次。
final class SyncManager: ObservableObject {
    static let shared = SyncManager()

    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var bridgeURL: URL? = nil
    @Published private(set) var bridgeName: String = "未选择桥文件"
    @Published private(set) var lastStatus: String = "尚未选择桥文件"
    /// 桥顶层 schedule 的原始 JSON（只读，Mac 永不生成/改动它）
    @Published private(set) var scheduleRaw: JSONValue? = nil

    private let driveBackend = DriveBridgeBackend()
    /// 当前活跃后端；任务二接入 Supabase 后可在此切换
    private var backend: SyncBackend { driveBackend }

    private var pollTimer: Timer? = nil
    private var started = false

    private init() {}

    // MARK: - 启动与轮询

    func start() {
        guard !started else { return }
        started = true
        if let errMsg = driveBackend.restoreBookmark() {
            lastStatus = errMsg
        }
        bridgeURL = driveBackend.sourceURL
        bridgeName = driveBackend.displayName
        synchronize()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.synchronize()
        }
    }

    // MARK: - 桥文件选择

    func chooseBridgeFile() {
        driveBackend.configure { [weak self] success in
            guard let self = self, success else { return }
            DispatchQueue.main.async {
                self.bridgeURL = self.driveBackend.sourceURL
                self.bridgeName = self.driveBackend.displayName
                self.synchronize()
            }
        }
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
        guard backend.isConfigured else {
            lastStatus = "尚未选择桥文件"
            return
        }
        // 铁律二：写之前（此处为读）先拿最新远端
        let remote: BackendData
        do {
            remote = try backend.fetchLatest()
        } catch {
            lastStatus = "读取桥文件失败：\(error.localizedDescription)"
            return
        }
        scheduleRaw = remote.meta["schedule"]

        // 铁律三：按 id 对齐合并，updatedAtMs 新者胜
        let merged = SyncManager.merge(local: tasks, remote: remote.tasks)
        if merged != tasks { tasks = merged }

        // 铁律一：签名一致就不回写
        if signature(of: merged) != signature(of: remote.tasks) {
            writeAndVerify(mergedTasks: merged, meta: remote.meta)
        }
        let visible = tasks.filter { !$0.deleted }.count
        lastStatus = "已同步 · 共 \(visible) 个任务 · \(timeFormatter.string(from: Date()))"

        // 同步后的自动动作检查（推迟到下一轮 runloop，避免在 synchronize 里嵌套再同步）
        DispatchQueue.main.async { [weak self] in
            self?.postSyncChecks()
        }
    }

    /// 铁律四：写文件 + 回读校验 id 集合；不一致就并集再补写一次。
    private func writeAndVerify(mergedTasks: [TaskItem], meta: [String: JSONValue]) {
        do {
            try backend.write(BackendData(tasks: mergedTasks, meta: meta))
            let back = try backend.readBack()
            let expected = Set(mergedTasks.map { $0.id })
            let got = Set(back.tasks.map { $0.id })
            if got != expected {
                let union = SyncManager.merge(local: back.tasks, remote: mergedTasks)
                try backend.write(BackendData(tasks: union, meta: back.meta))
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
