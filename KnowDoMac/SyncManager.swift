import Foundation

/// 同步管理器：负责同步编排（四铁律）、合并逻辑、任务状态缓存与发布。
/// 具体的 I/O（Supabase REST+Realtime）由 SyncBackend
/// 实现承接；切换后端只需替换 `backend` 属性，此类无需改动。
///
/// 同步四铁律（与安卓 v1.5.3 口径一致）：
/// 1）没变化绝不回写（按 id→updatedAtMs 签名做语义比较）；
/// 2）写之前重新读一遍最新文件再合并；
/// 3）合并按 id 对齐，updatedAtMs 新者胜，deleted 墓碑不许复活；
/// 4）写后回读校验任务 id 集合，丢了就并集补写一次。
@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()

    @Published private(set) var tasks: [TaskItem] = [] {
        didSet { scheduleCacheSave() }
    }
    @Published private(set) var accountName: String = "未登录"
    @Published private(set) var lastStatus: String = "尚未登录"
    /// user_state.schedule 的原始 JSON（只读，Mac 永不生成/改动它）
    @Published private(set) var scheduleRaw: JSONValue? = nil

    private let supabaseBackend = SupabaseBackend()
    private var backend: SyncBackend { supabaseBackend }

    private var pollTimer: Timer? = nil
    private var started = false
    private var syncInFlight = false
    private var pollTick = 0
    private var cacheSaveWork: DispatchWorkItem?

    // MARK: - 本地缓存（断网也能看、能改；恢复后按 updatedAtMs 新者胜合并回云端）

    private struct Cache: Codable {
        var userId: String
        var tasks: [TaskItem]
        var schedule: JSONValue?
    }

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnowDoMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tasks-cache.json")
    }

    private func loadCache() {
        guard let uid = SupabaseAuth.shared.userId,
              let data = try? Data(contentsOf: cacheURL),
              let c = try? JSONDecoder().decode(Cache.self, from: data),
              c.userId == uid else { return }   // 换了账号就不用旧缓存
        tasks = c.tasks
        scheduleRaw = c.schedule
        accountName = SupabaseAuth.shared.userEmail ?? accountName
        lastStatus = "已载入本地缓存 · 共 \(c.tasks.filter { !$0.deleted }.count) 个任务"
    }

    private func scheduleCacheSave() {
        cacheSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveCache() }
        cacheSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveCache() {
        guard let uid = SupabaseAuth.shared.userId else { return }
        let c = Cache(userId: uid, tasks: tasks, schedule: scheduleRaw)
        if let data = try? JSONEncoder().encode(c) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    private func clearCache() {
        cacheSaveWork?.cancel()
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private init() {}

    // MARK: - 启动与轮询

    func start() {
        guard !started else { return }
        started = true
        if SupabaseAuth.shared.isLoggedIn {
            loadCache()
            connectRealtime()
        }
        synchronize()
        // 有 Realtime 推送，轮询只作 30 秒对账兜底。
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.pollTick += 1
            if self.pollTick % 3 != 0 { return }
            self.synchronize()
        }
    }

    /// Realtime 只有一个回调槽：任务变更触发同步，user_state 变更顺带拉计时状态，由这里统一分发。
    private func connectRealtime() {
        SupabaseRealtime.shared.onRemoteChange = { [weak self] in
            self?.synchronize()
            Task { @MainActor in await TimerSync.shared.pullAndApply() }
        }
        SupabaseRealtime.shared.connect()
        TimerSync.shared.start()
    }

    /// 登录/登出后调用，切换后端并重新连接 Realtime。
    func handleAuthChange() {
        if SupabaseAuth.shared.isLoggedIn {
            connectRealtime()
        } else {
            SupabaseRealtime.shared.disconnect()
            TimerSync.shared.stop()
            clearCache()
            tasks = []
            scheduleRaw = nil
            accountName = "未登录"
            lastStatus = "尚未登录"
        }
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
        guard !syncInFlight else { return }
        syncInFlight = true
        Task { [weak self] in
            await self?.doSync()
            self?.syncInFlight = false
            // 放到锁释放之后：autoStart 回写触发的 synchronize() 才不会被 guard 丢掉
            self?.postSyncChecks()
        }
    }

    private func doSync() async {
        let be = backend
        guard be.isConfigured else {
            lastStatus = SupabaseAuth.shared.isLoggedIn ? "正在连接 Supabase…" : "尚未登录，请在设置里登录账号"
            return
        }
        // 铁律二：写之前先拿最新远端
        let remote: BackendData
        do {
            remote = try await be.fetchLatest()
        } catch {
            lastStatus = tasks.isEmpty
                ? "读取失败：\(error.localizedDescription)"
                : "离线，显示本地缓存（改动会在恢复连接后自动同步）"
            return
        }
        scheduleRaw = remote.meta["schedule"]

        // 铁律三：按 id 对齐合并，updatedAtMs 新者胜
        let merged = SyncManager.merge(local: tasks, remote: remote.tasks)
        if merged != tasks { tasks = merged }

        // 铁律一：签名一致就不回写
        if signature(of: merged) != signature(of: remote.tasks) {
            await writeAndVerify(mergedTasks: merged, meta: remote.meta, backend: be)
        }
        let visible = tasks.filter { !$0.deleted }.count
        accountName = supabaseBackend.displayName
        lastStatus = "已同步 · 共 \(visible) 个任务 · \(timeFormatter.string(from: Date()))"
    }

    /// 铁律四：写 + 回读校验 id 集合；不一致就并集再补写一次。
    private func writeAndVerify(mergedTasks: [TaskItem], meta: [String: JSONValue], backend be: SyncBackend) async {
        do {
            try await be.write(BackendData(tasks: mergedTasks, meta: meta))
            let back = try await be.readBack()
            let expected = Set(mergedTasks.map { $0.id })
            let got = Set(back.tasks.map { $0.id })
            if got != expected {
                let union = SyncManager.merge(local: back.tasks, remote: mergedTasks)
                try await be.write(BackendData(tasks: union, meta: back.meta))
                if union != tasks { tasks = union }
            } else if SupabaseAuth.shared.isLoggedIn {
                adoptServerTimestamps(from: back.tasks, wrote: mergedTasks)
            }
        } catch {
            lastStatus = "写入失败：\(error.localizedDescription)"
        }
    }

    /// Supabase 的 updated_at 由服务端生成：写成功后，把刚写出的那些任务的 updatedAt 对齐成服务端值，
    /// 否则本地与云端的签名永远差一点，会每轮都重写（违反「没变化绝不回写」）。
    /// 写入后用户又改过的任务（updatedAtMs 已不是写出时的值）不动。
    private func adoptServerTimestamps(from back: [TaskItem], wrote: [TaskItem]) {
        let serverById = Dictionary(back.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let wroteMs = Dictionary(wrote.map { ($0.id, $0.updatedAtMs) }, uniquingKeysWith: { a, _ in a })
        for i in tasks.indices {
            let id = tasks[i].id
            guard let srv = serverById[id], wroteMs[id] == tasks[i].updatedAtMs,
                  srv.updatedAtMs > 0 else { continue }
            tasks[i].updatedAtMs = srv.updatedAtMs
            tasks[i].updatedAtISO = srv.updatedAtISO
        }
    }

    /// autoStart 检查：桥端置了 autoStart 的任务，没在计时就自动开始，并回写 false。
    private func postSyncChecks() {
        for t in tasks where t.autoStart && !t.deleted && !t.isDoneToday() {
            TimerEngine.shared.tryAutoStart(taskId: t.id)
        }
    }
}
