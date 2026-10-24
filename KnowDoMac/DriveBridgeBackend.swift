import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Drive 桥文件后端

/// Google Drive 桥文件后端：负责 security-scoped bookmark 管理、
/// NSOpenPanel 文件选择、以及桥文件的读写操作。
/// 这是 SyncBackend 协议的第一个实现，行为与原 SyncManager 直连版完全一致。
final class DriveBridgeBackend: SyncBackend {
    private(set) var currentURL: URL? = nil
    private var accessingURL: URL? = nil
    private let bookmarkKey = "bridgeBookmarkData"

    var isConfigured: Bool { currentURL != nil }
    var displayName: String { currentURL?.lastPathComponent ?? "未选择桥文件" }
    var sourceURL: URL? { currentURL }

    /// 从 UserDefaults 恢复 security-scoped bookmark。
    /// 返回非 nil 表示出现了需要向用户展示的错误（书签已失效）。
    func restoreBookmark() -> String? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            if url.startAccessingSecurityScopedResource() {
                accessingURL = url
            }
            currentURL = url
            if stale { saveBookmark(for: url) }
        } catch {
            return "桥文件书签已失效，请在设置里重新选择"
        }
        return nil
    }

    private func saveBookmark(for url: URL) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }

    func fetchLatest() throws -> BackendData {
        guard let url = currentURL else { throw BackendError.notConfigured }
        let data = try Data(contentsOf: url)
        let bridge = try BridgeFile.decode(data)
        return BackendData(tasks: bridge.tasks, meta: bridge.meta)
    }

    func write(_ data: BackendData) throws {
        guard let url = currentURL else { throw BackendError.notConfigured }
        let bridge = BridgeFile(tasks: data.tasks, meta: data.meta)
        // 直接覆写（不用 .atomic：security-scoped 单文件书签下，
        // 原子写要在同目录建临时文件，可能没有目录权限）
        let encoded = try bridge.encodeForWrite(tasks: data.tasks)
        try encoded.write(to: url, options: [])
    }

    func readBack() throws -> BackendData {
        guard let url = currentURL else { throw BackendError.notConfigured }
        let data = try Data(contentsOf: url)
        let bridge = try BridgeFile.decode(data)
        return BackendData(tasks: bridge.tasks, meta: bridge.meta)
    }

    func configure(completion: @escaping (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "选择知行桥文件 tasks.json"
        panel.message = "请选择与手机版共用的同一个 tasks.json（需在已同步到本机的 Google Drive 文件夹里）"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.nameFieldStringValue = "tasks.json"
        if let cur = currentURL {
            panel.directoryURL = cur.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else {
            completion(false)
            return
        }
        if let old = accessingURL {
            old.stopAccessingSecurityScopedResource()
            accessingURL = nil
        }
        saveBookmark(for: url)
        if url.startAccessingSecurityScopedResource() {
            accessingURL = url
        }
        currentURL = url
        completion(true)
    }
}

enum BackendError: Error {
    case notConfigured
}
