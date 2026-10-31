import Foundation
import Security

/// DVR 密碼存放於 macOS Keychain。
///
/// 所有設備的密碼存在**同一筆**項目（JSON：設備 UUID → 密碼），每次啟動只讀一次，
/// 之後使用記憶體中的副本。這樣 App 更新或重新編譯（簽章改變）後，macOS 只會詢問一次
/// 鑰匙圈權限，而不是每台 DVR 各問一次。密碼不寫入任何檔案或 UserDefaults。
///
/// 舊版每台設備一筆（account = 設備 UUID）的項目，會在第一次讀取時搬進新項目後刪除。
enum KeychainStore {
    static let service = "local.dvrviewer.device"
    private static let vaultAccount = "all-devices"

    enum KeychainError: LocalizedError {
        case status(OSStatus)
        case notFound

        var errorDescription: String? {
            switch self {
            case .notFound: return "Keychain 中找不到此設備的密碼"
            case .status(let s): return "Keychain 錯誤（\(s)）：\(SecCopyErrorMessageString(s, nil) as String? ?? "")"
            }
        }
    }

    // 記憶體快取（DVRConnection 會從背景執行緒讀取）
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String]?

    static func setPassword(_ password: String, for id: UUID) throws {
        try lock.withLock {
            var all = try loadLocked()
            all[id.uuidString] = password
            try saveLocked(all)
        }
    }

    static func password(for id: UUID) throws -> String {
        try lock.withLock {
            guard let p = try loadLocked()[id.uuidString] else { throw KeychainError.notFound }
            return p
        }
    }

    static func deletePassword(for id: UUID) {
        lock.withLock {
            guard var all = try? loadLocked(), all.removeValue(forKey: id.uuidString) != nil else { return }
            try? saveLocked(all)
        }
    }

    // MARK: - 內部（呼叫前須持有 lock）

    private static func query(account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: service,
         kSecAttrAccount: account]
    }

    private static func loadLocked() throws -> [String: String] {
        if let c = cache { return c }
        var q = query(account: vaultAccount)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        var all: [String: String]
        switch st {
        case errSecSuccess:
            guard let d = out as? Data, let dict = try? JSONDecoder().decode([String: String].self, from: d) else {
                throw KeychainError.status(errSecDecode)
            }
            all = dict
        case errSecItemNotFound:
            all = [:]
        default:
            throw KeychainError.status(st)
        }
        // 搬移舊版（每台一筆）的項目
        let legacy = migrateLegacyLocked()
        if !legacy.isEmpty {
            all.merge(legacy) { current, _ in current }
            try saveLocked(all)
            legacy.keys.forEach { SecItemDelete(query(account: $0) as CFDictionary) }
        }
        cache = all
        return all
    }

    /// 讀取舊版每台設備一筆的密碼（account 為 UUID）
    private static func migrateLegacyLocked() -> [String: String] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                  kSecAttrService: service,
                                  kSecReturnAttributes: true,
                                  kSecMatchLimit: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[CFString: Any]] else { return [:] }
        var result: [String: String] = [:]
        for item in items {
            guard let acct = item[kSecAttrAccount] as? String, acct != vaultAccount, UUID(uuidString: acct) != nil else { continue }
            q = query(account: acct)
            q[kSecReturnData] = true
            q[kSecMatchLimit] = kSecMatchLimitOne
            var d: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &d) == errSecSuccess, let data = d as? Data {
                result[acct] = String(decoding: data, as: UTF8.self)
            }
        }
        return result
    }

    private static func saveLocked(_ all: [String: String]) throws {
        let data = try JSONEncoder().encode(all)
        let q = query(account: vaultAccount)
        var st = SecItemUpdate(q as CFDictionary, [kSecValueData: data] as CFDictionary)
        if st == errSecItemNotFound {
            var add = q
            add[kSecValueData] = data
            add[kSecAttrLabel] = "DVR Viewer 設備密碼"
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            st = SecItemAdd(add as CFDictionary, nil)
        }
        guard st == errSecSuccess else { throw KeychainError.status(st) }
        cache = all
    }
}
