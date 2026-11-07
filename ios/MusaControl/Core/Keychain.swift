import Foundation
import Security

/// Small Keychain wrapper. Items are device-only (never synced to iCloud).
/// The gateway token is readable after the first unlock since boot, so an
/// Approve tapped on a notification can reach the gateway while the app is
/// in the background; the notification action itself demands Face ID or the
/// passcode (UNNotificationActionOptions.authenticationRequired).
enum Keychain {
    private static let service = "uk.co.musastudios.musacontrol"

    static func set(_ data: Data, for key: String, accessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = accessible
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func delete(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key] as CFDictionary)
    }

    /// Items saved by earlier builds used WhenUnlocked; re-save them once.
    static func migrateAccessibility(_ key: String) {
        guard !UserDefaults.standard.bool(forKey: "keychain.migrated.\(key)"), let d = get(key) else { return }
        set(d, for: key)
        UserDefaults.standard.set(true, forKey: "keychain.migrated.\(key)")
    }

    static func string(_ key: String) -> String? { get(key).flatMap { String(data: $0, encoding: .utf8) } }
    static func setString(_ s: String, for key: String) { set(Data(s.utf8), for: key) }
}
