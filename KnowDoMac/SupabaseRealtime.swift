import Foundation

// MARK: - Supabase Realtime（Phoenix WebSocket 协议）

/// 监听 Supabase Realtime 的 postgres_changes 事件。
/// 当 tasks 表或 user_state 表有变化时，通知 SyncManager 触发同步。
@MainActor
final class SupabaseRealtime: NSObject, URLSessionWebSocketDelegate {
    static let shared = SupabaseRealtime()
    private override init() {}

    var onRemoteChange: (() -> Void)?

    private var wsTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var heartbeatTimer: Timer?
    private var msgRef = 0
    private var isConnected = false
    private var sentToken = ""
    private var joinedTopics: [String] = []

    // MARK: - 公开接口

    func connect() {
        guard !isConnected else { return }
        guard let userId = SupabaseAuth.shared.userId else { return }
        let urlStr = Secrets.supabaseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            + "/realtime/v1/websocket?apikey=\(Secrets.supabaseKey)&vsn=1.0.0"
        guard let url = URL(string: urlStr) else { return }
        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        wsTask = urlSession?.webSocketTask(with: url)
        wsTask?.resume()
        isConnected = true
        receiveLoop()
        startHeartbeat()
        joinChannel(userId: userId)
    }

    func disconnect() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        urlSession = nil
        isConnected = false
    }

    // MARK: - Phoenix 协议

    private func joinChannel(userId: String) {
        // RLS 按人隔离靠 JWT：join 包里必须带 access_token，否则以 anon 身份订阅，收不到自己的行变更
        let token = SupabaseAuth.shared.accessToken ?? ""
        sentToken = token
        joinedTopics = ["realtime:tasks_\(userId)", "realtime:user_state_\(userId)"]
        // 订阅 tasks 表中属于当前用户的行变更
        sendMessage(topic: "realtime:tasks_\(userId)",
                    event: "phx_join",
                    payload: [
                        "access_token": token,
                        "config": [
                            "broadcast": ["ack": false, "self": false],
                            "presence": ["key": ""],
                            "postgres_changes": [
                                ["event": "*", "schema": "public", "table": "tasks",
                                 "filter": "user_id=eq.\(userId)"]
                            ]
                        ]
                    ])
        // 订阅 user_state 中当前用户的行（timer_state 变更）
        sendMessage(topic: "realtime:user_state_\(userId)",
                    event: "phx_join",
                    payload: [
                        "access_token": token,
                        "config": [
                            "broadcast": ["ack": false, "self": false],
                            "presence": ["key": ""],
                            "postgres_changes": [
                                ["event": "*", "schema": "public", "table": "user_state",
                                 "filter": "user_id=eq.\(userId)"]
                            ]
                        ]
                    ])
    }

    /// 令牌刷新后调用：用 access_token 事件把新 JWT 推给已加入的频道。
    func updateToken() {
        guard isConnected, let token = SupabaseAuth.shared.accessToken, token != sentToken else { return }
        sentToken = token
        for topic in joinedTopics {
            sendMessage(topic: topic, event: "access_token", payload: ["access_token": token])
        }
    }

    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sendMessage(topic: "phoenix", event: "heartbeat", payload: [:])
            }
        }
    }

    private func sendMessage(topic: String, event: String, payload: [String: Any]) {
        msgRef += 1
        let msg: [String: Any] = ["topic": topic, "event": event,
                                  "payload": payload, "ref": "\(msgRef)"]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }
        wsTask?.send(.string(str)) { _ in }
    }

    // MARK: - 接收循环

    private func receiveLoop() {
        wsTask?.receive { [weak self] result in
            switch result {
            case .success(let msg):
                self?.handleMessage(msg)
                self?.receiveLoop()
            case .failure:
                Task { @MainActor [weak self] in
                    self?.isConnected = false
                    // 5 秒后自动重连
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    self?.connect()
                    // 断线期间可能漏了推送：重连后触发一次对账
                    self?.onRemoteChange?()
                }
            }
        }
    }

    private func handleMessage(_ msg: URLSessionWebSocketTask.Message) {
        guard case .string(let str) = msg,
              let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String else { return }

        if event == "postgres_changes" {
            Task { @MainActor [weak self] in
                self?.onRemoteChange?()
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {}

    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        Task { @MainActor [weak self] in
            self?.isConnected = false
        }
    }
}
