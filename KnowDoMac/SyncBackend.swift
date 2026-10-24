import Foundation

// MARK: - 同步后端协议

/// 数据同步后端接口：历史上有 Drive 桥文件实现（已移除），现为
/// Supabase 实现（SupabaseBackend，任务二）都遵循此协议。
/// SyncManager 只依赖此协议，不直接引用任何具体实现。
protocol SyncBackend: AnyObject {
    /// 后端是否已就绪（Drive：已选文件；Supabase：已登录）
    var isConfigured: Bool { get }
    /// 显示名称，用于 UI 展示（如 "tasks.json" 或登录邮箱）
    var displayName: String { get }
    /// 原始地址（Drive 返回文件 URL；无原始 URL 的后端返回 nil）
    var sourceURL: URL? { get }

    /// 读取后端最新数据。未就绪或读失败抛出错误。
    func fetchLatest() async throws -> BackendData
    /// 把合并后的数据写回后端。
    func write(_ data: BackendData) async throws
    /// 回读刚写入的数据，用于写后校验（四铁律第四条）。
    func readBack() async throws -> BackendData

    /// 让用户配置这个后端（Drive：弹文件选择框；Supabase：触发登录 UI）。
    /// completion(true) = 配置成功，SyncManager 应立即调用 synchronize()。
    func configure(completion: @escaping (Bool) -> Void)
}

// MARK: - 后端传输数据包

struct BackendData {
    var tasks: [TaskItem]
    var meta: [String: JSONValue]
}
