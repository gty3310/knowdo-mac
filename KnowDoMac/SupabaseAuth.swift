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

    private func keychainSave(_ key: KeychainKey, _ value: String) {
        let data = Data(value.utf8)
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                  kSecAttrAccount: key.rawValue]
        if SecItemUpdate(q as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecItemNotFound {
            SecItemAdd(q.merging([kSecValueData: data]) { $1 } as CFDictionary, nil)
        }
    }

    private func keychainLoad(_ key: KeychainKey) -> String? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                  kSecAttrAccount: key.rawValue,
                                  kSecReturnData: true,
                                  kSecMatchLimit: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let d = result as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func keychainDelete(_ key: KeychainKey) {
        SecItemDelete([kSecClass: kSecClassGenericPassword,
                       kSecAttrAccount: key.rawValue] as CFDictionary)
    }
}

enum AuthError: LocalizedError {
    case notLoggedIn
    var errorDescription: String? { "尚未登录" }
}
