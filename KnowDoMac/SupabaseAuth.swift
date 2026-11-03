import Foundation
import Security
import SwiftUI

// MARK: - Auth 状态与操作

@MainActor
final class SupabaseAuth: ObservableObject {
    static let shared = SupabaseAuth()
    private init() { loadFromKeychain() }

    @Published private(set) var isLoggedIn = false
    @Published private(set) var userId: String? = nil
    @Published private(set) var userEmail: String? = nil
    @Published var authError: String? = nil
    @Published var isLoading = false

    // 给 SupabaseClient 调用
    var accessToken: String? { keychainLoad(.accessToken) }
    var refreshToken: String? { keychainLoad(.refreshToken) }

    // MARK: - 公开操作

    func signIn(email: String, password: String) async {
        await run {
            let data = try await SupabaseHTTP.shared.authPost(
                path: "/auth/v1/token?grant_type=password",
                body: ["email": email, "password": password])
            try self.applyAuthResponse(data, fallbackEmail: email)
        }
    }

    func signUp(email: String, password: String) async {
        await run {
            let data = try await SupabaseHTTP.shared.authPost(
                path: "/auth/v1/signup",
                body: ["email": email, "password": password])
            try self.applyAuthResponse(data, fallbackEmail: email)
        }
    }

    func signOut() async {
        isLoading = true
        if let token = accessToken {
            _ = try? await SupabaseHTTP.shared.authPost(
                path: "/auth/v1/logout", body: [:], bearerToken: token)
        }
        clearKeychain()
        isLoggedIn = false; userId = nil; userEmail = nil
        isLoading = false
    }

    /// 用 refresh_token 换新 access_token；SupabaseHTTP 在 401 时自动调用。
    func refreshSession() async throws {
        guard let rt = refreshToken else { throw AuthError.notLoggedIn }
        let data = try await SupabaseHTTP.shared.authPost(
            path: "/auth/v1/token?grant_type=refresh_token",
            body: ["refresh_token": rt])
        try applyAuthResponse(data, fallbackEmail: userEmail ?? "")
    }

    // MARK: - 内部

    private func run(_ body: @escaping () async throws -> Void) async {
        isLoading = true; authError = nil
        do { try await body() } catch { authError = error.localizedDescription }
        isLoading = false
    }

    private func applyAuthResponse(_ data: Data, fallbackEmail: String) throws {
        struct Resp: Decodable {
            let access_token: String
            let refresh_token: String
            let user: User
            struct User: Decodable { let id: String; let email: String? }
        }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        keychainSave(.accessToken, r.access_token)
        keychainSave(.refreshToken, r.refresh_token)
        let email = r.user.email ?? fallbackEmail
        keychainSave(.userId, r.user.id)
        keychainSave(.userEmail, email)
        userId = r.user.id
        userEmail = email
        isLoggedIn = true
        SupabaseRealtime.shared.updateToken()
    }

    private func loadFromKeychain() {
        userId = keychainLoad(.userId)
        userEmail = keychainLoad(.userEmail)
        isLoggedIn = accessToken != nil && userId != nil
    }

    private func clearKeychain() {
        for k in KeychainKey.allCases { keychainDelete(k) }
    }

    // MARK: - Keychain helpers

    private enum KeychainKey: String, CaseIterable {
        case accessToken = "knowdo.sb.at"
        case refreshToken = "knowdo.sb.rt"
        case userId = "knowdo.sb.uid"
        case userEmail = "knowdo.sb.email"
    }

    // 不再用钥匙串：本机自签名每次重编译签名都变，系统会反复要登录密码。
    // 改存 Application Support/KnowDoMac/auth.json（权限 0600，仅当前用户可读），内存里缓存。
    private var store: [String: String] = SupabaseAuth.loadStore()

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnowDoMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("auth.json")
    }

    private static func loadStore() -> [String: String] {
        // 一次性清掉旧版留在钥匙串里的条目（只删不读，不触发授权框）
        for k in ["knowdo.sb.at", "knowdo.sb.rt", "knowdo.sb.uid", "knowdo.sb.email"] {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrAccount: k] as CFDictionary)
        }
        guard let d = try? Data(contentsOf: storeURL),
              let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return m
    }

    private func persistStore() {
        guard let d = try? JSONEncoder().encode(store) else { return }
        let url = Self.storeURL
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func keychainSave(_ key: KeychainKey, _ value: String) {
        store[key.rawValue] = value
        persistStore()
    }

    private func keychainLoad(_ key: KeychainKey) -> String? { store[key.rawValue] }

    private func keychainDelete(_ key: KeychainKey) {
        store[key.rawValue] = nil
        persistStore()
    }
}

enum AuthError: LocalizedError {
    case notLoggedIn
    var errorDescription: String? { "尚未登录" }
}
