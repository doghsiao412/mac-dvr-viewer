import Foundation
import Security

/// DVR 密碼存放於 macOS Keychain（每台設備一筆，account = 設備 UUID）。
/// 密碼不寫入任何檔案或 UserDefaults。
enum KeychainStore {
    static let service = "local.dvrviewer.device"

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

    private static func baseQuery(_ id: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: service,
         kSecAttrAccount: id.uuidString]
    }

    static func setPassword(_ password: String, for id: UUID) throws {
        let data = Data(password.utf8)
        let q = baseQuery(id)
        let update: [CFString: Any] = [kSecValueData: data]
        var st = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if st == errSecItemNotFound {
            var add = q
            add[kSecValueData] = data
            add[kSecAttrLabel] = "DVR Viewer 設備密碼"
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            st = SecItemAdd(add as CFDictionary, nil)
        }
        guard st == errSecSuccess else { throw KeychainError.status(st) }
    }

    static func password(for id: UUID) throws -> String {
        var q = baseQuery(id)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { throw KeychainError.notFound }
        guard st == errSecSuccess, let d = out as? Data else { throw KeychainError.status(st) }
        return String(decoding: d, as: UTF8.self)
    }

    static func deletePassword(for id: UUID) {
        SecItemDelete(baseQuery(id) as CFDictionary)
    }
}
