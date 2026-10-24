import Foundation

// MARK: - 底层 HTTP 客户端

/// 封装所有对 Supabase REST/Auth 端点的 HTTP 调用。
/// 自动注入 apikey/Authorization 头，在 401 时尝试一次 token 刷新后重试。
final class SupabaseHTTP {
    static let shared = SupabaseHTTP()
    private init() {}

    private let base = Secrets.supabaseURL
    private let apiKey = Secrets.supabaseKey
    private var session: URLSession { .shared }

    // MARK: - Auth 端点（不走重试，避免循环）

    func authPost(path: String, body: [String: String], bearerToken: String? = nil) async throws -> Data {
        var req = request(path: path, method: "POST")
        req.httpBody = try JSONEncoder().encode(body)
        if let t = bearerToken { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await session.data(for: req)
        try checkStatus(data: data, response: resp)
        return data
    }

    // MARK: - REST 端点（带一次 token 刷新重试）

    func restGet(path: String) async throws -> Data {
        try await restCall(method: "GET", path: path, body: nil, prefer: nil)
    }

    func restPost(path: String, body: Data, prefer: String? = nil) async throws -> Data {
        try await restCall(method: "POST", path: path, body: body, prefer: prefer)
    }

    func restPatch(path: String, body: Data) async throws -> Data {
        try await restCall(method: "PATCH", path: path, body: body, prefer: nil)
    }

    func restUpsert(path: String, body: Data) async throws -> Data {
        try await restCall(method: "POST", path: path, body: body,
                           prefer: "resolution=merge-duplicates,return=minimal")
    }

    // MARK: - 内部

    private func restCall(method: String, path: String, body: Data?, prefer: String?) async throws -> Data {
        let call: () async throws -> Data = {
            var req = self.request(path: path, method: method)
            if let b = body { req.httpBody = b }
            if let p = prefer { req.setValue("return=minimal,\(p)", forHTTPHeaderField: "Prefer") }
            if let token = await SupabaseAuth.shared.accessToken {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, resp) = try await self.session.data(for: req)
            try self.checkStatus(data: data, response: resp)
            return data
        }
        do {
            return try await call()
        } catch SupabaseError.unauthorized {
            // 401：刷新 token 后重试一次
            try await SupabaseAuth.shared.refreshSession()
            return try await call()
        }
    }

    private func request(path: String, method: String) -> URLRequest {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func checkStatus(data: Data, response: URLResponse) throws {
        guard let h = response as? HTTPURLResponse else { return }
        switch h.statusCode {
        case 200...299: return
        case 401: throw SupabaseError.unauthorized
        default:
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(h.statusCode)"
            throw SupabaseError.httpError(h.statusCode, msg)
        }
    }
}

enum SupabaseError: LocalizedError {
    case unauthorized
    case httpError(Int, String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "登录已过期，请重新登录"
        case .httpError(let code, let msg): return "服务器错误 \(code): \(msg)"
        case .decodeFailed(let detail): return "数据解析失败: \(detail)"
        }
    }
}
